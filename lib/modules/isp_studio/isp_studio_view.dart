import 'dart:io';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/isp_studio_state.dart';
import 'models/isp_align_mode.dart';
import 'models/isp_node.dart';
import 'widgets/editor_tab_bar.dart';
import 'widgets/node_canvas.dart';
import 'widgets/node_code_page.dart';
import 'widgets/node_layout.dart';
import 'widgets/node_palette.dart';
import 'widgets/node_property_panel.dart';
import 'widgets/run_progress_dialog.dart';

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
  /// 注意：必须使用平台分隔符拼接。Windows 上混用 '/' 会导致
  /// file_selector 内部 SHCreateItemFromParsingName 失败（E_INVALIDARG），
  /// 文件对话框静默回退到“上次使用的目录”而不是 IspFlow。
  Future<Directory> _flowDir() async {
    final dir = Directory(
        '${Directory.current.path}${Platform.pathSeparator}IspFlow');
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

  /// 把当前流程图保存为 .ispflow 文件；返回是否真正保存
  /// （用户在保存对话框中取消返回 false）。
  Future<bool> _saveFlow(IspStudioState state) async {
    final loc = await getSaveLocation(
      suggestedName: '${state.graphTabTitle}.ispflow',
      acceptedTypeGroups: [_flowTypeGroup],
      initialDirectory: (await _flowDir()).path,
    );
    if (loc == null) return false;
    await state.saveGraphToFile(loc.path);
    return !state.statusMessage.startsWith('保存流程失败');
  }

  /// 清除画布：警告窗口（保存并清除 / 清除画布 / 取消操作）。
  Future<void> _confirmResetCanvas(
      BuildContext context, IspStudioState state) async {
    final action = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清除画布'),
        content: const Text('本操作将清除当前画布上的所有节点。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop('save'),
            child: const Text('保存并清除'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop('clear'),
            child: const Text('清除画布',
                style: TextStyle(color: Color(0xFFCF6679))),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop('cancel'),
            child: const Text('取消操作'),
          ),
        ],
      ),
    );
    if (action == 'save') {
      // 保存成功才清除；保存对话框被取消或写盘失败都不动画布。
      if (await _saveFlow(state)) {
        state.clearGraph();
      }
    } else if (action == 'clear') {
      state.clearGraph();
    }
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
      ],
    );
  }

  Widget _buildDivider() {
    return Container(
      height: 18,
      width: 1,
      margin: const EdgeInsets.symmetric(horizontal: 6),
      color: Colors.white24,
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
          // 组1：文件操作
          IconButton(
            icon: const Icon(Icons.file_open, size: 18),
            tooltip: '打开流程 (.ispflow)',
            color: Colors.white,
            onPressed: () => _importFlow(state),
          ),
          IconButton(
            icon: const Icon(Icons.save, size: 18),
            tooltip: '保存流程 (.ispflow)',
            color: Colors.white,
            onPressed: () => _saveFlow(state),
          ),
          _buildDivider(),

          // 组2：执行与视图
          IconButton(
            icon: const Icon(Icons.play_arrow, size: 20),
            tooltip: '运行预览',
            color: state.isProcessing ? Colors.white38 : const Color(0xFF4CAF50),
            onPressed: state.isProcessing
                ? null
                : () => runPreviewWithProgress(context, state),
          ),
          IconButton(
            icon: const Icon(Icons.center_focus_strong, size: 18),
            tooltip: '适配全屏',
            color: Colors.white,
            onPressed: () => state.resetView(),
          ),
          IconButton(
            icon: const Icon(Icons.layers_clear_outlined, size: 18),
            tooltip: '清除画布',
            color: Colors.white,
            onPressed: () => _confirmResetCanvas(context, state),
          ),
          _buildDivider(),

          // 组3：水平对齐
          IconButton(
            icon: const Icon(Icons.align_horizontal_left, size: 18),
            tooltip: '左对齐',
            color: Colors.white,
            onPressed: () => state.alignNodes(IspAlignMode.left),
          ),
          IconButton(
            icon: const Icon(Icons.align_horizontal_center, size: 18),
            tooltip: '水平居中',
            color: Colors.white,
            onPressed: () => state.alignNodes(IspAlignMode.horizontalCenter),
          ),
          IconButton(
            icon: const Icon(Icons.align_horizontal_right, size: 18),
            tooltip: '右对齐',
            color: Colors.white,
            onPressed: () => state.alignNodes(IspAlignMode.right),
          ),
          _buildDivider(),

          // 组4：垂直对齐
          IconButton(
            icon: const Icon(Icons.align_vertical_top, size: 18),
            tooltip: '顶对齐',
            color: Colors.white,
            onPressed: () => state.alignNodes(IspAlignMode.top),
          ),
          IconButton(
            icon: const Icon(Icons.align_vertical_center, size: 18),
            tooltip: '垂直居中',
            color: Colors.white,
            onPressed: () => state.alignNodes(IspAlignMode.verticalCenter),
          ),
          IconButton(
            icon: const Icon(Icons.align_vertical_bottom, size: 18),
            tooltip: '底对齐',
            color: Colors.white,
            onPressed: () => state.alignNodes(IspAlignMode.bottom),
          ),
          _buildDivider(),

          // 组5：等间距与尺寸控制
          IconButton(
            icon: const Icon(Icons.horizontal_distribute, size: 18),
            tooltip: '水平等间距分布',
            color: Colors.white,
            onPressed: () => state.alignNodes(IspAlignMode.distributeHorizontal),
          ),
          IconButton(
            icon: const Icon(Icons.vertical_distribute, size: 18),
            tooltip: '垂直等间距分布',
            color: Colors.white,
            onPressed: () => state.alignNodes(IspAlignMode.distributeVertical),
          ),
          IconButton(
            icon: const Icon(Icons.swap_horiz, size: 18),
            tooltip: '统一为首选节点宽度 (黄框)',
            color: state.selectedNodeIds.length >= 2
                ? const Color(0xFFFFC107)
                : Colors.white38,
            onPressed: state.selectedNodeIds.length >= 2
                ? () => state.matchSelectedNodesWidth()
                : null,
          ),
          IconButton(
            icon: const Icon(Icons.swap_vert, size: 18),
            tooltip: '统一为首选节点高度 (黄框)',
            color: state.selectedNodeIds.length >= 2
                ? const Color(0xFFFFC107)
                : Colors.white38,
            onPressed: state.selectedNodeIds.length >= 2
                ? () => state.matchSelectedNodesHeight()
                : null,
          ),
          IconButton(
            icon: const Icon(Icons.aspect_ratio, size: 18),
            tooltip: '统一为首选节点尺寸 (黄框)',
            color: state.selectedNodeIds.length >= 2
                ? const Color(0xFFFFC107)
                : Colors.white38,
            onPressed: state.selectedNodeIds.length >= 2
                ? () => state.matchSelectedNodesSize()
                : null,
          ),

          const Spacer(),
          if (state.primarySelectedNode != null) ...[
            Builder(builder: (context) {
              final node = state.primarySelectedNode!;
              final type = IspNodeRegistry.byId(node.typeId);
              final h = type == null
                  ? 0.0
                  : nodeHeight(type, previewExtraHeight: node.extraHeight);
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFC107).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                      color: const Color(0xFFFFC107).withValues(alpha: 0.5)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.straighten,
                        size: 13, color: Color(0xFFFFC107)),
                    const SizedBox(width: 4),
                    Text(
                      'W:${node.width.toInt()} × H:${h.toInt()}',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFFFFC107),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              );
            }),
            const SizedBox(width: 8),
          ],
          if (state.isProcessing) ...[
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            IconButton(
              icon: const Icon(Icons.stop, size: 18, color: Color(0xFFCF6679)),
              tooltip: '取消处理',
              onPressed: () => state.cancelProcessing(),
            ),
          ],
        ],
      ),
    );
  }
}
