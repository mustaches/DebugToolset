import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/oscilloscope_state.dart';
import 'widgets/chart_widget.dart';
import 'widgets/minimap_widget.dart';
import 'widgets/top_info_bar.dart';
import 'widgets/bottom_channel_bar.dart';
import 'widgets/right_control_panel.dart';
import 'widgets/packet_list_panel.dart';
import 'widgets/register_info_panel.dart';
import 'widgets/time_rule_widget.dart';
import 'widgets/la_toolbar.dart';

class OscilloscopeView extends StatelessWidget {
  const OscilloscopeView({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<OscilloscopeState>();
    return Container(
      color: Colors.black, // Professional Dark Theme
      child: Column(
        children: [
          // Top Info Bar
          const TopInfoBar(),
          
          // Main Chart Area & Right Control Panel
          Expanded(
            child: Row(
              children: [
                Expanded(
                  flex: 1,
                  child: Center(
                    child: FittedBox(
                      fit: BoxFit.contain,
                      child: SizedBox(
                        width: 1920,
                        height: 1080,
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.black,
                            border: Border.all(
                              color: Colors.grey.shade800,
                              width: 2.0,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const Expanded(
                                flex: 1,
                                child: MinimapWidget(),
                              ),
                              if (state.digitalChannel.enabledPins.isNotEmpty || state.digitalChannel.buses.isNotEmpty)
                                const LogicAnalyzerToolbar(),
                              Divider(height: 1, thickness: 1, color: Colors.grey.shade800),
                              Expanded(
                                flex: 10,
                                child: Stack(
                                  children: [
                                    const Positioned.fill(
                                      child: ClipRect(
                                        child: ChartWidget(),
                                      ),
                                    ),
                                    if (state.digitalChannel.enabledPins.isNotEmpty)
                                      Positioned(
                                        top: 0,
                                        left: 0,
                                        right: 0,
                                        height: 25,
                                        child: Container(
                                          decoration: BoxDecoration(
                                            color: const Color(0xFF161616),
                                            border: Border(bottom: BorderSide(color: Colors.grey.shade800, width: 1.0)),
                                          ),
                                          child: const TimeRuleWidget(),
                                        ),
                                      ),
                                    if (state.highlightedBusName != null && state.showRegisterInfoPanel)
                                      Positioned(
                                        bottom: 0,
                                        left: 0,
                                        right: state.activeEventListBusName != null ? 418.0 : 0.0,
                                        height: 240,
                                        child: const RegisterInfoPanel(),
                                      ),
                                    if (state.activeEventListBusName != null)
                                      Positioned(
                                        top: 0,
                                        bottom: 0,
                                        right: -2.0,
                                        width: 420,
                                        child: PacketListPanel(busName: state.activeEventListBusName!),
                                      ),
                                  ],
                                ),
                              ),
                              const BottomChannelBar(),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const RightControlPanel(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
