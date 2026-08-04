import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  @override
  void dispose() {
    _keyFocus.dispose();
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
          child: Transform.scale(
            scale: scale,
            alignment: Alignment.topLeft,
            child: _buildCanvasSurface(state, page, logicalW, logicalH, scale),
          ),
        );

        return Container(
          color: const Color(0xFF1B1B1B),
          child: Scrollbar(
            thumbVisibility: true,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Scrollbar(
                thumbVisibility: true,
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: canvas,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildCanvasSurface(UiDesignerState state, UiPage page, double w,
      double h, double scale) {
    final pageBg = Color(page.bgColor);
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
            color: pageBg,
            border: Border.all(color: Colors.grey.shade700),
          ),
          child: ClipRect(
            child: Stack(
              children: [
                if (!state.previewMode && state.snapEnabled)
                  CustomPaint(
                    size: Size(w, h),
                    painter: _GridPainter(state.gridSize.toDouble()),
                  ),
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
              onPanStart: (_) => _startResize(w, i),
              onPanUpdate: (d) => _updateResize(state, d.delta),
              onPanEnd: (_) => _endResize(state),
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
  }

  void _updateResize(UiDesignerState state, Offset delta) {
    final id = _resizeId;
    if (id == null) return;
    final w = state.currentPage?.widgetById(id);
    if (w == null) return;
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
    if (state.previewMode) return KeyEventResult.ignored;
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

class _GridPainter extends CustomPainter {
  _GridPainter(this.grid);

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
