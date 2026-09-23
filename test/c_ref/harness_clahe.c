/**
 * @file harness_clahe.c
 * @brief 对拍 harness —— CLAHE 组：clahe_rgb / clahe_mono。
 *
 * params 约定（两个 op 相同）：
 *   width, height        帧宽高（int）
 *   blockSize            tile 边长（int，< 2 时 kernel 内修正为 32）
 *   clipLimit            裁剪倍数（double）
 *   strength             混合比（double；<= 0 为空操作直通）
 *   max_value            采样最大值（int，默认 1023）
 * 输入：in0.bin = w*h*3（clahe_rgb）或 w*h（clahe_mono）个 u16；
 * 输出：out0.bin 同尺寸。
 * scratch 由 ISP_CLAHE_SCRATCH_BYTES 宏给出，malloc 天然满足 double 对齐。
 */

#include "harness.h"
#include "isp_clahe.h"

#include <stdlib.h>

/** 公共参数读取。 */
typedef struct ClaheParams {
  int w, h;
  int block_size;
  double clip_limit;
  double strength;
  int max_value;
} ClaheParams;

static ClaheParams read_params_(CaseIO *io) {
  ClaheParams p;
  p.w = case_param_int(io, "width", 0);
  p.h = case_param_int(io, "height", 0);
  p.block_size = case_param_int(io, "blockSize", 32);
  p.clip_limit = case_param_double(io, "clipLimit", 2.0);
  p.strength = case_param_double(io, "strength", 1.0);
  p.max_value = case_param_int(io, "max_value", 1023);
  return p;
}

int op_clahe_rgb(CaseIO *io) {
  const ClaheParams p = read_params_(io);
  const size_t len = (size_t)p.w * (size_t)p.h * 3;
  uint16_t *frame;
  void *scratch;
  int rc;

  if (p.w <= 0 || p.h <= 0) {
    snprintf(io->err, CASE_ERR_LEN, "clahe_rgb: bad size %dx%d", p.w, p.h);
    return ISP_ERR_SIZE;
  }
  frame = case_load_in(io, 0, len);
  if (frame == NULL) return ISP_ERR_ARG;
  scratch = case_scratch(io, ISP_CLAHE_SCRATCH_BYTES(p.w, p.h, p.block_size));
  if (scratch == NULL) {
    free(frame);
    return ISP_ERR_ARG;
  }
  rc = isp_clahe_apply(frame, p.w, p.h, p.block_size, p.clip_limit, p.strength,
                       p.max_value, scratch);
  if (rc == ISP_OK) rc = case_write_out(io, 0, frame, len);
  free(scratch);
  free(frame);
  return rc;
}

int op_clahe_mono(CaseIO *io) {
  const ClaheParams p = read_params_(io);
  const size_t len = (size_t)p.w * (size_t)p.h;
  uint16_t *frame;
  void *scratch;
  int rc;

  if (p.w <= 0 || p.h <= 0) {
    snprintf(io->err, CASE_ERR_LEN, "clahe_mono: bad size %dx%d", p.w, p.h);
    return ISP_ERR_SIZE;
  }
  frame = case_load_in(io, 0, len);
  if (frame == NULL) return ISP_ERR_ARG;
  /* mono 只用 LUT + 直方图区，按统一契约仍申请完整宏大小。 */
  scratch = case_scratch(io, ISP_CLAHE_SCRATCH_BYTES(p.w, p.h, p.block_size));
  if (scratch == NULL) {
    free(frame);
    return ISP_ERR_ARG;
  }
  rc = isp_clahe_apply_mono(frame, p.w, p.h, p.block_size, p.clip_limit,
                            p.strength, p.max_value, scratch);
  if (rc == ISP_OK) rc = case_write_out(io, 0, frame, len);
  free(scratch);
  free(frame);
  return rc;
}
