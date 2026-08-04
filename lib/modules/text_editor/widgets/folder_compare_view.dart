import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../../providers/text_editor_state.dart';
import '../utils/folder_diff.dart';
import 'diff_view.dart';
import 'folder_tree_panel.dart';

/// Body of the folder comparison mode.
///
/// Laid out like the single-file comparison: the view is split into a left
/// (original) and a right (modified) frame. Each frame carries an
/// explorer-style tree of its folder on its left side; the rest of the frame
/// shows that side of the selected file's side-by-side diff. Both diff panes
/// scroll in sync so corresponding lines stay aligned.
class FolderCompareView extends StatefulWidget {
  const FolderCompareView({super.key});

  @override
  State<FolderCompareView> createState() => _FolderCompareViewState();
}

class _FolderCompareViewState extends State<FolderCompareView> {
  bool _onlyDiff = true;

  final _originalScroll = ScrollController();
  final _modifiedScroll = ScrollController();

  // The two folder trees: shared scroll sync and shared collapsed state, so
  // both sides scroll, expand and collapse together.
  final _treeOriginalScroll = ScrollController();
  final _treeModifiedScroll = ScrollController();
  final Set<String> _collapsedDirs = {};

  bool _syncingScroll = false;

  @override
  void initState() {
    super.initState();
    _originalScroll
        .addListener(() => _syncScroll(_originalScroll, _modifiedScroll));
    _modifiedScroll
        .addListener(() => _syncScroll(_modifiedScroll, _originalScroll));
    _treeOriginalScroll.addListener(
        () => _syncScroll(_treeOriginalScroll, _treeModifiedScroll));
    _treeModifiedScroll.addListener(
        () => _syncScroll(_treeModifiedScroll, _treeOriginalScroll));
  }

  @override
  void dispose() {
    _originalScroll.dispose();
    _modifiedScroll.dispose();
    _treeOriginalScroll.dispose();
    _treeModifiedScroll.dispose();
    super.dispose();
  }

  /// Expands or collapses a directory on both trees at once.
  void _toggleDir(String path) {
    setState(() {
      _collapsedDirs.contains(path)
          ? _collapsedDirs.remove(path)
          : _collapsedDirs.add(path);
    });
  }

