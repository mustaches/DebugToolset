/// 自研电路图 SVG 导出：由 [NetlistDiagramModel]（同一布局模型，所见即
/// 所得）生成纯 SVG 文本——**不依赖 netlistsvg/ELK**，也不使用 `<style>`
/// 块（flutter_svg / vector_graphics 不支持样式块），全部用呈现属性。
///
/// 「导出PNG」经 [rasterizeSvgPng] 复用本产物栅格化，两种载体同一口径。
library;

import 'dart:ui' show Color, Offset, Rect, Size;

import '../widgets/ip_block_diagram.dart' show SchPalette;
import 'netlist_model.dart';
import 'netlist_symbols.dart';
import '../widgets/netlist_diagram.dart';

/// 生成电路图 SVG。坐标与画布尺寸与页内视图完全一致（1:1 同坐标）。
///
/// 连线与页内 RTL 视图同口径：每网按 [topology] 画直线（团=全对、星形=
/// 到质心），不做正交布线。
String buildNetlistSvg(
  NetlistDiagramModel model, {
  SchPalette palette = SchPalette.dark,
  String? fontFamily,
  NlNetTopology topology = NlNetTopology.clique,
  String? diagnosticOverlay,
  Map<NlWire, List<(Offset, Offset)>>? autoRoutes,
  Map<NlWire, List<Offset>>? autoJunctions,
}) {
  final w = model.canvasSize.width;
  final h = model.canvasSize.height;
  final font = fontFamily ?? 'monospace';
  final b = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln(
      '<svg xmlns="http://www.w3.org/2000/svg" '
      'width="${_n(w)}" height="${_n(h)}" '
      'viewBox="0 0 ${_n(w)} ${_n(h)}">',
    )
    ..writeln(
      '  <rect x="0" y="0" width="${_n(w)}" height="${_n(h)}" '
      'fill="${_c(palette.canvasBg)}"/>',
    );

  // ---- 针脚自身短线（pinStroke，未指定时跟随块边框色；对应网只画到外部节点 pos，不进入 edge）----
  // 单信号 0.5dp；总线针脚加粗到 2dp。
  for (final (bus, width) in [(false, '0.5'), (true, '2.0')]) {
    b.writeln(
      '  <g stroke="${_c(palette.pinStrokeOrBorder)}" stroke-width="$width">',
    );
    for (final blk in model.blocks) {
      if (blk.isIo) continue;
      for (final p in [...blk.ins, ...blk.outs]) {
        if (p.isBus != bus) continue;
        b.writeln(
          '    <line x1="${_n(p.edge.dx)}" y1="${_n(p.edge.dy)}" '
          'x2="${_n(p.pos.dx)}" y2="${_n(p.pos.dy)}"/>',
        );
      }
    }
    b.writeln('  </g>');
  }

  // ---- 常量标记 ----
  for (final blk in model.blocks) {
    if (blk.isIo) continue;
    for (final p in [...blk.ins, ...blk.outs]) {
      final text = p.constText;
      if (text == null) continue;
      b.writeln(
        '  <rect x="${_n(p.pos.dx)}" y="${_n(p.pos.dy - 5)}" '
        'width="10" height="10" fill="${_c(palette.canvasBg)}" '
        'stroke="${_c(palette.cellConst)}" stroke-width="0.5"/>',
      );
      b.writeln(
        '  <text x="${_n(nlConstLabelX(p, _svgTextWidth(text, 9)))}" '
        'y="${_n(p.pos.dy + 3)}" font-family="$font" font-size="9" '
        'fill="${_c(palette.cellConst)}">${_e(text)}</text>',
      );
    }
  }

  // ---- 连线（正交布线优先；否则每网按拓扑画直线；网名贴驱动端标注）----
  for (final wire in model.wires) {
    final segments =
        autoRoutes?[wire] ?? nlStraightWireSegments(wire, topology);
    if (segments.isEmpty) continue;
    final color = wire.isBus ? palette.wireBus : palette.wire;
    final d = StringBuffer();
    for (final (a, b) in segments) {
      d.write('M${_n(a.dx)},${_n(a.dy)} L${_n(b.dx)},${_n(b.dy)} ');
    }
    b.writeln(
      '  <path d="${d.toString().trim()}" fill="none" '
      'stroke="${_c(color)}" stroke-width="${wire.isBus ? 3.0 : 0.5}"/>',
    );
    for (final j in autoJunctions?[wire] ?? const <Offset>[]) {
      b.writeln(
        '  <circle cx="${_n(j.dx)}" cy="${_n(j.dy)}" '
        'r="${wire.isBus ? 4.0 : 2.0}" fill="${_c(color)}"/>',
      );
    }
    if (autoRoutes == null) {
      for (final j in nlStraightWireJunctions(wire, topology)) {
        b.writeln(
          '  <circle cx="${_n(j.dx)}" cy="${_n(j.dy)}" '
          'r="${wire.isBus ? 4.0 : 2.0}" fill="${_c(color)}"/>',
        );
      }
    }
    if (wire.label.isEmpty) continue;
    final text = wire.label;
    final lw = text.length * 5.4;
    // 驱动端上方；靠近画布右缘时改放左侧。
    var x = wire.from.pos.dx + 5;
    if (x + lw > model.canvasSize.width - 4) {
      x = wire.from.pos.dx - lw - 5;
    }
    final y = wire.from.pos.dy - 4;
    b.writeln(
      '  <rect x="${_n(x - 3)}" y="${_n(y - 12)}" width="${_n(lw + 6)}" '
      'height="13" rx="2.5" fill="${_c(palette.canvasBg)}" '
      'fill-opacity="0.82" stroke="${_c(palette.netLabel)}" '
      'stroke-opacity="0.45"/>',
    );
    b.writeln(
      '  <text x="${_n(x)}" y="${_n(y)}" font-family="$font" '
      'font-size="9.5" fill="${_c(palette.netLabel)}">${_e(text)}</text>',
    );
  }

  // ---- 端口符号（输入/输出五边形 + 双向六边形，含 `I`/`O`/`IO` 标注）----
  for (final blk in model.blocks) {
    if (!blk.isIo) continue;
    for (final p in [...blk.ins, ...blk.outs]) {
      final left = p.isPortInput ? p.pos.dx - _kSvgPortW : p.pos.dx;
      final top = p.pos.dy - _kSvgPortH / 2;
      final tip = _kSvgPortH / 2;
      // 数据流方向：输入尖端朝右（指向设计内），输出尖端朝右（指向设计外），
      // 双向为两端带尖的六边形。
      final d = p.dir == NetlistPortDir.inout
          ? 'M${_n(left + tip)},${_n(top)} '
                'L${_n(left + _kSvgPortW - tip)},${_n(top)} '
                'L${_n(left + _kSvgPortW)},${_n(p.pos.dy)} '
                'L${_n(left + _kSvgPortW - tip)},${_n(top + _kSvgPortH)} '
                'L${_n(left + tip)},${_n(top + _kSvgPortH)} '
                'L${_n(left)},${_n(p.pos.dy)} Z'
          : 'M${_n(left)},${_n(top)} '
                'L${_n(left + _kSvgPortW - tip)},${_n(top)} '
                'L${_n(left + _kSvgPortW)},${_n(p.pos.dy)} '
                'L${_n(left + _kSvgPortW - tip)},${_n(top + _kSvgPortH)} '
                'L${_n(left)},${_n(top + _kSvgPortH)} Z';
      final fill = switch (p.dir) {
        NetlistPortDir.input => palette.portFill,
        NetlistPortDir.output => palette.portFillOut,
        NetlistPortDir.inout => palette.portFillInout,
      };
      b.writeln(
        '  <path d="$d" fill="${_c(fill)}" '
        'stroke="${_c(palette.portBorder)}" stroke-width="0.5"/>',
      );
      // 符号内方向标注。
      b.writeln(
        '  <text x="${_n(left + _kSvgPortW / 2)}" '
        'y="${_n(p.pos.dy + 3)}" font-family="$font" '
        'font-size="${p.dir == NetlistPortDir.inout ? 7.5 : 8.5}" '
        'font-weight="600" text-anchor="middle" '
        'fill="${_c(palette.portBorder)}">${p.dir.label}</text>',
      );
      final anchor = p.isPortInput ? 'end' : 'start';
      final tx = p.isPortInput
          ? left - _kSvgPortGap
          : left + _kSvgPortW + _kSvgPortGap;
      b.writeln(
        '  <text x="${_n(tx)}" y="${_n(p.pos.dy + 3)}" '
        'font-family="$font" font-size="10" text-anchor="$anchor" '
        'fill="${_c(palette.portText)}">${_e(p.display)}</text>',
      );
    }
  }

  // ---- 标准单元符号（与页内 Canvas 共用几何）----
  for (final blk in model.blocks) {
    if (blk.isIo) continue;
    final fill = netlistCellFill(blk.cell?.kind, palette);
    final rect = Rect.fromLTWH(
      blk.boxOrigin.dx,
      blk.boxOrigin.dy,
      blk.boxSize.width,
      blk.boxSize.height,
    );
    final pins = <NetlistSymbolPin>[
      for (final p in blk.ins)
        NetlistSymbolPin(
          port: p.port,
          display: p.display,
          edge: p.edge,
          isInput: true,
        ),
      for (final p in blk.outs)
        NetlistSymbolPin(
          port: p.port,
          display: p.display,
          edge: p.edge,
          isInput: false,
        ),
    ];
    final geometry = buildNetlistSymbol(blk.cell, rect, pins: pins);
    b.writeln('  <g data-symbol="${geometry.kind.name}">');
    b.writeln(
      '    <path d="${geometry.outline.toSvg()}" fill="${_c(fill)}" '
      'stroke="${_c(palette.blockBorder)}" stroke-width="0.5"/>',
    );
    for (final detail in geometry.details) {
      b.writeln(
        '    <path d="${detail.toSvg()}" fill="none" '
        'stroke="${_c(palette.blockBorder)}" stroke-width="0.5"/>',
      );
    }
    for (final bubble in geometry.bubbles) {
      b.writeln(
        '    <circle cx="${_n(bubble.center.dx)}" '
        'cy="${_n(bubble.center.dy)}" r="${_n(bubble.radius)}" '
        'fill="${_c(fill)}" stroke="${_c(palette.blockBorder)}" '
        'stroke-width="0.5"/>',
      );
    }
    final label = geometry.centerLabel;
    if (label != null && label.isNotEmpty) {
      b.writeln(
        '    <text x="${_n(rect.center.dx)}" '
        'y="${_n(rect.center.dy + geometry.centerLabelSize * 0.35)}" '
        'font-family="$font" font-size="${_n(geometry.centerLabelSize)}" '
        'text-anchor="middle" fill="${_c(palette.pinText)}">'
        '${_e(label)}</text>',
      );
    }
    // 实例名（符号内部顶端左侧，避开「＋」与顶边针脚）。
    b.writeln(
      '    <text x="${_n(rect.left + 4)}" y="${_n(rect.top + 15)}" '
      'font-family="$font" font-size="7.5" text-anchor="start" '
      'fill="${_c(nlBlockLabelColor)}">${_e(blk.title)}</text>',
    );
    // 类型名（符号内部底端左侧，避开底边针脚）。
    b.writeln(
      '    <text x="${_n(rect.left + 4)}" y="${_n(rect.bottom - 8)}" '
      'font-family="$font" font-size="6" text-anchor="start" '
      'fill="${_c(nlBlockLabelColor)}">${_e(blk.subtitle)}</text>',
    );
    for (final p in pins) {
      final at = netlistSymbolPinLabelTopLeft(
        geometry.kind,
        p,
        rect,
        Size(_svgTextWidth(p.display, 10), 12),
        isInstance: blk.cell?.isInstance ?? false,
      );
      b.writeln(
        '    <text x="${_n(at.dx)}" y="${_n(at.dy + 10)}" '
        'font-family="$font" font-size="10" '
        'fill="${_c(palette.pinText)}">${_e(p.display)}</text>',
      );
    }
    b.writeln('  </g>');
  }

  if (diagnosticOverlay != null && diagnosticOverlay.isNotEmpty) {
    b.writeln(diagnosticOverlay);
  }
  b.writeln('</svg>');
  return b.toString();
}

/// SVG 中的端口符号尺寸（与页内绘制常量一致）。
const double _kSvgPortW = 27.0;
const double _kSvgPortH = 15.0;
const double _kSvgPortGap = 6.0;

String _n(double v) => v.toStringAsFixed(1);

double _svgTextWidth(String text, double fontSize) =>
    text.runes.length * fontSize * 0.56;

String _c(Color c) {
  final r = (c.r * 255).round();
  final g = (c.g * 255).round();
  final b = (c.b * 255).round();
  return '#${r.toRadixString(16).padLeft(2, '0')}'
      '${g.toRadixString(16).padLeft(2, '0')}'
      '${b.toRadixString(16).padLeft(2, '0')}';
}

String _e(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');
