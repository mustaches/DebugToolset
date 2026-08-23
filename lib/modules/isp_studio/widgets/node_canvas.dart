/// ISP Studio 无限画布：点阵背景、平移缩放、连线落点命中、键盘删除。
library;

import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../providers/isp_studio_state.dart';
import '../models/isp_graph.dart';
import '../models/isp_node.dart';
import 'connection_painter.dart';
import 'node_layout.dart';
import 'node_widget.dart';

/// 编组名显示带的高度（包围框顶部向上延伸的净空区，保证组名不被
/// 成员节点遮挡；连线在框下层绘制，名字带内衬底后同样遮不住）。
const double kGroupNameStripHeight = 16;

/// 编组包围框（成员节点包围盒外扩 8px，顶部再向上延伸组名显示带）：
/// painter 与命中测试共用。
Rect? ispGroupBounds(IspGraph graph, IspNodeGroup group) {
  Rect? bounds;
  for (final id in group.nodeIds) {
    final node = graph.nodes[id];
    if (node == null) continue;
    final type = IspNodeRegistry.byId(node.typeId);
    final h = type == null
        ? 0.0
        : nodeHeight(type, previewExtraHeight: node.extraHeight);
    final r = Rect.fromLTWH(node.x, node.y, node.width, h);
    bounds = bounds == null ? r : bounds.expandToInclude(r);
  }
  if (bounds == null) return null;
  var r = bounds.inflate(8);
  if (group.name.isNotEmpty) {
    r = Rect.fromLTRB(
        r.left, r.top - kGroupNameStripHeight, r.right, r.bottom);
  }
  return r;
}

