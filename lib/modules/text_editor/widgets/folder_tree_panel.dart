import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../utils/folder_diff.dart';

/// A regedit-style hierarchical file tree for one opened folder.
///
/// Built from a list of forward-slash relative file paths. Directories can be
/// expanded/collapsed like in the Windows Registry Editor: every row is
/// connected to its ancestors with dotted guide lines (`│ ├ └`), and
/// directory rows carry a `[+]`/`[-]` toggle box on the junction. When
/// [statusOf] is provided, files are tinted with their comparison status
/// color.
class FolderTreePanel extends StatefulWidget {
  /// Header title, e.g. '原文件夹'.
  final String title;

  /// Absolute path of the opened folder, or null when not selected yet.
  final String? rootDir;

  /// Sorted forward-slash relative paths of the files to show.
  final List<String> files;

  /// Optional comparison status lookup, keyed by relative path.
  final FolderFileStatus? Function(String relativePath)? statusOf;

  /// Relative path of the currently selected file, if any.
  final String? selectedPath;

  /// Called when a file row is tapped.
  final void Function(String relativePath)? onFileTap;

  /// Message shown when [rootDir] is set but [files] is empty.
  final String emptyHint;

  /// Optional scroll controller for the tree's list, used to keep two panels
  /// scrolling in sync.
  final ScrollController? scrollController;

  /// When provided (together with [onToggleDir]), the set of collapsed
  /// directory paths is owned by the parent so two panels can share it.
  final Set<String>? collapsedPaths;

  /// Called when a directory row is tapped while [collapsedPaths] is set.
  final void Function(String dirPath)? onToggleDir;

  const FolderTreePanel({
    super.key,
    required this.title,
    required this.rootDir,
    required this.files,
    this.statusOf,
    this.selectedPath,
    this.onFileTap,
    this.emptyHint = '（空文件夹）',
    this.scrollController,
    this.collapsedPaths,
    this.onToggleDir,
  });

  @override
  State<FolderTreePanel> createState() => _FolderTreePanelState();
}

class _FolderTreePanelState extends State<FolderTreePanel> {
  /// Paths of collapsed directories; everything else is expanded. Only used
  /// when the parent does not supply [FolderTreePanel.collapsedPaths].
  final Set<String> _collapsed = {};
  late _DirNode _root;

  /// The effective collapsed set: the parent's when shared, else local.
  Set<String> get _collapsedPaths => widget.collapsedPaths ?? _collapsed;

  @override
  void initState() {
    super.initState();
    _root = _buildTree(widget.files);
  }

