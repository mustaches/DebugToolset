/**
 * @file harness_raw1.c
 * @brief 对拍 harness —— RAW 域组 1：black_level / dpc / lsc / grgb_balance。
 *
 * params 约定（black_level）：
 *   width, height        帧宽高（int）
 *   pattern              rggb / bggr / grbg / gbrg / mono（mono 走统一偏移）
 *   r, gr, gb, b         四相位偏移（double；mono 只用 r）
 * 输入：in0.bin = w*h 个 u16；输出：out0.bin 同尺寸。
 *
 * params 约定（dpc）：
 *   width, height        帧宽高（int）
 *   pattern              -1 = mono（全像素 ±1 邻域），0..3 = rggb/bggr/grbg/
 *                        gbrg（同相位 ±2 邻域；序号与 IspBayerPattern 一致）
 *   threshold            离群阈值，满量程百分比（double）
 *   mode                 median / directional
 *   max_value            采样最大值（int，默认 1023）
 *
 * params 约定（lsc）：
 *   width, height        帧宽高（int）
 *   pattern              -1 = mono / 0..3 = Bayer（增益与相位无关，内核忽略，
 *                        仅为接口对称保留解析校验）
 *   strength, centerX, centerY  校正强度与归一化中心（double）
 *   max_value            采样最大值（int，默认 1023）
 *
 * params 约定（grgb_balance）：
 *   width, height        帧宽高（int）
 *   pattern              0..3 = rggb/bggr/grbg/gbrg（必选，仅 Bayer 有意义）
 *   strength             收敛强度（double）
 */

#include "harness.h"
#include "isp_black_level.h"
#include "isp_dpc.h"
#include "isp_lsc.h"
#include "isp_grgb_balance.h"

#include <stdlib.h>
#include <string.h>

/** Bayer 模式字符串 -> IspBayerPattern；非法返回 -1。 */
static int parse_pattern(const char *s) {
  if (strcmp(s, "rggb") == 0) return ISP_BAYER_RGGB;
  if (strcmp(s, "bggr") == 0) return ISP_BAYER_BGGR;
  if (strcmp(s, "grbg") == 0) return ISP_BAYER_GRBG;
  if (strcmp(s, "gbrg") == 0) return ISP_BAYER_GBRG;
  return -1;
}

int op_black_level(CaseIO *io) {
  const int w = case_param_int(io, "width", 0);
  const int h = case_param_int(io, "height", 0);
  const char *pattern = case_param_str(io, "pattern", "rggb");
  const size_t len = (size_t)w * (size_t)h;
  uint16_t *frame;
  int rc;

  if (w <= 0 || h <= 0) {
    snprintf(io->err, CASE_ERR_LEN, "black_level: bad size %dx%d", w, h);
    return ISP_ERR_SIZE;
  }
  frame = case_load_in(io, 0, len);
  if (frame == NULL) return ISP_ERR_ARG;

  if (strcmp(pattern, "mono") == 0) {
    rc = isp_black_level_apply_mono(frame, w, h,
                                    case_param_double(io, "r", 0.0));
  } else {
    const int pat = parse_pattern(pattern);
    if (pat < 0) {
      snprintf(io->err, CASE_ERR_LEN, "black_level: bad pattern %s", pattern);
      free(frame);
      return ISP_ERR_ARG;
    }
    rc = isp_black_level_apply(frame, w, h, (IspBayerPattern)pat,
                               case_param_double(io, "r", 0.0),
                               case_param_double(io, "gr", 0.0),
                               case_param_double(io, "gb", 0.0),
                               case_param_double(io, "b", 0.0));
  }
  if (rc == ISP_OK) rc = case_write_out(io, 0, frame, len);
  free(frame);
  return rc;
}

