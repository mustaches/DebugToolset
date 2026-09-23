/**
 * @file harness_raw2.c
 * @brief 对拍 harness —— RAW 域组 2：fpn / bayer_dnr / highlight。
 *
 * params 约定（fpn）：
 *   width, height        帧宽高（int）
 *   pattern              rggb / bggr / grbg / gbrg / mono（仅自描述用；
 *                        isp_fpn_apply 无相位概念，不读取本参数）
 *   row, col             行/列方向开关（0/1，默认 1）
 *   maxCorr              校正量限幅（double，默认 64）
 *   radius               滑窗半径（int，默认 8）
 *
 * params 约定（bayer_dnr）：
 *   width, height        帧宽高（int）
 *   pattern              rggb / bggr / grbg / gbrg / mono（mono 传 NULL）
 *   strength             σ 倍率（double，默认 1.0）
 *
 * params 约定（highlight）：
 *   width, height        帧宽高（int）
 *   pattern              rggb / bggr / grbg / gbrg / mono（mono 传 NULL）
 *   maxValue             采样最大值（int，默认 1023）
 *   mode                 recover / clip
 *   knee                 膝点比例（double，默认 0.9）
 *
 * 输入：in0.bin = w*h 个 u16；输出：out0.bin 同尺寸。
 */

#include "harness.h"
#include "isp_fpn.h"
#include "isp_bayer_dnr.h"
#include "isp_highlight.h"

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

/**
 * @brief 解析 pattern 参数为内核指针：mono -> NULL，Bayer -> 静态常量地址。
 * 内核只判空不解引用（见 isp_phase_neighbors），静态常量仅为提供非 NULL。
 */
static const IspBayerPattern *parse_pattern_ptr(CaseIO *io, const char *s) {
  static const IspBayerPattern kPat[4] = {ISP_BAYER_RGGB, ISP_BAYER_BGGR,
                                          ISP_BAYER_GRBG, ISP_BAYER_GBRG};
  int pat;
  if (strcmp(s, "mono") == 0) return NULL;
  pat = parse_pattern(s);
  if (pat < 0) {
    snprintf(io->err, CASE_ERR_LEN, "bad pattern %s", s);
    return NULL;
  }
  return &kPat[pat];
}

int op_fpn(CaseIO *io) {
  const int w = case_param_int(io, "width", 0);
  const int h = case_param_int(io, "height", 0);
  const size_t len = (size_t)w * (size_t)h;
  uint16_t *frame;
  void *scratch;
  int rc;

  if (w <= 0 || h <= 0) {
    snprintf(io->err, CASE_ERR_LEN, "fpn: bad size %dx%d", w, h);
    return ISP_ERR_SIZE;
  }
  frame = case_load_in(io, 0, len);
  if (frame == NULL) return ISP_ERR_ARG;
  scratch = case_scratch(io, ISP_FPN_SCRATCH_BYTES(w, h));
  if (scratch == NULL) {
    free(frame);
    return ISP_ERR_ARG;
  }
  rc = isp_fpn_apply(frame, w, h, case_param_int(io, "row", 1),
                     case_param_int(io, "col", 1),
                     case_param_double(io, "maxCorr", 64.0),
                     case_param_int(io, "radius", 8), scratch,
                     ISP_FPN_SCRATCH_BYTES(w, h));
  free(scratch);
  if (rc == ISP_OK) rc = case_write_out(io, 0, frame, len);
  free(frame);
  return rc;
}

