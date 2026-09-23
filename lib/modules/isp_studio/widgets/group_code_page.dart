/// ISP Studio 编组代码标签页。
///
/// 右键编组菜单「查看C代码」打开：顶部页头（编组名 + 只读标识），左侧为
/// 编组导出的完整文件清单（顶层 pipeline / 节点封装 / 算法参考 c_ref
/// 三组，底部附「导出代码」按钮，选目录后写盘全部文件），右侧为带行号
/// 的 C 语法高亮代码区（只读）。文件内容由 buildGroupCFiles 按当前图
/// 内存生成（c_ref 经 loadCRefFile 缓存），参数改动后重建页面即刷新；
/// 校验不过（见 validateGroupCExport）时显示错误原因而非文件树。
/// 代码区支持「定义预览」：悬停到在本文件集中有定义的函数名/宏名上时，代码区
/// 分成左右两栏，右栏直接预览该函数/宏定义；预览标题栏的「Go to REF」按钮
/// 点击跳到该定义所在文件与行（索引见 indexCDefs）。
library;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../providers/isp_studio_state.dart';
import '../../text_editor/utils/syntax_highlighter.dart';
import '../codegen/c_compile.dart';
import '../codegen/group_c_export.dart';
import '../models/isp_graph.dart';
import '../pipeline/c_def_index.dart';
import 'code_browser.dart';

/// 校验编组能否导出 C 代码；不可导出时弹错误对话框并返回 false。
Future<bool> ensureGroupCExportable(
    BuildContext context, IspGraph graph, IspNodeGroup group) async {
  final error = validateGroupCExport(graph, group);
  if (error == null) return true;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF2E2E2E),
      title: const Text('无法导出代码',
          style: TextStyle(color: Colors.white, fontSize: 14)),
      content: Text(error,
          style: const TextStyle(color: Colors.white70, fontSize: 12)),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了')),
      ],
    ),
  );
  return false;
}

/// 编组导出 C 代码：选择目录 → 生成写盘 → SnackBar 提示（须已校验，
/// 见 [ensureGroupCExportable]）。
Future<void> exportGroupCCodeInteractive(
    BuildContext context, IspStudioState state, IspNodeGroup group) async {
  final dir = await getDirectoryPath();
  if (dir == null || !context.mounted) return;
  try {
    final result = await exportGroupCCode(state.graph, group, dir);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(
              '已导出 ${result.files.length} 个文件到 $dir（top 层：${result.topName}.h/.c）')),
    );
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content:
              Text('导出失败：${e.toString().replaceFirst('Bad state: ', '')}')),
    );
  }
}

/// 编组的只读代码页面（作为编辑器标签页嵌入主视图）。
/// 点「编译」在右侧代码区下方切出 1/4 高度的终端面板，流式打印编译过程。
class GroupCodePage extends StatefulWidget {
  final String groupId;

  /// 编译执行器注入点（测试替换为假实现；缺省为 compileGroupCFiles）。
  final GroupCompileRunner? compileRunner;

  /// 文件生成器注入点（测试替换为立即返回的假实现，绕开 rootBundle
  /// 真实资产 IO；缺省为 buildGroupCFiles）。
  final Future<Map<String, String>> Function(IspGraph graph, IspNodeGroup group)?
      filesBuilder;

  const GroupCodePage(
      {super.key, required this.groupId, this.compileRunner, this.filesBuilder});

  @override
  State<GroupCodePage> createState() => _GroupCodePageState();
}

class _GroupCodePageState extends State<GroupCodePage> {
  /// 当前选中的文件（null 时默认选 top 层 .c，无则第一个 .c / 第一个文件）。
  String? _selectedFile;

  /// 最近一次生成结果：重新生成期间继续显示旧内容，避免闪烁。
  Map<String, String>? _files;

  /// 代码区跳转控制器（「Go to REF」点击后滚动到定义行）。
  late final CodeAreaController _codeCtl = CodeAreaController();

