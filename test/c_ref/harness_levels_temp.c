/**
 * @file harness_levels_temp.c
 * @brief 对拍 harness —— levels / 色温组：levels_lut（out0=u16[4096]）/
 * levels_apply（in1=lut）/ color_temp_gains / color_temp_whitepoint /
 * color_temp_ccm / color_temp_measure_cct（均出 scalars）。
 *
 * params 约定：
 * - levels_lut：mode（spline/bezier/linear/gamma，缺省 spline）、
 *   points（"x0,y0;x1,y1;..."，缺失/空 -> 恒等曲线）、gamma（double，
 *   仅 gamma 模式使用）。无输入帧；输出 out0 = 4096 级 LUT。
 * - levels_apply：width, height, max_value；in0 = w*h*3 交织 RGB 帧，
 *   in1 = 4096 级 LUT；输出 out0 = w*h*3。
 * - color_temp_gains：targetCct（double）、referenceCct（int，<=0 默认
 *   6500）；scalars 输出 r/g/b。
 * - color_temp_whitepoint：cct（int）；scalars 输出 r/g/b。
 * - color_temp_ccm：r/g/b（double 增益）；scalars 输出 m0..m8（行优先）。
 * - color_temp_measure_cct：width, height；inRaw0 = w*h*4 RGBA8888 字节；
 *   scalars 输出 cct。无法估计（全黑/色度奇异）时返回
 *   ISP_ERR_UNSUPPORTED（进程非零退出，对应 Dart 返回 null）。
 */

#include "harness.h"
#include "isp_levels.h"
#include "isp_color_temp.h"

#include <stdlib.h>
#include <string.h>

/**
 * 解析 "x0,y0;x1,y1;..." 为扁平 double 数组（malloc，调用方 free）。
 * 空串/NULL -> *out_xy=NULL, *out_n=0。语法错误截断到已解析前缀。
 */
static void parse_points(const char *s, double **out_xy, int *out_n) {
  int cap = 8, n = 0;
  double *buf;
  *out_xy = NULL;
  *out_n = 0;
  if (s == NULL || *s == '\0') return;
  buf = (double *)malloc((size_t)cap * 2u * sizeof(double));
  if (buf == NULL) return;
  while (*s != '\0') {
    char *end;
    double x = strtod(s, &end);
    double y;
    if (end == s || *end != ',') break;
    s = end + 1;
    y = strtod(s, &end);
    if (end == s) break;
    s = end;
    if (n >= cap) {
      double *nb;
      cap *= 2;
      nb = (double *)realloc(buf, (size_t)cap * 2u * sizeof(double));
      if (nb == NULL) break;
      buf = nb;
    }
    buf[2 * n] = x;
    buf[2 * n + 1] = y;
    n++;
    if (*s == ';') {
      s++;
    } else {
      break;
    }
  }
  if (n == 0) {
    free(buf);
    return;
  }
  *out_xy = buf;
  *out_n = n;
}

int op_levels_lut(CaseIO *io) {
  const char *mode_name = case_param_str(io, "mode", "spline");
  const IspLevelsCurveMode mode = isp_levels_curve_mode_from_name(mode_name);
  const double gamma = case_param_double(io, "gamma", 1.0);
  double *raw = NULL;
  int raw_n = 0;
  double *norm = NULL;
  int norm_n = 0;
  double *scratch = NULL;
  uint16_t *lut = NULL;
  int rc = ISP_OK;

  parse_points(case_param_str(io, "points", NULL), &raw, &raw_n);
  norm = (double *)malloc((size_t)(raw_n < 2 ? 2 : raw_n) * 2u *
                          sizeof(double));
  lut = (uint16_t *)malloc(ISP_LEVELS_LUT_SIZE * sizeof(uint16_t));
  if (norm == NULL || lut == NULL) {
    snprintf(io->err, CASE_ERR_LEN, "levels_lut: out of memory");
    rc = ISP_ERR_ARG;
    goto done;
  }
  rc = isp_levels_normalize_points(raw, raw_n, norm,
                                   raw_n < 2 ? 2 : raw_n, &norm_n);
  if (rc != ISP_OK) goto done;
  scratch = (double *)case_scratch(io, ISP_LEVELS_SCRATCH_BYTES(norm_n));
  if (scratch == NULL) {
    rc = ISP_ERR_ARG;
    goto done;
  }
  rc = isp_levels_curve_lut(norm, norm_n, mode, gamma, scratch, lut);
  if (rc != ISP_OK) goto done;
  rc = case_write_out(io, 0, lut, ISP_LEVELS_LUT_SIZE);

done:
  free(raw);
  free(norm);
  free(scratch);
  free(lut);
  return rc;
}

