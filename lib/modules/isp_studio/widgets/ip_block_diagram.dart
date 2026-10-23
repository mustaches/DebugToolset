/// RTL 网表共享的画布配色与缩放适配工具。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 电路图画布配色（Vivado 浅色 / 暗色两套）。
class SchPalette {
  final Color canvasBg;
  final Color blockFill;
  final Color blockBorder;
  final Color instanceText;
  final Color moduleText;
  final Color pinText;

  /// 针脚图形色（针脚短线、边缘点、容器针脚连接短线；null = 跟随 blockBorder）。
  final Color? pinStroke;
  final Color portFill;
  final Color portBorder;
  final Color portText;

  /// 输出端口填充（与输入区分；网表图用）。
  final Color portFillOut;

  /// 双向端口填充（inout；网表图用）。
  final Color portFillInout;
  final Color wire;
  final Color wireBus;
  final Color wireDim;
  final Color netLabel;

  /// 常量引脚标记色（网表图用：`1'b0`/`8'h00` 等常量引脚的方块与文本）。
  final Color cellConst;

  /// 悬停高亮色（块边框 / 相连连线）。
  final Color hover;

  /// 绘图文字字体族（null = 平台默认；位图导出/主题定制可指定）。
  final String? fontFamily;

  const SchPalette({
    required this.canvasBg,
    required this.blockFill,
    required this.blockBorder,
    required this.instanceText,
    required this.moduleText,
    required this.pinText,
    this.pinStroke,
    required this.portFill,
    required this.portBorder,
    required this.portText,
    this.portFillOut = const Color(0xFFFFF3E0),
    this.portFillInout = const Color(0xFFF3E5F5),
    required this.wire,
    required this.wireBus,
    required this.wireDim,
    required this.netLabel,
    required this.hover,
    this.cellConst = const Color(0xFF8A6D3B),
    this.fontFamily,
  });

  /// 针脚图形实际用色（未指定时跟随 blockBorder）。
  Color get pinStrokeOrBorder => pinStroke ?? blockBorder;

  /// 复制并指定字体族（绘图文字用）。
  SchPalette withFontFamily(String? family) => SchPalette(
    canvasBg: canvasBg,
    blockFill: blockFill,
    blockBorder: blockBorder,
    instanceText: instanceText,
    moduleText: moduleText,
    pinText: pinText,
    pinStroke: pinStroke,
    portFill: portFill,
    portBorder: portBorder,
    portText: portText,
    portFillOut: portFillOut,
    portFillInout: portFillInout,
    wire: wire,
    wireBus: wireBus,
    wireDim: wireDim,
    netLabel: netLabel,
    hover: hover,
    cellConst: cellConst,
    fontFamily: family,
  );

  /// Vivado Elaborated Design 浅色（可通过工具栏切换）。
  static const vivadoLight = SchPalette(
    canvasBg: Color(0xFFFFFFFF),
    blockFill: Color(0xFFDCE7F5),
    blockBorder: Color(0xFF6E8CAE),
    instanceText: Color(0xFF10233A),
    moduleText: Color(0xFF3C4A5A),
    pinText: Color(0xFF000000),
    pinStroke: Color(0xFF000000),
    portFill: Color(0xFFFFFFFF),
    portBorder: Color(0xFF4A6B8A),
    portText: Color(0xFF10233A),
    portFillOut: Color(0xFFFFF3E0),
    portFillInout: Color(0xFFF3E5F5),
    wire: Color(0xFF14651A),
    wireBus: Color(0xFF1F4E79),
    wireDim: Color(0xFFAFC9B1),
    netLabel: Color(0xFF2A2A2A),
    hover: Color(0xFFFFD600),
  );

  /// 暗色（与应用暗色主题一致）。
  static const dark = SchPalette(
    canvasBg: Color(0xFF1E1E1E),
    blockFill: Color(0xFF252526),
    blockBorder: Color(0xFFFFFFFF),
    instanceText: Color(0xFFFFFFFF),
    moduleText: Color(0xFFFFFFFF),
    pinText: Color(0xFFFFFFFF),
    portFill: Color(0xFF1B2A28),
    portBorder: Color(0xFFFFFFFF),
    portText: Color(0xFFFFFFFF),
    portFillOut: Color(0xFF2A2418),
    portFillInout: Color(0xFF2A2036),
    wire: Color(0xFF4CAF50),
    wireBus: Color(0xFF00BFFF),
    wireDim: Color(0xFF2E5A34),
    netLabel: Color(0xFF9CCC9C),
    cellConst: Color(0xFFFFFFFF),
    hover: Color(0xFFFFD600),
  );
}

void schFitView(
  TransformationController ctrl,
  Size viewport,
  Size content, {
  double maxScale = 2.0,
  double minScale = 0.05,
}) {
  if (viewport.isEmpty || content.isEmpty) return;
  var s = math.min(
    viewport.width / content.width,
    viewport.height / content.height,
  );
  final double tx, ty;
  if (s < minScale) {
    if (content.height / content.width > viewport.height / viewport.width) {
      // 超高内容：按宽适配 + 顶对齐。
      s = (viewport.width / content.width).clamp(minScale, maxScale);
      tx = (viewport.width - content.width * s) / 2;
      ty = 12.0;
    } else {
      // 超宽内容：按高适配 + 左对齐。
      s = (viewport.height / content.height).clamp(minScale, maxScale);
      tx = 12.0;
      ty = (viewport.height - content.height * s) / 2;
    }
  } else {
    s = s.clamp(minScale, maxScale);
    tx = (viewport.width - content.width * s) / 2;
    ty = (viewport.height - content.height * s) / 2;
  }
  // z 轴同步缩放：Matrix4.getMaxScaleOnAxis 取三轴最大值，z 恒为 1 时
  // 会把 0.5 的 2D 缩放读成 1.0（InteractiveViewer 的 min/max 缩放钳制
  // 与工具栏缩放步进都依赖它）。
  ctrl.value = Matrix4.identity()
    ..translateByDouble(tx, ty, 0, 1)
    ..scaleByDouble(s, s, s, 1);
}
