/// ISP Studio 编组 Verilog IP 标签页。
///
/// 右键编组菜单「生成Verilog IP」打开：顶部页头（编组名 + 厂商 + 只读
/// 标识），左侧为 IP 包文件清单（核心/顶层/封装/仿真/脚本/文档六组，
/// 底部「导出IP包」按钮写盘全部文件），右侧为带行号的 Verilog 语法高亮
/// 代码区（只读），工具栏「一键仿真」在底部终端面板流式跑 iverilog。
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
import '../models/isp_graph.dart';
import 'code_browser.dart';
import 'ip_gen_dialog.dart';

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

  @override
  void initState() {
    super.initState();
    _options = widget.options;
    _reload();
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
      _simLog.clear();
      _simResult = null;
    });
    try {
      final r = await runIpSimulation(_files!, onOutput: (c) {
        if (mounted) {
          setState(() => _simLog.write(c));
        }
      });
      if (!mounted) return;
      setState(() => _simResult = r);
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导出失败：$e')),
      );
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('IP 包已导出到 $dir')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<IspStudioState>();
    final group =
        state.graph.groups.firstWhere((g) => g.id == widget.groupId);
    return Container(
      color: const Color(0xFF1E1E1E),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(group, state),
          Expanded(
            child: Row(
              children: [
                SizedBox(
                  width: 280,
                  child: _error != null
                      ? const Center(
                          child: Icon(Icons.error_outline,
                              color: Colors.red, size: 32))
                      : _files == null
                          ? const Center(
                              child: CircularProgressIndicator())
                          : CFileList(
                          files: _files!.keys.toList(),
                          selected: _selectedFile,
                          onSelect: (f) =>
                              setState(() => _selectedFile = f),
                          groups: _groupsOf(_files!),
                          highlightGroupTitles: true,
                          onExport: (_) => _exportPackage(),
                        ),
                ),
                Expanded(child: _buildCodeArea()),
              ],
            ),
          ),
          _buildSimPanel(),
        ],
      ),
    );
  }

  Widget _buildHeader(IspNodeGroup group, IspStudioState state) {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        color: Color(0xFF252525),
        border: Border(bottom: BorderSide(color: Color(0xFF3A3A3A))),
      ),
      child: Row(
        children: [
          const Icon(Icons.memory, size: 18, color: Colors.grey),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${group.name} · IP · ${_options.vendor.shortName}（只读）',
              style: const TextStyle(fontSize: 13, color: Colors.white),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          _headerButton(
            onPressed: () => _pickOptions(state),
            icon: Icons.tune,
            label: '生成选项',
          ),
          const SizedBox(width: 8),
          _headerButton(
            onPressed: _exportPackage,
            icon: Icons.save_alt,
            label: '导出IP包',
          ),
          const SizedBox(width: 8),
          _headerButton(
            onPressed: _simRunning ? null : _runSim,
            icon: Icons.play_arrow,
            label: '一键仿真',
          ),
        ],
      ),
    );
  }

  /// 页头按钮：统一蓝底白字风格（主题 VSCode 蓝）。
  Widget _headerButton({
    required VoidCallback? onPressed,
    required IconData icon,
    required String label,
  }) {
    return FilledButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      label: Text(label),
      style: FilledButton.styleFrom(
        backgroundColor: const Color(0xFF007ACC),
        foregroundColor: Colors.white,
        disabledBackgroundColor: const Color(0xFF3A3A3A),
        disabledForegroundColor: Colors.grey,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        textStyle: const TextStyle(fontSize: 13),
      ),
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

  Widget _buildSimPanel() {
    final hasLog = _simLog.isNotEmpty || _simResult != null;
    return Container(
      height: hasLog ? 180 : 0,
      decoration: const BoxDecoration(
        color: Color(0xFF151515),
        border: Border(top: BorderSide(color: Color(0xFF3A3A3A))),
      ),
      child: hasLog
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 4),
                  child: Row(
                    children: [
                      const Text('仿真输出',
                          style: TextStyle(
                              fontSize: 11, color: Colors.grey)),
                      const Spacer(),
                      if (_simResult != null)
                        Text(
                          _simResult!.passed ? 'PASS ✓' : 'FAIL ✗',
                          style: TextStyle(
                            fontSize: 12,
                            color: _simResult!.passed
                                ? Colors.green
                                : Colors.red,
                          ),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: SelectableText(
                      _simLog.toString(),
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFFCCCCCC),
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ),
              ],
            )
          : const SizedBox.shrink(),
    );
  }

  List<CodeFileGroup> _groupsOf(Map<String, String> files) {
    return [
      CodeFileGroup('仿真', [
        for (final f in files.keys)
          if (f.startsWith('tb_') || f.startsWith('golden_') ||
              f.endsWith('.gtkw') || f.endsWith('.sucl')) f,
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
