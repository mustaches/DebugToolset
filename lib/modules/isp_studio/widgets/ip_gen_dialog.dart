/// ISP 编组「生成Verilog IP」选项：厂商、Vivado 版本、器件与 IP 参数。
library;

import 'package:flutter/material.dart';

import '../codegen/ip_gen_config.dart';
import '../codegen/ip_target.dart';
import '../codegen/iverilog_sim.dart';
import '../codegen/vivado_parts.dart';
import '../codegen/vivado_runner.dart';
import 'ip_config_dialog_io.dart';
import 'vivado_part_picker.dart';

Future<IpGenOptions?> showIpGenDialog(
  BuildContext context, {
  IpGenOptions? initial,
  /// 编组内是否有 YUV↔RGB 节点；无则不显示「YUV 矩阵标准」选项。
  bool hasYuvMatrix = true,
  /// 编组内是否有色温节点；有序时显示「表存块 RAM」选项（USE_BRAM）。
  bool hasColorTemp = false,
  List<VivadoToolchain>? toolchains,
  List<VivadoPart>? parts,
  Future<List<VivadoPart>> Function(VivadoToolchain toolchain)? partsLoader,
}) {
  return showDialog<IpGenOptions>(
    context: context,
    builder: (ctx) => _IpGenDialog(
      initial: initial,
      hasYuvMatrix: hasYuvMatrix,
      hasColorTemp: hasColorTemp,
      toolchains: toolchains,
      parts: parts,
      partsLoader: partsLoader,
    ),
  );
}

class _IpGenDialog extends StatefulWidget {
  final IpGenOptions? initial;
  final bool hasYuvMatrix;
  final bool hasColorTemp;
  final List<VivadoToolchain>? toolchains;
  final List<VivadoPart>? parts;
  final Future<List<VivadoPart>> Function(VivadoToolchain toolchain)?
  partsLoader;

  const _IpGenDialog({
    this.initial,
    this.hasYuvMatrix = true,
    this.hasColorTemp = false,
    this.toolchains,
    this.parts,
    this.partsLoader,
  });

  @override
  State<_IpGenDialog> createState() => _IpGenDialogState();
}

