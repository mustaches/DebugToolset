import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:path/path.dart' as p;

import 'package:provider/provider.dart';

import '../../../providers/font_extractor_state.dart';
import '../models/lang_binding.dart';
import '../utils/font_coverage.dart';
import '../utils/font_info.dart';

/// In-app font picker that lists fonts from the OS font directory.
///
/// The native file dialog cannot reliably browse `C:\Windows\Fonts`
/// (it is a special shell folder and type filters match nothing there),
/// so we scan the directory ourselves and present a searchable list.
///
/// Fonts can be filtered by target script (中文/日文/西里尔...). When
/// [targetRanges] is given (the charset currently selected in the extractor),
/// an extra "当前字符集" target is offered and selected by default, showing
/// how much of that charset each font actually covers.
Future<String?> showFontPickerDialog(
  BuildContext context, {
  CodePointRanges? targetRanges,
  String? initialContinent,
  String? initialRegion,
  String? initialCountry,
  String? initialScript,
  LangBinding? initialLangBinding,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _FontPickerDialog(
      targetRanges: targetRanges,
      initialContinent: initialContinent,
      initialRegion: initialRegion,
      initialCountry: initialCountry,
      initialScript: initialScript,
      initialLangBinding: initialLangBinding,
    ),
  );
}

/// Returns the OS font directory candidates that exist on this machine.
List<Directory> systemFontDirs() {
  final dirs = <Directory>[];
  if (Platform.isWindows) {
    final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    dirs.add(Directory('$root\\Fonts'));
    final local = Platform.environment['LOCALAPPDATA'];
    if (local != null) {
      dirs.add(Directory('$local\\Microsoft\\Windows\\Fonts'));
    }
  } else if (Platform.isMacOS) {
    dirs.add(Directory('/System/Library/Fonts'));
    dirs.add(Directory('/Library/Fonts'));
  } else if (Platform.isLinux) {
    dirs.add(Directory('/usr/share/fonts'));
    dirs.add(Directory('${Platform.environment['HOME'] ?? ''}/.fonts'));
  }
  return dirs.where((d) => d.existsSync()).toList();
}

const _fontExtensions = {'.ttf', '.otf', '.ttc'};

/// Target filter values: [-2] = 全部字体, [-1] = 当前字符集, >= 0 indexes
/// into [kScriptGroups].
const _targetAll = -2;
const _targetCharset = -1;

class _FontPickerDialog extends StatefulWidget {
  final CodePointRanges? targetRanges;
  final String? initialContinent;
  final String? initialRegion;
  final String? initialCountry;
  final String? initialScript;
  final LangBinding? initialLangBinding;

  const _FontPickerDialog({
    this.targetRanges,
    this.initialContinent,
    this.initialRegion,
    this.initialCountry,
    this.initialScript,
    this.initialLangBinding,
  });

  @override
  State<_FontPickerDialog> createState() => _FontPickerDialogState();
}

class _FontPickerDialogState extends State<_FontPickerDialog> {
  final _searchController = TextEditingController();
  List<File> _fonts = [];
  String _query = '';
  String? _scanError;

  late String _selectedContinent;
  late String _selectedRegion;
  late String _selectedCountry;

  late int _target;

  List<String> get _continents {
    final list = <String>['全部'];
    for (final g in kScriptGroups) {
      if (!list.contains(g.continent)) list.add(g.continent);
    }
    return list;
  }

  List<String> _regionsFor(String continent) {
    final list = <String>['全部'];
    for (final g in kScriptGroups) {
      if (continent != '全部' && g.continent != continent) continue;
      if (!list.contains(g.region)) list.add(g.region);
    }
    return list;
  }

  List<String> _countriesFor(String continent, String region) {
    final list = <String>['全部'];
    for (final g in kScriptGroups) {
      if (continent != '全部' && g.continent != continent) continue;
      if (region != '全部' && g.region != region) continue;
      if (!list.contains(g.country)) list.add(g.country);
    }
    return list;
  }

