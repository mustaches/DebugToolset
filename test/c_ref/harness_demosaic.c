/**
 * @file harness_demosaic.c
 * @brief 对拍 harness —— 去马赛克组：bilinear + 4 种非 Bayer CFA。
 * demosaic_rccb 经参数 rccg=0/1 复用 RCCG 形态。
 *
 * params 约定：
 *   width, height        帧宽高（int）
 *   maxValue             采样最大值（int，非 Bayer 路径用，默认 1023）
 *   pattern              demosaic_bilinear 用：rggb / bggr / grbg / gbrg
 *   rccg                 demosaic_rccb 用：0=RCCB，1=RCCG
 *   irSubtraction        demosaic_rgbir 用：double 红外扣除系数
 * 输入：in0.bin = w*h 个 u16；输出：out0.bin = w*h*3 个 u16（交织 RGB）。
 */

#include "harness.h"
#include "isp_demosaic.h"

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

/** 加载 w*h 输入帧并分配 w*h*3 输出缓冲；失败填 io->err 返回非零。 */
static int load_case(CaseIO *io, int *w, int *h, uint16_t **frame,
                     uint16_t **rgb) {
  const size_t len = (size_t)(*w) * (size_t)(*h);
  if (*w <= 0 || *h <= 0) {
    snprintf(io->err, CASE_ERR_LEN, "demosaic: bad size %dx%d", *w, *h);
    return ISP_ERR_SIZE;
  }
  *frame = case_load_in(io, 0, len);
  if (*frame == NULL) return ISP_ERR_ARG;
  *rgb = (uint16_t *)case_scratch(io, len * 3 * sizeof(uint16_t));
  if (*rgb == NULL) {
    free(*frame);
    *frame = NULL;
    return ISP_ERR_ARG;
  }
  return ISP_OK;
}

int op_demosaic_bilinear(CaseIO *io) {
  int w = case_param_int(io, "width", 0);
  int h = case_param_int(io, "height", 0);
  const char *pattern = case_param_str(io, "pattern", "rggb");
  uint16_t *frame = NULL;
  uint16_t *rgb = NULL;
  int pat;
  int rc = load_case(io, &w, &h, &frame, &rgb);
  if (rc != ISP_OK) return rc;

  pat = parse_pattern(pattern);
  if (pat < 0) {
    snprintf(io->err, CASE_ERR_LEN, "demosaic_bilinear: bad pattern %s",
             pattern);
    free(frame);
    free(rgb);
    return ISP_ERR_ARG;
  }
  rc = isp_demosaic_bilinear(frame, w, h, (IspBayerPattern)pat, rgb);
  if (rc == ISP_OK) rc = case_write_out(io, 0, rgb, (size_t)w * (size_t)h * 3);
  free(frame);
  free(rgb);
  return rc;
}

int op_demosaic_rccb(CaseIO *io) {
  int w = case_param_int(io, "width", 0);
  int h = case_param_int(io, "height", 0);
  const bool rccg = case_param_int(io, "rccg", 0) != 0;
  const int max_value = case_param_int(io, "maxValue", 1023);
  uint16_t *frame = NULL;
  uint16_t *rgb = NULL;
  int rc = load_case(io, &w, &h, &frame, &rgb);
  if (rc != ISP_OK) return rc;

  rc = isp_demosaic_rccb(frame, w, h, rccg, max_value, rgb);
  if (rc == ISP_OK) rc = case_write_out(io, 0, rgb, (size_t)w * (size_t)h * 3);
  free(frame);
  free(rgb);
  return rc;
}

int op_demosaic_rccc(CaseIO *io) {
  int w = case_param_int(io, "width", 0);
  int h = case_param_int(io, "height", 0);
  const int max_value = case_param_int(io, "maxValue", 1023);
  uint16_t *frame = NULL;
  uint16_t *rgb = NULL;
  int rc = load_case(io, &w, &h, &frame, &rgb);
  if (rc != ISP_OK) return rc;

  rc = isp_demosaic_rccc(frame, w, h, max_value, rgb);
  if (rc == ISP_OK) rc = case_write_out(io, 0, rgb, (size_t)w * (size_t)h * 3);
  free(frame);
  free(rgb);
  return rc;
}

int op_demosaic_ryycy(CaseIO *io) {
  int w = case_param_int(io, "width", 0);
  int h = case_param_int(io, "height", 0);
  const int max_value = case_param_int(io, "maxValue", 1023);
  uint16_t *frame = NULL;
  uint16_t *rgb = NULL;
  int rc = load_case(io, &w, &h, &frame, &rgb);
  if (rc != ISP_OK) return rc;

  rc = isp_demosaic_ryycy(frame, w, h, max_value, rgb);
  if (rc == ISP_OK) rc = case_write_out(io, 0, rgb, (size_t)w * (size_t)h * 3);
  free(frame);
  free(rgb);
  return rc;
}

int op_demosaic_rgbir(CaseIO *io) {
  int w = case_param_int(io, "width", 0);
  int h = case_param_int(io, "height", 0);
  const int max_value = case_param_int(io, "maxValue", 1023);
  const double ir_sub = case_param_double(io, "irSubtraction", 0.5);
  uint16_t *frame = NULL;
  uint16_t *rgb = NULL;
  int rc = load_case(io, &w, &h, &frame, &rgb);
  if (rc != ISP_OK) return rc;

  rc = isp_demosaic_rgb_ir(frame, w, h, max_value, ir_sub, rgb);
  if (rc == ISP_OK) rc = case_write_out(io, 0, rgb, (size_t)w * (size_t)h * 3);
  free(frame);
  free(rgb);
  return rc;
}
