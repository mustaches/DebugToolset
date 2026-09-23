/**
 * @file isp_edge_extract.h
 * @brief ISP Studio C99 参考实现 —— 高频边缘提取节点（edge_extract）。
 *
 * 覆盖节点：edge_extract。
 * 对应 Dart 函数（lib/modules/isp_studio/pipeline/isp_kernels.dart）：
 * - extractHighFreq  亮度高通输出黑底白线边缘图：detail = Y − 3x3 盒式
 *                    模糊（与 applySharpen 同一 detail 定义），相对对比度
 *                    rel = |detail|/邻域均值（均值下限 maxValue/128 防除零），
 *                    rel < threshold/maxValue 置零（相对门限），输出 =
 *                    gain×√rel×maxValue 截位到 [0, maxValue]，按输入帧
 *                    色彩域（rgb/yuv/hsl）保持格式的黑底白线图。
 *
 * 规范要点速览见 isp_common.h 文件头注释（C99 子集、零 malloc、帧约定
 * uint16_t* + int w/h + int max_value、错误码、数值语义与 Dart 逐位一致）。
 */

#ifndef ISP_EDGE_EXTRACT_H
#define ISP_EDGE_EXTRACT_H

#include "isp_common.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief 输入帧色彩域（对应 Dart extractHighFreq 的 format 字符串参数）。
 *
 * 枚举值顺序与 Dart 的 'rgb'/'yuv'/'hsl' 分支一一对应；亮度通道取法：
 * RGB 域求 BT.601 定点亮度，YUV 域取 Y 通道（通道 0），HSL 域取 L 通道
 * （通道 2）。
 */
typedef enum IspEdgeExtractFormat {
  /** RGB 交织帧：亮度 = (19595R + 38470G + 7471B + 32768) >> 16。 */
  ISP_EDGE_EXTRACT_RGB = 0,
  /** YUV 交织帧：亮度 = 通道 0（Y）。 */
  ISP_EDGE_EXTRACT_YUV = 1,
  /** HSL 交织帧：亮度 = 通道 2（L）。 */
  ISP_EDGE_EXTRACT_HSL = 2
} IspEdgeExtractFormat;

/**
 * @brief edge_extract 所需 scratch 字节数。
 *
 * 布局：ys 亮度平面 w*h 个 uint16_t（先行全帧抽取，边缘检测循环内只读
 * ys、只写 out，输入帧保持 const 不被修改）。
 */
#define ISP_EDGE_EXTRACT_SCRATCH_BYTES(w, h) \
  ((size_t)(w) * (size_t)(h) * sizeof(uint16_t))

/**
 * @brief 高频边缘提取（节点 edge_extract）：输出黑底白线边缘图。
 *
 * Dart 来源：isp_kernels.dart `extractHighFreq`。
 * 处理流程（与 Dart 逐步对应）：
 * 1. 按 format 抽取亮度平面 ys（RGB 域 BT.601 定点 / YUV 取 Y / HSL 取 L）；
 * 2. 逐像素：detail = Y − 3x3 盒式均值（含中心、越界裁剪、double 除法）；
 * 3. 相对对比度 rel = |detail| / max(mean, maxValue/128)
 *    （均值下限防近黑区域除零爆增益；Dart 为 mean < meanFloor ? meanFloor
 *    : mean，等价于 max 但保持原式）；
 * 4. 相对门限：rel < threshold/maxValue 时 rel 置零；
 * 5. 输出码值 = _clampTo(gain×√rel×maxValue, maxValue)（四舍五入+钳位），
 *    √rel 显示压缩提亮弱边缘；
 * 6. 按 format 组装输出：rgb → 三通道同值；yuv → Y=v、U=V=maxValue>>1
 *    （中灰）；hsl → H=0、S=0、L=v。
 *
 * @param data      输入交织帧（w*h*3 个 uint16_t），只读不修改。
 * @param out       输出交织帧（w*h*3 个 uint16_t），调用方提供；
 *                  允许与 data 相同（ys 已先行快照，逐像素写出安全）。
 * @param width     帧宽（> 0）。
 * @param height    帧高（> 0）。
 * @param format    输入帧色彩域。
 * @param gain      输出增益。
 * @param threshold 相对门限（满量程码值量纲，内部除以 maxValue）。
 * @param max_value 采样最大值（1..65535）。
 * @param scratch   临时缓冲，至少 ISP_EDGE_EXTRACT_SCRATCH_BYTES(width, height)。
 * @return ISP_OK 成功；ISP_ERR_ARG 空指针、format 或 max_value 非法；
 *         ISP_ERR_SIZE 宽高 <= 0。
 */
int isp_edge_extract_run(const uint16_t *data, uint16_t *out, int width,
                         int height, IspEdgeExtractFormat format, double gain,
                         double threshold, int max_value, uint16_t *scratch);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* ISP_EDGE_EXTRACT_H */
