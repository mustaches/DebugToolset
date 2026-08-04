import 'package:flutter/material.dart';

import '../models/ui_widget.dart';

/// Interactive preview of a `scrolllist` widget: a real scrollable list
/// with momentum physics, snap-to-item and tap-to-select, used only in
/// preview mode.
class ScrollListPreview extends StatefulWidget {
  const ScrollListPreview({
    super.key,
    required this.model,
    required this.selectedIndex,
    required this.onSelected,
  });

  final UiWidgetModel model;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  State<ScrollListPreview> createState() => _ScrollListPreviewState();
}

class _ScrollListPreviewState extends State<ScrollListPreview> {
  late final ScrollController _controller;

  List<String> get _items => (widget.model.props['items'] as String? ?? '')
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  bool get _vertical =>
      (widget.model.props['orientation'] as String? ?? 'vertical') ==
      'vertical';

  double get _extent =>
      (widget.model.props['itemExtent'] as num?)?.toDouble() ?? 36;

  double get _spacing =>
      (widget.model.props['spacing'] as num?)?.toDouble() ?? 4;

  double get _step => _extent + _spacing;

  @override
  void initState() {
    super.initState();
    _controller = ScrollController(
        initialScrollOffset: widget.selectedIndex * _step);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _snapTo(int index) {
    if (!_controller.hasClients) return;
    _controller.animateTo(
      index * _step,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  void _onScrollEnd() {
    if (!_controller.hasClients || _items.isEmpty) return;
    final index =
        (_controller.offset / _step).round().clamp(0, _items.length - 1);
    if (index != widget.selectedIndex) {
      widget.onSelected(index);
    }
    _snapTo(index);
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    if (items.isEmpty) return const SizedBox.shrink();
    final selectedColor =
        Color(widget.model.props['selectedColor'] as int? ?? 0xFF1E88E5);
    final textColor =
        Color(widget.model.props['textColor'] as int? ?? 0xFFFFFFFF);
    final fontSize = (widget.model.props['fontSize'] as num?)?.toDouble() ?? 16;

    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n is ScrollEndNotification) _onScrollEnd();
        return false;
      },
      child: ListView.builder(
        controller: _controller,
        scrollDirection: _vertical ? Axis.vertical : Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemExtent: _step,
        itemCount: items.length,
        itemBuilder: (_, i) {
          final selected = i == widget.selectedIndex;
          final item = GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              widget.onSelected(i);
              _snapTo(i);
            },
            child: Container(
              margin: EdgeInsets.only(
                  bottom: _vertical ? _spacing : 0,
                  right: _vertical ? 0 : _spacing),
              decoration: BoxDecoration(
                color: selected
                    ? selectedColor.withValues(alpha: 0.85)
                    : Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(6),
              ),
              alignment: Alignment.center,
              child: Text(
                items[i],
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: fontSize,
                  color: selected ? Colors.white : textColor,
                  fontWeight:
                      selected ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ),
          );
          return item;
        },
      ),
    );
  }
}
