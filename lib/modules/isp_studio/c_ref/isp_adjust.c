#include "isp_adjust.h"

#include <math.h>

/* ---------------------------------------------------------------------------
 * 本文件内部 static helper（未进 isp_common 的私有工具，见各自注释）。
 * ------------------------------------------------------------------------- */

/**
 * @brief double 输入的 _clampTo 等价物：先比较、后四舍五入。
 *
 * Dart 来源：isp_kernels.dart `_clampTo`：
 * `v < 0 ? 0 : (v > maxValue ? maxValue : v.round())`。
 * 注意顺序是先按 double 原值与 0 / maxValue 比较，越界直接取端点，
 * 界内才 round()（Dart round 为四舍五入、半边远离零，与 C99 round() 一致；
 * 此处入参经前置比较已非负，等价 floor(v + 0.5)）。
 * isp_common.h 的 isp_clamp_u16 只接收 int，故本 helper 作为本文件私有
 * static 实现（如后续多个文件都需要，建议提升进 isp_common）。
 */
static int isp_adjust_clamp_to(double v, int max_value) {
  if (v < 0) return 0;
  if (v > (double)max_value) return max_value;
  return (int)round(v);
}

/**
 * @brief HSL→RGB 的分段 hue 映射。
 *
 * Dart 来源：isp_kernels.dart `_hueToRgb`。逐行对应，含 t 的 ±1 环绕修正。
 */
static double isp_adjust_hue_to_rgb(double p, double q, double t) {
  double tt = t;
  if (tt < 0) tt += 1;
  if (tt > 1) tt -= 1;
  if (tt < 1.0 / 6) return p + (q - p) * 6 * tt;
  if (tt < 1.0 / 2) return q;
  if (tt < 2.0 / 3) return p + (q - p) * (2.0 / 3 - tt) * 6;
  return p;
}

/**
 * @brief 单像素 HSL→RGB（中间 RGB 量化为整数，供色彩平衡 HSL 域往返用）。
 *
 * Dart 来源：isp_kernels.dart `hslToRgb` 的循环体。
 * h 取模用 fmod：Dart 的 % 为欧几里得取模，被模数非负时与 fmod 结果一致，
 * 此处 hsl[0] >= 0 故无需修正。
 */
static void isp_adjust_hsl_to_rgb_px(const uint16_t *hsl, int max_value,
                                     uint16_t *rgb) {
  const double inv = 1.0 / max_value;
  const double hh = fmod(hsl[0] * inv, 1.0);
  const double s = hsl[1] * inv;
  const double l = hsl[2] * inv;
  double r, g, b;
  if (s == 0) {
    r = g = b = l;
  } else {
    const double q = l < 0.5 ? l * (1 + s) : l + s - l * s;
    const double p = 2 * l - q;
    r = isp_adjust_hue_to_rgb(p, q, hh + 1.0 / 3);
    g = isp_adjust_hue_to_rgb(p, q, hh);
    b = isp_adjust_hue_to_rgb(p, q, hh - 1.0 / 3);
  }
  rgb[0] = (uint16_t)isp_adjust_clamp_to(r * max_value, max_value);
  rgb[1] = (uint16_t)isp_adjust_clamp_to(g * max_value, max_value);
  rgb[2] = (uint16_t)isp_adjust_clamp_to(b * max_value, max_value);
}

/**
 * @brief 单像素 RGB→HSL（供色彩平衡 HSL 域往返用）。
 *
 * Dart 来源：isp_kernels.dart `rgbToHsl` 的循环体。
 * 关键差异点：Dart `((g - b) / d) % 6` 的 % 是欧几里得取模，结果恒落在
 * [0, 6)；C 的 fmod 对被模数为负时返回负值，需 +6 修正后再除 6，
 * 之后 `if (h < 0) h += 1` 与 Dart 原式保持一致（保留以逐行对应）。
 */
static void isp_adjust_rgb_to_hsl_px(const uint16_t *rgb, int max_value,
                                     uint16_t *hsl) {
  const double inv = 1.0 / max_value;
  const double r = rgb[0] * inv;
  const double g = rgb[1] * inv;
  const double b = rgb[2] * inv;
  const double mx = ISP_MAX(r, ISP_MAX(g, b));
  const double mn = ISP_MIN(r, ISP_MIN(g, b));
  const double l = (mx + mn) / 2;
  double hh = 0.0;
  double s = 0.0;
  const double d = mx - mn;
  if (d > 0) {
    s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn);
    if (mx == r) {
      hh = fmod((g - b) / d, 6.0);
      if (hh < 0) hh += 6.0; /* Dart % 恒非负，fmod 需修正 */
    } else if (mx == g) {
      hh = (b - r) / d + 2;
    } else {
      hh = (r - g) / d + 4;
    }
    hh /= 6;
    if (hh < 0) hh += 1;
  }
  hsl[0] = (uint16_t)isp_adjust_clamp_to(hh * max_value, max_value);
  hsl[1] = (uint16_t)isp_adjust_clamp_to(s * max_value, max_value);
  hsl[2] = (uint16_t)isp_adjust_clamp_to(l * max_value, max_value);
}