  int get _targetCodePointCount {
    final ranges = widget.targetRanges;
    if (ranges == null) return 0;
    int total = 0;
    for (final r in ranges) {
      total += r.end - r.start + 1;
    }
    return total;
  }

  @override
  void initState() {
    super.initState();

    _selectedContinent = widget.initialContinent ?? '全部';
    if (!_continents.contains(_selectedContinent)) _selectedContinent = '全部';

    _selectedRegion = widget.initialRegion ?? '全部';
    if (!_regionsFor(_selectedContinent).contains(_selectedRegion)) {
      _selectedRegion = '全部';
    }

    _selectedCountry = widget.initialCountry ?? '全部';
    if (!_countriesFor(_selectedContinent, _selectedRegion)
        .contains(_selectedCountry)) {
      _selectedCountry = '全部';
    }

    if (widget.initialLangBinding != null) {
      final binding = widget.initialLangBinding!;
      final idx = kScriptGroups.indexWhere((g) =>
          (g.country == binding.countryTag && g.script == binding.scriptTag) ||
          g.name.contains(binding.name));
      if (idx != -1) {
        _target = idx;
      } else {
        _target = widget.targetRanges != null ? _targetCharset : _targetAll;
      }
    } else if (widget.initialScript != null && widget.initialScript != '全部') {
      final idx =
          kScriptGroups.indexWhere((g) => g.script == widget.initialScript);
      if (idx != -1) {
        _target = idx;
      } else {
        _target = widget.targetRanges != null ? _targetCharset : _targetAll;
      }
    } else {
      _target = widget.targetRanges != null ? _targetCharset : _targetAll;
    }

    _scan();
  }

