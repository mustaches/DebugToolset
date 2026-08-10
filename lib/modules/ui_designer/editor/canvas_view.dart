import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../../providers/ui_designer_state.dart';
import '../models/ui_page.dart';
import '../models/ui_widget.dart';
import 'widget_renderer.dart';

/// The design canvas: renders the current page at a scaled size and
/// handles selection, dragging, resizing, marquee selection and keyboard
/// shortcuts in edit mode; routes interactions to the simulator in
/// preview mode.
class CanvasView extends StatefulWidget {
  const CanvasView({super.key});

  @override
  State<CanvasView> createState() => _CanvasViewState();
}

class _CanvasViewState extends State<CanvasView> {
  final FocusNode _keyFocus = FocusNode();

  // 显式滚动控制器：水平滚动视图不会注册为 PrimaryScrollController，
  // 不给 Scrollbar 显式控制器时，底部水平滚动条只能显示、不能拖动。
  final ScrollController _hScrollController = ScrollController();
  final ScrollController _vScrollController = ScrollController();

  // Marquee selection.
  Offset? _marqueeStart;
  Offset? _marqueeCurrent;

  // Move drag.
  Map<String, Rect> _dragOrigins = {};
  Offset _dragDelta = Offset.zero;

  // Resize drag: handle index 0..7 (NW N NE E SE S SW W).
  String? _resizeId;
  int _resizeHandle = -1;
  Rect _resizeOrigin = Rect.zero;
  Offset _resizeDelta = Offset.zero;

