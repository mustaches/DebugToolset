/**
 * @file isp_csc_sse.h
 * @brief RGB↔HSL 双像素 SSE2 快路径（仅内部使用：main_win.c 装帧/解包与
 *        对拍 harness 包含本头；全部为宏与 static inline 定义，无独立编译
 *        单元）。
 *
 * 背景：HSL 端口编组的 Win32 验证程序每帧要做整帧 RGB→HSL（装帧）与
 * HSL→RGB（解包显示）逐像素 FP64 转换，4K 单线程实测 ~195/~245ms、
 * OpenMP 16 线程 ~15/~17ms，合计 30ms+/帧，是播放帧率被压到 ~23fps 的
 * 瓶颈（4K 纯内存搬运口径仅 ~1ms，全为 FP64 除法/分支开销）。
 *
 * 数值一致性：SSE2 的 mul/div/add/sub 与标量同为 IEEE 正确舍入，逐车道
 * 与 isp_csc_rgb_to_hsl_px / isp_csc_hsl_to_rgb_px 的对应运算逐位一致；
 * 标量的数据相关分支全部改为双分支都算 + 掩码选择（blend），被丢弃车道
 * 的值不参与结果。d=0 车道多算的无意义除法（0/0=NaN 等）最终恒被
 * 掩码剔除，与标量「不进入分支」结果一致。逐位等价经全量对拍验证
 *（256^3 全输入域 @ max_value=255 + LCG 抽样 @ 1023/4095/65535，见
 * test/c_ref/harness_csc.c 的 csc_sse_selfcheck 与
 * test/isp_csc_sse_test.dart）。
 *
 * 非 SSE2 平台（ARM 交叉编译等）自动回退为两次标量调用，语义不变。
 */

#ifndef ISP_CSC_SSE_H
#define ISP_CSC_SSE_H

#include "isp_csc_common.h"

#if defined(_M_X64) || defined(_M_AMD64) || defined(__x86_64__) ||           \
    defined(__SSE2__) || (defined(_M_IX86_FP) && _M_IX86_FP >= 2)
#define ISP_CSC_SSE2 1
#else
#define ISP_CSC_SSE2 0
#endif

#if ISP_CSC_SSE2
#include <emmintrin.h>

/**
 * @brief Dart `_clampTo` 等价（双车道）：v < 0 ? 0 :
 *        (v > max ? max : trunc(v + 0.5))。
 *
 * 与 isp_csc_clamp_d 逐位一致：界内仅做 (int64)(v+0.5) 的截断取整
 *（cvttpd 同为向零截断）；越界车道在转整前已被替换为 maxd/+0.0，故
 * cvttpd 不会看到溢出值。返回 __m128i 的低两个 int32 车道。
 */
static inline __m128i isp_csc_clamp2(__m128d v, __m128d maxd) {
  const __m128d mgt = _mm_cmpgt_pd(v, maxd);
  __m128d pre = _mm_add_pd(v, _mm_set1_pd(0.5));
  pre = _mm_or_pd(_mm_and_pd(mgt, maxd), _mm_andnot_pd(mgt, pre));
  pre = _mm_andnot_pd(_mm_cmplt_pd(v, _mm_setzero_pd()), pre);
  return _mm_cvttpd_epi32(pre);
}

