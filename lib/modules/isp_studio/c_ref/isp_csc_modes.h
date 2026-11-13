#ifndef ISP_CSC_MODES_H
#define ISP_CSC_MODES_H

#include "isp_common.h"
#include "isp_csc_common.h"

#define ISP_CSC_VARIANT_RGB2YUV 0
#define ISP_CSC_VARIANT_RGB2HSL 1
#define ISP_CSC_VARIANT_YUV2RGB 2
#define ISP_CSC_VARIANT_YUV2HSL 3
#define ISP_CSC_VARIANT_HSL2RGB 4
#define ISP_CSC_VARIANT_HSL2YUV 5

#define ISP_CSC_CODEGEN_FUNC 0
#define ISP_CSC_CODEGEN_FUNC_FIXED 1
#define ISP_CSC_CODEGEN_LUT 2
#define ISP_CSC_CODEGEN_LUT_FIXED 3

static int isp_csc_div_round_nearest(int64_t num, int64_t den) {
  if (den <= 0) return 0;
  if (num >= 0) return (int)((num + (den >> 1)) / den);
  return -(int)((-num + (den >> 1)) / den);
}

static int isp_csc_q14_clamp(int v, int max_value) {
  return v < 0 ? 0 : (v > max_value ? max_value : v);
}

static int isp_csc_q14_norm(int v, int max_value) {
  return isp_csc_div_round_nearest((int64_t)v * 16384, max_value);
}

static int isp_csc_q14_mul(int a, int b) {
  return (int)(((int64_t)a * b + 8192) >> 14);
}

static void isp_csc_rgb_to_hsl_q14(int r, int g, int b, int max_value,
                                   uint16_t *out) {
  int mx = g > b ? g : b;
  int mn = g < b ? g : b;
  int d, l, s = 0, h = 0;
  mx = r > mx ? r : mx;
  mn = r < mn ? r : mn;
  l = (mx + mn) >> 1;
  d = mx - mn;
  if (d > 0) {
    const int den = l > 8192 ? 32768 - mx - mn : mx + mn;
    int t;
    s = isp_csc_div_round_nearest((int64_t)d * 16384, den);
    if (mx == r) {
      t = isp_csc_div_round_nearest((int64_t)(g - b) * 16384, d);
      if (t < 0) t += 98304;
    } else if (mx == g) {
      t = isp_csc_div_round_nearest((int64_t)(b - r) * 16384, d) + 32768;
    } else {
      t = isp_csc_div_round_nearest((int64_t)(r - g) * 16384, d) + 65536;
    }
    h = isp_csc_div_round_nearest(t, 6);
  }
  out[0] = (uint16_t)isp_csc_q14_clamp(
      isp_csc_div_round_nearest((int64_t)h * max_value, 16384), max_value);
  out[1] = (uint16_t)isp_csc_q14_clamp(
      isp_csc_div_round_nearest((int64_t)s * max_value, 16384), max_value);
  out[2] = (uint16_t)isp_csc_q14_clamp(
      isp_csc_div_round_nearest((int64_t)l * max_value, 16384), max_value);
}

static int isp_csc_hue_q14(int p, int q, int t) {
  if (t < 0) t += 49152;
  if (t > 49152) t -= 49152;
  if (t < 8192) return p + isp_csc_div_round_nearest((q - p) * (int64_t)t, 8192);
  if (t < 24576) return q;
  if (t < 32768) {
    return p + isp_csc_div_round_nearest((q - p) * (int64_t)(32768 - t), 8192);
  }
  return p;
}

