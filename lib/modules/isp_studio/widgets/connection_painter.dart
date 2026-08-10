/// ISP Studio 连线绘制器：在画布（未缩放）坐标系中绘制贝塞尔连线。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../providers/isp_studio_state.dart';
import '../models/isp_graph.dart';
import '../models/isp_node.dart';
import 'node_layout.dart';

/// 连线命中测试容差（屏幕逻辑像素，调用处除以缩放换算成画布坐标）。
const double kWireHitTolerance = 8.0;

/// 选中连线中点删除控制点的半径（屏幕逻辑像素）。
const double kWireControlRadius = 9.0;

/// 一条连线解析后的几何信息（画布坐标）。
class IspWireGeometry {
  final Offset start;
  final Offset end;
  final Color color;

  const IspWireGeometry(this.start, this.end, this.color);
}

/// 由连接解析出起止端口坐标与颜色；节点/端口缺失时返回 null。
IspWireGeometry? resolveWireGeometry(IspGraph graph, IspConnection conn) {
  final fromNode = graph.nodes[conn.fromNodeId];
  final toNode = graph.nodes[conn.toNodeId];
  if (fromNode == null || toNode == null) return null;
  final fromType = IspNodeRegistry.byId(fromNode.typeId);
  final toType = IspNodeRegistry.byId(toNode.typeId);
  if (fromType == null || toType == null) return null;
  final outIndex = fromType.outputs.indexWhere((p) => p.name == conn.fromPort);
  final inIndex = toType.inputs.indexWhere((p) => p.name == conn.toPort);
  if (outIndex < 0 || inIndex < 0) return null;
  return IspWireGeometry(
    outputPortPos(fromNode, fromType, outIndex),
    inputPortPos(toNode, toType, inIndex),
    portColor(fromType.outputs[outIndex].type),
  );
}

/// 贝塞尔水平控制点偏移量（绘制与几何计算共用，保证一致）。
double _wireCp(Offset start, Offset end) {
  return math.max(40.0, (end.dx - start.dx).abs() * 0.5);
}

/// 三次贝塞尔在 t 处的点。
Offset _cubicPoint(Offset p0, Offset p1, Offset p2, Offset p3, double t) {
  final u = 1 - t;
  return p0 * (u * u * u) +
      p1 * (3 * u * u * t) +
      p2 * (3 * u * t * t) +
      p3 * (t * t * t);
}

/// 连线中点（t = 0.5），删除控制点放在这里。
Offset wireMidpoint(Offset start, Offset end) {
  final cp = _wireCp(start, end);
  return _cubicPoint(start, Offset(start.dx + cp, start.dy),
      Offset(end.dx - cp, end.dy), end, 0.5);
}

double _distToSegment(Offset p, Offset a, Offset b) {
  final ab = b - a;
  final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
  if (len2 == 0) return (p - a).distance;
  final t =
      (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / len2).clamp(0.0, 1.0);
  return (p - (a + ab * t)).distance;
}

/// 点到连线的最近距离（对折线化后的贝塞尔采样）。
double _distanceToWire(Offset start, Offset end, Offset p) {
  const segments = 24;
  final cp = _wireCp(start, end);
  final c1 = Offset(start.dx + cp, start.dy);
  final c2 = Offset(end.dx - cp, end.dy);
  var prev = start;
  var min = double.infinity;
  for (var i = 1; i <= segments; i++) {
    final pt = _cubicPoint(start, c1, c2, end, i / segments);
    final d = _distToSegment(p, prev, pt);
    if (d < min) min = d;
    prev = pt;
  }
  return min;
}

/// 命中测试：返回距 [pos] 最近且距离不超过 [tolerance] 的连接 id。
String? hitTestWire(IspGraph graph, Offset pos, double tolerance) {
  String? bestId;
  var best = tolerance;
  for (final conn in graph.connections) {
    final geo = resolveWireGeometry(graph, conn);
    if (geo == null) continue;
    final d = _distanceToWire(geo.start, geo.end, pos);
    if (d <= best) {
      best = d;
      bestId = conn.id;
    }
  }
  return bestId;
}

/// 绘制已建立的连线与正在拖拽中的临时连线。
/// 该 painter 被放置在与节点相同的 Transform 内，直接使用画布坐标。
class IspConnectionPainter extends CustomPainter {
  final IspStudioState state;

  IspConnectionPainter(this.state) : super(repaint: state);

  @override
  void paint(Canvas canvas, Size size) {
    for (final conn in state.graph.connections) {
      final geo = resolveWireGeometry(state.graph, conn);
      if (geo == null) continue;
      final selected = conn.id == state.selectedConnectionId;
      if (selected) {
        _drawWire(canvas, geo.start, geo.end, Colors.white, 0.35,
            width: 5.5);
      }
      _drawWire(canvas, geo.start, geo.end, geo.color, 1.0);
      if (selected) {
        _drawDeleteControl(
            canvas, wireMidpoint(geo.start, geo.end));
      }
    }

    // 拖拽中的临时连线（60% 透明度）。
    final fromId = state.dragFromNodeId;
    final fromPort = state.dragFromPort;
    if (fromId != null && fromPort != null) {
      final fromNode = state.graph.nodes[fromId];
      final fromType =
          fromNode == null ? null : IspNodeRegistry.byId(fromNode.typeId);
      if (fromNode != null && fromType != null) {
        final outIndex =
            fromType.outputs.indexWhere((p) => p.name == fromPort);
        if (outIndex >= 0) {
          _drawWire(
            canvas,
            outputPortPos(fromNode, fromType, outIndex),
            state.dragCurrentPos,
            portColor(fromType.outputs[outIndex].type),
            0.6,
          );
        }
      }
    }
  }

  void _drawWire(
    Canvas canvas,
    Offset start,
    Offset end,
    Color color,
    double alpha, {
    double width = 2.5,
  }) {
    final cp = _wireCp(start, end);
    final path = Path()
      ..moveTo(start.dx, start.dy)
      ..cubicTo(start.dx + cp, start.dy, end.dx - cp, end.dy, end.dx, end.dy);
    canvas.drawPath(
      path,
      Paint()
        ..color = color.withValues(alpha: alpha)
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round,
    );
  }

  /// 选中连线中点的删除控制点：红底白叉圆钮，视觉尺寸不随缩放变化。
  void _drawDeleteControl(Canvas canvas, Offset center) {
    final r = kWireControlRadius / state.canvasZoom;
    canvas.drawCircle(
      center,
      r,
      Paint()..color = const Color(0xFFD84A4A),
    );
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5 / state.canvasZoom,
    );
    final x = r * 0.45;
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = 1.8 / state.canvasZoom
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
        center - Offset(x, x), center + Offset(x, x), paint);
    canvas.drawLine(
        center - Offset(x, -x), center + Offset(x, -x), paint);
  }

  @override
  bool shouldRepaint(IspConnectionPainter oldDelegate) => true;
}
