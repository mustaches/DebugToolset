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

/// 端口圆点半径。
const double kPortRadius = 5;

/// 节点总高度：标题 + 端口行 + 类型附加区 + 底部留白。
/// [previewExtraHeight] 对 preview 与仪器节点生效（可拖动调整的附加区高度）。
double nodeHeight(IspNodeType type, {double previewExtraHeight = 160}) {
  final rows = math.max(type.inputs.length, type.outputs.length);
  var h = kNodeTitleHeight + rows * kPortRowHeight + 8;
  if (type.typeId == 'preview' || instrumentTypes.contains(type.typeId)) {
    h += previewExtraHeight;
  }
  if (type.typeId == 'image_output' || type.typeId == 'video_output') {
    h += 34; // 导出按钮行
  }
  return h;
}

/// 端口行中心 y（画布坐标，未缩放）。
double _portRowCenterY(IspNode node, int index) {
  return node.y + kNodeTitleHeight + 4 + index * kPortRowHeight + kPortRowHeight / 2;
}

/// 输入端口圆心（画布坐标，未缩放），位于节点左边缘。
Offset inputPortPos(IspNode node, IspNodeType type, int index) {
  return Offset(node.x, _portRowCenterY(node, index));
}

/// 输出端口圆心（画布坐标，未缩放），位于节点右边缘。
Offset outputPortPos(IspNode node, IspNodeType type, int index) {
  return Offset(node.x + node.width, _portRowCenterY(node, index));
}

/// 端口颜色：bayer 橙，rgb 绿，yuv 蓝，hsl 粉。
Color portColor(IspPortType type) {
  return switch (type) {
    IspPortType.bayer => const Color(0xFFE0A050),
    IspPortType.rgb => const Color(0xFF50C080),
    IspPortType.yuv => const Color(0xFF5078C0),
    IspPortType.hsl => const Color(0xFFC05078),
    IspPortType.audio => const Color(0xFF9E8ED0),
  };
}
