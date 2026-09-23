/**
 * @file harness_enhance.c
 * @brief 对拍 harness —— 增强组：rgb_dnr / sharpen / edge_extract /
 * gaussian_blur / morphology。
 *
 * params 约定：
 * - 公共：width, height（int）；in0.bin 为交织帧（rgb/yuv/hsl 为 w*h*3，
 *   mono 为 w*h），out0.bin 同尺寸写回。
 * - rgb_dnr：luma, chroma（double）, max_value（int）。
 * - sharpen：amount, threshold（double）, max_value（int）。
 * - edge_extract：format（rgb/yuv/hsl 字符串）, gain, threshold（double）,
 *   max_value（int）。输入帧只读，输出到独立缓冲。
 * - gaussian_blur：channels（int，1=mono / 3=交织）, sigma, strength（double）。
 * - morphology：channels（int）, erode（0/1）, radius（int）。
 */

#include "harness.h"
#include "isp_rgb_dnr.h"
#include "isp_sharpen.h"
#include "isp_edge_extract.h"
#include "isp_gaussian_blur.h"
#include "isp_morphology.h"

#include <stdlib.h>
#include <string.h>

/** 读公共尺寸参数并校验；失败填 io->err 返回非零。 */
static int read_size(CaseIO *io, const char *op, int *w, int *h) {
  *w = case_param_int(io, "width", 0);
  *h = case_param_int(io, "height", 0);
  if (*w <= 0 || *h <= 0) {
    snprintf(io->err, CASE_ERR_LEN, "%s: bad size %dx%d", op, *w, *h);
    return ISP_ERR_SIZE;
  }
  return ISP_OK;
}

int op_rgb_dnr(CaseIO *io) {
  int w, h;
  const size_t len = (size_t)case_param_int(io, "width", 0) *
                     (size_t)case_param_int(io, "height", 0) * 3u;
  uint16_t *frame;
  uint16_t *scratch;
  int rc = read_size(io, "rgb_dnr", &w, &h);
  if (rc != ISP_OK) return rc;

  frame = case_load_in(io, 0, len);
  if (frame == NULL) return ISP_ERR_ARG;
  scratch = (uint16_t *)case_scratch(io, ISP_RGB_DNR_SCRATCH_BYTES(w, h));
  if (scratch == NULL) {
    free(frame);
    return ISP_ERR_ARG;
  }
  rc = isp_rgb_dnr_apply(frame, w, h, case_param_double(io, "luma", 0.0),
                         case_param_double(io, "chroma", 0.0),
                         case_param_int(io, "max_value", 1023), scratch);
  free(scratch);
  if (rc == ISP_OK) rc = case_write_out(io, 0, frame, len);
  free(frame);
  return rc;
}

int op_sharpen(CaseIO *io) {
  int w, h;
  const size_t len = (size_t)case_param_int(io, "width", 0) *
                     (size_t)case_param_int(io, "height", 0) * 3u;
  uint16_t *frame;
  uint16_t *scratch;
  int rc = read_size(io, "sharpen", &w, &h);
  if (rc != ISP_OK) return rc;

  frame = case_load_in(io, 0, len);
  if (frame == NULL) return ISP_ERR_ARG;
  scratch = (uint16_t *)case_scratch(io, ISP_SHARPEN_SCRATCH_BYTES(w, h));
  if (scratch == NULL) {
    free(frame);
    return ISP_ERR_ARG;
  }
  rc = isp_sharpen_apply(frame, w, h, case_param_double(io, "amount", 0.0),
                         case_param_double(io, "threshold", 0.0),
                         case_param_int(io, "max_value", 1023), scratch);
  free(scratch);
  if (rc == ISP_OK) rc = case_write_out(io, 0, frame, len);
  free(frame);
  return rc;
}

/** format 字符串 -> IspEdgeExtractFormat；非法返回 -1。 */
static int parse_edge_format(const char *s) {
  if (strcmp(s, "rgb") == 0) return ISP_EDGE_EXTRACT_RGB;
  if (strcmp(s, "yuv") == 0) return ISP_EDGE_EXTRACT_YUV;
  if (strcmp(s, "hsl") == 0) return ISP_EDGE_EXTRACT_HSL;
  return -1;
}