  @override
  void didUpdateWidget(covariant FolderTreePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.files, widget.files)) {
      _root = _buildTree(widget.files);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          color: const Color(0xFF2A2A2A),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              Text(widget.title,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.bold)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  widget.rootDir != null
                      ? p.basename(widget.rootDir!)
                      : '（未选择）',
                  style: const TextStyle(
                      color: Colors.grey,
                      fontSize: 11,
                      fontFamily: 'Consolas'),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        Expanded(child: _buildBody()),
      ],
    );
  }

  Widget _buildBody() {
    if (widget.rootDir == null) {
      return const Center(
        child: Text('（未选择文件夹）',
            style: TextStyle(color: Colors.grey, fontSize: 12)),
      );
    }
    if (widget.files.isEmpty) {
      return Center(
        child: Text(widget.emptyHint,
            style: const TextStyle(color: Colors.grey, fontSize: 12)),
      );
    }
    final rows = _flatten(_root, collapsed: _collapsedPaths);
    return ListView.builder(
      controller: widget.scrollController,
      itemCount: rows.length,
      itemExtent: _TreeGuidesPainter.rowHeight,
      itemBuilder: (context, index) => _buildRow(rows[index]),
    );
  }

  Widget _buildRow(_Row row) {
    final guideWidth = _TreeGuidesPainter.leftMargin +
        row.depth * _TreeGuidesPainter.cellWidth +
        _TreeGuidesPainter.stubWidth;

    if (row.isDir) {
      final expanded = !_collapsedPaths.contains(row.path);
      return InkWell(
        onTap: _toggleDir(row.path, expanded),
        child: Row(
          children: [
            SizedBox(
              width: guideWidth,
              height: _TreeGuidesPainter.rowHeight,
              child: CustomPaint(
                painter: _TreeGuidesPainter(
                  ancestorLines: row.ancestorLines,
                  isLast: row.isLast,
                  isDir: true,
                  expanded: expanded,
                ),
              ),
            ),
            const Icon(Icons.folder, size: 13, color: Color(0xFFDCBD67)),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                row.name,
                style: const TextStyle(fontSize: 11, color: Colors.white70),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }

    final selected = widget.selectedPath == row.path;
    final status = widget.statusOf?.call(row.path);
    final color = selected
        ? Colors.cyanAccent
        : status != null
            ? _statusColor(status)
            : Colors.white70;
    return InkWell(
      onTap: () => widget.onFileTap?.call(row.path),
      child: Container(
        color: selected ? const Color(0xFF0A4A5A) : null,
        padding: const EdgeInsets.only(right: 6),
        child: Row(
          children: [
            SizedBox(
              width: guideWidth,
              height: _TreeGuidesPainter.rowHeight,
              child: CustomPaint(
                painter: _TreeGuidesPainter(
                  ancestorLines: row.ancestorLines,
                  isLast: row.isLast,
                  isDir: false,
                  expanded: false,
                ),
              ),
            ),
            Icon(_statusIcon(status), size: 12, color: color),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                row.name,
                style: TextStyle(fontSize: 11, color: color),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Toggles a directory's collapsed state: delegates to the parent when the
  /// collapsed set is shared between panels, otherwise mutates the local set.
  VoidCallback _toggleDir(String path, bool expanded) {
    final onToggle = widget.onToggleDir;
    if (widget.collapsedPaths != null && onToggle != null) {
      return () => onToggle(path);
    }
    return () => setState(() {
      expanded ? _collapsed.add(path) : _collapsed.remove(path);
    });
  }

  static Color _statusColor(FolderFileStatus status) {
    switch (status) {
      case FolderFileStatus.added:
        return Colors.green;
      case FolderFileStatus.deleted:
        return Colors.redAccent;
      case FolderFileStatus.modified:
        return Colors.orangeAccent;
      case FolderFileStatus.unchanged:
        return Colors.white70;
      case FolderFileStatus.binary:
        return Colors.yellowAccent;
    }
  }

  static IconData _statusIcon(FolderFileStatus? status) {
    switch (status) {
      case FolderFileStatus.added:
        return Icons.add_circle_outline;
      case FolderFileStatus.deleted:
        return Icons.remove_circle_outline;
      case FolderFileStatus.modified:
        return Icons.edit_outlined;
      case FolderFileStatus.binary:
        return Icons.block;
      case FolderFileStatus.unchanged:
      case null:
        return Icons.insert_drive_file_outlined;
    }
  }
}

/// Paints the regedit-style guide lines of one row: a dotted vertical line
/// for every ancestor that still has siblings below, the dotted stub
/// (`├` or `└`) connecting the row to its parent, and — for directories —
/// the `[+]`/`[-]` toggle box centered on the junction.
class _TreeGuidesPainter extends CustomPainter {
  _TreeGuidesPainter({
    required this.ancestorLines,
    required this.isLast,
    required this.isDir,
    required this.expanded,
  });

  /// One flag per ancestor level: true when that ancestor has a following
  /// sibling, i.e. its vertical line continues through this row.
  final List<bool> ancestorLines;

  /// True when this row is the last child of its parent (draw `└`).
  final bool isLast;

  /// True for directory rows: draws the `[+]`/`[-]` box on the junction.
  final bool isDir;

  /// Expansion state of the directory; selects `-` vs `+` in the box.
  final bool expanded;

  static const double rowHeight = 24;
  static const double leftMargin = 2;
  static const double cellWidth = 14;
  static const double stubWidth = 16;

  static const Color _lineColor = Color(0xFF7F7F7F);
  static const Color _boxFill = Color(0xFF1E1E1E);
  static const double _boxSize = 9;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = _lineColor
      ..strokeWidth = 1;
    const midY = rowHeight / 2;

    // Vertical continuation lines of the ancestors.
    for (var i = 0; i < ancestorLines.length; i++) {
      if (ancestorLines[i]) {
        final x = leftMargin + i * cellWidth + cellWidth / 2;
        _dottedV(canvas, paint, x, 0, rowHeight);
      }
    }

    // The stub connecting this row to its parent.
    final stubX = leftMargin + ancestorLines.length * cellWidth + cellWidth / 2;
    _dottedV(canvas, paint, stubX, 0, isLast ? midY : rowHeight);

    if (isDir) {
      const half = _boxSize / 2;
      final box = Rect.fromCenter(
          center: Offset(stubX, midY), width: _boxSize, height: _boxSize);
      canvas.drawRect(box, Paint()..color = _boxFill);
      canvas.drawRect(
          box,
          Paint()
            ..color = _lineColor
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1);
      _dottedH(canvas, paint, stubX + half, stubX + stubWidth / 2 + 1, midY);
      // '-' always; '+' only when collapsed.
      final signPaint = Paint()
        ..color = Colors.white70
        ..strokeWidth = 1;
      canvas.drawLine(
          Offset(stubX - 2, midY), Offset(stubX + 2, midY), signPaint);
      if (!expanded) {
        canvas.drawLine(
            Offset(stubX, midY - 2), Offset(stubX, midY + 2), signPaint);
      }
    } else {
      _dottedH(canvas, paint, stubX, stubX + stubWidth / 2 + 1, midY);
    }
  }

  void _dottedV(Canvas canvas, Paint paint, double x, double y0, double y1) {
    for (var y = y0; y < y1; y += 2) {
      canvas.drawLine(Offset(x, y), Offset(x, math.min(y + 1, y1)), paint);
    }
  }

  void _dottedH(Canvas canvas, Paint paint, double x0, double x1, double y) {
    for (var x = x0; x < x1; x += 2) {
      canvas.drawLine(Offset(x, y), Offset(math.min(x + 1, x1), y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _TreeGuidesPainter old) =>
      old.isLast != isLast ||
      old.isDir != isDir ||
      old.expanded != expanded ||
      old.ancestorLines.length != ancestorLines.length ||
      !_listEquals(old.ancestorLines, ancestorLines);

  bool _listEquals(List<bool> a, List<bool> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// A visible row in the flattened tree.
class _Row {
  final int depth;
  final bool isDir;
  final String name;

  /// Directory path for dirs, full relative file path for files.
  final String path;

  /// One flag per ancestor level, see [_TreeGuidesPainter.ancestorLines].
  final List<bool> ancestorLines;

  /// True when this row is the last child of its parent.
  final bool isLast;

  const _Row({
    required this.depth,
    required this.isDir,
    required this.name,
    required this.path,
    required this.ancestorLines,
    required this.isLast,
  });
}

class _DirNode {
  _DirNode(this.path);

  /// Forward-slash relative path of this directory ('' for the root).
  final String path;
  final Map<String, _DirNode> dirs = {};
  final List<String> files = [];
}

_DirNode _buildTree(List<String> files) {
  final root = _DirNode('');
  for (final file in files) {
    final parts = file.split('/');
    var node = root;
    for (var i = 0; i < parts.length - 1; i++) {
      final dirPath = parts.sublist(0, i + 1).join('/');
      node = node.dirs.putIfAbsent(parts[i], () => _DirNode(dirPath));
    }
    node.files.add(file);
  }
  return root;
}

/// Flattens the tree into visible rows: directories first (sorted), then
/// files (sorted), descending into expanded directories only. Each row
/// records whether it is the last child of its parent and which ancestors
/// still have following siblings, so the guide lines can be drawn.
List<_Row> _flatten(_DirNode root, {Set<String> collapsed = const {}}) {
  final rows = <_Row>[];

  void walk(_DirNode node, int depth, List<bool> ancestorLines) {
    final dirNames = node.dirs.keys.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    final fileNames = node.files.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    final total = dirNames.length + fileNames.length;

    var index = 0;
    for (final name in dirNames) {
      final child = node.dirs[name]!;
      final isLast = index == total - 1;
      rows.add(_Row(
        depth: depth,
        isDir: true,
        name: name,
        path: child.path,
        ancestorLines: List.of(ancestorLines),
        isLast: isLast,
      ));
      if (!collapsed.contains(child.path)) {
        walk(child, depth + 1, [...ancestorLines, !isLast]);
      }
      index++;
    }
    for (final file in fileNames) {
      final isLast = index == total - 1;
      rows.add(_Row(
        depth: depth,
        isDir: false,
        name: file.split('/').last,
        path: file,
        ancestorLines: List.of(ancestorLines),
        isLast: isLast,
      ));
      index++;
    }
  }

  walk(root, 0, const []);
  return rows;
}