/** @brief hue_to_rgb 双车道等价（分段阈值比较→掩码选择，运算结合序不变）。 */
static inline __m128d isp_csc_hue2(__m128d p, __m128d q, __m128d t) {
  const __m128d one = _mm_set1_pd(1.0);
  const __m128d six = _mm_set1_pd(6.0);
  const __m128d c16 = _mm_set1_pd(1.0 / 6.0);
  const __m128d c23 = _mm_set1_pd(2.0 / 3.0);
  __m128d tt = _mm_add_pd(t, _mm_and_pd(_mm_cmplt_pd(t, _mm_setzero_pd()), one));
  tt = _mm_sub_pd(tt, _mm_and_pd(_mm_cmpgt_pd(tt, one), one));
  const __m128d qp = _mm_sub_pd(q, p);
  const __m128d c1 = _mm_add_pd(p, _mm_mul_pd(_mm_mul_pd(qp, six), tt));
  const __m128d c3 =
      _mm_add_pd(p, _mm_mul_pd(_mm_mul_pd(qp, _mm_sub_pd(c23, tt)), six));
  const __m128d m16 = _mm_cmplt_pd(tt, c16);
  const __m128d m12 = _mm_cmplt_pd(tt, _mm_set1_pd(1.0 / 2.0));
  const __m128d m23 = _mm_cmplt_pd(tt, c23);
  __m128d r = _mm_or_pd(_mm_and_pd(m23, c3), _mm_andnot_pd(m23, p));
  r = _mm_or_pd(_mm_and_pd(m12, q), _mm_andnot_pd(m12, r));
  r = _mm_or_pd(_mm_and_pd(m16, c1), _mm_andnot_pd(m16, r));
  return r;
}
#endif /* ISP_CSC_SSE2 */

#if ISP_CSC_SSE2
/**
 * @brief nv12 → r/g/b 平面字节（BT.709 限幅 Q8 定点），一次 8 像素。
 *
 * 与 main_win.c 标量（pack_fused_nv12 / nv12_to_rgb709 同式）逐位一致：
 * madd 的 int32 累加与标量 int 算术精确相同；+128 后 _mm_srai_epi32 算术
 * 右移 8 同标量 `>> 8`；_mm_packus_epi16 的 0..255 无符号饱和与标量
 * 三元钳位逐值一致（中间值域 [-248, 506]，packs_epi32 有符号饱和不触发）。
 *
 * @param yp   8 个亮度字节（y0..y7）。
 * @param uvp  nv12 交织色度 8 字节（U0 V0 U1 V1 U2 V2 U3 V3，对应 4 个
 *             像素对）；调用方保证 yp/uvp 对齐同一行内偶数列。
 * @param r8/g8/b8  输出各 8 字节平面通道（已钳位 0..255）。
 */
