import 'package:flutter/material.dart';
import '../models/hex_file_data.dart';

class HexMinimap extends StatelessWidget {
  final ScrollController scrollController;
  final HexFileData file;
  final Set<int> mismatchRows;
  final List<int> sortedMismatchRows;
  final bool alignAbs;
  final int rowCount;

  const HexMinimap({
    super.key,
    required this.scrollController,
    required this.file,
    required this.mismatchRows,
    required this.sortedMismatchRows,
    required this.alignAbs,
    required this.rowCount,
  });

  void _scrollToPosition(double localY, double maxHeight) {
    if (!scrollController.hasClients || maxHeight <= 0) return;
    final pos = scrollController.position;

    final double totalContentHeight = pos.maxScrollExtent + pos.viewportDimension;

    // Proportional target scroll offset: Y ratio * total height minus half of viewport height to center the clicked area
    final double ratio = localY / maxHeight;
    double targetOffset = ratio * totalContentHeight - (pos.viewportDimension / 2);
    targetOffset = targetOffset.clamp(0.0, pos.maxScrollExtent);

    scrollController.jumpTo(targetOffset);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanUpdate: (details) {
        final box = context.findRenderObject() as RenderBox?;
        if (box != null) {
          _scrollToPosition(details.localPosition.dy, box.size.height);
        }
      },
      onTapDown: (details) {
        final box = context.findRenderObject() as RenderBox?;
        if (box != null) {
          _scrollToPosition(details.localPosition.dy, box.size.height);
        }
      },
      child: Container(
        width: 21,
        decoration: const BoxDecoration(
          color: Color(0xFF1A1A1A),
          border: Border(left: BorderSide(color: Color(0xFF2A2A2A), width: 1)),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Static mismatch ticks layer: only repaints when data changes.
            CustomPaint(
              size: Size.infinite,
              painter: _MinimapTicksPainter(
                sortedMismatchRows: sortedMismatchRows,
                rowCount: rowCount,
              ),
            ),
            // Dynamic viewport tracker layer: only this repaints while scrolling.
            AnimatedBuilder(
              animation: scrollController,
              builder: (context, child) {
                if (!scrollController.hasClients || rowCount <= 0) {
                  return const SizedBox.shrink();
                }

                final pos = scrollController.position;
                if (!pos.hasContentDimensions) {
                  return const SizedBox.shrink();
                }

                return CustomPaint(
                  size: Size.infinite,
                  painter: _MinimapViewportPainter(
                    scrollOffset: pos.pixels,
                    viewportDimension: pos.viewportDimension,
                    maxScrollExtent: pos.maxScrollExtent,
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Paints mismatch tick marks. This painter is static and does not depend on
/// scroll offset, so it is not rebuilt during scrolling.
class _MinimapTicksPainter extends CustomPainter {
  final List<int> sortedMismatchRows;
  final int rowCount;

  _MinimapTicksPainter({
    required this.sortedMismatchRows,
    required this.rowCount,
  });

  bool _hasValueInRange(List<int> sortedList, int start, int end) {
    if (sortedList.isEmpty) return false;
    int minIdx = 0;
    int maxIdx = sortedList.length - 1;
    while (minIdx <= maxIdx) {
      final int mid = (minIdx + maxIdx) ~/ 2;
      final int val = sortedList[mid];
      if (val >= start && val <= end) {
        return true;
      } else if (val < start) {
        minIdx = mid + 1;
      } else {
        maxIdx = mid - 1;
      }
    }
    return false;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (rowCount <= 0 || sortedMismatchRows.isEmpty) return;

    final Paint tickPaint = Paint()
      ..color = Colors.redAccent.withValues(alpha: 0.8)
      ..strokeWidth = 1.5;

    for (double y = 0; y < size.height; y += 1.0) {
      // Determine the row index range corresponding to this single vertical pixel slice
      final int rowStart = ((y / size.height) * rowCount).floor();
      final int rowEnd = (((y + 1) / size.height) * rowCount).floor();

      // Perform O(log M) binary search range query instead of O(M) loop
      if (_hasValueInRange(sortedMismatchRows, rowStart, rowEnd)) {
        canvas.drawLine(Offset(1, y), Offset(size.width - 1, y), tickPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _MinimapTicksPainter oldDelegate) {
    return oldDelegate.sortedMismatchRows.length != sortedMismatchRows.length ||
        oldDelegate.rowCount != rowCount;
  }
}

/// Paints the viewport tracker. This painter only depends on scroll position,
/// so it is the only layer repainted during scrolling.
class _MinimapViewportPainter extends CustomPainter {
  final double scrollOffset;
  final double viewportDimension;
  final double maxScrollExtent;

  _MinimapViewportPainter({
    required this.scrollOffset,
    required this.viewportDimension,
    required this.maxScrollExtent,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final double totalContentHeight = maxScrollExtent + viewportDimension;
    if (totalContentHeight <= 0) return;

    final double viewportTop = (scrollOffset / totalContentHeight) * size.height;
    final double viewportHeight = (viewportDimension / totalContentHeight) * size.height;

    final Paint viewportPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.12)
      ..style = PaintingStyle.fill;

    final Paint viewportBorderPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.25)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    final viewportRect = Rect.fromLTWH(
      0,
      viewportTop,
      size.width,
      viewportHeight.clamp(4.0, size.height), // Minimum 4px height so it's always visible
    );
    canvas.drawRect(viewportRect, viewportPaint);
    canvas.drawRect(viewportRect, viewportBorderPaint);
  }

  @override
  bool shouldRepaint(covariant _MinimapViewportPainter oldDelegate) {
    return oldDelegate.scrollOffset != scrollOffset ||
        oldDelegate.viewportDimension != viewportDimension ||
        oldDelegate.maxScrollExtent != maxScrollExtent;
  }
}