static void isp_csc_hsl_to_rgb_q14(int h, int s, int l, int max_value,
                                   int *ri, int *gi, int *bi) {
  int r, g, b;
  h %= 16384;
  if (h < 0) h += 16384;
  if (s == 0) {
    r = g = b = l;
  } else {
    const int q = l < 8192 ? l + isp_csc_q14_mul(l, s)
                           : l + s - isp_csc_q14_mul(l, s);
    const int p = 2 * l - q;
    const int h3 = h * 3;
    r = isp_csc_hue_q14(p, q, h3 + 16384);
    g = isp_csc_hue_q14(p, q, h3);
    b = isp_csc_hue_q14(p, q, h3 - 16384);
  }
  *ri = isp_csc_q14_clamp(
      isp_csc_div_round_nearest((int64_t)r * max_value, 16384), max_value);
  *gi = isp_csc_q14_clamp(
      isp_csc_div_round_nearest((int64_t)g * max_value, 16384), max_value);
  *bi = isp_csc_q14_clamp(
      isp_csc_div_round_nearest((int64_t)b * max_value, 16384), max_value);
}

static int isp_csc_lut_index(int v, int max_value) {
  return v < 0 ? 0 : (v > max_value ? max_value : v);
}

static int isp_csc_norm_round(double v, int max_value) {
  return (int)isp_csc_dround(v * max_value);
}

static void isp_csc_rgb_to_yuv_lut_px(int r, int g, int b, int max_value,
                                      int limited, const int32_t *lut,
                                      uint16_t *out) {
  const int stride = max_value + 1;
  const int half = max_value >> 1;
  r = isp_csc_lut_index(r, max_value);
  g = isp_csc_lut_index(g, max_value);
  b = isp_csc_lut_index(b, max_value);
  int y = (int)(((int64_t)lut[r] + lut[stride + g] + lut[2 * stride + b] +
                 32768) >> 16);
  int u = (int)(((int64_t)lut[3 * stride + r] + lut[4 * stride + g] +
                 lut[5 * stride + b] + 32768) >> 16) + half;
  int v = (int)(((int64_t)lut[6 * stride + r] + lut[7 * stride + g] +
                 lut[8 * stride + b] + 32768) >> 16) + half;
  if (limited) {
    const int off_y = (max_value * 16 + 127) / 255;
    int d;
    y = off_y + (y * 219 + 127) / 255;
    d = u - half;
    u = half + (d * 224 + (d >= 0 ? 127 : -127)) / 255;
    d = v - half;
    v = half + (d * 224 + (d >= 0 ? 127 : -127)) / 255;
  }
  out[0] = isp_clamp_u16(y, max_value);
  out[1] = isp_clamp_u16(u, max_value);
  out[2] = isp_clamp_u16(v, max_value);
}

static void isp_csc_yuv_to_rgb_lut_px(int y, int u, int v, int max_value,
                                      const int32_t *lut, int *rgb) {
  const int stride = max_value + 1;
  u = isp_csc_lut_index(u, max_value);
  v = isp_csc_lut_index(v, max_value);
  rgb[0] = isp_clamp_int(y + (int)((lut[v] + 32768) >> 16), 0, max_value);
  rgb[1] = isp_clamp_int(
      y + (int)(((int64_t)lut[stride + u] + lut[2 * stride + v] + 32768) >> 16),
      0, max_value);
  rgb[2] = isp_clamp_int(y + (int)((lut[3 * stride + u] + 32768) >> 16), 0,
                         max_value);
}

