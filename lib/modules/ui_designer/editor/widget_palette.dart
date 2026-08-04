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
      child: ListView(
        padding: const EdgeInsets.all(6),
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            child: Text('控件',
                style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey,
                    fontWeight: FontWeight.bold)),
          ),
          for (final def in WidgetRegistry.all)
            InkWell(
              onTap: () => state.addWidget(def.type),
              child: Container(
                margin: const EdgeInsets.only(bottom: 4),
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E1E),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.grey.shade800),
                ),
                child: Row(
                  children: [
                    Icon(def.icon, size: 16, color: Colors.cyanAccent),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(def.label,
                          style: const TextStyle(fontSize: 12)),
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
