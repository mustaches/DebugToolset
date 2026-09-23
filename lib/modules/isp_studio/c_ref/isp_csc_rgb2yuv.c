/**
 * @file isp_csc_rgb2yuv.c
 * @brief ISP Studio C99 参考实现 —— RGB→YUV 色彩空间转换（声明与语义
 *        见 isp_csc_rgb2yuv.h 头注释；系数与工具见 isp_csc_common.h）。
 */

#include "isp_csc_rgb2yuv.h"

#include "isp_csc_common.h"

int isp_csc_rgb_to_yuv(const uint16_t *rgb, int w, int h, int max_value,
                       IspCscStandard standard, IspCscRange range,
                       uint16_t *out) {
  int rc = isp_csc_check(rgb, out, w, h, max_value);
  const size_t pixels = (size_t)w * (size_t)h;
  const int half = max_value >> 1;
  /* 系数默认 BT.601（Dart 中只有 standard == 'bt709' 才切换，其余一律 601） */
  int cyR = ISP_CSC_CY_R_601, cyG = ISP_CSC_CY_G_601, cyB = ISP_CSC_CY_B_601;
  int cuR = ISP_CSC_CU_R_601, cuG = ISP_CSC_CU_G_601, cuB = ISP_CSC_CU_B_601;
  int cvR = ISP_CSC_CV_R_601, cvG = ISP_CSC_CV_G_601, cvB = ISP_CSC_CV_B_601;
  const int limited = (range == ISP_CSC_RANGE_LIMITED);
  /* limited 亮度偏移：Dart (maxValue * 16 + 127) ~/ 255（截断除法） */
  const int off_y = (max_value * 16 + 127) / 255;
  size_t p, i;
  if (rc != ISP_OK) return rc;
  if (standard != ISP_CSC_BT601 && standard != ISP_CSC_BT709) return ISP_ERR_ARG;
  if (range != ISP_CSC_RANGE_FULL && range != ISP_CSC_RANGE_LIMITED) return ISP_ERR_ARG;
  if (standard == ISP_CSC_BT709) {
    cyR = ISP_CSC_CY_R_709; cyG = ISP_CSC_CY_G_709; cyB = ISP_CSC_CY_B_709;
    cuR = ISP_CSC_CU_R_709; cuG = ISP_CSC_CU_G_709;
    cvG = ISP_CSC_CV_G_709; cvB = ISP_CSC_CV_B_709;
    /* cuB / cvR 保持 601 的 32768，与 Dart 一致 */
  }
  /* Dart 中 standard != 'bt709' && range == 'full' 的快路径直接调用
   * rgbToYuv；此处系数默认 601 且 limited 关闭，同一循环数值逐位等价。 */
  for (p = 0, i = 0; p < pixels; p++, i += 3) {
    const int r = rgb[i];
    const int g = rgb[i + 1];
    const int b = rgb[i + 2];
    int y = (int)(((int64_t)cyR * r + (int64_t)cyG * g + (int64_t)cyB * b + 32768) >> 16);
    int u = (int)(((int64_t)cuR * r + (int64_t)cuG * g + (int64_t)cuB * b + 32768) >> 16) + half;
    int v = (int)(((int64_t)cvR * r + (int64_t)cvG * g + (int64_t)cvB * b + 32768) >> 16) + half;
    if (limited) {
      /* Y：offY + (y * 219 + 127) ~/ 255；U/V：去零点后按 224/255 压缩，
       * 四舍五入偏置按符号取 ±127，~/ 为截断除法（C `/` 同语义） */
      int d;
      y = off_y + (y * 219 + 127) / 255;
      d = u - half;
      u = half + (d * 224 + (d >= 0 ? 127 : -127)) / 255;
      d = v - half;
      v = half + (d * 224 + (d >= 0 ? 127 : -127)) / 255;
    }
    out[i] = isp_clamp_u16(y, max_value);
    out[i + 1] = isp_clamp_u16(u, max_value);
    out[i + 2] = isp_clamp_u16(v, max_value);
  }
  return ISP_OK;
}
