/**
 * @file harness_csc.c
 * @brief 对拍 harness —— 色彩空间转换组：rgb/yuv/hsl 六向互换。
 *
 * 公共 params 约定：
 *   width, height   帧宽高（int）
 *   max_value       采样最大值（int，默认 1023）
 * 输入：in0.bin = w*h*3 个 u16（交织三通道）；输出：out0.bin 同尺寸。
 * csc_rgb2yuv 额外参数：
 *   standard        bt601 / bt709（默认 bt601）
 *   range           full / limited（默认 full）
 */

#include "harness.h"
/* isp_csc 全家桶已按变体拆分：对拍 harness 引用全部六个变体头。 */
#include "isp_csc_rgb2yuv.h"
#include "isp_csc_rgb2hsl.h"
#include "isp_csc_yuv2rgb.h"
#include "isp_csc_yuv2hsl.h"
#include "isp_csc_hsl2rgb.h"
#include "isp_csc_hsl2yuv.h"
/* RGB↔HSL 双像素 SSE2 快路径（csc_sse_selfcheck 对拍对象）。 */
#include "isp_csc_sse.h"

#include <stdlib.h>
#include <string.h>

/** 读公共尺寸参数并加载输入帧；失败返回 NULL（w/h/max_value 经出参返回）。 */
static uint16_t *csc_load_frame(CaseIO *io, int *w, int *h, int *max_value) {
  *w = case_param_int(io, "width", 0);
  *h = case_param_int(io, "height", 0);
  *max_value = case_param_int(io, "max_value", 1023);
  if (*w <= 0 || *h <= 0) {
    snprintf(io->err, CASE_ERR_LEN, "csc: bad size %dx%d", *w, *h);
    return NULL;
  }
  return case_load_in(io, 0, (size_t)(*w) * (size_t)(*h) * 3);
}

/** 内核成功后写回 out0；调用方负责 free in/out。 */
static int csc_run(CaseIO *io, uint16_t *out, size_t len, int rc) {
  if (rc == ISP_OK) rc = case_write_out(io, 0, out, len);
  return rc;
}

int op_csc_rgb2yuv(CaseIO *io) {
  int w, h, max_value;
  const char *standard = case_param_str(io, "standard", "bt601");
  const char *range = case_param_str(io, "range", "full");
  uint16_t *in = csc_load_frame(io, &w, &h, &max_value);
  uint16_t *out;
  size_t len;
  int rc, std_id, rng_id;
  if (in == NULL) return ISP_ERR_ARG;
  if (strcmp(standard, "bt709") == 0) {
    std_id = ISP_CSC_BT709;
  } else if (strcmp(standard, "bt601") == 0) {
    std_id = ISP_CSC_BT601;
  } else {
    snprintf(io->err, CASE_ERR_LEN, "csc_rgb2yuv: bad standard %s", standard);
    free(in);
    return ISP_ERR_ARG;
  }
  if (strcmp(range, "limited") == 0) {
    rng_id = ISP_CSC_RANGE_LIMITED;
  } else if (strcmp(range, "full") == 0) {
    rng_id = ISP_CSC_RANGE_FULL;
  } else {
    snprintf(io->err, CASE_ERR_LEN, "csc_rgb2yuv: bad range %s", range);
    free(in);
    return ISP_ERR_ARG;
  }
  len = (size_t)w * (size_t)h * 3;
  out = (uint16_t *)case_scratch(io, len * 2);
  if (out == NULL) {
    free(in);
    return ISP_ERR_ARG;
  }
  rc = isp_csc_rgb_to_yuv(in, w, h, max_value, (IspCscStandard)std_id,
                          (IspCscRange)rng_id, out);
  rc = csc_run(io, out, len, rc);
  free(in);
  free(out);
  return rc;
}

/** 五个无附加参数的转换 op 的公共骨架。 */
typedef int (*CscKernel)(const uint16_t *src, int w, int h, int max_value,
                         uint16_t *out);

