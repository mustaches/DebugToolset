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
import 'widgets/resizable_split_view.dart';

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
                  flex: 1, // Let ChartWidget take remaining space
                  child: Container(
                    margin: const EdgeInsets.all(4.0),
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
                        const LogicAnalyzerToolbar(),
                        if (state.digitalChannel.enabledPins.isNotEmpty)
                          const SizedBox(
                            height: 24,
                            child: TimeRuleWidget(),
                          ),
                        Divider(height: 1, thickness: 1, color: Colors.grey.shade800),
                        Expanded(
                          flex: 10,
                          child: state.highlightedBusName != null && state.showRegisterInfoPanel
                            ? const ResizableSplitView(
                                topWidget: ClipRect(child: ChartWidget()),
                                bottomWidget: RegisterInfoPanel(),
                                initialRatio: 0.75,
                              )
                            : const ClipRect(child: ChartWidget()),
                        ),
                      ],
                    ),
                  ),
                ),
                if (state.activeEventListBusName != null)
                  Container(
                    width: 400,
                    margin: const EdgeInsets.only(top: 4.0, bottom: 4.0, right: 4.0),
                    child: PacketListPanel(busName: state.activeEventListBusName!),
                  ),
                const RightControlPanel(),
              ],
            ),
          ),
          
          // Bottom Channel Bar
          const BottomChannelBar(),
        ],
      ),
    );
  }
}
