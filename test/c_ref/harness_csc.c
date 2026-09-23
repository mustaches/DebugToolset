/**
 * @file harness_csc.c
 * @brief 对拍 harness —— 色彩空间转换组：rgb/yuv/hsl 六向互换。
 *
 * 公共 params 约定：
 *   width, height   帧宽高（int）
 *   max_value       采样最大值（int，默认 1023）
 * 输入：in0.bin = w*h*3 个 u16（交织三通道）；输出：out0.bin 同尺寸。
 * csc_rgb2yuv 额外参数：
 *   standard        bt601 / bt709（默认 bt601）
 *   range           full / limited（默认 full）
 */

#include "harness.h"
/* isp_csc 全家桶已按变体拆分：对拍 harness 引用全部六个变体头。 */
#include "isp_csc_rgb2yuv.h"
#include "isp_csc_rgb2hsl.h"
#include "isp_csc_yuv2rgb.h"
#include "isp_csc_yuv2hsl.h"
#include "isp_csc_hsl2rgb.h"
#include "isp_csc_hsl2yuv.h"

#include <stdlib.h>
#include <string.h>

/** 读公共尺寸参数并加载输入帧；失败返回 NULL（w/h/max_value 经出参返回）。 */
static uint16_t *csc_load_frame(CaseIO *io, int *w, int *h, int *max_value) {
  *w = case_param_int(io, "width", 0);
  *h = case_param_int(io, "height", 0);
  *max_value = case_param_int(io, "max_value", 1023);
  if (*w <= 0 || *h <= 0) {
    snprintf(io->err, CASE_ERR_LEN, "csc: bad size %dx%d", *w, *h);
    return NULL;
  }
  return case_load_in(io, 0, (size_t)(*w) * (size_t)(*h) * 3);
}

/** 内核成功后写回 out0；调用方负责 free in/out。 */
static int csc_run(CaseIO *io, uint16_t *out, size_t len, int rc) {
  if (rc == ISP_OK) rc = case_write_out(io, 0, out, len);
  return rc;
}

int op_csc_rgb2yuv(CaseIO *io) {
  int w, h, max_value;
  const char *standard = case_param_str(io, "standard", "bt601");
  const char *range = case_param_str(io, "range", "full");
  uint16_t *in = csc_load_frame(io, &w, &h, &max_value);
  uint16_t *out;
  size_t len;
  int rc, std_id, rng_id;
  if (in == NULL) return ISP_ERR_ARG;
  if (strcmp(standard, "bt709") == 0) {
    std_id = ISP_CSC_BT709;
  } else if (strcmp(standard, "bt601") == 0) {
    std_id = ISP_CSC_BT601;
  } else {
    snprintf(io->err, CASE_ERR_LEN, "csc_rgb2yuv: bad standard %s", standard);
    free(in);
    return ISP_ERR_ARG;
  }
  if (strcmp(range, "limited") == 0) {
    rng_id = ISP_CSC_RANGE_LIMITED;
  } else if (strcmp(range, "full") == 0) {
    rng_id = ISP_CSC_RANGE_FULL;
  } else {
    snprintf(io->err, CASE_ERR_LEN, "csc_rgb2yuv: bad range %s", range);
    free(in);
    return ISP_ERR_ARG;
  }
  len = (size_t)w * (size_t)h * 3;
  out = (uint16_t *)case_scratch(io, len * 2);
  if (out == NULL) {
    free(in);
    return ISP_ERR_ARG;
  }
  rc = isp_csc_rgb_to_yuv(in, w, h, max_value, (IspCscStandard)std_id,
                          (IspCscRange)rng_id, out);
  rc = csc_run(io, out, len, rc);
  free(in);
  free(out);
  return rc;
}

/** 五个无附加参数的转换 op 的公共骨架。 */
typedef int (*CscKernel)(const uint16_t *src, int w, int h, int max_value,
                         uint16_t *out);

static int csc_simple_op(CaseIO *io, CscKernel kernel) {
  int w, h, max_value;
  uint16_t *in = csc_load_frame(io, &w, &h, &max_value);
  uint16_t *out;
  size_t len;
  int rc;
  if (in == NULL) return ISP_ERR_ARG;
  len = (size_t)w * (size_t)h * 3;
  out = (uint16_t *)case_scratch(io, len * 2);
  if (out == NULL) {
    free(in);
    return ISP_ERR_ARG;
  }
  rc = kernel(in, w, h, max_value, out);
  rc = csc_run(io, out, len, rc);
  free(in);
  free(out);
  return rc;
}

int op_csc_rgb2hsl(CaseIO *io) {
  return csc_simple_op(io, isp_csc_rgb_to_hsl);
}

int op_csc_yuv2rgb(CaseIO *io) {
  return csc_simple_op(io, isp_csc_yuv_to_rgb);
}

int op_csc_yuv2hsl(CaseIO *io) {
  return csc_simple_op(io, isp_csc_yuv_to_hsl);
}

int op_csc_hsl2rgb(CaseIO *io) {
  return csc_simple_op(io, isp_csc_hsl_to_rgb);
}

int op_csc_hsl2yuv(CaseIO *io) {
  return csc_simple_op(io, isp_csc_hsl_to_yuv);
}