  void _notifySelectionToState({String? fontPath}) {
    try {
      final state = context.read<FontExtractorState>();
      final ScriptGroup? group =
          (_target >= 0 && _target < kScriptGroups.length)
              ? kScriptGroups[_target]
              : null;

      state.selectBlocksForFilter(
        continent: _selectedContinent,
        region: _selectedRegion,
        country: _selectedCountry,
        scriptGroup: group,
        fontPath: fontPath,
      );
    } catch (_) {}
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _scan() {
    try {
      final files = <File>[];
      for (final dir in systemFontDirs()) {
        for (final entity in dir.listSync(recursive: true, followLinks: false)) {
          if (entity is File &&
              _fontExtensions.contains(p.extension(entity.path).toLowerCase())) {
            files.add(entity);
          }
        }
      }
      files.sort((a, b) => p
          .basename(a.path)
          .toLowerCase()
          .compareTo(p.basename(b.path).toLowerCase()));
      setState(() => _fonts = files);
      _scanNameInfo();
      _scanCoverage();
    } catch (e) {
      setState(() => _scanError = '$e');
    }
  }

  /// Scans all fonts for their name/version metadata in small batches so
  /// the search box can filter by font name as well as file name.
  Future<void> _scanNameInfo() async {
    if (_nameInfoScanning) return;
    _nameInfoScanning = true;
    const batch = 32;
    final all = List<File>.from(_fonts);
    for (int i = 0; i < all.length; i += batch) {
      if (!mounted) break;
      final end = (i + batch > all.length) ? all.length : i + batch;
      await Future.wait(
        all.sublist(i, end).map((f) => _nameInfo(f.path)),
      );
      if (mounted) setState(() {});
    }
    _nameInfoScanning = false;
    if (mounted) setState(() {});
  }

  // Process-global font family cache and counter so each font file gets a
  // unique, permanent family name in the Flutter engine that persists across
  // dialog re-opens and hot reloads.
  static int _globalFamilyCounter = 0;
  static final Map<String, Future<String?>> _globalFamilyFutures = {};

  Future<String?> _loadFamily(String path) {
    return _globalFamilyFutures.putIfAbsent(path, () {
      final family = 'FPREV_${_globalFamilyCounter++}';
      return () async {
        try {
          final bytes = await File(path).readAsBytes();
          final loader = FontLoader(family);
          loader.addFont(Future.value(ByteData.sublistView(bytes)));
          await loader.load();
          return family;
        } catch (_) {
          return null;
        }
      }();
    });
  }

  // Monospace filtering state.
  bool _monoOnly = false;
  bool _monoScanning = false;
  int _monoScanned = 0;
  final Map<String, bool> _monoResults = {};

  // Embedded-bitmap filtering state.
  bool _bitmapOnly = false;
  bool _bitmapScanning = false;
  int _bitmapScanned = 0;
  final Map<String, bool> _bitmapResults = {};

  // Name/version metadata cache.
  bool _nameInfoScanning = false;
  final Map<String, FontNameInfo> _nameInfoResults = {};

  // Cmap coverage cache. A null value means the cmap could not be read.
  bool _coverageScanning = false;
  int _coverageScanned = 0;
  final Map<String, CodePointRanges?> _cmapResults = {};

  /// Checks the font file's own `post.isFixedPitch` flag (fast, no
  /// font-engine loading) and caches the result.
  Future<bool> _isMono(String path) async {
    final cached = _monoResults[path];
    if (cached != null) return cached;
    final mono = await isMonospaceFontFile(path);
    _monoResults[path] = mono;
    return mono;
  }

  /// Reads the font's `name` table (full name + version) and caches it.
  Future<FontNameInfo> _nameInfo(String path) async {
    final cached = _nameInfoResults[path];
    if (cached != null) return cached;
    final info = await readFontNameInfo(path);
    _nameInfoResults[path] = info;
    return info;
  }

  /// Reads the font's `cmap` table and caches the supported ranges.
  Future<CodePointRanges?> _cmap(String path) async {
    if (_cmapResults.containsKey(path)) return _cmapResults[path];
    final ranges = await readFontCmap(path);
    _cmapResults[path] = ranges;
    return ranges;
  }

  /// Scans all fonts for their cmap coverage in small batches so the UI
  /// stays responsive; the list updates as results arrive.
  Future<void> _scanCoverage() async {
    if (_coverageScanning) return;
    _coverageScanning = true;
    _coverageScanned = 0;
    const batch = 32;
    final all = List<File>.from(_fonts);
    for (int i = 0; i < all.length; i += batch) {
      if (!mounted) break;
      final end = (i + batch > all.length) ? all.length : i + batch;
      await Future.wait(
        all.sublist(i, end).map((f) => _cmap(f.path)),
      );
      _coverageScanned = end;
      if (mounted) setState(() {});
    }
    _coverageScanning = false;
    if (mounted) setState(() {});
  }

  /// Coverage of the current target for [path], or null when the target is
  /// "全部字体", the cmap is not scanned yet, or the cmap is unreadable.
  double? _coverageFor(String path) {
    if (_target == _targetAll) return null;
    final cmap = _cmapResults[path];
    if (cmap == null) return null;
    if (_target == _targetCharset) {
      return coverageOfRanges(cmap, widget.targetRanges!);
    }
    return coverageOfRanges(cmap, kScriptGroups[_target].ranges);
  }

  /// Script-group badges (coverage >= 80%) for a font, at most 4.
  List<String> _badgesFor(String path) {
    final cmap = _cmapResults[path];
    if (cmap == null) return const [];
    final tags = <String>[];
    for (final group in kScriptGroups) {
      if (coverageOfRanges(cmap, group.ranges) >= 0.8) {
        tags.add(group.tag);
        if (tags.length >= 4) break;
      }
    }
    return tags;
  }

  void _setMonoOnly(bool value) {
    setState(() => _monoOnly = value);
    if (value) _scanMono();
  }

  /// Scans all fonts for the monospace flag in small batches so the UI
  /// stays responsive; the list updates as results arrive.
  Future<void> _scanMono() async {
    if (_monoScanning) return;
    _monoScanning = true;
    _monoScanned = 0;
    const batch = 32;
    final all = List<File>.from(_fonts);
    for (int i = 0; i < all.length; i += batch) {
      if (!_monoOnly || !mounted) break;
      final end = (i + batch > all.length) ? all.length : i + batch;
      await Future.wait(
        all.sublist(i, end).map((f) => _isMono(f.path)),
      );
      _monoScanned = end;
      if (mounted) setState(() {});
    }
    _monoScanning = false;
    if (mounted) setState(() {});
  }

  /// Checks the font file for embedded bitmap tables (EBDT/CBDT/sbix/...)
  /// and caches the result.
  Future<bool> _hasBitmap(String path) async {
    final cached = _bitmapResults[path];
    if (cached != null) return cached;
    final has = await fontHasEmbeddedBitmap(path);
    _bitmapResults[path] = has;
    return has;
  }

  void _setBitmapOnly(bool value) {
    setState(() => _bitmapOnly = value);
    if (value) _scanBitmap();
  }

  /// Scans all fonts for embedded bitmap data in small batches so the UI
  /// stays responsive; the list updates as results arrive.
  Future<void> _scanBitmap() async {
    if (_bitmapScanning) return;
    _bitmapScanning = true;
    _bitmapScanned = 0;
    const batch = 32;
    final all = List<File>.from(_fonts);
    for (int i = 0; i < all.length; i += batch) {
      if (!_bitmapOnly || !mounted) break;
      final end = (i + batch > all.length) ? all.length : i + batch;
      await Future.wait(
        all.sublist(i, end).map((f) => _hasBitmap(f.path)),
      );
      _bitmapScanned = end;
      if (mounted) setState(() {});
    }
    _bitmapScanning = false;
    if (mounted) setState(() {});
  }

  /// Dynamic preview text builder for a font row: renders "[Country Name], [Target Language Name], [Monospace / Proportional Font]"
  /// in the selected target script/language.
  String _previewTextBuilder(bool isMono) {
    if (_target >= 0 && _target < kScriptGroups.length) {
      return kScriptGroups[_target].buildPreviewText(isMono);
    }
    if (_selectedCountry != '全部' || _selectedRegion != '全部' || _selectedContinent != '全部') {
      for (final g in kScriptGroups) {
        if (_selectedContinent != '全部' && g.continent != _selectedContinent) continue;
        if (_selectedRegion != '全部' && g.region != _selectedRegion) continue;
        if (_selectedCountry != '全部' && g.country != _selectedCountry) continue;
        return g.buildPreviewText(isMono);
      }
    }
    return isMono ? '中国，简体中文，等宽字体' : '中国，简体中文，比例字体';
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.toLowerCase();
    var filtered = _query.isEmpty
        ? List<File>.from(_fonts)
        : _fonts.where((f) {
            if (p.basename(f.path).toLowerCase().contains(query)) return true;
            final info = _nameInfoResults[f.path];
            final displayName = info?.displayName?.toLowerCase() ?? '';
            final version = info?.version?.toLowerCase() ?? '';
            return displayName.contains(query) || version.contains(query);
          }).toList();
    if (_monoOnly) {
      filtered = filtered.where((f) => _monoResults[f.path] == true).toList();
    }
    if (_bitmapOnly) {
      filtered =
          filtered.where((f) => _bitmapResults[f.path] == true).toList();
    }
    if (_target != _targetAll) {
      // Keep fonts covering at least half of the target, best coverage
      // first; fonts not yet scanned stay listed only while scanning runs.
      final scanned = <File>[];
      final pending = <File>[];
      for (final f in filtered) {
        final cov = _coverageFor(f.path);
        if (cov != null && cov >= 0.5) {
          scanned.add(f);
        } else if (cov == null &&
            _coverageScanning &&
            !_cmapResults.containsKey(f.path)) {
          pending.add(f);
        }
      }
      scanned.sort((a, b) => (_coverageFor(b.path) ?? 0)
          .compareTo(_coverageFor(a.path) ?? 0));
      filtered = [...scanned, ...pending];
    }

    return AlertDialog(
      backgroundColor: const Color(0xFF252525),
      title: const Text('选择字体', style: TextStyle(color: Colors.white, fontSize: 16)),
      content: SizedBox(
        width: 860,
        height: 520,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _searchController,
              autofocus: true,
              style: const TextStyle(fontSize: 13, fontFamily: 'Consolas'),
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 18),
                hintText: '搜索字体名称、版本或文件名...',
                hintStyle: const TextStyle(fontSize: 12, color: Colors.grey),
                filled: true,
                fillColor: const Color(0xFF1E1E1E),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(4),
                  borderSide: BorderSide(color: Colors.grey.shade800),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(4),
                  borderSide: BorderSide(color: Colors.grey.shade800),
                ),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: 6),
            // Classification & Target Script Dropdowns on a Single Row: 大洲 · 地区 · 国家 · 目标文字
            Row(
              children: [
                const Text('大洲：', style: TextStyle(fontSize: 11, color: Colors.grey)),
                const SizedBox(width: 3),
                Expanded(flex: 3, child: _buildContinentDropdown()),
                const SizedBox(width: 8),
                const Text('地区：', style: TextStyle(fontSize: 11, color: Colors.grey)),
                const SizedBox(width: 3),
                Expanded(flex: 3, child: _buildRegionDropdown()),
                const SizedBox(width: 8),
                const Text('国家：', style: TextStyle(fontSize: 11, color: Colors.grey)),
                const SizedBox(width: 3),
                Expanded(flex: 3, child: _buildCountryDropdown()),
                const SizedBox(width: 8),
                const Text('目标文字：', style: TextStyle(fontSize: 11, color: Colors.grey)),
                const SizedBox(width: 3),
                Expanded(flex: 5, child: _buildTargetDropdown()),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                SizedBox(
                  width: 18,
                  height: 18,
                  child: Checkbox(
                    value: _monoOnly,
                    onChanged: (v) => _setMonoOnly(v ?? false),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                const SizedBox(width: 6),
                const Text('只显示等宽字体', style: TextStyle(fontSize: 12)),
                const SizedBox(width: 16),
                SizedBox(
                  width: 18,
                  height: 18,
                  child: Checkbox(
                    value: _bitmapOnly,
                    onChanged: (v) => _setBitmapOnly(v ?? false),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                const SizedBox(width: 6),
                const Text('只显示包含点阵字库的字体',
                    style: TextStyle(fontSize: 12)),
                const Spacer(),
                if (_bitmapOnly && _bitmapScanning)
                  Text(
                    '点阵检测 $_bitmapScanned/${_fonts.length}...',
                    style: const TextStyle(fontSize: 10, color: Colors.grey),
                  ),
                if (_monoOnly && _monoScanning)
                  Text(
                    '等宽检测 $_monoScanned/${_fonts.length}...',
                    style: const TextStyle(fontSize: 10, color: Colors.grey),
                  ),
                if (_coverageScanning)
                  Text(
                    '覆盖率检测 $_coverageScanned/${_fonts.length}...',
                    style: const TextStyle(fontSize: 10, color: Colors.grey),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Text(
                  _scanError != null
                      ? '扫描失败: $_scanError'
                      : '${filtered.length} / ${_fonts.length} 个字体文件',
                  style: TextStyle(
                    fontSize: 11,
                    color: _scanError != null ? Colors.redAccent : Colors.grey,
                  ),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: _browseOther,
                  icon: const Icon(Icons.folder_open, size: 14),
                  label: const Text('浏览其他位置...', style: TextStyle(fontSize: 11)),
                  style: TextButton.styleFrom(foregroundColor: Colors.cyanAccent),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E1E),
                  border: Border.all(color: Colors.grey.shade800),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: filtered.isEmpty
                    ? Center(
                        child: Text(
                          _target != _targetAll && !_coverageScanning
                              ? '没有覆盖该目标文字的字体'
                              : '没有匹配的字体',
                          style:
                              const TextStyle(color: Colors.grey, fontSize: 12),
                        ),
                      )
                    : ListView.separated(
                        itemCount: filtered.length,
                        separatorBuilder: (context, index) => Divider(
                          height: 1,
                          thickness: 0.5,
                          color: Colors.grey.shade800,
                        ),
                        itemBuilder: (context, index) {
                          final file = filtered[index];
                          return _FontRow(
                            key: ValueKey(file.path),
                            index: index + 1,
                            file: file,
                            loadFamily: _loadFamily,
                            isMono: _isMono,
                            nameInfo: _nameInfo,
                            coverage: _coverageFor(file.path),
                            coveragePending: _target != _targetAll &&
                                !_cmapResults.containsKey(file.path),
                            badges: _badgesFor(file.path),
                            previewTextBuilder: _previewTextBuilder,
                            onTap: () {
                              _notifySelectionToState(fontPath: file.path);
                              Navigator.of(context).pop(file.path);
                            },
                          );
                        },
                      ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消', style: TextStyle(color: Colors.grey)),
        ),
      ],
    );
  }

  Widget _buildContinentDropdown() {
    final continents = _continents;
    if (!continents.contains(_selectedContinent)) _selectedContinent = '全部';
    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        border: Border.all(color: Colors.grey.shade800),
        borderRadius: BorderRadius.circular(4),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _selectedContinent,
          isExpanded: true,
          isDense: true,
          dropdownColor: const Color(0xFF2D2D2D),
          style: const TextStyle(fontSize: 11, color: Colors.cyanAccent),
          icon: const Icon(Icons.arrow_drop_down, size: 16, color: Colors.cyanAccent),
          items: continents.map((c) {
            final count = c == '全部'
                ? kScriptGroups.length
                : kScriptGroups.where((g) => g.continent == c).length;
            return DropdownMenuItem<String>(
              value: c,
              child: Text('$c ($count)', overflow: TextOverflow.ellipsis),
            );
          }).toList(),
          onChanged: (val) {
            if (val != null) {
              setState(() {
                _selectedContinent = val;
                _selectedRegion = '全部';
                _selectedCountry = '全部';
              });
              _notifySelectionToState();
            }
          },
        ),
      ),
    );
  }

  Widget _buildRegionDropdown() {
    final regions = _regionsFor(_selectedContinent);
    if (!regions.contains(_selectedRegion)) _selectedRegion = '全部';
    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        border: Border.all(color: Colors.grey.shade800),
        borderRadius: BorderRadius.circular(4),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _selectedRegion,
          isExpanded: true,
          isDense: true,
          dropdownColor: const Color(0xFF2D2D2D),
          style: const TextStyle(fontSize: 11, color: Colors.cyanAccent),
          icon: const Icon(Icons.arrow_drop_down, size: 16, color: Colors.cyanAccent),
          items: regions.map((r) {
            final count = kScriptGroups.where((g) {
              if (_selectedContinent != '全部' && g.continent != _selectedContinent) {
                return false;
              }
              return r == '全部' || g.region == r;
            }).length;
            return DropdownMenuItem<String>(
              value: r,
              child: Text('$r ($count)', overflow: TextOverflow.ellipsis),
            );
          }).toList(),
          onChanged: (val) {
            if (val != null) {
              setState(() {
                _selectedRegion = val;
                _selectedCountry = '全部';
              });
              _notifySelectionToState();
            }
          },
        ),
      ),
    );
  }

  Widget _buildCountryDropdown() {
    final countries = _countriesFor(_selectedContinent, _selectedRegion);
    if (!countries.contains(_selectedCountry)) _selectedCountry = '全部';
    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        border: Border.all(color: Colors.grey.shade800),
        borderRadius: BorderRadius.circular(4),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _selectedCountry,
          isExpanded: true,
          isDense: true,
          dropdownColor: const Color(0xFF2D2D2D),
          style: const TextStyle(fontSize: 11, color: Colors.cyanAccent),
          icon: const Icon(Icons.arrow_drop_down, size: 16, color: Colors.cyanAccent),
          items: countries.map((c) {
            final count = kScriptGroups.where((g) {
              if (_selectedContinent != '全部' && g.continent != _selectedContinent) {
                return false;
              }
              if (_selectedRegion != '全部' && g.region != _selectedRegion) {
                return false;
              }
              return c == '全部' || g.country == c;
            }).length;
            return DropdownMenuItem<String>(
              value: c,
              child: Text('$c ($count)', overflow: TextOverflow.ellipsis),
            );
          }).toList(),
          onChanged: (val) {
            if (val != null) {
              setState(() => _selectedCountry = val);
              _notifySelectionToState();
            }
          },
        ),
      ),
    );
  }

  Widget _buildTargetDropdown() {
    final filteredIndices = <int>[];
    for (int i = 0; i < kScriptGroups.length; i++) {
      final g = kScriptGroups[i];
      if (_selectedContinent != '全部' && g.continent != _selectedContinent) {
        continue;
      }
      if (_selectedRegion != '全部' && g.region != _selectedRegion) continue;
      if (_selectedCountry != '全部' && g.country != _selectedCountry) continue;
      filteredIndices.add(i);
    }

    final validValues = <int>[
      if (widget.targetRanges != null) _targetCharset,
      _targetAll,
      ...filteredIndices,
    ];
    final effectiveTarget = validValues.contains(_target) ? _target : _targetAll;

    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        border: Border.all(color: Colors.grey.shade800),
        borderRadius: BorderRadius.circular(4),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<int>(
          value: effectiveTarget,
          isExpanded: true,
          isDense: true,
          dropdownColor: const Color(0xFF2D2D2D),
          style: const TextStyle(fontSize: 11, color: Colors.white),
          items: [
            if (widget.targetRanges != null)
              DropdownMenuItem(
                value: _targetCharset,
                child: Text('当前字符集 ($_targetCodePointCount 码点)'),
              ),
            const DropdownMenuItem(value: _targetAll, child: Text('全部字体')),
            for (final i in filteredIndices)
              DropdownMenuItem(
                value: i,
                child: Text(kScriptGroups[i].name, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (v) {
            if (v != null) {
              setState(() => _target = v);
              _notifySelectionToState();
            }
          },
        ),
      ),
    );
  }

  Future<void> _browseOther() async {
    final file = await openFile(acceptedTypeGroups: const [
      XTypeGroup(
        label: 'Font Files (*.ttf, *.otf, *.ttc)',
        extensions: ['ttf', 'otf', 'ttc'],
      ),
      XTypeGroup(label: 'All Files', extensions: []),
    ]);
    if (file != null && mounted) {
      _notifySelectionToState(fontPath: file.path);
      Navigator.of(context).pop(file.path);
    }
  }
}

