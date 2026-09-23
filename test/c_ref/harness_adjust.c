/**
 * @file harness_adjust.c
 * @brief 对拍 harness —— 调节器组：adjust_hsl / adjust_rgb / adjust_yuv /
 * adjust_satbright / adjust_brightcontrast / adjust_colorbalance /
 * color_controller。
 *
 * params 公共约定：
 *   width, height   帧宽高（int）
 *   max_value       采样最大值（int，缺省 1023）
 *   format          rgb / yuv / hsl / mono（仅带 format 的 op）
 * 输入：in0.bin = 交织三通道 w*h*3 个 u16（mono 为 w*h 个）；
 * 输出：out0.bin 同尺寸（全部核原地修改 / 调用方提供 dst）。
 * 各 op 专有参数见对应 handler 注释。
 */

#include "harness.h"
#include "isp_adjust.h"
#include "isp_color_controller.h"

#include <stdlib.h>
#include <string.h>

/** format 字符串 -> IspAdjustFormat；非法返回 -1。 */
static int parse_format(const char *s) {
  if (strcmp(s, "rgb") == 0) return ISP_ADJ_FMT_RGB;
  if (strcmp(s, "yuv") == 0) return ISP_ADJ_FMT_YUV;
  if (strcmp(s, "hsl") == 0) return ISP_ADJ_FMT_HSL;
  if (strcmp(s, "mono") == 0) return ISP_ADJ_FMT_MONO;
  return -1;
}

/** 公共尺寸/帧长解析：mono 帧长 w*h，其余 w*h*3。失败填 io->err 返回 0。 */
static int adj_frame_len(CaseIO *io, const char *op, int has_format,
                         int *w, int *h, size_t *len) {
  const char *fmt;
  *w = case_param_int(io, "width", 0);
  *h = case_param_int(io, "height", 0);
  if (*w <= 0 || *h <= 0) {
    snprintf(io->err, CASE_ERR_LEN, "%s: bad size %dx%d", op, *w, *h);
    return 0;
  }
  *len = (size_t)(*w) * (size_t)(*h) * 3u;
  if (has_format) {
    fmt = case_param_str(io, "format", "rgb");
    if (strcmp(fmt, "mono") == 0) *len = (size_t)(*w) * (size_t)(*h);
  }
  return 1;
}

/* params: hShiftDeg, sGain, lGain（double） */
int op_adjust_hsl(CaseIO *io) {
  int w, h;
  size_t len;
  uint16_t *frame;
  int rc;
  if (!adj_frame_len(io, "adjust_hsl", 0, &w, &h, &len)) return ISP_ERR_SIZE;
  frame = case_load_in(io, 0, len);
  if (frame == NULL) return ISP_ERR_ARG;
  rc = isp_adjust_hsl(frame, w, h, case_param_int(io, "max_value", 1023),
                      case_param_double(io, "hShiftDeg", 0.0),
                      case_param_double(io, "sGain", 1.0),
                      case_param_double(io, "lGain", 1.0));
  if (rc == ISP_OK) rc = case_write_out(io, 0, frame, len);
  free(frame);
  return rc;
}

/* params: rGain, gGain, bGain（double） */
int op_adjust_rgb(CaseIO *io) {
  int w, h;
  size_t len;
  uint16_t *frame;
  int rc;
  if (!adj_frame_len(io, "adjust_rgb", 0, &w, &h, &len)) return ISP_ERR_SIZE;
  frame = case_load_in(io, 0, len);
  if (frame == NULL) return ISP_ERR_ARG;
  rc = isp_adjust_rgb(frame, w, h, case_param_int(io, "max_value", 1023),
                      case_param_double(io, "rGain", 1.0),
                      case_param_double(io, "gGain", 1.0),
                      case_param_double(io, "bGain", 1.0));
  if (rc == ISP_OK) rc = case_write_out(io, 0, frame, len);
  free(frame);
  return rc;
}

/* params: yGain, uGain, vGain（double） */
int op_adjust_yuv(CaseIO *io) {
  int w, h;
  size_t len;
  uint16_t *frame;
  int rc;
  if (!adj_frame_len(io, "adjust_yuv", 0, &w, &h, &len)) return ISP_ERR_SIZE;
  frame = case_load_in(io, 0, len);
  if (frame == NULL) return ISP_ERR_ARG;
  rc = isp_adjust_yuv(frame, w, h, case_param_int(io, "max_value", 1023),
                      case_param_double(io, "yGain", 1.0),
                      case_param_double(io, "uGain", 1.0),
                      case_param_double(io, "vGain", 1.0));
  if (rc == ISP_OK) rc = case_write_out(io, 0, frame, len);
  free(frame);
  return rc;
}