static void isp_csc_apply_px(int variant, int mode, int standard, int limited,
                             int max_value, const uint16_t *in,
                             const void *lut, const void *norm_lut,
                             uint16_t *out) {
  const double inv = 1.0 / max_value;
  const int half = max_value >> 1;
  int a[3];
  int r = in[0], g = in[1], b = in[2];
  if (mode == ISP_CSC_CODEGEN_LUT ||
      mode == ISP_CSC_CODEGEN_LUT_FIXED) {
    if (variant == ISP_CSC_VARIANT_RGB2YUV ||
        variant == ISP_CSC_VARIANT_HSL2YUV) {
      /* HSL2YUV 先转 RGB，再复用同一张 RGB→YUV 乘积表。 */
    } else if (variant == ISP_CSC_VARIANT_YUV2RGB ||
               variant == ISP_CSC_VARIANT_YUV2HSL) {
      isp_csc_yuv_to_rgb_lut_px(r, g, b, max_value,
                                (const int32_t *)lut, a);
      r = a[0]; g = a[1]; b = a[2];
    } else if (mode == ISP_CSC_CODEGEN_LUT) {
      const double *norm = (const double *)norm_lut;
      const int stride = max_value + 1;
      r = isp_csc_norm_round(norm[isp_csc_lut_index(r, max_value)], max_value);
      g = isp_csc_norm_round(norm[stride + isp_csc_lut_index(g, max_value)],
                             max_value);
      b = isp_csc_norm_round(norm[2 * stride + isp_csc_lut_index(b, max_value)],
                             max_value);
    } else {
      const int32_t *norm = (const int32_t *)norm_lut;
      const int stride = max_value + 1;
      r = norm[isp_csc_lut_index(r, max_value)];
      g = norm[stride + isp_csc_lut_index(g, max_value)];
      b = norm[2 * stride + isp_csc_lut_index(b, max_value)];
    }
  }

  switch (variant) {
    case ISP_CSC_VARIANT_RGB2YUV:
      if (mode == ISP_CSC_CODEGEN_LUT || mode == ISP_CSC_CODEGEN_LUT_FIXED) {
        isp_csc_rgb_to_yuv_lut_px(r, g, b, max_value, limited,
                                  (const int32_t *)lut, out);
      } else {
        int cyR, cyG, cyB, cuR, cuG, cuB, cvR, cvG, cvB;
        int y, u, v;
        isp_csc_rgb_to_yuv_coef(standard, &cyR, &cyG, &cyB, &cuR, &cuG, &cuB,
                                &cvR, &cvG, &cvB);
        y = (int)(((int64_t)cyR * r + (int64_t)cyG * g +
                   (int64_t)cyB * b + 32768) >> 16);
        u = (int)(((int64_t)cuR * r + (int64_t)cuG * g +
                   (int64_t)cuB * b + 32768) >> 16) + half;
        v = (int)(((int64_t)cvR * r + (int64_t)cvG * g +
                   (int64_t)cvB * b + 32768) >> 16) + half;
        if (limited) {
          const int off_y = (max_value * 16 + 127) / 255;
          int d;
          y = off_y + (y * 219 + 127) / 255;
          d = u - half;
          u = half + (d * 224 + (d >= 0 ? 127 : -127)) / 255;
          d = v - half;
          v = half + (d * 224 + (d >= 0 ? 127 : -127)) / 255;
        }
        out[0] = isp_clamp_u16(y, max_value);
        out[1] = isp_clamp_u16(u, max_value);
        out[2] = isp_clamp_u16(v, max_value);
      }
      break;
    case ISP_CSC_VARIANT_RGB2HSL:
      if (mode == ISP_CSC_CODEGEN_FUNC_FIXED ||
          mode == ISP_CSC_CODEGEN_LUT_FIXED) {
        if (mode == ISP_CSC_CODEGEN_FUNC_FIXED) {
          r = isp_csc_q14_norm(r, max_value);
          g = isp_csc_q14_norm(g, max_value);
          b = isp_csc_q14_norm(b, max_value);
        }
        isp_csc_rgb_to_hsl_q14(r, g, b, max_value, out);
      } else {
        isp_csc_rgb_to_hsl_px(r, g, b, max_value, inv, out);
      }
      break;
    case ISP_CSC_VARIANT_YUV2RGB:
      if (mode == ISP_CSC_CODEGEN_LUT || mode == ISP_CSC_CODEGEN_LUT_FIXED) {
        out[0] = (uint16_t)r; out[1] = (uint16_t)g; out[2] = (uint16_t)b;
      } else {
        isp_csc_yuv_to_rgb_px_s(r, g, b, half, max_value, standard, a, a + 1,
                                a + 2);
        out[0] = (uint16_t)a[0]; out[1] = (uint16_t)a[1]; out[2] = (uint16_t)a[2];
      }
      break;
    case ISP_CSC_VARIANT_YUV2HSL:
      if (mode != ISP_CSC_CODEGEN_LUT && mode != ISP_CSC_CODEGEN_LUT_FIXED) {
        isp_csc_yuv_to_rgb_px_s(r, g, b, half, max_value, standard, a, a + 1,
                                a + 2);
        r = a[0]; g = a[1]; b = a[2];
      }
      if (mode == ISP_CSC_CODEGEN_FUNC_FIXED ||
          mode == ISP_CSC_CODEGEN_LUT_FIXED) {
        if (mode == ISP_CSC_CODEGEN_FUNC_FIXED) {
          r = isp_csc_q14_norm(r, max_value);
          g = isp_csc_q14_norm(g, max_value);
          b = isp_csc_q14_norm(b, max_value);
        }
        isp_csc_rgb_to_hsl_q14(r, g, b, max_value, out);
      } else {
        isp_csc_rgb_to_hsl_px(r, g, b, max_value, inv, out);
      }
      break;
    case ISP_CSC_VARIANT_HSL2RGB:
      if (mode == ISP_CSC_CODEGEN_FUNC_FIXED ||
          mode == ISP_CSC_CODEGEN_LUT_FIXED) {
        if (mode == ISP_CSC_CODEGEN_FUNC_FIXED) {
          r = isp_csc_q14_norm(r, max_value);
          g = isp_csc_q14_norm(g, max_value);
          b = isp_csc_q14_norm(b, max_value);
        }
        isp_csc_hsl_to_rgb_q14(r, g, b, max_value, a, a + 1, a + 2);
      } else {
        isp_csc_hsl_to_rgb_px(r, g, b, max_value, inv, a, a + 1, a + 2);
      }
      out[0] = (uint16_t)a[0]; out[1] = (uint16_t)a[1]; out[2] = (uint16_t)a[2];
      break;
    case ISP_CSC_VARIANT_HSL2YUV:
      if (mode == ISP_CSC_CODEGEN_FUNC_FIXED ||
          mode == ISP_CSC_CODEGEN_LUT_FIXED) {
        r = isp_csc_q14_norm(r, max_value);
        g = isp_csc_q14_norm(g, max_value);
        b = isp_csc_q14_norm(b, max_value);
        isp_csc_hsl_to_rgb_q14(r, g, b, max_value, a, a + 1, a + 2);
      } else {
        isp_csc_hsl_to_rgb_px(r, g, b, max_value, inv, a, a + 1, a + 2);
      }
      if (mode == ISP_CSC_CODEGEN_LUT || mode == ISP_CSC_CODEGEN_LUT_FIXED) {
        isp_csc_rgb_to_yuv_lut_px(a[0], a[1], a[2], max_value, 0,
                                  (const int32_t *)lut, out);
      } else {
        isp_csc_rgb_to_yuv_px_s(a[0], a[1], a[2], half, max_value, standard,
                                out);
      }
      break;
    default:
      out[0] = in[0]; out[1] = in[1]; out[2] = in[2];
      break;
  }
}

static int isp_csc_apply_modes(const uint16_t *in, int w, int h, int max_value,
                               int variant, int mode, int standard, int limited,
                               const void *lut, const void *norm_lut,
                             uint16_t *out) {
  const int rc = isp_csc_check(in, out, w, h, max_value);
  size_t p, i;
  if (rc != ISP_OK) return rc;
  for (p = 0, i = 0; p < (size_t)w * (size_t)h; p++, i += 3) {
    isp_csc_apply_px(variant, mode, standard, limited, max_value, in + i, lut,
                     norm_lut, out + i);
  }
  return ISP_OK;
}

#endif