static inline void isp_csc_nv12_rgb8(const unsigned char *yp,
                                     const unsigned char *uvp,
                                     unsigned char *r8, unsigned char *g8,
                                     unsigned char *b8) {
  const __m128i y16 = _mm_sub_epi16(
      _mm_unpacklo_epi8(_mm_loadl_epi64((const __m128i *)yp),
                        _mm_setzero_si128()),
      _mm_set1_epi16(16));
  const __m128i uv16 = _mm_unpacklo_epi8(
      _mm_loadl_epi64((const __m128i *)uvp), _mm_setzero_si128());
  /* 解交织并成对复制：u = [U0 U0 U1 U1 ...]，v 同理（各 -128） */
  const __m128i ut = _mm_and_si128(uv16, _mm_set1_epi32(0x0000FFFF));
  const __m128i vt = _mm_srli_epi32(uv16, 16);
  const __m128i u16 = _mm_sub_epi16(
      _mm_or_si128(ut, _mm_slli_epi32(ut, 16)), _mm_set1_epi16(128));
  const __m128i v16 = _mm_sub_epi16(
      _mm_or_si128(vt, _mm_slli_epi32(vt, 16)), _mm_set1_epi16(128));
  const __m128i yv_lo = _mm_unpacklo_epi16(y16, v16);
  const __m128i yv_hi = _mm_unpackhi_epi16(y16, v16);
  const __m128i yu_lo = _mm_unpacklo_epi16(y16, u16);
  const __m128i yu_hi = _mm_unpackhi_epi16(y16, u16);
  const __m128i c128 = _mm_set1_epi32(128);
  /* r = (298*yy + 459*v + 128) >> 8 */
  __m128i r_lo = _mm_madd_epi16(yv_lo, _mm_set1_epi32((459 << 16) | 298));
  __m128i r_hi = _mm_madd_epi16(yv_hi, _mm_set1_epi32((459 << 16) | 298));
  /* g = (298*yy - 55*u - 136*v + 128) >> 8 */
  __m128i g_lo = _mm_add_epi32(
      _mm_madd_epi16(yu_lo, _mm_set1_epi32((int)0xFFC9012A /* [-55, 298] */)),
      _mm_madd_epi16(yv_lo, _mm_set1_epi32((int)0xFF780000 /* [-136, 0] */)));
  __m128i g_hi = _mm_add_epi32(
      _mm_madd_epi16(yu_hi, _mm_set1_epi32((int)0xFFC9012A)),
      _mm_madd_epi16(yv_hi, _mm_set1_epi32((int)0xFF780000)));
  /* b = (298*yy + 541*u + 128) >> 8 */
  __m128i b_lo = _mm_madd_epi16(yu_lo, _mm_set1_epi32((541 << 16) | 298));
  __m128i b_hi = _mm_madd_epi16(yu_hi, _mm_set1_epi32((541 << 16) | 298));
  r_lo = _mm_srai_epi32(_mm_add_epi32(r_lo, c128), 8);
  r_hi = _mm_srai_epi32(_mm_add_epi32(r_hi, c128), 8);
  g_lo = _mm_srai_epi32(_mm_add_epi32(g_lo, c128), 8);
  g_hi = _mm_srai_epi32(_mm_add_epi32(g_hi, c128), 8);
  b_lo = _mm_srai_epi32(_mm_add_epi32(b_lo, c128), 8);
  b_hi = _mm_srai_epi32(_mm_add_epi32(b_hi, c128), 8);
  _mm_storel_epi64(
      (__m128i *)r8,
      _mm_packus_epi16(_mm_packs_epi32(r_lo, r_hi), _mm_setzero_si128()));
  _mm_storel_epi64(
      (__m128i *)g8,
      _mm_packus_epi16(_mm_packs_epi32(g_lo, g_hi), _mm_setzero_si128()));
  _mm_storel_epi64(
      (__m128i *)b8,
      _mm_packus_epi16(_mm_packs_epi32(b_lo, b_hi), _mm_setzero_si128()));
}
#endif /* ISP_CSC_SSE2 */

/**
 * @brief 双像素 RGB→HSL：与两次 isp_csc_rgb_to_hsl_px 逐位一致。
 *
 * @param r0/g0/b0/r1/g1/b1 已钳位到 [0, max_value] 的 RGB 整数。
 * @param inv               1.0 / max_value。
 * @param out               输出 H/S/L ×2（uint16_t[6]）。
 */
