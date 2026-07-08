
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../providers/oscilloscope_state.dart';

class MinimapWidget extends StatefulWidget {
  const MinimapWidget({super.key});

  @override
  State<MinimapWidget> createState() => _MinimapWidgetState();
}

class _MinimapWidgetState extends State<MinimapWidget> {
  void _handlePan(DragUpdateDetails details, OscilloscopeState state, double width) {
    _updateScrollOffset(details.localPosition.dx, state, width);
  }

  void _handleTap(TapDownDetails details, OscilloscopeState state, double width) {
    _updateScrollOffset(details.localPosition.dx, state, width);
  }

  void _updateScrollOffset(double localX, OscilloscopeState state, double width) {
    double latestX = _getLatestX(state);
    if (latestX <= 0 || width <= 0) return;

    double activeScale = state.xScale;
    double minScale = state.chartWidth / state.minimapMaxPoints;
    if (activeScale < minScale) {
      activeScale = minScale;
    }

    double windowPoints = state.chartWidth / activeScale;
    double centerPointIndex = (localX / width) * state.minimapMaxPoints;
    double startPointIndex = centerPointIndex - windowPoints / 2;
    
    double newScrollOffset = (latestX - startPointIndex) * activeScale - state.chartWidth;

    double maxScroll = 0;
    if (latestX * activeScale > state.chartWidth) {
      maxScroll = latestX * activeScale - state.chartWidth;
    }

    if (newScrollOffset > maxScroll) newScrollOffset = maxScroll;
    if (newScrollOffset < 0) newScrollOffset = 0;

    state.setXScrollOffset(newScrollOffset);
  }

  double _getLatestX(OscilloscopeState state) {
    return state.latestX;
  }

