/// ISP Studio 编辑器标签栏：流程图标签 + 各节点的只读代码标签。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../providers/isp_studio_state.dart';
import '../codegen/group_c_target.dart';
import '../codegen/ip_target.dart';

/// 多标签栏：首标签为节点流程图（标题用工程名，默认图显示「缺省流程」），
/// 其后为已打开的节点/编组代码标签（标题为节点名/编组名，可关闭）。
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
          for (final (i, tab) in state.openCodeTabs.indexed)
            _EditorTab(
              icon: tab.startsWith('group:') || tab.startsWith('gbb:')
                  ? Icons.account_tree
                  : tab.startsWith('gip:')
                      ? Icons.memory
                      : Icons.code,
              title: _tabTitle(state, tab),
              tooltip: '$tab — 只读代码',
              active: state.activeTab == i + 1,
              onTap: () => state.setActiveTab(i + 1),
              onClose: () => state.closeCodeTab(tab),
            ),
        ],
      ),
    );
  }

  /// 代码标签标题：节点标签为节点实例名（节点已删除时退化为 id）；
  /// 编组标签（`'group:<id>@<target>'` 前缀）为「编组名·目标短名」；
  /// 黑盒标签（`'gbb:<id>@<target>'` 前缀）为「编组名·黑盒·目标短名」
  ///（编组已解散时均退化为通用名；无 @ 后缀的旧 key 不带目标短名）。
  static String _tabTitle(IspStudioState state, String tab) {
    // 解析 `@<target>` 后缀（见 isp_studio_state 的标签 key 约定）。
    (String, GroupCTarget?) splitTarget(String rest) {
      final at = rest.indexOf('@');
      if (at < 0) return (rest, null);
      return (
        rest.substring(0, at),
        GroupCTarget.values.asNameMap()[rest.substring(at + 1)]
      );
    }

    // 解析 `@<vendor>` 后缀（IP 标签 key 约定）。
    (String, IpVendor?) splitVendor(String rest) {
      final at = rest.indexOf('@');
      if (at < 0) return (rest, null);
      return (
        rest.substring(0, at),
        IpVendor.values.asNameMap()[rest.substring(at + 1)]
      );
    }

    if (tab.startsWith('gip:')) {
      final (groupId, vendor) = splitVendor(tab.substring(4));
      for (final g in state.graph.groups) {
        if (g.id == groupId) {
          return '${g.name}·IP${vendor == null ? '' : '·${vendor.shortName}'}';
        }
      }
      return '编组 IP';
    }
    if (tab.startsWith('gbb:')) {
      final (groupId, target) = splitTarget(tab.substring(4));
      for (final g in state.graph.groups) {
        if (g.id == groupId) {
          return '${g.name}·黑盒${target == null ? '' : '·${target.tabShort}'}';
        }
      }
      return '编组黑盒代码';
    }
    if (tab.startsWith('group:')) {
      final (groupId, target) = splitTarget(tab.substring(6));
      for (final g in state.graph.groups) {
        if (g.id == groupId) {
          return '${g.name}${target == null ? '' : '·${target.tabShort}'}';
        }
      }
      return '编组代码';
    }
    final node = state.graph.nodes[tab];
    if (node == null) return tab;
    return node.name;
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
