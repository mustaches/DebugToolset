/// RTL 单元的标准电路符号几何：同一份路径命令可输出 Canvas [Path] 与
/// SVG path，保证页内视图和导出文件的符号一致。
library;

import 'dart:math' as math;
import 'dart:ui' show Offset, Path, Rect, Size;

import 'netlist_model.dart';

enum NetlistSymbolKind {
  andGate,
  orGate,
  xorGate,
  notGate,
  buffer,
  mux,
  flipFlop,
  latch,
  memory,
  operatorBlock,
  block,
}

/// 一条符号路径。坐标由调用方给定，可为画布局部坐标或 SVG 全局坐标。
class NetlistSymbolPath {
  final List<(String, List<double>)> _commands = [];

  void moveTo(double x, double y) => _commands.add(('M', [x, y]));

  void lineTo(double x, double y) => _commands.add(('L', [x, y]));

  void cubicTo(
    double x1,
    double y1,
    double x2,
    double y2,
    double x,
    double y,
  ) => _commands.add(('C', [x1, y1, x2, y2, x, y]));

  void quadraticTo(double x1, double y1, double x, double y) =>
      _commands.add(('Q', [x1, y1, x, y]));

  void close() => _commands.add(('Z', const []));

  Path toPath() {
    final path = Path();
    for (final (cmd, v) in _commands) {
      switch (cmd) {
        case 'M':
          path.moveTo(v[0], v[1]);
        case 'L':
          path.lineTo(v[0], v[1]);
        case 'C':
          path.cubicTo(v[0], v[1], v[2], v[3], v[4], v[5]);
        case 'Q':
          path.quadraticBezierTo(v[0], v[1], v[2], v[3]);
        case 'Z':
          path.close();
      }
    }
    return path;
  }

  String toSvg() => _commands
      .map(
        (e) => e.$1 == 'Z' ? 'Z' : '${e.$1}${e.$2.map(_svgNumber).join(',')}',
      )
      .join(' ');
}

class NetlistSymbolBubble {
  final Offset center;
  final double radius;

  const NetlistSymbolBubble(this.center, this.radius);
}

/// 符号绘制所需的针脚信息；不依赖 UI 层的 NlPin，供两种渲染后端复用。
class NetlistSymbolPin {
  final String port;
  final String display;
  final Offset edge;
  final bool isInput;

  const NetlistSymbolPin({
    required this.port,
    required this.display,
    required this.edge,
    required this.isInput,
  });
}

class NetlistSymbolGeometry {
  final NetlistSymbolKind kind;
  final NetlistSymbolPath outline;
  final List<NetlistSymbolPath> details;
  final List<NetlistSymbolBubble> bubbles;
  final String? centerLabel;
  final double centerLabelSize;

  const NetlistSymbolGeometry({
    required this.kind,
    required this.outline,
    this.details = const [],
    this.bubbles = const [],
    this.centerLabel,
    this.centerLabelSize = 15,
  });
}

NetlistSymbolKind netlistSymbolKindOf(NetlistCell? cell) {
  if (cell == null || cell.isInstance) return NetlistSymbolKind.block;
  switch (cell.type) {
    case r'$and':
    case r'$logic_and':
    case r'$reduce_and':
    case r'$nand':
      return NetlistSymbolKind.andGate;
    case r'$or':
    case r'$logic_or':
    case r'$reduce_or':
    case r'$reduce_bool':
    case r'$nor':
      return NetlistSymbolKind.orGate;
    case r'$xor':
    case r'$reduce_xor':
    case r'$xnor':
      return NetlistSymbolKind.xorGate;
    case r'$not':
    case r'$logic_not':
      return NetlistSymbolKind.notGate;
    case r'$tribuf':
      return NetlistSymbolKind.buffer;
    case r'$mux':
    case r'$pmux':
    case r'$bmux':
      return NetlistSymbolKind.mux;
    case r'$dlatch':
    case r'$adlatch':
    case r'$sr':
      return NetlistSymbolKind.latch;
    default:
      if (cell.kind == NetlistCellKind.seq) return NetlistSymbolKind.flipFlop;
      if (cell.kind == NetlistCellKind.mem) return NetlistSymbolKind.memory;
      if (cell.kind == NetlistCellKind.arith ||
          cell.kind == NetlistCellKind.compare ||
          cell.kind == NetlistCellKind.shift) {
        return NetlistSymbolKind.operatorBlock;
      }
      return NetlistSymbolKind.block;
  }
}