  @override
  Widget build(BuildContext context) {
    final state = context.read<OscilloscopeState>();

    return LayoutBuilder(
      builder: (context, constraints) {
        return GestureDetector(
          onPanDown: (_) => state.setDraggingMinimap(true),
          onPanStart: (_) => state.setDraggingMinimap(true),
          onPanEnd: (_) => state.setDraggingMinimap(false),
          onPanCancel: () => state.setDraggingMinimap(false),
          onPanUpdate: (details) => _handlePan(details, state, constraints.maxWidth),
          onTapDown: (details) {
            state.setDraggingMinimap(true);
            _handleTap(details, state, constraints.maxWidth);
          },
          onTapUp: (_) => state.setDraggingMinimap(false),
          onTapCancel: () => state.setDraggingMinimap(false),
          child: Container(
            color: Colors.black,
            child: Column(
              children: [
                Expanded(
                  child: ClipRect(
                    child: Stack(
                      children: [
                        RepaintBoundary(
                          child: Selector<OscilloscopeState, Object>(
                            selector: (context, s) => Object.hash(
                              s.totalPointsAdded,
                              s.chartHeight,
                              s.chartWidth,
                              Object.hashAll(s.channels.map((c) => Object.hash(c.isVisible, c.color, c.yOffset, c.yScale))),
                              Object.hashAll(s.digitalChannel.enabledPins),
                              Object.hashAll(s.digitalChannel.buses.map((b) => Object.hash(b.color, b.yOffset, b.startPin, b.endPin, b.isExpanded))),
                            ),
                            builder: (context, _, child) {
                              return CustomPaint(
                                size: Size.infinite,
                                painter: MinimapWaveformPainter(state: state),
                              );
                            },
                          ),
                        ),
                        CustomPaint(
                          size: Size.infinite,
                          painter: MinimapOverlayPainter(state: state),
                        ),
                      ],
                    ),
                  ),
                ),
                SizedBox(
                  height: 8.0,
                  width: double.infinity,
                  child: CustomPaint(
                    painter: MinimapProgressBarPainter(state: state),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class MinimapWaveformPainter extends CustomPainter {
  final OscilloscopeState state;

  MinimapWaveformPainter({
    required this.state,
  });

  @override
  void paint(Canvas canvas, Size size) {
    double latestX = state.latestX;

    bool hasData = latestX > 0;

    if (hasData) {
      double yRatio = state.chartHeight > 0 ? (size.height / state.chartHeight) : (size.height / 600.0);

      // 1. Draw Analog Channels
      for (var ch in state.channels) {
        if (!ch.isVisible || ch.count == 0) continue;

        final paint = Paint()
          ..color = ch.color.withValues(alpha: 0.8)
          ..strokeWidth = 1.0
          ..style = PaintingStyle.stroke;

        int startIndex = ch.count == ch.maxPoints ? ch.head : 0;
        double mappedOffset = ch.yOffset * yRatio;
        double mappedScale = ch.yScale * yRatio;
        double midY = size.height / 2 + mappedOffset;

        double pointsPerPixel = state.minimapMaxPoints / size.width;
        if (pointsPerPixel > 2) {
          int ppp = pointsPerPixel.floor();
          Path path = Path();
          
          for (int i = 0; i < ch.count; i += ppp) {
            int chunkEnd = i + ppp - 1;
            if (chunkEnd >= ch.count) chunkEnd = ch.count - 1;

            double minY = double.infinity;
            double maxY = -double.infinity;

            for (int j = i; j <= chunkEnd; ) {
              int bufferIdx = (startIndex + j) % ch.maxPoints;
              int offsetInChunk = bufferIdx % OscilloscopeState.chunkSize;
              int remainingInLoop = chunkEnd - j + 1;
              
              if (offsetInChunk == 0 && remainingInLoop >= OscilloscopeState.chunkSize) {
                int cacheIdx = bufferIdx ~/ OscilloscopeState.chunkSize;
                if (ch.chunkMins[cacheIdx] < minY) minY = ch.chunkMins[cacheIdx];
                if (ch.chunkMaxs[cacheIdx] > maxY) maxY = ch.chunkMaxs[cacheIdx];
                j += OscilloscopeState.chunkSize;
              } else {
                double val = ch.points[bufferIdx];
                if (val < minY) minY = val;
                if (val > maxY) maxY = val;
                j++;
              }
            }

            double x = (i / state.minimapMaxPoints) * size.width;
            if (i == 0) {
              path.moveTo(x, midY - (minY * mappedScale));
            } else {
              path.lineTo(x, midY - (minY * mappedScale));
            }
            path.lineTo(x, midY - (maxY * mappedScale));
          }
          canvas.drawPath(path, paint);
        } else {
          Path path = Path();
          bool first = true;
          for (int i = 0; i < ch.count; i++) {
            int bufferIdx = (startIndex + i) % ch.maxPoints;
            double val = ch.points[bufferIdx];
            double x = (i / state.minimapMaxPoints) * size.width;
            double y = midY - (val * mappedScale);
            if (first) {
               path.moveTo(x, y);
               first = false;
            } else {
               path.lineTo(x, y);
            }
          }
          canvas.drawPath(path, paint);
        }
      }

      // 2. Draw Digital Channels
      if (state.digitalChannel.count > 0 && state.digitalChannel.enabledPins.isNotEmpty) {
        int startIndex = state.digitalChannel.count == state.digitalChannel.maxPoints ? state.digitalChannel.head : 0;
        
        for (int pin in state.digitalChannel.enabledPins) {
          Color pinColor = Colors.greenAccent.withValues(alpha: 0.8);
          double baseY = (state.digitalChannel.pinYOffsets[pin] ?? (100.0 + pin * 30.0)) * yRatio;
          
          for (var bus in state.digitalChannel.buses) {
            int minPin = bus.startPin < bus.endPin ? bus.startPin : bus.endPin;
            int maxPin = bus.startPin > bus.endPin ? bus.startPin : bus.endPin;
            if (pin >= minPin && pin <= maxPin) {
              pinColor = bus.color.withValues(alpha: 0.8);
              baseY = bus.yOffset * yRatio;
              break;
            }
          }

          final paint = Paint()
            ..color = pinColor
            ..strokeWidth = 1.0
            ..style = PaintingStyle.stroke;

          double amplitude = 20.0 * yRatio;
          if (amplitude < 2.0) amplitude = 2.0;
          
          double pointsPerPixel = state.minimapMaxPoints / size.width;

          if (pointsPerPixel > 2) {
            int ppp = pointsPerPixel.floor();
            Path path = Path();
            bool first = true;
            int prevState = 0;
            
            for (int i = 0; i < state.digitalChannel.count; i += ppp) {
              int chunkEnd = i + ppp - 1;
              if (chunkEnd >= state.digitalChannel.count) chunkEnd = state.digitalChannel.count - 1;

              bool has0 = false;
              bool has1 = false;
              
              for (int j = i; j <= chunkEnd; ) {
                int bufferIdx = (startIndex + j) % state.digitalChannel.maxPoints;
                int offsetInChunk = bufferIdx % OscilloscopeState.chunkSize;
                int remainingInLoop = chunkEnd - j + 1;
                
                if (offsetInChunk == 0 && remainingInLoop >= OscilloscopeState.chunkSize) {
                  int cacheIdx = bufferIdx ~/ OscilloscopeState.chunkSize;
                  if ((state.digitalChannel.chunkOrs[cacheIdx] & (1 << pin)) != 0) {
                    has1 = true;
                  }
                  if ((state.digitalChannel.chunkAnds[cacheIdx] & (1 << pin)) == 0) {
                    has0 = true;
                  }
                  j += OscilloscopeState.chunkSize;
                } else {
                  if ((state.digitalChannel.states[bufferIdx] & (1 << pin)) != 0) {
                    has1 = true;
                  } else {
                    has0 = true;
                  }
                  j++;
                }
                if (has0 && has1) break;
              }

              int stateVal = (has0 && has1) ? 2 : (has1 ? 1 : 0);
              double x = (i / state.minimapMaxPoints) * size.width;

              if (first) {
                if (stateVal == 2) {
                  path.moveTo(x, baseY);
                  path.lineTo(x, baseY - amplitude);
                } else {
                  path.moveTo(x, baseY - stateVal * amplitude);
                }
                first = false;
              } else {
                if (stateVal == 2) {
                  if (prevState == 0) {
                    path.lineTo(x, baseY);
                    path.lineTo(x, baseY - amplitude);
                  } else if (prevState == 1) {
                    path.lineTo(x, baseY - amplitude);
                    path.lineTo(x, baseY);
                  } else {
                    path.lineTo(x, baseY);
                    path.lineTo(x, baseY - amplitude);
                  }
                } else if (stateVal == 0) {
                  if (prevState == 1 || prevState == 2) {
                    path.lineTo(x, baseY - amplitude);
                    path.lineTo(x, baseY);
                  } else {
                    path.lineTo(x, baseY);
                  }
                } else if (stateVal == 1) {
                  if (prevState == 0 || prevState == 2) {
                    path.lineTo(x, baseY);
                    path.lineTo(x, baseY - amplitude);
                  } else {
                    path.lineTo(x, baseY - amplitude);
                  }
                }
              }
              prevState = stateVal;
            }
            canvas.drawPath(path, paint);
          } else {
            Path path = Path();
            bool first = true;
            int prevState = 0;
            for (int i = 0; i < state.digitalChannel.count; i++) {
              int idx = (startIndex + i) % state.digitalChannel.maxPoints;
              double x = (i / state.minimapMaxPoints) * size.width;
              int bitState = (state.digitalChannel.states[idx] & (1 << pin)) != 0 ? 1 : 0;
              double y = baseY - (bitState * amplitude);

              if (first) {
                path.moveTo(x, y);
                first = false;
              } else if (bitState != prevState) {
                double prevY = baseY - (prevState * amplitude);
                path.lineTo(x, prevY);
                path.lineTo(x, y);
              }
              if (i == state.digitalChannel.count - 1) {
                path.lineTo(x, baseY - (bitState * amplitude));
              }
              prevState = bitState;
            }
            canvas.drawPath(path, paint);
          }
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant MinimapWaveformPainter oldDelegate) {
    return true; // Driven by the Selector, so always repaint when rebuilt
  }
}

class MinimapOverlayPainter extends CustomPainter {
  final OscilloscopeState state;

  MinimapOverlayPainter({
    required this.state,
  }) : super(repaint: state);

  @override
  void paint(Canvas canvas, Size size) {
    double latestX = state.latestX;

    bool hasData = latestX > 0;

    double activeScale = state.xScale;
    double minScale = state.chartWidth / state.minimapMaxPoints;
    if (activeScale < minScale) {
      activeScale = minScale;
    }

    double maxScroll = latestX * activeScale;
    double clampedScrollOffset = state.xScrollOffset;
    if (clampedScrollOffset > maxScroll) clampedScrollOffset = maxScroll;

    double startI;
    if (latestX * activeScale <= state.chartWidth) {
      startI = -clampedScrollOffset / activeScale;
    } else {
      startI = latestX - state.chartWidth / activeScale - clampedScrollOffset / activeScale;
    }

    double windowPoints = state.chartWidth / activeScale;
    
    double windowStartX = 0;
    double windowWidth = size.width;
    
    if (hasData) {
      double endI = startI + windowPoints;
      
      double maxPoints = state.minimapMaxPoints.toDouble();
      windowStartX = (startI / maxPoints) * size.width;
      double windowEndX = (endI / maxPoints) * size.width;
      
      if (windowStartX < 0) windowStartX = 0;
      if (windowEndX > size.width) windowEndX = size.width;
      
      windowWidth = windowEndX - windowStartX;
      if (windowWidth < 0) windowWidth = 0;
    }

    final overlayPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.2)
      ..style = PaintingStyle.fill;
      
    final borderPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.8)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    Rect windowRect = Rect.fromLTWH(windowStartX, 0, windowWidth, size.height - 1.0);

    // Draw the window overlay
    canvas.drawRect(windowRect, overlayPaint);
    canvas.drawRect(windowRect, borderPaint);
    
    // Draw the search matches
    if (state.searchMatches.isNotEmpty) {
      final matchPaint = Paint()
        ..color = state.searchMatchColor.withValues(alpha: 0.5)
        ..strokeWidth = 1.0;
        
      final currentMatchPaint = Paint()
        ..color = Colors.orangeAccent
        ..strokeWidth = 2.0;
        
      double maxPoints = state.minimapMaxPoints.toDouble();
      final textPainter = TextPainter(textDirection: TextDirection.ltr);
      
      for (int i = 0; i < state.searchMatches.length; i++) {
        double t = state.searchMatches[i].time;
        double pointIndex = t * state.sampleRate;
        double x = (pointIndex / maxPoints) * size.width;
        
        if (x >= 0 && x <= size.width) {
          bool isCurrent = i == state.currentSearchMatchIndex;
          canvas.drawLine(
            Offset(x, 0),
            Offset(x, size.height),
            isCurrent ? currentMatchPaint : matchPaint
          );
          
          String text = '${i + 1}';
          textPainter.text = TextSpan(
             text: text,
             style: TextStyle(color: isCurrent ? Colors.orangeAccent : Colors.yellowAccent, fontSize: 9, fontWeight: FontWeight.bold)
          );
          textPainter.layout();
          
          double boxWidth = textPainter.width + 4;
          double boxHeight = textPainter.height + 2;
          
          canvas.drawRect(
             Rect.fromLTWH(x - boxWidth / 2, 0, boxWidth, boxHeight),
             Paint()..color = Colors.black.withValues(alpha: 0.8)..style = PaintingStyle.fill
          );
          
          textPainter.paint(canvas, Offset(x - textPainter.width / 2, 1));
          
          if (isCurrent) {
            Path triangle = Path();
            triangle.moveTo(x - 4, boxHeight);
            triangle.lineTo(x + 4, boxHeight);
            triangle.lineTo(x, boxHeight + 6);
            triangle.close();
            canvas.drawPath(triangle, Paint()..color = Colors.orangeAccent..style = PaintingStyle.fill);
          }
        }
      }
    }
    
    // Draw Cursors
    if (state.showCursors && state.showXCursors) {
      double maxPoints = state.minimapMaxPoints.toDouble();
      
      void drawCursor(double time, String label, Color color) {
         double pointIndex = time * state.sampleRate;
         double x = (pointIndex / maxPoints) * size.width;
         if (x >= 0 && x <= size.width) {
            final paint = Paint()
              ..color = color
              ..strokeWidth = 1.0;
            canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
            
            final textPainter = TextPainter(
              text: TextSpan(text: label, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.bold)),
              textDirection: TextDirection.ltr,
            );
            textPainter.layout();
            
            double boxWidth = textPainter.width + 4;
            double boxHeight = textPainter.height + 2;
            
            // Draw at bottom of minimap to avoid overlapping with search matches
            canvas.drawRect(
               Rect.fromLTWH(x - boxWidth / 2, size.height - boxHeight - 2, boxWidth, boxHeight),
               Paint()..color = Colors.black.withValues(alpha: 0.8)..style = PaintingStyle.fill
            );
            textPainter.paint(canvas, Offset(x - textPainter.width / 2, size.height - boxHeight - 1));
         }
      }
      
      drawCursor(state.cursorX1, 'X1', Colors.yellowAccent);
      drawCursor(state.cursorX2, 'X2', Colors.yellowAccent);
    }

    // Draw Trigger Marker
    if (!state.isWaitingForTrigger && state.postTriggerCount > 0 && state.postTriggerCount <= state.maxCount) {
      double maxPoints = state.minimapMaxPoints.toDouble();
      int triggerIndex = state.maxCount - state.postTriggerCount;
      double x = (triggerIndex / maxPoints) * size.width;

      if (x >= 0 && x <= size.width) {
        final triggerPaint = Paint()
          ..color = Colors.orangeAccent
          ..strokeWidth = 1.0;
        
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), triggerPaint);
        
        final textPainter = TextPainter(
          text: const TextSpan(text: 'T', style: TextStyle(color: Colors.orangeAccent, fontSize: 10, fontWeight: FontWeight.bold)),
          textDirection: TextDirection.ltr,
        );
        textPainter.layout();
        
        double boxWidth = textPainter.width + 4;
        double boxHeight = textPainter.height + 2;
        
        // Draw 'T' at top of minimap (slightly offset to avoid overlap if possible, or just top)
        canvas.drawRect(
           Rect.fromLTWH(x - boxWidth / 2, 0, boxWidth, boxHeight),
           Paint()..color = Colors.black.withValues(alpha: 0.8)..style = PaintingStyle.fill
        );
        textPainter.paint(canvas, Offset(x - textPainter.width / 2, 1));
        
        // Draw a small triangle pointing down
        Path triangle = Path();
        triangle.moveTo(x - 4, boxHeight);
        triangle.lineTo(x + 4, boxHeight);
        triangle.lineTo(x, boxHeight + 6);
        triangle.close();
        canvas.drawPath(triangle, Paint()..color = Colors.orangeAccent..style = PaintingStyle.fill);
      }
    }
  }

  @override
  bool shouldRepaint(covariant MinimapOverlayPainter oldDelegate) {
    return true; // We always repaint when state changes (xScrollOffset)
  }
}

class MinimapProgressBarPainter extends CustomPainter {
  final OscilloscopeState state;

  MinimapProgressBarPainter({
    required this.state,
  }) : super(repaint: state);

  @override
  void paint(Canvas canvas, Size size) {
    int maxCount = state.maxCount;

    double usagePercent = maxCount / OscilloscopeState.maxPointsPerChannel;
    if (usagePercent > 1.0) usagePercent = 1.0;

    int headPos = 0;
    if (state.digitalChannel.count == maxCount) {
      headPos = state.digitalChannel.head;
    } else {
      for (var ch in state.channels) {
        if (ch.count == maxCount) {
          headPos = ch.head;
          break;
        }
      }
    }

    double headPercent = headPos / state.minimapMaxPoints;
    if (headPercent > 1.0) headPercent = 1.0;

    final progressBarBackgroundPaint = Paint()..style = PaintingStyle.fill;
    final progressBarPaint = Paint()..style = PaintingStyle.fill;

    double barWidth = 0.0;

    if (maxCount < OscilloscopeState.maxPointsPerChannel) {
      progressBarBackgroundPaint.color = Colors.grey.withValues(alpha: 0.3);
      Color progressColor = Colors.blueAccent.withValues(alpha: 0.8);
      if (usagePercent > 0.8) {
        progressColor = Colors.orangeAccent.withValues(alpha: 0.8);
      }
      progressBarPaint.color = progressColor;
      barWidth = size.width * usagePercent;
    } else {
      progressBarBackgroundPaint.color = Colors.green.withValues(alpha: 0.4);
      progressBarPaint.color = Colors.greenAccent.withValues(alpha: 0.9);
      barWidth = size.width * headPercent;
    }

    Rect bgRect = Rect.fromLTWH(0, 0, size.width, size.height);
    Rect progressRect = Rect.fromLTWH(0, 0, barWidth, size.height);

    canvas.drawRect(bgRect, progressBarBackgroundPaint);
    canvas.drawRect(progressRect, progressBarPaint);

    final borderLinePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.3)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;
      
    canvas.drawLine(Offset(0, 0), Offset(size.width, 0), borderLinePaint);
    canvas.drawLine(Offset(0, size.height), Offset(size.width, size.height), borderLinePaint);
  }

  @override
  bool shouldRepaint(covariant MinimapProgressBarPainter oldDelegate) {
    return true;
  }
}