int op_edge_extract(CaseIO *io) {
  int w, h;
  const size_t len = (size_t)case_param_int(io, "width", 0) *
                     (size_t)case_param_int(io, "height", 0) * 3u;
  const char *format = case_param_str(io, "format", "rgb");
  uint16_t *frame;
  uint16_t *out;
  uint16_t *scratch;
  int fmt;
  int rc = read_size(io, "edge_extract", &w, &h);
  if (rc != ISP_OK) return rc;

  fmt = parse_edge_format(format);
  if (fmt < 0) {
    snprintf(io->err, CASE_ERR_LEN, "edge_extract: bad format %s", format);
    return ISP_ERR_ARG;
  }
  frame = case_load_in(io, 0, len);
  if (frame == NULL) return ISP_ERR_ARG;
  out = (uint16_t *)malloc(len * sizeof(uint16_t));
  scratch = (uint16_t *)case_scratch(io, ISP_EDGE_EXTRACT_SCRATCH_BYTES(w, h));
  if (out == NULL || scratch == NULL) {
    snprintf(io->err, CASE_ERR_LEN, "edge_extract: out of memory");
    free(out);
    free(scratch);
    free(frame);
    return ISP_ERR_ARG;
  }
  rc = isp_edge_extract_run(frame, out, w, h, (IspEdgeExtractFormat)fmt,
                            case_param_double(io, "gain", 1.0),
                            case_param_double(io, "threshold", 0.0),
                            case_param_int(io, "max_value", 1023), scratch);
  free(scratch);
  if (rc == ISP_OK) rc = case_write_out(io, 0, out, len);
  free(out);
  free(frame);
  return rc;
}

int op_gaussian_blur(CaseIO *io) {
  int w, h;
  const int channels = case_param_int(io, "channels", 3);
  const double sigma = case_param_double(io, "sigma", 0.0);
  const double strength = case_param_double(io, "strength", 0.0);
  size_t len;
  uint16_t *frame;
  void *scratch;
  int rc = read_size(io, "gaussian_blur", &w, &h);
  if (rc != ISP_OK) return rc;
  if (channels < 1) {
    snprintf(io->err, CASE_ERR_LEN, "gaussian_blur: bad channels %d", channels);
    return ISP_ERR_ARG;
  }
  len = (size_t)w * (size_t)h * (size_t)channels;
  frame = case_load_in(io, 0, len);
  if (frame == NULL) return ISP_ERR_ARG;
  /* case_scratch 底层为 malloc，x64 下 16 字节对齐，满足 double 对齐要求。 */
  scratch = case_scratch(
      io, ISP_GAUSSIAN_BLUR_SCRATCH_BYTES(w, channels,
                                          isp_gaussian_blur_radius(sigma)));
  if (scratch == NULL) {
    free(frame);
    return ISP_ERR_ARG;
  }
  rc = isp_gaussian_blur_apply(frame, w, h, channels, sigma, strength, scratch);
  free(scratch);
  if (rc == ISP_OK) rc = case_write_out(io, 0, frame, len);
  free(frame);
  return rc;
}

int op_morphology(CaseIO *io) {
  int w, h;
  const int channels = case_param_int(io, "channels", 1);
  const int radius = case_param_int(io, "radius", 1);
  size_t len;
  uint16_t *frame;
  uint16_t *scratch;
  int rc = read_size(io, "morphology", &w, &h);
  if (rc != ISP_OK) return rc;
  if (channels < 1) {
    snprintf(io->err, CASE_ERR_LEN, "morphology: bad channels %d", channels);
    return ISP_ERR_ARG;
  }
  len = (size_t)w * (size_t)h * (size_t)channels;
  frame = case_load_in(io, 0, len);
  if (frame == NULL) return ISP_ERR_ARG;
  scratch = (uint16_t *)case_scratch(
      io, ISP_MORPHOLOGY_SCRATCH_BYTES(w, channels, radius));
  if (scratch == NULL) {
    free(frame);
    return ISP_ERR_ARG;
  }
  rc = isp_morphology_apply(frame, w, h, channels,
                            case_param_int(io, "erode", 1) != 0, radius,
                            scratch);
  free(scratch);
  if (rc == ISP_OK) rc = case_write_out(io, 0, frame, len);
  free(frame);
  return rc;
}
