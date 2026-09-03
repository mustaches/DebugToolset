/// ISP Studio 节点编辑器共享布局常量与几何计算。
/// 节点卡片与连线绘制必须从这里取尺寸，保证两者一致。
library;

import 'dart:math' as math;
import 'dart:ui' show Color, Offset;

import '../models/isp_node.dart';

/// 标题栏高度。
const double kNodeTitleHeight = 30;

/// 每个端口行的高度。
const double kPortRowHeight = 22;

/// 端口分组间隔行：typeId → 需要在其**前面**插入一行（kPortRowHeight）
/// 间隔的端口行索引。节点高度、端口几何与视觉行三处共用此表，必须
/// 保持一致（混叠器：蒙版/混叠图与基图四端口分组显示）。
const Map<String, List<int>> kPortGroupGapRows = {
  'blender': [4, 5],
  'psnr': [4], // 参考图/测试图两组输入之间
  'ssim': [4], // 同 PSNR：参考/测试两组输入之间
  'msssim': [4], // 同 PSNR：参考/测试两组输入之间
  'fsim': [4], // 同 PSNR：参考/测试两组输入之间
  'lpips': [4], // 同 PSNR：参考/测试两组输入之间
  'dists': [4], // 同 PSNR：参考/测试两组输入之间
  'fid': [4], // 同 PSNR：参考/测试两组输入之间
  'kid': [4], // 同 PSNR：参考/测试两组输入之间
  'mux4': [4, 8, 12], // 源1/源2/源3/源4 四组输入之间
};

/// 端口圆点半径。
const double kPortRadius = 5;

/// 节点总高度：标题 + 端口行 + 类型附加区 + 底部留白。
/// [previewExtraHeight] 对 preview、调节器（HSL/RGB/YUV、色饱和度/亮度、
/// 亮度/对比度、色彩平衡、色温）、高频边缘提取、曲线调节器与仪器节点
/// 生效（可拖动调整的附加区高度）。
double nodeHeight(IspNodeType type, {double previewExtraHeight = 160}) {
  final rows = math.max(type.inputs.length, type.outputs.length);
  var h = kNodeTitleHeight + rows * kPortRowHeight + 8;
  // 端口分组间隔行（如混叠器的基图/蒙版/混叠图分组）。
  h += (kPortGroupGapRows[type.typeId]?.length ?? 0) * kPortRowHeight;
  if (type.typeId == 'preview' ||
      type.typeId == 'hsl_debugger' ||
      type.typeId == 'rgb_debugger' ||
      type.typeId == 'yuv_debugger' ||
      type.typeId == 'sat_bright_adjuster' ||
      type.typeId == 'bright_contrast_adjuster' ||
      type.typeId == 'gaussian_blur' ||
      type.typeId == 'color_balance' ||
      type.typeId == 'color_temp_adjuster' ||
      type.typeId == 'edge_extract' ||
      type.typeId == 'levels_curves' ||
      allInstrumentTypes.contains(type.typeId)) {
    h += previewExtraHeight;
  }
  if (type.typeId == 'multiplier') {
    h += 48; // 源1/源2 偏移步进行（2 × 24）
  }
  if (type.typeId == 'adder') {
    h += 38; // 平衡值显示行（14）+ 平衡控制条行（24）
  }
  if (type.typeId == 'mux4') {
    h += 24; // 源1~源4 单选开关行
  }
  if (type.typeId == 'image_output' || type.typeId == 'video_output') {
    h += 34; // 导出按钮行
  }
  return h;
}

/// 端口行中心 y（画布坐标，未缩放）。分组间隔行（kPortGroupGapRows）
/// 会把它之后的端口整体下移。
double _portRowCenterY(IspNode node, int index) {
  final gaps = kPortGroupGapRows[node.typeId] ?? const <int>[];
  final gapCount = gaps.where((g) => g <= index).length;
  return node.y +
      kNodeTitleHeight +
      4 +
      (index + gapCount) * kPortRowHeight +
      kPortRowHeight / 2;
}

/// 输入端口圆心（画布坐标，未缩放），位于节点左边缘。
Offset inputPortPos(IspNode node, IspNodeType type, int index) {
  return Offset(node.x, _portRowCenterY(node, index));
}

/// 输出端口圆心（画布坐标，未缩放），位于节点右边缘。
Offset outputPortPos(IspNode node, IspNodeType type, int index) {
  return Offset(node.x + node.width, _portRowCenterY(node, index));
}

/// 端口颜色：bayer 橙，rgb 绿，yuv 蓝，hsl 粉，audio 紫，单通道各色。
Color portColor(IspPortType type) {
  return switch (type) {
    IspPortType.bayer => const Color(0xFFE0A050),
    IspPortType.rgb => const Color(0xFF50C080),
    IspPortType.yuv => const Color(0xFF5078C0),
    IspPortType.hsl => const Color(0xFFC05078),
    IspPortType.audio => const Color(0xFF9E8ED0),
    IspPortType.r => const Color(0xFFE55353),
    IspPortType.g => const Color(0xFF53E553),
    IspPortType.b => const Color(0xFF5383E5),
    IspPortType.y => const Color(0xFFE5E553),
    IspPortType.u => const Color(0xFF53E5E5),
    IspPortType.v => const Color(0xFFE553E5),
    IspPortType.h => const Color(0xFFE58053),
    IspPortType.s => const Color(0xFFB553E5),
    IspPortType.l => const Color(0xFFD0D8E8),
    IspPortType.mono => const Color(0xFF50A0B0),
  };
}
