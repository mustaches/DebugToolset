import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:provider/provider.dart';
import '../../../providers/oscilloscope_state.dart';
import '../models/protocol_decoder.dart';
import 'la_toolbar.dart';

const double digitalAmplitude = 20.0;

Color getDigitalPinColor(int pin) {
  const colors = [
    Colors.cyanAccent,
    Colors.purpleAccent,
    Colors.yellowAccent,
    Colors.lightGreenAccent,
    Colors.pinkAccent,
  ];
  return colors[pin % colors.length];
}

class ChartWidget extends StatefulWidget {
  const ChartWidget({super.key});

  @override
  State<ChartWidget> createState() => _ChartWidgetState();
}

class _ChartWidgetState extends State<ChartWidget> {
  double? _dragStartX;
  double? _dragCurrentX;
  bool _isRightDragging = false;

  
  final ValueNotifier<Offset?> _hoverPosX1 = ValueNotifier(null);
  final ValueNotifier<Offset?> _hoverPosX2 = ValueNotifier(null);
  final ValueNotifier<Offset?> _hoverPosY1 = ValueNotifier(null);
  final ValueNotifier<Offset?> _hoverPosY2 = ValueNotifier(null);

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      if (event.logicalKey == LogicalKeyboardKey.f3) {
        final keys = HardwareKeyboard.instance.logicalKeysPressed;
        bool isShift = keys.contains(LogicalKeyboardKey.shiftLeft) || keys.contains(LogicalKeyboardKey.shiftRight);
        if (mounted) {
          final state = context.read<OscilloscopeState>();
          if (isShift) {
            state.jumpToPrevSearchMatch();
          } else {
            state.jumpToNextSearchMatch();
          }
        }
        return true;
      }
    }
    return false;
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    _hoverPosX1.dispose();
    _hoverPosX2.dispose();
    _hoverPosY1.dispose();
    _hoverPosY2.dispose();
    super.dispose();
  }

  void _applySelectionZoom(double startX, double endX, OscilloscopeState state, BoxConstraints constraints) {
    if ((startX - endX).abs() < 10) return; // Ignore small drags
    
    double left = math.min(startX, endX);
    double right = math.max(startX, endX);
    
    double activeScale = state.xScale;
    double minScale = constraints.maxWidth / OscilloscopeState.maxPointsPerChannel;
    if (activeScale < minScale) activeScale = minScale;
    
    double latestX = 0;
    if (state.channels.isNotEmpty && state.channels[0].count > 0) {
      latestX = (state.channels[0].count - 1).toDouble();
    } else if (state.digitalChannel.count > 0) {
      latestX = (state.digitalChannel.count - 1).toDouble();
    }
    
    double translateX = constraints.maxWidth - latestX * activeScale + state.xScrollOffset;
    
    double leftIndex = (left - translateX) / activeScale;
    double rightIndex = (right - translateX) / activeScale;
    
    double newScale = constraints.maxWidth / (rightIndex - leftIndex);
    
    if (newScale < 0.01) newScale = 0.01;
    if (newScale > 500.0) newScale = 500.0;
    
    double newActiveScale = newScale < minScale ? minScale : newScale;
    
    double newTranslateX = -leftIndex * newActiveScale;
    
    double newScrollOffset = newTranslateX - constraints.maxWidth + latestX * newActiveScale;
    
    double maxScroll = 0;
    if (latestX * newActiveScale > constraints.maxWidth) {
      maxScroll = latestX * newActiveScale - constraints.maxWidth;
    }
    
    if (newScrollOffset > maxScroll) newScrollOffset = maxScroll;
    if (newScrollOffset < 0) newScrollOffset = 0;
    
    state.setTimebase(newScale);
    state.setXScrollOffset(newScrollOffset);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.read<OscilloscopeState>();

    return LayoutBuilder(
      builder: (context, constraints) {
        // Pass the available height to the state so that autoSetup can calculate the slices
        WidgetsBinding.instance.addPostFrameCallback((_) {
          state.updateChartSize(constraints.maxWidth, constraints.maxHeight);
        });
        
        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (event) {
            if (event.buttons == kSecondaryButton) {
              setState(() {
                _dragStartX = event.localPosition.dx;
                _dragCurrentX = _dragStartX;
                _isRightDragging = true;
              });
            }
          },
          onPointerMove: (event) {
            if (_isRightDragging) {
              setState(() {
                _dragCurrentX = event.localPosition.dx;
              });
            }
          },
          onPointerUp: (event) {
            if (_isRightDragging) {
              _isRightDragging = false;
              if (_dragStartX != null && _dragCurrentX != null) {
                _applySelectionZoom(_dragStartX!, _dragCurrentX!, state, constraints);
              }
              setState(() {
                _dragStartX = null;
                _dragCurrentX = null;
              });
            }
          },
          onPointerSignal: (pointerSignal) {
            if (pointerSignal is PointerScrollEvent) {
              final keys = HardwareKeyboard.instance.logicalKeysPressed;
              bool isShiftPressed = keys.contains(LogicalKeyboardKey.shiftLeft) || keys.contains(LogicalKeyboardKey.shiftRight);
              if (isShiftPressed) return;

              bool isCtrlPressed = keys.contains(LogicalKeyboardKey.controlLeft) || 
                                   keys.contains(LogicalKeyboardKey.controlRight);
              if (isCtrlPressed) {
                // Smooth zoom based on scrollDelta.dy
                double zoomFactor = math.exp(pointerSignal.scrollDelta.dy / -500.0);
                
                double oldScale = state.xScale;
                double newScale = oldScale * zoomFactor;
                if (newScale < 0.01) newScale = 0.01;
                if (newScale > 500.0) newScale = 500.0;
                
                double oldMinScale = constraints.maxWidth / OscilloscopeState.maxPointsPerChannel;
                double oldActiveScale = oldScale < oldMinScale ? oldMinScale : oldScale;
                
                double latestX = 0;
                if (state.channels.isNotEmpty && state.channels[0].count > 0) {
                  latestX = (state.channels[0].count - 1).toDouble();
                } else if (state.digitalChannel.count > 0) {
                  latestX = (state.digitalChannel.count - 1).toDouble();
                }

                double oldTranslateX = constraints.maxWidth - latestX * oldActiveScale + state.xScrollOffset;
                
                double mouseX = pointerSignal.localPosition.dx;
                double indexUnderCursor = (mouseX - oldTranslateX) / oldActiveScale;

                double newActiveScale = newScale < oldMinScale ? oldMinScale : newScale;
                double newTranslateX = mouseX - indexUnderCursor * newActiveScale;
                double newScrollOffset = newTranslateX - constraints.maxWidth + latestX * newActiveScale;

                double maxScroll = 0;
                if (latestX * newActiveScale > constraints.maxWidth) {
                  maxScroll = latestX * newActiveScale - constraints.maxWidth;
                }
                
                if (newScrollOffset > maxScroll) newScrollOffset = maxScroll;
                if (newScrollOffset < 0) newScrollOffset = 0;

                state.setTimebase(newScale);
                state.setXScrollOffset(newScrollOffset);
              } else {
                // Pan left/right
                double newOffset = state.xScrollOffset + pointerSignal.scrollDelta.dy;
                
                double activeScale = state.xScale;
                double minScale = constraints.maxWidth / OscilloscopeState.maxPointsPerChannel;
                if (activeScale < minScale) activeScale = minScale;
                
                double latestX = 0;
                if (state.channels.isNotEmpty && state.channels[0].count > 0) {
                  latestX = (state.channels[0].count - 1).toDouble();
                } else if (state.digitalChannel.count > 0) {
                  latestX = (state.digitalChannel.count - 1).toDouble();
                }
                
                double maxScroll = 0;
                if (latestX * activeScale > constraints.maxWidth) {
                  maxScroll = latestX * activeScale - constraints.maxWidth;
                }
                
                if (newOffset > maxScroll) newOffset = maxScroll;
                if (newOffset < 0) newOffset = 0;
                
                state.setXScrollOffset(newOffset);
              }
            }
          },
          child: Stack(
            children: [
            // Background Canvas
            MouseRegion(
              hitTestBehavior: HitTestBehavior.opaque,
              cursor: SystemMouseCursors.resizeLeftRight,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,

                onDoubleTapDown: (details) {
                double dy = details.localPosition.dy;
                for (var bus in state.digitalChannel.buses) {
                  if (bus.decoder != null && bus.decoder!.isEnabled) {
                    int minPin = bus.startPin < bus.endPin ? bus.startPin : bus.endPin;
                    int maxPin = bus.startPin > bus.endPin ? bus.startPin : bus.endPin;
                    int numPins = maxPin - minPin + 1;
                    int maxLanes = bus.decoder!.maxLanes;
                    int totalRows = numPins + maxLanes + 1;
                    double spacing = 5.0;
                    double totalHeight = totalRows * digitalAmplitude + (totalRows - 1) * spacing;
                    
                    double topY = bus.yOffset - totalHeight / 2;
                    double bottomY = bus.yOffset + totalHeight / 2;
                    
                    if (dy >= topY - 15 && dy <= bottomY + 15) {
                      if (state.activeEventListBusName != bus.name) {
                        state.toggleEventList(bus.name);
                      }
                      break;
                    }
                  }
                }
              },
              onDoubleTap: () {},
              onPanUpdate: (details) {
                double newOffset = state.xScrollOffset + details.delta.dx * 3.0;
                
                double activeScale = state.xScale;
                double minScale = constraints.maxWidth / OscilloscopeState.maxPointsPerChannel;
                if (activeScale < minScale) activeScale = minScale;
                
                double latestX = 0;
                if (state.channels.isNotEmpty && state.channels[0].count > 0) {
                  latestX = (state.channels[0].count - 1).toDouble();
                } else if (state.digitalChannel.count > 0) {
                  latestX = (state.digitalChannel.count - 1).toDouble();
                }
                
                double maxScroll = 0;
                if (latestX * activeScale > constraints.maxWidth) {
                  maxScroll = latestX * activeScale - constraints.maxWidth;
                }
                
                if (newOffset > maxScroll) newOffset = maxScroll;
                if (newOffset < 0) newOffset = 0;
                
                state.setXScrollOffset(newOffset);
              },
              child: CustomPaint(
                painter: OscilloscopePainter(
                  state: state,
                  theme: Theme.of(context),
                ),
                size: Size.infinite,
              ),
            ),
            ),
            
            Selector<OscilloscopeState, String>(
              selector: (context, s) {
                return '${s.channels.map((c) => "${c.isVisible},${c.name},${c.yOffset},${c.yScale}").join("|")}'
                       '|${s.digitalChannel.enabledPins.join(",")}'
                       '|${s.digitalChannel.pinYOffsets.values.join(",")}'
                       '|${s.digitalChannel.pinYScales.values.join(",")}'
                       '|${s.digitalChannel.pinNames.entries.map((e) => "${e.key}:${e.value}").join(",")}'
                       '|${s.digitalChannel.buses.map((b) => "${b.name},${b.isExpanded},${b.yOffset},${b.pinNames.entries.map((e) => "${e.key}:${e.value}").join(";")}").join(",")}'
                       '|${s.showCursors}|${s.showXCursors}|${s.showYCursors}|${s.linkCursors}|${s.cursorX1}|${s.cursorX2}|${s.cursorY1}|${s.cursorY2}'
                       '|${s.selectedChannelIndex}|${s.sampleRate}'
                       '|${s.activeEventListBusName}'
                       '|${s.isDraggingMinimap}'
                       '|${s.xScrollOffset}|${s.xScale}'
                       '|${s.digitalChannel.buses.map((b) => b.decoder != null ? b.decoder!.packets.length : 0).join(",")}';
              },
              builder: (context, hash, child) {
                return Stack(
                  clipBehavior: Clip.none,
                  fit: StackFit.expand,
                  children: [


              if (state.showCursors)
                ...[
                  if (state.showXCursors) ...(() {
                    double activeScale = state.xScale;
                    double minScale = constraints.maxWidth / OscilloscopeState.maxPointsPerChannel;
                    if (activeScale < minScale) activeScale = minScale;

                    double translateX = constraints.maxWidth - state.latestX * activeScale + state.xScrollOffset;
                    
                    double px1Raw = state.cursorX1 * state.sampleRate * activeScale + translateX;
                    double px2Raw = state.cursorX2 * state.sampleRate * activeScale + translateX;
                    
                    double px1 = px1Raw.clamp(0.0, constraints.maxWidth);
                    double px2 = px2Raw.clamp(0.0, constraints.maxWidth);
                    
                    bool isX1ClampedLeft = px1Raw < 0;
                    bool isX1ClampedRight = px1Raw > constraints.maxWidth;
                    bool isX2ClampedLeft = px2Raw < 0;
                    bool isX2ClampedRight = px2Raw > constraints.maxWidth;

                    bool hasDigital = state.digitalChannel.enabledPins.isNotEmpty || state.digitalChannel.buses.isNotEmpty;
                    double topOffset = hasDigital ? 25.0 : 0.0;
                    bool hasToolbar = state.digitalChannel.enabledPins.isNotEmpty || state.digitalChannel.buses.isNotEmpty;
                    double gridCenterY = constraints.maxHeight / 2 - (hasToolbar ? 12.0 : 0.0);

                    void updateX1FromGlobal(Offset globalPos) {
                      RenderBox box = context.findRenderObject() as RenderBox;
                      double chartX = box.globalToLocal(globalPos).dx;
                      double newTime = (chartX - translateX) / activeScale / state.sampleRate;
                      state.setCursorX1(newTime);
                    }

                    void updateX2FromGlobal(Offset globalPos) {
                      RenderBox box = context.findRenderObject() as RenderBox;
                      double chartX = box.globalToLocal(globalPos).dx;
                      double newTime = (chartX - translateX) / activeScale / state.sampleRate;
                      state.setCursorX2(newTime);
                    }

                    return [
                      // X1
                      Positioned(
                        left: px1,
                        top: topOffset, bottom: 0, width: 1,
                        child: CustomPaint(painter: DashedLinePainter(color: Colors.yellowAccent)),
                      ),
                      Positioned(
                        key: const ValueKey('x1_hitbox'),
                        left: isX1ClampedLeft ? 0.0 : (isX1ClampedRight ? px1 - 30.0 : px1 - 10.0),
                        top: topOffset, bottom: 0, width: (isX1ClampedLeft || isX1ClampedRight) ? 30.0 : 20.0,
                        child: MouseRegion(
                          cursor: SystemMouseCursors.resizeLeftRight,
                          onEnter: (e) => _hoverPosX1.value = e.localPosition,
                          onHover: (e) => _hoverPosX1.value = e.localPosition,
                          onExit: (e) => _hoverPosX1.value = null,
                          child: Stack(
                            clipBehavior: Clip.none,
                            fit: StackFit.expand,
                            children: [
                              GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onPanDown: (d) => updateX1FromGlobal(d.globalPosition),
                                onPanUpdate: (d) => updateX1FromGlobal(d.globalPosition),
                                child: Container(color: Colors.transparent),
                              ),
                              ValueListenableBuilder<Offset?>(
                                valueListenable: _hoverPosX1,
                                builder: (context, pos, child) {
                                  if (pos == null) return const SizedBox.shrink();
                                  return Positioned(
                                    left: pos.dx + 12,
                                    top: pos.dy - 12,
                                    child: IgnorePointer(
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Icon(Icons.swap_horiz, color: Colors.yellowAccent, size: 24),
                                          if (state.snapToEdge)
                                            Padding(
                                              padding: const EdgeInsets.only(top: 2.0),
                                              child: Transform.rotate(
                                                angle: math.pi * 0.75,
                                                child: CustomPaint(
                                                  size: const Size(14, 14),
                                                  painter: MagnetIconPainter(Colors.orangeAccent),
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                      ),
                      Positioned(
                        left: isX1ClampedRight ? px1 - 20 : px1 + 2, top: 4 + topOffset,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('X1', style: TextStyle(color: Colors.yellowAccent, fontSize: 10, fontWeight: FontWeight.bold)),
                            if (state.linkCursors)
                              const Padding(
                                padding: EdgeInsets.only(top: 2.0),
                                child: Icon(Icons.link, color: Colors.greenAccent, size: 12),
                              ),
                          ],
                        ),
                      ),

                      // X2
                      Positioned(
                        left: px2,
                        top: topOffset, bottom: 0, width: 1,
                        child: CustomPaint(painter: DashedLinePainter(color: Colors.yellowAccent)),
                      ),
                      Positioned(
                        key: const ValueKey('x2_hitbox'),
                        left: isX2ClampedLeft ? 0.0 : (isX2ClampedRight ? px2 - 30.0 : px2 - 10.0),
                        top: topOffset, bottom: 0, width: (isX2ClampedLeft || isX2ClampedRight) ? 30.0 : 20.0,
                        child: MouseRegion(
                          cursor: SystemMouseCursors.resizeLeftRight,
                          onEnter: (e) => _hoverPosX2.value = e.localPosition,
                          onHover: (e) => _hoverPosX2.value = e.localPosition,
                          onExit: (e) => _hoverPosX2.value = null,
                          child: Stack(
                            clipBehavior: Clip.none,
                            fit: StackFit.expand,
                            children: [
                              GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onPanDown: (d) => updateX2FromGlobal(d.globalPosition),
                                onPanUpdate: (d) => updateX2FromGlobal(d.globalPosition),
                                child: Container(color: Colors.transparent),
                              ),
                              ValueListenableBuilder<Offset?>(
                                valueListenable: _hoverPosX2,
                                builder: (context, pos, child) {
                                  if (pos == null) return const SizedBox.shrink();
                                  return Positioned(
                                    left: pos.dx + 12,
                                    top: pos.dy - 12,
                                    child: IgnorePointer(
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Icon(Icons.swap_horiz, color: Colors.yellowAccent, size: 24),
                                          if (state.snapToEdge)
                                            Padding(
                                              padding: const EdgeInsets.only(top: 2.0),
                                              child: Transform.rotate(
                                                angle: math.pi * 0.75,
                                                child: CustomPaint(
                                                  size: const Size(14, 14),
                                                  painter: MagnetIconPainter(Colors.orangeAccent),
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                      ),
                      Positioned(
                        left: isX2ClampedRight ? px2 - 20 : px2 + 2, top: 4 + topOffset,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('X2', style: TextStyle(color: Colors.yellowAccent, fontSize: 10, fontWeight: FontWeight.bold)),
                            if (state.linkCursors)
                              const Padding(
                                padding: EdgeInsets.only(top: 2.0),
                                child: Icon(Icons.link, color: Colors.greenAccent, size: 12),
                              ),
                          ],
                        ),
                      ),
                      
                      // Arrows (placed last with IgnorePointer to avoid blocking gestures)
                      if (isX1ClampedLeft)
                        Positioned(
                          left: 0, top: gridCenterY - 12,
                          child: const IgnorePointer(
                            child: Icon(Icons.arrow_left, color: Colors.yellowAccent, size: 24),
                          )
                        ),
                      if (isX1ClampedRight)
                        Positioned(
                          left: constraints.maxWidth - 24, top: gridCenterY - 12,
                          child: const IgnorePointer(
                            child: Icon(Icons.arrow_right, color: Colors.yellowAccent, size: 24),
                          )
                        ),
                      if (isX2ClampedLeft)
                        Positioned(
                          left: 0, top: gridCenterY + 12,
                          child: const IgnorePointer(
                            child: Icon(Icons.arrow_left, color: Colors.yellowAccent, size: 24),
                          )
                        ),
                      if (isX2ClampedRight)
                        Positioned(
                          left: constraints.maxWidth - 24, top: gridCenterY + 12,
                          child: const IgnorePointer(
                            child: Icon(Icons.arrow_right, color: Colors.yellowAccent, size: 24),
                          )
                        ),
                    ];
                  })(),

                  if (state.showYCursors) ...[
                    // Y1
                    Positioned(
                      top: state.cursorY1,
                      left: 0, right: 0, height: 1,
                      child: CustomPaint(painter: DashedLinePainter(color: Colors.cyanAccent, isHorizontal: true)),
                    ),
                    Positioned(
                      top: state.cursorY1 - 10,
                      left: 0, right: 0, height: 20,
                      child: MouseRegion(
                        cursor: SystemMouseCursors.resizeUpDown,
                        onEnter: (e) => _hoverPosY1.value = e.localPosition,
                        onHover: (e) => _hoverPosY1.value = e.localPosition,
                        onExit: (e) => _hoverPosY1.value = null,
                        child: Stack(
                          clipBehavior: Clip.none,
                          fit: StackFit.expand,
                          children: [
                            GestureDetector(
                              onPanUpdate: (d) => state.setCursorY1((state.cursorY1 + d.delta.dy).clamp(0.0, constraints.maxHeight)),
                              child: Container(color: Colors.transparent),
                            ),
                            ValueListenableBuilder<Offset?>(
                              valueListenable: _hoverPosY1,
                              builder: (context, pos, child) {
                                if (pos == null) return const SizedBox.shrink();
                                return Positioned(
                                  left: pos.dx - 12,
                                  top: pos.dy + 12,
                                  child: const IgnorePointer(
                                    child: Icon(Icons.swap_vert, color: Colors.cyanAccent, size: 24),
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                    Positioned(
                      top: state.cursorY1 - 14, right: 4,
                      child: const Text('Y1', style: TextStyle(color: Colors.cyanAccent, fontSize: 10, fontWeight: FontWeight.bold)),
                    ),

                    // Y2
                    Positioned(
                      top: state.cursorY2,
                      left: 0, right: 0, height: 1,
                      child: CustomPaint(painter: DashedLinePainter(color: Colors.cyanAccent, isHorizontal: true)),
                    ),
                    Positioned(
                      top: state.cursorY2 - 10,
                      left: 0, right: 0, height: 20,
                      child: MouseRegion(
                        cursor: SystemMouseCursors.resizeUpDown,
                        onEnter: (e) => _hoverPosY2.value = e.localPosition,
                        onHover: (e) => _hoverPosY2.value = e.localPosition,
                        onExit: (e) => _hoverPosY2.value = null,
                        child: Stack(
                          clipBehavior: Clip.none,
                          fit: StackFit.expand,
                          children: [
                            GestureDetector(
                              onPanUpdate: (d) => state.setCursorY2((state.cursorY2 + d.delta.dy).clamp(0.0, constraints.maxHeight)),
                              child: Container(color: Colors.transparent),
                            ),
                            ValueListenableBuilder<Offset?>(
                              valueListenable: _hoverPosY2,
                              builder: (context, pos, child) {
                                if (pos == null) return const SizedBox.shrink();
                                return Positioned(
                                  left: pos.dx - 12,
                                  top: pos.dy + 12,
                                  child: const IgnorePointer(
                                    child: Icon(Icons.swap_vert, color: Colors.cyanAccent, size: 24),
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                    Positioned(
                      top: state.cursorY2 - 14, right: 4,
                      child: const Text('Y2', style: TextStyle(color: Colors.cyanAccent, fontSize: 10, fontWeight: FontWeight.bold)),
                    ),
                  ],

                // Info panel
                Positioned(
                  top: 10 + (state.digitalChannel.enabledPins.isNotEmpty ? 25.0 : 0.0), right: 20,
                  child: IgnorePointer( // Don't block interactions behind the info panel
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xB30C0C0C),
                        border: Border.all(color: Colors.yellowAccent),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Builder(
                        builder: (context) {
                          double deltaTime = (state.cursorX2 - state.cursorX1).abs();
                          
                          String formatTime(double t) {
                            if (t < 1e-6) return '${(t * 1e9).toStringAsFixed(2)} ns';
                            if (t < 1e-3) return '${(t * 1e6).toStringAsFixed(2)} µs';
                            if (t < 1.0) return '${(t * 1e3).toStringAsFixed(2)} ms';
                            return '${t.toStringAsFixed(2)} s';
                          }

                          String formatFreq(double f) {
                            if (f > 1e6) return '${(f / 1e6).toStringAsFixed(2)} MHz';
                            if (f > 1e3) return '${(f / 1e3).toStringAsFixed(2)} kHz';
                            return '${f.toStringAsFixed(2)} Hz';
                          }

                          String timeStr = formatTime(deltaTime);
                          String freqStr = deltaTime > 0 ? formatFreq(1.0 / deltaTime) : '---';

                          int ch = state.selectedChannelIndex;
                          
                          double getVoltage(double py) {
                            bool hasToolbar = state.digitalChannel.enabledPins.isNotEmpty || state.digitalChannel.buses.isNotEmpty;
                            double gridCenterY = constraints.maxHeight / 2 - (hasToolbar ? 12.0 : 0.0);
                            double adcValue = (gridCenterY + state.channels[ch].yOffset - py) / state.channels[ch].yScale;
                            return adcValue * (20.0 / 4095.0); // Corrected to +/-10V span (20V range / 4095)
                          }

                          double v1 = getVoltage(state.cursorY1);
                          double v2 = getVoltage(state.cursorY2);
                          double deltaV = (v2 - v1).abs();

                          double t1 = state.cursorX1;
                          double t2 = state.cursorX2;

                          String formatAbsTime(double t) {
                            double ns = t * 1e9;
                            String nsStr = ns.toStringAsFixed(0);
                            bool isNegative = false;
                            if (nsStr.startsWith('-')) {
                              isNegative = true;
                              nsStr = nsStr.substring(1);
                            }
                            String result = '';
                            int count = 0;
                            for (int i = nsStr.length - 1; i >= 0; i--) {
                              if (count > 0 && count % 3 == 0) {
                                result = ',$result';
                              }
                              result = '${nsStr[i]}$result';
                              count++;
                            }
                            return '${isNegative ? '-' : ''}$result nS';
                          }

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Cursor Info', style: TextStyle(color: Colors.yellowAccent, fontWeight: FontWeight.bold, fontSize: 12)),
                              const SizedBox(height: 6),
                              Text('X1: ${formatAbsTime(t1)}', style: const TextStyle(color: Colors.white, fontSize: 10)),
                              Text('X2: ${formatAbsTime(t2)}', style: const TextStyle(color: Colors.white, fontSize: 10)),
                              Text('ΔT: $timeStr', style: const TextStyle(color: Colors.yellowAccent, fontSize: 11, fontWeight: FontWeight.bold)),
                              Text('1/ΔT: $freqStr', style: const TextStyle(color: Colors.yellowAccent, fontSize: 11, fontWeight: FontWeight.bold)),
                              const SizedBox(height: 4),
                              Text('Y1: ${v1.toStringAsFixed(3)} V', style: const TextStyle(color: Colors.white, fontSize: 10)),
                              Text('Y2: ${v2.toStringAsFixed(3)} V', style: const TextStyle(color: Colors.white, fontSize: 10)),
                              Text('ΔAmp: ${deltaV.toStringAsFixed(3)} V (CH${ch+1})', style: const TextStyle(color: Colors.cyanAccent, fontSize: 11, fontWeight: FontWeight.bold)),
                            ],
                          );
                        }
                      ),
                    ),
                  ),
                ),
              ],
                    // Draggable 0V Indicators for each active channel
            for (int i = 0; i < state.channels.length; i++)
              if (state.channels[i].isVisible)
                DraggableChannelIndicator(
                  chIndex: i, 
                  state: state, 
                  maxHeight: constraints.maxHeight
                ),
                
            // Determine which pins are in buses
            ...(() {
              Set<int> pinsInBuses = {};
              for (var bus in state.digitalChannel.buses) {
                int minPin = bus.startPin < bus.endPin ? bus.startPin : bus.endPin;
                int maxPin = bus.startPin > bus.endPin ? bus.startPin : bus.endPin;
                for (int p = minPin; p <= maxPin; p++) {
                  pinsInBuses.add(p);
                }
              }

              List<Widget> edgeWidgets = [];
              List<Widget> inlineWidgets = [];
              for (int pin in state.digitalChannel.enabledPins) {
                if (!pinsInBuses.contains(pin)) {
                  edgeWidgets.add(DraggableDigitalChannelIndicator(
                    pin: pin,
                    state: state,
                    maxHeight: constraints.maxHeight,
                  ));
                }
              }

              for (var bus in state.digitalChannel.buses) {
                edgeWidgets.add(DraggableDigitalBusIndicator(
                  bus: bus,
                  state: state,
                  maxHeight: constraints.maxHeight,
                ));
                if (bus.isExpanded || bus.decoder != null) {
                  int minPin = bus.startPin < bus.endPin ? bus.startPin : bus.endPin;
                  int maxPin = bus.startPin > bus.endPin ? bus.startPin : bus.endPin;
                  int numPins = maxPin - minPin + 1;
                  int totalRows = bus.decoder != null ? numPins + bus.decoder!.maxLanes + 1 : numPins;
                  double spacing = 5.0;
                  double bitAmplitude = digitalAmplitude;
                  double totalHeight = totalRows * bitAmplitude + (totalRows - 1) * spacing;
                  
                  List<int> pinsOrdered = [];
                  if (bus.startPin < bus.endPin) {
                    for (int p = bus.endPin; p >= bus.startPin; p--) {
                      pinsOrdered.add(p);
                    }
                  } else {
                    for (int p = bus.startPin; p >= bus.endPin; p--) {
                      pinsOrdered.add(p);
                    }
                  }

                  for (int bitIndex = 0; bitIndex < numPins; bitIndex++) {
                    int pin = pinsOrdered[bitIndex];
                    double bitBaseY = bus.yOffset - totalHeight / 2 + bitAmplitude + bitIndex * (bitAmplitude + spacing);
                    
                    edgeWidgets.add(ExpandedBusPinIndicator(
                       bus: bus,
                       pin: pin,
                       state: state,
                       yCenter: bitBaseY - bitAmplitude / 2,
                    ));
                  }
                  
                  if (bus.decoder != null) {
                    double frameBaseY = bus.yOffset - totalHeight / 2 + bitAmplitude + (numPins) * (bitAmplitude + spacing);
                    edgeWidgets.add(ProtocolLaneIndicator(
                       bus: bus,
                       laneIndex: -1,
                       label: 'Frame No.',
                       yCenter: frameBaseY - bitAmplitude / 2,
                    ));
                    for (int lane = 0; lane < bus.decoder!.maxLanes; lane++) {
                      double laneBaseY = bus.yOffset - totalHeight / 2 + bitAmplitude + (numPins + 1 + lane) * (bitAmplitude + spacing);
                      edgeWidgets.add(ProtocolLaneIndicator(
                         bus: bus,
                         laneIndex: lane,
                         label: bus.decoder!.getLaneLabel(lane),
                         yCenter: laneBaseY - bitAmplitude / 2,
                      ));
                    }
                  }
                }
                
                // Add Hovers for Protocol Packets
                if (bus.decoder != null && bus.decoder!.isEnabled) {
                  var decoder = bus.decoder!;
                  int minPin = bus.startPin < bus.endPin ? bus.startPin : bus.endPin;
                  int maxPin = bus.startPin > bus.endPin ? bus.startPin : bus.endPin;
                  int numPins = maxPin - minPin + 1;
                  int maxLanes = decoder.maxLanes;
                  int totalRows = numPins + maxLanes + 1;
                  double spacing = 5.0;
                  double bitAmplitude = digitalAmplitude;
                  double totalHeight = totalRows * bitAmplitude + (totalRows - 1) * spacing;
                  
                  double activeScale = state.xScale;
                  double minScale = constraints.maxWidth / OscilloscopeState.maxPointsPerChannel;
                  if (activeScale < minScale) activeScale = minScale;

                  double latestX = state.latestX;
                  double translateX = constraints.maxWidth - latestX * activeScale + state.xScrollOffset;

                  int startI = (-translateX / activeScale).floor();
                  int endI = ((constraints.maxWidth - translateX) / activeScale).ceil();
                  
                  if (state.isDraggingMinimap) {
                    continue; // Skip building tooltips for this bus while dragging
                  }

                  int currentAbsoluteOffset = state.digitalChannel.totalPointsAdded - state.digitalChannel.count;
                  int offsetDiff = decoder.lastDecodeAbsoluteOffset - currentAbsoluteOffset;

                  int firstPacketIndex = 0;
                  if (decoder.packets.isNotEmpty) {
                    int low = 0;
                    int high = decoder.packets.length - 1;
                    while (low <= high) {
                      int mid = low + (high - low) ~/ 2;
                      if (decoder.packets[mid].endIndex + offsetDiff >= startI) {
                        firstPacketIndex = mid;
                        high = mid - 1;
                      } else {
                        low = mid + 1;
                      }
                    }
                    firstPacketIndex -= 20; // Safety margin for multi-lane out-of-order packets
                    if (firstPacketIndex < 0) firstPacketIndex = 0;
                  }

                  // Frame clickable areas
                  if (decoder.frames.isNotEmpty && !state.isDraggingMinimap) {
                    double frameBaseY = bus.yOffset - totalHeight / 2 + bitAmplitude + (numPins) * (bitAmplitude + spacing);
                    double midY = frameBaseY - digitalAmplitude / 2;
                    double topY = midY - 8.0;

                    for (int i = 0; i < decoder.frames.length; i++) {
                      var frame = decoder.frames[i];
                      int startLogical = frame.startIndex + offsetDiff;
                      int endLogical = frame.endIndex + offsetDiff;
                      
                      if (endLogical < startI) continue;
                      if (startLogical > endI) break; // Frames are ordered

                      double x1 = translateX + startLogical * activeScale;
                      double x2 = translateX + endLogical * activeScale;
                      
                      if (x1 < 0) x1 = 0;
                      if (x2 > constraints.maxWidth) x2 = constraints.maxWidth;
                      double width = x2 - x1;
                      if (width < 2) continue;

                      inlineWidgets.add(Positioned(
                        left: x1,
                        top: topY,
                        width: width,
                        height: 16.0,
                        child: GestureDetector(
                          onTap: () {
                            state.setHighlight(bus.name, frame.startIndex, frame.endIndex);
                          },
                          child: Container(color: Colors.transparent),
                        ),
                      ));
                    }
                  }

                  int packetsBeyondRightEdge = 0;
                  for (int i = firstPacketIndex; i < decoder.packets.length; i++) {
                    var packet = decoder.packets[i];
                    int lane = packet.laneIndex;
                    if (lane < 0 || lane >= maxLanes) lane = 0;

                    double laneBaseY = bus.yOffset - totalHeight / 2 + bitAmplitude + (numPins + 1 + lane) * (bitAmplitude + spacing);
                    double midY = laneBaseY - digitalAmplitude / 2;
                    double topY = midY - 8.0;

                    int startLogical = packet.startIndex + offsetDiff;
                    int endLogical = packet.endIndex + offsetDiff;
                    
                    if (endLogical < startI) continue;
                    if (startLogical > endI) {
                      packetsBeyondRightEdge++;
                      if (packetsBeyondRightEdge > 20) break; // Terminate early once we are safely past the screen
                      continue;
                    }
                    packetsBeyondRightEdge = 0; // Reset if we see a visible packet

                    double x1 = translateX + startLogical * activeScale;
                    double x2 = translateX + endLogical * activeScale;
                    
                    if (x1 < 0) x1 = 0;
                    if (x2 > constraints.maxWidth) x2 = constraints.maxWidth;
                    double width = x2 - x1;
                    if (width < 2) continue; // too small to hover

                    String tooltipMsg = 'Type: ${packet.type.name}\nData: ${packet.data}';
                    if (packet.rawValue != null) {
                      tooltipMsg += '\nRaw: ${packet.rawValue}';
                    }

                    inlineWidgets.add(Positioned(
                      left: x1,
                      top: topY,
                      width: width,
                      height: 16.0,
                      child: Tooltip(
                        message: tooltipMsg,
                        waitDuration: Duration.zero,
                        child: GestureDetector(
                          onTap: () {
                            state.setHighlight(bus.name, packet.startIndex, packet.endIndex);
                          },
                          child: Container(color: Colors.transparent),
                        ),
                      ),
                    ));
                  }
                }
              }

              return [...inlineWidgets, ...edgeWidgets];
            })(),
                  ],
                );
              },
            ),

            // Selection overlay overlay
            if (_isRightDragging && _dragStartX != null && _dragCurrentX != null)
              Positioned(
                left: math.min(_dragStartX!, _dragCurrentX!),
                top: 0,
                width: (_dragCurrentX! - _dragStartX!).abs(),
                bottom: 0,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.blue.withValues(alpha: 0.2),
                    border: Border(
                      left: BorderSide(color: Colors.blue, width: 1),
                      right: BorderSide(color: Colors.blue, width: 1),
                    )
                  )
                ),
              ),
          ],
        ),
      );
    });
  }
}

class DraggableDigitalBusIndicator extends StatefulWidget {
  final DigitalBus bus;
  final OscilloscopeState state;
  final double maxHeight;

  const DraggableDigitalBusIndicator({
    super.key,
    required this.bus,
    required this.state,
    required this.maxHeight,
  });

  @override
  State<DraggableDigitalBusIndicator> createState() => _DraggableDigitalBusIndicatorState();
}

class _DraggableDigitalBusIndicatorState extends State<DraggableDigitalBusIndicator> with SingleTickerProviderStateMixin {
  bool _isHovered = false;
  bool _isShiftPressed = false;
  late AnimationController _fadeController;

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..repeat(reverse: true);
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    _fadeController.dispose();
    super.dispose();
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (_isHovered) {
      final keys = HardwareKeyboard.instance.logicalKeysPressed;
      bool shiftPressed = keys.contains(LogicalKeyboardKey.shiftLeft) || keys.contains(LogicalKeyboardKey.shiftRight);
      if (_isShiftPressed != shiftPressed) {
        setState(() {
          _isShiftPressed = shiftPressed;
        });
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    Color color = widget.bus.color;
    double currentScale = widget.bus.yScale;
    double currentAmplitude = digitalAmplitude * currentScale;
    double baseY = widget.bus.yOffset;
    
    bool isProtocol = widget.bus.decoder != null && widget.bus.decoder!.isEnabled;
    double y = (widget.bus.isExpanded || isProtocol) ? baseY : baseY - currentAmplitude / 2;
    
    if (y < 8) y = 8;
    if (y > widget.maxHeight - 8) y = widget.maxHeight - 8;

    String label = widget.bus.name;
    double paintWidth = 24.0 + label.length * 7.0;

    return Positioned(
      left: 0,
      top: y - 16,
      child: MouseRegion(
        cursor: _isShiftPressed ? SystemMouseCursors.resizeUpDown : SystemMouseCursors.resizeUpDown,
        onEnter: (_) {
          final keys = HardwareKeyboard.instance.logicalKeysPressed;
          bool shiftPressed = keys.contains(LogicalKeyboardKey.shiftLeft) || keys.contains(LogicalKeyboardKey.shiftRight);
          setState(() {
            _isHovered = true;
            _isShiftPressed = shiftPressed;
          });
        },
        onExit: (_) => setState(() => _isHovered = false),
        child: Listener(
          onPointerSignal: (pointerSignal) {
            if (pointerSignal is PointerScrollEvent && _isShiftPressed && !widget.bus.isExpanded) {
              double scale = currentScale;
              if (pointerSignal.scrollDelta.dy > 0) {
                scale -= 0.5;
              } else {
                scale += 0.5;
              }
              if (scale < 1.0) scale = 1.0;
              if (scale > 5.0) scale = 5.0;
              
              if (scale != currentScale) {
                double newAmplitude = digitalAmplitude * scale;
                double newBaseY = y + newAmplitude / 2;
                widget.state.setDigitalBusScale(widget.bus.name, scale);
                widget.state.setDigitalBusOffset(widget.bus.name, newBaseY);
              }
            }
          },
          child: GestureDetector(
            onDoubleTap: () {
              if (widget.bus.decoder != null && widget.bus.decoder!.isEnabled) return;
              widget.state.toggleDigitalBusExpanded(widget.bus.name);
            },
            onPanUpdate: (details) {
              if (!_isShiftPressed) {
                // Read latest state to prevent stale closure data causing drag lag
                double currentBaseY = widget.state.digitalChannel.buses.firstWhere((b) => b.name == widget.bus.name).yOffset;
                double newBaseY = currentBaseY + details.delta.dy;
                widget.state.setDigitalBusOffset(widget.bus.name, newBaseY);
              }
            },
            child: Container(
              height: 32,
              width: paintWidth + 80,
              color: Colors.transparent, // Expand hit area
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.centerLeft,
                children: [
                  CustomPaint(
                    size: Size(paintWidth, 24),
                    painter: _IndicatorPainter(color: color, text: label),
                  ),
                  if (_isHovered)
                    Positioned(
                      left: paintWidth + 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xCC000000),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (!_isShiftPressed)
                              FadeTransition(
                                opacity: _fadeController,
                                child: Icon(Icons.unfold_more, size: 20, color: color),
                              ),
                            if (_isShiftPressed && !widget.bus.isExpanded)
                              FadeTransition(
                                opacity: _fadeController,
                                child: Icon(Icons.search, size: 20, color: color),
                              ),
                            if (_isShiftPressed && !widget.bus.isExpanded)
                              Padding(
                                padding: const EdgeInsets.only(left: 4.0),
                                child: Text(
                                  '${currentScale.toStringAsFixed(1)}x',
                                  style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.bold),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}


class DraggableChannelIndicator extends StatefulWidget {
  final int chIndex;
  final OscilloscopeState state;
  final double maxHeight;

  const DraggableChannelIndicator({
    super.key,
    required this.chIndex,
    required this.state,
    required this.maxHeight,
  });

  @override
  State<DraggableChannelIndicator> createState() => _DraggableChannelIndicatorState();
}

class _DraggableChannelIndicatorState extends State<DraggableChannelIndicator> with SingleTickerProviderStateMixin {
  bool _isHovered = false;
  bool _isShiftPressed = false;
  late AnimationController _pulseController;

  void _showRenameDialog(BuildContext context, String currentName, Function(String?) onRename) {
    TextEditingController controller = TextEditingController(text: currentName);
    showDialog(
      context: context,
      useRootNavigator: false,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF2A2A2A),
          title: const Text('重命名通道', style: TextStyle(color: Colors.white, fontSize: 14)),
          content: TextField(
            controller: controller,
            autofocus: true,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              hintText: '输入别名 (留空则清除)',
              hintStyle: TextStyle(color: Colors.grey),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消', style: TextStyle(color: Colors.grey)),
            ),
            TextButton(
              onPressed: () {
                onRename(controller.text.trim());
                Navigator.of(ctx).pop();
              },
              child: const Text('确定', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      }
    );
  }

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    _pulseController.dispose();
    super.dispose();
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (_isHovered) {
      final keys = HardwareKeyboard.instance.logicalKeysPressed;
      bool shiftPressed = keys.contains(LogicalKeyboardKey.shiftLeft) || keys.contains(LogicalKeyboardKey.shiftRight);
      if (_isShiftPressed != shiftPressed) {
        setState(() {
          _isShiftPressed = shiftPressed;
        });
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    var ch = widget.state.channels[widget.chIndex];
    bool hasToolbar = widget.state.digitalChannel.enabledPins.isNotEmpty || widget.state.digitalChannel.buses.isNotEmpty;
    double gridCenterY = widget.maxHeight / 2 - (hasToolbar ? 12.0 : 0.0);
    double y = gridCenterY + ch.yOffset;
    
    // Keep within bounds
    if (y < 8) y = 8;
    if (y > widget.maxHeight - 8) y = widget.maxHeight - 8;

    String label = ch.name != null && ch.name!.isNotEmpty ? '${widget.chIndex + 1}-${ch.name}' : '${widget.chIndex + 1}';
    double paintWidth = 16.0 + label.length * 7.0;

    return Positioned(
      left: 0,
      top: y - 16, // Center the 32px height hit-box on y
      child: MouseRegion(
        cursor: _isShiftPressed ? SystemMouseCursors.resizeUpDown : SystemMouseCursors.resizeUpDown,
        onEnter: (_) {
          final keys = HardwareKeyboard.instance.logicalKeysPressed;
          bool shiftPressed = keys.contains(LogicalKeyboardKey.shiftLeft) || keys.contains(LogicalKeyboardKey.shiftRight);
          setState(() {
            _isHovered = true;
            _isShiftPressed = shiftPressed;
          });
        },
        onExit: (_) => setState(() => _isHovered = false),
        child: Listener(
          onPointerSignal: (pointerSignal) {
            if (pointerSignal is PointerScrollEvent && _isShiftPressed) {
              // Zoom Y axis continuously
              double zoomFactor = pointerSignal.scrollDelta.dy > 0 ? 0.9 : 1.1; // down = zoom out, up = zoom in
              double newScale = ch.yScale * zoomFactor;
              if (newScale < 0.001) newScale = 0.001;
              if (newScale > 1000.0) newScale = 1000.0;
              widget.state.setChannelScale(widget.chIndex, newScale);
            }
          },
          child: GestureDetector(
            onDoubleTap: () {
              _showRenameDialog(context, ch.name ?? '', (newName) {
                widget.state.setChannelName(widget.chIndex, newName!.isEmpty ? null : newName);
              });
            },
            onPanUpdate: (details) {
              bool hasToolbar = widget.state.digitalChannel.enabledPins.isNotEmpty || widget.state.digitalChannel.buses.isNotEmpty;
              double gridCenterY = widget.maxHeight / 2 - (hasToolbar ? 12.0 : 0.0);
              double edgeTop = 8 - gridCenterY;
              double edgeBottom = widget.maxHeight - 8 - gridCenterY;
              
              // Read latest state to prevent stale closure data causing drag lag
              double currentOffset = widget.state.channels[widget.chIndex].yOffset;
              
              // Anti-hysteresis: snap to edge if dragging inwards from an off-screen position
              if (currentOffset < edgeTop && details.delta.dy > 0) {
                currentOffset = edgeTop;
              } else if (currentOffset > edgeBottom && details.delta.dy < 0) {
                currentOffset = edgeBottom;
              }

              double newOffset = currentOffset + details.delta.dy;
              if (newOffset < -10000) newOffset = -10000;
              if (newOffset > 10000) newOffset = 10000;
              if (newOffset != currentOffset) {
                widget.state.setChannelOffset(widget.chIndex, newOffset);
                widget.state.selectChannel(widget.chIndex);
              }
            },
            child: SizedBox(
              width: paintWidth + 80,
              height: 32,
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.centerLeft,
                children: [
                  Container(
                    color: Colors.transparent, // Expand hit area
                    child: CustomPaint(
                      size: Size(paintWidth, 16),
                      painter: _IndicatorPainter(color: ch.color, text: label),
                    ),
                  ),
                  if (_isHovered)
                    Positioned(
                      left: paintWidth + 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xCC000000),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            FadeTransition(
                              opacity: _pulseController,
                              child: Icon(_isShiftPressed ? Icons.search : Icons.unfold_more, size: 20, color: ch.color),
                            ),
                            if (_isShiftPressed)
                              Padding(
                                padding: const EdgeInsets.only(left: 4.0),
                                child: Text(
                                  '${ch.yScale.toStringAsFixed(1)}x',
                                  style: TextStyle(color: ch.color, fontSize: 12, fontWeight: FontWeight.bold),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ),
      ),
      ),
    );
  }
}

class DraggableDigitalChannelIndicator extends StatefulWidget {
  final int pin;
  final OscilloscopeState state;
  final double maxHeight;

  const DraggableDigitalChannelIndicator({
    super.key,
    required this.pin,
    required this.state,
    required this.maxHeight,
  });

  @override
  State<DraggableDigitalChannelIndicator> createState() => _DraggableDigitalChannelIndicatorState();
}

class _DraggableDigitalChannelIndicatorState extends State<DraggableDigitalChannelIndicator> with SingleTickerProviderStateMixin {
  bool _isHovered = false;
  bool _isShiftPressed = false;
  late AnimationController _fadeController;

  void _showRenameDialog(BuildContext context, String currentName, Function(String?) onRename) {
    TextEditingController controller = TextEditingController(text: currentName);
    showDialog(
      context: context,
      useRootNavigator: false,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF2A2A2A),
          title: const Text('重命名逻辑通道', style: TextStyle(color: Colors.white, fontSize: 14)),
          content: TextField(
            controller: controller,
            autofocus: true,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              hintText: '输入别名 (留空则清除)',
              hintStyle: TextStyle(color: Colors.grey),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消', style: TextStyle(color: Colors.grey)),
            ),
            TextButton(
              onPressed: () {
                onRename(controller.text.trim());
                Navigator.of(ctx).pop();
              },
              child: const Text('确定', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      }
    );
  }

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..repeat(reverse: true);
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    _fadeController.dispose();
    super.dispose();
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (_isHovered) {
      final keys = HardwareKeyboard.instance.logicalKeysPressed;
      bool shiftPressed = keys.contains(LogicalKeyboardKey.shiftLeft) || keys.contains(LogicalKeyboardKey.shiftRight);
      if (_isShiftPressed != shiftPressed) {
        setState(() {
          _isShiftPressed = shiftPressed;
        });
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    Color color = getDigitalPinColor(widget.pin);
    double currentScale = widget.state.digitalChannel.pinYScales[widget.pin] ?? 1.0;
    double currentAmplitude = digitalAmplitude * currentScale;
    double baseY = widget.state.digitalChannel.pinYOffsets[widget.pin] ?? (100.0 + widget.pin * 30.0);
    // Center to the middle of the digital waveform (which drops by currentAmplitude)
    double y = baseY - currentAmplitude / 2;
    
    // Keep within bounds
    if (y < 8) y = 8;
    if (y > widget.maxHeight - 8) y = widget.maxHeight - 8;

    String? customName = widget.state.digitalChannel.pinNames[widget.pin];
    String label = customName != null && customName.isNotEmpty ? 'D${widget.pin}-$customName' : 'D${widget.pin}';
    double paintWidth = 16.0 + label.length * 7.0;

    return Positioned(
      left: 0,
      top: y - 16, // Center the 32px height hit-box on y
      child: MouseRegion(
        cursor: _isShiftPressed ? SystemMouseCursors.resizeUpDown : SystemMouseCursors.resizeUpDown,
        onEnter: (_) {
          final keys = HardwareKeyboard.instance.logicalKeysPressed;
          bool shiftPressed = keys.contains(LogicalKeyboardKey.shiftLeft) || keys.contains(LogicalKeyboardKey.shiftRight);
          setState(() {
            _isHovered = true;
            _isShiftPressed = shiftPressed;
          });
        },
        onExit: (_) => setState(() => _isHovered = false),
        child: Listener(
          onPointerSignal: (pointerSignal) {
            if (pointerSignal is PointerScrollEvent && _isShiftPressed) {
              // Digital channel Y scale step by 0.5 (1.0 to 5.0)
              double scale = currentScale;
              if (pointerSignal.scrollDelta.dy > 0) {
                scale -= 0.5; // Zoom out
              } else {
                scale += 0.5; // Zoom in
              }
              if (scale < 1.0) scale = 1.0;
              if (scale > 5.0) scale = 5.0;
              
              if (scale != currentScale) {
                double newAmplitude = digitalAmplitude * scale;
                double currentArrowY = baseY - currentAmplitude / 2;
                double newBaseY = currentArrowY + newAmplitude / 2;
                widget.state.setDigitalPinScale(widget.pin, scale);
                widget.state.setDigitalPinOffset(widget.pin, newBaseY);
              }
            }
          },
          child: GestureDetector(
            onDoubleTap: () {
              _showRenameDialog(context, widget.state.digitalChannel.pinNames[widget.pin] ?? '', (newName) {
                widget.state.setDigitalPinName(widget.pin, newName!.isEmpty ? null : newName);
              });
            },
            onPanUpdate: (details) {
              double edgeTop = 8 + currentAmplitude / 2;
              double edgeBottom = widget.maxHeight - 8 + currentAmplitude / 2;
              
              // Read latest state to prevent stale closure data causing drag lag
              double currentBaseY = widget.state.digitalChannel.pinYOffsets[widget.pin] ?? (100.0 + widget.pin * 30.0);

              // Anti-hysteresis: snap to edge if dragging inwards from an off-screen position
              if (currentBaseY < edgeTop && details.delta.dy > 0) {
                currentBaseY = edgeTop;
              } else if (currentBaseY > edgeBottom && details.delta.dy < 0) {
                currentBaseY = edgeBottom;
              }

              double newBaseY = currentBaseY + details.delta.dy;
              if (newBaseY < -10000) newBaseY = -10000;
              if (newBaseY > 10000) newBaseY = 10000;
              widget.state.setDigitalPinOffset(widget.pin, newBaseY);
            },
            child: Container(
              width: paintWidth + 26 + (_isHovered && _isShiftPressed ? 40 : 0), // Wider to accommodate the animated arrow and text
              height: 32,
              color: Colors.transparent, // Expand hit area
              alignment: Alignment.centerLeft,
              child: Row(
                children: [
                  CustomPaint(
                    size: Size(paintWidth, 16),
                    painter: _IndicatorPainter(color: color, text: label),
                  ),
                  if (_isHovered)
                    FadeTransition(
                      opacity: _fadeController,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(left: 4.0),
                            child: Icon(_isShiftPressed ? Icons.search : Icons.unfold_more, size: 20, color: color),
                          ),
                          if (_isShiftPressed)
                            Padding(
                              padding: const EdgeInsets.only(left: 4.0),
                              child: Text(
                                '${currentScale.toStringAsFixed(1)}x',
                                style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.bold),
                              ),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ExpandedBusPinIndicator extends StatelessWidget {
  final DigitalBus bus;
  final int pin;
  final OscilloscopeState state;
  final double yCenter;

  const ExpandedBusPinIndicator({
    super.key,
    required this.bus,
    required this.pin,
    required this.state,
    required this.yCenter,
  });

  void _showRenameDialog(BuildContext context, String currentName) {
    TextEditingController controller = TextEditingController(text: currentName);
    showDialog(
      context: context,
      useRootNavigator: false,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF2A2A2A),
          title: Text('重命名总线引脚 (D$pin)', style: const TextStyle(color: Colors.white, fontSize: 14)),
          content: TextField(
            controller: controller,
            autofocus: true,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              hintText: '输入别名 (留空则清除)',
              hintStyle: TextStyle(color: Colors.grey),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消', style: TextStyle(color: Colors.grey)),
            ),
            TextButton(
              onPressed: () {
                state.setDigitalBusPinName(bus.name, pin, controller.text.trim());
                Navigator.of(ctx).pop();
              },
              child: const Text('确定', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      }
    );
  }

  @override
  Widget build(BuildContext context) {
    String? customName = bus.pinNames[pin];
    double arrowWidth = 24.0 + bus.name.length * 7.0;
    
    return Positioned(
      left: arrowWidth + 8,
      top: yCenter - 8,
      child: GestureDetector(
        onDoubleTap: () => _showRenameDialog(context, customName ?? ''),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
          decoration: BoxDecoration(
            color: const Color(0xCC000000),
            borderRadius: BorderRadius.circular(2),
          ),
          child: customName != null && customName.isNotEmpty
              ? RichText(
                  text: TextSpan(
                    children: [
                      TextSpan(
                        text: customName,
                        style: const TextStyle(color: Colors.yellowAccent, fontSize: 10, fontWeight: FontWeight.bold),
                      ),
                      TextSpan(
                        text: ' (D$pin)',
                        style: const TextStyle(color: Color(0xFF808080), fontSize: 10, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                )
              : Text(
                  'D$pin',
                  style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                ),
        ),
      ),
    );
  }
}

class _IndicatorPainter extends CustomPainter {
  final Color color;
  final String text;

  _IndicatorPainter({required this.color, required this.text});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
      
    double w = size.width;
    double h = size.height;
    
    final path = Path();
    path.moveTo(0, 0);
    path.lineTo(w - 8, 0);
    path.lineTo(w, h / 2);
    path.lineTo(w - 8, h);
    path.lineTo(0, h);
    path.close();
    
    canvas.drawPath(path, paint);
    
    // Add dark border for stereoscopic/3D effect
    final borderPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    canvas.drawPath(path, borderPaint);
    
    final textSpan = TextSpan(
      text: text,
      style: const TextStyle(color: Colors.black, fontSize: 11, fontWeight: FontWeight.bold),
    );
    final textPainter = TextPainter(
      text: textSpan,
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    
    // Center text in the rectangular part (width - 8)
    double textX = (w - 8) / 2 - textPainter.width / 2;
    double textY = h / 2 - textPainter.height / 2;
    textPainter.paint(canvas, Offset(textX, textY));
  }

  @override
  bool shouldRepaint(covariant _IndicatorPainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.text != text;
  }
}

class OscilloscopePainter extends CustomPainter {
  final OscilloscopeState state;
  final ThemeData theme;

  OscilloscopePainter({
    required this.state,
    required this.theme,
  }) : super(repaint: state);

  List<ChannelData> get channels => state.channels;
  DigitalChannelData get digitalChannel => state.digitalChannel;
  double get xScale => state.xScale;
  double get xScrollOffset => state.xScrollOffset;
  String? get highlightedBusName => state.highlightedBusName;
  int? get highlightedStartIndex => state.highlightedStartIndex;
  int? get highlightedEndIndex => state.highlightedEndIndex;
  bool get isPaused => state.isPaused;

  @override
  void paint(Canvas canvas, Size size) {
    // 1. Draw Grid
    _drawGrid(canvas, size);

    // 2. Compute Master X synchronization
    double activeScale = xScale;
    double minScale = size.width / OscilloscopeState.maxPointsPerChannel;
    if (activeScale < minScale) {
      activeScale = minScale;
    }

    double latestX = state.latestX;
    double maxScroll = latestX * activeScale;
    double clampedScrollOffset = xScrollOffset;
    if (clampedScrollOffset > maxScroll) clampedScrollOffset = maxScroll;

    double translateX;
    if (latestX * activeScale <= size.width) {
      translateX = -clampedScrollOffset;
    } else {
      translateX = size.width - latestX * activeScale + clampedScrollOffset;
    }

    // 3. Draw Analog Waveforms
    for (var ch in channels) {
      if (!ch.isVisible || ch.count == 0) continue;

      final paint = Paint()
        ..color = ch.color
        ..strokeWidth = 1.5
        ..isAntiAlias = false
        ..style = PaintingStyle.stroke;

      canvas.save();
      // Apply per-channel vertical offset and scale
      // Note: we invert Y axis mathematically so positive values go up.
      bool hasToolbar = state.digitalChannel.enabledPins.isNotEmpty || state.digitalChannel.buses.isNotEmpty;
      double gridCenterY = size.height / 2 - (hasToolbar ? 12.0 : 0.0);
      canvas.translate(0, gridCenterY + ch.yOffset);

      int startI = (-translateX / activeScale).floor();
      int endI = ((size.width - translateX) / activeScale).ceil();
      if (startI < 0) startI = 0;
      if (endI >= ch.count) endI = ch.count - 1;
      
      int visibleCount = endI - startI + 1;
      if (visibleCount <= 0) continue;

      int startIndex = ch.count == ch.maxPoints ? ch.head : 0;
      int pointsPerPixel = (1.0 / activeScale).floor();
      
      if (pointsPerPixel > 2) {
        // Min-Max Decimation: draw envelope instead of every point
        Path path = Path();
        
        for (int i = startI; i <= endI; i += pointsPerPixel) {
           int chunkEnd = i + pointsPerPixel - 1;
           if (chunkEnd > endI) chunkEnd = endI;
           
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
           
           double x = i.toDouble() * activeScale + translateX;
           if (i == startI) {
             path.moveTo(x, -(minY * ch.yScale));
           } else {
             path.lineTo(x, -(minY * ch.yScale));
           }
           path.lineTo(x, -(maxY * ch.yScale));
        }
        canvas.drawPath(path, paint);
      } else {
        // 1:1 or zoomed in: draw every point
        Path path = Path();
        for (int i = startI; i <= endI; i++) {
          int bufferIdx = (startIndex + i) % ch.maxPoints;
          double x = i.toDouble() * activeScale + translateX;
          double y = -(ch.points[bufferIdx] * ch.yScale);
          if (i == startI) {
            path.moveTo(x, y);
          } else {
            path.lineTo(x, y);
          }
        }
        canvas.drawPath(path, paint);
      }
      canvas.restore();
    }

    // 4. Draw Digital Logic Waveforms (MSO)
    if (digitalChannel.count > 0 && digitalChannel.enabledPins.isNotEmpty) {
      _drawDigitalChannels(canvas, size, translateX, activeScale);
    }

    // 5. Draw Search Matches
    if (state.searchMatches.isNotEmpty) {
      final matchPaint = Paint()
        ..color = state.searchMatchColor.withValues(alpha: 0.5)
        ..strokeWidth = 1.0;
        
      final currentMatchPaint = Paint()
        ..color = Colors.orangeAccent
        ..strokeWidth = 2.0;

      for (int i = 0; i < state.searchMatches.length; i++) {
        double t = state.searchMatches[i].time;
        double pointIndex = t * state.sampleRate;
        double x = pointIndex * activeScale + translateX;
        
        if (x >= 0 && x <= size.width) {
          bool isCurrent = i == state.currentSearchMatchIndex;
          canvas.drawLine(
            Offset(x, 0),
            Offset(x, size.height),
            isCurrent ? currentMatchPaint : matchPaint
          );
          
          if (isCurrent) {
            Path triangle = Path();
            triangle.moveTo(x - 5, 0);
            triangle.lineTo(x + 5, 0);
            triangle.lineTo(x, 10);
            triangle.close();
            canvas.drawPath(triangle, Paint()..color = Colors.orangeAccent..style = PaintingStyle.fill);
          }
        }
      }
    }


  }

  void _drawDigitalChannels(Canvas canvas, Size size, double translateX, double activeScale) {
    final paint = Paint()
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = false;

    int startIndex = digitalChannel.count == digitalChannel.maxPoints ? digitalChannel.head : 0;

    int startI = (-translateX / activeScale).floor();
    int endI = ((size.width - translateX) / activeScale).ceil();
    if (startI < 0) startI = 0;
    if (endI >= digitalChannel.count) endI = digitalChannel.count - 1;

    if (startI > endI) return;

    int pointsPerPixel = (1.0 / activeScale).floor();

    void drawDigitalTrace(Canvas canvas, Paint tracePaint, double baseY, double amplitude, int pin) {
      if (pointsPerPixel > 2) {
        Path path = Path();
        bool firstPoint = true;
        double currentY = baseY;

        for (int i = startI; i <= endI; i += pointsPerPixel) {
          int chunkEnd = i + pointsPerPixel - 1;
          if (chunkEnd > endI) chunkEnd = endI;

          bool has0 = false;
          bool has1 = false;
          
          for (int j = i; j <= chunkEnd; ) {
            int bufferIdx = (startIndex + j) % digitalChannel.maxPoints;
            int offsetInChunk = bufferIdx % OscilloscopeState.chunkSize;
            int remainingInLoop = chunkEnd - j + 1;
            
            if (offsetInChunk == 0 && remainingInLoop >= OscilloscopeState.chunkSize) {
              int cacheIdx = bufferIdx ~/ OscilloscopeState.chunkSize;
              int orVal = digitalChannel.chunkOrs[cacheIdx];
              int andVal = digitalChannel.chunkAnds[cacheIdx];
              
              if ((orVal & (1 << pin)) != 0) has1 = true;
              if ((andVal & (1 << pin)) == 0) has0 = true;
              
              j += OscilloscopeState.chunkSize;
            } else {
              int stateVal = digitalChannel.states[bufferIdx];
              if ((stateVal & (1 << pin)) != 0) {
                has1 = true;
              } else {
                has0 = true;
              }
              j++;
            }
            if (has0 && has1) break;
          }

          int state = (has0 && has1) ? 2 : (has1 ? 1 : 0);
          double x = i.toDouble() * activeScale + translateX;

          if (firstPoint) {
            if (state == 2) {
              path.moveTo(x, baseY);
              path.lineTo(x, baseY - amplitude);
              currentY = baseY - amplitude;
            } else {
              currentY = baseY - state * amplitude;
              path.moveTo(x, currentY);
            }
            firstPoint = false;
          } else {
            if (state == 2) {
              path.lineTo(x, currentY);
              double nextY = (currentY == baseY) ? (baseY - amplitude) : baseY;
              path.lineTo(x, nextY);
              currentY = nextY;
            } else {
              double targetY = baseY - state * amplitude;
              if (currentY != targetY) {
                path.lineTo(x, currentY);
                path.lineTo(x, targetY);
                currentY = targetY;
              }
            }
          }

          if (i + pointsPerPixel > endI) {
            double endX = endI.toDouble() * activeScale + translateX;
            path.lineTo(endX, currentY);
          }
        }
        canvas.drawPath(path, tracePaint);
      } else {
        Path path = Path();
        bool firstPoint = true;
        double currentY = baseY;
        
        for (int i = startI; i <= endI; i++) {
          int idx = (startIndex + i) % digitalChannel.maxPoints;
          double x = i.toDouble() * activeScale + translateX;
          int bitState = (digitalChannel.states[idx] & (1 << pin)) != 0 ? 1 : 0;
          double y = baseY - (bitState * amplitude);

          if (firstPoint) {
            currentY = y;
            path.moveTo(x, y);
            firstPoint = false;
          } else if (y != currentY) {
            path.lineTo(x, currentY);
            path.lineTo(x, y);
            currentY = y;
          }
          
          if (i == endI) {
            path.lineTo(x, currentY);
          }
        }
        canvas.drawPath(path, tracePaint);
      }
    }

    // 1. Determine which pins are in buses
    Set<int> pinsInBuses = {};
    for (var bus in digitalChannel.buses) {
      int minPin = bus.startPin < bus.endPin ? bus.startPin : bus.endPin;
      int maxPin = bus.startPin > bus.endPin ? bus.startPin : bus.endPin;
      for (int p = minPin; p <= maxPin; p++) {
        pinsInBuses.add(p);
      }
    }

    // 2. Draw Digital Buses
    final textPainter = TextPainter(textDirection: TextDirection.ltr);
    for (var bus in digitalChannel.buses) {
      paint.color = bus.color;
      double baseY = bus.yOffset;
      if (bus.decoder != null && bus.decoder!.isEnabled) {
        var decoder = bus.decoder!;
        int minPin = bus.startPin < bus.endPin ? bus.startPin : bus.endPin;
        int maxPin = bus.startPin > bus.endPin ? bus.startPin : bus.endPin;
        int numPins = maxPin - minPin + 1;
        int maxLanes = decoder.maxLanes;
        int totalRows = numPins + maxLanes + 1;
        double spacing = 5.0;
        double bitAmplitude = digitalAmplitude;
        double totalHeight = totalRows * bitAmplitude + (totalRows - 1) * spacing;
        
        double currentAmplitude = digitalAmplitude; // Scale is forced to 1.0 when expanded
        double dx = 4.0;
        
        int currentAbsoluteOffset = digitalChannel.totalPointsAdded - digitalChannel.count;
        int offsetDiff = decoder.lastDecodeAbsoluteOffset - currentAbsoluteOffset;

        // Draw highlight background if applicable
        if (highlightedBusName == bus.name && highlightedStartIndex != null && highlightedEndIndex != null) {
          double hlX1 = (highlightedStartIndex! + offsetDiff).toDouble() * activeScale + translateX;
          double hlX2 = (highlightedEndIndex! + offsetDiff).toDouble() * activeScale + translateX;
          
          if (hlX2 >= 0 && hlX1 <= size.width) {
             double hlTop = baseY - totalHeight / 2 - 10.0;
             double hlBottom = baseY + totalHeight / 2 + 10.0;
             canvas.drawRect(Rect.fromLTRB(hlX1, hlTop, hlX2, hlBottom), Paint()..color = Colors.cyan.withAlpha(80));
          }
        }

        List<int?> prevEndLogical = List.filled(maxLanes, null);
        List<double> prevX2 = List.filled(maxLanes, 0.0);
        List<double> lastDrawnPixel = List.filled(maxLanes, -100.0);

        int startI = (-translateX / activeScale).floor();

        int firstPacketIndex = 0;
        if (decoder.packets.isNotEmpty) {
          int low = 0;
          int high = decoder.packets.length - 1;
          while (low <= high) {
            int mid = low + (high - low) ~/ 2;
            if (decoder.packets[mid].endIndex + offsetDiff >= startI) {
              firstPacketIndex = mid;
              high = mid - 1;
            } else {
              low = mid + 1;
            }
          }
          firstPacketIndex -= 20;
          if (firstPacketIndex < 0) firstPacketIndex = 0;
        }

          if (!state.isDraggingMinimap) {
            // Draw Frame layer
            if (decoder.frames.isNotEmpty) {
              double frameBaseY = baseY - totalHeight / 2 + bitAmplitude + (numPins) * (bitAmplitude + spacing);
              double midY = frameBaseY - currentAmplitude / 2;
              double topY = midY - 8.0;
              double bottomY = midY + 8.0;
              
              for (int i = 0; i < decoder.frames.length; i++) {
                var frame = decoder.frames[i];
                int startLogical = frame.startIndex + offsetDiff;
                int endLogical = frame.endIndex + offsetDiff;
                
                double x1 = startLogical.toDouble() * activeScale + translateX;
                double x2 = endLogical.toDouble() * activeScale + translateX;
                
                if (x2 < 0) continue;
                if (x1 > size.width) break;
                
                paint.style = PaintingStyle.fill;
                paint.color = Colors.white.withAlpha(40);
                canvas.drawRect(Rect.fromLTRB(x1, topY, x2, bottomY), paint);
                
                paint.style = PaintingStyle.stroke;
                paint.color = Colors.white70;
                paint.strokeWidth = 1.0;
                canvas.drawRect(Rect.fromLTRB(x1, topY, x2, bottomY), paint);
                
                double visX1 = math.max(0.0, x1);
                double visX2 = math.min(size.width, x2);
                double visWidth = visX2 - visX1;
                
                if (visWidth > 20) {
                  textPainter.text = TextSpan(
                    text: 'Frame $i',
                    style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                  );
                  textPainter.layout();
                  if (textPainter.width + 8 <= visWidth) {
                    double textX = visX1 + (visWidth - textPainter.width) / 2;
                    textPainter.paint(canvas, Offset(textX, midY - textPainter.height / 2));
                  }
                }
              }
            }

            int packetsBeyondRightEdge = 0;
            for (int i = firstPacketIndex; i < decoder.packets.length; i++) {
              var packet = decoder.packets[i];
              int lane = packet.laneIndex;
              if (lane < 0 || lane >= maxLanes) lane = 0;
              
              double laneBaseY = baseY - totalHeight / 2 + bitAmplitude + (numPins + 1 + lane) * (bitAmplitude + spacing);
              double midY = laneBaseY - currentAmplitude / 2;
            double topY = midY - 8.0;
            double bottomY = midY + 8.0;

            int startLogical = packet.startIndex + offsetDiff;
            int endLogical = packet.endIndex + offsetDiff;
            
            double x1 = startLogical.toDouble() * activeScale + translateX;
            double x2 = endLogical.toDouble() * activeScale + translateX;
            
            if (x2 < 0) {
              prevEndLogical[lane] = endLogical;
              if (x2 > prevX2[lane]) prevX2[lane] = x2;
              continue;
            }
            
            if (x1 > size.width) {
              packetsBeyondRightEdge++;
              if (packetsBeyondRightEdge > 20) break;
              continue;
            }
            packetsBeyondRightEdge = 0;

            if (x1 > prevX2[lane]) {
              paint.style = PaintingStyle.stroke;
              paint.color = Colors.white54;
              paint.strokeWidth = 1.0;
              canvas.drawLine(Offset(prevX2[lane], midY), Offset(x1, midY), paint);
            }
            prevEndLogical[lane] = endLogical;
            if (x2 > prevX2[lane]) prevX2[lane] = x2;
            
            bool skipDrawing = false;
            if (x2 - x1 < 2.0) {
              if (x1 < lastDrawnPixel[lane] + 2.0) {
                skipDrawing = true;
              } else {
                lastDrawnPixel[lane] = x1;
              }
            }

            if (!skipDrawing) {
              bool isHighlightedMatch = false;
              if (state.searchMatches.isNotEmpty && state.currentSearchMatchIndex >= 0 && state.currentSearchMatchIndex < state.searchMatches.length) {
                  var match = state.searchMatches[state.currentSearchMatchIndex];
                  if (match.busName == bus.name && packet.startIndex >= match.startIndex && packet.endIndex <= match.endIndex) {
                      isHighlightedMatch = true;
                  }
              }

              paint.color = isHighlightedMatch ? packet.color.withValues(alpha: 1.0) : packet.color.withValues(alpha: 0.8);
              paint.style = PaintingStyle.fill;
              
              if (x2 - x1 < 2 * dx) {
                canvas.drawRect(Rect.fromLTRB(x1, topY, x2, bottomY), paint);
                paint.style = PaintingStyle.stroke;
                paint.color = isHighlightedMatch ? Colors.yellowAccent : Colors.white;
                paint.strokeWidth = isHighlightedMatch ? 3.0 : 1.0;
                canvas.drawRect(Rect.fromLTRB(x1, topY, x2, bottomY), paint);
              } else {
                Path path = Path();
                path.moveTo(x1, midY);
                path.lineTo(x1 + dx, topY);
                path.lineTo(x2 - dx, topY);
                path.lineTo(x2, midY);
                path.lineTo(x2 - dx, bottomY);
                path.lineTo(x1 + dx, bottomY);
                path.close();
                canvas.drawPath(path, paint);
                
                paint.style = PaintingStyle.stroke;
                paint.color = isHighlightedMatch ? Colors.yellowAccent : Colors.white;
                paint.strokeWidth = isHighlightedMatch ? 3.0 : 1.0;
                canvas.drawPath(path, paint);
              }
              
              double availableWidth = (x2 - dx) - (x1 + dx);
              if (availableWidth > 8) {
                String fullText = packet.data;
                if (packet.type == PacketType.address && packet.rawValue != null) {
                  var regfile = state.getRegfileFor(bus.name, packet.rawValue!);
                  if (regfile != null) {
                    fullText = '${packet.data} (${regfile.name})';
                  }
                }
                String shortText = fullText;
                
                if (packet.type == PacketType.start) {
                  fullText = 'START';
                  shortText = 'S';
                } else if (packet.type == PacketType.stop) {
                  fullText = 'STOP';
                  shortText = 'P';
                } else if (packet.type == PacketType.info) {
                  if (packet.data == 'A') {
                    fullText = 'ACK';
                    shortText = 'A';
                  } else if (packet.data == 'N') {
                    fullText = 'NACK';
                    shortText = 'N';
                  }
                } else if (packet.type == PacketType.readWrite) {
                  if (packet.data == 'READ') {
                    fullText = 'READ';
                    shortText = 'R';
                  } else if (packet.data == 'WRITE') {
                    fullText = 'WRITE';
                    shortText = 'W';
                  }
                } else if (packet.type == PacketType.data || packet.type == PacketType.address) {
                  shortText = fullText.replaceAll('0x', '').replaceAll(' ', '');
                }
                
                textPainter.text = TextSpan(
                  text: fullText,
                  style: const TextStyle(color: Colors.white, fontSize: 10),
                );
                textPainter.layout();
                
                if (textPainter.width + 4 <= availableWidth) {
                   double textX = (x1 + x2) / 2 - textPainter.width / 2;
                   double textY = midY - textPainter.height / 2;
                   textPainter.paint(canvas, Offset(textX, textY));
                } else {
                   textPainter.text = TextSpan(
                     text: shortText,
                     style: const TextStyle(color: Colors.white, fontSize: 10),
                   );
                   textPainter.layout();
                   if (textPainter.width + 4 <= availableWidth) {
                      double textX = (x1 + x2) / 2 - textPainter.width / 2;
                      double textY = midY - textPainter.height / 2;
                      textPainter.paint(canvas, Offset(textX, textY));
                   }
                }
                }
              }
            }
            
            for (int lane = 0; lane < maxLanes; lane++) {
              if (prevX2[lane] < size.width) {
                double laneBaseY = baseY - totalHeight / 2 + bitAmplitude + (numPins + 1 + lane) * (bitAmplitude + spacing);
                double midY = laneBaseY - currentAmplitude / 2;
                paint.style = PaintingStyle.stroke;
                paint.color = Colors.white54;
                paint.strokeWidth = 1.0;
                double startX = prevX2[lane];
                if (startX < 0) startX = 0; 
                canvas.drawLine(Offset(startX, midY), Offset(size.width, midY), paint);
              }
            }
          }
      } else if (!bus.isExpanded) {
        double currentScale = bus.yScale;
        double currentAmplitude = digitalAmplitude * currentScale;
        double midY = baseY - currentAmplitude / 2;
        double topY = baseY - currentAmplitude;
        double bottomY = baseY;
        double dx = 4.0;

        int getBusValue(int state) {
          int value = 0;
          int bitOffset = 0;
          if (bus.startPin <= bus.endPin) {
            for (int p = bus.startPin; p <= bus.endPin; p++) {
              if ((state & (1 << p)) != 0) value |= (1 << bitOffset);
              bitOffset++;
            }
          } else {
            for (int p = bus.startPin; p >= bus.endPin; p--) {
              if ((state & (1 << p)) != 0) value |= (1 << bitOffset);
              bitOffset++;
            }
          }
          return value;
        }

        // Helper to check if a sample index range overlaps any search match for this bus
        bool isSegmentHighlighted(int segStartSample, int segEndSample) {
          if (state.searchMatches.isEmpty) return false;
          for (var match in state.searchMatches) {
            if (match.busName != bus.name) continue;
            if (segStartSample <= match.endIndex && segEndSample >= match.startIndex) {
              return true;
            }
          }
          return false;
        }

        void drawBusSegment(double x1, double x2, int value, {bool isHighlighted = false}) {
          Path path = Path();
          if (x2 - x1 < 2 * dx) {
            double halfX = (x1 + x2) / 2;
            double dy = ((x2 - x1) / (2 * dx)) * (currentAmplitude / 2);
            path.moveTo(x1, midY);
            path.lineTo(halfX, midY - dy);
            path.lineTo(x2, midY);
            path.lineTo(halfX, midY + dy);
            path.close();
            if (isHighlighted) {
              canvas.drawPath(path, Paint()..color = bus.color.withValues(alpha: 0.2)..style = PaintingStyle.fill);
              canvas.drawPath(path, Paint()..color = Colors.yellowAccent..style = PaintingStyle.stroke..strokeWidth = 2.0);
            } else {
              canvas.drawPath(path, paint);
            }
          } else {
            path.moveTo(x1, midY);
            path.lineTo(x1 + dx, topY);
            path.lineTo(x2 - dx, topY);
            path.lineTo(x2, midY);
            path.lineTo(x2 - dx, bottomY);
            path.lineTo(x1 + dx, bottomY);
            path.close();
            
            if (isHighlighted) {
              canvas.drawPath(path, Paint()..color = bus.color.withValues(alpha: 0.2)..style = PaintingStyle.fill);
              canvas.drawPath(path, Paint()..color = Colors.yellowAccent..style = PaintingStyle.stroke..strokeWidth = 2.0);
            } else {
              canvas.drawPath(path, paint);
            }

            // Draw Text
            String text = '';
            int numPins = (bus.endPin - bus.startPin).abs() + 1;
            if (bus.format == DigitalBusFormat.hex) {
              int hexDigits = (numPins / 4).ceil();
              text = '0x${value.toRadixString(16).padLeft(hexDigits, '0').toUpperCase()}';
            } else if (bus.format == DigitalBusFormat.decimal) {
              text = '$value';
            } else if (bus.format == DigitalBusFormat.binary) {
              text = value.toRadixString(2).padLeft(numPins, '0');
            }

            double dynamicFontSize = (currentAmplitude * 0.6).clamp(6.0, 32.0);
            textPainter.text = TextSpan(
              text: text,
              style: TextStyle(
                color: isHighlighted ? Colors.white : bus.color,
                fontSize: dynamicFontSize,
                fontWeight: isHighlighted ? FontWeight.bold : FontWeight.normal,
              ),
            );
            textPainter.layout();

            double availableWidth = (x2 - dx) - (x1 + dx);
            if (textPainter.width + 4 <= availableWidth && currentAmplitude >= 12 && value != -2) {
              double textX = (x1 + x2) / 2 - textPainter.width / 2;
              double textY = midY - textPainter.height / 2;
              textPainter.paint(canvas, Offset(textX, textY));
            }
          }
        }

        if (pointsPerPixel > 2) {
          int prevState = -1;
          double startSegmentX = startI.toDouble() * activeScale + translateX;
          int segStartSample = startI;
          
          for (int i = startI; i <= endI; i += pointsPerPixel) {
            int chunkEnd = i + pointsPerPixel - 1;
            if (chunkEnd > endI) chunkEnd = endI;
            
            bool isConstant = true;
            int firstVal = getBusValue(digitalChannel.states[(startIndex + i) % digitalChannel.maxPoints]);
            int busMask = 0;
            int minBusPin = bus.startPin < bus.endPin ? bus.startPin : bus.endPin;
            int maxBusPin = bus.startPin > bus.endPin ? bus.startPin : bus.endPin;
            for (int p = minBusPin; p <= maxBusPin; p++) {
              busMask |= (1 << p);
            }

            for (int j = i + 1; j <= chunkEnd; ) {
              int bufferIdx = (startIndex + j) % digitalChannel.maxPoints;
              int offsetInChunk = bufferIdx % OscilloscopeState.chunkSize;
              int remainingInLoop = chunkEnd - j + 1;

              if (offsetInChunk == 0 && remainingInLoop >= OscilloscopeState.chunkSize) {
                int cacheIdx = bufferIdx ~/ OscilloscopeState.chunkSize;
                if ((digitalChannel.chunkOrs[cacheIdx] & busMask) != (digitalChannel.chunkAnds[cacheIdx] & busMask)) {
                  isConstant = false;
                  break;
                }
                j += OscilloscopeState.chunkSize;
              } else {
                if (getBusValue(digitalChannel.states[bufferIdx]) != firstVal) {
                  isConstant = false;
                  break;
                }
                j++;
              }
            }
            int displayValue = isConstant ? firstVal : -2;
            double x = i.toDouble() * activeScale + translateX;
            
            if (prevState == -1) {
              prevState = displayValue;
              startSegmentX = x;
              segStartSample = i;
            } else if (displayValue != prevState) {
              bool highlighted = isSegmentHighlighted(segStartSample, i - 1);
              drawBusSegment(startSegmentX, x, prevState, isHighlighted: highlighted);
              prevState = displayValue;
              startSegmentX = x;
              segStartSample = i;
            }
            
            if (i + pointsPerPixel > endI) {
              bool highlighted = isSegmentHighlighted(segStartSample, endI);
              drawBusSegment(startSegmentX, endI.toDouble() * activeScale + translateX, prevState, isHighlighted: highlighted);
            }
          }
        } else {
          int prevState = -1;
          double startSegmentX = startI.toDouble() * activeScale + translateX;
          int segStartSample = startI;
          for (int i = startI; i <= endI; i++) {
            int idx = (startIndex + i) % digitalChannel.maxPoints;
            double x = i.toDouble() * activeScale + translateX;
            int value = getBusValue(digitalChannel.states[idx]);

            if (prevState == -1) {
              prevState = value;
              startSegmentX = x;
              segStartSample = i;
            } else if (value != prevState) {
              bool highlighted = isSegmentHighlighted(segStartSample, i - 1);
              drawBusSegment(startSegmentX, x, prevState, isHighlighted: highlighted);
              prevState = value;
              startSegmentX = x;
              segStartSample = i;
            }

            if (i == endI) {
              bool highlighted = isSegmentHighlighted(segStartSample, endI);
              drawBusSegment(startSegmentX, x, prevState, isHighlighted: highlighted);
            }
          }
        }
      }

      if (bus.isExpanded || bus.decoder != null) {
        int minPin = bus.startPin < bus.endPin ? bus.startPin : bus.endPin;
        int maxPin = bus.startPin > bus.endPin ? bus.startPin : bus.endPin;
        int numPins = maxPin - minPin + 1;
        int totalRows = bus.decoder != null ? numPins + bus.decoder!.maxLanes + 1 : numPins;
        double spacing = 5.0;
        double bitAmplitude = digitalAmplitude; // Scale is forced to 1.0 when expanded
        double totalHeight = totalRows * bitAmplitude + (totalRows - 1) * spacing;
        
        // Draw pins from MSB (top) to LSB (bottom)
        // If startPin < endPin, then endPin is MSB.
        List<int> pinsOrdered = [];
        if (bus.startPin < bus.endPin) {
          for (int p = bus.endPin; p >= bus.startPin; p--) {
            pinsOrdered.add(p);
          }
        } else {
          for (int p = bus.startPin; p >= bus.endPin; p--) {
            pinsOrdered.add(p);
          }
        }

        for (int bitIndex = 0; bitIndex < numPins; bitIndex++) {
          int pin = pinsOrdered[bitIndex];
          double bitBaseY = baseY - totalHeight / 2 + bitAmplitude + bitIndex * (bitAmplitude + spacing);
          
          var tracePaint = Paint()
            ..color = bus.color
            ..strokeWidth = 1.5
            ..style = PaintingStyle.stroke
            ..strokeJoin = StrokeJoin.round
            ..strokeCap = StrokeCap.round
            ..isAntiAlias = false;
          drawDigitalTrace(canvas, tracePaint, bitBaseY, bitAmplitude, pin);
          
          var decoder = bus.decoder;
          if (decoder != null && decoder.isEnabled && !state.isDraggingMinimap && decoder.pinClocks.containsKey(pin)) {
            int currentAbsoluteOffset = digitalChannel.totalPointsAdded - digitalChannel.count;
            int offsetDiff = decoder.lastDecodeAbsoluteOffset - currentAbsoluteOffset;
            
            // Binary search for the first clock in range
            var clocks = decoder.pinClocks[pin]!;
            int firstClockIndex = 0;
            if (clocks.isNotEmpty) {
              int low = 0;
              int high = clocks.length - 1;
              while (low <= high) {
                int mid = low + (high - low) ~/ 2;
                if (clocks[mid].index + offsetDiff >= startI) {
                  firstClockIndex = mid;
                  high = mid - 1;
                } else {
                  low = mid + 1;
                }
              }
              firstClockIndex -= 20;
              if (firstClockIndex < 0) firstClockIndex = 0;
            }

            int clocksBeyondRightEdge = 0;
            double lastDrawnClockX = -100.0;
            for (int i = firstClockIndex; i < clocks.length; i++) {
              var clock = clocks[i];
              int logicalIndex = clock.index + offsetDiff;
              
              double x = logicalIndex.toDouble() * activeScale + translateX;
              if (x < 0) continue;
              if (x > size.width) {
                clocksBeyondRightEdge++;
                if (clocksBeyondRightEdge > 20) break;
                continue;
              }
              clocksBeyondRightEdge = 0;
              
              if (x - lastDrawnClockX < 15.0) continue; // Skip drawing clocks that overlap
              lastDrawnClockX = x;
              
              textPainter.text = TextSpan(
                text: clock.label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              );
              textPainter.layout();
              
              // Draw to the right of the rising edge, vertically centered
              double y = bitBaseY - bitAmplitude / 2 - textPainter.height / 2;
              textPainter.paint(canvas, Offset(x + 3.0, y));
            }
          }
        }
      }
    }

    // 3. Draw individual enabled pins
    for (int pin in digitalChannel.enabledPins) {
       if (pinsInBuses.contains(pin)) continue;

       paint.color = getDigitalPinColor(pin); 
       double baseY = digitalChannel.pinYOffsets[pin] ?? 100.0 + pin * 30.0;
       double currentScale = digitalChannel.pinYScales[pin] ?? 1.0;
       double currentAmplitude = digitalAmplitude * currentScale;
       
       var tracePaint = Paint()
          ..color = getDigitalPinColor(pin)
          ..strokeWidth = 1.5
          ..style = PaintingStyle.stroke
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round
          ..isAntiAlias = false;
       drawDigitalTrace(canvas, tracePaint, baseY, currentAmplitude, pin);
    }


  }

  void _drawGrid(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.1)
      ..strokeWidth = 1.0;

    final centerPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.25)
      ..strokeWidth = 1.0;

    int hGrids = 8;
    int vGrids = 14; // Rigol style 14 divisions horizontally
    
    bool hasToolbar = state.digitalChannel.enabledPins.isNotEmpty || state.digitalChannel.buses.isNotEmpty;
    double refHeight = size.height + (hasToolbar ? 24.0 : 0.0);
    double hSpacing = refHeight / hGrids;
    double vSpacing = size.width / vGrids;

    // Draw horizontal grids
    for (int i = 1; i < hGrids; i++) {
      double y = size.height - i * hSpacing;
      if (i == hGrids / 2) {
        // Draw center horizontal line slightly brighter with tick marks
        canvas.drawLine(Offset(0, y), Offset(size.width, y), centerPaint);
        // Draw tick marks
        for(int j=0; j < vGrids * 5; j++) {
           double tickX = j * (vSpacing / 5);
           canvas.drawLine(Offset(tickX, y - 2), Offset(tickX, y + 2), centerPaint);
        }
      } else {
        canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
      }
    }

    // Draw vertical grids
    for (int i = 1; i < vGrids; i++) {
      double x = i * vSpacing;
      if (i == vGrids / 2) {
        // Draw center vertical line slightly brighter
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), centerPaint);
        // Draw tick marks
        for(int j=0; j < hGrids * 5; j++) {
           double tickY = size.height - j * (hSpacing / 5);
           canvas.drawLine(Offset(x - 2, tickY), Offset(x + 2, tickY), centerPaint);
        }
      } else {
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant OscilloscopePainter oldDelegate) {
    return false; // Repaint is entirely driven by the `repaint` Listenable (state)
  }
}

class ProtocolLaneIndicator extends StatelessWidget {
  final DigitalBus bus;
  final int laneIndex;
  final String label;
  final double yCenter;

  const ProtocolLaneIndicator({
    super.key,
    required this.bus,
    required this.laneIndex,
    required this.label,
    required this.yCenter,
  });

  @override
  Widget build(BuildContext context) {
    double arrowWidth = 24.0 + bus.name.length * 7.0;
    
    Color textColor = Colors.orangeAccent;
    if (label.startsWith('R:') || label.startsWith('TXD')) {
      textColor = Colors.yellow;
    } else if (label.startsWith('W:') || label.startsWith('RXD')) {
      textColor = Colors.cyanAccent;
    }
    
    return Positioned(
      left: arrowWidth + 8,
      top: yCenter - 8,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        decoration: BoxDecoration(
          color: const Color(0xCC000000),
          borderRadius: BorderRadius.circular(2),
          border: Border.all(color: Colors.white24, width: 1),
        ),
        child: Text(
          label,
          style: TextStyle(color: textColor, fontSize: 10, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}

class DashedLinePainter extends CustomPainter {
  final Color color;
  final bool isHorizontal;
  final double strokeWidth;
  final double dashWidth;
  final double dashSpace;

  DashedLinePainter({
    required this.color,
    this.isHorizontal = false,
    this.strokeWidth = 1.0,
    this.dashWidth = 5.0,
    this.dashSpace = 5.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    var paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke;

    double start = 0.0;
    if (isHorizontal) {
      while (start < size.width) {
        canvas.drawLine(Offset(start, 0), Offset(start + dashWidth, 0), paint);
        start += dashWidth + dashSpace;
      }
    } else {
      while (start < size.height) {
        canvas.drawLine(Offset(0, start), Offset(0, start + dashWidth), paint);
        start += dashWidth + dashSpace;
      }
    }
  }

  @override
  bool shouldRepaint(covariant DashedLinePainter oldDelegate) {
    return oldDelegate.color != color ||
           oldDelegate.isHorizontal != isHorizontal ||
           oldDelegate.strokeWidth != strokeWidth ||
           oldDelegate.dashWidth != dashWidth ||
           oldDelegate.dashSpace != dashSpace;
  }
}


