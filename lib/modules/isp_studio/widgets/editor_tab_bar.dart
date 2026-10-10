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
            // 流程图标签用 codicon type-hierarchy-sub（白色 PNG，随
            // 激活态着色）。
            icon: (fg) => Image.asset(
              'icons/type-hierarchy-sub.png',
              width: 26,
              height: 26,
              color: fg,
              colorBlendMode: BlendMode.srcIn,
            ),
            title: state.graphTabTitle,
            active: state.activeTab == 0,
            onTap: () => state.setActiveTab(0),
          ),
          for (final (i, tab) in state.openCodeTabs.indexed)
            _EditorTab(
              icon: tab.startsWith('group:') || tab.startsWith('gbb:')
                  // 「查看C代码」（group:）与「查看黑盒C代码」（gbb:）标签用
                  // codicon file-code（白色 PNG，随激活态着色）；电路图
                  // （sch:）用 circuit-board；其余为 Material 图标。
                  ? (fg) => Image.asset(
                        'icons/file-code.png',
                        width: 26,
                        height: 26,
                        color: fg,
                        colorBlendMode: BlendMode.srcIn,
                      )
                  : tab.startsWith('sch:')
                      ? (fg) => Image.asset(
                            'icons/circuit-board.png',
                            width: 26,
                            height: 26,
                            color: fg,
                            colorBlendMode: BlendMode.srcIn,
                          )
                      : tab.startsWith('gip:')
                      // Verilog IP 标签用 codicon kimi（白色 PNG）。
                      ? (fg) => Image.asset(
                            'icons/kimi.png',
                            width: 26,
                            height: 26,
                            color: fg,
                            colorBlendMode: BlendMode.srcIn,
                          )
                      : tab.startsWith('wave:')
                          // 仿真波形标签用 codicon telescope（白色 PNG）。
                          ? (fg) => Image.asset(
                                'icons/telescope.png',
                                width: 26,
                                height: 26,
                                color: fg,
                                colorBlendMode: BlendMode.srcIn,
                              )
                          : (fg) => Image.asset(
                                // 节点「查看代码」标签用 codicon
                                // code-oss（白色 PNG，随激活态着色）。
                                'icons/code-oss.png',
                                width: 26,
                                height: 26,
                                color: fg,
                                colorBlendMode: BlendMode.srcIn,
                              ),
              title: _tabTitle(state, tab),
              tooltip: tab.startsWith('wave:')
                  ? '仿真波形（Surfer 内嵌）'
                  : '$tab — 只读代码',
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

    if (tab.startsWith('wave:')) return '仿真波形';
    if (tab.startsWith('sch:')) {
      final (groupId, vendor) = splitVendor(tab.substring(4));
      for (final g in state.graph.groups) {
        if (g.id == groupId) {
          return '${g.name}·电路图${vendor == null ? '' : '·${vendor.shortName}'}';
        }
      }
      return '编组电路图';
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

/// 单个标签：图标（随激活态着色的构建器）+ 标题 + 可选关闭按钮。
class _EditorTab extends StatelessWidget {
  final Widget Function(Color fg) icon;
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
    // Chrome 浏览器标签风格：活动标签圆角顶角 + 与下方工具栏条同色连通
    //（活动标签底色 = 工具栏条底色 0xFF252525），非活动标签透明底。
    final tab = Container(
      decoration: BoxDecoration(
        color: active ? const Color(0xFF252525) : Colors.transparent,
        borderRadius: active
            ? const BorderRadius.vertical(top: Radius.circular(8))
            : null,
        border: Border(
          left: BorderSide(
              color: active
                  ? const Color(0xFF3A3A3A)
                  : const Color(0xFF2A2A2A)),
          right: BorderSide(
              color: active
                  ? const Color(0xFF3A3A3A)
                  : const Color(0xFF2A2A2A)),
          top: BorderSide(
              color: active
                  ? const Color(0xFF3A3A3A)
                  : Colors.transparent),
        ),
      ),
      margin: const EdgeInsets.only(left: 2, top: 3),
      padding: const EdgeInsets.only(left: 10, right: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          icon(fg),
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
      child: InkWell(
          onTap: onTap,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
          child: tab),
    );
  }
}
