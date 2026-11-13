/// ISP Studio 编组 Verilog IP 标签页。
///
/// 右键编组菜单「生成Verilog IP」打开，布局与 C 代码页一致：顶部工具栏
/// （白色图标按钮在左，编组名 + 厂商 + 只读标识在右），左侧为 IP 包文件
/// 清单（核心/顶层/封装/仿真/脚本/文档六组，190px），右侧为带行号的
/// Verilog 语法高亮代码区（只读）；工具栏「一键仿真」在代码区下方切出
/// 1/4 高度终端面板流式跑 iverilog（与编译终端同一风格）。
library;

import 'dart:async';
import 'dart:isolate';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../providers/isp_studio_state.dart';
import '../../text_editor/utils/syntax_highlighter.dart';
import '../codegen/group_ip_export.dart';
import '../codegen/ip_gen_plan.dart';
import '../codegen/ip_stimulus.dart';
import '../codegen/ip_target.dart';
import '../codegen/iverilog_sim.dart';
import '../codegen/sim_wave_store.dart';
import '../codegen/vivado_runner.dart';
import '../models/demo_prj_session.dart';
import '../models/isp_graph.dart';
import 'code_browser.dart';
import 'demo_prj_dialog.dart';
import 'ip_gen_dialog.dart';
import 'ip_stimulus_dialog.dart';
import 'markdown_view.dart';
import 'tab_toolbar.dart';
import 'verilog_print_preview.dart';

enum _IpConsoleTask { simulation, demoProject }

Map<String, String> _buildIpFilesInIsolate(Map<String, Object?> request) {
  final graph = IspGraph.fromJson(
    (request['graph'] as Map).cast<String, Object?>(),
  );
  final group = graph.groups.firstWhere((g) => g.id == request['groupId']);
  final send = request['sendPort'] as SendPort;
  return buildGroupIpFiles(
    graph,
    group,
    request['options'] as IpGenOptions,
    stimulus: request['stimulus'] as IpSimStimulus,
    onProgress: (stage, progress) =>
        send.send({'stage': stage, 'progress': progress}),
  );
}

void _ipIsolateEntry(Map<String, Object?> request) {
  final send = request['sendPort'] as SendPort;
  try {
    send.send({'files': _buildIpFilesInIsolate(request)});
  } catch (error) {
    send.send('$error');
  }
}

Future<Map<String, String>> _generateIpFilesOffstage(
  Map<String, Object?> request, {
  IpBuildProgress? onProgress,
}) async {
  final port = ReceivePort();
  request['sendPort'] = port.sendPort;
  await Isolate.spawn(_ipIsolateEntry, request);
  try {
    await for (final response in port) {
      if (response is String) throw StateError(response);
      final message = response as Map;
      final files = message['files'];
      if (files is Map) return files.cast<String, String>();
      onProgress?.call(
        message['stage'] as String,
        (message['progress'] as num).toDouble(),
      );
    }
    throw StateError('后台生成意外中断');
  } finally {
    port.close();
  }
}

void _ipHighlightEntry(Map<String, Object?> request) {
  final send = request['sendPort'] as SendPort;
  try {
    send.send(
      SyntaxHighlighter.highlightText(
        request['text'] as String,
        'v',
        baseStyle: kCodeBrowserStyle,
      ),
    );
  } catch (error) {
    send.send('$error');
  }
}

Future<List<TextSpan>> _highlightIpCodeOffstage(String text) async {
  final port = ReceivePort();
  await Isolate.spawn(_ipHighlightEntry, {
    'sendPort': port.sendPort,
    'text': text,
  });
  try {
    final response = await port.first;
    if (response is String) throw StateError(response);
    return (response as List).cast<TextSpan>();
  } finally {
    port.close();
  }
}

/// word 在 text 中是否按 Verilog 标识符词边界出现（自动选文件用）。
bool containsVerilogWord(String text, String word) {
  if (word.isEmpty) return false;
  var i = 0;
  while (i < text.length) {
    final idx = text.indexOf(word, i);
    if (idx < 0) return false;
    final before = idx > 0 ? text.codeUnitAt(idx - 1) : 0;
    final end = idx + word.length;
    final after = end < text.length ? text.codeUnitAt(end) : 0;
    if (!_isVerilogIdChar(before) && !_isVerilogIdChar(after)) return true;
    i = end;
  }
  return false;
}

