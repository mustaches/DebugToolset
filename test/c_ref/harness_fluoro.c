/**
 * @file harness_fluoro.c
 * @brief 对拍 harness —— 荧光组：fluoro_leak / fluoro_background /
 * fluoro_normalize / fluoro_temporal（has_history=0/1 两形态，out0=输出帧
 * out1=新历史）/ pseudo_color / fluoro_fusion（in0=白光rgb in1=荧光mono）。
 *
 * params 约定：
 * - fluoro_leak：width, height, level, maxSub；in0=w*h，out0 同尺寸。
 * - fluoro_background：width, height, blockSize, strength；in0/out0 同尺寸。
 * - fluoro_normalize：width, height, reference, epsilon, maxValue；
 *   in0/out0 同尺寸。
 * - fluoro_temporal：width, height, alpha, motionAdapt(0/1), maxValue,
 *   has_history(0/1)；in0=当前帧，has_history=1 时 in1=历史帧；
 *   out0=输出帧，out1=新历史帧。
 * - pseudo_color：width, height, colormap(green/magenta/hot), gain, maxValue；
 *   in0=w*h，out0=w*h*3 交织 RGB。
 * - fluoro_fusion：width, height, mode(alpha/contour), threshold, alphaMax,
 *   colormap, offsetX, offsetY, maxValue；in0=w*h*3 白光 RGB，in1=w*h
 *   荧光 mono，out0=w*h*3。
 */

#include "harness.h"
#include "isp_fluoro.h"

#include <stdlib.h>
#include <string.h>

/** 伪彩色表字符串 -> IspFluoroColormap；非法返回 -1。 */
static int parse_colormap(const char *s) {
  if (strcmp(s, "green") == 0) return ISP_FLUORO_CMAP_GREEN;
  if (strcmp(s, "magenta") == 0) return ISP_FLUORO_CMAP_MAGENTA;
  if (strcmp(s, "hot") == 0) return ISP_FLUORO_CMAP_HOT;
  return -1;
}

/** 融合模式字符串 -> IspFluoroFusionMode；非法返回 -1。 */
static int parse_fusion_mode(const char *s) {
  if (strcmp(s, "alpha") == 0) return ISP_FLUORO_FUSION_ALPHA;
  if (strcmp(s, "contour") == 0) return ISP_FLUORO_FUSION_CONTOUR;
  return -1;
}

int op_fluoro_leak(CaseIO *io) {
  const int w = case_param_int(io, "width", 0);
  const int h = case_param_int(io, "height", 0);
  const size_t len = (size_t)w * (size_t)h;
  uint16_t *mono;
  int rc;

  if (w <= 0 || h <= 0) {
    snprintf(io->err, CASE_ERR_LEN, "fluoro_leak: bad size %dx%d", w, h);
    return ISP_ERR_SIZE;
  }
  mono = case_load_in(io, 0, len);
  if (mono == NULL) return ISP_ERR_ARG;

  rc = isp_fluoro_leak_apply(mono, w, h, case_param_double(io, "level", 0.0),
                             case_param_double(io, "maxSub", 65535.0));
  if (rc == ISP_OK) rc = case_write_out(io, 0, mono, len);
  free(mono);
  return rc;
}

int op_fluoro_background(CaseIO *io) {
  const int w = case_param_int(io, "width", 0);
  const int h = case_param_int(io, "height", 0);
  const int bs = case_param_int(io, "blockSize", 16);
  const size_t len = (size_t)w * (size_t)h;
  uint16_t *mono;
  void *scratch;
  int rc;

  if (w <= 0 || h <= 0) {
    snprintf(io->err, CASE_ERR_LEN, "fluoro_background: bad size %dx%d", w, h);
    return ISP_ERR_SIZE;
  }
  mono = case_load_in(io, 0, len);
  if (mono == NULL) return ISP_ERR_ARG;
  scratch = case_scratch(io, ISP_FLUORO_BACKGROUND_SCRATCH_BYTES(w, h, bs));
  if (scratch == NULL) {
    free(mono);
    return ISP_ERR_ARG;
  }

  rc = isp_fluoro_background_apply(mono, w, h, bs,
                                   case_param_double(io, "strength", 1.0),
                                   scratch);
  if (rc == ISP_OK) rc = case_write_out(io, 0, mono, len);
  free(scratch);
  free(mono);
  return rc;
}

