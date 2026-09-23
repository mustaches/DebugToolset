/**
 * @file isp_unpack.h
 * @brief ISP Studio C99 参考实现 —— RAW 解包（字节流 → uint16_t 像素帧）。
 *
 * 覆盖节点：bayer_source / cis_bayer_rggb / cis_rccb_rccg / cis_rccc /
 * cis_ryycy / cis_rgb_ir / cis_mono（这些节点的源数据装载共用同一套
 * 解包逻辑；CFA 相位语义由 isp_common.h 的 isp_bayer_color_at /
 * isp_cfa_*_at 提供，本文件只负责字节 → 采样值）。
 *
 * 对应的 Dart 语义来源：lib/modules/isp_studio/pipeline/isp_kernels.dart
 * - `enum BayerPacking`   → IspBayerPacking
 * - `frameByteSize`       → isp_frame_byte_size
 * - `unpackBayer`         → isp_unpack_bayer
 *
 * 规范要点速览见 isp_common.h 文件头注释（C99 子集 / 零动态分配 /
 * 帧约定 / 命名 / 错误码 / 中文 Doxygen / 与 Dart 逐位一致）。
 *
 * 内存模型：输出帧 out 由调用方提供（w*h 个 uint16_t）；本模块纯流式
 * 解包，无需任何 scratch 缓冲，故不提供 ISP_UNPACK_SCRATCH_BYTES 宏。
 */

#ifndef ISP_UNPACK_H
#define ISP_UNPACK_H

#include "isp_common.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------------------
 * RAW 打包方式
 * ------------------------------------------------------------------------- */

/**
 * @brief 原始字节流的打包方式。
 *
 * Dart 来源：isp_kernels.dart `enum BayerPacking`，枚举值顺序一致
 * （unpackedLsb=0, unpackedMsb=1, mipi=2，兼容直接按 Dart 侧序号传参）。
 */
typedef enum IspBayerPacking {
  /** 每像素一个 16 位字（固定 2 字节，与位深无关），数据右对齐：
   *  value = raw & mask。 */
  ISP_PACKING_UNPACKED_LSB = 0,
  /** 每像素一个 16 位字，数据左对齐（MSB 对齐）：
   *  value = raw >> (16 - bitDepth)。 */
  ISP_PACKING_UNPACKED_MSB = 1,
  /** MIPI CSI-2 打包：10bit → 4 像素 5 字节；12bit → 2 像素 3 字节。 */
  ISP_PACKING_MIPI = 2
} IspBayerPacking;

/* ---------------------------------------------------------------------------
 * 帧字节数计算
 * ------------------------------------------------------------------------- */

/**
 * @brief 计算一帧 RAW 数据在指定格式下占用的字节数（用于多帧文件切分）。
 *
 * Dart 来源：isp_kernels.dart `frameByteSize`。
 * - UNPACKED_LSB / UNPACKED_MSB：固定 pixels * 2（每像素 16 位字，与位深无关）；
 * - MIPI 10bit：(pixels * 5 + 3) ~/ 4（Dart ~/ 为向下取整）；
 * - MIPI 12bit：(pixels * 3 + 1) ~/ 2；
 * - MIPI 其他位深：Dart 抛 ArgumentError，本函数返回 ISP_ERR_UNSUPPORTED。
 *
 * @param width     帧宽（像素）。
 * @param height    帧高（像素）。
 * @param bit_depth 位深。
 * @param packing   打包方式。
 * @return >= 0 为所需字节数；< 0 为错误码（ISP_ERR_UNSUPPORTED /
 *         ISP_ERR_SIZE，宽高 <= 0 时）。
 *         返回值用 int64_t 以避免大尺寸帧 pixels*2 溢出 int。
 */
int64_t isp_frame_byte_size(int width, int height, int bit_depth,
                            IspBayerPacking packing);

/* ---------------------------------------------------------------------------
 * RAW 解包
 * --------------------------------------------------------------------------- */

/**
 * @brief 将一帧 RAW 字节流解包为 uint16_t 像素帧（长度 width*height）。
 *
 * Dart 来源：isp_kernels.dart `unpackBayer`。逐字节布局与 Dart 严格一致：
 *
 * - UNPACKED_LSB / UNPACKED_MSB（Dart `case unpackedLsb/unpackedMsb`）：
 *   每像素 2 字节，按 little_endian 组字：
 *   raw = LE ? bytes[p] | (bytes[p+1] << 8) : (bytes[p] << 8) | bytes[p+1]；
 *   LSB 对齐：out = raw & mask（mask = (1<<bitDepth)-1）；
 *   MSB 对齐：out = raw >> (16 - bitDepth)。
 *
 * - MIPI 10bit（Dart `case mipi` bitDepth==10 分支）：
 *   每组 5 字节解 4 像素：前 4 字节为各像素高 8 位，第 5 字节按
 *   bits[2i, 2i+1] 存放像素 i 的低 2 位：
 *   out = (bytes[p+i] << 2) | ((lsb >> (2*i)) & 0x3)。
 *   要求 width*height % 4 == 0（Dart 对尾像素视为错误）。
 *
 * - MIPI 12bit（Dart bitDepth==12 分支）：
 *   每组 3 字节解 2 像素：
 *   p0 = (bytes[p] << 4) | (bytes[p+2] & 0xF)；
 *   p1 = (bytes[p+1] << 4) | (bytes[p+2] >> 4)。
 *   要求 width*height % 2 == 0。
 *
 * 与 Dart 的错误对应关系：
 * - bitDepth 不在 1..16 / MIPI 位深非 10/12 / packing 枚举非法
 *   → ISP_ERR_UNSUPPORTED（Dart 抛 ArgumentError）；
 * - 从 byte_offset 起可用字节不足一帧
 *   → ISP_ERR_SIZE（Dart 抛 ArgumentError "Buffer too small"）；
 * - MIPI 10bit 像素数非 4 的倍数、MIPI 12bit 像素数非 2 的倍数
 *   → ISP_ERR_SIZE（Dart 抛 ArgumentError；Dart 是先写部分输出再抛，
 *   本实现在解包前预检，返回错误时 out 内容未定义，调用方不应使用）。
 *
 * @param bytes        原始字节缓冲。
 * @param bytes_len    bytes 的总长度（字节）。
 * @param width        帧宽（像素），> 0。
 * @param height       帧高（像素），> 0。
 * @param bit_depth    位深（1..16；MIPI 仅 10/12）。
 * @param packing      打包方式。
 * @param little_endian 16 位字字节序（仅 UNPACKED_* 有意义；MIPI 忽略，
 *                     与 Dart 一致——Dart 的 littleEndian 只用于 unpacked 分支）。
 * @param byte_offset  帧数据在 bytes 中的起始偏移。
 * @param out          输出帧缓冲，调用方提供，容量至少 width*height 个
 *                     uint16_t。
 * @return ISP_OK 或负错误码（ISP_ERR_ARG / ISP_ERR_SIZE /
 *         ISP_ERR_UNSUPPORTED）。
 */
int isp_unpack_bayer(const uint8_t *bytes, size_t bytes_len, int width,
                     int height, int bit_depth, IspBayerPacking packing,
                     bool little_endian, size_t byte_offset, uint16_t *out);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* ISP_UNPACK_H */
