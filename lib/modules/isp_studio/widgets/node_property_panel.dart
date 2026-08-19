/// ISP Studio 右侧属性面板：显示并编辑选中节点的参数。
library;

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../providers/isp_studio_state.dart';
import '../models/isp_node.dart';

/// 右侧固定宽度属性面板。
class NodePropertyPanel extends StatelessWidget {
  const NodePropertyPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<IspStudioState>();
    final selectedId = state.selectedNodeId;
    final node = selectedId == null ? null : state.graph.nodes[selectedId];
    final type = node == null ? null : IspNodeRegistry.byId(node.typeId);

    return Container(
      width: 260,
      decoration: BoxDecoration(
        color: const Color(0xFF252525),
        border: Border(left: BorderSide(color: Colors.grey.shade800)),
      ),
      child: node == null || type == null
          ? const Center(
              child: Text('点击节点查看参数',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
            )
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                Text(type.displayName,
                    style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: Colors.white)),
                Text(type.typeId,
                    style:
                        const TextStyle(fontSize: 11, color: Colors.grey)),
                Divider(height: 24, color: Colors.grey.shade800),
                for (final spec in type.params)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _editorFor(context, state, node, spec),
                  ),
                if (node.typeId == 'bayer_source' &&
                    state.totalFrames != null)
                  Text('帧数: ${state.totalFrames}',
                      style: const TextStyle(
                          fontSize: 12, color: Colors.grey)),
              ],
            ),
    );
  }

  Widget _editorFor(BuildContext context, IspStudioState state, IspNode node,
      IspParamSpec spec) {
    final value = node.paramValues[spec.key];
    switch (spec.type) {
      case IspParamType.intNumber:
      case IspParamType.doubleNumber:
        return _labeled(
          spec.label,
          _NumberField(
            key: ValueKey('${node.id}:${spec.key}'),
            value: value,
            isInt: spec.type == IspParamType.intNumber,
            min: spec.min,
            max: spec.max,
            onCommit: (v) => state.setParam(node.id, spec.key, v),
          ),
        );
      case IspParamType.boolean:
        return Row(
          children: [
            Expanded(
                child: Text(spec.label, style: _labelStyle)),
            Switch(
              value: value == true,
              onChanged: (v) => state.setParam(node.id, spec.key, v),
            ),
          ],
        );
      case IspParamType.choice:
        final current = value?.toString();
        final options = spec.options ?? const <String>[];
        return Row(
          children: [
            Expanded(
                child: Text(spec.label, style: _labelStyle)),
            DropdownButton<String>(
              value: options.contains(current) ? current : null,
              isDense: true,
              items: [
                for (final o in options)
                  DropdownMenuItem(
                      value: o,
                      child: Text(o, style: const TextStyle(fontSize: 12))),
              ],
              onChanged: (v) {
                if (v != null) state.setParam(node.id, spec.key, v);
              },
            ),
          ],
        );
      case IspParamType.text:
        return _labeled(
          spec.label,
          _TextField(
            key: ValueKey('${node.id}:${spec.key}'),
            value: value,
            onCommit: (v) => state.setParam(node.id, spec.key, v),
          ),
        );
      case IspParamType.filePath:
        return _labeled(
          spec.label,
          Row(
            children: [
              Expanded(
                child: _TextField(
                  key: ValueKey('${node.id}:${spec.key}'),
                  value: value,
                  onCommit: (v) => state.setParam(node.id, spec.key, v),
                ),
              ),
              TextButton(
                onPressed: () => _browsePath(state, node, spec),
                child:
                    const Text('浏览…', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        );
      case IspParamType.matrix3:
        return _matrix3Editor(state, node, spec);
    }
  }

  static const _labelStyle = TextStyle(fontSize: 12, color: Colors.white70);

  Widget _labeled(String label, Widget field) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: _labelStyle),
        const SizedBox(height: 4),
        field,
      ],
    );
  }

  /// Bayer RGGB（cis_bayer_rggb）节点浏览 RAW 文件的默认目录
  /// （根目录 IspFlow/BayerRGGB，不存在则创建）。
  /// 注意：必须使用平台分隔符拼接。Windows 上混用 '/' 会导致
  /// file_selector 内部 SHCreateItemFromParsingName 失败（E_INVALIDARG），
  /// 文件对话框静默回退到“上次使用的目录”。
  Future<String> _bayerRawDir() async {
    final sep = Platform.pathSeparator;
    final dir = Directory(
        '${Directory.current.path}${sep}IspFlow${sep}BayerRGGB');
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir.path;
  }

  /// 按 (节点类型, 参数 key) 选择文件/目录/保存位置对话框。
  Future<void> _browsePath(
      IspStudioState state, IspNode node, IspParamSpec spec) async {
    String? path;
    if (node.typeId == 'image_output' && spec.key == 'directory') {
      path = await getDirectoryPath();
    } else if (node.typeId == 'video_output' && spec.key == 'filePath') {
      final loc = await getSaveLocation(suggestedName: 'output.mp4');
      path = loc?.path;
    } else if (node.typeId == 'cis_bayer_rggb' && spec.key == 'filePath') {
      final file = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(label: 'RAW/DNG 图像', extensions: ['raw', 'dng']),
        ],
        initialDirectory: await _bayerRawDir(),
      );
      path = file?.path;
    } else if (node.typeId == 'image_source' && spec.key == 'filePath') {
      final file = await openFile(acceptedTypeGroups: [
        const XTypeGroup(
            label: '图片', extensions: ['bmp', 'jpg', 'jpeg', 'png', 'gif']),
      ]);
      path = file?.path;
    } else if (node.typeId == 'video_source' && spec.key == 'filePath') {
      final file = await openFile(acceptedTypeGroups: [
        const XTypeGroup(
            label: '视频',
            extensions: ['mp4', 'mkv', 'avi', 'mov', 'ts', 'flv', 'wmv']),
      ]);
      path = file?.path;
    } else {
      final file = await openFile();
      path = file?.path;
    }
    if (path != null) {
      state.setParam(node.id, spec.key, path);
    }
  }

  Widget _matrix3Editor(
      IspStudioState state, IspNode node, IspParamSpec spec) {
    final raw = node.paramValues[spec.key];
    final values = raw is List
        ? raw.map((e) => (e as num).toDouble()).toList()
        : List<double>.filled(9, 0);
    while (values.length < 9) {
      values.add(0);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(spec.label, style: _labelStyle),
        const SizedBox(height: 4),
        for (var r = 0; r < 3; r++)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                for (var c = 0; c < 3; c++) ...[
                  if (c > 0) const SizedBox(width: 4),
                  Expanded(
                    child: _NumberField(
                      key: ValueKey('${node.id}:${spec.key}:$r$c'),
                      value: values[r * 3 + c],
                      isInt: false,
                      onCommit: (v) {
                        final copy = List<double>.from(values);
                        copy[r * 3 + c] = v.toDouble();
                        state.setParam(node.id, spec.key, copy);
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

/// 数字输入框：自带 controller，编辑完成或失焦时提交（含 min/max 钳制）。
class _NumberField extends StatefulWidget {
  final Object? value;
  final bool isInt;
  final double? min;
  final double? max;
  final ValueChanged<num> onCommit;

  const _NumberField({
    super.key,
    required this.value,
    required this.isInt,
    this.min,
    this.max,
    required this.onCommit,
  });

  @override
  State<_NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<_NumberField> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  String _format(Object? v) => v?.toString() ?? '';

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: _format(widget.value));
    _focusNode = FocusNode()
      ..addListener(() {
        if (!_focusNode.hasFocus) _commit();
      });
  }

  @override
  void didUpdateWidget(_NumberField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_focusNode.hasFocus &&
        _format(widget.value) != _format(oldWidget.value)) {
      _controller.text = _format(widget.value);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _commit() {
    final text = _controller.text.trim();
    num? parsed =
        widget.isInt ? int.tryParse(text) : double.tryParse(text);
    if (parsed == null) {
      _controller.text = _format(widget.value); // 非法输入回退
      return;
    }
    var v = parsed;
    if (widget.min != null && v < widget.min!) v = widget.min!;
    if (widget.max != null && v > widget.max!) v = widget.max!;
    if (widget.isInt) v = v.toInt();
    widget.onCommit(v);
    if (_controller.text != v.toString()) _controller.text = v.toString();
  }

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: _controller,
      focusNode: _focusNode,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      style: const TextStyle(fontSize: 12),
      decoration: const InputDecoration(
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        border: OutlineInputBorder(),
      ),
      onEditingComplete: _commit,
    );
  }
}

/// 文本输入框：编辑完成或失焦时提交。
class _TextField extends StatefulWidget {
  final Object? value;
  final ValueChanged<String> onCommit;

  const _TextField({super.key, required this.value, required this.onCommit});

  @override
  State<_TextField> createState() => _TextFieldState();
}

class _TextFieldState extends State<_TextField> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value?.toString() ?? '');
    _focusNode = FocusNode()
      ..addListener(() {
        if (!_focusNode.hasFocus) _commit();
      });
  }

  @override
  void didUpdateWidget(_TextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    final text = widget.value?.toString() ?? '';
    if (!_focusNode.hasFocus && _controller.text != text) {
      _controller.text = text;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _commit() {
    if (_controller.text != (widget.value?.toString() ?? '')) {
      widget.onCommit(_controller.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: _controller,
      focusNode: _focusNode,
      style: const TextStyle(fontSize: 12),
      decoration: const InputDecoration(
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        border: OutlineInputBorder(),
      ),
      onEditingComplete: _commit,
    );
  }
}
