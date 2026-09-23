/**
 * @file harness_blend_split.c
 * @brief 对拍 harness —— 混合/拆分合并组：multiply（双输入）/ blend_mono
 * （双输入）/ blend_mask（三输入 in0=base in1=blend in2=mask）/ mux4
 * （四输入透传）/ split_rgb|yuv|hsl（in0 -> out0..2）/
 * combine_rgb|yuv|hsl（in0..2 -> out0，缺路参数 has_in1=0 等）。
 *
 * params 约定：
 * - 公共：width, height（int）；maxValue（int，缺省 1023）。
 * - multiply：offset1, offset2（double）；in0/in1 = w*h u16 -> out0。
 * - blend_mono：balance（double）；in0/in1 = w*h u16 -> out0。
 * - blend_mask：format = rgb/yuv/hsl/mono，blendChannels = 1/3，
 *   strength（double）；in0 = 基图（mono 时 w*h，其余 w*h*3），
 *   in1 = 混叠图（blendChannels 决定长度），in2 = 蒙版（w*h）-> out0。
 * - mux4：select（int，越界钳位 1..4），channels（int，缺省 1）；
 *   in0..in3 = w*h*channels u16 -> out0 透传选中路。
 * - split_*：in0 = w*h*3 交织 -> out0/out1/out2 各 w*h 平面。
 * - combine_*：has_in0/has_in1/has_in2（0/1，缺省 1，0 表示该路未连接
 *   传 NULL）；可选 len0/len1/len2 覆盖该路有效长度（验证 Dart 的
 *   `i < data.length` 短平面兜底，缺省 w*h）；in0..in2 -> out0 = w*h*3。
 */

#include "harness.h"
#include "isp_blend.h"
#include "isp_split.h"

#include <stdlib.h>
#include <string.h>

/** 取公共尺寸参数；非法时填 io->err 返回 0。 */
static int grp_size(CaseIO *io, int *w, int *h) {
  *w = case_param_int(io, "width", 0);
  *h = case_param_int(io, "height", 0);
  if (*w <= 0 || *h <= 0) {
    snprintf(io->err, CASE_ERR_LEN, "blend_split: bad size %dx%d", *w, *h);
    return 0;
  }
  return 1;
}

/** blend_mask 格式字符串 -> IspBlendFormat；非法返回 -1。 */
static int parse_blend_format(const char *s) {
  if (strcmp(s, "rgb") == 0) return ISP_BLEND_FORMAT_RGB;
  if (strcmp(s, "yuv") == 0) return ISP_BLEND_FORMAT_YUV;
  if (strcmp(s, "hsl") == 0) return ISP_BLEND_FORMAT_HSL;
  if (strcmp(s, "mono") == 0) return ISP_BLEND_FORMAT_MONO;
  return -1;
}

int op_multiply(CaseIO *io) {
  int w, h;
  size_t len;
  const int max_value = case_param_int(io, "maxValue", 1023);
  const double offset1 = case_param_double(io, "offset1", 0.0);
  const double offset2 = case_param_double(io, "offset2", 0.0);
  uint16_t *a, *b, *out;
  int rc;

  if (!grp_size(io, &w, &h)) return ISP_ERR_SIZE;
  len = (size_t)w * (size_t)h;
  a = case_load_in(io, 0, len);
  if (a == NULL) return ISP_ERR_ARG;
  b = case_load_in(io, 1, len);
  if (b == NULL) {
    free(a);
    return ISP_ERR_ARG;
  }
  out = (uint16_t *)case_scratch(io, len * sizeof(uint16_t));
  if (out == NULL) {
    free(a);
    free(b);
    return ISP_ERR_ARG;
  }
  rc = isp_blend_multiply(a, b, (int)len, offset1, offset2, max_value, out);
  if (rc == ISP_OK) rc = case_write_out(io, 0, out, len);
  free(a);
  free(b);
  free(out);
  return rc;
}

