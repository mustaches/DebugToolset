import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import 'package:debug_tool_set/modules/font_extractor/models/lang_binding.dart';
import 'package:debug_tool_set/modules/font_extractor/utils/unicode_blocks.dart';
import 'package:debug_tool_set/modules/font_extractor/widgets/font_picker_dialog.dart';
import 'package:debug_tool_set/providers/font_extractor_state.dart';

/// Section body: font selection mode (Fallback Cascade vs Multi-Language Binding).
class FontSection extends StatefulWidget {
  const FontSection({super.key});

  @override
  State<FontSection> createState() => _FontSectionState();
}

class _FontSectionState extends State<FontSection> {
  String _selectedContinent = '全部';
  String _selectedRegion = '全部';
  String _selectedCountry = '全部';
  String _selectedScript = '全部';

  /// Continent categories in preset order, derived from the bindings.
  static List<String> _continentsFor(FontExtractorState state) {
    final continents = <String>['全部'];
    for (final b in state.langBindings) {
      if (!continents.contains(b.continentTag)) continents.add(b.continentTag);
    }
    return continents;
  }

  /// Region categories within [continent], derived from the bindings.
  static List<String> _regionsFor(FontExtractorState state, String continent) {
    final regions = <String>['全部'];
    for (final b in state.langBindings) {
      if (continent != '全部' && b.continentTag != continent) continue;
      if (!regions.contains(b.regionTag)) regions.add(b.regionTag);
    }
    return regions;
  }

  /// Country/Territory categories within [continent] and [region], derived from the bindings.
  static List<String> _countriesFor(
      FontExtractorState state, String continent, String region) {
    final countries = <String>['全部'];
    for (final b in state.langBindings) {
      if (b.countryTag.isEmpty) continue;
      if (continent != '全部' && b.continentTag != continent) continue;
      if (region != '全部' && b.regionTag != region) continue;
      if (!countries.contains(b.countryTag)) countries.add(b.countryTag);
    }
    return countries;
  }

