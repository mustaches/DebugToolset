/// ISP Studio 无限画布：点阵背景、平移缩放、连线落点命中、键盘删除。
library;

import 'dart:ui' as ui;

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

  /// 连线拖拽结束：在已注册的输入端口中找最近者（约 28 屏幕像素内，
  /// 换算为画布坐标随缩放调整——否则缩得越小说越难点中；最近者胜出，
  /// 多端口节点不会误连）。
  void endDrag() {
    final state = context.read<IspStudioState>();
    if (state.dragFromNodeId == null) return;
    final pos = state.dragCurrentPos;
    String? bestNodeId;
    String? bestPort;
    var bestDist = 28.0 / state.canvasZoom;
    for (final entry in _portKeys.entries) {
      final ctx = entry.value.currentContext;
      if (ctx == null) continue;
      final box = ctx.findRenderObject();
      if (box is! RenderBox || !box.attached) continue;
      final sep = entry.key.indexOf(':');
      final nodeId = entry.key.substring(0, sep);
      final port = entry.key.substring(sep + 1);
      // 视频输入组互斥置灰的端口不作为落点。
      if (!state.graph.videoInputPortAvailable(nodeId, port)) continue;
      // localToGlobal 会叠加端口控件自身的 Transform.translate 与画布变换。
      final centerGlobal =
          box.localToGlobal(box.size.center(Offset.zero));
      final dist = (globalToCanvas(centerGlobal) - pos).distance;
      if (dist < bestDist) {
        bestDist = dist;
        bestNodeId = nodeId;
        bestPort = port;
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

  /// 左键拖拽的目标节点 id；null 表示拖动画布或框选。
  String? _dragNodeId;

  /// 画布坐标下的框选起点；null 表示当前未进行框选。
  Offset? _boxSelectStartCanvasPos;

  /// 画布坐标下的节点标题栏命中（后绘制者优先）：左键点住标题栏拖动节点。
  String? _nodeAt(IspStudioState state, Offset canvasPos) {
    for (final node in state.graph.nodes.values.toList().reversed) {
      if (canvasPos.dx >= node.x &&
          canvasPos.dx <= node.x + node.width &&
          canvasPos.dy >= node.y &&
          canvasPos.dy <= node.y + kNodeTitleHeight) {
        return node.id;
      }
    }
    return null;
  }

  /// 画布坐标下的节点整体区域命中检测（包含卡片主干、操作按钮与控制点）。
  String? _nodeCardAt(IspStudioState state, Offset canvasPos) {
    for (final node in state.graph.nodes.values.toList().reversed) {
      final type = IspNodeRegistry.byId(node.typeId);
      final h = type == null
          ? 0.0
          : nodeHeight(type, previewExtraHeight: node.extraHeight);
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

    return LayoutBuilder(
      // 把视口尺寸同步给 state（「适配全屏」整体适配用）；纯字段，
      // 不触发重建。
      builder: (context, constraints) {
        state.canvasViewport = constraints.biggest;
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
          if (event.buttons & kPrimaryButton != 0) {
            final canvasPos = globalToCanvas(event.position);
            final titleNodeId = _nodeAt(state, canvasPos);
            _dragNodeId = titleNodeId;
            if (titleNodeId != null) {
              state.beginNodeDrag(titleNodeId);
              _boxSelectStartCanvasPos = null;
            } else {
              final cardNodeId = _nodeCardAt(state, canvasPos);
              if (cardNodeId == null) {
                _boxSelectStartCanvasPos = canvasPos;
              } else {
                _boxSelectStartCanvasPos = null;
              }
            }
          } else {
            _dragNodeId = null;
            _boxSelectStartCanvasPos = null;
          }
        },
        onPointerMove: (event) {
          if (event.buttons & kPrimaryButton != 0) {
            final id = _dragNodeId;
            if (id != null) {
              state.moveNode(id, event.delta / state.canvasZoom);
            } else if (_boxSelectStartCanvasPos != null) {
              final isMulti = HardwareKeyboard.instance.isShiftPressed ||
                  HardwareKeyboard.instance.isControlPressed ||
                  HardwareKeyboard.instance.isMetaPressed;
              final currentPos = globalToCanvas(event.position);
              state.updateBoxSelection(_boxSelectStartCanvasPos!, currentPos,
                  multiSelect: isMulti);
            }
          } else if (event.buttons & kSecondaryButton != 0) {
            state.panBy(event.delta);
          }
        },
        onPointerUp: (_) {
          if (_dragNodeId != null) {
            state.endNodeDrag();
            _dragNodeId = null;
          }
          if (_boxSelectStartCanvasPos != null) {
            state.endBoxSelection();
            _boxSelectStartCanvasPos = null;
          }
        },
        onPointerCancel: (_) {
          if (_dragNodeId != null) {
            state.endNodeDrag();
            _dragNodeId = null;
          }
          if (_boxSelectStartCanvasPos != null) {
            state.endBoxSelection();
            _boxSelectStartCanvasPos = null;
          }
        },
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
                          if (state.selectionBoxRect != null)
                            Positioned.fill(
                              child: CustomPaint(
                                painter:
                                    _SelectionBoxPainter(state.selectionBoxRect),
                              ),
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
                                selected: state.selectedNodeIds.contains(node.id),
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
      },
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

/// 屏幕空间点阵背景，基础间距 10 画布逻辑像素，每 10 格（100px 间隔）画一条
/// 主线（颜色与暗点一致），其余位置为暗灰点。缩小时按 2 的幂抽稀（步长 step），
/// 屏幕间距不低于 ~8px。
class _DotGridPainter extends CustomPainter {
  final Offset offset;
  final double zoom;

  _DotGridPainter(this.offset, this.zoom);

  @override
  void paint(Canvas canvas, Size size) {
    const gridSpacing = IspStudioState.kGridSize; // 10.0
    // 缩小时按 2 的幂抽稀格点，保证屏幕间距不低于 ~8px：间距过密时
    // 一帧要画几十万个点（0.25 倍缩放下 1920 宽视口约 33 万个），
    // 拖动平移每帧重绘直接打爆光栅线程；这个密度的点在视觉上也已
    // 糊成一片，抽稀不损失信息。
    var step = 1;
    var spacing = gridSpacing * zoom;
    while (spacing < 8) {
      step *= 2;
      spacing *= 2;
    }

    // 两点一批的 drawPoints 比逐点 drawCircle 快几个数量级；
    // StrokeCap.round 让小点仍呈圆形。
    final minorPoints = <Offset>[];
    final minorPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.08)
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;
    // 主线：每 10 格一条直线，颜色与暗点一致。
    final linePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.08)
      ..strokeWidth = 1.0;

    final startI = (-offset.dx / spacing).floor();
    final endI = ((size.width - offset.dx) / spacing).ceil();
    final startJ = (-offset.dy / spacing).floor();
    final endJ = ((size.height - offset.dy) / spacing).ceil();

    for (var i = startI; i <= endI; i++) {
      final x = offset.dx + i * spacing;
      if ((i * step) % 10 == 0) {
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), linePaint);
      }
    }
    for (var j = startJ; j <= endJ; j++) {
      final y = offset.dy + j * spacing;
      if ((j * step) % 10 == 0) {
        canvas.drawLine(Offset(0, y), Offset(size.width, y), linePaint);
      }
    }
    // 落在主线上的点被线覆盖，跳过不画。
    for (var i = startI; i <= endI; i++) {
      final x = offset.dx + i * spacing;
      final onMajorX = (i * step) % 10 == 0;
      for (var j = startJ; j <= endJ; j++) {
        if (onMajorX || (j * step) % 10 == 0) continue;
        minorPoints.add(Offset(x, offset.dy + j * spacing));
      }
    }
    canvas.drawPoints(ui.PointMode.points, minorPoints, minorPaint);
  }

  @override
  bool shouldRepaint(_DotGridPainter oldDelegate) =>
      oldDelegate.offset != offset || oldDelegate.zoom != zoom;
}

/// 画布坐标系下的框选矩形绘制（半透明蓝色填充 + 蓝边）。
class _SelectionBoxPainter extends CustomPainter {
  final Rect? rect;

  _SelectionBoxPainter(this.rect);

  @override
  void paint(Canvas canvas, Size size) {
    final r = rect;
    if (r == null) return;
    final fillPaint = Paint()
      ..color = const Color(0x252196F3)
      ..style = PaintingStyle.fill;
    final borderPaint = Paint()
      ..color = const Color(0xFF2196F3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    canvas.drawRect(r, fillPaint);
    canvas.drawRect(r, borderPaint);
  }

  @override
  bool shouldRepaint(_SelectionBoxPainter oldDelegate) => oldDelegate.rect != rect;
}