/// 组合逻辑的单输出位于符号垂直中心；触发器/锁存器的 Q 仍与首行 D 对齐。
bool netlistSymbolCentersOutput(NetlistCell? cell) {
  final kind = netlistSymbolKindOf(cell);
  return kind != NetlistSymbolKind.block &&
      kind != NetlistSymbolKind.flipFlop &&
      kind != NetlistSymbolKind.latch;
}

bool netlistSymbolIsBottomPin(NetlistCell? cell, String port) =>
    netlistSymbolKindOf(cell) == NetlistSymbolKind.mux && port == 'S';

double netlistSymbolMinWidth(NetlistCell? cell) =>
    switch (netlistSymbolKindOf(cell)) {
      NetlistSymbolKind.notGate || NetlistSymbolKind.buffer => 62,
      NetlistSymbolKind.andGate ||
      NetlistSymbolKind.orGate ||
      NetlistSymbolKind.xorGate => 72,
      NetlistSymbolKind.mux => 78,
      _ => 96,
    };

/// OR/XOR 的输入短线必须接到内凹曲线，而不是包围盒左缘。
double netlistSymbolInputEdgeX(NetlistCell? cell, Rect rect, double y) {
  final kind = netlistSymbolKindOf(cell);
  if (kind != NetlistSymbolKind.orGate && kind != NetlistSymbolKind.xorGate) {
    return rect.left;
  }
  final t = rect.height == 0
      ? 0.0
      : ((y - rect.top) / rect.height).clamp(0.0, 1.0);
  return rect.left + 2 * _orInputIndent(rect) * t * (1 - t);
}

NetlistSymbolGeometry buildNetlistSymbol(
  NetlistCell? cell,
  Rect rect, {
  List<NetlistSymbolPin> pins = const [],
}) {
  final kind = netlistSymbolKindOf(cell);
  final outline = NetlistSymbolPath();
  final details = <NetlistSymbolPath>[];
  final bubbles = <NetlistSymbolBubble>[];
  String? label;
  var labelSize = 15.0;

  bool invertedOutput(NetlistCell? c) =>
      c != null &&
      (c.type == r'$not' ||
          c.type == r'$logic_not' ||
          c.type == r'$xnor' ||
          c.type == r'$nand' ||
          c.type == r'$nor');

  final outputBubble = invertedOutput(cell);
  final bodyRight = rect.right - (outputBubble ? 6 : 0);
  switch (kind) {
    case NetlistSymbolKind.andGate:
      final midX = (rect.left + bodyRight) / 2;
      final controlX = midX + (bodyRight - midX) * 4 / 3;
      outline
        ..moveTo(rect.left, rect.top)
        ..lineTo(midX, rect.top)
        ..cubicTo(controlX, rect.top, controlX, rect.bottom, midX, rect.bottom)
        ..lineTo(rect.left, rect.bottom)
        ..close();
    case NetlistSymbolKind.orGate:
    case NetlistSymbolKind.xorGate:
      _orOutline(outline, rect, bodyRight);
      if (kind == NetlistSymbolKind.xorGate) {
        final extra = NetlistSymbolPath();
        final indent = _orInputIndent(rect);
        final shift = math.min(6.0, rect.width * 0.07);
        extra
          ..moveTo(rect.left - shift, rect.bottom)
          ..quadraticTo(
            rect.left + indent - shift,
            rect.center.dy,
            rect.left - shift,
            rect.top,
          );
        details.add(extra);
      }
    case NetlistSymbolKind.notGate:
    case NetlistSymbolKind.buffer:
      outline
        ..moveTo(rect.left, rect.top)
        ..lineTo(bodyRight, rect.center.dy)
        ..lineTo(rect.left, rect.bottom)
        ..close();
    case NetlistSymbolKind.mux:
      final inset = math.min(9.0, rect.height * 0.18);
      outline
        ..moveTo(rect.left, rect.top)
        ..lineTo(rect.right, rect.top + inset)
        ..lineTo(rect.right, rect.bottom - inset)
        ..lineTo(rect.left, rect.bottom)
        ..close();
    case NetlistSymbolKind.flipFlop:
    case NetlistSymbolKind.latch:
    case NetlistSymbolKind.memory:
    case NetlistSymbolKind.operatorBlock:
    case NetlistSymbolKind.block:
      outline
        ..moveTo(rect.left, rect.top)
        ..lineTo(rect.right, rect.top)
        ..lineTo(rect.right, rect.bottom)
        ..lineTo(rect.left, rect.bottom)
        ..close();
      if (kind == NetlistSymbolKind.memory) {
        label = cell?.typeLabel ?? 'MEM';
        labelSize = 11;
      } else if (kind == NetlistSymbolKind.operatorBlock) {
        label = _operatorLabel(cell);
        labelSize = label.length > 3 ? 10 : 16;
      }
  }

  if (outputBubble) {
    bubbles.add(NetlistSymbolBubble(Offset(rect.right - 3, rect.center.dy), 3));
  }

  if (kind == NetlistSymbolKind.flipFlop || kind == NetlistSymbolKind.memory) {
    for (final p in pins) {
      if (!p.isInput || !_isClockPort(p.port)) continue;
      final tri = NetlistSymbolPath()
        ..moveTo(p.edge.dx, p.edge.dy - 4)
        ..lineTo(p.edge.dx + 7, p.edge.dy)
        ..lineTo(p.edge.dx, p.edge.dy + 4)
        ..close();
      details.add(tri);
    }
  }

  if (cell != null &&
      (kind == NetlistSymbolKind.flipFlop ||
          kind == NetlistSymbolKind.memory)) {
    for (final p in pins) {
      if (!p.isInput || !_isActiveLow(cell, p.port)) continue;
      bubbles.add(NetlistSymbolBubble(p.edge, 2.5));
    }
  }

  return NetlistSymbolGeometry(
    kind: kind,
    outline: outline,
    details: details,
    bubbles: bubbles,
    centerLabel: label,
    centerLabelSize: labelSize,
  );
}

