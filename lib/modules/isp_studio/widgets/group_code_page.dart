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
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../providers/isp_studio_state.dart';
import '../../text_editor/utils/syntax_highlighter.dart';
import '../codegen/c_compile.dart';
import '../codegen/group_c_export.dart';
import '../codegen/group_c_export_bb.dart';
import '../codegen/group_c_target.dart';
import '../models/isp_graph.dart';
import '../pipeline/c_def_index.dart';
import '../pipeline/node_c_code.dart' show loadCRefFile;
import '../pipeline/video_source.dart';
import 'code_browser.dart';

/// 校验编组能否导出 C 代码；不可导出时弹错误对话框并返回 false。
/// [blackBox] 为 true 时按黑盒（行级流水）口径校验。
Future<bool> ensureGroupCExportable(
    BuildContext context, IspGraph graph, IspNodeGroup group,
    {bool blackBox = false}) async {
  final error = blackBox
      ? validateGroupBlackBoxExport(graph, group)
      : validateGroupCExport(graph, group);
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
/// 见 [ensureGroupCExportable]）。[blackBox] 为 true 时导出黑盒变体。
/// [target] 为导出目标 CPU（文件头注释块与 lut_fixed 行核 SIMD 变体）。
Future<void> exportGroupCCodeInteractive(
    BuildContext context, IspStudioState state, IspNodeGroup group,
    {bool blackBox = false,
    GroupCTarget target = GroupCTarget.cortexA53_55}) async {
  final dir = await getDirectoryPath();
  if (dir == null || !context.mounted) return;
  try {
    final result = blackBox
        ? await exportGroupBlackBoxCCode(state.graph, group, dir,
            target: target)
        : await exportGroupCCode(state.graph, group, dir, target: target);
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

  /// 黑盒（行级流水）变体：校验/生成/top 名/导出全部切换到
  /// group_c_export_bb 口径。
  final bool blackBox;

  /// 导出目标 CPU（生成物头注释块与 lut_fixed 行核 SIMD 变体随其分叉）。
  final GroupCTarget target;

  /// 编译执行器注入点（测试替换为假实现；缺省为 compileGroupCFiles）。
  final GroupCompileRunner? compileRunner;

  /// 文件生成器注入点（测试替换为立即返回的假实现，绕开 rootBundle
  /// 真实资产 IO；缺省为 buildGroupCFiles / buildGroupBlackBoxCFiles）。
  final Future<Map<String, String>> Function(IspGraph graph, IspNodeGroup group)?
      filesBuilder;

  const GroupCodePage(
      {super.key,
      required this.groupId,
      this.blackBox = false,
      this.target = GroupCTarget.cortexA53_55,
      this.compileRunner,
      this.filesBuilder});

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

  /// top 层名（整帧版 isp_pipeline_<组>；黑盒 isp_pipe_<组>_bb）。
  String _topName(IspNodeGroup group) => widget.blackBox
      ? groupBlackBoxTopName(group)
      : groupCTopName(group);

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
    final error = widget.blackBox
        ? validateGroupBlackBoxExport(state.graph, group)
        : validateGroupCExport(state.graph, group);
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
      future: (widget.filesBuilder ??
          (widget.blackBox
              ? (g, gr) =>
                  buildGroupBlackBoxCFiles(g, gr, target: widget.target)
              : (g, gr) =>
                  buildGroupCFiles(g, gr, target: widget.target)))(state.graph, group),
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
          Text(
            widget.blackBox ? '编组·黑盒' : '编组',
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
          const SizedBox(width: 6),
          // 目标 CPU 徽标（生成物随其分叉，见 group_c_target.dart）。
          Text(
            widget.target.displayName,
            style: const TextStyle(fontSize: 11, color: Color(0xFF4EC9B0)),
          ),
          const Spacer(),
          const Icon(Icons.lock_outline, size: 12, color: Colors.grey),
          const SizedBox(width: 4),
          const Text('只读', style: TextStyle(fontSize: 11, color: Colors.grey)),
        ],
      ),
    );
  }

  /// 文件清单分组：顶层（isp_pipeline_* / 黑盒 isp_pipe_*_bb）/ 节点封装 /
  /// 算法参考（c_ref，isp_common.* 与各算法 isp_* 文件），组内保持生成顺序。
  /// 黑盒无节点封装组（单文件自含），分组自动为空。
  List<CodeFileGroup> _groupsOf(Map<String, String> files) {
    final top = <String>[];
    final wrappers = <String>[];
    final cRef = <String>[];
    for (final f in files.keys) {
      if (f.startsWith('isp_pipeline_') ||
          (f.startsWith('isp_pipe_') && f.contains('_bb.'))) {
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

  /// 「运行验证（原尺寸/scale）」：构建成功后带源参数启动窗口程序；无源
  /// 时回退内置测试图案（不带 --video）。[scaleDown] 为 true 时附加
  /// --scale（视频逐级减半降档至宽 ≤1280，四段耗时同比缩小）；false 保持
  /// 原生分辨率，让「处理 Xms」反映嵌入式目标的全尺寸帧耗时。
  Future<CCompileResult> _buildAndRunWinVerify(
      IspStudioState state,
      IspNodeGroup group,
      Map<String, String> files,
      String inFormat,
      String outFormat,
      bool hasScratch,
      void Function(String chunk) onOutput,
      {required bool scaleDown}) async {
    final launchArgs =
        await _verifyLaunchArgs(state, group, scaleDown: scaleDown);
    final needCsc = inFormat == 'hsl' || outFormat == 'hsl';
    final result = await buildWinVerifyApp(files,
        topName: _topName(group),
        inFormat: inFormat,
        outFormat: outFormat,
        hasScratch: hasScratch,
        maxValue: _verifyMaxValue(state, group),
        // HSL 转换头经资产包注入（rootBundle，开发/安装版一致）；
        // c_compile.dart 是纯 Dart 不能用 rootBundle，参数缺省时
        // 保留磁盘回退（测试/开发环境行为不变）。
        cscCommonHeader: needCsc && !files.containsKey('isp_csc_common.h')
            ? await loadCRefFile('isp_csc_common.h')
            : null,
        cscSseHeader: needCsc && !files.containsKey('isp_csc_sse.h')
            ? await loadCRefFile('isp_csc_sse.h')
            : null,
        onOutput: onOutput);
    if (result.success && result.artifactPath != null) {
      // 同名编组的旧验证实例先结束：每个实例独占数百 MB 帧缓冲 + 数十
      // 个 omp 线程 + 一个 ffmpeg 解码子进程，反复改参重建验证多实例叠
      // 加会把整机内存/带宽耗尽可能死机。
      final top = _topName(group);
      final oldPid = _verifyPids[top];
      if (oldPid != null) {
        _verifyPids.remove(top);
        Process.killPid(oldPid);
      }
      final proc = await Process.start(result.artifactPath!, launchArgs);
      _verifyPids[top] = proc.pid;
      unawaited(proc.exitCode.then((_) {
        if (_verifyPids[top] == proc.pid) _verifyPids.remove(top);
      }));
    }
    return result;
  }

  /// 各编组（top 名）最近启动的验证程序 PID：同名编组重建验证时先结
  /// 束旧实例（见 _buildAndRunWinVerify）。静态表：代码页随编组切换销
  /// 毁/重建，实例字段会丢。
  static final Map<String, int> _verifyPids = {};

  /// 验证程序的管线量化域（lutDomainMaxOf，沿编组成员上游位深推导）：
  /// LUT 模式节点的查表快路径要求运行时 max_value 与烘焙域一致，否则
  /// 逐像素回退直算（实测 4K ~375ms/帧与 func 无差）。
  int _verifyMaxValue(IspStudioState state, IspNodeGroup group) {
    final node = state.graph.nodes[group.nodeIds.first];
    return node == null ? 255 : lutDomainMaxOf(state.graph, node);
  }

  /// 验证程序启动参数：编组上游视频/图片源 → ['--video', 文件,
  /// '--ffmpeg', ffmpeg路径]（窗口程序内 ffmpeg 子进程管道流式解码）；
  /// 无源或文件缺失返回空（内置测试图案）。[scaleDown] 为 true 且视频宽
  /// >1280 时附加 ['--scale', 'WxH'] 逐级减半降档；false 保持原生分辨率。
  Future<List<String>> _verifyLaunchArgs(
      IspStudioState state, IspNodeGroup group,
      {required bool scaleDown}) async {
    // 编组成员的上游中找视频/图片源。
    String? srcId;
    for (final id in group.nodeIds) {
      for (final upId in state.graph.upstreamOf(id)) {
        final t = state.graph.nodes[upId]?.typeId;
        if (t == 'video_source' || t == 'image_source') {
          srcId = upId;
          break;
        }
      }
      if (srcId != null) break;
    }
    if (srcId == null) return const [];
    final node = state.graph.nodes[srcId]!;
    final path = node.paramValues['filePath']?.toString() ?? '';
    if (path.isEmpty || !File(path).existsSync()) return const [];
    final ff = node.paramValues['ffmpegPath']?.toString() ?? '';
    // 默认工具相对工程根目录，传绝对路径（验证程序的 cwd 不保证是根目录）。
    final ffmpeg = ff.isEmpty
        ? '${Directory.current.path}${Platform.pathSeparator}tools'
            '${Platform.pathSeparator}ffmpeg${Platform.pathSeparator}ffmpeg.exe'
        : ff;
    final args = ['--video', path, '--ffmpeg', ffmpeg];
    // libav* DLL 目录（ffmpeg shared 包的 bin/）：存在时验证程序内嵌
    // 常驻解码器做播放器级拖动预览（av_seek_frame 关键帧直达）；缺失时
    // 验证程序自动回退子进程单帧预览。
    final avDir = Directory(
        '${Directory.current.path}${Platform.pathSeparator}tools'
        '${Platform.pathSeparator}ffmpeg${Platform.pathSeparator}bin');
    if (avDir.existsSync() &&
        avDir.listSync().any((f) =>
            f.path.contains('avcodec-') && f.path.endsWith('.dll'))) {
      args.addAll(['--avdir', avDir.absolute.path]);
    }
    // 视频源探测一次：HDR 判定（--hdr）与 --scale 降档共用；图片源尺寸
    // 适中不处理。
    if (node.typeId == 'video_source') {
      try {
        final info = await videoFileInfo(path, ffmpegPath: ffmpeg);
        // HDR（BT.2020 PQ/HLG）片源：验证程序解码链前置 zscale+tonemap
        // 映射为 BT.709 SDR 交付，与应用内播放/导出同口径（否则 BT.2020
        // 帧按 SDR 直解上屏发灰发暗）。预览 HDR/SDR 切换选 SDR 直解时
        // 同样直通到验证程序（不加 --hdr）。
        if (info.isHdr && state.hdrToneMapEnabled) args.add('--hdr');
        // --scale 降档（解码时缩放，四段耗时同比缩小）。
        if (scaleDown) {
          var sw = info.width, sh = info.height;
          while (sw > 1280) {
            sw ~/= 2;
            sh ~/= 2;
          }
          if (sw < info.width) args.addAll(['--scale', '${sw}x$sh']);
        }
      } catch (_) {}
    }
    return args;
  }

  Widget _buildWithFiles(
      IspStudioState state, IspNodeGroup group, Map<String, String> files) {
    // Win32 可运行验证的支持判定：单外部输入帧 + 单外部输出帧，均
    // uint16_t/3 通道且格式 rgb/hsl（HSL 端口经 csc 装帧显示；多输入/
    // 输出或 mono/bayer/rgba8 端口首版不支持，不显示入口）。
    final plan = planGroupC(state.graph, group);
    final extIn = plan.extInputParams;
    final extOut = plan.extOutputParams;
    bool fmtOk(String f) => f == 'rgb' || f == 'hsl';
    final winOk = extIn.length == 1 &&
        extOut.length == 1 &&
        extIn.single.cType == 'uint16_t' &&
        extOut.single.cType == 'uint16_t' &&
        fmtOk(extIn.single.format) &&
        fmtOk(extOut.single.format);
    // top 层 run 是否带 scratch 参数（整帧版恒有；黑盒无需环形缓冲时
    // 没有——按生成的 top .h 判定）。
    final hasScratch =
        (files['${_topName(group)}.h'] ?? '').contains('void *scratch');
    // 展示用文件集：生成物 + 编译 stub main.c（「临时main调用（不导出）」分组，展示
    // 通用形态——不带 ARM syscall 桩；桩在真正编译时按目标补充，见
    // stubMainCSource）+ Win32 可运行验证 main_win.c（支持时）。两者均只
    // 展示，不进导出物（exportGroupCCode 与编译 filesLoader 都用原 files）。
    final displayFiles = {
      ...files,
      'main.c': stubMainCSource(
          topName: _topName(group), target: CCompileTarget.x86),
      if (winOk)
        'main_win.c': stubMainWinSource(
            topName: _topName(group),
            inFormat: extIn.single.format,
            outFormat: extOut.single.format,
            hasScratch: hasScratch,
            maxValue: _verifyMaxValue(state, group)),
    };
    // 默认选中 top 层 .c；无则第一个 .c，再退化为第一个文件。
    final selected =
        _selectedFile != null && displayFiles.containsKey(_selectedFile)
            ? _selectedFile!
            : (files.containsKey('${_topName(group)}.c')
                ? '${_topName(group)}.c'
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
                  if (winOk)
                    const CodeFileGroup(
                        'Win32可运行验证（不导出）', ['main_win.c'],
                        titleColor: Color(0xFFC42B1C)),
                ],
                highlightGroupTitles: true,
                onExport: (ctx) async {
                  if (await ensureGroupCExportable(ctx, state.graph, group,
                      blackBox: widget.blackBox)) {
                    if (!ctx.mounted) return;
                    await exportGroupCCodeInteractive(ctx, state, group,
                        blackBox: widget.blackBox, target: widget.target);
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
              filesLoader: () async => {
                    ...files,
                    if (winOk) ...{
                      // X86 编译验证时替代 stub main.c（见 compileGroupCFiles
                      // 的 useWinMain 分支）。
                      'main_win.c': stubMainWinSource(
                          topName: _topName(group),
                          inFormat: extIn.single.format,
                          outFormat: extOut.single.format,
                          hasScratch: hasScratch,
                          maxValue: _verifyMaxValue(state, group)),
                      // HSL 转换头（文件集缺失时经资产包注入，与
                      // buildWinVerifyApp 同口径；rootBundle 开发/安装版
                      // 一致，安装版无 lib/ 目录可读盘）。
                      if ((extIn.single.format == 'hsl' ||
                              extOut.single.format == 'hsl') &&
                          !files.containsKey('isp_csc_common.h'))
                        'isp_csc_common.h':
                            await loadCRefFile('isp_csc_common.h'),
                      // HSL 装帧/解包 SSE2 快路径头（同上口径注入）。
                      if ((extIn.single.format == 'hsl' ||
                              extOut.single.format == 'hsl') &&
                          !files.containsKey('isp_csc_sse.h'))
                        'isp_csc_sse.h': await loadCRefFile('isp_csc_sse.h'),
                    },
                  },
              topName: _topName(group),
              compileRunner: widget.compileRunner,
              preCompileCheck: (ctx) => ensureGroupCExportable(
                  ctx, state.graph, group,
                  blackBox: widget.blackBox),
              // Win32 可运行验证（支持判定时出现两个按钮）：抽帧（用户源）
              // + 构建 + 带参启动窗口程序；scaleDown 对应「scale」按钮。
              winVerifyBuilder: winOk
                  ? (onOutput, {required scaleDown}) => _buildAndRunWinVerify(
                      state, group, files, extIn.single.format,
                      extOut.single.format, hasScratch, onOutput,
                      scaleDown: scaleDown)
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}