int op_fluoro_normalize(CaseIO *io) {
  const int w = case_param_int(io, "width", 0);
  const int h = case_param_int(io, "height", 0);
  const size_t len = (size_t)w * (size_t)h;
  uint16_t *mono;
  int rc;

  if (w <= 0 || h <= 0) {
    snprintf(io->err, CASE_ERR_LEN, "fluoro_normalize: bad size %dx%d", w, h);
    return ISP_ERR_SIZE;
  }
  mono = case_load_in(io, 0, len);
  if (mono == NULL) return ISP_ERR_ARG;

  rc = isp_fluoro_normalize_apply(
      mono, w, h, case_param_double(io, "reference", 0.0),
      case_param_double(io, "epsilon", 1.0),
      case_param_int(io, "maxValue", 1023));
  if (rc == ISP_OK) rc = case_write_out(io, 0, mono, len);
  free(mono);
  return rc;
}

int op_fluoro_temporal(CaseIO *io) {
  const int w = case_param_int(io, "width", 0);
  const int h = case_param_int(io, "height", 0);
  const int has_history = case_param_int(io, "has_history", 0);
  const size_t len = (size_t)w * (size_t)h;
  uint16_t *mono;
  uint16_t *history;
  uint16_t *out;
  int rc;

  if (w <= 0 || h <= 0) {
    snprintf(io->err, CASE_ERR_LEN, "fluoro_temporal: bad size %dx%d", w, h);
    return ISP_ERR_SIZE;
  }
  mono = case_load_in(io, 0, len);
  if (mono == NULL) return ISP_ERR_ARG;
  history = (uint16_t *)case_scratch(io, len * sizeof(uint16_t));
  out = (uint16_t *)case_scratch(io, len * sizeof(uint16_t));
  if (history == NULL || out == NULL) {
    free(out);
    free(history);
    free(mono);
    return ISP_ERR_ARG;
  }
  if (has_history) {
    uint16_t *hist_in = case_load_in(io, 1, len);
    if (hist_in == NULL) {
      free(out);
      free(history);
      free(mono);
      return ISP_ERR_ARG;
    }
    memcpy(history, hist_in, len * sizeof(uint16_t));
    free(hist_in);
  }

  rc = isp_fluoro_temporal_iir_apply(
      mono, history, has_history != 0, out, w, h,
      case_param_double(io, "alpha", 0.5),
      case_param_int(io, "motionAdapt", 0) != 0,
      case_param_int(io, "maxValue", 1023));
  if (rc == ISP_OK) rc = case_write_out(io, 0, out, len);
  /* out1 = 新历史帧（内核原地更新 history 缓冲）。 */
  if (rc == ISP_OK) rc = case_write_out(io, 1, history, len);
  free(out);
  free(history);
  free(mono);
  return rc;
}

int op_pseudo_color(CaseIO *io) {
  const int w = case_param_int(io, "width", 0);
  const int h = case_param_int(io, "height", 0);
  const char *colormap = case_param_str(io, "colormap", "green");
  const size_t len = (size_t)w * (size_t)h;
  const int cm = parse_colormap(colormap);
  uint16_t *mono;
  uint16_t *out_rgb;
  int rc;

  if (w <= 0 || h <= 0) {
    snprintf(io->err, CASE_ERR_LEN, "pseudo_color: bad size %dx%d", w, h);
    return ISP_ERR_SIZE;
  }
  if (cm < 0) {
    snprintf(io->err, CASE_ERR_LEN, "pseudo_color: bad colormap %s", colormap);
    return ISP_ERR_ARG;
  }
  mono = case_load_in(io, 0, len);
  if (mono == NULL) return ISP_ERR_ARG;
  out_rgb = (uint16_t *)case_scratch(io, len * 3 * sizeof(uint16_t));
  if (out_rgb == NULL) {
    free(mono);
    return ISP_ERR_ARG;
  }

  rc = isp_fluoro_pseudo_color_apply(
      mono, out_rgb, w, h, (IspFluoroColormap)cm,
      case_param_double(io, "gain", 1.0),
      case_param_int(io, "maxValue", 1023));
  if (rc == ISP_OK) rc = case_write_out(io, 0, out_rgb, len * 3);
  free(out_rgb);
  free(mono);
  return rc;
}