int op_blend_mono(CaseIO *io) {
  int w, h;
  size_t len;
  const int max_value = case_param_int(io, "maxValue", 1023);
  const double balance = case_param_double(io, "balance", 0.5);
  uint16_t *a, *b, *out;
  int rc;

  if (!grp_size(io, &w, &h)) return ISP_ERR_SIZE;
  len = (size_t)w * (size_t)h;
  a = case_load_in(io, 0, len);
  if (a == NULL) return ISP_ERR_ARG;
  b = case_load_in(io, 1, len);
  if (b == NULL) {
    free(a);
    return ISP_ERR_ARG;
  }
  out = (uint16_t *)case_scratch(io, len * sizeof(uint16_t));
  if (out == NULL) {
    free(a);
    free(b);
    return ISP_ERR_ARG;
  }
  rc = isp_blend_add(a, b, (int)len, balance, max_value, out);
  if (rc == ISP_OK) rc = case_write_out(io, 0, out, len);
  free(a);
  free(b);
  free(out);
  return rc;
}

int op_blend_mask(CaseIO *io) {
  int w, h;
  const char *format = case_param_str(io, "format", "rgb");
  const int fmt = parse_blend_format(format);
  const int blend_channels = case_param_int(io, "blendChannels", 1);
  const double strength = case_param_double(io, "strength", 1.0);
  const int max_value = case_param_int(io, "maxValue", 1023);
  int base_channels;
  size_t pixels;
  uint16_t *base, *blend, *mask;
  int rc;

  if (!grp_size(io, &w, &h)) return ISP_ERR_SIZE;
  if (fmt < 0) {
    snprintf(io->err, CASE_ERR_LEN, "blend_mask: bad format %s", format);
    return ISP_ERR_ARG;
  }
  if (blend_channels != 1 && blend_channels != 3) {
    snprintf(io->err, CASE_ERR_LEN, "blend_mask: bad blendChannels %d",
             blend_channels);
    return ISP_ERR_ARG;
  }
  base_channels = (fmt == ISP_BLEND_FORMAT_MONO) ? 1 : 3;
  pixels = (size_t)w * (size_t)h;
  base = case_load_in(io, 0, pixels * (size_t)base_channels);
  if (base == NULL) return ISP_ERR_ARG;
  blend = case_load_in(io, 1, pixels * (size_t)blend_channels);
  if (blend == NULL) {
    free(base);
    return ISP_ERR_ARG;
  }
  mask = case_load_in(io, 2, pixels);
  if (mask == NULL) {
    free(base);
    free(blend);
    return ISP_ERR_ARG;
  }
  /* isp_blend_mask_apply 为原地版本：base 既作输入又作输出（与 Dart
   * 「复制基图再叠加」逐位一致，见 isp_blend.h 函数注释）。 */
  rc = isp_blend_mask_apply(base, blend, mask, w, h, (IspBlendFormat)fmt,
                            blend_channels, strength, max_value);
  if (rc == ISP_OK) {
    rc = case_write_out(io, 0, base, pixels * (size_t)base_channels);
  }
  free(base);
  free(blend);
  free(mask);
  return rc;
}

int op_mux4(CaseIO *io) {
  int w, h;
  const int channels = case_param_int(io, "channels", 1);
  const int select = case_param_int(io, "select", 1);
  size_t len;
  uint16_t *ins[4];
  const uint16_t *sel;
  int rc = ISP_OK;
  int i;

  if (!grp_size(io, &w, &h)) return ISP_ERR_SIZE;
  if (channels <= 0) {
    snprintf(io->err, CASE_ERR_LEN, "mux4: bad channels %d", channels);
    return ISP_ERR_ARG;
  }
  len = (size_t)w * (size_t)h * (size_t)channels;
  for (i = 0; i < 4; i++) {
    ins[i] = case_load_in(io, i, len);
    if (ins[i] == NULL) {
      while (--i >= 0) free(ins[i]);
      return ISP_ERR_ARG;
    }
  }
  sel = isp_mux4_select(select, ins[0], ins[1], ins[2], ins[3]);
  if (sel == NULL) {
    snprintf(io->err, CASE_ERR_LEN, "mux4: selected input is NULL");
    rc = ISP_ERR_ARG;
  } else {
    rc = case_write_out(io, 0, sel, len);
  }
  for (i = 0; i < 4; i++) free(ins[i]);
  return rc;
}

