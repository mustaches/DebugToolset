/// Vivado 器件筛选选择器：Category/Family/Package/Speed/Temperature/Static power
/// 联动下拉 + 搜索 + 结果表，由 demo_prj 对话框抽出的公共组件。
library;

import 'package:flutter/material.dart';

import '../codegen/ip_gen_config.dart';
import '../codegen/ip_target.dart';
import '../codegen/vivado_parts.dart';
import '../codegen/vivado_runner.dart';

class VivadoPartPicker extends StatefulWidget {
  /// 用于枚举器件的 Vivado 工具链。
  final VivadoToolchain toolchain;

  /// 初始选中的器件名（加载完成后若存在则选中并回调）。
  final String initialPart;

  /// 选中变化回调；加载开始回调 null，完成后回调选中项（无匹配为 null）。
  final ValueChanged<VivadoPart?> onSelected;

  /// 固定器件列表（测试用）；提供时不走异步加载。
  final List<VivadoPart>? parts;

  /// 器件列表加载器，默认 [listVivadoParts]。
  final Future<List<VivadoPart>> Function(VivadoToolchain toolchain)?
  partsLoader;

  /// 初始筛选条件；非空时在 initState 恢复，且不应用默认筛选。
  final VivadoPartFilters? initialFilters;

  /// 筛选条件变化回调（下拉/搜索/重置后，post-frame 回调完整新值）。
  final ValueChanged<VivadoPartFilters>? onFiltersChanged;

  const VivadoPartPicker({
    super.key,
    required this.toolchain,
    required this.initialPart,
    required this.onSelected,
    this.parts,
    this.partsLoader,
    this.initialFilters,
    this.onFiltersChanged,
  });

  @override
  State<VivadoPartPicker> createState() => _VivadoPartPickerState();
}

class _VivadoPartPickerState extends State<VivadoPartPicker> {
  final _searchController = TextEditingController();
  List<VivadoPart> _allParts = const [];
  List<VivadoPart> _filteredParts = const [];
  VivadoPart? _selected;
  bool _loading = false;
  String? _error;
  String _category = '';
  String _family = '';
  String _package = '';
  String _speed = '';
  String _temperature = '';
  String _staticPower = '';
  int _loadGen = 0;
  bool _defaultsApplied = false;

  void _ensureDefaultFilters() {
    if (_defaultsApplied ||
        widget.initialPart != VivadoSeries.zynqUltrascalePlus.part) {
      return;
    }
    _defaultsApplied = true;
    _category = 'General Purpose';
    _family = 'Zynq UltraScale+';
    _package = 'ffvb1156';
    _speed = '-2';
    _temperature = 'I';
    _applyFilters();
  }

  @override
  void initState() {
    super.initState();
    final initialFilters = widget.initialFilters;
    if (initialFilters != null) {
      _category = initialFilters.category;
      _family = initialFilters.family;
      _package = initialFilters.package;
      _speed = initialFilters.speed;
      _temperature = initialFilters.temperature;
      _staticPower = initialFilters.staticPower;
      _searchController.text = initialFilters.search;
      // 导入了筛选条件：标记默认筛选已应用，避免 _ensureDefaultFilters 覆盖
      _defaultsApplied = true;
    }
    final parts = widget.parts;
    if (parts != null) {
      _setParts(parts);
    } else {
      _loading = true;
      _loadParts();
    }
    _notifyFiltersChanged();
  }