  @override
  void dispose() {
    _codeCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<IspStudioState>();
    final group = state.graph.groups
        .where((g) => g.id == widget.groupId)
        .firstOrNull;
    if (group == null) {
      return const Center(
        child: Text('编组已被解散', style: TextStyle(color: Colors.grey)),
      );
    }
    final error = validateGroupCExport(state.graph, group);
    if (error != null) {
      return Container(
        color: const Color(0xFF1E1E1E),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(group),
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(error,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 12, color: Color(0xFFCF6679))),
                ),
              ),
            ),
          ],
        ),
      );
    }
    // 每次 build 按当前图重新生成（生成本身快，c_ref 内容有缓存），
    // 节点参数/连线改动后页面即随之刷新。
    return FutureBuilder<Map<String, String>>(
      future: (widget.filesBuilder ?? buildGroupCFiles)(state.graph, group),
      initialData: _files,
      builder: (context, snapshot) {
        final files = snapshot.data;
        if (files == null) {
          // 生成失败要显示错误而不是永远卡在「生成中…」。
          final error = snapshot.hasError
              ? '生成代码失败：${snapshot.error.toString().replaceFirst('Bad state: ', '')}'
              : null;
          return Container(
            color: const Color(0xFF1E1E1E),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildHeader(group),
                Expanded(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        error ?? '生成中…',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          color: error != null
                              ? const Color(0xFFCF6679)
                              : Colors.grey,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        }
        _files = files;
        return _buildWithFiles(state, group, files);
      },
    );
  }

  /// 页头：编组名 + 组 id + 只读标识（与节点代码页同一风格）。
  Widget _buildHeader(IspNodeGroup group) {
    return Container(
      height: 28,
      color: const Color(0xFF252525),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          Text(
            '${group.name} (${widget.groupId})',
            style: const TextStyle(fontSize: 12, color: Colors.white70),
          ),
          const SizedBox(width: 8),
          const Text(
            '编组',
            style: TextStyle(fontSize: 11, color: Colors.grey),
          ),
          const Spacer(),
          const Icon(Icons.lock_outline, size: 12, color: Colors.grey),
          const SizedBox(width: 4),
          const Text('只读', style: TextStyle(fontSize: 11, color: Colors.grey)),
        ],
      ),
    );
  }

  /// 文件清单分组：顶层（isp_pipeline_*）/ 节点封装 / 算法参考（c_ref，
  /// isp_common.* 与各算法 isp_* 文件），组内保持生成顺序。
  List<CodeFileGroup> _groupsOf(Map<String, String> files) {
    final top = <String>[];
    final wrappers = <String>[];
    final cRef = <String>[];
    for (final f in files.keys) {
      if (f.startsWith('isp_pipeline_')) {
        top.add(f);
      } else if (f.startsWith('isp_')) {
        cRef.add(f);
      } else {
        wrappers.add(f);
      }
    }
    return [
      CodeFileGroup('顶层', top),
      CodeFileGroup('节点封装', wrappers),
      CodeFileGroup('算法参考（c_ref）', cRef),
    ];
  }

  Widget _buildWithFiles(
      IspStudioState state, IspNodeGroup group, Map<String, String> files) {
    // 展示用文件集：生成物 + 编译 stub main.c（「临时main调用（不导出）」分组，展示
    // 通用形态——不带 ARM syscall 桩；桩在真正编译时按目标补充，见
    // stubMainCSource）。main.c 只展示，不进导出物（exportGroupCCode
    // 与编译 filesLoader 都用原 files）。
    final displayFiles = {
      ...files,
      'main.c': stubMainCSource(
          topName: groupCTopName(group), target: CCompileTarget.x86),
    };
    // 默认选中 top 层 .c；无则第一个 .c，再退化为第一个文件。
    final selected =
        _selectedFile != null && displayFiles.containsKey(_selectedFile)
            ? _selectedFile!
            : (files.containsKey('${groupCTopName(group)}.c')
                ? '${groupCTopName(group)}.c'
                : displayFiles.keys.firstWhere((f) => f.endsWith('.c'),
                    orElse: () => displayFiles.keys.first));
    // 与文本对比/补丁视图同一套 VSCode Dark+ 语法高亮（C family 规则）。
    final trimmed = {
      for (final e in displayFiles.entries) e.key: e.value.trim()
    };
    // 悬停「定义预览」函数/宏定义索引：含 main.c，使 stub 里对 top 层 run 的
    // 调用也能预览。
    final refIndex = indexCDefs(trimmed);
    final spans = SyntaxHighlighter.highlightText(
      trimmed[selected]!,
      'c',
      baseStyle: kCodeBrowserStyle,
    );
    return Container(
      color: const Color(0xFF1E1E1E),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(group),
          // 编译工具栏 + 文件清单 + 代码区/终端面板（公共组件）。
          Expanded(
            child: CodeCompileArea(
              buttonKey: const ValueKey('groupCompileButton'),
              terminalKey: const ValueKey('groupCompileTerminal'),
              leftPane: CFileList(
                files: files.keys.toList(),
                selected: selected,
                onSelect: (f) => setState(() => _selectedFile = f),
                groups: [
                  ..._groupsOf(files),
                  // 「临时main调用（不导出）」分组标题用红色底标识（VS 系红，白字可读）。
                  const CodeFileGroup('临时main调用（不导出）', ['main.c'],
                      titleColor: Color(0xFFC42B1C)),
                ],
                highlightGroupTitles: true,
                onExport: (ctx) async {
                  if (await ensureGroupCExportable(ctx, state.graph, group)) {
                    if (!ctx.mounted) return;
                    await exportGroupCCodeInteractive(ctx, state, group);
                  }
                },
              ),
              codeArea: CodeArea(
                spans: spans,
                controller: _codeCtl,
                plainText: trimmed[selected],
                currentFile: selected,
                refIndex: refIndex,
                refContents: trimmed,
                // 点预览标题栏「Go to REF」：切左侧文件清单选中项 + 代码区滚到定义行。
                onGoToRef: (file, line) {
                  setState(() => _selectedFile = file);
                  _codeCtl.jumpTo(line);
                },
              ),
              filesLoader: () async => files,
              topName: groupCTopName(group),
              compileRunner: widget.compileRunner,
              preCompileCheck: (ctx) =>
                  ensureGroupCExportable(ctx, state.graph, group),
            ),
          ),
        ],
      ),
    );
  }
}
