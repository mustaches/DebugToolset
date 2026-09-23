/**
 * @file harness_unpack.c
 * @brief 对拍 harness —— unpack 组（RAW 位流解包 isp_unpack_bayer +
 *        帧字节数 isp_frame_byte_size）。
 *
 * params 约定（unpack）：
 *   width, height        帧宽高（int，> 0）
 *   bit_depth            位深（int，1..16；MIPI 仅 10/12）
 *   packing              打包方式：字符串 unpackedLsb / unpackedMsb / mipi，
 *                        或枚举整数 0/1/2（与 Dart BayerPacking 序号一致）
 *   little_endian        16 位字字节序（0/1，仅 unpacked_* 有意义，默认 1）
 *   byte_offset          帧数据在字节流中的起始偏移（int，默认 0）
 *   raw_len              inRaw0.bin 的总字节数（int，必填；size_only 时不需要）
 *   size_only            为 1 时只输出 frame_byte_size 标量、不做解包
 *                        （用于验证 isp_frame_byte_size 的取整公式，包括
 *                        pixels%4!=0 / pixels%2!=0 等无法成功解包的组合；
 *                        非法组合时标量为负错误码，与 Dart 抛异常对应）
 * 输入：inRaw0.bin 原始字节流（长度 = raw_len）。
 * 输出：out0.bin = w*h 个 u16；scalars.txt 含 frame_byte_size。
 */

#include "harness.h"
#include "isp_unpack.h"

#include <stdlib.h>
#include <string.h>

/** packing 字符串/枚举整数 -> IspBayerPacking；非法返回 -1。 */
static int parse_packing(const char *s) {
  if (strcmp(s, "unpackedLsb") == 0) return ISP_PACKING_UNPACKED_LSB;
  if (strcmp(s, "unpackedMsb") == 0) return ISP_PACKING_UNPACKED_MSB;
  if (strcmp(s, "mipi") == 0) return ISP_PACKING_MIPI;
  /* 兼容直接按 Dart 枚举序号传 0/1/2。 */
  if (s[0] >= '0' && s[0] <= '9') return atoi(s);
  return -1;
}

int op_unpack(CaseIO *io) {
  const int w = case_param_int(io, "width", 0);
  const int h = case_param_int(io, "height", 0);
  const int bit_depth = case_param_int(io, "bit_depth", 10);
  const char *packing_str = case_param_str(io, "packing", "unpackedLsb");
  const int packing = parse_packing(packing_str);
  const int little_endian = case_param_int(io, "little_endian", 1);
  const int byte_offset_i = case_param_int(io, "byte_offset", 0);
  const int size_only = case_param_int(io, "size_only", 0);
  const int raw_len = case_param_int(io, "raw_len", -1);
  const size_t len = (size_t)w * (size_t)h;
  int64_t fbs;
  uint8_t *raw;
  uint16_t *out;
  int rc;

  if (w <= 0 || h <= 0) {
    snprintf(io->err, CASE_ERR_LEN, "unpack: bad size %dx%d", w, h);
    return ISP_ERR_SIZE;
  }
  if (packing < 0) {
    snprintf(io->err, CASE_ERR_LEN, "unpack: bad packing %s", packing_str);
    return ISP_ERR_ARG;
  }
  if (byte_offset_i < 0) {
    snprintf(io->err, CASE_ERR_LEN, "unpack: bad byte_offset %d",
             byte_offset_i);
    return ISP_ERR_ARG;
  }

  /* 帧字节数标量：合法组合为字节数，非法组合为负错误码（Dart 侧对应
   * frameByteSize 抛 ArgumentError，测试按符号断言）。 */
  fbs = isp_frame_byte_size(w, h, bit_depth, (IspBayerPacking)packing);
  rc = case_scalar(io, "frame_byte_size", (double)fbs);
  if (rc != ISP_OK) return rc;

  if (size_only) {
    /* 只验证 isp_frame_byte_size，不解包（覆盖无法成功解包的取整组合）。 */
    return ISP_OK;
  }
  if (fbs < 0) return (int)fbs;

  if (raw_len < 0) {
    snprintf(io->err, CASE_ERR_LEN, "unpack: missing raw_len");
    return ISP_ERR_ARG;
  }
  raw = case_load_in_raw(io, 0, (size_t)raw_len);
  if (raw == NULL) return ISP_ERR_ARG;

  out = (uint16_t *)malloc(len * 2);
  if (out == NULL) {
    snprintf(io->err, CASE_ERR_LEN, "unpack: out of memory (%lu bytes)",
             (unsigned long)(len * 2));
    free(raw);
    return ISP_ERR_ARG;
  }

  rc = isp_unpack_bayer(raw, (size_t)raw_len, w, h, bit_depth,
                        (IspBayerPacking)packing, little_endian != 0,
                        (size_t)byte_offset_i, out);
  if (rc == ISP_OK) rc = case_write_out(io, 0, out, len);
  free(out);
  free(raw);
  return rc;
}