/**
 * @brief 亮度/对比度的单点映射 adjust(y)（Dart 同名闭包）。
 *
 * Dart 来源：isp_kernels.dart adjustBrightContrast 内
 * `int adjust(int y) => _clampTo(((y * bs) - base) * gs + base, maxValue)`。
 */
static int isp_adjust_bc_map(int y, double bs, double base, double gs,
                             int max_value) {
  return isp_adjust_clamp_to(((y * bs) - base) * gs + base, max_value);
}

/* ---------------------------------------------------------------------------
 * 参数公共校验
 * ------------------------------------------------------------------------- */

static int isp_adjust_check(const uint16_t *data, int w, int h,
                            int max_value) {
  if (data == NULL) return ISP_ERR_ARG;
  if (w <= 0 || h <= 0) return ISP_ERR_SIZE;
  if (max_value <= 0) return ISP_ERR_ARG;
  return ISP_OK;
}

/* ---------------------------------------------------------------------------
 * 六个调节器
 * ------------------------------------------------------------------------- */

int isp_adjust_hsl(uint16_t *hsl, int w, int h, int max_value,
                   double h_shift_deg, double s_gain, double l_gain) {
  const int rc = isp_adjust_check(hsl, w, h, max_value);
  const int m = max_value + 1; /* 色环模数：H 在 0..max_value 上循环 */
  const int64_t shift = (int64_t)round(h_shift_deg / 360.0 * max_value);
  const size_t n = (size_t)w * (size_t)h;
  size_t px;
  if (rc != ISP_OK) return rc;
  /* 恒等直通：不动数据（对应 Dart 的 return hsl 不拷贝分支）。 */
  if (h_shift_deg == 0 && s_gain == 1.0 && l_gain == 1.0) return ISP_OK;
  for (px = 0; px < n; px++) {
    uint16_t *const p = hsl + px * 3;
    /* C 的 % 对负数返回负值，用 ((x % m) + m) % m 修正环绕（与 Dart 注释一致）。 */
    const int64_t hv = (int64_t)p[0] + shift;
    p[0] = (uint16_t)(((hv % m) + m) % m);
    p[1] = (uint16_t)isp_adjust_clamp_to(p[1] * s_gain, max_value);
    p[2] = (uint16_t)isp_adjust_clamp_to(p[2] * l_gain, max_value);
  }
  return ISP_OK;
}

int isp_adjust_rgb(uint16_t *rgb, int w, int h, int max_value,
                   double r_gain, double g_gain, double b_gain) {
  const int rc = isp_adjust_check(rgb, w, h, max_value);
  const size_t n = (size_t)w * (size_t)h;
  size_t px;
  if (rc != ISP_OK) return rc;
  if (r_gain == 1.0 && g_gain == 1.0 && b_gain == 1.0) return ISP_OK;
  for (px = 0; px < n; px++) {
    uint16_t *const p = rgb + px * 3;
    p[0] = (uint16_t)isp_adjust_clamp_to(p[0] * r_gain, max_value);
    p[1] = (uint16_t)isp_adjust_clamp_to(p[1] * g_gain, max_value);
    p[2] = (uint16_t)isp_adjust_clamp_to(p[2] * b_gain, max_value);
  }
  return ISP_OK;
}

int isp_adjust_yuv(uint16_t *yuv, int w, int h, int max_value,
                   double y_gain, double u_gain, double v_gain) {
  const int rc = isp_adjust_check(yuv, w, h, max_value);
  const int half = max_value >> 1; /* 色度中点：增益不改变中性色点 */
  const size_t n = (size_t)w * (size_t)h;
  size_t px;
  if (rc != ISP_OK) return rc;
  if (y_gain == 1.0 && u_gain == 1.0 && v_gain == 1.0) return ISP_OK;
  for (px = 0; px < n; px++) {
    uint16_t *const p = yuv + px * 3;
    p[0] = (uint16_t)isp_adjust_clamp_to(p[0] * y_gain, max_value);
    p[1] = (uint16_t)isp_adjust_clamp_to(half + (p[1] - half) * u_gain,
                                         max_value);
    p[2] = (uint16_t)isp_adjust_clamp_to(half + (p[2] - half) * v_gain,
                                         max_value);
  }
  return ISP_OK;
}