  @override
  void didUpdateWidget(VivadoPartPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 工具链变化：丢弃旧结果，按新工具链重新加载
    if (oldWidget.toolchain.executable != widget.toolchain.executable) {
      _loadGen++;
      _selected = null;
      _error = null;
      final parts = widget.parts;
      if (parts != null) {
        setState(() => _setParts(parts));
      } else {
        setState(() => _loading = true);
        _loadParts();
      }
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _notifySelected(VivadoPart? part) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onSelected(part);
    });
  }

  void _notifyFiltersChanged() {
    final callback = widget.onFiltersChanged;
    if (callback == null) return;
    final filters = VivadoPartFilters(
      category: _category,
      family: _family,
      package: _package,
      speed: _speed,
      temperature: _temperature,
      staticPower: _staticPower,
      search: _searchController.text.trim(),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) callback(filters);
    });
  }

  Future<void> _loadParts() async {
    // 代次计数：快速切换工具链时丢弃过期结果，防止旧数据覆盖新数据
    final gen = ++_loadGen;
    _notifySelected(null);
    try {
      final loader = widget.partsLoader ?? listVivadoParts;
      final parts = await loader(widget.toolchain);
      if (!mounted || gen != _loadGen) return;
      setState(() {
        _error = null;
        _loading = false;
        _setParts(parts);
      });
    } catch (e) {
      if (!mounted || gen != _loadGen) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _setParts(List<VivadoPart> parts) {
    _allParts = parts;
    _selected = null;
    for (final p in parts) {
      if (p.name == widget.initialPart) {
        _selected = p;
        break;
      }
    }
    _notifySelected(_selected);
    _applyFilters();
  }

  bool _matches(VivadoPart p, [String? except]) {
    final search = _searchController.text.trim().toLowerCase();
    return (except == 'category' ||
            _category.isEmpty ||
            p.category == _category) &&
        (except == 'family' || _family.isEmpty || p.familyDisplay == _family) &&
        (except == 'package' || _package.isEmpty || p.package == _package) &&
        (except == 'speed' || _speed.isEmpty || p.speed == _speed) &&
        (except == 'temperature' ||
            _temperature.isEmpty ||
            p.temperature == _temperature) &&
        (except == 'staticPower' ||
            _staticPower.isEmpty ||
            p.staticPower == _staticPower) &&
        (search.isEmpty || p.name.toLowerCase().contains(search));
  }

  void _applyFilters() {
    _filteredParts = _allParts.where((p) => _matches(p)).toList();
  }

  List<String> _options(String except, String Function(VivadoPart) select) {
    final values =
        _allParts
            .where((p) => _matches(p, except))
            .map(select)
            .where((v) => v.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    return values;
  }

  void _resetFilters() {
    setState(() {
      _category = '';
      _family = '';
      _package = '';
      _speed = '';
      _temperature = '';
      _staticPower = '';
      _searchController.clear();
      _applyFilters();
    });
    _notifyFiltersChanged();
  }

  @override
  Widget build(BuildContext context) {
    _ensureDefaultFilters();
    if (_loading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('正在从 Vivado 读取器件列表…'),
          ],
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('器件列表加载失败：$_error', textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () {
                setState(() {
                  _error = null;
                  _loading = true;
                });
                _loadParts();
              },
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _resetFilters,
            icon: const Icon(Icons.filter_alt_off, size: 16),
            label: const Text('Reset All Filters'),
          ),
        ),
        Row(
          children: [
            Expanded(
              child: _filterDropdown(
                'Category',
                'category',
                _category,
                (p) => p.category,
                (v) => _category = v,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _filterDropdown(
                'Package',
                'package',
                _package,
                (p) => p.package,
                (v) => _package = v,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _filterDropdown(
                'Temperature',
                'temperature',
                _temperature,
                (p) => p.temperature,
                (v) => _temperature = v,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _filterDropdown(
                'Family',
                'family',
                _family,
                (p) => p.familyDisplay,
                (v) => _family = v,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _filterDropdown(
                'Speed',
                'speed',
                _speed,
                (p) => p.speed,
                (v) => _speed = v,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _filterDropdown(
                'Static power',
                'staticPower',
                _staticPower,
                (p) => p.staticPower,
                (v) => _staticPower = v,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _searchController,
          decoration: const InputDecoration(
            labelText: 'Search',
            prefixIcon: Icon(Icons.search, size: 18),
            isDense: true,
          ),
          onChanged: (_) {
            setState(_applyFilters);
            _notifyFiltersChanged();
          },
        ),
        const SizedBox(height: 8),
        Text(
          '${_filteredParts.length} / ${_allParts.length} 个器件',
          style: const TextStyle(fontSize: 13, color: Colors.white),
        ),
        const SizedBox(height: 6),
        _partRow(null),
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0xFF3A3A3A)),
            ),
            child: _filteredParts.isEmpty
                ? const Center(child: Text('没有符合筛选条件的器件'))
                : ListView.builder(
                    itemCount: _filteredParts.length,
                    itemBuilder: (context, i) => _partRow(_filteredParts[i]),
                  ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _selected == null ? '请选择目标器件' : '目标 PART：${_selected!.name}',
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14, color: Colors.white),
        ),
      ],
    );
  }

  Widget _filterDropdown(
    String label,
    String key,
    String value,
    String Function(VivadoPart) select,
    void Function(String) assign,
  ) {
    final values = _options(key, select);
    return DropdownButtonFormField<String>(
      key: ValueKey('$key:$value:${values.length}'),
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: label, isDense: true),
      items: [
        const DropdownMenuItem(
          value: '',
          child: Text('All', overflow: TextOverflow.ellipsis),
        ),
        for (final v in values)
          DropdownMenuItem(
            value: v,
            child: Text(v, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (v) {
        if (v == null) return;
        setState(() {
          assign(v);
          _applyFilters();
        });
        _notifyFiltersChanged();
      },
    );
  }

  Widget _partRow(VivadoPart? part) {
    final selected = part != null && part.name == _selected?.name;
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 9),
      child: Row(
        children: [
          SizedBox(
            width: 280,
            child: Text(part?.name ?? 'Part', overflow: TextOverflow.ellipsis),
          ),
          Expanded(
            child: Text(
              part?.familyDisplay ?? 'Family',
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(
            width: 82,
            child: Text(
              part?.package ?? 'Package',
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(
            width: 58,
            child: Text(
              part?.speed ?? 'Speed',
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(width: 44, child: Text(part?.temperature ?? 'Temp.')),
          SizedBox(width: 34, child: Text(part?.staticPower ?? 'Pwr')),
        ],
      ),
    );
    if (part == null) {
      return DefaultTextStyle(
        style: const TextStyle(
          fontSize: 13,
          color: Colors.white,
          fontWeight: FontWeight.bold,
        ),
        child: content,
      );
    }
    return InkWell(
      onTap: () {
        setState(() => _selected = part);
        _notifySelected(part);
      },
      child: Container(
        color: selected ? const Color(0xFF264F78) : null,
        child: DefaultTextStyle(
          style: const TextStyle(fontSize: 14, color: Colors.white),
          child: content,
        ),
      ),
    );
  }
}
