import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../../modules/font_extractor/utils/unicode_blocks.dart';
import '../../../modules/font_extractor/widgets/font_picker_dialog.dart';
import '../../../providers/font_extractor_state.dart';

/// Section body: font file list (primary + fallbacks) with add/clear.
class FontSection extends StatelessWidget {
  const FontSection({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<FontExtractorState>();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            ElevatedButton.icon(
              onPressed: () => _pickFont(context, state),
              icon: const Icon(Icons.font_download, size: 14),
              label: const Text('添加字体', style: TextStyle(fontSize: 12)),
              style: _btnStyle(),
            ),
            if (state.fontPaths.isNotEmpty)
              ElevatedButton.icon(
                onPressed: state.clearFonts,
                icon: const Icon(Icons.clear_all, size: 14),
                label: const Text('清空', style: TextStyle(fontSize: 12)),
                style: _btnStyle(),
              ),
          ],
        ),
        const SizedBox(height: 6),
        if (state.fontPaths.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              '从这里开始：添加一个 TrueType/OpenType 字体文件，'
              '等宽字体效果最佳；可再添加后备字体补全缺字。',
              style: TextStyle(color: Colors.grey, fontSize: 11),
            ),
          )
        else
          ...List.generate(state.fontPaths.length, (i) {
            final path = state.fontPaths[i];
            final displayName = state.fontDisplayName(path);
            final fileName = p.basename(path);
            return Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                children: [
                  Icon(
                    i == 0
                        ? Icons.font_download
                        : Icons.subdirectory_arrow_right,
                    size: 12,
                    color: i == 0 ? Colors.cyanAccent : Colors.grey,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Tooltip(
                      message: path,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            displayName + (i == 0 ? ' (主)' : ' (后备)'),
                            style: const TextStyle(fontSize: 12),
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (displayName != fileName)
                            Text(
                              fileName,
                              style: const TextStyle(
                                  fontSize: 9,
                                  color: Colors.grey,
                                  fontFamily: 'Consolas'),
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
                    ),
                  ),
                  InkWell(
                    onTap: () => state.removeFontAt(i),
                    child: const Icon(Icons.close,
                        size: 12, color: Colors.grey),
                  ),
                ],
              ),
            );
          }),
      ],
    );
  }

  Future<void> _pickFont(BuildContext context, FontExtractorState state) async {
    try {
      final path = await showFontPickerDialog(
        context,
        targetRanges: _currentCharsetRanges(state),
      );
      if (path != null) {
        await state.addFontFile(path);
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              backgroundColor: Colors.redAccent, content: Text('打开字体失败: $e')),
        );
      }
    }
  }

  /// The charset currently selected in the extractor (checked Unicode
  /// blocks plus custom ranges), used by the font picker to show per-font
  /// coverage. Unparseable custom-range input is ignored.
  List<({int start, int end})>? _currentCharsetRanges(
      FontExtractorState state) {
    final ranges = <({int start, int end})>[
      for (final i in state.selectedBlockIndexes)
        (start: kUnicodeBlocks[i].start, end: kUnicodeBlocks[i].end),
    ];
    try {
      if (state.customRangeInput.trim().isNotEmpty) {
        ranges.addAll(parseRangeInput(state.customRangeInput));
      }
    } catch (_) {}
    return ranges.isEmpty ? null : ranges;
  }

  ButtonStyle _btnStyle() {
    return ElevatedButton.styleFrom(
      backgroundColor: const Color(0xFF333333),
      foregroundColor: Colors.cyanAccent,
      minimumSize: const Size(0, 28),
      padding: const EdgeInsets.symmetric(horizontal: 10),
    );
  }
}