/* params: format=rgb/yuv/hsl, satGain, brightGain（double） */
int op_adjust_satbright(CaseIO *io) {
  int w, h;
  size_t len;
  uint16_t *frame;
  int fmt, rc;
  if (!adj_frame_len(io, "adjust_satbright", 1, &w, &h, &len)) {
    return ISP_ERR_SIZE;
  }
  fmt = parse_format(case_param_str(io, "format", "rgb"));
  if (fmt < 0 || fmt == ISP_ADJ_FMT_MONO) {
    snprintf(io->err, CASE_ERR_LEN, "adjust_satbright: bad format %s",
             case_param_str(io, "format", "rgb"));
    return ISP_ERR_ARG;
  }
  frame = case_load_in(io, 0, len);
  if (frame == NULL) return ISP_ERR_ARG;
  rc = isp_adjust_sat_bright(frame, w, h, (IspAdjustFormat)fmt,
                             case_param_int(io, "max_value", 1023),
                             case_param_double(io, "satGain", 1.0),
                             case_param_double(io, "brightGain", 1.0));
  if (rc == ISP_OK) rc = case_write_out(io, 0, frame, len);
  free(frame);
  return rc;
}

/* params: format=rgb/yuv/hsl/mono, brightPct, baselinePct, gainPct（double） */
int op_adjust_brightcontrast(CaseIO *io) {
  int w, h;
  size_t len;
  uint16_t *frame;
  int fmt, rc;
  if (!adj_frame_len(io, "adjust_brightcontrast", 1, &w, &h, &len)) {
    return ISP_ERR_SIZE;
  }
  fmt = parse_format(case_param_str(io, "format", "rgb"));
  if (fmt < 0) {
    snprintf(io->err, CASE_ERR_LEN, "adjust_brightcontrast: bad format %s",
             case_param_str(io, "format", "rgb"));
    return ISP_ERR_ARG;
  }
  frame = case_load_in(io, 0, len);
  if (frame == NULL) return ISP_ERR_ARG;
  rc = isp_adjust_bright_contrast(frame, w, h, (IspAdjustFormat)fmt,
                                  case_param_int(io, "max_value", 1023),
                                  case_param_double(io, "brightPct", 100.0),
                                  case_param_double(io, "baselinePct", 50.0),
                                  case_param_double(io, "gainPct", 100.0));
  if (rc == ISP_OK) rc = case_write_out(io, 0, frame, len);
  free(frame);
  return rc;
}

/* params: format=rgb/yuv/hsl, cyanRed, magentaGreen, yellowBlue（double，±100） */
int op_adjust_colorbalance(CaseIO *io) {
  int w, h;
  size_t len;
  uint16_t *frame;
  int fmt, rc;
  if (!adj_frame_len(io, "adjust_colorbalance", 1, &w, &h, &len)) {
    return ISP_ERR_SIZE;
  }
  fmt = parse_format(case_param_str(io, "format", "rgb"));
  if (fmt < 0 || fmt == ISP_ADJ_FMT_MONO) {
    snprintf(io->err, CASE_ERR_LEN, "adjust_colorbalance: bad format %s",
             case_param_str(io, "format", "rgb"));
    return ISP_ERR_ARG;
  }
  frame = case_load_in(io, 0, len);
  if (frame == NULL) return ISP_ERR_ARG;
  rc = isp_adjust_color_balance(frame, w, h, (IspAdjustFormat)fmt,
                                case_param_int(io, "max_value", 1023),
                                case_param_double(io, "cyanRed", 0.0),
                                case_param_double(io, "magentaGreen", 0.0),
                                case_param_double(io, "yellowBlue", 0.0));
  if (rc == ISP_OK) rc = case_write_out(io, 0, frame, len);
  free(frame);
  return rc;
}

/* params: hCenterDeg, q, hShiftDeg, sGain, lGain（double）；src/dst 分离缓冲 */
int op_color_controller(CaseIO *io) {
  int w, h;
  size_t len;
  uint16_t *src;
  uint16_t *dst;
  int rc;
  if (!adj_frame_len(io, "color_controller", 0, &w, &h, &len)) {
    return ISP_ERR_SIZE;
  }
  src = case_load_in(io, 0, len);
  if (src == NULL) return ISP_ERR_ARG;
  dst = (uint16_t *)malloc(len * 2);
  if (dst == NULL) {
    snprintf(io->err, CASE_ERR_LEN, "color_controller: out of memory");
    free(src);
    return ISP_ERR_ARG;
  }
  rc = isp_color_controller_apply(src, dst, w, h,
                                  case_param_int(io, "max_value", 1023),
                                  case_param_double(io, "hCenterDeg", 0.0),
                                  case_param_double(io, "q", 2.0),
                                  case_param_double(io, "hShiftDeg", 0.0),
                                  case_param_double(io, "sGain", 1.0),
                                  case_param_double(io, "lGain", 1.0));
  if (rc == ISP_OK) rc = case_write_out(io, 0, dst, len);
  free(dst);
  free(src);
  return rc;
}

