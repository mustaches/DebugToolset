/// ISP Studio 节点代码标签页：左侧 2/3 为带行号的语法高亮代码区（只读），
/// 右侧 1/3 为变量表（变量名 / 数据类型 / 变量内容，数组以表格展开）。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../providers/isp_studio_state.dart';
import '../../text_editor/utils/syntax_highlighter.dart';
import '../models/isp_node.dart';
import '../pipeline/code_variables.dart';
import '../pipeline/frame3d.dart';
import '../pipeline/node_code.dart';

/// 单个节点的只读代码页面（作为编辑器标签页嵌入主视图）。
class NodeCodePage extends StatelessWidget {
  final String nodeId;

  const NodeCodePage({super.key, required this.nodeId});

  static const _codeStyle = TextStyle(
    fontFamily: 'Consolas',
    fontFamilyFallback: ['Courier New', 'monospace'],
    fontSize: 12,
    height: 1.45,
    color: kVscodePlain,
  );

  @override
  Widget build(BuildContext context) {
    final state = context.watch<IspStudioState>();
    final node = state.graph.nodes[nodeId];
    if (node == null) {
      return const Center(
        child: Text('节点已被删除', style: TextStyle(color: Colors.grey)),
      );
    }
    final type = IspNodeRegistry.byId(node.typeId);
    final code = nodeSourceCode[node.typeId] ?? '// 该节点类型暂无可展示的代码';
    // 与文本对比/补丁视图同一套 VSCode Dark+ 语法高亮（Dart 走 C family 规则）。
    final spans = SyntaxHighlighter.highlightText(
      code.trim(),
      'dart',
      baseStyle: _codeStyle,
    );
    final variables = groupNodeVariables(node.typeId, code);
    // 预览运行后，用采样到的真实数据替换契约说明：
    // Output 用本节点输出采样；Input 的数据缓冲用上游节点的输出采样，
    // 参数类输入直接显示节点参数的实际值（无需运行）。
    final capture = state.nodeOutputCaptures[nodeId];
    final upstreamId = _upstreamNodeId(state, node, type);
    final upstreamCapture =
        upstreamId != null ? state.nodeOutputCaptures[upstreamId] : null;
    final inputs =
        _applyInputs(variables.inputs, node, upstreamCapture, upstreamId);
    final outputs = _applyCapture(variables.outputs, capture, nodeId);
    final isSource = type?.inputs.isEmpty ?? false;
    return Container(
      color: const Color(0xFF1E1E1E),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 页头：节点名 + 类型 id + 只读标识。
          Container(
            height: 28,
            color: const Color(0xFF252525),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            alignment: Alignment.centerLeft,
            child: Row(
              children: [
                Text(
                  '${type?.displayName ?? node.typeId} ($nodeId)',
                  style: const TextStyle(fontSize: 12, color: Colors.white70),
                ),
                const SizedBox(width: 8),
                Text(
                  node.typeId,
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
                const Spacer(),
                const Icon(Icons.lock_outline, size: 12, color: Colors.grey),
                const SizedBox(width: 4),
                const Text('只读',
                    style: TextStyle(fontSize: 11, color: Colors.grey)),
              ],
            ),
          ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: 2, child: _CodeArea(spans: spans)),
                Container(width: 1, color: const Color(0xFF3A3A3A)),
                Expanded(
                  flex: 1,
                  child: _VariablePanel(
                    inputs: inputs,
                    outputs: outputs,
                    inside: variables.inside,
                    inputTitle: isSource
                        ? 'Input（参数值）'
                        : (upstreamCapture != null
                            ? 'Input（运行值）'
                            : 'Input（未运行）'),
                    outputTitle: capture != null
                        ? 'Output（运行值）'
                        : 'Output（未运行）',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 该节点输入端口所连上游节点的 id（未连接为 null）。
  static String? _upstreamNodeId(
      IspStudioState state, IspNode node, IspNodeType? type) {
    if (type == null) return null;
    for (final port in type.inputs) {
      final conn = state.graph.connectionAt(node.id, port.name);
      if (conn != null) return conn.fromNodeId;
    }
    return null;
  }

  /// 数据缓冲变量（Uint8List/Uint16List）→ 运行采样数组，
  /// 元素以 (frame, width, height) 三维坐标标注（只加载当前帧，frame 恒为 0）。
  /// [queryNodeId] 为坐标查询的目标节点（输出=本节点，输入=上游节点）。
  static CodeVariable _runtimeBufferVar(
      CodeVariable v, Map<String, Object?> capture, String queryNodeId) {
    final sample = (capture['sample'] as List).cast<int>();
    final length = capture['length'] as int;
    final format = capture['format'] as String;
    final channels = Frame3D.channelsOf(format);
    final view = Frame3D(
      data: sample,
      width: capture['width'] as int,
      height: capture['height'] as int,
      channels: channels,
    );
    final channelLabels = _channelLabels[format];
    final labels = <String>[];
    for (var i = 0; i < sample.length; i++) {
      final (f, x, y, c) = view.coordinateOf(i);
      labels.add(view.channels == 1
          ? '($f, $x, $y)'
          : '($f, $x, $y) ${channelLabels?[c] ?? 'c$c'}');
    }
    return CodeVariable(
      name: v.name,
      type: v.type,
      value: '运行值（$format，共 $length 项'
          '${sample.length < length ? '，显示前 ${sample.length}' : ''}）',
      items: [for (final x in sample) '$x'],
      itemLabels: labels,
      frameWidth: view.width,
      frameHeight: view.height,
      frameChannels: channels,
      queryNodeId: queryNodeId,
    );
  }

  /// 把预览运行时采样到的输出数据合并进 Output 变量；
  /// 非数据缓冲变量保留契约说明。
  static List<CodeVariable> _applyCapture(
      List<CodeVariable> outputs, Map<String, Object?>? capture,
      String nodeId) {
    if (capture == null) return outputs;
    return [
      for (final v in outputs)
        if (v.type.startsWith('Uint'))
          _runtimeBufferVar(v, capture, nodeId)
        else
          v,
    ];
  }

  /// 解析 Input 变量的实际值：
  /// 数据缓冲取上游节点的运行采样；width/height 取上游帧尺寸；
  /// maxValue 按位深参数推导；其余与节点参数同名的显示参数实际值。
  static List<CodeVariable> _applyInputs(
      List<CodeVariable> inputs,
      IspNode node,
      Map<String, Object?>? upstreamCapture,
      String? upstreamNodeId) {
    /// 输入变量名 → 节点参数键（命名不一致时的别名）。
    const paramAliases = {'path': 'filePath', 'pattern': 'bayerPattern'};
    final params = node.paramValues;
    return [
      for (final v in inputs)
        if (v.type.startsWith('Uint') &&
            upstreamCapture != null &&
            upstreamNodeId != null)
          _runtimeBufferVar(v, upstreamCapture, upstreamNodeId)
        else if ((v.name == 'width' || v.name == 'height') &&
            upstreamCapture != null)
          CodeVariable(
              name: v.name, type: v.type, value: '${upstreamCapture[v.name]}')
        else if (v.name == 'maxValue' && params['bitDepth'] != null)
          CodeVariable(
            name: v.name,
            type: v.type,
            value:
                '${(1 << (int.tryParse('${params['bitDepth']}') ?? 10)) - 1}',
          )
        else if (params.containsKey(paramAliases[v.name] ?? v.name))
          _paramVar(v, params[paramAliases[v.name] ?? v.name])
        else
          v,
    ];
  }

  /// 节点参数的实际值；列表参数（如 CCM 矩阵）展开为数组。
  static CodeVariable _paramVar(CodeVariable v, Object? val) {
    if (val is List) {
      return CodeVariable(
        name: v.name,
        type: v.type,
        value: '参数（${val.length} 项）',
        items: [for (final e in val) '$e'],
      );
    }
    return CodeVariable(name: v.name, type: v.type, value: '$val');
  }

  /// 链格式 → 通道标签（多通道缓冲的坐标后缀）。
  static const _channelLabels = {
    'rgb': ['R', 'G', 'B'],
    'yuv': ['Y', 'U', 'V'],
    'hsl': ['H', 'S', 'L'],
    'rgba': ['R', 'G', 'B', 'A'],
  };
}

/// 左侧代码区：行号列 + 语法高亮代码，双向滚动。
class _CodeArea extends StatefulWidget {
  final List<TextSpan> spans;

  const _CodeArea({required this.spans});

  @override
  State<_CodeArea> createState() => _CodeAreaState();
}

class _CodeAreaState extends State<_CodeArea> {
  /// 显式垂直滚动控制器（Scrollbar 在桌面/测试环境无 primary 控制器时需要）。
  final _vController = ScrollController();

  @override
  void dispose() {
    _vController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 行数从 span 文本里数（高亮按行产出，'\n' 分隔）。
    final lineCount = widget.spans
            .fold<int>(0, (n, s) => n + '\n'.allMatches(s.text ?? '').length) +
        1;
    final gutterWidth = lineCount.toString().length * 7.5 + 14;
    const lineNoStyle = TextStyle(
      fontFamily: 'Consolas',
      fontFamilyFallback: ['Courier New', 'monospace'],
      fontSize: 12,
      height: 1.45,
      color: Color(0xFF858585),
    );
    return Scrollbar(
      controller: _vController,
      thumbVisibility: true,
      child: SingleChildScrollView(
        controller: _vController,
        padding: const EdgeInsets.all(12),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: gutterWidth,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (var i = 1; i <= lineCount; i++)
                      Text('$i', style: lineNoStyle),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              SelectableText.rich(
                TextSpan(children: widget.spans),
                style: NodeCodePage._codeStyle,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 右侧变量表（调试器视角）：Input（传入节点）→ Output（节点产出）→
/// Inside（内部变量）三节；每节内为 变量名 / 数据类型 / 变量内容，
/// 数组变量展开为坐标-内容表格；数值内容支持 DEC/HEX 切换。
class _VariablePanel extends StatefulWidget {
  final List<CodeVariable> inputs;
  final List<CodeVariable> outputs;
  final List<CodeVariable> inside;

  /// Input / Output 分节标题（含运行状态提示）。
  final String inputTitle;
  final String outputTitle;

  const _VariablePanel({
    required this.inputs,
    required this.outputs,
    required this.inside,
    required this.inputTitle,
    required this.outputTitle,
  });

  @override
  State<_VariablePanel> createState() => _VariablePanelState();
}

class _VariablePanelState extends State<_VariablePanel> {
  /// 数值内容是否按十六进制显示。
  bool _hex = false;

  static const _headerStyle = TextStyle(fontSize: 11, color: Colors.grey);
  static const _nameStyle = TextStyle(
      fontSize: 11, color: kVscodeVariable, fontFamily: 'Consolas');
  static const _typeStyle = TextStyle(
      fontSize: 11, color: kVscodeType, fontFamily: 'Consolas');
  static const _valueStyle = TextStyle(
      fontSize: 11, color: kVscodePlain, fontFamily: 'Consolas');

  bool get _isEmpty =>
      widget.inputs.isEmpty &&
      widget.outputs.isEmpty &&
      widget.inside.isEmpty;

  /// 按当前进制格式化数值内容；非纯数字（表达式等）原样返回。
  String _formatValue(String content) {
    if (!_hex) return content;
    final v = int.tryParse(content);
    if (v == null || v < 0) return content;
    return '0x${v.toRadixString(16).toUpperCase().padLeft(v > 0xFF ? 4 : 2, '0')}';
  }

  /// DEC/HEX 迷你切换按钮。
  Widget _radixButton(String label, bool active) {
    return InkWell(
      onTap: () => setState(() => _hex = label == 'HEX'),
      child: Container(
        margin: const EdgeInsets.only(left: 2),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: active
              ? Theme.of(context).colorScheme.primary
              : Colors.transparent,
          borderRadius: BorderRadius.circular(3),
          border: Border.all(
              color: active ? Colors.transparent : Colors.grey.shade700),
        ),
        child: Text(
          label,
          style: TextStyle(
              fontSize: 10, color: active ? Colors.white : Colors.grey),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF202020),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 表头 + DEC/HEX 切换。
          Container(
            height: 24,
            color: const Color(0xFF2A2A2A),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            alignment: Alignment.centerLeft,
            child: Row(
              children: [
                const Expanded(
                    flex: 3, child: Text('变量名', style: _headerStyle)),
                const Expanded(
                    flex: 2, child: Text('数据类型', style: _headerStyle)),
                const Expanded(
                    flex: 3, child: Text('变量内容', style: _headerStyle)),
                _radixButton('DEC', !_hex),
                _radixButton('HEX', _hex),
              ],
            ),
          ),
          Expanded(
            child: _isEmpty
                ? const Center(
                    child: Text('未解析到变量',
                        style:
                            TextStyle(fontSize: 11, color: Colors.grey)),
                  )
                : ListView(
                    children: [
                      _buildSection(widget.inputTitle, widget.inputs,
                          const Color(0xFF569CD6)),
                      _buildSection(widget.outputTitle, widget.outputs,
                          const Color(0xFFC586C0)),
                      _buildSection('Inside', widget.inside,
                          const Color(0xFF858585)),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  /// 一节：分组标题条 + 变量行。
  Widget _buildSection(
      String title, List<CodeVariable> vars, Color accent) {
    if (vars.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 20,
          color: const Color(0xFF252525),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          alignment: Alignment.centerLeft,
          child: Row(
            children: [
              Container(
                width: 6,
                height: 6,
                decoration:
                    BoxDecoration(color: accent, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Text(
                title,
                style: TextStyle(
                    fontSize: 11,
                    color: accent,
                    fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
        for (final v in vars) _buildVariable(v),
      ],
    );
  }

  Widget _buildVariable(CodeVariable v) {
    final items = v.items;
    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFF2E2E2E))),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                flex: 3,
                child: Text(v.name,
                    style: _nameStyle, overflow: TextOverflow.ellipsis),
              ),
              Expanded(
                flex: 2,
                child: Text(v.type,
                    style: _typeStyle, overflow: TextOverflow.ellipsis),
              ),
              Expanded(
                flex: 3,
                child: Tooltip(
                  message: _formatValue(v.value),
                  child: Text(
                    // 字面量数组显示聚合形态；运行采样的 value 已是描述文本。
                    items != null && v.value.startsWith('[')
                        ? '数组（${items.length} 项）'
                        : _formatValue(v.value),
                    style: _valueStyle,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
          if (items != null) _buildArrayTable(v),
        ],
      ),
    );
  }

  /// 数组序列：坐标（或数字序号）+ 内容；运行缓冲附 (帧, 宽, 高) 查询栏。
  Widget _buildArrayTable(CodeVariable v) {
    final items = v.items!;
    final labels = v.itemLabels;
    const border = BorderSide(color: Color(0xFF3A3A3A));
    TableRow row(String index, String content,
        {Color? bg, TextStyle style = _valueStyle}) {
      return TableRow(
        decoration: BoxDecoration(color: bg),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Text(index, style: style, textAlign: TextAlign.right),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Tooltip(
              message: _formatValue(content),
              child: Text(_formatValue(content),
                  style: style, overflow: TextOverflow.ellipsis),
            ),
          ),
        ],
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (v.queryNodeId != null &&
              v.frameWidth != null &&
              v.frameHeight != null &&
              v.frameChannels != null)
            _CoordinateQueryBar(
              nodeId: v.queryNodeId!,
              width: v.frameWidth!,
              height: v.frameHeight!,
              channels: v.frameChannels!,
              format: _formatValue,
            ),
          Table(
            columnWidths: {0: FixedColumnWidth(labels != null ? 110 : 36)},
            border: const TableBorder(
              top: border,
              bottom: border,
              left: border,
              right: border,
              horizontalInside: border,
              verticalInside: border,
            ),
            children: [
              row(labels != null ? '(帧, 宽, 高)' : '序号', '内容',
                  bg: const Color(0xFF2A2A2A), style: _headerStyle),
              for (final (i, item) in items.indexed)
                row(labels != null ? labels[i] : '$i', item),
            ],
          ),
        ],
      ),
    );
  }
}

/// 运行缓冲的坐标查询栏：输入 (帧, 宽, 高[, 通道]) 后按需重跑流水线，
/// 查看采样窗口之外任意位置的元素值。
class _CoordinateQueryBar extends StatefulWidget {
  /// 查询目标节点（输出缓冲=本节点，输入缓冲=上游节点）。
  final String nodeId;

  /// 帧尺寸与通道数（坐标取值范围；帧当前恒为第 0 帧）。
  final int width;
  final int height;
  final int channels;

  /// 结果值的进制格式化（跟随变量表的 DEC/HEX 切换）。
  final String Function(String) format;

  const _CoordinateQueryBar({
    required this.nodeId,
    required this.width,
    required this.height,
    required this.channels,
    required this.format,
  });

  @override
  State<_CoordinateQueryBar> createState() => _CoordinateQueryBarState();
}

class _CoordinateQueryBarState extends State<_CoordinateQueryBar> {
  final _frame = TextEditingController(text: '0');
  final _x = TextEditingController();
  final _y = TextEditingController();
  final _channel = TextEditingController(text: '0');

  bool _busy = false;
  String? _result;
  String? _error;

  @override
  void dispose() {
    _frame.dispose();
    _x.dispose();
    _y.dispose();
    _channel.dispose();
    super.dispose();
  }

  Future<void> _query() async {
    final f = int.tryParse(_frame.text.trim());
    final x = int.tryParse(_x.text.trim());
    final y = int.tryParse(_y.text.trim());
    final c = int.tryParse(_channel.text.trim());
    String? error;
    if (f == null || x == null || y == null ||
        (widget.channels > 1 && c == null)) {
      error = '请输入整数坐标';
    } else if (f != 0) {
      error = '当前仅加载第 0 帧';
    } else if (x < 0 || x >= widget.width) {
      error = '宽应在 0..${widget.width - 1}';
    } else if (y < 0 || y >= widget.height) {
      error = '高应在 0..${widget.height - 1}';
    } else if ((c ?? 0) < 0 || (c ?? 0) >= widget.channels) {
      error = '通道应在 0..${widget.channels - 1}';
    }
    if (error != null) {
      setState(() {
        _error = error;
        _result = null;
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final v = await context
          .read<IspStudioState>()
          .queryNodeOutputAt(widget.nodeId, x!, y!, c ?? 0);
      if (!mounted) return;
      setState(() {
        final coord = widget.channels > 1 ? '(0, $x, $y) c${c ?? 0}' : '(0, $x, $y)';
        _result = '$coord = ${widget.format('$v')}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Bad state: ', '');
        _result = null;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 单个坐标输入框（标签 + 窄文本框）。
  Widget _field(String label, TextEditingController controller,
      {double width = 48}) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: _VariablePanelState._headerStyle),
          const SizedBox(width: 2),
          SizedBox(
            width: width,
            height: 22,
            child: TextField(
              controller: controller,
              style: _VariablePanelState._valueStyle,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                isDense: true,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _query(),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _field('帧', _frame, width: 32),
              _field('宽', _x),
              _field('高', _y),
              if (widget.channels > 1) _field('通道', _channel, width: 32),
              InkWell(
                onTap: _busy ? null : _query,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary,
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    _busy ? '查询中…' : '查询',
                    style: const TextStyle(fontSize: 10, color: Colors.white),
                  ),
                ),
              ),
            ],
          ),
          if (_result != null || _error != null)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                _result ?? _error!,
                style: TextStyle(
                  fontSize: 11,
                  fontFamily: 'Consolas',
                  color: _error != null
                      ? const Color(0xFFF48771)
                      : const Color(0xFFD4D4D4),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
