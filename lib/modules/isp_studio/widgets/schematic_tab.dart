/// ISP Studio「电路图」标签页：两种视图——
/// - **模块框图**（默认）：由编组规划 IR 直绘的模块级框图（实例块 +
///   端口针脚 + 网表连线 + 位宽标注，Vivado Elaborated Design 风格，
///   见 ip_block_diagram.dart），零工具链依赖、即时显示；
/// - **RTL 网表**：Yosys + netlistsvg 渲染的实际网表电路图（见
///   codegen/yosys_schematic.dart），首次切换时懒触发渲染，页内嵌
///   SVG 浏览（缩放/平移）。
///
/// 从 IP 标签页工具栏「电路图浏览」打开（key 前缀 `sch:`）。工具链缺失
/// （yosys / netlistsvg / node）时 RTL 视图显示安装提示，框图不受影响。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';

import '../../../providers/isp_studio_state.dart';
import '../codegen/group_ip_export.dart';
import '../codegen/ip_gen_plan.dart';
import '../codegen/ip_target.dart';
import '../codegen/yosys_schematic.dart';
import '../models/isp_graph.dart';
import 'ip_block_diagram.dart';
import 'tab_toolbar.dart';

/// 编组的电路图浏览标签页（作为编辑器标签页嵌入主视图）。
class SchematicTab extends StatefulWidget {
  final String groupId;

  /// FPGA 厂商目标（决定电路图顶层封装的选择，见 schematicTopModule）。
  final IpVendor vendor;

  /// 渲染器注入点（测试替换为假实现；缺省为 renderSchematic）。
  final Future<SchRenderResult> Function(
    Map<String, String> files, {
    required String topName,
    void Function(String chunk)? onOutput,
  })? renderer;

  /// IP 文件生成器注入点（测试替换；缺省为 buildGroupIpFiles）。
  final Future<Map<String, String>> Function(
      IspGraph graph, IspNodeGroup group, IpGenOptions options)? filesBuilder;

  const SchematicTab({
    super.key,
    required this.groupId,
    this.vendor = IpVendor.generic,
    this.renderer,
    this.filesBuilder,
  });

  @override
  State<SchematicTab> createState() => _SchematicTabState();
}

class _SchematicTabState extends State<SchematicTab> {
  /// 渲染产物：SVG 字节与源 SVG 路径（「导出SVG」复用同一份产物）。
  Uint8List? _svgBytes;
  String? _svgPath;
  String? _error;

  bool _running = false;

  /// 管线日志（终端面板显示；成功后可收起）。
  final StringBuffer _log = StringBuffer();

  /// 日志面板是否可见（渲染中/失败时强制显示，成功后默认收起）。
  bool _logVisible = false;

  /// 视图模式：false = 模块级框图（默认，纯 Dart 由规划 IR 绘制，见
  /// ip_block_diagram.dart）；true = RTL 网表（yosys + netlistsvg 管线，
  /// 首次切换时懒触发渲染）。
  bool _rtlMode = false;

  /// RTL 网表是否已触发过首次渲染。
  bool _rtlStarted = false;