/** split_* 公共实现：in0 交织 -> out0..2 三平面。 */
static int do_split(CaseIO *io,
                    int (*fn)(const uint16_t *, int, int, int,
                              uint16_t *, uint16_t *, uint16_t *)) {
  int w, h;
  const int max_value = case_param_int(io, "maxValue", 1023);
  size_t pixels;
  uint16_t *src, *p0, *p1, *p2;
  int rc;

  if (!grp_size(io, &w, &h)) return ISP_ERR_SIZE;
  pixels = (size_t)w * (size_t)h;
  src = case_load_in(io, 0, pixels * 3);
  if (src == NULL) return ISP_ERR_ARG;
  p0 = (uint16_t *)case_scratch(io, pixels * 3 * sizeof(uint16_t));
  if (p0 == NULL) {
    free(src);
    return ISP_ERR_ARG;
  }
  p1 = p0 + pixels;
  p2 = p1 + pixels;
  rc = fn(src, w, h, max_value, p0, p1, p2);
  if (rc == ISP_OK) rc = case_write_out(io, 0, p0, pixels);
  if (rc == ISP_OK) rc = case_write_out(io, 1, p1, pixels);
  if (rc == ISP_OK) rc = case_write_out(io, 2, p2, pixels);
  free(src);
  free(p0);
  return rc;
}

int op_split_rgb(CaseIO *io) { return do_split(io, isp_split_rgb); }

int op_split_yuv(CaseIO *io) { return do_split(io, isp_split_yuv); }

int op_split_hsl(CaseIO *io) { return do_split(io, isp_split_hsl); }

/** combine_* 公共实现：三平面（可缺路/短平面）-> out0 交织。 */
static int do_combine(CaseIO *io,
                      int (*fn)(const uint16_t *, int,
                                const uint16_t *, int,
                                const uint16_t *, int,
                                int, int, int, uint16_t *)) {
  int w, h;
  const int max_value = case_param_int(io, "maxValue", 1023);
  size_t pixels;
  uint16_t *ins[3] = {NULL, NULL, NULL};
  int lens[3] = {0, 0, 0};
  uint16_t *dst;
  int rc = ISP_OK;
  int i;
  char key[16];

  if (!grp_size(io, &w, &h)) return ISP_ERR_SIZE;
  pixels = (size_t)w * (size_t)h;
  for (i = 0; i < 3; i++) {
    snprintf(key, sizeof(key), "has_in%d", i);
    if (case_param_int(io, key, 1) == 0) continue; /* 未连接：NULL + len 0 */
    snprintf(key, sizeof(key), "len%d", i);
    lens[i] = case_param_int(io, key, (int)pixels);
    if (lens[i] <= 0) {
      snprintf(io->err, CASE_ERR_LEN, "combine: bad len%d %d", i, lens[i]);
      rc = ISP_ERR_ARG;
      goto done;
    }
    ins[i] = case_load_in(io, i, (size_t)lens[i]);
    if (ins[i] == NULL) {
      rc = ISP_ERR_ARG;
      goto done;
    }
  }
  dst = (uint16_t *)case_scratch(io, pixels * 3 * sizeof(uint16_t));
  if (dst == NULL) {
    rc = ISP_ERR_ARG;
    goto done;
  }
  rc = fn(ins[0], lens[0], ins[1], lens[1], ins[2], lens[2],
          w, h, max_value, dst);
  if (rc == ISP_OK) rc = case_write_out(io, 0, dst, pixels * 3);
  free(dst);
done:
  for (i = 0; i < 3; i++) free(ins[i]);
  return rc;
}

int op_combine_rgb(CaseIO *io) { return do_combine(io, isp_combine_rgb); }

int op_combine_yuv(CaseIO *io) { return do_combine(io, isp_combine_yuv); }

int op_combine_hsl(CaseIO *io) { return do_combine(io, isp_combine_hsl); }