static inline void isp_csc_rgb2_to_hsl6(int r0, int g0, int b0, int r1, int g1,
                                        int b1, int max_value, double inv,
                                        uint16_t *out) {
#if ISP_CSC_SSE2
  const __m128d zero = _mm_setzero_pd();
  const __m128d one = _mm_set1_pd(1.0);
  const __m128d two = _mm_set1_pd(2.0);
  const __m128d six = _mm_set1_pd(6.0);
  const __m128d half = _mm_set1_pd(0.5);
  const __m128d invv = _mm_set1_pd(inv);
  const __m128d maxd = _mm_set1_pd((double)max_value);
  const __m128d r =
      _mm_mul_pd(_mm_cvtepi32_pd(_mm_set_epi32(0, 0, r1, r0)), invv);
  const __m128d g =
      _mm_mul_pd(_mm_cvtepi32_pd(_mm_set_epi32(0, 0, g1, g0)), invv);
  const __m128d b =
      _mm_mul_pd(_mm_cvtepi32_pd(_mm_set_epi32(0, 0, b1, b0)), invv);
  /* 与标量比较链同值：max/max(g,b) 再对 r 取 max（无 NaN，等值结果相同） */
  const __m128d mx = _mm_max_pd(r, _mm_max_pd(g, b));
  const __m128d mn = _mm_min_pd(r, _mm_min_pd(g, b));
  const __m128d l = _mm_mul_pd(_mm_add_pd(mx, mn), half);
  const __m128d d = _mm_sub_pd(mx, mn);
  const __m128d dpos = _mm_cmpgt_pd(d, zero);
  const __m128d eq_r = _mm_cmpeq_pd(mx, r);
  const __m128d eq_g = _mm_cmpeq_pd(mx, g);
  /* s：分母先按车道选择再做单除法——l > 0.5 ? d/(2.0-mx-mn) : d/(mx+mn)。
   * IEEE 除法结果唯一确定于（被除数, 除数），「混合分母后单除」与「双除
   * 后掩码选择」逐位一致，省一路 divpd；d=0 车道的 0/0 随后屏蔽。 */
  const __m128d lgt = _mm_cmpgt_pd(l, half);
  const __m128d den = _mm_or_pd(
      _mm_and_pd(lgt, _mm_sub_pd(_mm_sub_pd(two, mx), mn)),
      _mm_andnot_pd(lgt, _mm_add_pd(mx, mn)));
  const __m128d s = _mm_and_pd(dpos, _mm_div_pd(d, den));
  /* h：分子同理先选择（eq_r → g-b；eq_g → b-r；否则 r-g）再单除 d；
   * 加常数 eq_r → t<0?6:0、eq_g → 2、否则 4，与标量分支逐位一致。 */
  const __m128d num = _mm_or_pd(
      _mm_and_pd(eq_r, _mm_sub_pd(g, b)),
      _mm_andnot_pd(eq_r, _mm_or_pd(_mm_and_pd(eq_g, _mm_sub_pd(b, r)),
                                    _mm_andnot_pd(eq_g, _mm_sub_pd(r, g)))));
  const __m128d t = _mm_div_pd(num, d);
  const __m128d off = _mm_or_pd(
      _mm_and_pd(eq_r, _mm_and_pd(_mm_cmplt_pd(t, zero), six)),
      _mm_andnot_pd(eq_r,
                    _mm_or_pd(_mm_and_pd(eq_g, two),
                              _mm_andnot_pd(eq_g, _mm_set1_pd(4.0)))));
  __m128d h = _mm_div_pd(_mm_add_pd(t, off), six);
  h = _mm_add_pd(h, _mm_and_pd(_mm_cmplt_pd(h, zero), one));
  h = _mm_and_pd(dpos, h);
  {
    const __m128i hi = isp_csc_clamp2(_mm_mul_pd(h, maxd), maxd);
    const __m128i si = isp_csc_clamp2(_mm_mul_pd(s, maxd), maxd);
    const __m128i li = isp_csc_clamp2(_mm_mul_pd(l, maxd), maxd);
    out[0] = (uint16_t)_mm_cvtsi128_si32(hi);
    out[1] = (uint16_t)_mm_cvtsi128_si32(si);
    out[2] = (uint16_t)_mm_cvtsi128_si32(li);
    out[3] = (uint16_t)_mm_cvtsi128_si32(_mm_srli_si128(hi, 4));
    out[4] = (uint16_t)_mm_cvtsi128_si32(_mm_srli_si128(si, 4));
    out[5] = (uint16_t)_mm_cvtsi128_si32(_mm_srli_si128(li, 4));
  }
#else
  isp_csc_rgb_to_hsl_px(r0, g0, b0, max_value, inv, out);
  isp_csc_rgb_to_hsl_px(r1, g1, b1, max_value, inv, out + 3);
#endif
}

/**
 * @brief 双像素 HSL→RGB：与两次 isp_csc_hsl_to_rgb_px 逐位一致。
 *
 * @param h0/s0/l0/h1/s1/l1 输入 H/S/L 原始采样值（同标量，不做输入钳位）。
 * @param inv               1.0 / max_value。
 * @param out               输出 R/G/B ×2 整数（int[6]，∈ [0, max_value]）。
 */
