/// Vivado demo_prj 导出配置：Vivado 版本、器件筛选与 IP 实例参数。
library;

import 'package:flutter/material.dart';

import '../codegen/ip_gen_config.dart';
import '../codegen/ip_target.dart';
import '../codegen/vivado_parts.dart';
import '../codegen/vivado_runner.dart';
import 'ip_config_dialog_io.dart';
import 'vivado_part_picker.dart';

Future<IpGenOptions?> showDemoPrjDialog(
  BuildContext context, {
  required IpGenOptions initial,
  /// 编组内是否有 YUV↔RGB 节点；无则不显示「YUV 矩阵标准」选项。
  bool hasYuvMatrix = true,
  String defaultProjectName = 'demo_prj',
  VivadoToolchain? vivado,
  List<VivadoToolchain>? toolchains,
  List<VivadoPart>? parts,
  Future<List<VivadoPart>> Function(VivadoToolchain toolchain)? partsLoader,
}) {
  return showDialog<IpGenOptions>(
    context: context,
    builder: (ctx) => _DemoPrjDialog(
      initial: initial,
      hasYuvMatrix: hasYuvMatrix,
      defaultProjectName: defaultProjectName,
      vivado: vivado,
      toolchains: toolchains,
      parts: parts,
      partsLoader: partsLoader,
    ),
  );
}

class _DemoPrjDialog extends StatefulWidget {
  final IpGenOptions initial;
  final bool hasYuvMatrix;
  final String defaultProjectName;
  final VivadoToolchain? vivado;
  final List<VivadoToolchain>? toolchains;
  final List<VivadoPart>? parts;
  final Future<List<VivadoPart>> Function(VivadoToolchain toolchain)?
  partsLoader;

  const _DemoPrjDialog({
    required this.initial,
    required this.hasYuvMatrix,
    required this.defaultProjectName,
    this.vivado,
    this.toolchains,
    this.parts,
    this.partsLoader,
  });

  @override
  State<_DemoPrjDialog> createState() => _DemoPrjDialogState();
}