/// A font list row showing the file name, supported-script badges, target
/// coverage, plus a live preview of the font rendering sample text.
class _FontRow extends StatefulWidget {
  final int index;
  final File file;
  final Future<String?> Function(String path) loadFamily;
  final Future<bool> Function(String path) isMono;
  final Future<FontNameInfo> Function(String path) nameInfo;
  final double? coverage;
  final bool coveragePending;
  final List<String> badges;
  final String Function(bool isMono) previewTextBuilder;
  final VoidCallback onTap;

  const _FontRow({
    super.key,
    required this.index,
    required this.file,
    required this.loadFamily,
    required this.isMono,
    required this.nameInfo,
    required this.coverage,
    required this.coveragePending,
    required this.badges,
    required this.previewTextBuilder,
    required this.onTap,
  });

  @override
  State<_FontRow> createState() => _FontRowState();
}

class _FontRowState extends State<_FontRow> {
  String? _family;
  bool _isMono = false;
  FontNameInfo _nameInfo = const FontNameInfo.empty();

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void didUpdateWidget(covariant _FontRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.path != widget.file.path) {
      _loadData();
    }
  }

  void _loadData() {
    widget.isMono(widget.file.path).then((mono) {
      if (!mounted) return;
      setState(() => _isMono = mono);
    });
    widget.loadFamily(widget.file.path).then((family) {
      if (!mounted || family == null) return;
      setState(() => _family = family);
    });
    widget.nameInfo(widget.file.path).then((info) {
      if (!mounted) return;
      setState(() => _nameInfo = info);
    });
  }

  @override
  Widget build(BuildContext context) {
    final displayName = _nameInfo.displayName ?? p.basename(widget.file.path);
    final fileName = p.basename(widget.file.path);
    final previewText = widget.previewTextBuilder(_isMono);

    return InkWell(
      onTap: widget.onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 28,
                  alignment: Alignment.center,
                  child: Text(
                    '${widget.index}',
                    style: const TextStyle(
                      color: Colors.grey,
                      fontSize: 12,
                      fontFamily: 'Consolas',
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.font_download,
                  size: 13,
                  color: _isMono ? Colors.cyanAccent : Colors.grey.shade600,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    displayName,
                    style: TextStyle(
                      fontSize: 13,
                      fontFamily: 'Consolas',
                      color: _isMono ? Colors.cyanAccent : Colors.white,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Flexible(
                  fit: FlexFit.loose,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    physics: const NeverScrollableScrollPhysics(),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final tag in widget.badges)
                          Container(
                            margin: const EdgeInsets.only(left: 3),
                            padding:
                                const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                            decoration: BoxDecoration(
                              color: const Color(0xFF3A3A20),
                              borderRadius: BorderRadius.circular(2),
                            ),
                            child: Text(
                              tag,
                              style: const TextStyle(
                                  fontSize: 9, color: Colors.amberAccent),
                            ),
                          ),
                        if (_isMono)
                          Container(
                            margin: const EdgeInsets.only(left: 3),
                            padding:
                                const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: const Color(0xFF0A4A5A),
                              borderRadius: BorderRadius.circular(2),
                            ),
                            child: const Text('等宽',
                                style: TextStyle(
                                    fontSize: 9, color: Colors.cyanAccent)),
                          ),
                        if (widget.coverage != null)
                          Container(
                            margin: const EdgeInsets.only(left: 3),
                            padding:
                                const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: _coverageBg(widget.coverage!),
                              borderRadius: BorderRadius.circular(2),
                            ),
                            child: Text(
                              '覆盖 ${(widget.coverage! * 100).toStringAsFixed(0)}%',
                              style: TextStyle(
                                  fontSize: 9, color: _coverageFg(widget.coverage!)),
                            ),
                          )
                        else if (widget.coveragePending)
                          const Padding(
                            padding: EdgeInsets.only(left: 3),
                            child: Text('检测中…',
                                style: TextStyle(fontSize: 9, color: Colors.grey)),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 45),
              child: Text(
                '${_nameInfo.version ?? '未知版本'} · $fileName',
                style: const TextStyle(
                  fontSize: 11,
                  color: Colors.grey,
                  fontFamily: 'Consolas',
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(height: 2),
            // Preview rendered with the candidate font. Falls back to the
            // default font until the file is registered.
            Text(
              previewText,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 28,
                height: 1.25,
                color: _family != null ? Colors.white : Colors.white38,
                fontFamily: _family,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _coverageBg(double coverage) {
    if (coverage >= 0.99) return const Color(0xFF1A4A20);
    if (coverage >= 0.8) return const Color(0xFF0A4A5A);
    return const Color(0xFF4A3A00);
  }

  Color _coverageFg(double coverage) {
    if (coverage >= 0.99) return Colors.greenAccent;
    if (coverage >= 0.8) return Colors.cyanAccent;
    return Colors.amberAccent;
  }
}
