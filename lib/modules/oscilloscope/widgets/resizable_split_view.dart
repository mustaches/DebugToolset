import 'package:flutter/material.dart';

class ResizableSplitView extends StatefulWidget {
  final Widget topWidget;
  final Widget bottomWidget;
  final double initialRatio;
  final double dividerHeight;

  const ResizableSplitView({
    super.key,
    required this.topWidget,
    required this.bottomWidget,
    this.initialRatio = 0.8,
    this.dividerHeight = 4.0,
  });

  @override
  State<ResizableSplitView> createState() => _ResizableSplitViewState();
}

class _ResizableSplitViewState extends State<ResizableSplitView> {
  double? _bottomHeight;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final totalHeight = constraints.maxHeight - widget.dividerHeight;
      
      _bottomHeight ??= (totalHeight * (1.0 - widget.initialRatio)) - 5.0;
      
      if (_bottomHeight! < 50) {
        _bottomHeight = 50;
      }
      if (_bottomHeight! > totalHeight - 50) {
        _bottomHeight = totalHeight - 50;
      }
      
      double topHeight = totalHeight - _bottomHeight!;

      return Column(
        children: [
          SizedBox(
            height: topHeight,
            child: widget.topWidget,
          ),
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onPanUpdate: (details) {
              setState(() {
                _bottomHeight = _bottomHeight! - details.delta.dy;
              });
            },
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeUpDown,
              child: Container(
                height: widget.dividerHeight,
                color: Colors.grey.shade700,
                child: Center(
                  child: Container(
                    width: 40,
                    height: 2,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade400,
                      borderRadius: BorderRadius.circular(1),
                    ),
                  ),
                ),
              ),
            ),
          ),
          SizedBox(
            height: _bottomHeight!,
            child: widget.bottomWidget,
          ),
        ],
      );
    });
  }
}
