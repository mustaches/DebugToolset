/// ISP Studio 编辑器标签栏：流程图标签 + 各节点的只读代码标签。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../providers/isp_studio_state.dart';
import '../models/isp_node.dart';

/// 多标签栏：首标签为节点流程图（标题用工程名，默认图显示「缺省流程」），
/// 其后为已打开的节点代码标签（标题为节点名，可关闭）。
class IspEditorTabBar extends StatelessWidget {
  const IspEditorTabBar({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<IspStudioState>();
    return Container(
      height: 32,
      decoration: const BoxDecoration(
        color: Color(0xFF1B1B1B),
        border: Border(bottom: BorderSide(color: Color(0xFF3A3A3A))),
      ),
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          _EditorTab(
            icon: Icons.account_tree_outlined,
            title: state.graphTabTitle,
            active: state.activeTab == 0,
            onTap: () => state.setActiveTab(0),
          ),
          for (final (i, nodeId) in state.openCodeTabs.indexed)
            _EditorTab(
              icon: Icons.code,
              title: _nodeTitle(state, nodeId),
              tooltip: '$nodeId — 只读代码',
              active: state.activeTab == i + 1,
              onTap: () => state.setActiveTab(i + 1),
              onClose: () => state.closeCodeTab(nodeId),
            ),
        ],
      ),
    );
  }

  /// 代码标签标题：节点显示名；节点已删除时退化为 id。
  static String _nodeTitle(IspStudioState state, String nodeId) {
    final node = state.graph.nodes[nodeId];
    if (node == null) return nodeId;
    return IspNodeRegistry.byId(node.typeId)?.displayName ?? node.typeId;
  }
}

/// 单个标签：图标 + 标题 + 可选关闭按钮。
class _EditorTab extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? tooltip;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback? onClose;

  const _EditorTab({
    required this.icon,
    required this.title,
    required this.active,
    required this.onTap,
    this.tooltip,
    this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final fg = active ? Colors.white : Colors.grey;
    final tab = Container(
      decoration: BoxDecoration(
        color: active ? const Color(0xFF252525) : Colors.transparent,
        border: Border(
          top: BorderSide(
            color: active
                ? Theme.of(context).colorScheme.primary
                : Colors.transparent,
            width: 2,
          ),
          right: const BorderSide(color: Color(0xFF3A3A3A)),
        ),
      ),
      padding: const EdgeInsets.only(left: 10, right: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: fg),
          const SizedBox(width: 6),
          Text(title, style: TextStyle(fontSize: 12, color: fg)),
          if (onClose != null)
            InkWell(
              onTap: onClose,
              borderRadius: BorderRadius.circular(8),
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.close, size: 12, color: Colors.grey),
              ),
            )
          else
            const SizedBox(width: 4),
        ],
      ),
    );
    return Tooltip(
      message: tooltip ?? title,
      child: InkWell(onTap: onTap, child: tab),
    );
  }
}