int op_fluoro_fusion(CaseIO *io) {
  const int w = case_param_int(io, "width", 0);
  const int h = case_param_int(io, "height", 0);
  const char *mode = case_param_str(io, "mode", "alpha");
  const char *colormap = case_param_str(io, "colormap", "green");
  const size_t len = (size_t)w * (size_t)h;
  const int md = parse_fusion_mode(mode);
  const int cm = parse_colormap(colormap);
  uint16_t *rgb_wl;
  uint16_t *mono_fl;
  uint16_t *out_rgb;
  int rc;

  if (w <= 0 || h <= 0) {
    snprintf(io->err, CASE_ERR_LEN, "fluoro_fusion: bad size %dx%d", w, h);
    return ISP_ERR_SIZE;
  }
  if (md < 0) {
    snprintf(io->err, CASE_ERR_LEN, "fluoro_fusion: bad mode %s", mode);
    return ISP_ERR_ARG;
  }
  if (cm < 0) {
    snprintf(io->err, CASE_ERR_LEN, "fluoro_fusion: bad colormap %s", colormap);
    return ISP_ERR_ARG;
  }
  rgb_wl = case_load_in(io, 0, len * 3);
  if (rgb_wl == NULL) return ISP_ERR_ARG;
  mono_fl = case_load_in(io, 1, len);
  if (mono_fl == NULL) {
    free(rgb_wl);
    return ISP_ERR_ARG;
  }
  out_rgb = (uint16_t *)case_scratch(io, len * 3 * sizeof(uint16_t));
  if (out_rgb == NULL) {
    free(mono_fl);
    free(rgb_wl);
    return ISP_ERR_ARG;
  }

  rc = isp_fluoro_fuse_apply(
      rgb_wl, mono_fl, out_rgb, w, h, (IspFluoroFusionMode)md,
      case_param_double(io, "threshold", 0.0),
      case_param_double(io, "alphaMax", 0.8), (IspFluoroColormap)cm,
      case_param_double(io, "offsetX", 0.0),
      case_param_double(io, "offsetY", 0.0),
      case_param_int(io, "maxValue", 1023));
  if (rc == ISP_OK) rc = case_write_out(io, 0, out_rgb, len * 3);
  free(out_rgb);
  free(mono_fl);
  free(rgb_wl);
  return rc;
}

/**
 * 伪彩 LUT 查表（LUT 模式）：in0=mono 帧（w*h u16），in1/in2/in3 =
 * lutR/lutG/lutB（各 max_value+1 个 u16，Dart 建表经输入文件传入）。
 */
int op_pseudo_color_lut_apply(CaseIO *io) {
  const int w = case_param_int(io, "width", 0);
  const int h = case_param_int(io, "height", 0);
  const int max_value = case_param_int(io, "max_value", 1023);
  uint16_t *mono, *lut_r, *lut_g, *lut_b, *out;
  int rc;
  if (w <= 0 || h <= 0) {
    snprintf(io->err, CASE_ERR_LEN, "pseudo_color_lut_apply: bad size %dx%d",
             w, h);
    return ISP_ERR_SIZE;
  }
  mono = case_load_in(io, 0, (size_t)w * (size_t)h);
  lut_r = case_load_in(io, 1, (size_t)max_value + 1);
  lut_g = case_load_in(io, 2, (size_t)max_value + 1);
  lut_b = case_load_in(io, 3, (size_t)max_value + 1);
  if (mono == NULL || lut_r == NULL || lut_g == NULL || lut_b == NULL) {
    return ISP_ERR_ARG;
  }
  out = (uint16_t *)case_scratch(io, (size_t)w * (size_t)h * 3 *
                                        sizeof(uint16_t));
  if (out == NULL) return ISP_ERR_ARG;
  rc = isp_fluoro_pseudo_color_lut_apply(mono, out, w, h, lut_r, lut_g, lut_b,
                                         max_value);
  if (rc == ISP_OK) rc = case_write_out(io, 0, out, (size_t)w * (size_t)h * 3);
  free(mono);
  free(lut_r);
  free(lut_g);
  free(lut_b);
  free(out);
  return rc;
}