class _DemoPrjDialogState extends State<_DemoPrjDialog> {
  late VivadoSeries _series;
  late int _pixBits;
  late int _maxWidth;
  late int _gstrategy;
  late int _fold;
  late int _dspPipe;
  late String _yuvStandard;
  late String _projectName;
  late final List<VivadoToolchain> _toolchains;
  VivadoToolchain? _vivado;
  VivadoPart? _selected;
  late String _preferredPart;
  VivadoPartFilters? _filters;
  int _pickerGeneration = 0;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _series = initial.series;
    _pixBits = initial.pixBits;
    _maxWidth = initial.maxWidth;
    _gstrategy = initial.gstrategy;
    _fold = initial.fold;
    _dspPipe = initial.dspPipe;
    _yuvStandard = initial.yuvStandard;
    _projectName = initial.projectName == 'demo_prj'
        ? widget.defaultProjectName
        : initial.projectName;
    _preferredPart = initial.vivadoPart;
    _toolchains = List.of(
      widget.toolchains ??
          (widget.vivado != null
              ? [widget.vivado!]
              : detectVivadoInstallations()),
    );
    if (initial.vivadoExecutable.isNotEmpty &&
        !_toolchains.any((t) => t.executable == initial.vivadoExecutable)) {
      _toolchains.add(VivadoToolchain(initial.vivadoExecutable));
    }
    for (final toolchain in _toolchains) {
      if (toolchain.executable == initial.vivadoExecutable) {
        _vivado = toolchain;
        break;
      }
    }
    _vivado ??= widget.vivado;
    _vivado ??= preferredVivadoToolchain(_toolchains);
  }

  Future<String?> _askProjectName() {
    final controller = TextEditingController(text: _projectName);
    final formKey = GlobalKey<FormState>();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('请输入工程名'),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: '工程名',
              helperText: '仅使用字母、数字和下划线，且以字母或下划线开头',
            ),
            validator: (value) {
              final name = value?.trim() ?? '';
              return RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(name)
                  ? null
                  : '请输入有效的工程名';
            },
            onFieldSubmitted: (_) {
              if (formKey.currentState!.validate()) {
                Navigator.pop(ctx, controller.text.trim());
              }
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.pop(ctx, controller.text.trim());
              }
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirm() async {
    final part = _selected;
    final vivado = _vivado;
    if (part == null || vivado == null) return;
    final projectName = await _askProjectName();
    if (projectName == null || !mounted) return;
    _projectName = projectName;
    Navigator.pop(
      context,
      IpGenOptions(
        vendor: IpVendor.vivado,
        series: _series,
        targetPart: part.name,
        targetFamily: part.family,
        vivadoExecutable: vivado.executable,
        pixBits: _pixBits,
        maxWidth: _maxWidth,
        gstrategy: _gstrategy,
        fold: _gstrategy == 0 ? _fold : 1,
        dspPipe: _dspPipe,
        yuvStandard: _yuvStandard,
        projectName: projectName,
      ),
    );
  }

  IpGenConfig _currentConfig() {
    return IpGenConfig(
      options: IpGenOptions(
        vendor: IpVendor.vivado,
        series: _series,
        targetPart: _selected?.name ?? _preferredPart,
        targetFamily: _selected?.family ?? widget.initial.targetFamily,
        vivadoExecutable: _vivado?.executable ?? '',
        pixBits: _pixBits,
        maxWidth: _maxWidth,
        gstrategy: _gstrategy,
        fold: _fold,
        dspPipe: _dspPipe,
        yuvStandard: _yuvStandard,
        projectName: _projectName,
      ),
      filters: _filters ?? const VivadoPartFilters(),
    );
  }

  Future<void> _saveConfig() async {
    final path = await pickSaveIpConfigPath('prjcfg');
    if (path == null || !mounted) return;
    try {
      final saved = await saveIpGenConfigFile(_currentConfig(), path, 'prjcfg');
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('配置已保存：$saved')));
    } catch (e) {
      if (mounted) await showIpConfigError(context, e);
    }
  }

  Future<void> _importConfig() async {
    final path = await pickOpenIpConfigPath('prjcfg');
    if (path == null || !mounted) return;
    try {
      final config = await readIpGenConfigFile(path, requireVivado: true);
      if (!mounted) return;
      final options = config.options;
      setState(() {
        _series = options.series;
        _pixBits = options.pixBits;
        _maxWidth = options.maxWidth;
        _gstrategy = options.gstrategy;
        _fold = options.fold;
        _dspPipe = options.dspPipe;
        _yuvStandard = options.yuvStandard;
        _projectName = options.projectName;
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
    final vivado = _vivado;
    return AlertDialog(
      title: const Text('导出 Vivado demo_prj'),
      content: vivado == null
          ? const SizedBox(
              width: 520,
              height: 100,
              child: Center(
                child: Text('未检测到 Vivado；请将 Vivado bin 目录加入 PATH 后重试。'),
              ),
            )
          : SizedBox(
              width: 1080,
              height: 640,
              child: Column(
                children: [
                  DropdownButtonFormField<VivadoToolchain>(
                    initialValue: vivado,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Vivado 版本'),
                    items: [
                      for (final t in _toolchains)
                        DropdownMenuItem(
                          value: t,
                          child: Text(
                            t.displayName,
                            overflow: TextOverflow.ellipsis,
                          ),
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
                            key: ValueKey('demo-picker-$_pickerGeneration'),
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
              ),
            ),
      actions: [
        TextButton(onPressed: _importConfig, child: const Text('导入配置')),
        TextButton(onPressed: _saveConfig, child: const Text('保存配置')),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _selected == null ? null : _confirm,
          child: const Text('生成工程'),
        ),
      ],
    );
  }

  Widget _buildIpOptions() {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'IP 配置',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
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
        ],
      ),
    );
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(text, style: const TextStyle(fontSize: 12)),
  );
}
