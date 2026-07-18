import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../providers/terminal_state.dart';
import '../modules/terminal/terminal_view.dart';
import '../modules/oscilloscope/oscilloscope_view.dart';
import '../modules/hex_editor/hex_editor_view.dart';
import '../modules/text_editor/text_editor_view.dart';

class MainLayout extends StatelessWidget {
  const MainLayout({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: Row(
              children: [
                _buildSidebar(context),
                const VerticalDivider(width: 1),
                _buildWorkspace(context),
              ],
            ),
          ),
          const Divider(height: 1),
          _buildStatusBar(context),
        ],
      ),
    );
  }

  Widget _buildSidebar(BuildContext context) {
    final appState = context.watch<AppState>();
    return Container(
      width: 40, // Compact sidebar (2/3 of original)
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        children: [
          const SizedBox(height: 10),
          _SidebarIcon(
            icon: Icons.show_chart,
            tooltip: '示波器',
            isSelected: appState.selectedModuleIndex == 0,
            onTap: () => appState.setModuleIndex(0),
          ),
          _SidebarIcon(
            icon: Icons.terminal,
            tooltip: '终端',
            isSelected: appState.selectedModuleIndex == 1,
            onTap: () => appState.setModuleIndex(1),
          ),
          _SidebarIcon(
            icon: Icons.memory,
            tooltip: 'Hex 编辑器',
            isSelected: appState.selectedModuleIndex == 2,
            onTap: () => appState.setModuleIndex(2),
          ),
          _SidebarIcon(
            icon: Icons.text_snippet,
            tooltip: '文本对比 / 补丁',
            isSelected: appState.selectedModuleIndex == 3,
            onTap: () => appState.setModuleIndex(3),
          ),
          _SidebarIcon(
            icon: Icons.text_fields,
            tooltip: '字库提取',
            isSelected: appState.selectedModuleIndex == 4,
            onTap: () => appState.setModuleIndex(4),
          ),
          _SidebarIcon(
            icon: Icons.image,
            tooltip: '图像提取',
            isSelected: appState.selectedModuleIndex == 5,
            onTap: () => appState.setModuleIndex(5),
          ),
          const Spacer(),
          const SizedBox(height: 10),
        ],
      ),
    );
  }

  Widget _buildWorkspace(BuildContext context) {
    final selectedIndex = context.watch<AppState>().selectedModuleIndex;
    
    // Placeholder for actual modules
    Widget activeModule;
    switch (selectedIndex) {
      case 0:
        activeModule = const OscilloscopeView();
        break;
      case 1:
        activeModule = const TerminalView();
        break;
      case 2:
        activeModule = const HexEditorView();
        break;
      case 3:
        activeModule = const TextEditorView();
        break;
      case 4:
        activeModule = const Center(child: Text('字库提取器 (开发中...)', textAlign: TextAlign.center));
        break;
      case 5:
        activeModule = const Center(child: Text('图像提取器 (开发中...)', textAlign: TextAlign.center));
        break;
      default:
        activeModule = const Center(child: Text('未知模块'));
    }

    return Expanded(
      child: Container(
        color: Theme.of(context).colorScheme.surface,
        child: activeModule,
      ),
    );
  }

  Widget _buildStatusBar(BuildContext context) {
    final terminalState = context.watch<TerminalState>();
    String statusLeft = terminalState.isConnected ? '正在运行' : '准备就绪';
    String statusRight = terminalState.isConnected 
        ? '${terminalState.serialPort} - ${terminalState.baudRate}' 
        : '未连接';

    return Container(
      height: 28,
      color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.8),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text('DebugToolSet $statusLeft', style: const TextStyle(fontSize: 12, color: Colors.white)),
          Text(statusRight, style: const TextStyle(fontSize: 12, color: Colors.white)),
        ],
      ),
    );
  }
}

class _SidebarIcon extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final bool isSelected;
  final VoidCallback onTap;

  const _SidebarIcon({
    required this.icon,
    required this.tooltip,
    required this.isSelected,
    required this.onTap,
  });

  @override
  State<_SidebarIcon> createState() => _SidebarIconState();
}

class _SidebarIconState extends State<_SidebarIcon> {
  OverlayEntry? _overlayEntry;
  Offset _mousePosition = Offset.zero;

  void _showTooltip() {
    _removeTooltip();
    _overlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        left: _mousePosition.dx + 14,
        top: _mousePosition.dy + 14,
        child: Material(
          color: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            decoration: BoxDecoration(
              color: const Color(0xFF424242),
              borderRadius: BorderRadius.circular(4),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.35),
                  blurRadius: 6,
                  offset: const Offset(1, 2),
                ),
              ],
            ),
            child: Text(
              widget.tooltip,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                decoration: TextDecoration.none,
              ),
            ),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(_overlayEntry!);
  }

  void _removeTooltip() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  @override
  void dispose() {
    _removeTooltip();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return MouseRegion(
      onEnter: (event) {
        _mousePosition = event.position;
        _showTooltip();
      },
      onHover: (event) {
        _mousePosition = event.position;
        _overlayEntry?.markNeedsBuild();
      },
      onExit: (_) => _removeTooltip(),
      child: InkWell(
        onTap: widget.onTap,
        child: Container(
          width: 40,
          height: 44,
          decoration: BoxDecoration(
            border: widget.isSelected
                ? Border(left: BorderSide(color: colorScheme.primary, width: 3))
                : const Border(left: BorderSide(color: Colors.transparent, width: 3)),
          ),
          child: Icon(
            widget.icon,
            color: widget.isSelected ? colorScheme.primary : Colors.grey,
            size: 22,
          ),
        ),
      ),
    );
  }
}

