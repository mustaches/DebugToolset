#include "isp_unpack.h"

/**
 * @file isp_unpack.c
 * @brief ISP Studio C99 参考实现 —— RAW 解包实现。
 *
 * 覆盖节点：bayer_source / cis_bayer_rggb / cis_rccb_rccg / cis_rccc /
 * cis_ryycy / cis_rgb_ir / cis_mono。
 *
 * 对应的 Dart 语义来源：lib/modules/isp_studio/pipeline/isp_kernels.dart
 * - isp_frame_byte_size ← `frameByteSize`
 * - isp_unpack_bayer    ← `unpackBayer`
 *
 * 数值说明：本模块全部操作为整数位运算（移位、掩码、字节拼接），
 * 与 Dart 的 Uint8List/Uint16List 语义天然逐位一致，无舍入问题。
 * Dart int 为 64 位，字节数中间计算用 int64_t 对齐，避免溢出分歧。
 */

int64_t isp_frame_byte_size(int width, int height, int bit_depth,
                            IspBayerPacking packing) {
  const int64_t pixels = (int64_t)width * (int64_t)height;
  if (width <= 0 || height <= 0) return ISP_ERR_SIZE;
  switch (packing) {
    case ISP_PACKING_UNPACKED_LSB:
    case ISP_PACKING_UNPACKED_MSB:
      /* 固定每像素 2 字节（16 位字），与位深无关（Dart 注释原话）。 */
      return pixels * 2;
    case ISP_PACKING_MIPI:
      /* Dart ~/ 为向下取整，正数下 C 整数除法同为截断，语义一致。 */
      if (bit_depth == 10) return (pixels * 5 + 3) / 4;
      if (bit_depth == 12) return (pixels * 3 + 1) / 2;
      /* Dart：MIPI packing supports only 10 or 12 bits。 */
      return ISP_ERR_UNSUPPORTED;
    default:
      return ISP_ERR_UNSUPPORTED;
  }
}

int isp_unpack_bayer(const uint8_t *bytes, size_t bytes_len, int width,
                     int height, int bit_depth, IspBayerPacking packing,
                     bool little_endian, size_t byte_offset, uint16_t *out) {
  int64_t needed64;
  size_t needed;
  size_t pixels;
  size_t p;
  size_t i;

  if (bytes == NULL || out == NULL) return ISP_ERR_ARG;
  if (width <= 0 || height <= 0) return ISP_ERR_SIZE;

  /* Dart：bitDepth 必须在 1..16，否则 ArgumentError。
   * 按任务约定映射为 ISP_ERR_UNSUPPORTED（不支持的位深）。 */
  if (bit_depth < 1 || bit_depth > 16) return ISP_ERR_UNSUPPORTED;

  needed64 = isp_frame_byte_size(width, height, bit_depth, packing);
  if (needed64 < 0) return (int)needed64; /* MIPI 非法位深等 → UNSUPPORTED */
  needed = (size_t)needed64;

  /* Dart：byteOffset < 0 || bytes.length - byteOffset < needed → 缓冲不足。
   * C 侧 byte_offset 为无符号，只需防 byte_offset > bytes_len 时的下溢。 */
  if (byte_offset > bytes_len || bytes_len - byte_offset < needed) {
    return ISP_ERR_SIZE;
  }

  pixels = (size_t)width * (size_t)height;

  switch (packing) {
    case ISP_PACKING_UNPACKED_LSB:
    case ISP_PACKING_UNPACKED_MSB: {
      /* Dart：固定每像素 2 字节（16 位字），8/10/12/14/16 位深同样按字读取。
       * isLsb: out = raw & mask；MSB: out = raw >> (16 - bitDepth)。 */
      const int is_lsb = (packing == ISP_PACKING_UNPACKED_LSB);
      const unsigned int mask = (unsigned int)((1 << bit_depth) - 1);
      const int shift = 16 - bit_depth;
      p = byte_offset;
      for (i = 0; i < pixels; i++, p += 2) {
        const unsigned int raw = little_endian
            ? ((unsigned int)bytes[p] | ((unsigned int)bytes[p + 1] << 8))
            : (((unsigned int)bytes[p] << 8) | (unsigned int)bytes[p + 1]);
        out[i] = (uint16_t)(is_lsb ? (raw & mask) : (raw >> shift));
      }
      return ISP_OK;
    }
    case ISP_PACKING_MIPI:
      if (bit_depth == 10) {
        /* MIPI 10bit：4 像素 / 5 字节。前 4 字节为各像素高 8 位，
         * 第 5 字节的 bits[2i, 2i+1] 为像素 i 的低 2 位。
         * Dart 先解包再检查 pixels % 4；此处预检（出错时 out 未定义，
         * 与 Dart 抛异常后调用方拿不到输出等价）。 */
        const size_t groups = pixels / 4;
        size_t g;
        size_t o = 0;
        if (pixels % 4 != 0) return ISP_ERR_SIZE;
        p = byte_offset;
        for (g = 0; g < groups; g++, p += 5) {
          const unsigned int lsb = bytes[p + 4];
          for (i = 0; i < 4; i++) {
            out[o++] = (uint16_t)(((unsigned int)bytes[p + i] << 2) |
                                  ((lsb >> (2 * i)) & 0x3u));
          }
        }
        return ISP_OK;
      } else if (bit_depth == 12) {
        /* MIPI 12bit：2 像素 / 3 字节。
         * p0 = b0 : b2[3:0]；p1 = b1 : b2[7:4]。 */
        const size_t groups = pixels / 2;
        size_t g;
        size_t o = 0;
        if (pixels % 2 != 0) return ISP_ERR_SIZE;
        p = byte_offset;
        for (g = 0; g < groups; g++, p += 3) {
          out[o++] = (uint16_t)(((unsigned int)bytes[p] << 4) |
                                ((unsigned int)bytes[p + 2] & 0xFu));
          out[o++] = (uint16_t)(((unsigned int)bytes[p + 1] << 4) |
                                ((unsigned int)bytes[p + 2] >> 4));
        }
        return ISP_OK;
      }
      /* MIPI 位深非 10/12（isp_frame_byte_size 已拦截，防御性兜底）。 */
      return ISP_ERR_UNSUPPORTED;
    default:
      return ISP_ERR_UNSUPPORTED;
  }
}