bool _isVerilogIdChar(int c) =>
    (c >= 0x30 && c <= 0x39) ||
    (c >= 0x41 && c <= 0x5A) ||
    (c >= 0x61 && c <= 0x7A) ||
    c == 0x5F ||
    c == 0x24;

/// 在语法高亮 spans 中把 [word]（按 Verilog 标识符词边界匹配）的所有
/// 出现改涂高亮底色（琥珀底黑字，保留原字族字号）——SimWave「跳转到
/// Verilog」的信号名高亮（所有用到该信号的 .v 文件共用）。
List<TextSpan> highlightWordOccurrences(List<TextSpan> spans, String word) {
  if (word.isEmpty) return spans;
  return [for (final s in spans) _highlightInSpan(s, word)];
}

TextSpan _highlightInSpan(TextSpan span, String word) {
  final children = span.children;
  if (children != null && children.isNotEmpty) {
    return TextSpan(
      style: span.style,
      children: [
        for (final c in children) c is TextSpan ? _highlightInSpan(c, word) : c,
      ],
    );
  }
  final text = span.text ?? '';
  if (!text.contains(word)) return span;
  final hi = (span.style ?? const TextStyle()).copyWith(
    backgroundColor: const Color(0xFFFFB300),
    color: Colors.black,
  );
  final parts = <TextSpan>[];
  var i = 0;
  while (i < text.length) {
    final idx = text.indexOf(word, i);
    if (idx < 0) {
      parts.add(TextSpan(text: text.substring(i), style: span.style));
      break;
    }
    final before = idx > 0 ? text.codeUnitAt(idx - 1) : 0;
    final end = idx + word.length;
    final after = end < text.length ? text.codeUnitAt(end) : 0;
    if (_isVerilogIdChar(before) || _isVerilogIdChar(after)) {
      // 非词边界（如 in_data2 中的 in_data）：跳过该处继续找下一个。
      parts.add(TextSpan(text: text.substring(i, end), style: span.style));
      i = end;
      continue;
    }
    if (idx > i) {
      parts.add(TextSpan(text: text.substring(i, idx), style: span.style));
    }
    parts.add(TextSpan(text: word, style: hi));
    i = end;
  }
  return parts.length == 1 ? parts[0] : TextSpan(children: parts);
}

/// IP 标签页的生成选项（由视图层解析 `gip:<id>@<vendor>` key + 会话缓存
/// 传入；页面内可经「生成选项」重开对话框换厂商/参数）。
class IpGeneratorPage extends StatefulWidget {
  final String groupId;

  /// 生成选项（首次打开时的默认；重开对话框后以新选项重建文件）。
  final IpGenOptions options;

  /// 文件生成函数（测试注入用）；默认按当前图 + 选项走 buildGroupIpFiles。
  final Future<Map<String, String>> Function()? filesBuilder;

  const IpGeneratorPage({
    super.key,
    required this.groupId,
    required this.options,
    this.filesBuilder,
  });

  @override
  State<IpGeneratorPage> createState() => _IpGeneratorPageState();
}

class _IpGeneratorPageState extends State<IpGeneratorPage> {
  late IpGenOptions _options;

  /// 一键仿真激励参数（工具栏「仿真激励参数」对话框指定；会话缓存
  /// [sessionIpSimStimulus] 回填，默认与历史固定行为一致）。
  late IpSimStimulus _stimulus;
  String _selectedFile = '';
  Map<String, String>? _files;
  String? _error;
  int _loadGeneration = 0;
  String _progressStage = '准备生成 Verilog IP';
  List<TextSpan>? _codeSpans;
  int _codeGeneration = 0;

  /// 仿真与 demo 生成共用终端输出（流式追加）。
  final StringBuffer _simLog = StringBuffer();
  bool _simRunning = false;
  bool _demoRunning = false;
  IpSimResult? _simResult;
  VivadoDemoResult? _demoResult;
  DemoPrjSession? _demoSession;
  _IpConsoleTask _consoleTask = _IpConsoleTask.simulation;

