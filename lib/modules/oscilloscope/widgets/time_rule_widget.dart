import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../providers/oscilloscope_state.dart';

class TimeRuleWidget extends StatelessWidget {
  const TimeRuleWidget({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<OscilloscopeState>();

    return Container(
      color: const Color(0xFF161616),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return ClipRect(
            child: CustomPaint(
              size: Size(constraints.maxWidth, constraints.maxHeight),
              painter: TimeRulePainter(state: state),
            ),
          );
        }
      ),
    );
  }
}

class TimeRulePainter extends CustomPainter {
  final OscilloscopeState state;

  TimeRulePainter({required this.state});

  String formatTime(double seconds) {
    if (seconds == 0) return '0s';
    
    double absSeconds = seconds.abs();
    if (absSeconds >= 1.0) {
      return '${seconds.toStringAsFixed(2)}s';
    } else if (absSeconds >= 1e-3) {
      return '${(seconds * 1e3).toStringAsFixed(1)}ms';
    } else if (absSeconds >= 1e-6) {
      return '${(seconds * 1e6).toStringAsFixed(1)}μs';
    } else {
      return '${(seconds * 1e9).toStringAsFixed(1)}ns';
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    double activeScale = state.xScale;
    double latestX = 0;
    if (state.channels.isNotEmpty && state.channels[0].count > 0) {
      latestX = (state.channels[0].count - 1).toDouble();
    } else if (state.digitalChannel.count > 0) {
      latestX = (state.digitalChannel.count - 1).toDouble();
    }

    double translateX = size.width - latestX * activeScale + state.xScrollOffset;
    double sampleRate = state.sampleRate;
    
    if (sampleRate <= 0) return;

    Paint majorTickPaint = Paint()
      ..color = Colors.grey.shade400
      ..strokeWidth = 1.0;
      
    Paint minorTickPaint = Paint()
      ..color = Colors.grey.shade700
      ..strokeWidth = 1.0;

    // Determine the grid size in time based on visual spacing
    double desiredPixelSpacing = 100.0;
    double desiredTimeSpacing = (desiredPixelSpacing / activeScale) / sampleRate;
    
    // Find a nice round time spacing (1, 2, 5, 10...)
    double exponent = (desiredTimeSpacing > 0) ? (math.log(desiredTimeSpacing) / math.ln10).floorToDouble() : 0;
    double magnitude = math.pow(10, exponent).toDouble();
    double mantissa = desiredTimeSpacing / magnitude;
    
    double niceMantissa = 1.0;
    if (mantissa < 1.5) {
      niceMantissa = 1.0;
    } else if (mantissa < 3.5) {
      niceMantissa = 2.0;
    } else if (mantissa < 7.5) {
      niceMantissa = 5.0;
    } else {
      niceMantissa = 10.0;
    }
    
    double niceTimeSpacing = niceMantissa * magnitude;
    
    // Calculate the left and right time boundaries of the screen
    double startTime = (-translateX / activeScale) / sampleRate;
    double endTime = ((size.width - translateX) / activeScale) / sampleRate;
    
    // Find the first major tick
    double firstTickTime = (startTime / niceTimeSpacing).ceil() * niceTimeSpacing;
    
    for (double t = firstTickTime; t <= endTime; t += niceTimeSpacing) {
      double px = (t * sampleRate * activeScale) + translateX;
      
      // Draw major tick
      canvas.drawLine(Offset(px, size.height - 10), Offset(px, size.height), majorTickPaint);
      
      // Draw minor ticks
      for (int m = 1; m < 5; m++) {
        double minorT = t + (niceTimeSpacing / 5) * m;
        if (minorT > endTime) break;
        double minorPx = (minorT * sampleRate * activeScale) + translateX;
        canvas.drawLine(Offset(minorPx, size.height - 5), Offset(minorPx, size.height), minorTickPaint);
      }
      
      // Draw text
      TextSpan span = TextSpan(style: TextStyle(color: Colors.grey.shade300, fontSize: 10), text: formatTime(t));
      TextPainter tp = TextPainter(text: span, textAlign: TextAlign.center, textDirection: TextDirection.ltr);
      tp.layout();
      double textX = px - tp.width / 2;
      // Clamp text coordinate to avoid drawing outside the left/right boundaries of the widget
      if (textX < 2.0) textX = 2.0;
      if (textX + tp.width > size.width - 2.0) textX = size.width - tp.width - 2.0;
      tp.paint(canvas, Offset(textX, size.height - 22));
    }
    
    // Also draw the bottom border line for the time rule
    canvas.drawLine(Offset(0, size.height), Offset(size.width, size.height), majorTickPaint);
  }

  @override
  bool shouldRepaint(covariant TimeRulePainter oldDelegate) {
    return true; // Simple approach: repaint on every frame. Optimization can be done later by comparing state variables.
  }
}
