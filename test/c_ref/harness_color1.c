/**
 * @file harness_color1.c
 * @brief 对拍 harness —— 色彩组 1：white_balance_apply / white_balance_auto
 * （出 scalars）/ ccm / tonemap（RGBA 输出为 u8 流，用 case_write_out_u8）。
 *
 * params 约定：
 * - white_balance_apply：width, height, rGain, bGain, max_value；
 *   输入 in0.bin = w*h*3 个 u16（交织 RGB），原地修改后写 out0.bin。
 * - white_balance_auto：width, height, sampleStride；输入 in0.bin 同上，
 *   输出 scalars.txt 的 rGain/bGain（Dart 返回 record (rGain, bGain)，
 *   顺序为 r 在前）。
 * - ccm：width, height, m0..m8（九个 double，行主序）, max_value；
 *   输入 in0.bin 同上，原地修改后写 out0.bin。
 * - tonemap：width, height, max_value, gamma, brightness, contrast；
 *   输入 in0.bin 同上，输出 out0.bin 为 w*h*4 字节 RGBA8888 u8 流
 *   （经 case_write_out_u8）；LUT scratch 按 ISP_GAMMA_LUT_BYTES 分配。
 */

#include "harness.h"
#include "isp_white_balance.h"
#include "isp_ccm.h"
#include "isp_gamma.h"

#include <stdlib.h>
#include <string.h>

int op_white_balance_apply(CaseIO *io) {
  const int w = case_param_int(io, "width", 0);
  const int h = case_param_int(io, "height", 0);
  const size_t len = (size_t)w * (size_t)h * 3;
  uint16_t *frame;
  int rc;

  if (w <= 0 || h <= 0) {
    snprintf(io->err, CASE_ERR_LEN, "white_balance_apply: bad size %dx%d", w, h);
    return ISP_ERR_SIZE;
  }
  frame = case_load_in(io, 0, len);
  if (frame == NULL) return ISP_ERR_ARG;

  rc = isp_white_balance_apply(frame, w, h, case_param_double(io, "rGain", 1.0),
                               case_param_double(io, "bGain", 1.0),
                               case_param_int(io, "max_value", 1023));
  if (rc == ISP_OK) rc = case_write_out(io, 0, frame, len);
  free(frame);
  return rc;
}

int op_white_balance_auto(CaseIO *io) {
  const int w = case_param_int(io, "width", 0);
  const int h = case_param_int(io, "height", 0);
  const size_t len = (size_t)w * (size_t)h * 3;
  uint16_t *frame;
  double r_gain = 1.0, b_gain = 1.0;
  int rc;

  if (w <= 0 || h <= 0) {
    snprintf(io->err, CASE_ERR_LEN, "white_balance_auto: bad size %dx%d", w, h);
    return ISP_ERR_SIZE;
  }
  frame = case_load_in(io, 0, len);
  if (frame == NULL) return ISP_ERR_ARG;

  rc = isp_white_balance_auto_gains(frame, w, h,
                                    case_param_int(io, "sampleStride", 16),
                                    &r_gain, &b_gain);
  /* Dart 返回 record (rGain, bGain)，r 在前；scalars 键名与 Dart 字段同名。 */
  if (rc == ISP_OK) rc = case_scalar(io, "rGain", r_gain);
  if (rc == ISP_OK) rc = case_scalar(io, "bGain", b_gain);
  free(frame);
  return rc;
}

int op_ccm(CaseIO *io) {
  const int w = case_param_int(io, "width", 0);
  const int h = case_param_int(io, "height", 0);
  const size_t len = (size_t)w * (size_t)h * 3;
  static const char *kKeys[9] = {"m0", "m1", "m2", "m3", "m4",
                                 "m5", "m6", "m7", "m8"};
  double matrix[9];
  uint16_t *frame;
  int i, rc;

  if (w <= 0 || h <= 0) {
    snprintf(io->err, CASE_ERR_LEN, "ccm: bad size %dx%d", w, h);
    return ISP_ERR_SIZE;
  }
  for (i = 0; i < 9; i++) {
    /* 缺省为单位阵元素（行主序对角 1 其余 0）。 */
    matrix[i] = case_param_double(io, kKeys[i], (i % 4 == 0) ? 1.0 : 0.0);
  }
  frame = case_load_in(io, 0, len);
  if (frame == NULL) return ISP_ERR_ARG;

  rc = isp_ccm_apply(frame, w, h, matrix, case_param_int(io, "max_value", 1023));
  if (rc == ISP_OK) rc = case_write_out(io, 0, frame, len);
  free(frame);
  return rc;
}

int op_tonemap(CaseIO *io) {
  const int w = case_param_int(io, "width", 0);
  const int h = case_param_int(io, "height", 0);
  const int max_value = case_param_int(io, "max_value", 1023);
  const size_t len = (size_t)w * (size_t)h * 3;
  const size_t rgba_len = (size_t)w * (size_t)h * 4;
  uint16_t *frame;
  uint8_t *lut;
  uint8_t *rgba;
  int rc;

  if (w <= 0 || h <= 0) {
    snprintf(io->err, CASE_ERR_LEN, "tonemap: bad size %dx%d", w, h);
    return ISP_ERR_SIZE;
  }
  frame = case_load_in(io, 0, len);
  if (frame == NULL) return ISP_ERR_ARG;

  /* LUT scratch 由 harness 按头文件宏 malloc（ISP_GAMMA_LUT_BYTES）。 */
  lut = (uint8_t *)case_scratch(io, ISP_GAMMA_LUT_BYTES(max_value));
  if (lut == NULL) {
    free(frame);
    return ISP_ERR_ARG;
  }
  rgba = (uint8_t *)case_scratch(io, rgba_len);
  if (rgba == NULL) {
    free(lut);
    free(frame);
    return ISP_ERR_ARG;
  }

  rc = isp_gamma_tonemap_to_rgba(frame, w, h, max_value,
                                 case_param_double(io, "gamma", 1.0),
                                 case_param_double(io, "brightness", 0.0),
                                 case_param_double(io, "contrast", 1.0), rgba,
                                 lut);
  if (rc == ISP_OK) rc = case_write_out_u8(io, 0, rgba, rgba_len);
  free(rgba);
  free(lut);
  free(frame);
  return rc;
}

/**
 * 白平衡 LUT 查表（LUT 模式）：in0=帧（w*h*3 u16），in1=lutR，in2=lutB
 *（各 max_value+1 个 u16，由 Dart 建表函数生成后经输入文件传入）。
 */
int op_white_balance_lut_apply(CaseIO *io) {
  const int w = case_param_int(io, "width", 0);
  const int h = case_param_int(io, "height", 0);
  const int max_value = case_param_int(io, "max_value", 1023);
  const size_t len = (size_t)w * (size_t)h * 3;
  uint16_t *frame, *lut_r, *lut_b;
  int rc;
  if (w <= 0 || h <= 0) {
    snprintf(io->err, CASE_ERR_LEN, "white_balance_lut_apply: bad size %dx%d",
             w, h);
    return ISP_ERR_SIZE;
  }
  frame = case_load_in(io, 0, len);
  lut_r = case_load_in(io, 1, (size_t)max_value + 1);
  lut_b = case_load_in(io, 2, (size_t)max_value + 1);
  if (frame == NULL || lut_r == NULL || lut_b == NULL) return ISP_ERR_ARG;
  rc = isp_white_balance_lut_apply(frame, w, h, lut_r, lut_b, max_value);
  if (rc == ISP_OK) rc = case_write_out(io, 0, frame, len);
  free(frame);
  free(lut_r);
  free(lut_b);
  return rc;
}
