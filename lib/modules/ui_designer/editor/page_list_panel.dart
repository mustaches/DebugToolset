import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../providers/ui_designer_state.dart';

/// Page list with add / rename / delete, shown under the widget palette.
class PageListPanel extends StatelessWidget {
  const PageListPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<UiDesignerState>();
    return Container(
      color: const Color(0xFF252525),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 4, 4),
            child: Row(
              children: [
                const Text('页面',
                    style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey,
                        fontWeight: FontWeight.bold)),
                const Spacer(),
                InkWell(
                  onTap: state.addPage,
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(Icons.add, size: 16, color: Colors.cyanAccent),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              children: [
                for (final page in state.project.pages)
                  Container(
                    margin: const EdgeInsets.only(bottom: 4),
                    decoration: BoxDecoration(
                      color: page.id == state.currentPageId
                          ? const Color(0xFF0A4A5A)
                          : const Color(0xFF1E1E1E),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: InkWell(
                      onTap: () => state.selectPage(page.id),
                      onDoubleTap: () => _renamePage(context, state, page.id,
                          page.name),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 8),
                        child: Row(
                          children: [
                            const Icon(Icons.web_asset,
                                size: 14, color: Colors.grey),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(page.name,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: page.id == state.currentPageId
                                          ? Colors.cyanAccent
                                          : Colors.white)),
                            ),
                            if (state.project.pages.length > 1)
                              InkWell(
                                onTap: () => state.removePage(page.id),
                                child: const Padding(
                                  padding: EdgeInsets.all(2),
                                  child: Icon(Icons.close,
                                      size: 14, color: Colors.grey),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _renamePage(BuildContext context, UiDesignerState state, String id,
      String current) {
    final controller = TextEditingController(text: current);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2E2E2E),
        title: const Text('重命名页面', style: TextStyle(fontSize: 14)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(fontSize: 13),
          onSubmitted: (_) {
            state.renamePage(id, controller.text);
            Navigator.of(ctx).pop();
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              state.renamePage(id, controller.text);
              Navigator.of(ctx).pop();
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }
}