static int csc_simple_op(CaseIO *io, CscKernel kernel) {
  int w, h, max_value;
  uint16_t *in = csc_load_frame(io, &w, &h, &max_value);
  uint16_t *out;
  size_t len;
  int rc;
  if (in == NULL) return ISP_ERR_ARG;
  len = (size_t)w * (size_t)h * 3;
  out = (uint16_t *)case_scratch(io, len * 2);
  if (out == NULL) {
    free(in);
    return ISP_ERR_ARG;
  }
  rc = kernel(in, w, h, max_value, out);
  rc = csc_run(io, out, len, rc);
  free(in);
  free(out);
  return rc;
}

int op_csc_rgb2hsl(CaseIO *io) {
  return csc_simple_op(io, isp_csc_rgb_to_hsl);
}

int op_csc_yuv2rgb(CaseIO *io) {
  return csc_simple_op(io, isp_csc_yuv_to_rgb);
}

int op_csc_yuv2hsl(CaseIO *io) {
  return csc_simple_op(io, isp_csc_yuv_to_hsl);
}

int op_csc_hsl2rgb(CaseIO *io) {
  return csc_simple_op(io, isp_csc_hsl_to_rgb);
}

int op_csc_hsl2yuv(CaseIO *io) {
  return csc_simple_op(io, isp_csc_hsl_to_yuv);
}

/* ---------------------------------------------------------------------------
 * csc_sse_selfcheck：isp_csc_sse.h 双像素 SSE2 快路径 vs 标量逐位对拍。
 * max_value=255：RGB/HSL 全 256^3 输入域穷举（双向）；其余 max_value：
 * LCG 抽样 samples 对（含 hv >= 2*max 的 fmod 慢路径与 s/l 超域输入）。
 * 不匹配数写 scalars（r2h_bad / h2r_bad），自身恒返回 ISP_OK。
 * ------------------------------------------------------------------------- */

static long long sse_sweep_r2h_255(void) {
  long long bad = 0;
  int R, G, B;
  for (R = 0; R < 256; R++) {
    for (G = 0; G < 256; G++) {
      for (B = 0; B < 256; B += 2) {
        uint16_t ref[6], got[6];
        const int B1 = B + 1 < 256 ? B + 1 : B;
        isp_csc_rgb_to_hsl_px(R, G, B, 255, 1.0 / 255, ref);
        isp_csc_rgb_to_hsl_px(R, G, B1, 255, 1.0 / 255, ref + 3);
        isp_csc_rgb2_to_hsl6(R, G, B, R, G, B1, 255, 1.0 / 255, got);
        if (memcmp(ref, got, sizeof(ref)) != 0) bad++;
      }
    }
  }
  return bad;
}

static long long sse_sweep_h2r_255(void) {
  long long bad = 0;
  int H, S, L;
  for (H = 0; H < 256; H++) {
    for (S = 0; S < 256; S++) {
      for (L = 0; L < 256; L += 2) {
        int ref[6], got[6];
        const int L1 = L + 1 < 256 ? L + 1 : L;
        isp_csc_hsl_to_rgb_px(H, S, L, 255, 1.0 / 255, ref, ref + 1, ref + 2);
        isp_csc_hsl_to_rgb_px(H, S, L1, 255, 1.0 / 255, ref + 3, ref + 4,
                              ref + 5);
        isp_csc_hsl2_to_rgb6(H, S, L, H, S, L1, 255, 1.0 / 255, got);
        if (memcmp(ref, got, sizeof(ref)) != 0) bad++;
      }
    }
  }
  return bad;
}

/* LCG 抽样（[h2r] 为 0 时 rgb 输入先钳到 [0,max]——与装帧调用方口径一致；
 * 为 1 时 hsl 输入保留超域/越界以覆盖慢路径）。 */
