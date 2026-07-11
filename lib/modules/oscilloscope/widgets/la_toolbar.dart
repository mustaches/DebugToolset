import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../providers/oscilloscope_state.dart';
import '../../../utils/hover_builder.dart';
import 'la_trigger_menu_dialog.dart';
import 'bus_search_dialog.dart';

class LogicAnalyzerToolbar extends StatelessWidget {
  const LogicAnalyzerToolbar({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<OscilloscopeState>();

    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        border: Border(
          bottom: BorderSide(color: Colors.grey.shade800, width: 1.0),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8.0),
      child: Row(
        children: [
          // Navigation & View Controls
          _buildToolbarButton(
            icon: Icons.zoom_in,
            label: '',
            tooltip: 'Zoom In',
            onTap: () {
              state.zoomFromCenter(1.2);
            },
          ),
          _buildToolbarButton(
            icon: Icons.zoom_out,
            label: '',
            tooltip: 'Zoom Out',
            onTap: () {
              state.zoomFromCenter(1 / 1.2);
            },
          ),
          _buildToolbarButton(
            icon: Icons.fullscreen,
            label: '',
            tooltip: 'Zoom to Fit',
            onTap: () {
              state.autoSetup();
            },
          ),
          const SizedBox(width: 4),
          Container(
            height: 20,
            width: 1,
            color: Colors.grey.shade700,
          ),
          const SizedBox(width: 4),
          _buildToolbarButton(
            icon: Icons.skip_previous,
            label: '',
            tooltip: 'Jump to Start',
            onTap: () {
              state.jumpToStart();
            },
          ),
          _buildToolbarButton(
            icon: Icons.fast_rewind,
            label: '',
            tooltip: 'Rewind',
            onTapDown: (_) => state.startScrolling(-1.0),
            onTapUp: (_) => state.stopScrolling(),
            onTapCancel: () => state.stopScrolling(),
          ),
          _buildToolbarButton(
            customIcon: CustomPaint(
              size: const Size(14, 14),
              painter: TriggerIconPainter(Colors.grey.shade400),
            ),
            label: '',
            tooltip: 'Jump to Trigger',
            onTap: () {
              state.jumpToTrigger();
            },
          ),
          _buildToolbarButton(
            icon: Icons.fast_forward,
            label: '',
            tooltip: 'Fast Forward',
            onTapDown: (_) => state.startScrolling(1.0),
            onTapUp: (_) => state.stopScrolling(),
            onTapCancel: () => state.stopScrolling(),
          ),
          _buildToolbarButton(
            icon: Icons.skip_next,
            label: '',
            tooltip: 'Jump to End',
            onTap: () {
              state.jumpToEnd();
            },
          ),
          const SizedBox(width: 4),
          Container(
            height: 20,
            width: 1,
            color: Colors.grey.shade700,
          ),
          const SizedBox(width: 4),
          _buildToolbarButton(
            icon: Icons.search,
            label: '',
            tooltip: 'Search',
            onTap: () {
              showDialog(
                context: context,
                useRootNavigator: false,
                builder: (context) => const BusSearchDialog(),
              );
            },
          ),
          if (state.searchMatches.isNotEmpty) ...[
             const SizedBox(width: 4),
             _buildToolbarButton(
               icon: Icons.navigate_before,
               label: '',
               tooltip: 'Previous Match (Shift+F3)',
               onTap: () => state.jumpToPrevSearchMatch(),
             ),
             Container(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                alignment: Alignment.center,
                child: Text('${state.currentSearchMatchIndex + 1}/${state.searchMatches.length}', style: const TextStyle(color: Colors.white70, fontSize: 12)),
             ),
             _buildToolbarButton(
               icon: Icons.navigate_next,
               label: '',
               tooltip: 'Next Match (F3)',
               onTap: () => state.jumpToNextSearchMatch(),
             ),
             _buildToolbarButton(
               icon: Icons.close,
               label: '',
               tooltip: 'Clear Matches',
               onTap: () => state.clearSearchMatches(),
             ),
          ],
          const SizedBox(width: 4),
          Container(
            height: 20,
            width: 1,
            color: Colors.grey.shade700,
          ),
          const SizedBox(width: 4),
          _buildToolbarButton(
            icon: Icons.compare_arrows,
            label: 'Xcursors',
            tooltip: state.showCursors ? 'X Cursor Off' : 'X Cursor On',
            isActive: state.showCursors,
            onTap: () => state.toggleCursors(),
          ),
          if (state.showCursors) ...[
            const SizedBox(width: 2),
            _buildToolbarButton(
              customIcon: CustomPaint(
                size: const Size(14, 14),
                painter: CursorResetIconPainter(Colors.grey.shade400),
              ),
              label: '',
              tooltip: 'Reset Cursors (X1 → 1/3, X2 → 2/3)',
              isActive: false,
              onTap: () => state.resetCursorsToThirds(),
            ),
            const SizedBox(width: 4),
            _buildToolbarButton(
              icon: state.linkCursors ? Icons.link : Icons.link_off,
              label: '',
              tooltip: state.linkCursors ? 'Unlink Cursors' : 'Link Cursors',
              isActive: state.linkCursors,
              color: state.linkCursors ? Colors.greenAccent : null,
              onTap: () => state.toggleLinkCursors(),
            ),
            const SizedBox(width: 4),
            _buildToolbarButton(
              customIcon: CustomPaint(
                size: const Size(14, 14),
                painter: MagnetIconPainter(
                  state.snapToEdge ? Colors.orangeAccent : Colors.grey.shade400,
                ),
              ),
              label: '',
              tooltip: state.snapToEdge ? 'Disable Snap to Edge' : 'Enable Snap to Edge',
              isActive: state.snapToEdge,
              color: state.snapToEdge ? Colors.orangeAccent : null,
              onTap: () => state.toggleSnapToEdge(),
            ),
            if (state.showXCursors && !state.isCursorX1Visible) ...[
              const SizedBox(width: 4),
              _buildToolbarButton(
                label: 'X1',
                tooltip: 'Center X1',
                color: Colors.yellowAccent,
                isActive: true,
                onTap: () => state.centerCursorX1(),
              ),
            ],
            if (state.showXCursors && !state.isCursorX2Visible) ...[
              const SizedBox(width: 4),
              _buildToolbarButton(
                label: 'X2',
                tooltip: 'Center X2',
                color: Colors.yellowAccent,
                isActive: true,
                onTap: () => state.centerCursorX2(),
              ),
            ],
          ],
          const SizedBox(width: 4),
          Container(
            height: 20,
            width: 1,
            color: Colors.grey.shade700,
          ),
          const SizedBox(width: 4),
          _buildToolbarButton(
            icon: Icons.settings_applications,
            label: 'Trigger Set',
            tooltip: 'Trigger Settings',
            onTap: () {
              showDialog(
                context: context,
                useRootNavigator: false,
                builder: (context) => const LATriggerMenuDialog(),
              );
            },
          ),
          
          const Spacer(),

          // Center: Decoders
          _buildToolbarButton(
            icon: Icons.add_box_outlined,
            label: 'Add Decoder',
            onTap: () {
              // Future: show Add Decoder Dialog
              debugPrint('Add Decoder clicked');
            },
          ),

          const Spacer(),

          // Right: Status & Settings
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12.0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.speed, color: Colors.cyanAccent, size: 16),
                const SizedBox(width: 4),
                Text(_formatSampleRate(state.sampleRate), style: const TextStyle(color: Colors.cyanAccent, fontSize: 13)),
              ],
            ),
          ),
          const SizedBox(width: 4),
          _buildTriggerStatusWidget(state),
        ],
      ),
    );
  }

  String _formatSampleRate(double rate) {
    if (rate >= 1e6) {
      return '${(rate / 1e6).toStringAsFixed(1)} MSa/s';
    } else if (rate >= 1e3) {
      return '${(rate / 1e3).toStringAsFixed(1)} kSa/s';
    } else {
      return '${rate.toStringAsFixed(0)} Sa/s';
    }
  }

  Widget _buildTriggerStatusWidget(OscilloscopeState state) {
    List<Widget> children = [];
    Color statusColor = state.triggerSourceType == TriggerSourceType.analog ? Colors.orangeAccent : Colors.cyanAccent;

    children.add(Icon(Icons.bolt, color: statusColor, size: 16));
    children.add(const SizedBox(width: 4));

    if (state.triggerSourceType == TriggerSourceType.analog) {
      children.add(Text('External (OSC)', style: TextStyle(color: statusColor, fontSize: 13)));
    } else {
      final config = state.digitalTrigger;
      if (config.type == DigitalTriggerType.singleChannel) {
        String alias = state.digitalChannel.pinNames[config.pinIndex] ?? '';
        String label = alias.isNotEmpty ? '$alias(D${config.pinIndex})' : 'D${config.pinIndex}';
        children.add(Text('$label ', style: TextStyle(color: statusColor, fontSize: 13)));
        children.add(
          SizedBox(
            width: 24,
            height: 14,
            child: CustomPaint(painter: EdgeIconPainter(config.edge, color: statusColor)),
          )
        );
      } else if (config.type == DigitalTriggerType.bus) {
        String busName = 'D${config.busMsbPin}-D${config.busLsbPin}';
        if (!config.isBusSequence) {
           String val = config.targetValues.isNotEmpty ? '0x${config.targetValues.first.toRadixString(16).toUpperCase()}' : '?';
           children.add(Text('$busName == $val', style: TextStyle(color: statusColor, fontSize: 13)));
        } else {
           children.add(Text('$busName Seq', style: TextStyle(color: statusColor, fontSize: 13)));
        }
      } else if (config.type == DigitalTriggerType.advancedBus) {
        children.add(Text(config.advancedProtocolType ?? "Adv. Bus", style: TextStyle(color: statusColor, fontSize: 13)));
      } else if (config.type == DigitalTriggerType.protocol) {
        children.add(Text(config.protocolTriggerType ?? "Protocol", style: TextStyle(color: statusColor, fontSize: 13)));
      }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12.0),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    );
  }

  Widget _buildToolbarButton({
    IconData? icon,
    Widget? customIcon,
    required String label,
    VoidCallback? onTap,
    GestureTapDownCallback? onTapDown,
    GestureTapUpCallback? onTapUp,
    GestureTapCancelCallback? onTapCancel,
    bool isActive = false,
    String? tooltip,
    Color? color,
  }) {
    Widget btn = HoverBuilder(
      builder: (context, isHovered) {
        return GestureDetector(
          onTap: onTap,
          onTapDown: onTapDown,
          onTapUp: onTapUp,
          onTapCancel: onTapCancel,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 2.0, vertical: 4.0),
            padding: EdgeInsets.symmetric(horizontal: label.isNotEmpty ? 10.0 : 6.0, vertical: 4.0),
            decoration: BoxDecoration(
              color: isActive 
                  ? (color?.withValues(alpha: 0.2) ?? Colors.blueAccent.withValues(alpha: 0.2)) 
                  : (isHovered ? const Color(0xFF333333) : Colors.transparent),
              borderRadius: BorderRadius.circular(4.0),
              border: Border.all(
                color: isActive 
                    ? (color?.withValues(alpha: 0.5) ?? Colors.blueAccent.withValues(alpha: 0.5)) 
                    : (isHovered ? Colors.grey.shade700 : Colors.transparent),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null)
                  Icon(
                    icon,
                    size: 14,
                    color: isActive ? (color ?? Colors.blueAccent) : (color ?? Colors.grey.shade400),
                  )
                else ?customIcon,
                if (label.isNotEmpty) ...[
                  if (icon != null || customIcon != null) const SizedBox(width: 6),
                  Text(
                    label,
                    style: TextStyle(
                      color: isActive ? (color ?? Colors.blueAccent) : (color ?? Colors.grey.shade300),
                      fontSize: 12,
                      fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                ]
              ],
            ),
          ),
        );
      }
    );

    if (tooltip != null) {
      btn = Tooltip(
        message: tooltip,
        textStyle: const TextStyle(fontSize: 12, color: Colors.yellowAccent),
        decoration: BoxDecoration(color: const Color(0xFF222222), borderRadius: BorderRadius.circular(4)),
        child: btn,
      );
    }
    
    return btn;
  }
}