int op_dpc(CaseIO *io) {
  const int w = case_param_int(io, "width", 0);
  const int h = case_param_int(io, "height", 0);
  const int pat = case_param_int(io, "pattern", -1);
  const double threshold = case_param_double(io, "threshold", 5.0);
  const char *mode = case_param_str(io, "mode", "median");
  const int max_value = case_param_int(io, "max_value", 1023);
  const size_t len = (size_t)w * (size_t)h;
  IspDpcMode dpc_mode;
  IspBayerPattern pattern_enum = ISP_BAYER_RGGB;
  const IspBayerPattern *pattern_ptr = NULL;
  uint16_t *frame;
  int rc;

  if (w <= 0 || h <= 0) {
    snprintf(io->err, CASE_ERR_LEN, "dpc: bad size %dx%d", w, h);
    return ISP_ERR_SIZE;
  }
  if (strcmp(mode, "median") == 0) {
    dpc_mode = ISP_DPC_MEDIAN;
  } else if (strcmp(mode, "directional") == 0) {
    dpc_mode = ISP_DPC_DIRECTIONAL;
  } else {
    snprintf(io->err, CASE_ERR_LEN, "dpc: bad mode %s", mode);
    return ISP_ERR_ARG;
  }
  if (pat == -1) {
    pattern_ptr = NULL; /* mono：全像素 ±1 邻域 */
  } else if (pat >= 0 && pat <= 3) {
    pattern_enum = (IspBayerPattern)pat;
    pattern_ptr = &pattern_enum;
  } else {
    snprintf(io->err, CASE_ERR_LEN, "dpc: bad pattern %d", pat);
    return ISP_ERR_ARG;
  }
  frame = case_load_in(io, 0, len);
  if (frame == NULL) return ISP_ERR_ARG;

  rc = isp_dpc_apply(frame, w, h, pattern_ptr, threshold, dpc_mode, max_value);
  if (rc == ISP_OK) rc = case_write_out(io, 0, frame, len);
  free(frame);
  return rc;
}

int op_lsc(CaseIO *io) {
  const int w = case_param_int(io, "width", 0);
  const int h = case_param_int(io, "height", 0);
  const int pat = case_param_int(io, "pattern", -1);
  const double strength = case_param_double(io, "strength", 0.5);
  const double center_x = case_param_double(io, "centerX", 0.5);
  const double center_y = case_param_double(io, "centerY", 0.5);
  const int max_value = case_param_int(io, "max_value", 1023);
  const size_t len = (size_t)w * (size_t)h;
  uint16_t *frame;
  int rc;

  if (w <= 0 || h <= 0) {
    snprintf(io->err, CASE_ERR_LEN, "lsc: bad size %dx%d", w, h);
    return ISP_ERR_SIZE;
  }
  /* 增益与相位无关（Dart applyLsc 函数体未用 pattern），仅校验取值域。 */
  if (pat < -1 || pat > 3) {
    snprintf(io->err, CASE_ERR_LEN, "lsc: bad pattern %d", pat);
    return ISP_ERR_ARG;
  }
  frame = case_load_in(io, 0, len);
  if (frame == NULL) return ISP_ERR_ARG;

  rc = isp_lsc_apply(frame, w, h, strength, center_x, center_y, max_value);
  if (rc == ISP_OK) rc = case_write_out(io, 0, frame, len);
  free(frame);
  return rc;
}

int op_grgb_balance(CaseIO *io) {
  const int w = case_param_int(io, "width", 0);
  const int h = case_param_int(io, "height", 0);
  const int pat = case_param_int(io, "pattern", -1);
  const double strength = case_param_double(io, "strength", 1.0);
  const size_t len = (size_t)w * (size_t)h;
  uint16_t *frame;
  int rc;

  if (w <= 0 || h <= 0) {
    snprintf(io->err, CASE_ERR_LEN, "grgb_balance: bad size %dx%d", w, h);
    return ISP_ERR_SIZE;
  }
  if (pat < 0 || pat > 3) {
    snprintf(io->err, CASE_ERR_LEN, "grgb_balance: bad pattern %d", pat);
    return ISP_ERR_ARG;
  }
  frame = case_load_in(io, 0, len);
  if (frame == NULL) return ISP_ERR_ARG;

  rc = isp_grgb_balance_apply(frame, w, h, (IspBayerPattern)pat, strength);
  if (rc == ISP_OK) rc = case_write_out(io, 0, frame, len);
  free(frame);
  return rc;
}
