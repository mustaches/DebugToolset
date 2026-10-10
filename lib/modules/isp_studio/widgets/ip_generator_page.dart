/// ISP Studio 编组 Verilog IP 标签页。
///
/// 右键编组菜单「生成Verilog IP」打开，布局与 C 代码页一致：顶部工具栏
/// （白色图标按钮在左，编组名 + 厂商 + 只读标识在右），左侧为 IP 包文件
/// 清单（核心/顶层/封装/仿真/脚本/文档六组，190px），右侧为带行号的
/// Verilog 语法高亮代码区（只读）；工具栏「一键仿真」在代码区下方切出
/// 1/4 高度终端面板流式跑 iverilog（与编译终端同一风格）。
library;

import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../providers/isp_studio_state.dart';
import '../../text_editor/utils/syntax_highlighter.dart';
import '../codegen/group_ip_export.dart';
import '../codegen/ip_target.dart';
import '../codegen/iverilog_sim.dart';
import '../codegen/sim_wave_store.dart';
import '../models/isp_graph.dart';
import 'code_browser.dart';
import 'ip_gen_dialog.dart';
import 'tab_toolbar.dart';

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
  String _selectedFile = '';
  Map<String, String>? _files;
  String? _error;

  /// 一键仿真终端输出（流式追加）。
  final StringBuffer _simLog = StringBuffer();
  bool _simRunning = false;
  IpSimResult? _simResult;

  /// 仿真终端面板是否可见（点「一键仿真」时打开，标题栏 × 关闭）。
  bool _simPanelVisible = false;

  /// 仿真终端输出区的滚动控制器（流式追加时自动滚底）。
  final _simScroll = ScrollController();

  /// 左栏文件清单宽度（分隔条可拖动调整，钳位 120~600px）。
  double _leftWidth = 190;

  @override
  void initState() {
    super.initState();
    _options = widget.options;
    _reload();
  }

  @override
  void dispose() {
    _simScroll.dispose();
    super.dispose();
  }

  Future<Map<String, String>> _buildFiles() async {
    final state = context.read<IspStudioState>();
    final group = state.graph.groups.firstWhere((g) => g.id == widget.groupId);
    return buildGroupIpFiles(state.graph, group, _options);
  }

  Future<void> _reload() async {
    try {
      final files = await (widget.filesBuilder ?? _buildFiles)();
      if (!mounted) return;
      setState(() {
        _files = files;
        _error = null;
        if (!files.containsKey(_selectedFile)) {
          _selectedFile = files.keys.isNotEmpty ? files.keys.first : '';
        }
      });
    } catch (e) {
      // 生成失败（如编组校验不通过）必须落到错误页，否则界面无限转圈
      if (!mounted) return;
      setState(() {
        _files = null;
        _error = '生成 IP 包失败：$e';
      });
    }
  }

  Future<void> _runSim() async {
    if (_files == null) await _reload();
    if (_files == null) return;
    setState(() {
      _simRunning = true;
      _simPanelVisible = true;
      _simLog.clear();
      _simResult = null;
    });
    try {
      // openWaveform: false —— 波形改由内嵌「仿真波形」标签页（Surfer
      // WASM）展示，外部查看器经标签页工具栏按钮手动打开。
      final r = await runIpSimulation(
        _files!,
        openWaveform: false,
        onOutput: (c) {
          if (mounted) {
            setState(() => _simLog.write(c));
            // 流式输出自动滚底（同编译终端）。
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (_simScroll.hasClients) {
                _simScroll.jumpTo(_simScroll.position.maxScrollExtent);
              }
            });
          }
        },
      );
      if (!mounted) return;
      setState(() => _simResult = r);
      // 登记波形并打开/激活内嵌波形标签页。
      final vcd = r.vcdData;
      if (r.success && vcd != null) {
        SimWaveStore.instance.registerWave(
          vcd,
          sucl: _files?['wave.sucl'],
          gtkw: _files?['wave.gtkw'],
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

  Future<void> _exportPackage() async {
    if (_files == null) await _reload();
    if (_files == null) return;
    final dir = await getDirectoryPath(confirmButtonText: '导出');
    if (dir == null) return;
    try {
      await exportGroupIpPackage(_files!, dir);
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
                            ? const Center(child: CircularProgressIndicator())
                            : CFileList(
                                files: _files!.keys.toList(),
                                selected: _selectedFile,
                                onSelect: (f) =>
                                    setState(() => _selectedFile = f),
                                groups: _groupsOf(_files!),
                                highlightGroupTitles: true,
                              ),
                      ),
                      // 1px 分隔线（含隐形热区），左右拖动调整左栏宽度。
                      IspVerticalDragDivider(
                        onDelta: (dx) => setState(() =>
                            _leftWidth =
                                (_leftWidth + dx).clamp(120.0, 600.0)),
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
  ///（生成选项 settings-gear / 导出IP包 git-stash-pop / 一键仿真 play，
  /// 悬停 tooltip 显示功能名），右侧为信息区（编组名 + 组 id +
  /// 编组·IP + 厂商徽标 + 只读标识）。
  Widget _buildToolbar(IspNodeGroup group, IspStudioState state) {
    return ispTabToolbarRow(
      children: [
        ispTabIconButton(
          tooltip: '生成选项',
          onTap: () => _pickOptions(state),
          icon: ispTabAssetIcon('icons/settings-gear.png'),
        ),
        ispTabIconButton(
          tooltip: '导出IP包',
          onTap: _exportPackage,
          icon: ispTabAssetIcon('icons/git-stash-pop.png'),
        ),
        ispTabIconButton(
          tooltip: '一键仿真',
          onTap: _simRunning ? null : _runSim,
          icon: ispTabAssetIcon('icons/play.png',
              color: _simRunning ? Colors.white38 : Colors.white),
        ),
        // 电路图浏览：yosys + netlistsvg 渲染 RTL 电路图（新标签页）。
        ispTabIconButton(
          tooltip: '电路图浏览',
          onTap: () => context
              .read<IspStudioState>()
              .openSchematicTab(widget.groupId, _options.vendor),
          icon: ispTabAssetIcon('icons/circuit-board.png'),
        ),
        const Spacer(),
        Text(
          '${group.name} (${widget.groupId})',
          style: const TextStyle(fontSize: 12, color: Colors.white70),
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(width: 8),
        const Text(
          '编组·IP',
          style: TextStyle(fontSize: 11, color: Colors.grey),
        ),
        const SizedBox(width: 6),
        // 厂商徽标（生成物随其分叉，与 C 代码页目标 CPU 徽标同位）。
        Text(
          _options.vendor.shortName,
          style: const TextStyle(fontSize: 11, color: Color(0xFF4EC9B0)),
        ),
        const SizedBox(width: 8),
        ispTabToolbarReadOnly(),
      ],
    );
  }

  Future<void> _pickOptions(IspStudioState state) async {
    final o = await showIpGenDialog(context, initial: _options);
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
      return const Center(child: CircularProgressIndicator());
    }
    final text = _files![_selectedFile]!.trim();
    final spans = SyntaxHighlighter.highlightText(
      text,
      'v',
      baseStyle: kCodeBrowserStyle,
    );
    return CodeArea(spans: spans);
  }

  /// 仿真终端面板（与编译终端同一风格）：标题栏（终端图标 +
  /// 「仿真 — iverilog」+ 状态 + 关闭按钮）+ 可选中等宽输出区，
  /// 流式追加并自动滚底。仿真中禁用关闭（同编译终端口径）。
  Widget _buildSimPanel() {
    final statusColor = _simRunning
        ? const Color(0xFFD7BA7D)
        : (_simResult?.passed ?? false)
        ? const Color(0xFF4CAF50)
        : const Color(0xFFCF6679);
    final statusText = _simRunning
        ? '仿真中…'
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
                const Text(
                  '仿真 — iverilog',
                  style: TextStyle(fontSize: 11, color: Colors.white70),
                ),
                const SizedBox(width: 8),
                Text(
                  statusText,
                  style: TextStyle(fontSize: 11, color: statusColor),
                ),
                const Spacer(),
                InkWell(
                  onTap: _simRunning
                      ? null
                      : () => setState(() => _simPanelVisible = false),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.all(3),
                    child: Icon(
                      Icons.close,
                      size: 12,
                      color: _simRunning ? Colors.white24 : Colors.grey,
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
          if (f.startsWith('tb_') ||
              f.startsWith('golden_') ||
              f.endsWith('.gtkw') ||
              f.endsWith('.sucl'))
            f,
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
