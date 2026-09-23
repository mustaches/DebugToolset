#include "isp_split.h"

/**
 * @file isp_split.c
 * @brief ISP Studio C99 参考实现 —— 分路/合路器组实现（纯平面拆分与合并）。
 *
 * 覆盖节点与 Dart 来源见 isp_split.h 文件头。本组函数全部为纯数据搬运：
 * 交织帧 ↔ 三个单通道平面，无舍入、无钳位、无色彩运算，输出与输入
 * 逐位一致。零动态分配：输出缓冲全部由调用方提供，且无需任何 scratch
 * 临时缓冲（故不提供 ISP_SPLIT_SCRATCH_BYTES 宏）。
 *
 * 不移植的 PC 侧逻辑：分路器 case 的跨色彩域兜底转换（yuvToRgb /
 * hslToRgb / rgbToYuv / rgbToHsl）属色彩空间组；YUV 平面轨道
 * （yuvPlanes8 零拷贝）为 PC 内存优化，嵌入式一律走 16 位交织路径。
 */

/* ---------------------------------------------------------------------------
 * 内部 helper
 * ------------------------------------------------------------------------- */

/**
 * @brief 交织帧拆三平面的公共实现（三个分路器语义相同，仅端口名不同）。
 *
 * Dart 来源：pipeline_runner.dart 三个 splitter case 的拆路循环
 * （dst0[i]=src[3i], dst1[i]=src[3i+1], dst2[i]=src[3i+2]）。
 */
static void isp_split3_impl(const uint16_t *src, int pixels,
                            uint16_t *dst0, uint16_t *dst1, uint16_t *dst2) {
  int s = 0;
  for (int i = 0; i < pixels; i++, s += 3) {
    dst0[i] = src[s];
    dst1[i] = src[s + 1];
    dst2[i] = src[s + 2];
  }
}

/**
 * @brief 三平面合交织的公共实现，每路独立缺省值。
 *
 * Dart 来源：pipeline_runner.dart 三个 combiner case 的合并循环：
 * combined[3i+c] = (data != null && i < data.length) ? data[i] : def_c。
 * 指针 NULL 或 i 超出该路有效长度时填 def。
 */
static void isp_combine3_impl(uint16_t *dst, int pixels,
                              const uint16_t *in0, int len0, uint16_t def0,
                              const uint16_t *in1, int len1, uint16_t def1,
                              const uint16_t *in2, int len2, uint16_t def2) {
  int d = 0;
  for (int i = 0; i < pixels; i++, d += 3) {
    dst[d]     = (in0 != NULL && i < len0) ? in0[i] : def0;
    dst[d + 1] = (in1 != NULL && i < len1) ? in1[i] : def1;
    dst[d + 2] = (in2 != NULL && i < len2) ? in2[i] : def2;
  }
}

/* ---------------------------------------------------------------------------
 * 分路器
 * ------------------------------------------------------------------------- */

int isp_split_rgb(const uint16_t *src, int w, int h, int max_value,
                  uint16_t *out_r, uint16_t *out_g, uint16_t *out_b) {
  (void)max_value; /* 纯拷贝与量化上限无关，仅为签名一致保留 */
  if (src == NULL || out_r == NULL || out_g == NULL || out_b == NULL) {
    return ISP_ERR_ARG;
  }
  if (w <= 0 || h <= 0) return ISP_ERR_SIZE;
  isp_split3_impl(src, w * h, out_r, out_g, out_b);
  return ISP_OK;
}

int isp_split_yuv(const uint16_t *src, int w, int h, int max_value,
                  uint16_t *out_y, uint16_t *out_u, uint16_t *out_v) {
  (void)max_value;
  if (src == NULL || out_y == NULL || out_u == NULL || out_v == NULL) {
    return ISP_ERR_ARG;
  }
  if (w <= 0 || h <= 0) return ISP_ERR_SIZE;
  isp_split3_impl(src, w * h, out_y, out_u, out_v);
  return ISP_OK;
}

int isp_split_hsl(const uint16_t *src, int w, int h, int max_value,
                  uint16_t *out_h, uint16_t *out_s, uint16_t *out_l) {
  (void)max_value;
  if (src == NULL || out_h == NULL || out_s == NULL || out_l == NULL) {
    return ISP_ERR_ARG;
  }
  if (w <= 0 || h <= 0) return ISP_ERR_SIZE;
  isp_split3_impl(src, w * h, out_h, out_s, out_l);
  return ISP_OK;
}

/* ---------------------------------------------------------------------------
 * 合路器
 * ------------------------------------------------------------------------- */

int isp_combine_rgb(const uint16_t *in_r, int r_len,
                    const uint16_t *in_g, int g_len,
                    const uint16_t *in_b, int b_len,
                    int w, int h, int max_value, uint16_t *dst) {
  (void)max_value; /* Dart 中 RGB 合路缺省值恒 0，不使用 max */
  if (dst == NULL) return ISP_ERR_ARG;
  if (w <= 0 || h <= 0) return ISP_ERR_SIZE;
  isp_combine3_impl(dst, w * h, in_r, r_len, 0, in_g, g_len, 0, in_b, b_len, 0);
  return ISP_OK;
}

int isp_combine_yuv(const uint16_t *in_y, int y_len,
                    const uint16_t *in_u, int u_len,
                    const uint16_t *in_v, int v_len,
                    int w, int h, int max_value, uint16_t *dst) {
  /* Dart: mid = max >> 1（非负 max 的算术右移，C 中 int >> 同语义）；
   * Y 缺省 0，U/V 缺省 mid。 */
  const uint16_t mid = (uint16_t)(max_value >> 1);
  if (dst == NULL) return ISP_ERR_ARG;
  if (w <= 0 || h <= 0) return ISP_ERR_SIZE;
  isp_combine3_impl(dst, w * h,
                    in_y, y_len, 0, in_u, u_len, mid, in_v, v_len, mid);
  return ISP_OK;
}

int isp_combine_hsl(const uint16_t *in_h, int h_len,
                    const uint16_t *in_s, int s_len,
                    const uint16_t *in_l, int l_len,
                    int w, int h, int max_value, uint16_t *dst) {
  (void)max_value; /* Dart 中 HSL 合路缺省值恒 0，不使用 max */
  if (dst == NULL) return ISP_ERR_ARG;
  if (w <= 0 || h <= 0) return ISP_ERR_SIZE;
  isp_combine3_impl(dst, w * h, in_h, h_len, 0, in_s, s_len, 0, in_l, l_len, 0);
  return ISP_OK;
}