/**
 * 三通道增益 LUT 查表（LUT 模式）：in0=帧（w*h*3 u16），in1/in2/in3 =
 * lutR/lutG/lutB（各 max_value+1 个 u16，Dart 建表经输入文件传入）。
 */
int op_adjust_lut3_apply(CaseIO *io) {
  int w, h;
  size_t len;
  const int max_value = case_param_int(io, "max_value", 1023);
  uint16_t *frame, *lut_r, *lut_g, *lut_b, *out;
  int rc;
  if (!adj_frame_len(io, "adjust_lut3_apply", 0, &w, &h, &len)) {
    return ISP_ERR_SIZE;
  }
  frame = case_load_in(io, 0, len);
  lut_r = case_load_in(io, 1, (size_t)max_value + 1);
  lut_g = case_load_in(io, 2, (size_t)max_value + 1);
  lut_b = case_load_in(io, 3, (size_t)max_value + 1);
  if (frame == NULL || lut_r == NULL || lut_g == NULL || lut_b == NULL) {
    return ISP_ERR_ARG;
  }
  out = (uint16_t *)case_scratch(io, len * sizeof(uint16_t));
  if (out == NULL) return ISP_ERR_ARG;
  rc = isp_adjust_lut3_apply(frame, w, h, max_value, lut_r, lut_g, lut_b, out);
  if (rc == ISP_OK) rc = case_write_out(io, 0, out, len);
  free(frame);
  free(lut_r);
  free(lut_g);
  free(lut_b);
  free(out);
  return rc;
}

/**
 * 亮度/对比度 LUT 查表（LUT 模式）：in0=帧（格式由 format 定，mono 为
 * w*h，其余 w*h*3），in1=adjust 映射表（max_value+1 个 u16）；format=rgb
 * 时另经 inRaw0 传 ratio 表（max_value+1 个 double 的小端字节流）。
 */
int op_adjust_bc_lut_apply(CaseIO *io) {
  int w, h;
  size_t len;
  const char *fmt = case_param_str(io, "format", "mono");
  const int max_value = case_param_int(io, "max_value", 1023);
  IspAdjustFormat format;
  uint16_t *frame, *adj_lut;
  int rc;
  if (strcmp(fmt, "rgb") == 0) {
    format = ISP_ADJ_FMT_RGB;
  } else if (strcmp(fmt, "yuv") == 0) {
    format = ISP_ADJ_FMT_YUV;
  } else if (strcmp(fmt, "hsl") == 0) {
    format = ISP_ADJ_FMT_HSL;
  } else {
    format = ISP_ADJ_FMT_MONO;
  }
  if (!adj_frame_len(io, "adjust_bc_lut_apply", 1, &w, &h, &len)) {
    return ISP_ERR_SIZE;
  }
  frame = case_load_in(io, 0, len);
  adj_lut = case_load_in(io, 1, (size_t)max_value + 1);
  if (frame == NULL || adj_lut == NULL) return ISP_ERR_ARG;
  rc = isp_adjust_bc_lut_apply(frame, w, h, format, max_value, adj_lut);
  if (rc == ISP_OK) rc = case_write_out(io, 0, frame, len);
  free(frame);
  free(adj_lut);
  return rc;
}

/**
 * 色彩控制器 LUT 查表（LUT 模式）：in0=HSL 帧（w*h*3 u16），三表经
 * inRaw0 打包传入：shift int32[N] + sMul double[N] + lMul double[N]
 *（N = max_value+1，均小端）。
 */
int op_color_controller_lut_apply(CaseIO *io) {
  int w, h;
  size_t len;
  const int max_value = case_param_int(io, "max_value", 1023);
  const size_t n = (size_t)max_value + 1;
  uint16_t *frame, *out;
  uint8_t *raw;
  const int32_t *shift_lut;
  const double *s_mul_lut, *l_mul_lut;
  int rc;
  if (!adj_frame_len(io, "color_controller_lut_apply", 0, &w, &h, &len)) {
    return ISP_ERR_SIZE;
  }
  frame = case_load_in(io, 0, len);
  raw = case_load_in_raw(io, 0,
                         n * (sizeof(int32_t) + 2 * sizeof(double)));
  if (frame == NULL || raw == NULL) return ISP_ERR_ARG;
  shift_lut = (const int32_t *)raw;
  s_mul_lut = (const double *)(raw + n * sizeof(int32_t));
  l_mul_lut = (const double *)(raw + n * (sizeof(int32_t) + sizeof(double)));
  out = (uint16_t *)case_scratch(io, len * sizeof(uint16_t));
  if (out == NULL) return ISP_ERR_ARG;
  rc = isp_color_controller_lut_apply(frame, out, w, h, max_value, shift_lut,
                                      s_mul_lut, l_mul_lut);
  if (rc == ISP_OK) rc = case_write_out(io, 0, out, len);
  free(frame);
  free(raw);
  free(out);
  return rc;
}
