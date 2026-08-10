import 'dart:io';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/isp_studio_state.dart';
import 'widgets/editor_tab_bar.dart';
import 'widgets/node_canvas.dart';
import 'widgets/node_code_page.dart';
import 'widgets/node_palette.dart';
import 'widgets/node_property_panel.dart';

/// ISP Studio 模块根视图：工具栏 + 标签栏 + 标签页（流程图 / 节点代码）+ 状态栏。
class IspStudioView extends StatelessWidget {
  const IspStudioView({super.key});

  /// 视口中心对应的画布坐标（近似值：扣除左侧工具栏
  /// [kNodePaletteWidth]、属性面板 260、工具栏 40、标签栏 32、状态栏 26 + 主状态栏 28）。
  Offset _pickCenter(BuildContext context, IspStudioState state) {
    final size = MediaQuery.sizeOf(context);
    final w = math.max(200.0, size.width - kNodePaletteWidth - 260);
    final h = math.max(200.0, size.height - 152);
    final center = Offset(w / 2, h / 2);
    return (center - state.canvasOffset) / state.canvasZoom;
  }

  /// 流程图文件类型（JSON 文本，与 .waveform/.uiproj 同一约定）。
  static const _flowTypeGroup =
      XTypeGroup(label: 'ISP 流程', extensions: ['ispflow']);

  /// 打开/保存流程的默认目录（根目录下的 IspFlow，不存在则创建）。
  Future<Directory> _flowDir() async {
    final dir = Directory('${Directory.current.path}/IspFlow');
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir;
  }

  /// 选择 .ispflow 文件并打开（替换当前图）。
  Future<void> _importFlow(IspStudioState state) async {
    final file = await openFile(
      acceptedTypeGroups: [_flowTypeGroup],
      initialDirectory: (await _flowDir()).path,
    );
    if (file != null) await state.importGraphFromFile(file.path);
  }

  /// 把当前流程图保存为 .ispflow 文件。
  Future<void> _saveFlow(IspStudioState state) async {
    final loc = await getSaveLocation(
      suggestedName: '${state.graphTabTitle}.ispflow',
      acceptedTypeGroups: [_flowTypeGroup],
      initialDirectory: (await _flowDir()).path,
    );
    if (loc != null) await state.saveGraphToFile(loc.path);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<IspStudioState>();
    return Column(
      children: [
        _buildToolbar(context, state),
        const IspEditorTabBar(),
        Expanded(
          // IndexedStack 保持流程图画布状态（缩放/平移/选中）不丢。
          child: IndexedStack(
            index: state.activeTab,
            children: [
              Row(
                children: [
                  IspNodePalette(
                      onPickCenter: () => _pickCenter(context, state)),
                  const Expanded(child: IspNodeCanvas()),
                  const NodePropertyPanel(),
                ],
              ),
              for (final nodeId in state.openCodeTabs)
                NodeCodePage(key: ValueKey(nodeId), nodeId: nodeId),
            ],
          ),
        ),
        _buildStatusBar(context, state),
      ],
    );
  }

  Widget _buildToolbar(BuildContext context, IspStudioState state) {
    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: const Color(0xFF252525),
        border: Border(bottom: BorderSide(color: Colors.grey.shade800)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          TextButton.icon(
            icon: const Icon(Icons.file_open, size: 16),
            label: const Text('打开流程', style: TextStyle(fontSize: 12)),
            style: TextButton.styleFrom(foregroundColor: Colors.white),
            onPressed: () => _importFlow(state),
          ),
          TextButton.icon(
            icon: const Icon(Icons.save, size: 16),
            label: const Text('保存流程', style: TextStyle(fontSize: 12)),
            style: TextButton.styleFrom(foregroundColor: Colors.white),
            onPressed: () => _saveFlow(state),
          ),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            icon: const Icon(Icons.play_arrow, size: 16),
            label: const Text('运行预览', style: TextStyle(fontSize: 12)),
            style: ElevatedButton.styleFrom(
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              minimumSize: const Size(0, 30),
            ),
            onPressed: state.isProcessing ? null : () => state.runPreview(),
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            icon: const Icon(Icons.center_focus_strong, size: 16),
            label: const Text('重置视图', style: TextStyle(fontSize: 12)),
            style: TextButton.styleFrom(foregroundColor: Colors.white),
            onPressed: () => state.resetView(),
          ),
          const Spacer(),
          if (state.isProcessing) ...[
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            TextButton(
              onPressed: () => state.cancelProcessing(),
              child: const Text('取消', style: TextStyle(fontSize: 12)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStatusBar(BuildContext context, IspStudioState state) {
    return Container(
      height: 26,
      color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.8),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Flexible(
            child: Text(
              state.statusMessage,
              style: const TextStyle(fontSize: 11, color: Colors.white),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (state.errors.isNotEmpty) ...[
            const SizedBox(width: 12),
            Flexible(
              child: Tooltip(
                message: state.errors.join('\n'),
                child: Text(
                  state.errors.first,
                  style: const TextStyle(
                      fontSize: 11, color: Color(0xFFCF6679)),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ],
          const Spacer(),
          if (state.isProcessing)
            Text(
              '${(state.progress * 100).toStringAsFixed(0)}%',
              style: const TextStyle(fontSize: 11, color: Colors.white),
            ),
        ],
      ),
    );
  }
}
