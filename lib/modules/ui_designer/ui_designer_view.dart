import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/ui_designer_state.dart';
import 'codegen/c_code_exporter.dart';
import 'editor/canvas_view.dart';
import 'editor/page_list_panel.dart';
import 'editor/property_panel.dart';
import 'editor/widget_palette.dart';
import 'tools/image_converter_dialog.dart';
import 'tools/raw_image_dialog.dart';

/// Main view of the UI designer module.
///
/// Layout: top action bar; left column = widget palette over page list;
/// center = canvas; right = property panel (edit) or callback log
/// (preview); bottom status bar with grid / zoom controls.
class UiDesignerView extends StatelessWidget {
  const UiDesignerView({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<UiDesignerState>();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildTopBar(context, state),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!state.previewMode)
                SizedBox(
                  // 108 = 左右各6 + 30px按钮x3 + 3px间距x2
                  width: 108,
                  child: Column(
                    children: const [
                      Expanded(flex: 3, child: WidgetPalette()),
                      Divider(height: 1),
                      Expanded(flex: 2, child: PageListPanel()),
                    ],
                  ),
                ),
              if (!state.previewMode)
                Container(width: 1, color: Colors.grey.shade800),
              const Expanded(child: CanvasView()),
              Container(width: 1, color: Colors.grey.shade800),
              SizedBox(
                width: 250,
                child: state.previewMode
                    ? _CallbackLogPanel(state: state)
                    : const PropertyPanel(),
              ),
            ],
          ),
        ),
        _buildBottomBar(context, state),
      ],
    );
  }

  // ------------------------------------------------------------------
  // Top bar
  // ------------------------------------------------------------------

  Widget _buildTopBar(BuildContext context, UiDesignerState state) {
    return Container(
      color: const Color(0xFF252525),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          const Text(
            'UI 设计器',
            style: TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.bold),
          ),
          const SizedBox(width: 16),
          _topButton(
            icon: Icons.note_add,
            label: '新建',
            onPressed: () => state.newProject(),
          ),
          _topButton(
            icon: Icons.folder_open,
            label: '打开',
            onPressed: () => _openProject(context, state),
          ),
          _topButton(
            icon: Icons.save_alt,
            label: '保存',
            onPressed: () => _saveProject(context, state),
          ),
          const VerticalDivider(width: 16),
          _topButton(
            icon: Icons.undo,
            label: '撤销',
            onPressed: state.canUndo ? state.undo : null,
          ),
          _topButton(
            icon: Icons.redo,
            label: '重做',
            onPressed: state.canRedo ? state.redo : null,
          ),
          const VerticalDivider(width: 16),
          _topButton(
            icon: Icons.photo_library,
            label: '图片转换',
            onPressed: () => showImageConverterDialog(context),
          ),
          _topButton(
            icon: Icons.find_in_page,
            label: '图像提取',
            onPressed: () => showRawImageDialog(context),
          ),
          const Spacer(),
          if (state.dirty)
            const Text('未保存',
                style: TextStyle(fontSize: 11, color: Colors.orangeAccent)),
          const SizedBox(width: 12),
          ElevatedButton.icon(
            onPressed: state.previewMode
                ? state.exitPreview
                : state.enterPreview,
            icon: Icon(state.previewMode ? Icons.stop : Icons.play_arrow,
                size: 16),
            label: Text(state.previewMode ? '退出预览' : '预览',
                style: const TextStyle(fontSize: 12)),
            style: ElevatedButton.styleFrom(
              backgroundColor: state.previewMode
                  ? const Color(0xFF5A2A0A)
                  : const Color(0xFF0A4A5A),
              foregroundColor: Colors.cyanAccent,
              minimumSize: const Size(0, 28),
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            onPressed: () => _exportCode(context, state),
            icon: const Icon(Icons.code, size: 16),
            label: const Text('导出代码', style: TextStyle(fontSize: 12)),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF333333),
              foregroundColor: Colors.cyanAccent,
              minimumSize: const Size(0, 28),
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _topButton({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: TextButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 15, color: Colors.cyanAccent),
        label: Text(label,
            style: const TextStyle(fontSize: 12, color: Colors.white)),
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 28),
          padding: const EdgeInsets.symmetric(horizontal: 8),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------
  // Bottom bar
  // ------------------------------------------------------------------

  Widget _buildBottomBar(BuildContext context, UiDesignerState state) {
    return Container(
      color: const Color(0xFF252525),
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Text(
            '${state.project.screenWidth} x ${state.project.screenHeight}',
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
          const SizedBox(width: 16),
          if (!state.previewMode) ...[
            InkWell(
              onTap: state.toggleSnap,
              child: Row(
                children: [
                  Icon(
                    state.snapEnabled ? Icons.grid_on : Icons.grid_off,
                    size: 14,
                    color: state.snapEnabled
                        ? Colors.cyanAccent
                        : Colors.grey,
                  ),
                  const SizedBox(width: 4),
                  Text('网格 ${state.gridSize}px',
                      style:
                          const TextStyle(fontSize: 11, color: Colors.grey)),
                ],
              ),
            ),
            const SizedBox(width: 16),
            DropdownButton<double>(
              value: state.zoom,
              isDense: true,
              style: const TextStyle(fontSize: 11),
              items: const [
                DropdownMenuItem(value: 0, child: Text('适配窗口')),
                DropdownMenuItem(value: 0.5, child: Text('50%')),
                DropdownMenuItem(value: 1, child: Text('100%')),
                DropdownMenuItem(value: 2, child: Text('200%')),
                DropdownMenuItem(value: 4, child: Text('400%')),
              ],
              onChanged: (v) {
                if (v != null) state.setZoom(v);
              },
            ),
          ],
          const Spacer(),
          Text(
            state.projectFilePath ?? '未保存的工程',
            style: const TextStyle(fontSize: 10, color: Colors.grey),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------
  // Project open / save / export
  // ------------------------------------------------------------------

  static const _projectTypeGroup = XTypeGroup(
    label: 'UI 工程',
    extensions: ['uiproj'],
  );

  Future<void> _openProject(
      BuildContext context, UiDesignerState state) async {
    try {
      final file = await openFile(
          acceptedTypeGroups: const [_projectTypeGroup],
          confirmButtonText: '打开工程');
      if (file == null) return;
      await state.loadProject(file.path);
      if (context.mounted) _snack(context, '工程已加载: ${file.path}');
    } catch (e) {
      if (context.mounted) _snack(context, '工程加载失败: $e', error: true);
    }
  }

  Future<void> _saveProject(
      BuildContext context, UiDesignerState state) async {
    try {
      final location = await getSaveLocation(
        acceptedTypeGroups: const [_projectTypeGroup],
        suggestedName: '${state.project.name}.uiproj',
        confirmButtonText: '保存工程',
      );
      if (location == null) return;
      await state.saveProject(location.path);
      if (context.mounted) _snack(context, '工程已保存到 ${location.path}');
    } catch (e) {
      if (context.mounted) _snack(context, '工程保存失败: $e', error: true);
    }
  }

  Future<void> _exportCode(
      BuildContext context, UiDesignerState state) async {
    try {
      final dir = await getDirectoryPath(confirmButtonText: '选择导出目录');
      if (dir == null) return;
      final files = await CCodeExporter.export(state.project, dir,
          projectDir: state.projectDir);
      if (context.mounted) {
        _snack(context, '已导出 ${files.length} 个文件到 $dir');
      }
    } catch (e) {
      if (context.mounted) _snack(context, '导出失败: $e', error: true);
    }
  }

  void _snack(BuildContext context, String msg, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: error ? Colors.redAccent : Colors.green,
        content: Text(msg),
      ),
    );
  }
}

/// Callback log shown on the right side in preview mode.
class _CallbackLogPanel extends StatelessWidget {
  const _CallbackLogPanel({required this.state});

  final UiDesignerState state;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF252525),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(10, 10, 10, 6),
            child: Text('回调日志（预览模式）',
                style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey,
                    fontWeight: FontWeight.bold)),
          ),
          Expanded(
            child: state.callbackLog.isEmpty
                ? const Center(
                    child: Text('与界面交互后，\n触发的回调会显示在这里',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 11, color: Colors.grey)),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    itemCount: state.callbackLog.length,
                    itemBuilder: (_, i) => Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Text(
                        state.callbackLog[i],
                        style: const TextStyle(
                            fontSize: 10,
                            fontFamily: 'Consolas',
                            color: Colors.cyanAccent),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

// tools 尚未实现前占位，避免误删 import。