int op_bayer_dnr(CaseIO *io) {
  const int w = case_param_int(io, "width", 0);
  const int h = case_param_int(io, "height", 0);
  const char *pattern = case_param_str(io, "pattern", "rggb");
  const size_t len = (size_t)w * (size_t)h;
  const IspBayerPattern *pat;
  uint16_t *frame;
  uint16_t *scratch;
  int rc;

  if (w <= 0 || h <= 0) {
    snprintf(io->err, CASE_ERR_LEN, "bayer_dnr: bad size %dx%d", w, h);
    return ISP_ERR_SIZE;
  }
  pat = parse_pattern_ptr(io, pattern);
  if (pat == NULL && strcmp(pattern, "mono") != 0) return ISP_ERR_ARG;
  frame = case_load_in(io, 0, len);
  if (frame == NULL) return ISP_ERR_ARG;
  scratch = (uint16_t *)case_scratch(io, ISP_BAYER_DNR_SCRATCH_BYTES(w, h));
  if (scratch == NULL) {
    free(frame);
    return ISP_ERR_ARG;
  }
  rc = isp_bayer_dnr_apply(frame, w, h, pat,
                           case_param_double(io, "strength", 1.0), scratch);
  free(scratch);
  if (rc == ISP_OK) rc = case_write_out(io, 0, frame, len);
  free(frame);
  return rc;
}

int op_highlight(CaseIO *io) {
  const int w = case_param_int(io, "width", 0);
  const int h = case_param_int(io, "height", 0);
  const char *pattern = case_param_str(io, "pattern", "rggb");
  const char *mode = case_param_str(io, "mode", "recover");
  const size_t len = (size_t)w * (size_t)h;
  const IspBayerPattern *pat;
  IspHighlightMode hmode;
  uint16_t *frame;
  uint16_t *scratch;
  int rc;

  if (w <= 0 || h <= 0) {
    snprintf(io->err, CASE_ERR_LEN, "highlight: bad size %dx%d", w, h);
    return ISP_ERR_SIZE;
  }
  pat = parse_pattern_ptr(io, pattern);
  if (pat == NULL && strcmp(pattern, "mono") != 0) return ISP_ERR_ARG;
  if (strcmp(mode, "recover") == 0) {
    hmode = ISP_HIGHLIGHT_RECOVER;
  } else if (strcmp(mode, "clip") == 0) {
    hmode = ISP_HIGHLIGHT_CLIP;
  } else {
    snprintf(io->err, CASE_ERR_LEN, "highlight: bad mode %s", mode);
    return ISP_ERR_ARG;
  }
  frame = case_load_in(io, 0, len);
  if (frame == NULL) return ISP_ERR_ARG;
  /* recover 需要整帧快照 scratch；clip 允许 NULL，但统一分配简化逻辑。 */
  scratch = (uint16_t *)case_scratch(io, ISP_HIGHLIGHT_SCRATCH_BYTES(w, h));
  if (scratch == NULL) {
    free(frame);
    return ISP_ERR_ARG;
  }
  rc = isp_highlight_apply(frame, w, h, pat,
                           case_param_int(io, "maxValue", 1023), hmode,
                           case_param_double(io, "knee", 0.9), scratch);
  free(scratch);
  if (rc == ISP_OK) rc = case_write_out(io, 0, frame, len);
  free(frame);
  return rc;
}

/** 高光 clip LUT 查表（LUT 模式）：in0=帧（w*h u16），in1=clip 表
 *（max_value+1 个 u16，Dart 建表经输入文件传入）。 */
int op_highlight_clip_lut(CaseIO *io) {
  const int w = case_param_int(io, "width", 0);
  const int h = case_param_int(io, "height", 0);
  const int max_value = case_param_int(io, "max_value", 1023);
  uint16_t *frame, *lut;
  int rc;
  if (w <= 0 || h <= 0) {
    snprintf(io->err, CASE_ERR_LEN, "highlight_clip_lut: bad size %dx%d", w, h);
    return ISP_ERR_SIZE;
  }
  frame = case_load_in(io, 0, (size_t)w * (size_t)h);
  lut = case_load_in(io, 1, (size_t)max_value + 1);
  if (frame == NULL || lut == NULL) return ISP_ERR_ARG;
  rc = isp_highlight_clip_lut_apply(frame, w, h, lut);
  if (rc == ISP_OK) rc = case_write_out(io, 0, frame, (size_t)w * (size_t)h);
  free(frame);
  free(lut);
  return rc;
}
