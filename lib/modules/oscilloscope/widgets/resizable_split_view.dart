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
  late double _ratio;

  bool _isInitialized = false;

  @override
  void initState() {
    super.initState();
    _ratio = widget.initialRatio;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final totalHeight = constraints.maxHeight - widget.dividerHeight;
      
      if (!_isInitialized) {
        _ratio = (totalHeight * widget.initialRatio + 5.0) / totalHeight;
        _isInitialized = true;
      }
      
      double topHeight = totalHeight * _ratio;
      double bottomHeight = totalHeight - topHeight;

      // Ensure min heights
      if (topHeight < 50) {
        topHeight = 50;
        bottomHeight = totalHeight - topHeight;
      }
      if (bottomHeight < 50) {
        bottomHeight = 50;
        topHeight = totalHeight - bottomHeight;
      }

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
                _ratio += details.delta.dy / totalHeight;
                if (_ratio < 0.1) _ratio = 0.1;
                if (_ratio > 0.9) _ratio = 0.9;
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
            height: bottomHeight,
            child: widget.bottomWidget,
          ),
        ],
      );
    });
  }
}