  /// Script (charset) categories within [continent], [region] and [country], derived from the bindings.
  static List<String> _scriptsFor(FontExtractorState state, String continent,
      String region, String country) {
    final scripts = <String>['全部'];
    for (final b in state.langBindings) {
      if (b.scriptTag.isEmpty) continue;
      if (continent != '全部' && b.continentTag != continent) continue;
      if (region != '全部' && b.regionTag != region) continue;
      if (country != '全部' && b.countryTag != country) continue;
      if (!scripts.contains(b.scriptTag)) scripts.add(b.scriptTag);
    }
    return scripts;
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<FontExtractorState>();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Mode Selector Toggle
        Container(
          height: 30,
          margin: const EdgeInsets.only(bottom: 8),
          child: SegmentedButton<FontExtractMode>(
            segments: const [
              ButtonSegment<FontExtractMode>(
                value: FontExtractMode.fallback,
                label: Text('主备级联', style: TextStyle(fontSize: 11)),
                icon: Icon(Icons.layers_outlined, size: 13),
              ),
              ButtonSegment<FontExtractMode>(
                value: FontExtractMode.multiLang,
                label: Text('按国家/语言绑定', style: TextStyle(fontSize: 11)),
                icon: Icon(Icons.language, size: 13),
              ),
            ],
            selected: {state.extractMode},
            onSelectionChanged: (set) => state.setExtractMode(set.first),
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              padding: WidgetStateProperty.all(EdgeInsets.zero),
              backgroundColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.selected)) {
                  return const Color(0xFF0A4A5A);
                }
                return const Color(0xFF252525);
              }),
              foregroundColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.selected)) {
                  return Colors.cyanAccent;
                }
                return Colors.grey;
              }),
            ),
          ),
        ),

        if (state.extractMode == FontExtractMode.fallback)
          _buildFallbackSection(context, state)
        else
          _buildMultiLangSection(context, state),
      ],
    );
  }

  /// Classic Primary + Fallbacks cascade list.
  Widget _buildFallbackSection(BuildContext context, FontExtractorState state) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            ElevatedButton.icon(
              onPressed: () => _pickFontForFallback(context, state),
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
            padding: EdgeInsets.symmetric(vertical: 6),
            child: Text(
              '添加 TrueType/OpenType 字体文件，'
              '等宽字体效果最佳；可再添加后备字体补全缺字。',
              style: TextStyle(color: Colors.grey, fontSize: 11),
            ),
          )
        else
          ...List.generate(state.fontPaths.length, (i) {
            final path = state.fontPaths[i];
            final displayName = state.fontDisplayName(path);
            final fileName = p.basename(path);
            return Container(
              margin: const EdgeInsets.only(bottom: 4),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E1E),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: i == 0
                      ? Colors.cyanAccent.withValues(alpha: 0.5)
                      : Colors.grey.shade800,
                ),
              ),
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

  /// Multi-language font binding mode section categorized by Continent -> Region -> Country -> Language/Script.
  Widget _buildMultiLangSection(BuildContext context, FontExtractorState state) {
    final continents = _continentsFor(state);
    if (!continents.contains(_selectedContinent)) _selectedContinent = '全部';

    final regions = _regionsFor(state, _selectedContinent);
    if (!regions.contains(_selectedRegion)) _selectedRegion = '全部';

    final countries =
        _countriesFor(state, _selectedContinent, _selectedRegion);
    if (!countries.contains(_selectedCountry)) _selectedCountry = '全部';

    final scripts = _scriptsFor(
        state, _selectedContinent, _selectedRegion, _selectedCountry);
    if (!scripts.contains(_selectedScript)) _selectedScript = '全部';

    final filteredBindings = state.langBindings.where((b) {
      if (_selectedContinent != '全部' && b.continentTag != _selectedContinent) {
        return false;
      }
      if (_selectedRegion != '全部' && b.regionTag != _selectedRegion) {
        return false;
      }
      if (_selectedCountry != '全部' && b.countryTag != _selectedCountry) {
        return false;
      }
      if (_selectedScript != '全部' && b.scriptTag != _selectedScript) {
        return false;
      }
      return true;
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '按大洲、地区、国家和语言绑定专属字体，生成时自动分流打包：',
          style: TextStyle(fontSize: 10, color: Colors.grey),
        ),
        const SizedBox(height: 6),
        // Dropdown Row 1: Continent (大洲)
        Row(
          children: [
            const Text('大洲：',
                style: TextStyle(fontSize: 11, color: Colors.grey)),
            const SizedBox(width: 6),
            Expanded(
              child: Container(
                height: 28,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E1E),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.grey.shade800),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _selectedContinent,
                    isExpanded: true,
                    dropdownColor: const Color(0xFF252525),
                    style: const TextStyle(fontSize: 11, color: Colors.cyanAccent),
                    icon: const Icon(Icons.arrow_drop_down,
                        size: 18, color: Colors.cyanAccent),
                    items: continents.map((c) {
                      final count = c == '全部'
                          ? state.langBindings.length
                          : state.langBindings
                              .where((b) => b.continentTag == c)
                              .length;
                      return DropdownMenuItem<String>(
                        value: c,
                        child: Text(
                          '$c ($count 个语言)',
                          overflow: TextOverflow.ellipsis,
                        ),
                      );
                    }).toList(),
                    onChanged: (val) {
                      if (val != null) {
                        _updateFilterAndSyncBlocks(state,
                            continent: val,
                            region: '全部',
                            country: '全部',
                            script: '全部');
                      }
                    },
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        // Dropdown Row 2: Region (地区)
        Row(
          children: [
            const Text('地区：',
                style: TextStyle(fontSize: 11, color: Colors.grey)),
            const SizedBox(width: 6),
            Expanded(
              child: Container(
                height: 28,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E1E),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.grey.shade800),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _selectedRegion,
                    isExpanded: true,
                    dropdownColor: const Color(0xFF252525),
                    style: const TextStyle(fontSize: 11, color: Colors.cyanAccent),
                    icon: const Icon(Icons.arrow_drop_down,
                        size: 18, color: Colors.cyanAccent),
                    items: regions.map((r) {
                      final count = state.langBindings.where((b) {
                        if (_selectedContinent != '全部' &&
                            b.continentTag != _selectedContinent) {
                          return false;
                        }
                        return r == '全部' || b.regionTag == r;
                      }).length;
                      return DropdownMenuItem<String>(
                        value: r,
                        child: Text(
                          '$r ($count 个项目)',
                          overflow: TextOverflow.ellipsis,
                        ),
                      );
                    }).toList(),
                    onChanged: (val) {
                      if (val != null) {
                        _updateFilterAndSyncBlocks(state,
                            region: val, country: '全部', script: '全部');
                      }
                    },
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        // Dropdown Row 3: Country (国家)
        Row(
          children: [
            const Text('国家：',
                style: TextStyle(fontSize: 11, color: Colors.grey)),
            const SizedBox(width: 6),
            Expanded(
              child: Container(
                height: 28,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E1E),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.grey.shade800),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _selectedCountry,
                    isExpanded: true,
                    dropdownColor: const Color(0xFF252525),
                    style: const TextStyle(fontSize: 11, color: Colors.cyanAccent),
                    icon: const Icon(Icons.arrow_drop_down,
                        size: 18, color: Colors.cyanAccent),
                    items: countries.map((c) {
                      final count = state.langBindings.where((b) {
                        if (_selectedContinent != '全部' &&
                            b.continentTag != _selectedContinent) {
                          return false;
                        }
                        if (_selectedRegion != '全部' &&
                            b.regionTag != _selectedRegion) {
                          return false;
                        }
                        return c == '全部' || b.countryTag == c;
                      }).length;
                      return DropdownMenuItem<String>(
                        value: c,
                        child: Text(
                          '$c ($count 个语言)',
                          overflow: TextOverflow.ellipsis,
                        ),
                      );
                    }).toList(),
                    onChanged: (val) {
                      if (val != null) {
                        _updateFilterAndSyncBlocks(state,
                            country: val, script: '全部');
                      }
                    },
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        // Dropdown Row 4: Script (文字)
        Row(
          children: [
            const Text('文字：',
                style: TextStyle(fontSize: 11, color: Colors.grey)),
            const SizedBox(width: 6),
            Expanded(
              child: Container(
                height: 28,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E1E),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.grey.shade800),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _selectedScript,
                    isExpanded: true,
                    dropdownColor: const Color(0xFF252525),
                    style: const TextStyle(fontSize: 11, color: Colors.cyanAccent),
                    icon: const Icon(Icons.arrow_drop_down,
                        size: 18, color: Colors.cyanAccent),
                    items: scripts.map((s) {
                      final count = state.langBindings.where((b) {
                        if (_selectedContinent != '全部' &&
                            b.continentTag != _selectedContinent) {
                          return false;
                        }
                        if (_selectedRegion != '全部' &&
                            b.regionTag != _selectedRegion) {
                          return false;
                        }
                        if (_selectedCountry != '全部' &&
                            b.countryTag != _selectedCountry) {
                          return false;
                        }
                        return s == '全部' || b.scriptTag == s;
                      }).length;
                      return DropdownMenuItem<String>(
                        value: s,
                        child: Text(
                          '$s ($count 个语言)',
                          overflow: TextOverflow.ellipsis,
                        ),
                      );
                    }).toList(),
                    onChanged: (val) {
                      if (val != null) {
                        _updateFilterAndSyncBlocks(state, script: val);
                      }
                    },
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Container(
          constraints: const BoxConstraints(maxHeight: 220),
          child: SingleChildScrollView(
            child: Column(
              children: filteredBindings.map((binding) {
                final isBound = binding.fontPath != null;
                return InkWell(
                  onTap: () => state.selectBlocksForBindings([binding]),
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 4),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E1E1E),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: isBound
                            ? Colors.cyanAccent.withValues(alpha: 0.4)
                            : Colors.grey.shade800,
                      ),
                    ),
                  child: Row(
                    children: [
                      if (isBound) ...[
                        Builder(builder: (_) {
                          final boundSeq = state.langBindings
                                  .where((b) =>
                                      b.fontPath != null &&
                                      b.fontPath!.isNotEmpty)
                                  .toList()
                                  .indexOf(binding) +
                              1;
                          return Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 1),
                            margin: const EdgeInsets.only(right: 6),
                            decoration: BoxDecoration(
                              color: const Color(0xFF0A4A5A),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              '#$boundSeq',
                              style: const TextStyle(
                                fontSize: 9,
                                color: Colors.cyanAccent,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          );
                        }),
                      ],
                      Text(binding.flag, style: const TextStyle(fontSize: 14)),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    binding.name,
                                    style: const TextStyle(
                                        fontSize: 11, fontWeight: FontWeight.w500),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Flexible(
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 4, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF2A2A2A),
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                    child: Text(
                                      '${binding.continentTag} · ${binding.regionTag} · ${binding.countryTag} · ${binding.scriptTag}',
                                      style: const TextStyle(
                                          fontSize: 8, color: Colors.grey),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            Text(
                              isBound
                                  ? (binding.fontDisplayName ??
                                      p.basename(binding.fontPath!))
                                  : '未绑定 (默认回退)',
                              style: TextStyle(
                                fontSize: 10,
                                color: isBound
                                    ? Colors.cyanAccent
                                    : Colors.grey.shade600,
                                fontFamily: isBound ? 'Consolas' : null,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      if (isBound) ...[
                        InkWell(
                          onTap: () => _pickFontForLang(context, state, binding),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 4),
                            child: Icon(Icons.edit,
                                size: 14, color: Colors.cyanAccent),
                          ),
                        ),
                        InkWell(
                          onTap: () => state.unbindLangFont(binding.id),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 4),
                            child: Icon(Icons.link_off,
                                size: 14, color: Colors.grey),
                          ),
                        ),
                      ] else ...[
                        ElevatedButton(
                          onPressed: () =>
                              _pickFontForLang(context, state, binding),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF333333),
                            foregroundColor: Colors.cyanAccent,
                            minimumSize: const Size(0, 24),
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            elevation: 0,
                          ),
                          child: const Text('绑定字体',
                              style: TextStyle(fontSize: 10)),
                        ),
                      ],
                    ],
                  ),
                ),
              );
            }).toList(),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _pickFontForFallback(
      BuildContext context, FontExtractorState state) async {
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

  Future<void> _pickFontForLang(BuildContext context, FontExtractorState state,
      LangBinding binding) async {
    try {
      final path = await showFontPickerDialog(
        context,
        targetRanges: [
          for (final b in binding.blocks) (start: b.start, end: b.end),
        ],
        initialContinent: binding.continentTag,
        initialRegion: binding.regionTag,
        initialCountry: binding.countryTag,
        initialScript: binding.scriptTag,
        initialLangBinding: binding,
      );
      if (path != null) {
        await state.bindLangFont(binding.id, path);
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              backgroundColor: Colors.redAccent,
              content: Text('绑定 ${binding.name} 字体失败: $e')),
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

  void _updateFilterAndSyncBlocks(FontExtractorState state, {
    String? continent,
    String? region,
    String? country,
    String? script,
  }) {
    setState(() {
      if (continent != null) _selectedContinent = continent;
      if (region != null) _selectedRegion = region;
      if (country != null) _selectedCountry = country;
      if (script != null) _selectedScript = script;
    });

    final filtered = state.langBindings.where((b) {
      if (_selectedContinent != '全部' && b.continentTag != _selectedContinent) {
        return false;
      }
      if (_selectedRegion != '全部' && b.regionTag != _selectedRegion) {
        return false;
      }
      if (_selectedCountry != '全部' && b.countryTag != _selectedCountry) {
        return false;
      }
      if (_selectedScript != '全部' && b.scriptTag != _selectedScript) {
        return false;
      }
      return true;
    }).toList();

    state.selectBlocksForBindings(filtered);
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