  @override
  void dispose() {
    _keyFocus.dispose();
    _hScrollController.dispose();
    _vScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<UiDesignerState>();
    final page = state.currentPage;
    if (page == null) {
      return const Center(child: Text('没有页面'));
    }

    final logicalW = state.project.screenWidth.toDouble();
    final logicalH = state.project.screenHeight.toDouble();

    return LayoutBuilder(
      builder: (context, constraints) {
        final widthFit = (constraints.maxWidth - 40) / logicalW;
        final heightFit = (constraints.maxHeight - 40) / logicalH;
        final fit = math.min(widthFit, heightFit).clamp(0.05, 8.0).toDouble();
        final scale = state.zoom == 0 ? fit : state.zoom;

        final canvas = SizedBox(
          width: logicalW * scale,
          height: logicalH * scale,
          // 松开 SizedBox 的紧约束，让画布表面保持逻辑尺寸；
          // 否则表面先被拉伸到 scale 倍，再被 Transform 放大一次，
          // 视觉上变成 scale²，右侧和下方溢出工作区。
          // 用 OverflowBox 而非 UnconstrainedBox：scale < 1 时逻辑
          // 表面比占位盒大，UnconstrainedBox 会报溢出错误。
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: 0,
            maxWidth: double.infinity,
            minHeight: 0,
            maxHeight: double.infinity,
            child: Transform.scale(
              scale: scale,
              alignment: Alignment.topLeft,
              child:
                  _buildCanvasSurface(state, page, logicalW, logicalH, scale),
            ),
          ),
        );

        return Container(
          color: const Color(0xFF1B1B1B),
          // 滚动条钉在视口右/下边缘，且作为 Stack 后绘制的兄弟节点，
          // 拖动手势在竞技场中优先于画布的框选/拖动。
          child: Stack(
            children: [
              SingleChildScrollView(
                controller: _vScrollController,
                child: SingleChildScrollView(
                  controller: _hScrollController,
                  scrollDirection: Axis.horizontal,
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: canvas,
                  ),
                ),
              ),
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                child: SizedBox(
                  width: 8,
                  child: _CanvasScrollBar(
                    key: const Key('canvas_v_scrollbar'),
                    controller: _vScrollController,
                    axis: Axis.vertical,
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: SizedBox(
                  height: 8,
                  child: _CanvasScrollBar(
                    key: const Key('canvas_h_scrollbar'),
                    controller: _hScrollController,
                    axis: Axis.horizontal,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCanvasSurface(UiDesignerState state, UiPage page, double w,
      double h, double scale) {
    return Focus(
      focusNode: _keyFocus,
      autofocus: true,
      onKeyEvent: _onKeyEvent,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: state.previewMode ? null : () => state.clearSelection(),
        onPanStart: state.previewMode ? null : _onMarqueeStart,
        onPanUpdate: state.previewMode ? null : _onMarqueeUpdate,
        onPanEnd: state.previewMode ? null : _onMarqueeEnd,
        child: Container(
          width: w,
          height: h,
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey.shade700),
          ),
          child: ClipRect(
            child: Stack(
              children: [
                Positioned.fill(
                    child: _buildPageBackground(state, page)),
                if (!state.previewMode && state.snapEnabled)
                  CustomPaint(
                    size: Size(w, h),
                    painter: _GridPainter(state.gridSize.toDouble()),
                  ),
                if (state.previewMode && state.transitionFrom != null)
                  _buildTransition(
                      state, state.transitionFrom!, page, w, h)
                else
                  for (final widget in page.widgets)
                    _buildWidgetWrapper(state, widget, scale),
                if (!state.previewMode)
                  for (final id in state.selectedIds)
                    if (page.widgetById(id) != null)
                      _buildSelectionOverlay(
                          state, page.widgetById(id)!, scale),
                if (_marqueeStart != null && _marqueeCurrent != null)
                  Positioned.fromRect(
                    rect: Rect.fromPoints(_marqueeStart!, _marqueeCurrent!),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.cyanAccent.withValues(alpha: 0.1),
                        border: Border.all(
                            color: Colors.cyanAccent.withValues(alpha: 0.7)),
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

  /// Page background: solid color, a screen-size image asset, or a video
  /// placeholder (the designer does not play video; on firmware the OSD
  /// is drawn over the live stream).
  Widget _buildPageBackground(UiDesignerState state, UiPage page) {
    switch (page.bgType) {
      case 'image':
        final asset = page.bgAssetId == null
            ? null
            : state.project.assetById(page.bgAssetId!);
        final path = asset == null ? null : state.resolveAssetPath(asset);
        if (path != null && File(path).existsSync()) {
          final image = Image.file(
            File(path),
            fit: BoxFit.fill,
            errorBuilder: (_, _, _) => _bgFallback(page, '背景图片加载失败'),
          );
          if (page.bgAnim != 'none') {
            return _AnimatedBg(mode: page.bgAnim, child: image);
          }
          return image;
        }
        return _bgFallback(page, '未设置背景图片', icon: Icons.image);
      case 'video':
        return _bgFallback(
          page,
          page.bgVideoPath == null
              ? '未设置背景视频'
              : '视频背景: ${p.basename(page.bgVideoPath!)}',
          icon: Icons.play_circle_outline,
        );
      default:
        return Container(color: Color(page.bgColor));
    }
  }

  Widget _bgFallback(UiPage page, String hint, {IconData? icon}) {
    return Container(
      color: Color(page.bgColor),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null)
              Icon(icon, color: Colors.grey, size: 32),
            Text(hint,
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------------
  // Page transitions (preview)
  // ------------------------------------------------------------------

  /// Static (non-interactive) render of a page, used by transitions.
  Widget _buildStaticPage(
      UiDesignerState state, UiPage page, double w, double h) {
    return SizedBox(
      width: w,
      height: h,
      child: Stack(
        children: [
          Positioned.fill(child: _buildPageBackground(state, page)),
          for (final widget in page.widgets)
            Positioned.fromRect(
              rect: widget.rect,
              child: IgnorePointer(
                child: UiWidgetContent(
                  model: widget,
                  preview: true,
                  runtimeValue: state.runtimeValues[widget.id],
                  pressed: state.pressedWidgetId == widget.id,
                  focused: state.focusedWidgetId == widget.id,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Both pages composited with the active transition effect.
  Widget _buildTransition(UiDesignerState state, UiPage from, UiPage to,
      double w, double h) {
    final t = Curves.easeInOut.transform(state.transitionT);
    final fromPage = _buildStaticPage(state, from, w, h);
    final toPage = _buildStaticPage(state, to, w, h);
    switch (state.transitionType) {
      case 'slideLeft':
        return Stack(children: [
          Transform.translate(offset: Offset(-w * t, 0), child: fromPage),
          Transform.translate(offset: Offset(w * (1 - t), 0), child: toPage),
        ]);
      case 'slideRight':
        return Stack(children: [
          Transform.translate(offset: Offset(w * t, 0), child: fromPage),
          Transform.translate(offset: Offset(-w * (1 - t), 0), child: toPage),
        ]);
      case 'pushLeft':
        return Stack(children: [
          fromPage,
          Transform.translate(offset: Offset(w * (1 - t), 0), child: toPage),
        ]);
      case 'fade':
        return Stack(children: [
          fromPage,
          Opacity(opacity: t, child: toPage),
        ]);
      case 'cube':
        final persp = Matrix4.identity()..setEntry(3, 2, 0.0012);
        return Stack(children: [
          Transform(
            transform: persp.clone()..rotateY(-math.pi / 2 * t),
            alignment: Alignment.center,
            child: fromPage,
          ),
          Transform(
            transform: persp.clone()..rotateY(math.pi / 2 * (1 - t)),
            alignment: Alignment.center,
            child: toPage,
          ),
        ]);
      default:
        return toPage;
    }
  }

  // ------------------------------------------------------------------
  // Widget wrappers
  // ------------------------------------------------------------------

  Widget _buildWidgetWrapper(
      UiDesignerState state, UiWidgetModel w, double scale) {
    final selected = state.selectedIds.contains(w.id);
    if (state.previewMode) {
      return Positioned.fromRect(
        rect: w.rect,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => state.previewTap(w),
          onTapDown: (_) => state.previewPressDown(w),
          onTapUp: (_) => state.previewPressUp(),
          onTapCancel: () => state.previewPressUp(),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: AnimatedScale(
              scale: state.pressedWidgetId == w.id ? 0.92 : 1.0,
              duration: const Duration(milliseconds: 120),
              child: UiWidgetContent(
                model: w,
                preview: true,
                runtimeValue: state.runtimeValues[w.id],
                pressed: state.pressedWidgetId == w.id,
                focused: state.focusedWidgetId == w.id,
                onSliderChanged: (v) => state.previewSetValue(w, v.round()),
                onListSelected: (i) => state.previewSetValue(w, i),
              ),
            ),
          ),
        ),
      );
    }
    return Positioned.fromRect(
      rect: w.rect,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (details) {
          _keyFocus.requestFocus();
          final ctrl = HardwareKeyboard.instance.isControlPressed ||
              HardwareKeyboard.instance.isMetaPressed;
          final state = context.read<UiDesignerState>();
          if (ctrl) {
            state.toggleSelected(w.id);
          } else if (!state.selectedIds.contains(w.id)) {
            state.setSelection([w.id]);
          }
        },
        onSecondaryTapDown: (details) => _showContextMenu(state, w, details),
        onPanStart: (_) => _startMove(state),
        onPanUpdate: (d) => _updateMove(state, d.delta),
        onPanEnd: (_) => _endMove(state),
        child: IgnorePointer(
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(
                color: selected ? Colors.cyanAccent : Colors.transparent,
              ),
            ),
            child: UiWidgetContent(model: w),
          ),
        ),
      ),
    );
  }

  Widget _buildSelectionOverlay(
      UiDesignerState state, UiWidgetModel w, double scale) {
    final handleSize = 7.0 / scale;
    final centers = <Offset>[
      w.rect.topLeft,
      w.rect.topCenter,
      w.rect.topRight,
      w.rect.centerRight,
      w.rect.bottomRight,
      w.rect.bottomCenter,
      w.rect.bottomLeft,
      w.rect.centerLeft,
    ];
    return Stack(
      children: [
        for (var i = 0; i < 8; i++)
          Positioned(
            left: centers[i].dx - handleSize / 2,
            top: centers[i].dy - handleSize / 2,
            width: handleSize,
            height: handleSize,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) {
                debugPrint('[resize] start handle=$i');
                _startResize(w, i);
              },
              onPanUpdate: (d) => _updateResize(state, d.delta),
              onPanEnd: (_) {
                debugPrint('[resize] end handle=$i');
                _endResize(state);
              },
              onPanCancel: () => debugPrint('[resize] CANCEL handle=$i'),
              child: MouseRegion(
                cursor: _handleCursor(i),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(color: Colors.cyanAccent),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  MouseCursor _handleCursor(int i) {
    switch (i) {
      case 0:
      case 4:
        return SystemMouseCursors.resizeUpLeftDownRight;
      case 2:
      case 6:
        return SystemMouseCursors.resizeUpRightDownLeft;
      case 1:
      case 5:
        return SystemMouseCursors.resizeUpDown;
      default:
        return SystemMouseCursors.resizeLeftRight;
    }
  }

  // ------------------------------------------------------------------
  // Move
  // ------------------------------------------------------------------

  void _startMove(UiDesignerState state) {
    final page = state.currentPage;
    if (page == null) return;
    state.beginMove();
    _dragOrigins = {
      for (final id in state.selectedIds)
        if (page.widgetById(id) != null) id: page.widgetById(id)!.rect,
    };
    _dragDelta = Offset.zero;
  }

  void _updateMove(UiDesignerState state, Offset delta) {
    if (_dragOrigins.isEmpty) return;
    _dragDelta += delta;
    final page = state.currentPage;
    if (page == null) return;
    for (final e in _dragOrigins.entries) {
      final w = page.widgetById(e.key);
      if (w == null) continue;
      final moved = e.value.translate(_dragDelta.dx, _dragDelta.dy);
      final snapped = state.snapEnabled
          ? Rect.fromLTWH(
              (moved.left / state.gridSize).round() *
                  state.gridSize.toDouble(),
              (moved.top / state.gridSize).round() * state.gridSize.toDouble(),
              moved.width,
              moved.height)
          : moved;
      w.setRect(snapped);
    }
    state.notifyMove();
  }

  void _endMove(UiDesignerState state) {
    if (_dragOrigins.isEmpty) return;
    _dragOrigins = {};
    _dragDelta = Offset.zero;
    state.commitMove();
  }

  // ------------------------------------------------------------------
  // Resize
  // ------------------------------------------------------------------

  void _startResize(UiWidgetModel w, int handle) {
    context.read<UiDesignerState>().beginMove();
    _resizeId = w.id;
    _resizeHandle = handle;
    _resizeOrigin = w.rect;
    _resizeDelta = Offset.zero;
  }

  void _updateResize(UiDesignerState state, Offset delta) {
    final id = _resizeId;
    if (id == null) {
      debugPrint('[resize] update arrived with null id (state lost)');
      return;
    }
    final w = state.currentPage?.widgetById(id);
    if (w == null) return;
    // onPanUpdate 的 delta 是单帧增量，必须累加后再作用于起始矩形，
    // 否则矩形每帧只移动一个增量、无法跟随鼠标。
    _resizeDelta += delta;
    delta = _resizeDelta;
    var l = _resizeOrigin.left, t = _resizeOrigin.top;
    var r = _resizeOrigin.right, b = _resizeOrigin.bottom;
    final i = _resizeHandle;
    if (i == 0 || i == 6 || i == 7) l += delta.dx;
    if (i == 2 || i == 3 || i == 4) r += delta.dx;
    if (i == 0 || i == 1 || i == 2) t += delta.dy;
    if (i == 4 || i == 5 || i == 6) b += delta.dy;
    const minSize = 4.0;
    if (r - l < minSize) {
      if (i == 0 || i == 6 || i == 7) {
        l = r - minSize;
      } else {
        r = l + minSize;
      }
    }
    if (b - t < minSize) {
      if (i == 0 || i == 1 || i == 2) {
        t = b - minSize;
      } else {
        b = t + minSize;
      }
    }
    w.setRect(Rect.fromLTRB(l, t, r, b));
    state.notifyMove();
  }

  void _endResize(UiDesignerState state) {
    _resizeId = null;
    _resizeDelta = Offset.zero;
    state.commitMove();
  }

  // ------------------------------------------------------------------
  // Marquee selection
  // ------------------------------------------------------------------

  void _onMarqueeStart(DragStartDetails d) {
    setState(() {
      _marqueeStart = d.localPosition;
      _marqueeCurrent = d.localPosition;
    });
  }

  void _onMarqueeUpdate(DragUpdateDetails d) {
    setState(() => _marqueeCurrent = d.localPosition);
  }

  void _onMarqueeEnd(DragEndDetails d) {
    final state = context.read<UiDesignerState>();
    final start = _marqueeStart, end = _marqueeCurrent;
    setState(() {
      _marqueeStart = null;
      _marqueeCurrent = null;
    });
    if (start == null || end == null) return;
    final rect = Rect.fromPoints(start, end);
    if (rect.width < 3 && rect.height < 3) return;
    final page = state.currentPage;
    if (page == null) return;
    state.setSelection([
      for (final w in page.widgets)
        if (rect.overlaps(w.rect)) w.id,
    ]);
  }

  // ------------------------------------------------------------------
  // Context menu / keyboard
  // ------------------------------------------------------------------

  void _showContextMenu(
      UiDesignerState state, UiWidgetModel w, TapDownDetails d) {
    if (!state.selectedIds.contains(w.id)) state.setSelection([w.id]);
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
          d.globalPosition.dx, d.globalPosition.dy, d.globalPosition.dx, 0),
      items: const [
        PopupMenuItem(value: 'copy', child: Text('复制')),
        PopupMenuItem(value: 'paste', child: Text('粘贴')),
        PopupMenuItem(value: 'front', child: Text('置于顶层')),
        PopupMenuItem(value: 'back', child: Text('置于底层')),
        PopupMenuItem(value: 'delete', child: Text('删除')),
      ],
    ).then((v) {
      switch (v) {
        case 'copy':
          state.copySelected();
        case 'paste':
          state.paste();
        case 'front':
          state.reorderSelected(front: true);
        case 'back':
          state.reorderSelected(front: false);
        case 'delete':
          state.deleteSelected();
      }
    });
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final state = context.read<UiDesignerState>();
    // Preview mode: OSD remote keys — arrows move focus / adjust values,
    // Enter/Space activates, Esc clears focus.
    if (state.previewMode) {
      final dir = switch (event.logicalKey) {
        LogicalKeyboardKey.arrowUp => UiNavDirection.up,
        LogicalKeyboardKey.arrowDown => UiNavDirection.down,
        LogicalKeyboardKey.arrowLeft => UiNavDirection.left,
        LogicalKeyboardKey.arrowRight => UiNavDirection.right,
        _ => null,
      };
      if (dir != null) {
        state.previewNavKey(dir);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.enter ||
          event.logicalKey == LogicalKeyboardKey.space) {
        state.previewActivate();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        state.previewClearFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    final ctrl = HardwareKeyboard.instance.isControlPressed;

    if (ctrl && event.logicalKey == LogicalKeyboardKey.keyZ) {
      state.undo();
      return KeyEventResult.handled;
    }
    if (ctrl && event.logicalKey == LogicalKeyboardKey.keyY) {
      state.redo();
      return KeyEventResult.handled;
    }
    if (ctrl && event.logicalKey == LogicalKeyboardKey.keyC) {
      state.copySelected();
      return KeyEventResult.handled;
    }
    if (ctrl && event.logicalKey == LogicalKeyboardKey.keyV) {
      state.paste();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.delete) {
      state.deleteSelected();
      return KeyEventResult.handled;
    }

    final step = HardwareKeyboard.instance.isShiftPressed
        ? state.gridSize.toDouble()
        : 1.0;
    Offset? delta;
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      delta = Offset(-step, 0);
    } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      delta = Offset(step, 0);
    } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      delta = Offset(0, -step);
    } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      delta = Offset(0, step);
    }
    if (delta != null && state.selectedIds.isNotEmpty) {
      state.nudgeSelected(delta);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }
}

/// A thin scrollbar strip pinned to a viewport edge.
///
/// The framework [Scrollbar] does not work for this 2D canvas: as an
/// ancestor of the scrollables its drag recognizer loses the gesture
/// arena to the canvas pan gestures (first member wins), and detached
/// from the scrollable it never receives scroll metrics. This widget
/// reads the [ScrollController] position directly and scrolls on drag.
class _CanvasScrollBar extends StatelessWidget {
  const _CanvasScrollBar({
    super.key,
    required this.controller,
    required this.axis,
  });

  final ScrollController controller;
  final Axis axis;

  bool get _horizontal => axis == Axis.horizontal;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return LayoutBuilder(
          builder: (context, constraints) {
            final track =
                _horizontal ? constraints.maxWidth : constraints.maxHeight;
            final pos = controller.hasClients ? controller.position : null;
            final ready = pos != null &&
                pos.hasViewportDimension &&
                pos.hasContentDimensions &&
                pos.maxScrollExtent > 0 &&
                track > 0;

            var thumbLen = track;
            var thumbOffset = 0.0;
            var ratio = 1.0;
            if (ready) {
              final content = pos.maxScrollExtent + pos.viewportDimension;
              thumbLen = (track * pos.viewportDimension / content)
                  .clamp(24.0, track);
              final movable = track - thumbLen;
              thumbOffset =
                  movable * (pos.pixels / pos.maxScrollExtent).clamp(0.0, 1.0);
              ratio = movable > 0 ? pos.maxScrollExtent / movable : 1.0;
            }

            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragUpdate: _horizontal && ready
                  ? (d) => _dragBy(d.delta.dx * ratio)
                  : null,
              onVerticalDragUpdate: !_horizontal && ready
                  ? (d) => _dragBy(d.delta.dy * ratio)
                  : null,
              child: Stack(
                children: [
                  Positioned(
                    left: _horizontal ? thumbOffset : 0,
                    top: _horizontal ? 0 : thumbOffset,
                    right: _horizontal ? null : 0,
                    bottom: _horizontal ? 0 : null,
                    width: _horizontal ? thumbLen : null,
                    height: _horizontal ? null : thumbLen,
                    child: Container(
                      margin: const EdgeInsets.all(1),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade600,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _dragBy(double scrollDelta) {
    if (!controller.hasClients) return;
    final pos = controller.position;
    pos.jumpTo((pos.pixels + scrollDelta).clamp(0.0, pos.maxScrollExtent));
  }
}

/// Animated image background: 'kenburns' = slow push-in/pan loop,
/// 'parallax' = gentle horizontal drift.
class _AnimatedBg extends StatefulWidget {
  const _AnimatedBg({required this.mode, required this.child});

  final String mode;
  final Widget child;

  @override
  State<_AnimatedBg> createState() => _AnimatedBgState();
}

class _AnimatedBgState extends State<_AnimatedBg>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: Duration(seconds: widget.mode == 'kenburns' ? 12 : 8),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final t = Curves.easeInOut.transform(_ctrl.value);
        if (widget.mode == 'kenburns') {
          return Transform.scale(
            scale: 1.0 + 0.18 * t,
            alignment: Alignment.lerp(
                Alignment.topLeft, Alignment.bottomRight, t)!,
            child: widget.child,
          );
        }
        // Parallax: slight overscan + horizontal drift.
        return Transform.scale(
          scale: 1.12,
          child: Transform.translate(
            offset: Offset((t * 2 - 1) * 18, 0),
            child: widget.child,
          ),
        );
      },
    );
  }
}

class _GridPainter extends CustomPainter {  _GridPainter(this.grid);

  final double grid;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0x14FFFFFF)
      ..strokeWidth = 0.5;
    for (double x = grid; x < size.width; x += grid) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = grid; y < size.height; y += grid) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) => old.grid != grid;
}