  /// Keeps the two diff panes at the same vertical offset.
  void _syncScroll(ScrollController source, ScrollController target) {
    if (_syncingScroll || !source.hasClients || !target.hasClients) return;
    final targetPos = target.position;
    final offset = source.offset
        .clamp(targetPos.minScrollExtent, targetPos.maxScrollExtent)
        .toDouble();
    if ((targetPos.pixels - offset).abs() < 1) return;
    _syncingScroll = true;
    target.jumpTo(offset);
    _syncingScroll = false;
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<TextEditorState>();

    if (!state.hasFolderContent) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_copy_outlined,
                size: 64, color: Colors.grey.shade700),
            const SizedBox(height: 16),
            const Text('文件夹对比 / 项目补丁',
                style: TextStyle(color: Colors.grey, fontSize: 16)),
            const SizedBox(height: 8),
            const Text('请打开两个文件夹，然后点击“比较差异”',
                style: TextStyle(color: Colors.grey, fontSize: 12)),
          ],
        ),
      );
    }

    final compared = state.folderCompared;
    final entries = state.folderEntries;
    final statusMap = compared
        ? {for (final e in entries) e.relativePath: e.status}
        : const <String, FolderFileStatus>{};

    List<String> visibleFiles(List<String> files) {
      if (!compared || !_onlyDiff) return files;
      return files
          .where((f) =>
              statusMap[f] != null &&
              statusMap[f] != FolderFileStatus.unchanged)
          .toList();
    }

    int countOf(FolderFileStatus s) =>
        entries.where((e) => e.status == s).length;

    final selectedPath = state.selectedFolderFile;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (compared)
          Container(
            color: const Color(0xFF252525),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                _stat('新增', countOf(FolderFileStatus.added), Colors.green),
                const SizedBox(width: 14),
                _stat('删除', countOf(FolderFileStatus.deleted),
                    Colors.redAccent),
                const SizedBox(width: 14),
                _stat('修改', countOf(FolderFileStatus.modified),
                    Colors.orangeAccent),
                const SizedBox(width: 14),
                _stat('相同', countOf(FolderFileStatus.unchanged), Colors.grey),
                const SizedBox(width: 14),
                _stat('二进制跳过', countOf(FolderFileStatus.binary),
                    Colors.yellowAccent),
                const Spacer(),
                SizedBox(
                  width: 18,
                  height: 18,
                  child: Checkbox(
                    value: _onlyDiff,
                    onChanged: (v) => setState(() => _onlyDiff = v ?? true),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                const SizedBox(width: 6),
                const Text('仅显示差异',
                    style: TextStyle(fontSize: 11, color: Colors.grey)),
              ],
            ),
          ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _sidePane(
                  state,
                  isOriginal: true,
                  rootDir: state.originalDir,
                  files: visibleFiles(state.originalFolderFiles),
                  statusMap: statusMap,
                  compared: compared,
                  selectedPath: selectedPath,
                ),
              ),
              Container(width: 1, color: Colors.grey.shade800),
              Expanded(
                child: _sidePane(
                  state,
                  isOriginal: false,
                  rootDir: state.modifiedDir,
                  files: visibleFiles(state.modifiedFolderFiles),
                  statusMap: statusMap,
                  compared: compared,
                  selectedPath: selectedPath,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// One frame of the comparison: the folder's explorer tree on the left and
  /// that side's diff (or status) content on the right.
  Widget _sidePane(
    TextEditorState state, {
    required bool isOriginal,
    required String? rootDir,
    required List<String> files,
    required Map<String, FolderFileStatus> statusMap,
    required bool compared,
    required String? selectedPath,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 200,
          child: FolderTreePanel(
            title: isOriginal ? '原文件夹' : '修改文件夹',
            rootDir: rootDir,
            files: files,
            statusOf: compared ? (f) => statusMap[f] : null,
            selectedPath: selectedPath,
            onFileTap: (f) => _tapFile(state, f),
            emptyHint: compared && _onlyDiff ? '没有差异文件' : '（空文件夹）',
            scrollController:
                isOriginal ? _treeOriginalScroll : _treeModifiedScroll,
            collapsedPaths: _collapsedDirs,
            onToggleDir: _toggleDir,
          ),
        ),
        Container(width: 1, color: Colors.grey.shade800),
        Expanded(child: _sideContent(state, isOriginal: isOriginal)),
      ],
    );
  }

  Widget _sideContent(TextEditorState state, {required bool isOriginal}) {
    if (state.isComparingFolder) {
      return const Center(
        child: Text('正在对比，请稍候…',
            style: TextStyle(color: Colors.grey, fontSize: 12)),
      );
    }
    final selected = state.selectedFolderFile;
    if (selected == null) {
      return Center(
        child: Text(
          state.folderCompared ? '选择左侧文件查看差异' : '点击左侧树中的文件查看内容',
          style: const TextStyle(color: Colors.grey, fontSize: 12),
        ),
      );
    }
    if (state.isOpeningFolderFile) {
      return const Center(
        child: Text('正在打开文件…',
            style: TextStyle(color: Colors.grey, fontSize: 12)),
      );
    }
    if (state.folderFileBinary) {
      return _message(
        icon: Icons.block,
        color: Colors.yellowAccent,
        text: '二进制文件，无法显示文本差异',
        path: selected,
      );
    }
    final exists =
        isOriginal ? state.folderFileInOriginal : state.folderFileInModified;
    if (!exists) {
      return _message(
        icon: Icons.remove_circle_outline,
        color: Colors.redAccent,
        text: '此文件夹中不存在该文件',
        path: selected,
      );
    }
    if (state.folderFileDiff.isEmpty) {
      return _message(
        icon: Icons.insert_drive_file_outlined,
        color: Colors.grey,
        text: '（空文件）',
        path: selected,
      );
    }
    return DiffView(
      diffLines: state.folderFileDiff,
      originalPath: p.join(state.originalDir ?? '', selected),
      modifiedPath: p.join(state.modifiedDir ?? '', selected),
      scrollController: isOriginal ? _originalScroll : _modifiedScroll,
      side: isOriginal ? DiffViewSide.original : DiffViewSide.modified,
    );
  }

  Widget _message({
    required IconData icon,
    required Color color,
    required String text,
    required String path,
  }) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40, color: color),
          const SizedBox(height: 10),
          Text(text, style: TextStyle(color: color, fontSize: 13)),
          const SizedBox(height: 4),
          Text(path,
              style: const TextStyle(
                  color: Colors.grey, fontSize: 11, fontFamily: 'Consolas')),
        ],
      ),
    );
  }

  void _tapFile(TextEditorState state, String relativePath) {
    state.openFolderFile(relativePath);
    if (_originalScroll.hasClients) _originalScroll.jumpTo(0);
    if (_modifiedScroll.hasClients) _modifiedScroll.jumpTo(0);
  }

  Widget _stat(String label, int count, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
              color: color, borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(width: 4),
        Text('$label: $count',
            style: const TextStyle(color: Colors.white, fontSize: 12)),
      ],
    );
  }
}