static long long sse_sample_check(int max_value, int samples, int h2r) {
  long long bad = 0;
  unsigned st = 0x12345678u ^ (unsigned)max_value ^ (unsigned)(h2r << 16);
  int i, k;
  for (i = 0; i < samples; i += 2) {
    int v[6];
    for (k = 0; k < 6; k++) {
      st = st * 1664525u + 1013904223u;
      v[k] = (int)((st >> 8) %
                   ((st & 0x80) ? (unsigned)(max_value * 3)
                                : (unsigned)(max_value + 1)));
    }
    if (h2r) {
      int ref[6], got[6];
      isp_csc_hsl_to_rgb_px(v[0], v[1], v[2], max_value, 1.0 / max_value, ref,
                            ref + 1, ref + 2);
      isp_csc_hsl_to_rgb_px(v[3], v[4], v[5], max_value, 1.0 / max_value,
                            ref + 3, ref + 4, ref + 5);
      isp_csc_hsl2_to_rgb6(v[0], v[1], v[2], v[3], v[4], v[5], max_value,
                           1.0 / max_value, got);
      if (memcmp(ref, got, sizeof(ref)) != 0) bad++;
    } else {
      uint16_t ref[6], got[6];
      for (k = 0; k < 6; k++) {
        if (v[k] > max_value) v[k] = max_value;
      }
      isp_csc_rgb_to_hsl_px(v[0], v[1], v[2], max_value, 1.0 / max_value, ref);
      isp_csc_rgb_to_hsl_px(v[3], v[4], v[5], max_value, 1.0 / max_value,
                            ref + 3);
      isp_csc_rgb2_to_hsl6(v[0], v[1], v[2], v[3], v[4], v[5], max_value,
                           1.0 / max_value, got);
      if (memcmp(ref, got, sizeof(ref)) != 0) bad++;
    }
  }
  return bad;
}

/* nv12→rgb Q8 SSE2 助手 vs 标量同式（LCG 抽样；标量式与 main_win.c 一致）。 */
static long long sse_nv12_check(int samples) {
  long long bad = 0;
  unsigned st = 0xABCDEF01u;
  int k, j;
  for (k = 0; k < samples; k++) {
    unsigned char yb[8], uvb[8], r[8], g[8], b[8];
    for (j = 0; j < 8; j++) {
      st = st * 1664525u + 1013904223u;
      yb[j] = (unsigned char)(st >> 24);
    }
    for (j = 0; j < 8; j++) {
      st = st * 1664525u + 1013904223u;
      uvb[j] = (unsigned char)(st >> 24);
    }
    isp_csc_nv12_rgb8(yb, uvb, r, g, b);
    for (j = 0; j < 8; j++) {
      const int u = uvb[j & ~1] - 128, v = uvb[(j & ~1) + 1] - 128;
      const int yy = yb[j] - 16;
      const int rq = (298 * yy + 459 * v + 128) >> 8;
      const int gq = (298 * yy - 55 * u - 136 * v + 128) >> 8;
      const int bq = (298 * yy + 541 * u + 128) >> 8;
      const int rr = rq < 0 ? 0 : (rq > 255 ? 255 : rq);
      const int gg = gq < 0 ? 0 : (gq > 255 ? 255 : gq);
      const int bb = bq < 0 ? 0 : (bq > 255 ? 255 : bq);
      if (r[j] != rr || g[j] != gg || b[j] != bb) bad++;
    }
  }
  return bad;
}

int op_csc_sse_selfcheck(CaseIO *io) {
  const int max_value = case_param_int(io, "max_value", 255);
  const int samples = case_param_int(io, "samples", 4000000);
  long long r2h_bad, h2r_bad;
  if (max_value == 255) {
    r2h_bad = sse_sweep_r2h_255();
    h2r_bad = sse_sweep_h2r_255();
  } else {
    r2h_bad = sse_sample_check(max_value, samples, 0);
    h2r_bad = sse_sample_check(max_value, samples, 1);
  }
  case_scalar(io, "r2h_bad", (double)r2h_bad);
  case_scalar(io, "h2r_bad", (double)h2r_bad);
  case_scalar(io, "nv12_bad", (double)sse_nv12_check(samples / 2));
  return ISP_OK;
}