  bool get _taskRunning => _simRunning || _demoRunning;

  /// 任务终端面板是否可见（点「一键仿真」或「导出demo_prj」时打开）。
  bool _simPanelVisible = false;

  /// 任务终端输出区的滚动控制器（流式追加时自动滚底）。
  final _simScroll = ScrollController();

  /// 左栏文件清单宽度（分隔条可拖动调整，钳位 120~600px）。
  double _leftWidth = 190;

  @override
  void initState() {
    super.initState();
    _options = widget.options;
    _stimulus = sessionIpSimStimulus[widget.groupId] ?? const IpSimStimulus();
    _reload();
  }

  @override
  void dispose() {
    _simScroll.dispose();
    super.dispose();
  }

  Future<Map<String, String>> _buildFiles() {
    final state = context.read<IspStudioState>();
    if (!state.graph.groups.any((g) => g.id == widget.groupId)) {
      throw StateError('编组不存在：${widget.groupId}');
    }
    final graph = state.graph.toJson();
    final options = _options;
    final stimulus = _stimulus;
    final groupId = widget.groupId;
    return _generateIpFilesOffstage(
      {
        'graph': graph,
        'groupId': groupId,
        'options': options,
        'stimulus': stimulus,
      },
      onProgress: (stage, _) {
        if (!mounted) return;
        setState(() => _progressStage = stage);
      },
    );
  }

