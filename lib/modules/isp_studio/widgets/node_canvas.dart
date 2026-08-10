/// ISP Studio 无限画布：点阵背景、平移缩放、连线落点命中、键盘删除。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../providers/isp_studio_state.dart';
import '../models/isp_node.dart';
import 'connection_painter.dart';
import 'node_layout.dart';
import 'node_widget.dart';

/// 节点画布。节点与连线绘制在画布（未缩放）坐标系中，
/// 通过外层 Transform.translate + Transform.scale 映射到屏幕。
class IspNodeCanvas extends StatefulWidget {
  const IspNodeCanvas({super.key});

  @override
  State<IspNodeCanvas> createState() => IspNodeCanvasState();
}

class IspNodeCanvasState extends State<IspNodeCanvas> {
  /// 输入端口命中表：'nodeId:port' → 端口控件的 GlobalKey。
  final Map<String, GlobalKey> _portKeys = {};

  /// 画布的键盘焦点（Delete/Backspace 删除选中项）。点过运行按钮、
  /// 文件对话框或属性面板后焦点会离开画布，任何指针按下时夺回。
  final FocusNode _canvasFocusNode = FocusNode();

  @override
  void dispose() {
    _canvasFocusNode.dispose();
    super.dispose();
  }

  /// 全局坐标 → 画布（未缩放）坐标。
  Offset globalToCanvas(Offset global) {
    final box = context.findRenderObject() as RenderBox;
    final local = box.globalToLocal(global);
    final state = context.read<IspStudioState>();
    return (local - state.canvasOffset) / state.canvasZoom;
  }

  /// 视口中心对应的画布坐标（供「添加节点」使用）。
  Offset viewportCenterCanvas() {
    final box = context.findRenderObject() as RenderBox;
    final center = box.size.center(Offset.zero);
    final state = context.read<IspStudioState>();
    return (center - state.canvasOffset) / state.canvasZoom;
  }

  /// 视口在画布（未缩放）坐标下的矩形（供「最大化」铺满视口）。
  Rect viewportCanvasRect() {
    final box = context.findRenderObject() as RenderBox;
    final state = context.read<IspStudioState>();
    final origin = -state.canvasOffset / state.canvasZoom;
    return Rect.fromLTWH(origin.dx, origin.dy,
        box.size.width / state.canvasZoom, box.size.height / state.canvasZoom);
  }

  /// 最大化/还原有显示区的节点（预览/仪器）。
  void toggleMaximizeNode(String nodeId) {
    context.read<IspStudioState>().toggleMaximize(nodeId, viewportCanvasRect());
  }

  GlobalKey _portKeyFor(String nodeId, String port) {
    return _portKeys.putIfAbsent(
        '$nodeId:$port', () => GlobalKey(debugLabel: '$nodeId:$port'));
  }

