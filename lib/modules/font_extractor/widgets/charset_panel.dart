import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../modules/font_extractor/utils/unicode_blocks.dart';
import '../../../providers/font_extractor_state.dart';

/// Left-panel section for picking the character set:
/// predefined Unicode blocks, custom ranges and text-file import.
class CharsetPanel extends StatefulWidget {
  const CharsetPanel({super.key});

  @override
  State<CharsetPanel> createState() => _CharsetPanelState();
}

class _CharsetPanelState extends State<CharsetPanel> {
  bool _showAll = false;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<FontExtractorState>();
    final rangeError = state.customRangeError;

    final blocks = [
      for (int i = 0; i < kUnicodeBlocks.length; i++)
        if (_showAll || state.selectedBlockIndexes.contains(i))
          (index: i, block: kUnicodeBlocks[i])
    ]..sort((a, b) => a.block.start.compareTo(b.block.start));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Text(
              '字符集',
              style: TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(width: 8),
            InkWell(
              onTap: () =>
                  state.toggleSelectAllBlocks(!state.isAllBlocksSelected),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: Checkbox(
                      value: state.isAllBlocksSelected,
                      onChanged: (v) => state.toggleSelectAllBlocks(v ?? false),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  const SizedBox(width: 3),
                  const Text('全选',
                      style: TextStyle(fontSize: 11, color: Colors.cyanAccent)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            InkWell(
              onTap: () =>
                  state.toggleSelectNoneBlocks(!state.isNoneSelected),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: Checkbox(
                      value: state.isNoneSelected,
                      onChanged: (v) =>
                          state.toggleSelectNoneBlocks(v ?? false),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  const SizedBox(width: 3),
                  const Text('全不选',
                      style: TextStyle(fontSize: 11, color: Colors.cyanAccent)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            InkWell(
              onTap: () => setState(() => _showAll = !_showAll),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: Checkbox(
                      value: _showAll,
                      onChanged: (v) => setState(() => _showAll = v ?? false),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  const SizedBox(width: 3),
                  const Text('显示全部',
                      style: TextStyle(fontSize: 11, color: Colors.grey)),
                ],
              ),
            ),
            const Spacer(),
            Text(
              '区块码点合计: ${state.charsetSize}',
              style: const TextStyle(fontSize: 10, color: Colors.grey),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Container(
          height: 190,
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E1E),
            border: Border.all(color: Colors.grey.shade800),
            borderRadius: BorderRadius.circular(4),
          ),
          child: blocks.isEmpty
              ? const Center(
                  child: Text(
                    '未选中任何字符集区块',
                    style: TextStyle(color: Colors.grey, fontSize: 11),
                  ),
                )
              : ListView.builder(
                  itemExtent: 26.0,
                  itemCount: blocks.length,
                  itemBuilder: (context, i) {
                    final index = blocks[i].index;
                    final block = blocks[i].block;
                    final selected = state.selectedBlockIndexes.contains(index);
                    return InkWell(
                      onTap: () => state.toggleBlock(index, !selected),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 16,
                              height: 16,
                              child: Checkbox(
                                value: selected,
                                onChanged: (v) =>
                                    state.toggleBlock(index, v ?? false),
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                                visualDensity: VisualDensity.compact,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                block.name,
                                style: const TextStyle(fontSize: 11),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                              if (block.direction == TextDir.rtl)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 3, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF4A3A00),
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                  child: const Text('RTL',
                                      style: TextStyle(
                                          fontSize: 9,
                                          color: Colors.amberAccent)),
                                ),
                              const SizedBox(width: 4),
                              Text(
                                '${formatCodePoint(block.start)}-${formatCodePoint(block.end)}',
                                style: const TextStyle(
                                    fontSize: 10,
                                    color: Colors.cyanAccent,
                                    fontFamily: 'Consolas'),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
        ),
        const SizedBox(height: 10),
        const Text('自定义码点范围',
            style: TextStyle(
                color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        TextField(
          onChanged: state.setCustomRangeInput,
          style: const TextStyle(fontSize: 11, fontFamily: 'Consolas'),
          decoration: InputDecoration(
            isDense: true,
            hintText: '0x20-0x7E, U+4E00-U+9FFF, 32-126',
            hintStyle: const TextStyle(fontSize: 10, color: Colors.grey),
            filled: true,
            fillColor: const Color(0xFF1E1E1E),
            errorText: rangeError,
            errorStyle: const TextStyle(fontSize: 10),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(4),
              borderSide: BorderSide(color: Colors.grey.shade800),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(4),
              borderSide: BorderSide(color: Colors.grey.shade800),
            ),
          ),
        ),
        const SizedBox(height: 10),
        const Text('从文本导入字符',
            style: TextStyle(
                color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ElevatedButton.icon(
              onPressed: () => _importText(context, state),
              icon: const Icon(Icons.text_snippet, size: 14),
              label: const Text('选择 txt 文件', style: TextStyle(fontSize: 12)),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF333333),
                foregroundColor: Colors.cyanAccent,
                minimumSize: const Size(0, 28),
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
            ),
            if (state.importedText.isNotEmpty)
              InkWell(
                onTap: state.clearImportedText,
                child: const Icon(Icons.close, size: 14, color: Colors.grey),
              ),
          ],
        ),
        if (state.importedText.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '已导入 ${state.importedText.characters.length} 个字素 '
              '(含组合附标整体提取)',
              style: const TextStyle(fontSize: 10, color: Colors.grey),
            ),
          ),
      ],
    );
  }

  Future<void> _importText(BuildContext context, FontExtractorState state) async {
    try {
      final file = await openFile(acceptedTypeGroups: const [
        XTypeGroup(label: 'Text Files', extensions: ['txt', 'md', 'csv']),
        XTypeGroup(label: 'All Files', extensions: []),
      ]);
      if (file != null) {
        await state.importTextFile(file.path);
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(backgroundColor: Colors.redAccent, content: Text('导入失败: $e')),
        );
      }
    }
  }
}
