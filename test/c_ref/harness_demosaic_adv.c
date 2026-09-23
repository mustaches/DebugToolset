/**
 * @file harness_demosaic_adv.c
 * @brief 对拍 harness —— 高级去马赛克组：mhc / aahd / amaze / lmmse / igv。
 *
 * params 约定（五个 op 相同）：
 *   width, height        帧宽高（int）
 *   pattern              rggb / bggr / grbg / gbrg
 *   max_value            采样最大值（int，默认 1023）
 * 输入：in0.bin = w*h 个 u16（Bayer 马赛克帧）；
 * 输出：out0.bin = w*h*3 个 u16（交织 RGB）。
 */

#include "harness.h"
#include "isp_demosaic_adv.h"

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
 * @brief 公共装载：解析 width/height/pattern/max_value 并读 in0.bin。
 *
 * 成功返回像素缓冲（调用方 free），各输出参数填好；失败返回 NULL
 * 并填 io->err。
 */
static uint16_t *load_bayer(CaseIO *io, int *w, int *h,
                            IspBayerPattern *pattern, int *max_value) {
  const char *pat_str;
  int pat;
  *w = case_param_int(io, "width", 0);
  *h = case_param_int(io, "height", 0);
  *max_value = case_param_int(io, "max_value", 1023);
  if (*w <= 0 || *h <= 0) {
    snprintf(io->err, CASE_ERR_LEN, "demosaic_adv: bad size %dx%d", *w, *h);
    return NULL;
  }
  pat_str = case_param_str(io, "pattern", "rggb");
  pat = parse_pattern(pat_str);
  if (pat < 0) {
    snprintf(io->err, CASE_ERR_LEN, "demosaic_adv: bad pattern %s", pat_str);
    return NULL;
  }
  *pattern = (IspBayerPattern)pat;
  return case_load_in(io, 0, (size_t)(*w) * (size_t)(*h));
}

/** 分配输出缓冲（w*h*3 个 u16）。 */
static uint16_t *alloc_rgb(CaseIO *io, int w, int h) {
  const size_t len = (size_t)w * (size_t)h * 3u;
  uint16_t *rgb = (uint16_t *)malloc(len * sizeof(uint16_t));
  if (rgb == NULL) {
    snprintf(io->err, CASE_ERR_LEN, "demosaic_adv: rgb alloc failed");
  }
  return rgb;
}

int op_demosaic_mhc(CaseIO *io) {
  int w, h, max_value, rc;
  IspBayerPattern pattern;
  uint16_t *bayer = load_bayer(io, &w, &h, &pattern, &max_value);
  uint16_t *rgb;
  if (bayer == NULL) return ISP_ERR_ARG;
  rgb = alloc_rgb(io, w, h);
  if (rgb == NULL) {
    free(bayer);
    return ISP_ERR_ARG;
  }
  /* MHC 无中间平面，不需 scratch。 */
  rc = isp_demosaic_adv_mhc(bayer, w, h, pattern, max_value, rgb);
  if (rc == ISP_OK) {
    rc = case_write_out(io, 0, rgb, (size_t)w * (size_t)h * 3u);
  }
  free(rgb);
  free(bayer);
  return rc;
}

/**
 * @brief 带 scratch 的四个 op 公共流程。
 *
 * op_kind: 0=aahd 1=amaze 2=lmmse 3=igv。
 */
static int run_scratch_op(CaseIO *io, int op_kind) {
  int w, h, max_value, rc;
  IspBayerPattern pattern;
  uint16_t *bayer = load_bayer(io, &w, &h, &pattern, &max_value);
  uint16_t *rgb;
  void *scratch;
  if (bayer == NULL) return ISP_ERR_ARG;
  rgb = alloc_rgb(io, w, h);
  if (rgb == NULL) {
    free(bayer);
    return ISP_ERR_ARG;
  }
  /* 统一按最大需求分配；malloc 满足 double 对齐。小图回退路径不访问
   * scratch，分配了也无副作用。 */
  scratch = case_scratch(io, ISP_DEMOSAIC_ADV_SCRATCH_BYTES(w, h));
  if (scratch == NULL) {
    free(rgb);
    free(bayer);
    return ISP_ERR_ARG;
  }
  switch (op_kind) {
    case 0:
      rc = isp_demosaic_adv_aahd(bayer, w, h, pattern, max_value, rgb,
                                 scratch);
      break;
    case 1:
      rc = isp_demosaic_adv_amaze(bayer, w, h, pattern, max_value, rgb,
                                  scratch);
      break;
    case 2:
      rc = isp_demosaic_adv_lmmse(bayer, w, h, pattern, max_value, rgb,
                                  scratch);
      break;
    default:
      rc = isp_demosaic_adv_igv(bayer, w, h, pattern, max_value, rgb,
                                scratch);
      break;
  }
  if (rc == ISP_OK) {
    rc = case_write_out(io, 0, rgb, (size_t)w * (size_t)h * 3u);
  }
  free(scratch);
  free(rgb);
  free(bayer);
  return rc;
}

int op_demosaic_aahd(CaseIO *io) { return run_scratch_op(io, 0); }

int op_demosaic_amaze(CaseIO *io) { return run_scratch_op(io, 1); }

int op_demosaic_lmmse(CaseIO *io) { return run_scratch_op(io, 2); }

int op_demosaic_igv(CaseIO *io) { return run_scratch_op(io, 3); }