  final _logScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    // 默认模块级框图（零工具链依赖、即时显示）；不自动跑 RTL 渲染。
  }

  /// 切换 框图 / RTL 网表 视图；首次切到网表时触发渲染。
  void _switchMode(bool rtl) {
    setState(() => _rtlMode = rtl);
    if (rtl && !_rtlStarted) {
      _rtlStarted = true;
      unawaited(_render());
    }
  }

  @override
  void dispose() {
    _logScroll.dispose();
    super.dispose();
  }

  /// 渲染电路图：重新生成 IP 文件 → yosys + netlistsvg 管线。
  Future<void> _render() async {
    final state = context.read<IspStudioState>();
    final group = state.graph.groups
        .where((g) => g.id == widget.groupId)
        .firstOrNull;
    if (group == null) return;
    setState(() {
      _running = true;
      _logVisible = true;
      _log.clear();
      _error = null;
    });
    void onOutput(String chunk) {
      if (!mounted) return;
      setState(() => _log.write(chunk));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_logScroll.hasClients) {
          _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
        }
      });
    }

    try {
      final options =
          sessionIpGenOptions[widget.groupId] ??
              IpGenOptions(vendor: widget.vendor);
      final files = await (widget.filesBuilder ??
          (g, gr, o) =>
              Future.value(buildGroupIpFiles(g, gr, o)))(state.graph, group, options);
      if (!mounted) return;
      final top = schematicTopModule(files, vendorHint: widget.vendor.name);
      final r = await (widget.renderer ?? renderSchematic)(files,
          topName: top, onOutput: onOutput);
      if (!mounted) return;
      setState(() {
        _running = false;
        if (r.success) {
          _svgBytes = r.svgBytes;
          _svgPath = r.svgPath;
          _error = null;
          _logVisible = false; // 成功收起日志，全幅显示电路图。
        } else {
          _svgBytes = null;
          _svgPath = null;
          _error = switch (r.missingTool) {
            'yosys' => '未检测到 yosys：请放置 tools/yosys（见 tools/README.md）',
            'netlistsvg' =>
              '未检测到 netlistsvg / Node.js：请放置 tools/netlistsvg（见 tools/README.md）',
            _ => '电路图渲染失败，详见下方日志',
          };
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _running = false;
        _error = '电路图渲染异常：$e';
      });
    }
  }

  /// 导出 SVG：选择目录后把产物复制为 `<top>_sch.svg`。
  Future<void> _exportSvg() async {
    final src = _svgPath;
    if (src == null) return;
    final dir = await getDirectoryPath(confirmButtonText: '导出');
    if (dir == null) return;
    // 产物文件位于 <工作目录>/<top>/sch.svg，导出名取 <top>_sch.svg。
    final top = File(src).parent.path.split(RegExp(r'[\\/]')).last;
    final dst = '$dir${Platform.pathSeparator}${top}_sch.svg';
    try {
      await File(src).copy(dst);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('导出失败：$e')));
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('电路图已导出到 $dst')));
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
    return Container(
      color: const Color(0xFF1E1E1E),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildToolbar(group),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: 3, child: _buildBody(group)),
                if (_rtlMode && _logVisible) ...[
                  Container(height: 1, color: const Color(0xFF3A3A3A)),
                  Expanded(flex: 1, child: _buildLogPanel()),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 工具栏：左侧为 框图/RTL网表 视图切换（激活态 teal 底）+ RTL 模式下
  /// 的 重新生成/导出SVG/日志 图标按钮；右侧信息区（与 C/Verilog 代码页
  /// 同一风格）。
  Widget _buildToolbar(IspNodeGroup group) {
    Widget modeButton(String tooltip, String icon, bool rtl) {
      final active = _rtlMode == rtl;
      return Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: () => _switchMode(rtl),
          borderRadius: BorderRadius.circular(3),
          child: Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: active ? const Color(0xFF1F3A35) : null,
              borderRadius: BorderRadius.circular(3),
              border: active
                  ? Border.all(color: const Color(0xFF4EC9B0))
                  : null,
            ),
            child: Center(
              child: ispTabAssetIcon(icon,
                  color: active ? Colors.white : Colors.white54),
            ),
          ),
        ),
      );
    }

    return ispTabToolbarRow(
      children: [
        // 视图切换：模块级框图（纯 Dart，零工具链）/ RTL 网表（yosys）。
        modeButton('模块框图（编组 IR 直绘）', 'icons/type-hierarchy-sub.png',
            false),
        modeButton('RTL 网表（yosys + netlistsvg）', 'icons/circuit-board.png',
            true),
        if (_rtlMode) ...[
          const SizedBox(width: 6),
          ispTabIconButton(
            tooltip: '重新生成',
            onTap: _running ? null : _render,
            icon: ispTabAssetIcon('icons/refresh.png',
                color: _running ? Colors.white38 : Colors.white),
          ),
          if (_svgPath != null)
            ispTabIconButton(
              tooltip: '导出SVG',
              onTap: _exportSvg,
              icon: ispTabAssetIcon('icons/git-stash-pop.png'),
            ),
          ispTabIconButton(
            tooltip: _logVisible ? '收起日志' : '查看日志',
            onTap: () => setState(() => _logVisible = !_logVisible),
            icon: const Icon(Icons.terminal, size: 20, color: Colors.white),
          ),
        ],
        const Spacer(),
        Text(
          '${group.name} (${widget.groupId})',
          style: const TextStyle(fontSize: 12, color: Colors.white70),
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(width: 8),
        const Text(
          '编组·电路图',
          style: TextStyle(fontSize: 11, color: Colors.grey),
        ),
        const SizedBox(width: 6),
        Text(
          widget.vendor.shortName,
          style: const TextStyle(fontSize: 11, color: Color(0xFF4EC9B0)),
        ),
        const SizedBox(width: 8),
        ispTabToolbarReadOnly(),
      ],
    );
  }

  /// 本体：框图模式为模块级框图（编组规划 IR 直绘）；RTL 模式为渲染
  /// 进度/错误/SVG 电路图（InteractiveViewer 拖动平移 + 滚轮缩放）。
  Widget _buildBody(IspNodeGroup group) {
    if (!_rtlMode) {
      // 模块级框图：规划是纯推导（快），每次 build 重建模型即可。
      final state = context.read<IspStudioState>();
      try {
        final options = sessionIpGenOptions[widget.groupId] ??
            IpGenOptions(vendor: widget.vendor);
        final plan = planGroupIp(state.graph, group, options);
        return IpBlockDiagram(
          model: buildSchModel(plan, state.graph, group),
          onOpenNode: (nodeId) =>
              context.read<IspStudioState>().openCodeTab(nodeId),
        );
      } catch (e) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              '框图构建失败：$e',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Color(0xFFCF6679)),
            ),
          ),
        );
      }
    }
    final bytes = _svgBytes;
    if (_running) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text('正在渲染电路图（yosys → netlistsvg）…',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, color: Color(0xFFCF6679)),
          ),
        ),
      );
    }
    if (bytes == null) {
      return const Center(
        child: Text('尚未生成电路图', style: TextStyle(color: Colors.grey)),
      );
    }
    // netlistsvg 默认皮肤为黑线透明底（原理图惯例白底图纸），给浅色
    // 底衬避免暗色主题下不可见。
    return Container(
      color: const Color(0xFFE8E8E8),
      child: InteractiveViewer(
        minScale: 0.05,
        maxScale: 40,
        boundaryMargin: const EdgeInsets.all(double.infinity),
        child: Center(child: SvgPicture.memory(bytes)),
      ),
    );
  }

  /// 日志面板（与仿真/编译终端同一风格）：标题栏 + 等宽输出区。
  Widget _buildLogPanel() {
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
                  '渲染日志 — yosys + netlistsvg',
                  style: TextStyle(fontSize: 11, color: Colors.white70),
                ),
                const Spacer(),
                InkWell(
                  onTap: _running
                      ? null
                      : () => setState(() => _logVisible = false),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.all(3),
                    child: Icon(
                      Icons.close,
                      size: 12,
                      color: _running ? Colors.white24 : Colors.grey,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              controller: _logScroll,
              padding: const EdgeInsets.all(8),
              child: SelectableText(
                _log.toString(),
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
}