class _IpGenDialogState extends State<_IpGenDialog> {
  late IpVendor _vendor;
  late VivadoSeries _series;
  late int _pixBits;
  late int _maxWidth;
  late int _gstrategy;
  late int _fold;
  late int _dspPipe;
  late bool _useBram;
  late String _yuvStandard;
  late String _vinType;
  late final List<VivadoToolchain> _toolchains;
  VivadoToolchain? _vivado;
  VivadoPart? _selected;
  late String _preferredPart;
  VivadoPartFilters? _filters;
  int _pickerGeneration = 0;
  IverilogToolchain? _iverilog;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _vendor = initial?.vendor ?? IpVendor.vivado;
    _series = initial?.series ?? VivadoSeries.zynqUltrascalePlus;
    _pixBits = initial?.pixBits ?? 0;
    _maxWidth = initial?.maxWidth ?? 3840;
    _gstrategy = initial?.gstrategy ?? 2;
    _fold = initial?.fold ?? 2;
    _dspPipe = initial?.dspPipe ?? 3;
    _useBram = initial?.useBram ?? true;
    _yuvStandard = initial?.yuvStandard ?? 'auto';
    _vinType = initial?.vinType ?? 'none';
    _preferredPart = initial?.vivadoPart ?? _series.part;
    _toolchains = List.of(widget.toolchains ?? detectVivadoInstallations());
    final selectedPath = initial?.vivadoExecutable ?? '';
    if (selectedPath.isNotEmpty &&
        !_toolchains.any((t) => t.executable == selectedPath)) {
      _toolchains.add(VivadoToolchain(selectedPath));
    }
    for (final toolchain in _toolchains) {
      if (toolchain.executable == selectedPath) {
        _vivado = toolchain;
        break;
      }
    }
    _vivado ??= preferredVivadoToolchain(_toolchains);
    _iverilog = detectIverilog();
  }

  void _confirm() {
    final vivado = _vivado;
    Navigator.pop(
      context,
      IpGenOptions(
        vendor: _vendor,
        series: _series,
        targetPart: _vendor.isVivado ? _selected?.name ?? '' : '',
        targetFamily: _vendor.isVivado ? _selected?.family ?? '' : '',
        vivadoExecutable: _vendor.isVivado ? vivado?.executable ?? '' : '',
        pixBits: _pixBits,
        maxWidth: _maxWidth,
        gstrategy: _gstrategy,
        fold: _gstrategy == 0 ? _fold : 1,
        dspPipe: _dspPipe,
        yuvStandard: _yuvStandard,
        vinType: _vinType,
        useBram: _useBram,
      ),
    );
  }

  IpGenConfig _currentConfig() {
    return IpGenConfig(
      options: IpGenOptions(
        vendor: _vendor,
        series: _series,
        targetPart: _selected?.name ?? _preferredPart,
        targetFamily: _selected?.family ?? widget.initial?.targetFamily ?? '',
        vivadoExecutable: _vivado?.executable ?? '',
        vinType: _vinType,
        pixBits: _pixBits,
        maxWidth: _maxWidth,
        gstrategy: _gstrategy,
        fold: _fold,
        dspPipe: _dspPipe,
        yuvStandard: _yuvStandard,
        useBram: _useBram,
      ),
      filters: _filters ?? const VivadoPartFilters(),
    );
  }

  Future<void> _saveConfig() async {
    final path = await pickSaveIpConfigPath('ipcfg');
    if (path == null || !mounted) return;
    try {
      final saved = await saveIpGenConfigFile(_currentConfig(), path, 'ipcfg');
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('配置已保存：$saved')));
    } catch (e) {
      if (mounted) await showIpConfigError(context, e);
    }
  }

  Future<void> _importConfig() async {
    final path = await pickOpenIpConfigPath('ipcfg');
    if (path == null || !mounted) return;
    try {
      final config = await readIpGenConfigFile(path);
      if (!mounted) return;
      final options = config.options;
      setState(() {
        _vendor = options.vendor;
        _series = options.series;
        _vinType = options.vinType;
        _pixBits = options.pixBits;
        _maxWidth = options.maxWidth;
        _gstrategy = options.gstrategy;
        _fold = options.fold;
        _dspPipe = options.dspPipe;
        _useBram = options.useBram;
        _yuvStandard = options.yuvStandard;
        _preferredPart = options.vivadoPart;
        _selected = null;
        _filters = config.filters;
        _pickerGeneration++;
        final executable = options.vivadoExecutable;
        if (executable.isNotEmpty &&
            !_toolchains.any((t) => t.executable == executable)) {
          _toolchains.add(VivadoToolchain(executable));
        }
        _vivado = null;
        for (final toolchain in _toolchains) {
          if (toolchain.executable == executable) {
            _vivado = toolchain;
            break;
          }
        }
        _vivado ??= preferredVivadoToolchain(_toolchains);
      });
    } catch (e) {
      if (mounted) await showIpConfigError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('生成Verilog IP'),
      content: _vendor.isVivado
          ? _buildVivadoContent()
          : _buildCompactContent(),
      actions: [
        TextButton(onPressed: _importConfig, child: const Text('导入配置')),
        TextButton(onPressed: _saveConfig, child: const Text('保存配置')),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _vendor.isVivado && _selected == null ? null : _confirm,
          child: const Text('生成'),
        ),
      ],
    );
  }

  Widget _buildVendor() {
    return DropdownButtonFormField<IpVendor>(
      initialValue: _vendor,
      decoration: const InputDecoration(labelText: '目标 FPGA 厂商'),
      items: [
        for (final v in IpVendor.values)
          DropdownMenuItem(
            value: v,
            enabled: v.enabled,
            child: Text(
              v.enabled ? v.displayName : '${v.displayName}（待完成）',
              style: v.enabled ? null : const TextStyle(color: Colors.grey),
            ),
          ),
      ],
      onChanged: (v) {
        if (v != null) setState(() => _vendor = v);
      },
    );
  }

  Widget _buildVivadoContent() {
    final vivado = _vivado;
    return SizedBox(
      width: 1080,
      height: 680,
      child: Column(
        children: [
          _buildVendor(),
          const SizedBox(height: 12),
          if (vivado == null)
            const Expanded(
              child: Center(child: Text('未检测到 Vivado；无法读取目标器件列表。')),
            )
          else ...[
            DropdownButtonFormField<VivadoToolchain>(
              initialValue: vivado,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Vivado 版本'),
              items: [
                for (final t in _toolchains)
                  DropdownMenuItem(
                    value: t,
                    child: Text(t.displayName, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (v) {
                if (v != null) setState(() => _vivado = v);
              },
            ),
            const SizedBox(height: 12),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    flex: 7,
                    child: VivadoPartPicker(
                      key: ValueKey('ip-picker-$_pickerGeneration'),
                      toolchain: vivado,
                      initialPart: _preferredPart,
                      initialFilters: _filters,
                      onFiltersChanged: (filters) => _filters = filters,
                      parts: widget.parts,
                      partsLoader: widget.partsLoader,
                      onSelected: (part) {
                        if (!mounted) return;
                        setState(() {
                          _selected = part;
                          if (part != null) _preferredPart = part.name;
                        });
                      },
                    ),
                  ),
                  const VerticalDivider(width: 24),
                  SizedBox(width: 300, child: _buildIpOptions()),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCompactContent() {
    return SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildVendor(),
            const SizedBox(height: 12),
            _buildIpOptions(),
          ],
        ),
      ),
    );
  }

  Widget _buildIpOptions() {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _label('像素位宽 PIX_BITS'),
          DropdownButtonFormField<int>(
            isExpanded: true,
            initialValue: _pixBits,
            items: [
              const DropdownMenuItem(value: 0, child: Text('位深推导（默认）')),
              for (final b in const [8, 10, 12, 14, 16])
                DropdownMenuItem(value: b, child: Text('$b bit')),
            ],
            onChanged: (v) {
              if (v != null) setState(() => _pixBits = v);
            },
          ),
          const SizedBox(height: 12),
          _label('最大行宽 MAX_WIDTH'),
          DropdownButtonFormField<int>(
            isExpanded: true,
            initialValue: _maxWidth,
            items: [
              for (final w in kIpMaxWidthOptions)
                DropdownMenuItem(value: w, child: Text('$w')),
            ],
            onChanged: (v) {
              if (v != null) setState(() => _maxWidth = v);
            },
          ),
          const SizedBox(height: 12),
          _label('优化策略 GSTRATEGY'),
          DropdownButtonFormField<int>(
            isExpanded: true,
            initialValue: _gstrategy,
            items: const [
              DropdownMenuItem(value: 2, child: Text('性能优先（乘法器优先用 DSP）')),
              DropdownMenuItem(value: 1, child: Text('平衡（综合器自选 LUT/DSP）')),
              DropdownMenuItem(value: 0, child: Text('面积优先（绑 LUT / 算子折叠）')),
            ],
            onChanged: (v) {
              if (v != null) setState(() => _gstrategy = v);
            },
          ),
          const SizedBox(height: 12),
          _label('折叠因子 FOLD（仅面积档生效）'),
          DropdownButtonFormField<int>(
            isExpanded: true,
            key: ValueKey(_gstrategy),
            initialValue: _gstrategy == 0 ? _fold : 1,
            items: [
              for (final f in const [1, 2, 4])
                DropdownMenuItem(value: f, child: Text('×$f')),
            ],
            onChanged: _gstrategy == 0
                ? (v) {
                    if (v != null) setState(() => _fold = v);
                  }
                : null,
          ),
          const SizedBox(height: 12),
          _label('段单元流水拍数 DSP_PIPE（func_fixed）'),
          DropdownButtonFormField<int>(
            isExpanded: true,
            initialValue: _dspPipe,
            items: const [
              DropdownMenuItem(
                value: 0,
                child: Text('0 = 纯组合（延迟最低）', overflow: TextOverflow.ellipsis),
              ),
              DropdownMenuItem(
                value: 1,
                child: Text('1 = 权重前段插一拍', overflow: TextOverflow.ellipsis),
              ),
              DropdownMenuItem(
                value: 2,
                child: Text('2 = 前段+中段各插一拍', overflow: TextOverflow.ellipsis),
              ),
              DropdownMenuItem(
                value: 3,
                child: Text(
                  '3 = DSP 内部全流水（Fmax 最高）',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
            onChanged: (v) {
              if (v != null) setState(() => _dspPipe = v);
            },
          ),
          if (widget.hasColorTemp) ...[
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('色温表存 Block RAM（USE_BRAM）', style: TextStyle(fontSize: 13)),
              subtitle: const Text(
                '勾选：白点/倒数表用块 RAM，CLB LUT 约减 40%（默认）；'
                '取消：组合 ROM 表（上一版实现，LUT 用量大）。',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
              value: _useBram,
              onChanged: (v) => setState(() => _useBram = v),
            ),
          ],
          if (widget.hasYuvMatrix) ...[
            const SizedBox(height: 12),
            _label('YUV 矩阵标准（YUV↔RGB）'),
            DropdownButtonFormField<String>(
              isExpanded: true,
              initialValue: _yuvStandard,
              items: const [
                DropdownMenuItem(value: 'auto', child: Text('跟随 ispflow 节点')),
                DropdownMenuItem(value: 'bt601', child: Text('BT.601（SD）')),
                DropdownMenuItem(value: 'bt709', child: Text('BT.709（HD）')),
                DropdownMenuItem(value: 'bt2020', child: Text('BT.2020（UHD）')),
              ],
              onChanged: (v) {
                if (v != null) setState(() => _yuvStandard = v);
              },
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Icon(
                _iverilog != null ? Icons.check_circle : Icons.info_outline,
                size: 15,
                color: _iverilog != null ? Colors.green : Colors.orange,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _iverilog != null
                      ? '已检测到 Icarus Verilog，可一键仿真'
                      : '未检测到 iverilog（一键仿真暂不可用；导出功能不受影响）',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            '以上参数在 Vivado Customize IP / SmartDesign generics 界面中可再次修改。',
            style: TextStyle(fontSize: 11, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(text, style: const TextStyle(fontSize: 12)),
  );
}