int isp_adjust_sat_bright(uint16_t *data, int w, int h,
                          IspAdjustFormat format, int max_value,
                          double sat_gain, double bright_gain) {
  const int rc = isp_adjust_check(data, w, h, max_value);
  const size_t n = (size_t)w * (size_t)h;
  size_t px;
  if (rc != ISP_OK) return rc;
  if (format != ISP_ADJ_FMT_RGB && format != ISP_ADJ_FMT_YUV &&
      format != ISP_ADJ_FMT_HSL) {
    return ISP_ERR_UNSUPPORTED;
  }
  if (sat_gain == 1.0 && bright_gain == 1.0) return ISP_OK;
  switch (format) {
    case ISP_ADJ_FMT_RGB:
      for (px = 0; px < n; px++) {
        uint16_t *const p = data + px * 3;
        const int r = p[0], g = p[1], b = p[2];
        /* BT.601 全范围亮度（与 rgbToYuv 的 Y 一致）。 */
        const double y = 0.299 * r + 0.587 * g + 0.114 * b;
        /* 先保亮度饱和度混合 c' = Y + (c − Y) × sat，再整体乘 bright。 */
        p[0] = (uint16_t)isp_adjust_clamp_to(
            (y + (r - y) * sat_gain) * bright_gain, max_value);
        p[1] = (uint16_t)isp_adjust_clamp_to(
            (y + (g - y) * sat_gain) * bright_gain, max_value);
        p[2] = (uint16_t)isp_adjust_clamp_to(
            (y + (b - y) * sat_gain) * bright_gain, max_value);
      }
      return ISP_OK;
    case ISP_ADJ_FMT_YUV: {
      const int half = max_value >> 1;
      for (px = 0; px < n; px++) {
        uint16_t *const p = data + px * 3;
        p[0] = (uint16_t)isp_adjust_clamp_to(p[0] * bright_gain, max_value);
        p[1] = (uint16_t)isp_adjust_clamp_to(half + (p[1] - half) * sat_gain,
                                             max_value);
        p[2] = (uint16_t)isp_adjust_clamp_to(half + (p[2] - half) * sat_gain,
                                             max_value);
      }
      return ISP_OK;
    }
    default: /* ISP_ADJ_FMT_HSL */
      for (px = 0; px < n; px++) {
        uint16_t *const p = data + px * 3;
        /* H 不变；S 乘 sat_gain；L 乘 bright_gain。 */
        p[1] = (uint16_t)isp_adjust_clamp_to(p[1] * sat_gain, max_value);
        p[2] = (uint16_t)isp_adjust_clamp_to(p[2] * bright_gain, max_value);
      }
      return ISP_OK;
  }
}

int isp_adjust_bright_contrast(uint16_t *data, int w, int h,
                               IspAdjustFormat format, int max_value,
                               double bright_pct, double baseline_pct,
                               double gain_pct) {
  const int rc = isp_adjust_check(data, w, h, max_value);
  const size_t n = (size_t)w * (size_t)h;
  const double base = baseline_pct / 100.0 * max_value;
  const double bs = bright_pct / 100.0;
  const double gs = gain_pct / 100.0;
  size_t px;
  if (rc != ISP_OK) return rc;
  if (format != ISP_ADJ_FMT_RGB && format != ISP_ADJ_FMT_YUV &&
      format != ISP_ADJ_FMT_HSL && format != ISP_ADJ_FMT_MONO) {
    return ISP_ERR_UNSUPPORTED;
  }
  /* 恒等与基线无关（对应 Dart 的恒等分支）。 */
  if (bright_pct == 100 && gain_pct == 100) return ISP_OK;
  switch (format) {
    case ISP_ADJ_FMT_RGB:
      for (px = 0; px < n; px++) {
        uint16_t *const p = data + px * 3;
        const int r = p[0], g = p[1], b = p[2];
        /* BT.601 全范围亮度（double，不取整）。 */
        const double y = 0.299 * r + 0.587 * g + 0.114 * b;
        double ratio;
        if (y <= 0) continue; /* 纯黑像素无亮度比例可言，保持 0 */
        /* Dart：ratio = adjust(y.round()) / y —— adjust 返回 int。 */
        ratio = (double)isp_adjust_bc_map((int)round(y), bs, base, gs,
                                          max_value) /
                y;
        p[0] = (uint16_t)isp_adjust_clamp_to(r * ratio, max_value);
        p[1] = (uint16_t)isp_adjust_clamp_to(g * ratio, max_value);
        p[2] = (uint16_t)isp_adjust_clamp_to(b * ratio, max_value);
      }
      return ISP_OK;
    case ISP_ADJ_FMT_YUV:
      for (px = 0; px < n; px++) {
        uint16_t *const p = data + px * 3;
        p[0] = (uint16_t)isp_adjust_bc_map(p[0], bs, base, gs, max_value);
        /* U/V 不变 */
      }
      return ISP_OK;
    case ISP_ADJ_FMT_HSL:
      for (px = 0; px < n; px++) {
        uint16_t *const p = data + px * 3;
        p[2] = (uint16_t)isp_adjust_bc_map(p[2], bs, base, gs, max_value);
        /* H/S 不变 */
      }
      return ISP_OK;
    default: /* ISP_ADJ_FMT_MONO：帧长 w*h */
      for (px = 0; px < n; px++) {
        data[px] =
            (uint16_t)isp_adjust_bc_map(data[px], bs, base, gs, max_value);
      }
      return ISP_OK;
  }
}

