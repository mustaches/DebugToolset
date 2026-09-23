import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../providers/terminal_state.dart';
import '../providers/network_terminal_state.dart';
import '../modules/terminal/terminal_view.dart';
import '../modules/network_terminal/network_terminal_view.dart';
import '../modules/oscilloscope/oscilloscope_view.dart';
import '../modules/hex_editor/hex_editor_view.dart';
import '../modules/text_editor/text_editor_view.dart';
import '../modules/font_extractor/font_extractor_view.dart';
import '../modules/ui_designer/ui_designer_view.dart';
import '../providers/isp_studio_state.dart';
import '../modules/isp_studio/isp_studio_view.dart';

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
            icon: Icons.terminal,
            tooltip: '串口终端',
            isSelected: appState.selectedModuleIndex == 0,
            onTap: () => appState.setModuleIndex(0),
          ),
          _SidebarIcon(
            icon: Icons.lan,
            tooltip: '网络终端',
            isSelected: appState.selectedModuleIndex == 1,
            onTap: () => appState.setModuleIndex(1),
          ),
          _SidebarIcon(
            iconBuilder: (color) => _OscilloscopeIcon(color: color),
            tooltip: '示波器',
            isSelected: appState.selectedModuleIndex == 2,
            onTap: () => appState.setModuleIndex(2),
          ),
          _SidebarIcon(
            icon: Icons.memory,
            tooltip: 'Hex 编辑器',
            isSelected: appState.selectedModuleIndex == 3,
            onTap: () => appState.setModuleIndex(3),
          ),
          _SidebarIcon(
            icon: Icons.text_snippet,
            tooltip: '文本对比 / 补丁',
            isSelected: appState.selectedModuleIndex == 4,
            onTap: () => appState.setModuleIndex(4),
          ),
          _SidebarIcon(
            icon: Icons.text_fields,
            tooltip: '字库提取',
            isSelected: appState.selectedModuleIndex == 5,
            onTap: () => appState.setModuleIndex(5),
          ),
          _SidebarIcon(
            icon: Icons.dashboard_customize,
            tooltip: 'UI 设计器',
            isSelected: appState.selectedModuleIndex == 6,
            onTap: () => appState.setModuleIndex(6),
          ),
          _SidebarIcon(
            icon: Icons.hub,
            tooltip: 'ISP Studio',
            isSelected: appState.selectedModuleIndex == 7,
            onTap: () => appState.setModuleIndex(7),
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
        activeModule = const TerminalView();
        break;
      case 1:
        activeModule = const NetworkTerminalView();
        break;
      case 2:
        activeModule = const OscilloscopeView();
        break;
      case 3:
        activeModule = const HexEditorView();
        break;
      case 4:
        activeModule = const TextEditorView();
        break;
      case 5:
        activeModule = const FontExtractorView();
        break;
      case 6:
        activeModule = const UiDesignerView();
        break;
      case 7:
        activeModule = const IspStudioView();
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
    final selectedIndex = context.watch<AppState>().selectedModuleIndex;
    final terminalState = context.watch<TerminalState>();
    final networkState = context.watch<NetworkTerminalState>();

    final statusParts = <String>[
      if (terminalState.isConnected) '${terminalState.serialPort} - ${terminalState.baudRate}',
      if (networkState.isConnected) '${networkState.host}:${networkState.port}',
    ];
    String statusRight = statusParts.isEmpty ? '未连接' : statusParts.join(' | ');

    if (selectedIndex == 7) {
      final ispState = context.watch<IspStudioState>();
      return Container(
        height: 28,
        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.8),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    // 导出中优先显示导出状态行（分辨率/帧率/时长/ETA/实时
                    // 帧率），监听 exportInfoTick（250ms 节流）；其余时候
                    // 播放中的逐帧状态（帧号/FPS/停滞）只监听 frameTick，
                    // 不依赖全树 notifyListeners。
                    child: ValueListenableBuilder<int>(
                      valueListenable: ispState.exportInfoTick,
                      builder: (context, tick, child) {
                        final info = ispState.exportVideoInfo;
                        if (info != null) {
                          return Text(
                            info.statusLine(),
                            style: const TextStyle(
                                fontSize: 12, color: Colors.white),
                            overflow: TextOverflow.ellipsis,
                          );
                        }
                        return ValueListenableBuilder<int>(
                          valueListenable: ispState.frameTick,
                          builder: (context, tick, child) {
                            final msg = ispState.statusMessage.isNotEmpty
                                ? ispState.statusMessage
                                : 'ISP Studio 准备就绪';
                            return Text(
                              msg,
                              style: const TextStyle(
                                  fontSize: 12, color: Colors.white),
                              overflow: TextOverflow.ellipsis,
                            );
                          },
                        );
                      },
                    ),
                  ),
                  if (ispState.errors.isNotEmpty) ...[
                    const SizedBox(width: 12),
                    Flexible(
                      child: Tooltip(
                        message: ispState.errors.join('\n'),
                        child: Text(
                          ispState.errors.first,
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFFCF6679)),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (ispState.isProcessing) ...[
                  // 百分比监听 progressTick 逐 tick 局部刷新（平滑
                  // 插值），不随状态栏整体重建。
                  ValueListenableBuilder<double>(
                    valueListenable: ispState.progressTick,
                    builder: (context, value, _) => Text(
                      '处理中 ${(value * 100).toStringAsFixed(0)}%',
                      style:
                          const TextStyle(fontSize: 12, color: Colors.white),
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                Text(
                  statusRight,
                  style: const TextStyle(fontSize: 12, color: Colors.white),
                ),
              ],
            ),
          ],
        ),
      );
    }

    String statusLeft = (terminalState.isConnected || networkState.isConnected) ? '正在运行' : '准备就绪';

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
  final IconData? icon;
  final Widget Function(Color color)? iconBuilder;
  final String tooltip;
  final bool isSelected;
  final VoidCallback onTap;

  const _SidebarIcon({
    this.icon,
    this.iconBuilder,
    required this.tooltip,
    required this.isSelected,
    required this.onTap,
  }) : assert(icon != null || iconBuilder != null);

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
          child: widget.iconBuilder != null
              ? Center(child: widget.iconBuilder!(widget.isSelected ? colorScheme.primary : Colors.grey))
              : Icon(
                  widget.icon,
                  color: widget.isSelected ? colorScheme.primary : Colors.grey,
                  size: 22,
                ),
        ),
      ),
    );
  }
}


