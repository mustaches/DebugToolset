import 'package:flutter/material.dart';

class HoverBuilder extends StatefulWidget {
  final Widget Function(BuildContext context, bool isHovered) builder;
  final bool cursorClick;

  const HoverBuilder({super.key, required this.builder, this.cursorClick = true});

  @override
  State<HoverBuilder> createState() => _HoverBuilderState();
}

class _HoverBuilderState extends State<HoverBuilder> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: widget.cursorClick ? SystemMouseCursors.click : MouseCursor.defer,
      child: widget.builder(context, _isHovered),
    );
  }
}