/// 针脚名的统一落位：输入贴实际轮廓、输出贴右缘、MUX 选择端贴所在边
/// （镜像后 S 在顶边时标签也跟着到顶边）。
Offset netlistSymbolPinLabelTopLeft(
  NetlistSymbolKind kind,
  NetlistSymbolPin pin,
  Rect rect,
  Size textSize, {
  bool isInstance = false,
}) {
  if (pin.isInput && kind == NetlistSymbolKind.mux && pin.port == 'S') {
    final topSide = pin.edge.dy < rect.center.dy;
    return Offset(
      rect.center.dx - textSize.width / 2,
      topSide ? rect.top + 2 : rect.bottom - textSize.height - 2,
    );
  }
  if (pin.isInput) {
    final clockPad = _isClockPort(pin.port) ? 11.0 : 5.0;
    final instancePad = isInstance ? 14.0 : 0.0;
    return Offset(
      pin.edge.dx + clockPad + instancePad,
      pin.edge.dy - textSize.height / 2,
    );
  }
  return Offset(
    pin.edge.dx - textSize.width - 5,
    pin.edge.dy - textSize.height / 2,
  );
}

void _orOutline(NetlistSymbolPath path, Rect rect, double right) {
  final indent = _orInputIndent(rect);
  final upperControlX = rect.left + (right - rect.left) * 0.58;
  path
    ..moveTo(rect.left, rect.top)
    ..quadraticTo(upperControlX, rect.top, right, rect.center.dy)
    ..quadraticTo(upperControlX, rect.bottom, rect.left, rect.bottom)
    ..quadraticTo(rect.left + indent, rect.center.dy, rect.left, rect.top)
    ..close();
}

double _orInputIndent(Rect rect) => math.min(30.0, rect.width * 0.30);

bool _isClockPort(String port) => port == 'CLK' || port.endsWith('_CLK');

bool _isActiveLow(NetlistCell cell, String port) {
  final key = switch (port) {
    'CLK' || 'RD_CLK' || 'WR_CLK' => 'CLK_POLARITY',
    'ARST' => 'ARST_POLARITY',
    'SRST' => 'SRST_POLARITY',
    'EN' || 'RD_EN' || 'WR_EN' => 'EN_POLARITY',
    'SET' => 'SET_POLARITY',
    'CLR' => 'CLR_POLARITY',
    _ => null,
  };
  return key != null && cell.params[key] == 0;
}

String _operatorLabel(NetlistCell? cell) => switch (cell?.type) {
  r'$add' => '+',
  r'$sub' || r'$neg' => '−',
  r'$mul' => '×',
  r'$div' => '÷',
  r'$mod' => 'mod',
  r'$pos' => '+',
  r'$lt' => '<',
  r'$le' => '≤',
  r'$gt' => '>',
  r'$ge' => '≥',
  r'$eq' => '=',
  r'$ne' => '≠',
  r'$shl' => '<<',
  r'$shr' => '>>',
  r'$sshl' => '<<<',
  r'$sshr' => '>>>',
  r'$shift' => 'shift',
  r'$shiftx' => 'shiftx',
  _ => cell?.typeLabel ?? '',
};

String _svgNumber(double v) => v.toStringAsFixed(1);