int op_levels_apply(CaseIO *io) {
  const int w = case_param_int(io, "width", 0);
  const int h = case_param_int(io, "height", 0);
  const int max_value = case_param_int(io, "max_value", 1023);
  const size_t len = (size_t)(w > 0 ? w : 0) * (size_t)(h > 0 ? h : 0) * 3u;
  uint16_t *frame = NULL;
  uint16_t *lut = NULL;
  uint16_t *out = NULL;
  int rc;

  if (w <= 0 || h <= 0) {
    snprintf(io->err, CASE_ERR_LEN, "levels_apply: bad size %dx%d", w, h);
    return ISP_ERR_SIZE;
  }
  frame = case_load_in(io, 0, len);
  if (frame == NULL) return ISP_ERR_ARG;
  lut = case_load_in(io, 1, ISP_LEVELS_LUT_SIZE);
  if (lut == NULL) {
    free(frame);
    return ISP_ERR_ARG;
  }
  out = (uint16_t *)malloc(len * sizeof(uint16_t));
  if (out == NULL) {
    snprintf(io->err, CASE_ERR_LEN, "levels_apply: out of memory");
    free(frame);
    free(lut);
    return ISP_ERR_ARG;
  }
  rc = isp_levels_apply_rgb(frame, w, h, lut, max_value, out);
  if (rc == ISP_OK) rc = case_write_out(io, 0, out, len);
  free(frame);
  free(lut);
  free(out);
  return rc;
}

int op_color_temp_gains(CaseIO *io) {
  const double target = case_param_double(io, "targetCct", 6500.0);
  const int ref = case_param_int(io, "referenceCct", 6500);
  double gains[3];
  int rc = isp_color_temp_gains(target, ref, gains);
  if (rc != ISP_OK) return rc;
  rc = case_scalar(io, "r", gains[0]);
  if (rc == ISP_OK) rc = case_scalar(io, "g", gains[1]);
  if (rc == ISP_OK) rc = case_scalar(io, "b", gains[2]);
  return rc;
}

int op_color_temp_whitepoint(CaseIO *io) {
  const int cct = case_param_int(io, "cct", 6500);
  double rgb[3];
  int rc = isp_color_temp_white_point(cct, rgb);
  if (rc != ISP_OK) return rc;
  rc = case_scalar(io, "r", rgb[0]);
  if (rc == ISP_OK) rc = case_scalar(io, "g", rgb[1]);
  if (rc == ISP_OK) rc = case_scalar(io, "b", rgb[2]);
  return rc;
}

int op_color_temp_ccm(CaseIO *io) {
  double gains[3];
  double ccm[9];
  int i, rc;
  gains[0] = case_param_double(io, "r", 1.0);
  gains[1] = case_param_double(io, "g", 1.0);
  gains[2] = case_param_double(io, "b", 1.0);
  isp_color_temp_ccm(gains, ccm);
  for (i = 0; i < 9; i++) {
    char key[8];
    snprintf(key, sizeof(key), "m%d", i);
    rc = case_scalar(io, key, ccm[i]);
    if (rc != ISP_OK) return rc;
  }
  return ISP_OK;
}

int op_color_temp_measure_cct(CaseIO *io) {
  const int w = case_param_int(io, "width", 0);
  const int h = case_param_int(io, "height", 0);
  uint8_t *rgba;
  int cct = 0;
  int rc;

  if (w <= 0 || h <= 0) {
    snprintf(io->err, CASE_ERR_LEN, "measure_cct: bad size %dx%d", w, h);
    return ISP_ERR_SIZE;
  }
  rgba = case_load_in_raw(io, 0, (size_t)w * (size_t)h * 4u);
  if (rgba == NULL) return ISP_ERR_ARG;
  rc = isp_color_temp_measure_cct(rgba, w, h, &cct);
  free(rgba);
  if (rc != ISP_OK) return rc;
  return case_scalar(io, "cct", (double)cct);
}