/// 示波器侧边栏图标：屏幕 + 底座 + 方波波形
class _OscilloscopeIcon extends StatelessWidget {
  final Color color;

  const _OscilloscopeIcon({required this.color});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size.square(22),
      painter: _OscilloscopePainter(color),
    );
  }
}

class _OscilloscopePainter extends CustomPainter {
  final Color color;

  _OscilloscopePainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 22.0; // 以 22x22 为设计基准等比缩放
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5 * s
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // 屏幕（圆角矩形）
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(1.6 * s, 2.4 * s, 20.4 * s, 16.4 * s),
        Radius.circular(2.6 * s),
      ),
      stroke,
    );

    // 底座
    canvas.drawLine(Offset(11 * s, 16.4 * s), Offset(11 * s, 19 * s), stroke);
    canvas.drawLine(Offset(7.6 * s, 19.4 * s), Offset(14.4 * s, 19.4 * s), stroke);

    // 方波波形
    final wave = Path()
      ..moveTo(3.6 * s, 9.4 * s)
      ..lineTo(5.8 * s, 9.4 * s)
      ..lineTo(5.8 * s, 6.0 * s)
      ..lineTo(9.6 * s, 6.0 * s)
      ..lineTo(9.6 * s, 12.8 * s)
      ..lineTo(13.4 * s, 12.8 * s)
      ..lineTo(13.4 * s, 6.0 * s)
      ..lineTo(17.2 * s, 6.0 * s)
      ..lineTo(17.2 * s, 9.4 * s)
      ..lineTo(18.6 * s, 9.4 * s);
    canvas.drawPath(
      wave,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4 * s
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_OscilloscopePainter oldDelegate) => oldDelegate.color != color;
}