/// 编组命名对话框：预填默认名「编组#N」，确定后以该名编组当前多选
/// 节点（空名回退默认名）。工具栏编组按钮与节点右键菜单「编组」共用。
Future<void> showIspGroupNamingDialog(
    BuildContext context, IspStudioState state) async {
  final controller =
      TextEditingController(text: state.graph.uniqueGroupName());
  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF2E2E2E),
      title: const Text('编组命名',
          style: TextStyle(color: Colors.white, fontSize: 14)),
      content: TextField(
        controller: controller,
        autofocus: true,
        style: const TextStyle(color: Colors.white),
        decoration: const InputDecoration(hintText: '编组名'),
        onSubmitted: (v) => Navigator.of(ctx).pop(v),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消')),
        TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('确定')),
      ],
    ),
  );
  final trimmed = name?.trim();
  if (trimmed != null) {
    state.groupSelectedNodes(name: trimmed.isEmpty ? null : trimmed);
  }
}

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
      return;
    }
    // 编组框内单击：选中整组（而不是清空选择）。
    final hitGroup = _groupAt(state, pos);
    if (hitGroup != null) {
      state.selectNode(hitGroup.nodeIds.first);
      return;
    }
    state.selectNode(null);
    state.selectConnection(null);
  }

  /// 画布坐标下的编组框命中（后建组优先）：框内左键拖动整个编组。
  IspNodeGroup? _groupAt(IspStudioState state, Offset canvasPos) {
    for (final g in state.graph.groups.reversed) {
      final bounds = ispGroupBounds(state.graph, g);
      if (bounds != null && bounds.contains(canvasPos)) return g;
    }
    return null;
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
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final state = context.read<IspStudioState>();
    final ctrl = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    // Ctrl/Cmd+C 复制选中节点，Ctrl/Cmd+V 粘贴（级联偏移）。
    if (ctrl && event.logicalKey == LogicalKeyboardKey.keyC) {
      state.copySelectedNodes();
      return KeyEventResult.handled;
    }
    if (ctrl && event.logicalKey == LogicalKeyboardKey.keyV) {
      state.pasteNodes();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.delete ||
        event.logicalKey == LogicalKeyboardKey.backspace) {
      state.removeSelected();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 节点标题栏右键菜单：多选时点中选中节点提供「编组」；点中已编组
  /// 节点提供「取消编组」。其余情况不弹菜单（保留右键拖动平移画布）。
  void _showNodeGroupMenu(
      IspStudioState state, String nodeId, Offset globalPos) {
    final groupId = state.groupIdOf(nodeId);
    final canGroup = groupId == null &&
        state.selectedNodeIds.length >= 2 &&
        state.selectedNodeIds.contains(nodeId);
    if (groupId == null && !canGroup) return;
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
          globalPos.dx, globalPos.dy, globalPos.dx, globalPos.dy),
      items: [
        if (canGroup)
          const PopupMenuItem(value: 'group', child: Text('编组')),
        if (groupId != null)
          const PopupMenuItem(value: 'ungroup', child: Text('取消编组')),
      ],
    ).then((v) {
      if (!mounted) return;
      if (v == 'group') {
        // 弹命名对话框（默认「编组#N」）后编组。
        showIspGroupNamingDialog(context, state);
      } else if (v == 'ungroup' && groupId != null) {
        state.ungroup(groupId);
      }
    });
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
                // 编组框内（未命中任何节点卡片）左键：选中并拖动整个
                // 编组，框选让位于编组拖动。
                final group = _groupAt(state, canvasPos);
                if (group != null) {
                  final member = group.nodeIds.first;
                  state.selectNode(member); // 编组联动：全选整组
                  state.beginNodeDrag(member);
                  _dragNodeId = member;
                  _boxSelectStartCanvasPos = null;
                } else {
                  _boxSelectStartCanvasPos = canvasPos;
                }
              } else {
                _boxSelectStartCanvasPos = null;
              }
            }
          } else {
            _dragNodeId = null;
            _boxSelectStartCanvasPos = null;
            if (event.buttons & kSecondaryButton != 0) {
              // 标题栏右键：编组/取消编组菜单。
              final titleNodeId = _nodeAt(state, globalToCanvas(event.position));
              if (titleNodeId != null) {
                _showNodeGroupMenu(state, titleNodeId, event.position);
              }
            }
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
                          // 编组包围框（连线之上、节点之下，不参与命中）。
                          if (state.graph.groups.isNotEmpty)
                            Positioned.fill(
                              child: CustomPaint(
                                painter: _GroupFramesPainter(state),
                              ),
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

/// 编组包围框：成员节点包围盒外扩一圈（顶部额外延伸组名显示带）的
/// 圆角矩形（半透明填充 + 描边），与框选蓝色区分用青绿色。节点拖动/
/// 缩放时画布整体重建，此处 shouldRepaint 恒真即可。
class _GroupFramesPainter extends CustomPainter {
  final IspStudioState state;

  _GroupFramesPainter(this.state);

  @override
  void paint(Canvas canvas, Size size) {
    for (final g in state.graph.groups) {
      final bounds = ispGroupBounds(state.graph, g);
      if (bounds == null) continue;
      final rrect =
          RRect.fromRectAndRadius(bounds, const Radius.circular(8));
      canvas.drawRRect(
          rrect,
          Paint()
            ..color = const Color(0x1426A69A)
            ..style = PaintingStyle.fill);
      canvas.drawRRect(
          rrect,
          Paint()
            ..color = const Color(0xFF26A69A)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5);
      // 编组名：框左上角的名字带内（包围盒已在顶部延伸净空），带不透明
      // 衬底防止连线干扰阅读；随框移动（画布坐标系绘制）。
      if (g.name.isNotEmpty) {
        final tp = TextPainter(
          text: TextSpan(
              text: g.name,
              style: const TextStyle(
                  color: Color(0xFF26A69A), fontSize: 11, height: 1.0)),
          textDirection: TextDirection.ltr,
        )..layout();
        final textPos = bounds.topLeft + const Offset(8, 2.5);
        canvas.drawRect(
            Rect.fromLTWH(textPos.dx - 2, textPos.dy - 1,
                tp.width + 4, tp.height + 2),
            Paint()..color = const Color(0xFF1E1E1E));
        tp.paint(canvas, textPos);
      }
    }
  }

  @override
  bool shouldRepaint(_GroupFramesPainter oldDelegate) => true;
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