  Future<void> _reload() async {
    final generation = ++_loadGeneration;
    _progressStage = '准备生成 Verilog IP';
    if (mounted) setState(() {});
    try {
      final files = await (widget.filesBuilder ?? _buildFiles)();
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _files = files;
        _error = null;
        _codeSpans = null;
        _codeGeneration++;
        if (!files.containsKey(_selectedFile)) {
          _selectedFile = files.keys.isNotEmpty ? files.keys.first : '';
        }
      });
      unawaited(_prepareCode());
    } catch (e) {
      // 生成失败（如编组校验不通过）必须落到错误页，否则界面无限转圈
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _files = null;
        _error = '生成 IP 包失败：$e';
      });
    }
  }

  void _appendConsole(String chunk) {
    if (_consoleTask == _IpConsoleTask.demoProject) {
      _demoSession?.append(chunk);
    }
    if (!mounted) return;
    setState(() => _simLog.write(chunk));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_simScroll.hasClients) {
        _simScroll.jumpTo(_simScroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _runSim() async {
    // 一键仿真先弹激励参数对话框（确认按钮「开始仿真」）：用户指定/确认
    // 激励参数后再跑；取消则整个中止（不打开终端面板）。
    final s = await showIpStimulusDialog(
      context,
      initial: _stimulus,
      confirmText: '开始仿真',
    );
    if (s == null || !mounted) return;
    if (s != _stimulus) {
      sessionIpSimStimulus[widget.groupId] = s;
      setState(() {
        _stimulus = s;
        _files = null;
      });
    }
    if (_files == null) await _reload();
    if (_files == null) return;
    setState(() {
      _simRunning = true;
      _simPanelVisible = true;
      _simLog.clear();
      _simResult = null;
      _consoleTask = _IpConsoleTask.simulation;
    });
    try {
      // 波形由内嵌「仿真波形」标签页展示（vcdData 登记 SimWaveStore）。
      final r = await runIpSimulation(_files!, onOutput: _appendConsole);
      if (!mounted) return;
      setState(() => _simResult = r);
      // 登记波形（附来源编组/厂商，Signal 右键「跳转到Verilog」用）
      // 并打开/激活内嵌波形标签页。
      final vcd = r.vcdData;
      if (r.success && vcd != null) {
        SimWaveStore.instance.registerWave(
          vcd,
          groupId: widget.groupId,
          vendor: _options.vendor,
        );
        context.read<IspStudioState>().openWaveTab();
      }
    } catch (e) {
      // 异常也要解锁按钮并在终端面板可见，否则界面表现为卡死
      if (!mounted) return;
      setState(() => _simLog.write('仿真异常：$e\n'));
    } finally {
      if (mounted) setState(() => _simRunning = false);
    }
  }

  Future<void> _printSelectedCode() async {
    final fileName = _selectedFile;
    final content = _files?[fileName];
    if (fileName.isEmpty || content == null) return;
    await showVerilogPrintPreview(context, fileName, content);
  }

  Future<void> _exportPackage() async {
    if (_files == null) await _reload();
    if (_files == null) return;
    final dir = await getDirectoryPath(confirmButtonText: '导出');
    if (dir == null) return;
    try {
      await exportGroupIpPackage(
        _files!,
        dir,
        vivadoExecutable: _options.vivadoExecutable,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('导出失败：$e')));
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('IP 包已导出到 $dir')));
  }

  Future<void> _exportDemoPrj() async {
    final state = context.read<IspStudioState>();
    final group = state.graph.groups.firstWhere((g) => g.id == widget.groupId);
    final options = await showDemoPrjDialog(
      context,
      initial: _options,
      hasYuvMatrix: groupHasYuvMatrix(state.graph, group),
      defaultProjectName: defaultGroupDemoProjectName(
        state.graph,
        group,
        flowName: state.graphName,
      ),
    );
    if (options == null || !mounted) return;
    final dir = await getDirectoryPath(
      confirmButtonText: '生成 ${options.projectName}',
    );
    if (dir == null || !mounted) return;
    final exportDir = demoPrjExportDirectory(dir, options.projectName);
    sessionIpGenOptions[widget.groupId] = options;
    _demoSession = state.openDemoPrjLogTab(widget.groupId, options.projectName);
    setState(() {
      _options = options;
      _demoRunning = true;
      _simPanelVisible = false;
      _simLog.clear();
      _demoResult = null;
      _consoleTask = _IpConsoleTask.demoProject;
    });
    _appendConsole('正在生成 IP 文件与工程 ${options.projectName}…\n');
    try {
      final files = await _generateIpFilesOffstage({
        'graph': state.graph.toJson(),
        'groupId': widget.groupId,
        'options': options,
        'stimulus': _stimulus,
      });
      _appendConsole('正在导出 IP 包到 $exportDir …\n');
      await exportGroupIpPackage(
        files,
        exportDir,
        vivadoExecutable: options.vivadoExecutable,
      );
      final result = await runVivadoDemoProject(
        exportDir,
        onOutput: _appendConsole,
        vivado: options.vivadoExecutable.isEmpty
            ? null
            : VivadoToolchain(options.vivadoExecutable),
        projectName: options.projectName,
      );
      _demoSession?.complete(result);
      if (!mounted) return;
      setState(() => _demoResult = result);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.success
                ? '${options.projectName} 已生成：${result.projectPath}'
                : '${options.projectName} 生成失败，请查看终端日志',
          ),
        ),
      );
    } catch (e) {
      _appendConsole('${options.projectName} 生成异常：$e\n');
      _demoSession?.fail(e);
    } finally {
      try {
        await saveDemoPrjExportLog(
          exportDir,
          _demoSession?.log.toString() ?? '',
        );
      } catch (e) {
        _appendConsole('导出日志保存失败：$e\n');
      }
      if (mounted) setState(() => _demoRunning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<IspStudioState>();
    final group = state.graph.groups.firstWhere((g) => g.id == widget.groupId);
    // 布局与 C 代码页一致：工具栏 + 左栏文件清单（190px）+ 分隔线 +
    // 右侧代码区（点「一键仿真」后代码区下方切出 1/4 高度终端面板）。
    // 生成失败时整页居中显示错误（同编组 C 代码页校验失败形态）。
    return Container(
      color: const Color(0xFF1E1E1E),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildToolbar(group, state),
          Expanded(
            child: _error != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFFCF6679),
                        ),
                      ),
                    ),
                  )
                : Row(
                    // stretch：子组件吃满全高，代码区内容从顶部开始排
                    //（缺省 center 会让代码区按内容高度收缩并垂直居中）。
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        width: _leftWidth,
                        child: _files == null
                            ? const Center(child: Text('正在生成 IP 文件…'))
                            : CFileList(
                                files: _files!.keys.toList(),
                                selected: _selectedFile,
                                onSelect: _selectCodeFile,
                                groups: _groupsOf(_files!),
                                highlightGroupTitles: true,
                              ),
                      ),
                      // 1px 分隔线（含隐形热区），左右拖动调整左栏宽度。
                      IspVerticalDragDivider(
                        onDelta: (dx) => setState(
                          () => _leftWidth = (_leftWidth + dx).clamp(
                            120.0,
                            600.0,
                          ),
                        ),
                      ),
                      // 右侧：代码区 3/4 + 仿真终端面板 1/4（终端关闭时
                      // 代码区占满，同编译终端口径）。
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(flex: 3, child: _buildCodeArea()),
                            if (_simPanelVisible) ...[
                              Container(
                                height: 1,
                                color: const Color(0xFF3A3A3A),
                              ),
                              Expanded(flex: 1, child: _buildSimPanel()),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  /// 工具栏：与 C 代码页同一风格——左侧白色 codicon 图标按钮
  ///（生成选项 / 导出IP包 / 导出demo_prj / 一键仿真 / 电路图浏览 / 打印，
  /// 悬停 tooltip 显示功能名），右侧为信息区（编组名 + 组 id + 编组·IP +
  /// 厂商徽标 + 资源估算 + 激励摘要 + 只读标识）。
  Widget _buildToolbar(IspNodeGroup group, IspStudioState state) {
    // 资源估算摘要（纯规划计算，随生成选项联动；估算口径见
    // ip_gen_plan.dart IpResourceEstimate）。
    var estSummary = '';
    try {
      estSummary = planGroupIp(
        state.graph,
        group,
        _options,
      ).resources.summary();
    } catch (_) {}
    return ispTabToolbarRow(
      children: [
        ispTabIconButton(
          tooltip: '生成选项',
          onTap: _taskRunning ? null : () => _pickOptions(state),
          icon: ispTabAssetIcon('icons/settings-gear.png'),
        ),
        ispTabIconButton(
          tooltip: '导出IP包',
          onTap: _taskRunning ? null : _exportPackage,
          icon: ispTabAssetIcon('icons/git-stash-pop.png'),
        ),
        ispTabIconButton(
          tooltip: _options.vendor.isVivado
              ? '导出demo_prj（配置目标芯片与 IP 参数）'
              : '导出demo_prj（仅 Vivado 目标可用）',
          onTap: _taskRunning || !_options.vendor.isVivado
              ? null
              : _exportDemoPrj,
          icon: ispTabAssetIcon(
            'icons/build.png',
            color: _taskRunning || !_options.vendor.isVivado
                ? Colors.white38
                : Colors.white,
          ),
        ),
        ispTabIconButton(
          tooltip: '一键仿真（先配置激励参数）',
          onTap: _taskRunning ? null : _runSim,
          icon: ispTabAssetIcon(
            'icons/play.png',
            color: _taskRunning ? Colors.white38 : Colors.white,
          ),
        ),
        // 电路图浏览：yosys 出网表 JSON + 应用自研布局渲染 RTL 电路图（新标签页）。
        ispTabIconButton(
          tooltip: '电路图浏览',
          onTap: () => context.read<IspStudioState>().openSchematicTab(
            widget.groupId,
            _options.vendor,
          ),
          icon: ispTabAssetIcon('icons/circuit-board.png'),
        ),
        ispTabIconButton(
          key: const ValueKey('print-verilog-code'),
          tooltip: '打印当前 Verilog 文件',
          onTap: _files == null ? null : _printSelectedCode,
          icon: const Icon(Icons.print_outlined, size: 20, color: Colors.white),
        ),
        // SimWave「跳转到Verilog」的信号名高亮指示（× 清除）。
        if (state.ipCodeHighlight != null) ...[
          const SizedBox(width: 6),
          Container(
            height: 22,
            padding: const EdgeInsets.only(left: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF3A2E1A),
              borderRadius: BorderRadius.circular(3),
              border: Border.all(color: const Color(0xFFFFB300)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '高亮 ${state.ipCodeHighlight}',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFFFFCC80),
                  ),
                ),
                InkWell(
                  onTap: () => state.setIpCodeHighlight(null),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: Icon(
                      Icons.close,
                      size: 12,
                      color: Color(0xFFFFCC80),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
        const Spacer(),
        Text(
          '${group.name} (${widget.groupId})',
          style: const TextStyle(fontSize: 12, color: Colors.white70),
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(width: 8),
        const Text('编组·IP', style: TextStyle(fontSize: 11, color: Colors.grey)),
        const SizedBox(width: 6),
        // 厂商徽标（生成物随其分叉，与 C 代码页目标 CPU 徽标同位）。
        Text(
          _options.vendor.shortName,
          style: const TextStyle(fontSize: 11, color: Color(0xFF4EC9B0)),
        ),
        const SizedBox(width: 8),
        // 资源估算摘要（粗估，随生成选项联动）。
        if (estSummary.isNotEmpty)
          Flexible(
            child: Text(
              estSummary,
              style: const TextStyle(fontSize: 11, color: Colors.grey),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        const SizedBox(width: 8),
        // 当前激励参数摘要（非默认时亮黄色提示引起注意；默认参数灰显）。
        Flexible(
          child: Text(
            '激励 ${_stimulus.summary()}',
            style: TextStyle(
              fontSize: 11,
              color: _stimulus.isDefault
                  ? Colors.grey
                  : const Color(0xFFFFFF00),
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 8),
        ispTabToolbarReadOnly(),
      ],
    );
  }

  Future<void> _pickOptions(IspStudioState state) async {
    final group = state.graph.groups.firstWhere(
      (g) => g.id == widget.groupId,
      orElse: () => IspNodeGroup(widget.groupId, <String>{}),
    );
    final o = await showIpGenDialog(
      context,
      initial: _options,
      hasYuvMatrix: groupHasYuvMatrix(state.graph, group),
      hasColorTemp: group.nodeIds.any(
        (id) => state.graph.nodes[id]?.typeId == 'color_temp_adjuster',
      ),
    );
    if (o == null || !mounted) return;
    if (o.vendor == _options.vendor) {
      // 厂商不变：原地更新参数（位宽/行宽）并刷新；会话缓存同步。
      sessionIpGenOptions[widget.groupId] = o;
      setState(() {
        _options = o;
        _files = null;
      });
      await _reload();
    } else {
      // 换厂商：开新标签（同一编组可同开多家厂商 IP 标签页）。
      state.openGroupIpTab(widget.groupId, o);
    }
  }

  void _selectCodeFile(String file) {
    setState(() {
      _selectedFile = file;
      _codeSpans = null;
    });
    _prepareCode();
  }

  Future<void> _prepareCode() async {
    final files = _files;
    final file = _selectedFile;
    if (files == null || file.isEmpty) return;
    final generation = ++_codeGeneration;
    final text = files[file]!.trim();
    if (file.endsWith('.md')) {
      setState(() => _codeSpans = const []);
      return;
    }
    setState(() => _progressStage = '准备代码高亮与排版');
    try {
      final spans = widget.filesBuilder != null
          ? SyntaxHighlighter.highlightText(
              text,
              'v',
              baseStyle: kCodeBrowserStyle,
            )
          : await _highlightIpCodeOffstage(text);
      if (!mounted || generation != _codeGeneration || file != _selectedFile) {
        return;
      }
      setState(() => _codeSpans = spans);
    } catch (error) {
      if (!mounted || generation != _codeGeneration) return;
      setState(() => _error = '代码显示准备失败：$error');
    }
  }

  Widget _buildGenerationProgress() {
    return Center(
      child: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_progressStage, style: const TextStyle(fontSize: 14)),
            const SizedBox(height: 16),
            const LinearProgressIndicator(),
          ],
        ),
      ),
    );
  }

  Widget _buildCodeArea() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!, style: const TextStyle(color: Colors.red)),
        ),
      );
    }
    if (_files == null || _selectedFile.isEmpty) {
      return _buildGenerationProgress();
    }
    // SimWave「跳转到Verilog」高亮词：当前文件不含该信号时自动切到
    // 首个含它的 .v 文件（所有 .v 文件中的出现都高亮）。
    final hl = context.watch<IspStudioState>().ipCodeHighlight;
    if (hl != null) {
      final cur = _files![_selectedFile] ?? '';
      if (!containsVerilogWord(cur, hl)) {
        for (final f in _files!.keys) {
          if (f.endsWith('.v') && containsVerilogWord(_files![f]!, hl)) {
            if (f != _selectedFile) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _selectCodeFile(f);
              });
            }
            break;
          }
        }
      }
    }
    final text = _files![_selectedFile]!.trim();
    // Markdown 文档（README.md）默认预览渲染，可切换源码视图。
    if (_selectedFile.endsWith('.md')) {
      return MarkdownView(text: text);
    }
    if (_codeSpans == null) return _buildGenerationProgress();
    var spans = _codeSpans!;
    if (hl != null) spans = highlightWordOccurrences(spans, hl);
    return CodeArea(spans: spans);
  }

  /// 仿真与 demo 生成共用终端面板：标题、状态随当前任务切换，流式追加并
  /// 自动滚底；任务运行中禁用关闭。
  Widget _buildSimPanel() {
    final demo = _consoleTask == _IpConsoleTask.demoProject;
    final succeeded = demo
        ? (_demoResult?.success ?? false)
        : (_simResult?.passed ?? false);
    final statusColor = _taskRunning
        ? const Color(0xFFD7BA7D)
        : succeeded
        ? const Color(0xFF4CAF50)
        : const Color(0xFFCF6679);
    final statusText = _taskRunning
        ? (demo ? '生成中…' : '仿真中…')
        : demo
        ? (_demoResult?.success ?? false ? '生成成功 ✓' : '生成失败 ✗')
        : _simResult == null
        ? '失败'
        : (_simResult!.passed ? 'PASS ✓' : 'FAIL ✗');
    return Container(
      color: const Color(0xFF141414),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 24,
            color: const Color(0xFF252525),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                const Icon(Icons.terminal, size: 12, color: Colors.grey),
                const SizedBox(width: 6),
                Text(
                  demo ? 'demo_prj — Vivado' : '仿真 — iverilog',
                  style: const TextStyle(fontSize: 11, color: Colors.white70),
                ),
                const SizedBox(width: 8),
                Text(
                  statusText,
                  style: TextStyle(fontSize: 11, color: statusColor),
                ),
                const Spacer(),
                InkWell(
                  onTap: _taskRunning
                      ? null
                      : () => setState(() => _simPanelVisible = false),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.all(3),
                    child: Icon(
                      Icons.close,
                      size: 12,
                      color: _taskRunning ? Colors.white24 : Colors.grey,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              controller: _simScroll,
              padding: const EdgeInsets.all(8),
              child: SelectableText(
                _simLog.toString(),
                style: const TextStyle(
                  fontFamily: 'Consolas',
                  fontFamilyFallback: ['Courier New', 'monospace'],
                  fontSize: 11,
                  height: 1.4,
                  color: Color(0xFFD4D4D4),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<CodeFileGroup> _groupsOf(Map<String, String> files) {
    return [
      CodeFileGroup('仿真', [
        for (final f in files.keys)
          if (f.startsWith('tb_') || f.startsWith('golden_')) f,
      ]),
      CodeFileGroup('核心/顶层', [
        for (final f in files.keys)
          if (f.endsWith('_core.v') || f.endsWith('_top.v')) f,
      ]),
      CodeFileGroup('接口封装', [
        for (final f in files.keys)
          if (f.endsWith('_axis.v') || f.endsWith('_libero.v')) f,
      ]),
      CodeFileGroup('脚本', [
        for (final f in files.keys)
          if (f.endsWith('.tcl')) f,
      ]),
      CodeFileGroup('文档', [
        for (final f in files.keys)
          if (f.endsWith('.md')) f,
      ]),
    ];
  }
}