static inline void isp_csc_hsl2_to_rgb6(int h0, int s0, int l0, int h1, int s1,
                                        int l1, int max_value, double inv,
                                        int *out) {
#if ISP_CSC_SSE2
  const __m128d zero = _mm_setzero_pd();
  const __m128d one = _mm_set1_pd(1.0);
  const __m128d half = _mm_set1_pd(0.5);
  const __m128d invv = _mm_set1_pd(inv);
  const __m128d maxd = _mm_set1_pd((double)max_value);
  const __m128d third = _mm_set1_pd(1.0 / 3.0);
  __m128d h, s, l, q, p, rr, gg, bb, s0m;
  __m128i ri, gi, bi;
  /* hv*inv >= 2.0 的欧几里得取模慢路径（异常输入，应用内恒不触发）：
   * 整对回退标量，保持 fmod 口径。 */
  if (h0 >= 2 * max_value || h1 >= 2 * max_value) {
    isp_csc_hsl_to_rgb_px(h0, s0, l0, max_value, inv, out, out + 1, out + 2);
    isp_csc_hsl_to_rgb_px(h1, s1, l1, max_value, inv, out + 3, out + 4,
                          out + 5);
    return;
  }
  h = _mm_mul_pd(_mm_cvtepi32_pd(_mm_set_epi32(0, 0, h1, h0)), invv);
  /* h >= 1.0 → h - 1.0（h < 2.0 由上方保证；Sterbenz 引理减法精确） */
  h = _mm_sub_pd(h, _mm_and_pd(_mm_cmpge_pd(h, one), one));
  s = _mm_mul_pd(_mm_cvtepi32_pd(_mm_set_epi32(0, 0, s1, s0)), invv);
  l = _mm_mul_pd(_mm_cvtepi32_pd(_mm_set_epi32(0, 0, l1, l0)), invv);
  s0m = _mm_cmpeq_pd(s, zero);
  /* q：l < 0.5 ? l*(1+s) : l+s-l*s（结合序同标量） */
  {
    const __m128d q_a = _mm_mul_pd(l, _mm_add_pd(one, s));
    const __m128d q_b = _mm_sub_pd(_mm_add_pd(l, s), _mm_mul_pd(l, s));
    const __m128d llt = _mm_cmplt_pd(l, half);
    q = _mm_or_pd(_mm_and_pd(llt, q_a), _mm_andnot_pd(llt, q_b));
  }
  p = _mm_sub_pd(_mm_mul_pd(_mm_set1_pd(2.0), l), q);
  rr = isp_csc_hue2(p, q, _mm_add_pd(h, third));
  gg = isp_csc_hue2(p, q, h);
  bb = isp_csc_hue2(p, q, _mm_sub_pd(h, third));
  /* s == 0 → r=g=b=l */
  rr = _mm_or_pd(_mm_and_pd(s0m, l), _mm_andnot_pd(s0m, rr));
  gg = _mm_or_pd(_mm_and_pd(s0m, l), _mm_andnot_pd(s0m, gg));
  bb = _mm_or_pd(_mm_and_pd(s0m, l), _mm_andnot_pd(s0m, bb));
  ri = isp_csc_clamp2(_mm_mul_pd(rr, maxd), maxd);
  gi = isp_csc_clamp2(_mm_mul_pd(gg, maxd), maxd);
  bi = isp_csc_clamp2(_mm_mul_pd(bb, maxd), maxd);
  out[0] = _mm_cvtsi128_si32(ri);
  out[1] = _mm_cvtsi128_si32(gi);
  out[2] = _mm_cvtsi128_si32(bi);
  out[3] = _mm_cvtsi128_si32(_mm_srli_si128(ri, 4));
  out[4] = _mm_cvtsi128_si32(_mm_srli_si128(gi, 4));
  out[5] = _mm_cvtsi128_si32(_mm_srli_si128(bi, 4));
#else
  isp_csc_hsl_to_rgb_px(h0, s0, l0, max_value, inv, out, out + 1, out + 2);
  isp_csc_hsl_to_rgb_px(h1, s1, l1, max_value, inv, out + 3, out + 4, out + 5);
#endif
}

#endif /* ISP_CSC_SSE_H */