int isp_adjust_color_balance(uint16_t *data, int w, int h,
                             IspAdjustFormat format, int max_value,
                             double cyan_red, double magenta_green,
                             double yellow_blue) {
  const int rc = isp_adjust_check(data, w, h, max_value);
  const size_t n = (size_t)w * (size_t)h;
  size_t px;
  if (rc != ISP_OK) return rc;
  if (format != ISP_ADJ_FMT_RGB && format != ISP_ADJ_FMT_YUV &&
      format != ISP_ADJ_FMT_HSL) {
    /* Dart default 分支抛 StateError（色彩平衡需要 RGB/YUV/HSL 输入）。 */
    return ISP_ERR_UNSUPPORTED;
  }
  if (cyan_red == 0 && magenta_green == 0 && yellow_blue == 0) {
    return ISP_OK; /* 三值全 0 直通不动数据 */
  }
  switch (format) {
    case ISP_ADJ_FMT_RGB: {
      /* Dart _colorBalanceRgb：偏移量 = 值/100 × maxValue，加性施加。 */
      const double dr = cyan_red / 100.0 * max_value;
      const double dg = magenta_green / 100.0 * max_value;
      const double db = yellow_blue / 100.0 * max_value;
      for (px = 0; px < n; px++) {
        uint16_t *const p = data + px * 3;
        const int r = p[0], g = p[1], b = p[2];
        /* 中间调权重：w = 1 − |2Y − 1|，Y 为 BT.601 归一化亮度。 */
        const double y = (0.299 * r + 0.587 * g + 0.114 * b) / max_value;
        const double wt = 1 - fabs(2 * y - 1);
        p[0] = (uint16_t)isp_adjust_clamp_to(r + dr * wt, max_value);
        p[1] = (uint16_t)isp_adjust_clamp_to(g + dg * wt, max_value);
        p[2] = (uint16_t)isp_adjust_clamp_to(b + db * wt, max_value);
      }
      return ISP_OK;
    }
    case ISP_ADJ_FMT_YUV: {
      /* Dart _colorBalanceYuv：k = maxValue/2/100（Dart / 为 double 除法，
       * 值 100 = 色度半量程）；青↔红 → V、黄↔蓝 → U、洋红↔绿 = −U−V 对角。 */
      const double k = (double)max_value / 2 / 100;
      const double du = yellow_blue * k;  /* U：正值偏蓝 */
      const double dv = cyan_red * k;     /* V：正值偏红 */
      const double dg = magenta_green * k; /* 洋红↔绿：绿 = −U−V */
      for (px = 0; px < n; px++) {
        uint16_t *const p = data + px * 3;
        const int y = p[0];
        /* 中间调权重直接取 Y 通道（不做 BT.601 加权和）。 */
        const double wt = 1 - fabs(2.0 * y / max_value - 1);
        /* Y 不变 */
        p[1] = (uint16_t)isp_adjust_clamp_to(p[1] + (du - dg) * wt, max_value);
        p[2] = (uint16_t)isp_adjust_clamp_to(p[2] + (dv - dg) * wt, max_value);
      }
      return ISP_OK;
    }
    default: { /* ISP_ADJ_FMT_HSL：按像素融合 HSL→RGB→偏移→HSL 往返 */
      const double dr = cyan_red / 100.0 * max_value;
      const double dg = magenta_green / 100.0 * max_value;
      const double db = yellow_blue / 100.0 * max_value;
      for (px = 0; px < n; px++) {
        uint16_t *const p = data + px * 3;
        uint16_t rgb[3];
        int r, g, b;
        double y, wt;
        /* 三段均为逐像素操作且无跨像素依赖；中间 RGB 先量化为整数
         * （与 Dart 整帧 hslToRgb 写出的 uint16 完全一致），再经
         * _colorBalanceRgb 与 rgbToHsl，整体与整帧往返逐位一致。 */
        isp_adjust_hsl_to_rgb_px(p, max_value, rgb);
        r = rgb[0];
        g = rgb[1];
        b = rgb[2];
        y = (0.299 * r + 0.587 * g + 0.114 * b) / max_value;
        wt = 1 - fabs(2 * y - 1);
        rgb[0] = (uint16_t)isp_adjust_clamp_to(r + dr * wt, max_value);
        rgb[1] = (uint16_t)isp_adjust_clamp_to(g + dg * wt, max_value);
        rgb[2] = (uint16_t)isp_adjust_clamp_to(b + db * wt, max_value);
        isp_adjust_rgb_to_hsl_px(rgb, max_value, p);
      }
      return ISP_OK;
    }
  }
}