  /// 连线拖拽结束：在已注册的输入端口中找最近者（24 逻辑像素内）。
  void endDrag() {
    final state = context.read<IspStudioState>();
    if (state.dragFromNodeId == null) return;
    final pos = state.dragCurrentPos;
    String? bestNodeId;
    String? bestPort;
    var bestDist = 24.0;
    for (final entry in _portKeys.entries) {
      final ctx = entry.value.currentContext;
      if (ctx == null) continue;
      final box = ctx.findRenderObject();
      if (box is! RenderBox || !box.attached) continue;
      // localToGlobal 会叠加端口控件自身的 Transform.translate 与画布变换。
      final centerGlobal =
          box.localToGlobal(box.size.center(Offset.zero));
      final dist = (globalToCanvas(centerGlobal) - pos).distance;
      if (dist < bestDist) {
        bestDist = dist;
        final sep = entry.key.indexOf(':');
        bestNodeId = entry.key.substring(0, sep);
        bestPort = entry.key.substring(sep + 1);
      }
    }
    final error = state.endConnectionDrag(bestNodeId, bestPort);
    if (error != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error), duration: const Duration(seconds: 2)),
      );
    }
  }

  /// 画布点击：优先命中已选连线的中点删除控制点，
  /// 其次做连线命中选中，点空白则取消所有选择。
  void _onCanvasTapUp(TapUpDetails details) {
    final state = context.read<IspStudioState>();
    final pos = globalToCanvas(details.globalPosition);
    final selId = state.selectedConnectionId;
    if (selId != null) {
      final conn = state.graph.connections
          .where((c) => c.id == selId)
          .firstOrNull;
      final geo = conn == null ? null : resolveWireGeometry(state.graph, conn);
      if (geo != null &&
          (wireMidpoint(geo.start, geo.end) - pos).distance <=
              kWireControlRadius / state.canvasZoom) {
        state.removeConnection(selId);
        return;
      }
    }
    final hitId =
        hitTestWire(state.graph, pos, kWireHitTolerance / state.canvasZoom);
    if (hitId != null) {
      state.selectConnection(hitId);
    } else {
      state.selectNode(null);
      state.selectConnection(null);
    }
  }

  /// 右键拖拽的目标节点 id；null 表示拖动画布。
  String? _rightDragNodeId;

  /// 画布坐标下的节点命中（后绘制者优先）。
  String? _nodeAt(IspStudioState state, Offset canvasPos) {
    for (final node in state.graph.nodes.values.toList().reversed) {
      final type = IspNodeRegistry.byId(node.typeId);
      if (type == null) continue;
      final h = nodeHeight(type,
          previewExtraHeight: state.previewExtraHeight(node.id));
      if (canvasPos.dx >= node.x &&
          canvasPos.dx <= node.x + node.width &&
          canvasPos.dy >= node.y &&
          canvasPos.dy <= node.y + h) {
        return node.id;
      }
    }
    return null;
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.delete ||
            event.logicalKey == LogicalKeyboardKey.backspace)) {
      context.read<IspStudioState>().removeSelected();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<IspStudioState>();
    // 清理已删除节点遗留的端口 key。
    _portKeys.removeWhere(
        (name, _) => !state.graph.nodes.containsKey(name.split(':').first));

    return Focus(
      focusNode: _canvasFocusNode,
      autofocus: true,
      onKeyEvent: _onKeyEvent,
      child: Listener(
        onPointerSignal: (event) {
          if (event is PointerScrollEvent) {
            state.zoomAt(event.localPosition,
                event.scrollDelta.dy < 0 ? 1.1 : 1 / 1.1);
          }
        },
        onPointerDown: (event) {
          // 夺回键盘焦点：否则点过运行按钮/文件对话框后 Delete 不再
          // 到达画布，选中节点无法删除。
          _canvasFocusNode.requestFocus();
          // 右键拖拽：按下点命中节点则拖动节点，否则拖动画布。
          if (event.buttons & kSecondaryButton != 0) {
            _rightDragNodeId = _nodeAt(state, globalToCanvas(event.position));
          }
        },
        onPointerMove: (event) {
          if (event.buttons & kSecondaryButton == 0) return;
          final id = _rightDragNodeId;
          if (id != null) {
            state.moveNode(id, event.delta / state.canvasZoom);
          } else {
            state.panBy(event.delta);
          }
        },
        onPointerUp: (_) => _rightDragNodeId = null,
        onPointerCancel: (_) => _rightDragNodeId = null,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          // 左键只做选中/连线/按钮，不再拖动画布。
          onTapUp: _onCanvasTapUp,
          child: ClipRect(
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // (a) 点阵背景（屏幕空间绘制）。
                Positioned.fill(
                  child: CustomPaint(
                    painter:
                        _DotGridPainter(state.canvasOffset, state.canvasZoom),
                  ),
                ),
                // (b) 画布坐标系：连线 + 节点。
                Positioned.fill(
                  child: Transform.translate(
                    offset: state.canvasOffset,
                    child: Transform.scale(
                      scale: state.canvasZoom,
                      alignment: Alignment.topLeft,
                      child: _UnboundedHitStack(
                        clipBehavior: Clip.none,
                        children: [
                          CustomPaint(
                            painter: IspConnectionPainter(state),
                            child: const SizedBox.expand(),
                          ),
                          // 最大化的节点排在最后渲染（置顶显示）。
                          for (final node in [
                            ...state.graph.nodes.values.where(
                                (n) => n.id != state.maximizedNodeId),
                            ...state.graph.nodes.values.where(
                                (n) => n.id == state.maximizedNodeId),
                          ])
                            Positioned(
                              left: node.x,
                              top: node.y,
                              child: IspNodeWidget(
                                node: node,
                                type: IspNodeRegistry.byId(node.typeId)!,
                                selected: node.id == state.selectedNodeId,
                                globalToCanvas: globalToCanvas,
                                onConnectionDragEnd: endDrag,
                                onToggleMaximize: () =>
                                    toggleMaximizeNode(node.id),
                                inputPortKeyFor: (port) =>
                                    _portKeyFor(node.id, port),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 与 [Stack] 相同，但命中测试不受自身尺寸限制。
///
/// 画布是可平移的无限平面：节点可能位于视口（Stack 尺寸）之外、
/// 又被平移变换移回可视区域内。默认 [RenderBox.hitTest] 会先检查
/// `size.contains(position)`，越界直接拒绝且不再测试子节点，
/// 导致节点"画得出、点不到"（clipBehavior 只影响绘制，不影响命中）。
class _UnboundedHitStack extends Stack {
  const _UnboundedHitStack({super.clipBehavior, required super.children});

  @override
  RenderStack createRenderObject(BuildContext context) {
    return _UnboundedHitRenderStack(
      alignment: alignment,
      textDirection: textDirection ?? Directionality.maybeOf(context),
      fit: fit,
      clipBehavior: clipBehavior,
    );
  }
}

class _UnboundedHitRenderStack extends RenderStack {
  _UnboundedHitRenderStack({
    super.alignment,
    super.textDirection,
    super.fit,
    super.clipBehavior,
  });

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    // 跳过 size.contains 预检，直接测试子节点（子节点各自做边界检查）。
    if (hitTestChildren(result, position: position)) {
      result.add(BoxHitTestEntry(this, position));
      return true;
    }
    return false;
  }
}

/// 屏幕空间点阵背景，间距 24 逻辑像素，随平移缩放变化。
class _DotGridPainter extends CustomPainter {
  final Offset offset;
  final double zoom;

  _DotGridPainter(this.offset, this.zoom);

  @override
  void paint(Canvas canvas, Size size) {
    final spacing = 24 * zoom;
    final paint = Paint()..color = Colors.white.withValues(alpha: 0.06);
    final startX = offset.dx % spacing;
    final startY = offset.dy % spacing;
    for (var x = startX; x < size.width; x += spacing) {
      for (var y = startY; y < size.height; y += spacing) {
        canvas.drawCircle(Offset(x, y), 1, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DotGridPainter oldDelegate) =>
      oldDelegate.offset != offset || oldDelegate.zoom != zoom;
}
