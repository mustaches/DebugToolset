import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../providers/ui_designer_state.dart';
import '../models/widget_registry.dart';

/// Left toolbox: click a widget type to add it to the current page.
class WidgetPalette extends StatelessWidget {
  const WidgetPalette({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.read<UiDesignerState>();
    return Container(
      color: const Color(0xFF252525),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 6, horizontal: 8),
            child: Text('控件',
                style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey,
                    fontWeight: FontWeight.bold)),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Wrap(
                spacing: 3,
                runSpacing: 3,
                children: [
                  for (final def in WidgetRegistry.all)
                    Tooltip(
                      message: def.label,
                      child: SizedBox(
                        width: 30,
                        height: 30,
                        child: InkWell(
                          onTap: () => state.addWidget(def.type),
                          borderRadius: BorderRadius.circular(4),
                          child: Container(
                            decoration: BoxDecoration(
                              color: const Color(0xFF1E1E1E),
                              borderRadius: BorderRadius.circular(4),
                              border:
                                  Border.all(color: Colors.grey.shade800),
                            ),
                            child: Icon(def.icon,
                                size: 16, color: Colors.cyanAccent),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