class MagnetIconPainter extends CustomPainter {
  final Color color;
  MagnetIconPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    Paint paint = Paint()
      ..color = color
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.square;

    // U shape (magnet body)
    Path path = Path();
    path.moveTo(size.width * 0.25, size.height * 0.2);
    path.lineTo(size.width * 0.25, size.height * 0.6);
    path.arcToPoint(
      Offset(size.width * 0.75, size.height * 0.6),
      radius: Radius.circular(size.width * 0.25),
      clockwise: false,
    );
    path.lineTo(size.width * 0.75, size.height * 0.2);
    canvas.drawPath(path, paint);

    // Magnet tips
    paint.style = PaintingStyle.fill;
    canvas.drawRect(Rect.fromLTRB(size.width * 0.15, size.height * 0.1, size.width * 0.35, size.height * 0.35), paint);
    canvas.drawRect(Rect.fromLTRB(size.width * 0.65, size.height * 0.1, size.width * 0.85, size.height * 0.35), paint);
  }

  @override
  bool shouldRepaint(covariant MagnetIconPainter oldDelegate) => oldDelegate.color != color;
}

class TriggerIconPainter extends CustomPainter {
  final Color color;
  TriggerIconPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    Paint paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    // Top horizontal bar
    canvas.drawLine(
      Offset(size.width * 0.2, size.height * 0.2), 
      Offset(size.width * 0.8, size.height * 0.2), 
      paint
    );
    // Vertical stem
    canvas.drawLine(
      Offset(size.width * 0.5, size.height * 0.2), 
      Offset(size.width * 0.5, size.height * 0.8), 
      paint
    );
  }

  @override
  bool shouldRepaint(covariant TriggerIconPainter oldDelegate) => oldDelegate.color != color;
}

