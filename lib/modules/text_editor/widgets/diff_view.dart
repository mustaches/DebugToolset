import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../../../modules/text_editor/utils/diff_utils.dart';
import '../../../modules/text_editor/utils/syntax_highlighter.dart';

/// Renders a side-by-side diff from a list of [DiffLine].
///
/// The view is divided into two equal panes. Deletions appear in the left
/// pane with a red background, insertions appear in the right pane with a
/// green background, and equal lines are shown on both sides with the default
/// background.
class DiffView extends StatefulWidget {
  final List<DiffLine> diffLines;
  final String? originalPath;
  final String? modifiedPath;
  final ScrollController? scrollController;

  const DiffView({
    super.key,
    required this.diffLines,
    this.originalPath,
    this.modifiedPath,
    this.scrollController,
  });

  @override
  State<DiffView> createState() => _DiffViewState();
}

class _DiffViewState extends State<DiffView> {
  final _scrollController = ScrollController();

  @override
  void dispose() {
    if (widget.scrollController == null) {
      _scrollController.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.scrollController ?? _scrollController;

    return Container(
      color: const Color(0xFF1E1E1E),
      child: Scrollbar(
        controller: controller,
        thumbVisibility: true,
        child: SelectionArea(
          child: ListView.builder(
            controller: controller,
            itemCount: widget.diffLines.length,
            itemBuilder: (context, index) {
              final line = widget.diffLines[index];
              return _DiffRow(
                line: line,
                originalPath: widget.originalPath,
                modifiedPath: widget.modifiedPath,
              );
            },
          ),
        ),
      ),
    );
  }
}

class _DiffRow extends StatelessWidget {
  final DiffLine line;
  final String? originalPath;
  final String? modifiedPath;

  const _DiffRow({
    required this.line,
    this.originalPath,
    this.modifiedPath,
  });

  @override
  Widget build(BuildContext context) {
    final leftColor = line.isDelete
        ? Colors.redAccent.withValues(alpha: 0.25)
        : line.isEqual
            ? Colors.transparent
            : const Color(0xFF2A2A2A);

    final rightColor = line.isInsert
        ? Colors.green.withValues(alpha: 0.25)
        : line.isEqual
            ? Colors.transparent
            : const Color(0xFF2A2A2A);

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _DiffLine(
              text: line.isInsert ? '' : line.text,
              lineNumber: line.originalLineNumber,
              backgroundColor: leftColor,
              language: _language(originalPath),
            ),
          ),
          Container(width: 1, color: Colors.grey.shade800),
          Expanded(
            child: _DiffLine(
              text: line.isDelete ? '' : line.text,
              lineNumber: line.modifiedLineNumber,
              backgroundColor: rightColor,
              language: _language(modifiedPath),
            ),
          ),
        ],
      ),
    );
  }

  String? _language(String? path) {
    if (path == null) return null;
    final ext = p.extension(path).replaceFirst('.', '').toLowerCase();
    return ext.isEmpty ? null : ext;
  }
}

class _DiffLine extends StatelessWidget {
  final String text;
  final int? lineNumber;
  final Color backgroundColor;
  final String? language;

  const _DiffLine({
    required this.text,
    this.lineNumber,
    required this.backgroundColor,
    this.language,
  });

  @override
  Widget build(BuildContext context) {
    const lineNumberStyle = TextStyle(
      color: Colors.grey,
      fontSize: 11,
      fontFamily: 'Consolas',
    );
    const textStyle = TextStyle(
      color: kVscodePlain,
      fontSize: 13,
      fontFamily: 'Consolas',
      height: 1.4,
    );

    return Container(
      color: backgroundColor,
      child: Row(
        children: [
          SizedBox(
            width: 50,
            child: Text(
              lineNumber != null ? '$lineNumber' : '',
              style: lineNumberStyle,
              textAlign: TextAlign.right,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text.rich(
              TextSpan(
                style: textStyle,
                children: SyntaxHighlighter.highlightText(
                  text,
                  language,
                  baseStyle: textStyle,
                ),
              ),
              softWrap: false,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