int isp_adjust_build_gain_lut(double gain, int max_value,
                              uint16_t *lut_out) {
  int v;
  if (lut_out == NULL || max_value < 0) return ISP_ERR_ARG;
  /* 与 Dart adjustGainLut 逐位一致：isp_adjust_clamp_to 先比界再 round。 */
  for (v = 0; v <= max_value; v++) {
    lut_out[v] = (uint16_t)isp_adjust_clamp_to(v * gain, max_value);
  }
  return ISP_OK;
}

int isp_adjust_lut3_apply(const uint16_t *rgb, int w, int h, int max_value,
                          const uint16_t *lut_r, const uint16_t *lut_g,
                          const uint16_t *lut_b, uint16_t *out) {
  const int rc = isp_adjust_check(rgb, w, h, max_value);
  const size_t n = (size_t)w * (size_t)h;
  size_t px;
  if (rc != ISP_OK) return rc;
  if (out == NULL || lut_r == NULL || lut_g == NULL || lut_b == NULL) {
    return ISP_ERR_ARG;
  }
  for (px = 0; px < n; px++) {
    out[px * 3] = lut_r[rgb[px * 3]];
    out[px * 3 + 1] = lut_g[rgb[px * 3 + 1]];
    out[px * 3 + 2] = lut_b[rgb[px * 3 + 2]];
  }
  return ISP_OK;
}

int isp_adjust_bc_lut_apply(uint16_t *data, int w, int h,
                            IspAdjustFormat format, int max_value,
                            const uint16_t *adjust_lut) {
  const int rc = isp_adjust_check(data, w, h, max_value);
  const size_t n = (size_t)w * (size_t)h;
  size_t px;
  if (rc != ISP_OK) return rc;
  if (adjust_lut == NULL) return ISP_ERR_ARG;
  if (format != ISP_ADJ_FMT_RGB && format != ISP_ADJ_FMT_YUV &&
      format != ISP_ADJ_FMT_HSL && format != ISP_ADJ_FMT_MONO) {
    return ISP_ERR_UNSUPPORTED;
  }
  switch (format) {
    case ISP_ADJ_FMT_RGB:
      for (px = 0; px < n; px++) {
        uint16_t *const p = data + px * 3;
        const int r = p[0], g = p[1], b = p[2];
        /* BT.601 全范围亮度（double，不取整）。 */
        const double y = 0.299 * r + 0.587 * g + 0.114 * b;
        double ratio;
        if (y <= 0) continue; /* 纯黑像素保持 0 */
        /* Dart：ratio = adjust(y.round()) / y —— adjust 查表，除法保留。 */
        ratio = (double)adjust_lut[(int)round(y)] / y;
        p[0] = (uint16_t)isp_adjust_clamp_to(r * ratio, max_value);
        p[1] = (uint16_t)isp_adjust_clamp_to(g * ratio, max_value);
        p[2] = (uint16_t)isp_adjust_clamp_to(b * ratio, max_value);
      }
      return ISP_OK;
    case ISP_ADJ_FMT_YUV:
      for (px = 0; px < n; px++) {
        uint16_t *const p = data + px * 3;
        p[0] = adjust_lut[p[0]];
      }
      return ISP_OK;
    case ISP_ADJ_FMT_HSL:
      for (px = 0; px < n; px++) {
        uint16_t *const p = data + px * 3;
        p[2] = adjust_lut[p[2]];
      }
      return ISP_OK;
    default: /* ISP_ADJ_FMT_MONO */
      for (px = 0; px < n; px++) {
        data[px] = adjust_lut[data[px]];
      }
      return ISP_OK;
  }
}
