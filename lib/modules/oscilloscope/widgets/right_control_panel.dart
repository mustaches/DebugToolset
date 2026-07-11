import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:provider/provider.dart';
import '../../../providers/oscilloscope_state.dart';
import '../../../utils/hover_builder.dart';
import 'trigger_menu_dialog.dart';

class RightControlPanel extends StatefulWidget {
  const RightControlPanel({super.key});

  @override
  State<RightControlPanel> createState() => _RightControlPanelState();
}

class _RightControlPanelState extends State<RightControlPanel> {
  bool _isMathActive = false;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<OscilloscopeState>();

    return Container(
      width: 320,
      decoration: BoxDecoration(
        color: const Color(0xFF161616),
        border: Border(left: BorderSide(color: Colors.grey.shade800, width: 2)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
      child: Column(
        children: [
          // Row 1: Top Actions
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildTopBtn('Measure', null),
              _buildTopBtn('SINGLE', () => state.singleShot()),
              _buildTopBtn('AUTO', () => state.autoSetup(), color: Colors.yellowAccent.shade700),
              _buildTopBtn(state.isPaused ? 'STOP' : 'RUN', () => state.togglePause(), color: state.isPaused ? Colors.redAccent : Colors.greenAccent),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildTopBtn('Cursor', () => state.toggleCursors(), color: state.showCursors ? Colors.blueAccent : null),
              _buildTopBtn('Analyse', null),
              _buildTopBtn('DEFAULT', () => state.resetToDefault()),
              _buildTopBtn('CLEAR', () => state.clearData()),
            ],
          ),
          const SizedBox(height: 16),
          const Divider(color: Colors.grey, height: 1),
          const SizedBox(height: 16),

          // Lower Section: Vertical, Horizontal, Trigger Columns
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 1. Vertical
                Expanded(
                  child: Column(
                    children: [
                      const Text('Vertical', style: TextStyle(color: Colors.white54, fontSize: 10, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 2),
                      DualHardwareKnob(
                        key: ValueKey('v_pos_${state.resetCount}'),
                        label: 'POSITION',
                        onRotate: (delta, isFine) {
                          int ch = state.selectedChannelIndex;
                          double step = isFine ? 1.0 : 10.0;
                          double val = state.channels[ch].yOffset - delta * step;
                          if (val < -10000.0) val = -10000.0;
                          if (val > 10000.0) val = 10000.0;
                          state.setChannelOffset(ch, val);
                        },
                      ),
                      const SizedBox(height: 4),
                      _buildUniformButton(
                        label: '1',
                        isActive: state.channels[0].isVisible,
                        isSelected: state.selectedChannelIndex == 0,
                        activeColor: state.channels[0].color,
                        onTap: () {
                          if (!state.channels[0].isVisible) {
                            state.toggleChannelVisibility(0);
                          }
                          state.selectChannel(0);
                        },
                        onLongPress: () {
                          if (state.channels[0].isVisible) {
                            state.toggleChannelVisibility(0);
                          }
                        },
                      ),
                      const SizedBox(height: 6),
                      _buildUniformButton(
                        label: '2',
                        isActive: state.channels[1].isVisible,
                        isSelected: state.selectedChannelIndex == 1,
                        activeColor: state.channels[1].color,
                        onTap: () {
                          if (!state.channels[1].isVisible) {
                            state.toggleChannelVisibility(1);
                          }
                          state.selectChannel(1);
                        },
                        onLongPress: () {
                          if (state.channels[1].isVisible) {
                            state.toggleChannelVisibility(1);
                          }
                        },
                      ),
                      const SizedBox(height: 6),
                      _buildUniformButton(
                        label: '3',
                        isActive: state.channels[2].isVisible,
                        isSelected: state.selectedChannelIndex == 2,
                        activeColor: state.channels[2].color,
                        onTap: () {
                          if (!state.channels[2].isVisible) {
                            state.toggleChannelVisibility(2);
                          }
                          state.selectChannel(2);
                        },
                        onLongPress: () {
                          if (state.channels[2].isVisible) {
                            state.toggleChannelVisibility(2);
                          }
                        },
                      ),
                      const SizedBox(height: 6),
                      _buildUniformButton(
                        label: '4',
                        isActive: state.channels[3].isVisible,
                        isSelected: state.selectedChannelIndex == 3,
                        activeColor: state.channels[3].color,
                        onTap: () {
                          if (!state.channels[3].isVisible) {
                            state.toggleChannelVisibility(3);
                          }
                          state.selectChannel(3);
                        },
                        onLongPress: () {
                          if (state.channels[3].isVisible) {
                            state.toggleChannelVisibility(3);
                          }
                        },
                      ),
                      const SizedBox(height: 6),
                      _buildUniformButton(
                        label: 'MATH',
                        isActive: _isMathActive,
                        isSelected: false,
                        activeColor: Colors.orangeAccent,
                        onTap: () {
                          setState(() {
                            _isMathActive = !_isMathActive;
                          });
                        },
                      ),
                      const SizedBox(height: 6),
                      _buildUniformButton(
                        label: 'LA',
                        isActive: state.digitalChannel.enabledPins.isNotEmpty,
                        isSelected: false,
                        activeColor: Colors.purpleAccent,
                        onTap: () {
                          if (state.digitalChannel.enabledPins.isNotEmpty) {
                            state.setDigitalPinGroupVisibility(0, 31, false);
                          } else {
                            state.setDigitalPinGroupVisibility(0, 7, true);
                          }
                        },
                      ),
                      const SizedBox(height: 4),
                      DualHardwareKnob(
                        key: ValueKey('v_scl_${state.resetCount}'),
                        label: 'SCALE',
                        onRotate: (delta, isFine) {
                          int ch = state.selectedChannelIndex;
                          double step = isFine ? 0.0025 : 0.05;
                          double val = state.channels[ch].yScale - delta * step;
                          if (val < 0.1) val = 0.1;
                          if (val > 10.0) val = 10.0;
                          state.setChannelScale(ch, val);
                        },
                      ),
                    ],
                  ),
                ),

                Container(width: 1, color: Colors.grey.shade800),

                // 2. Horizontal
                Expanded(
                  child: Column(
                    children: [
                      const Text('Horizontal', style: TextStyle(color: Colors.white54, fontSize: 10, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 2),
                      DualHardwareKnob(
                        key: ValueKey('h_pos_${state.resetCount}'),
                        label: 'POSITION',
                        onRotate: (delta, isFine) {
                          // TODO: implement xOffset logic
                        },
                      ),
                      const SizedBox(height: 4),
                      _buildBtn('Menu'),
                      _buildBtn('Navigate'),
                      const SizedBox(height: 2),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.arrow_left, color: Colors.grey.shade400, size: 24),
                          Icon(Icons.pause_circle_filled, color: Colors.grey.shade400, size: 24),
                          Icon(Icons.arrow_right, color: Colors.grey.shade400, size: 24),
                        ],
                      ),
                      const Spacer(),
                      DualHardwareKnob(
                        key: ValueKey('h_scl_${state.resetCount}'),
                        label: 'SCALE',
                        onRotate: (delta, isFine) {
                          double step = isFine ? 0.0025 : 0.05;
                          double val = state.xScale - delta * step;
                          if (val < 0.1) val = 0.1;
                          if (val > 10.0) val = 10.0;
                          state.setTimebase(val);
                        },
                      ),
                      const SizedBox(height: 4), // Align bottom
                    ],
                  ),
                ),

                Container(width: 1, color: Colors.grey.shade800),

                // 3. Trigger
                Expanded(
                  child: Column(
                    children: [
                      const Text('Trigger', style: TextStyle(color: Colors.white54, fontSize: 10, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 2),
                      _buildBtn('Menu', isOutline: true, onTap: () {
                        showDialog(
                          context: context.read<OscilloscopeState>().oscNavigatorKey.currentContext ?? context,
                          useRootNavigator: false,
                          builder: (context) => const TriggerMenuDialog(),
                        );
                      }),
                      const Spacer(),
                      HardwareKnob(
                        key: ValueKey('t_lvl_${state.resetCount}'),
                        label: 'LEVEL',
                        onRotate: (delta) {
                          int val = state.triggerLevel - (delta * 10).round();
                          if (val < 0) val = 0;
                          if (val > 4095) val = 4095;
                          state.setTriggerLevel(val);
                        },
                      ),
                      const Spacer(),
                      _buildBtn('Slope', onTap: () {
                        TriggerEdge nextEdge;
                        if (state.triggerEdge == TriggerEdge.rising) {
                          nextEdge = TriggerEdge.falling;
                        } else if (state.triggerEdge == TriggerEdge.falling) {
                          nextEdge = TriggerEdge.both;
                        } else {
                          nextEdge = TriggerEdge.rising;
                        }
                        state.setTriggerEdge(nextEdge);
                      }),
                      _buildBtn('Force', onTap: () {
                        state.forceTrigger();
                      }),
                      const SizedBox(height: 4), // Align bottom
                    ],
                  ),
                ),
              ],
            ),
          )
        ],
      ),
    );
  }

  Widget _buildTopBtn(String label, VoidCallback? onTap, {Color? color}) {
    return HoverBuilder(
      builder: (context, isHovered) {
        return GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: isHovered ? const Color(0xFF3A3A3A) : const Color(0xFF2A2A2A),
              border: Border.all(
                color: isHovered ? (color ?? Colors.white) : (color ?? Colors.grey.shade700), 
                width: 1.5
              ),
              borderRadius: BorderRadius.circular(4),
              boxShadow: isHovered && color != null ? [BoxShadow(color: color.withValues(alpha: 0.3), blurRadius: 4)] : null,
            ),
            child: Text(
              label,
              style: TextStyle(color: color ?? Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
            ),
          ),
        );
      }
    );
  }

  Widget _buildBtn(String label, {bool isOutline = false, VoidCallback? onTap}) {
    return HoverBuilder(
      builder: (context, isHovered) {
        return GestureDetector(
          onTap: onTap,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 2),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: isOutline 
                ? (isHovered ? Colors.white10 : Colors.transparent)
                : (isHovered ? const Color(0xFF444444) : const Color(0xFF333333)),
              border: Border.all(color: isHovered ? Colors.white : (isOutline ? Colors.grey : Colors.transparent)),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              label,
              style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
            ),
          ),
        );
      }
    );
  }

  Widget _buildUniformButton({
    required String label,
    required bool isActive,
    required bool isSelected,
    required Color activeColor,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
  }) {
    return HoverBuilder(
      builder: (context, isHovered) {
        Color bgColor;
        Color textColor;
        Border border;
        List<BoxShadow>? shadow;

        if (isSelected) {
          bgColor = activeColor;
          textColor = Colors.black;
          border = Border.all(color: activeColor, width: 1.5);
          shadow = [BoxShadow(color: activeColor.withValues(alpha: 0.3), blurRadius: 6)];
        } else if (isActive) {
          bgColor = const Color(0xFF222222);
          textColor = activeColor;
          border = Border.all(color: activeColor, width: 1.5);
          if (isHovered) {
            bgColor = const Color(0xFF333333);
            shadow = [BoxShadow(color: activeColor.withValues(alpha: 0.2), blurRadius: 4)];
          }
        } else {
          bgColor = isHovered ? const Color(0xFF444444) : const Color(0xFF333333);
          textColor = isHovered ? Colors.white : Colors.grey;
          border = Border.all(color: isHovered ? Colors.white : Colors.transparent, width: 1.5);
        }

        return GestureDetector(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Container(
            width: 76,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(4),
              border: border,
              boxShadow: shadow,
            ),
            child: Text(
              label,
              style: TextStyle(
                color: textColor,
                fontSize: 12,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        );
      }
    );
  }
}

class HardwareKnob extends StatefulWidget {
  final String label;
  final Function(double delta) onRotate;

  const HardwareKnob({super.key, required this.label, required this.onRotate});

  @override
  State<HardwareKnob> createState() => _HardwareKnobState();
}

class _HardwareKnobState extends State<HardwareKnob> {
  bool _isHovered = false;
  double _rotation = 0.0;

  void _handleScroll(PointerScrollEvent event) {
    // scroll down (positive dy) -> decrease value -> delta negative
    // scroll up (negative dy) -> increase value -> delta positive
    double delta = event.scrollDelta.dy > 0 ? -1.0 : 1.0;
    _updateRotation(delta);
  }

  void _handlePanUpdate(DragUpdateDetails details) {
    // drag down -> positive dy -> decrease value
    double delta = details.delta.dy > 0 ? -0.5 : 0.5;
    _updateRotation(delta);
  }

  void _updateRotation(double delta) {
    setState(() {
      _rotation += delta * 0.2; // Visual rotation
    });
    widget.onRotate(delta);
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: Listener(
        onPointerSignal: (pointerSignal) {
          if (pointerSignal is PointerScrollEvent) {
            _handleScroll(pointerSignal);
          }
        },
        child: GestureDetector(
          onPanUpdate: _handlePanUpdate,
          child: Column(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF222222),
                  border: Border.all(
                    color: _isHovered ? Colors.greenAccent : Colors.grey.shade700,
                    width: _isHovered ? 2.0 : 1.0,
                  ),
                  boxShadow: _isHovered ? [BoxShadow(color: Colors.greenAccent.withValues(alpha: 0.3), blurRadius: 8)] : null,
                ),
                child: Center(
                  child: Transform.rotate(
                    angle: _rotation,
                    child: Container(
                      width: 38,
                      height: 38,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: Color(0xFF111111),
                      ),
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: Container(
                          margin: const EdgeInsets.only(top: 4),
                          width: 4,
                          height: 8,
                          decoration: BoxDecoration(
                            color: _isHovered ? Colors.greenAccent : Colors.white,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(widget.label, style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
            ],
          ),
        ),
      ),
    );
  }
}

class DualHardwareKnob extends StatefulWidget {
  final String label;
  final Function(double delta, bool isFine) onRotate;

  const DualHardwareKnob({super.key, required this.label, required this.onRotate});

  @override
  State<DualHardwareKnob> createState() => _DualHardwareKnobState();
}

class _DualHardwareKnobState extends State<DualHardwareKnob> {
  bool _isOuterHovered = false;
  bool _isInnerHovered = false;
  double _outerRotation = 0.0;
  double _innerRotation = 0.0;

  void _handleScroll(PointerScrollEvent event, bool isFine) {
    double delta = event.scrollDelta.dy > 0 ? -1.0 : 1.0;
    _updateRotation(delta, isFine);
  }

  void _handlePanUpdate(DragUpdateDetails details, bool isFine) {
    double delta = details.delta.dy > 0 ? -0.5 : 0.5;
    _updateRotation(delta, isFine);
  }

  void _updateRotation(double delta, bool isFine) {
    setState(() {
      if (isFine) {
        _outerRotation += delta * 0.2;
      } else {
        _innerRotation += delta * 0.2;
      }
    });
    widget.onRotate(delta, isFine);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SizedBox(
          width: 52,
          height: 52,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Outer Ring
              MouseRegion(
                onEnter: (_) => setState(() => _isOuterHovered = true),
                onExit: (_) => setState(() => _isOuterHovered = false),
                child: Listener(
                  onPointerSignal: (event) {
                    if (event is PointerScrollEvent && !_isInnerHovered) {
                      _handleScroll(event, true);
                    }
                  },
                  child: GestureDetector(
                    onPanUpdate: (d) => _handlePanUpdate(d, true),
                    child: Transform.rotate(
                      angle: _outerRotation,
                      child: Container(
                        width: 52,
                        height: 52,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(0xFF2A2A2A),
                          border: Border.all(
                            color: _isOuterHovered && !_isInnerHovered ? Colors.greenAccent : Colors.grey.shade600,
                            width: _isOuterHovered && !_isInnerHovered ? 2.0 : 1.0,
                          ),
                          boxShadow: _isOuterHovered && !_isInnerHovered ? [BoxShadow(color: Colors.greenAccent.withValues(alpha: 0.3), blurRadius: 6)] : null,
                        ),
                        child: Align(
                          alignment: Alignment.topCenter,
                          child: Container(
                            margin: const EdgeInsets.only(top: 4),
                            width: 3,
                            height: 6,
                            decoration: BoxDecoration(
                              color: _isOuterHovered && !_isInnerHovered ? Colors.greenAccent : Colors.grey.shade400,
                              borderRadius: BorderRadius.circular(1.5),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              // Inner Ring
              MouseRegion(
                onEnter: (_) => setState(() => _isInnerHovered = true),
                onExit: (_) => setState(() => _isInnerHovered = false),
                child: Listener(
                  onPointerSignal: (event) {
                    if (event is PointerScrollEvent) {
                      _handleScroll(event, false);
                    }
                  },
                  child: GestureDetector(
                    onPanUpdate: (d) => _handlePanUpdate(d, false),
                    child: Transform.rotate(
                      angle: _innerRotation,
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(0xFF111111),
                          border: Border.all(
                            color: _isInnerHovered ? Colors.greenAccent : Colors.grey.shade800,
                            width: _isInnerHovered ? 2.0 : 1.0,
                          ),
                        ),
                        child: Align(
                          alignment: Alignment.topCenter,
                          child: Container(
                            margin: const EdgeInsets.only(top: 3),
                            width: 4,
                            height: 8,
                            decoration: BoxDecoration(
                              color: _isInnerHovered ? Colors.greenAccent : Colors.white,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Text(widget.label, style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
      ],
    );
  }
}