/// Draws a rectangle divided into thirds by two vertical dashed lines,
/// with small downward arrowheads at 1/3 and 2/3 to indicate cursor placement.
class CursorResetIconPainter extends CustomPainter {
  final Color color;
  CursorResetIconPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final linePaint = Paint()
      ..color = color
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final fillPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    double w = size.width;
    double h = size.height;

    // Outer bounding rectangle
    canvas.drawRect(Rect.fromLTRB(0, h * 0.2, w, h * 0.95), linePaint);

    // Left divider at 1/3
    double x1 = w / 3.0;
    canvas.drawLine(Offset(x1, h * 0.2), Offset(x1, h * 0.95), linePaint);

    // Right divider at 2/3
    double x2 = w * 2.0 / 3.0;
    canvas.drawLine(Offset(x2, h * 0.2), Offset(x2, h * 0.95), linePaint);

    // Downward arrowheads above each divider line
    void drawArrow(double cx) {
      Path arrow = Path();
      arrow.moveTo(cx - h * 0.15, 0);
      arrow.lineTo(cx + h * 0.15, 0);
      arrow.lineTo(cx, h * 0.18);
      arrow.close();
      canvas.drawPath(arrow, fillPaint);
    }
    drawArrow(x1);
    drawArrow(x2);
  }

  @override
  bool shouldRepaint(covariant CursorResetIconPainter oldDelegate) => oldDelegate.color != color;
}
