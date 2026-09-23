/// ISP Studio 只读代码浏览公共组件：节点代码页与编组代码页共用。
///
/// - [CodeArea]：行号列 + 语法高亮代码区（双向滚动，只读可选中）；
///   可选「定义预览」：传入 plainText/currentFile/refIndex/refContents/
///   onGoToRef 后，悬停到本文件集中有定义的函数名/宏名上时代码区分成左右
///   两栏，右栏直接预览该函数定义（标题栏保留「Go to REF」按钮，点击经
///   回调正式跳转定义所在文件与行）；经 [CodeAreaController] 可让代码区
///   滚动到指定行。五项参数同时非 null 才启用，缺省行为与之前完全一致。
/// - [CFileList]：左侧文件清单（分组小标题 + 文件项选中高亮 + 底部
///   「导出代码」按钮），分组与导出行为均可由调用方定制。
library;

import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../text_editor/utils/syntax_highlighter.dart';
import '../codegen/c_compile.dart';
import '../pipeline/c_def_index.dart';
import '../pipeline/node_c_code.dart';
import 'group_compile_dialog.dart';

/// 代码区与行号共用字体（Consolas，VSCode Dark+ 纯文本色）。
const kCodeBrowserStyle = TextStyle(
  fontFamily: 'Consolas',
  fontFamilyFallback: ['Courier New', 'monospace'],
  fontSize: 12,
  height: 1.45,
  color: kVscodePlain,
);

/// 行号 gutter 与代码区共用的 strut：forceStrutHeight 把每行高度钉死在
/// 12 × 1.45 = 17.4，避免 CJK 回退字体的更大 ascent/descent 度量撑高
/// RichText 实际行高，导致行号列与代码行逐渐错位（悬停命中也依赖该行高）。
const kCodeBrowserStrut = StrutStyle(
  fontFamily: 'Consolas',
  fontSize: 12,
  height: 1.45,
  forceStrutHeight: true,
  leadingDistribution: TextLeadingDistribution.even,
);

/// 悬停标识符高亮样式：VSCode 亮黄底 + 黑字（暗色主题下醒目且协调）。
/// 叠加在原语法高亮样式之上（merge，只覆盖背景色与文字色）。
const kIdentHighlightStyle = TextStyle(
  backgroundColor: Color(0xFFFFF176),
  color: Colors.black,
);

/// 把 [spans]（按行产出、'\n' 分隔的扁平 TextSpan 列表）中第 [line] 行
///（0 起始）字符区间 [start, end) 的文本拆出为独立段并叠加样式 [hl]
///（悬停标识符/定义处黄底黑字高亮用）；其余段原样保留（同一对象）。
List<TextSpan> applyIdentHighlight(
  List<TextSpan> spans,
  int line,
  int start,
  int end,
  TextStyle hl,
) {
  final out = <TextSpan>[];
  var curLine = 0; // 当前段所处行（0 起始）
  var col = 0; // 当前段起点在行内的字符偏移
  void advance(String text) {
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) == 0x0A) {
        curLine++;
        col = 0;
      } else {
        col++;
      }
    }
  }

  for (final s in spans) {
    final text = s.text ?? '';
    // 仅处理起点在目标行的段：行内部分（首个 '\n' 之前）与 [start, end)
    // 有交叠时切成 前/中/后 三段，中段叠加高亮样式。
    if (curLine == line && text.isNotEmpty) {
      final nl = text.indexOf('\n');
      final lineLen = nl < 0 ? text.length : nl;
      final a = start - col > 0 ? start - col : 0;
      final b = end - col < lineLen ? end - col : lineLen;
      if (a < b) {
        if (a > 0) {
          out.add(TextSpan(text: text.substring(0, a), style: s.style));
        }
        out.add(TextSpan(
          text: text.substring(a, b),
          style: (s.style ?? const TextStyle()).merge(hl),
        ));
        if (b < text.length) {
          out.add(TextSpan(text: text.substring(b), style: s.style));
        }
        advance(text);
        continue;
      }
    }
    out.add(s);
    advance(text);
  }
  return out;
}

/// 取 [spans] 中第 [line] 行（0 起始）的纯文本；行号越界返回 null。
String? spansLineText(List<TextSpan> spans, int line) {
  var cur = 0;
  final buf = StringBuffer();
  for (final s in spans) {
    final text = s.text ?? '';
    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      if (ch == '\n') {
        if (cur == line) return buf.toString();
        cur++;
        buf.clear();
      } else if (cur == line) {
        buf.write(ch);
      }
    }
  }
  return cur == line ? buf.toString() : null;
}

/// 在 [spans] 第 [line] 行（0 起始）中找 [name] 的第一个整词出现
///（前后非 `[A-Za-z0-9_]`），返回行内字符区间；找不到返回 null。
(int start, int end)? findIdentRangeInLine(
  List<TextSpan> spans,
  int line,
  String name,
) {
  final lineText = spansLineText(spans, line);
  if (lineText == null) return null;
  final m = RegExp(
    '(?<![A-Za-z0-9_])${RegExp.escape(name)}(?![A-Za-z0-9_])',
  ).firstMatch(lineText);
  if (m == null) return null;
  return (m.start, m.end);
}

/// 文件分组：小标题 + 组内文件（按列表顺序显示）。
class CodeFileGroup {
  final String label;
  final List<String> files;

  /// 分组标题高亮底色：null 时跟随默认（highlightGroupTitles 开启为亮蓝
  /// 0xFF007ACC，关闭为灰色小标题无底色）；非 null 时强制使用该底色 +
  /// 白字（如「临时main调用（不导出）」分组的红色标识），与 highlightGroupTitles 无关。
  final Color? titleColor;

  const CodeFileGroup(this.label, this.files, {this.titleColor});
}

/// 代码区跳转控制器：经 [jumpTo] 让 [CodeArea] 滚动到指定行（1 起始，
/// 目标行滚到距顶部约 5 行处）。由调用方持有与 dispose。
class CodeAreaController {
  /// 待跳转行（1 起始）；ValueNotifier 同值不重复通知，故不置空。
  final ValueNotifier<int?> jumpLine = ValueNotifier(null);

  void jumpTo(int line) => jumpLine.value = line;

  void dispose() => jumpLine.dispose();
}

/// 代码区：行号列 + 语法高亮代码，双向滚动。
///
/// 「定义预览」（可选）：[plainText]/[currentFile]/[refIndex]/[refContents]/
/// [onGoToRef] 同时非 null 时启用——悬停到在本文件集中有定义的函数名/宏名
/// （见 indexCDefs）上时，代码区分成左右两栏，右栏直接预览该函数/宏
/// 定义（定义文件完整代码 + 自动滚到定义行）；预览标题栏的「Go to REF」
/// 按钮点击回调正式跳转。预览一旦打开就保持（悬停空白不收起），鼠标
/// 离开整个代码区约 350ms 后或点标题栏 × 才关闭。不传这些参数时行为
/// 与纯展示形态完全一致。
class CodeArea extends StatefulWidget {
  final List<TextSpan> spans;

  /// 跳转控制器（可选，见 [CodeAreaController]）。
  final CodeAreaController? controller;

  /// 与 spans 同源的纯文本（trim 后）：悬停命中按行取词用。
  final String? plainText;

  /// 当前显示的文件名：同文件多定义优先、定义就在本行时不预览。
  final String? currentFile;

  /// 函数名/宏名 → 定义位置索引（indexCDefs 产物）。
  final Map<String, List<CDefLocation>>? refIndex;

  /// 函数定义预览内容源：文件名 → 纯文本（trim 后），启用悬停时一并
  /// 传入；拿不到内容时右栏显示占位文案。
  final Map<String, String>? refContents;

  /// 点预览标题栏「Go to REF」的回调：目标文件 + 1 起始行号。
  final void Function(String file, int line)? onGoToRef;

  /// 定义处高亮目标（可选，行号 1 起始）：非 null 时把该行中 [name] 的
  /// 第一个整词出现标为黄底黑字（右栏定义预览传入函数/宏定义行与名字）。
  final ({int line, String name})? highlightTarget;

  const CodeArea({
    super.key,
    required this.spans,
    this.controller,
    this.plainText,
    this.currentFile,
    this.refIndex,
    this.refContents,
    this.onGoToRef,
    this.highlightTarget,
  });

  @override
  State<CodeArea> createState() => _CodeAreaState();
}

class _CodeAreaState extends State<CodeArea> {
  /// 显式垂直滚动控制器（Scrollbar 在桌面/测试环境无 primary 控制器时需要）。
  final _vController = ScrollController();

  /// 当前 build 的行号 gutter 宽度（悬停命中换算 dx 用）。
  double _gutterWidth = 0;

  /// 右栏定义预览：null 表示未打开；非 null 时代码区分左右两栏。
  ({String func, CDefLocation loc})? _peek;

  /// 右栏预览代码区的跳转控制器（随 _peek 切换重建）。
  CodeAreaController? _peekCtl;

  /// 悬停去抖：上次计算的 (行, dx/4 桶)，相同则跳过。
  (int, int)? _lastHover;

  /// 当前悬停命中的标识符高亮范围（0 起始行 + 行内字符区间）；
  /// null 表示无高亮。粘性保持：移到空白/移出代码区不清除，
  /// 只有悬停到另一个索引内标识符时才替换（内容过期时由
  /// didUpdateWidget 清除）。
  ({int line, int start, int end})? _hoverHl;

  /// plainText 的行拆分缓存（悬停命中高频访问）。
  String? _plainCache;
  List<String>? _linesCache;

  /// 行高：12 × 1.45 = 17.4 逻辑像素（等宽字体行距）。
  double get _lineHeight =>
      kCodeBrowserStyle.fontSize! * kCodeBrowserStyle.height!;

  /// 「定义预览」悬停功能是否启用（五项参数同时非 null）。
  bool get _hoverEnabled =>
      widget.plainText != null &&
      widget.currentFile != null &&
      widget.refIndex != null &&
      widget.refContents != null &&
      widget.onGoToRef != null;

  List<String> get _lines {
    final t = widget.plainText!;
    if (_plainCache != t) {
      _plainCache = t;
      _linesCache = t.split('\n');
    }
    return _linesCache!;
  }

  @override
  void initState() {
    super.initState();
    widget.controller?.jumpLine.addListener(_onJump);
  }

  @override
  void didUpdateWidget(CodeArea oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?.jumpLine.removeListener(_onJump);
      widget.controller?.jumpLine.addListener(_onJump);
    }
    if (oldWidget.plainText != widget.plainText ||
        oldWidget.refIndex != widget.refIndex) {
      _resetPeek();
      _hoverHl = null;
    }
  }

  @override
  void deactivate() {
    _resetPeek();
    super.deactivate();
  }

  @override
  void dispose() {
    _resetPeek();
    widget.controller?.jumpLine.removeListener(_onJump);
    _vController.dispose();
    super.dispose();
  }

  /// 跳转请求：目标行滚到距顶部约 5 行处（等帧末布局完成后执行）。
  void _onJump() {
    final line = widget.controller?.jumpLine.value;
    if (line == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_vController.hasClients) return;
      _vController.jumpTo(
        (((line - 5).clamp(1, line)) * _lineHeight).clamp(
          0.0,
          _vController.position.maxScrollExtent,
        ),
      );
    });
  }

  /// 清理预览状态（不触发 setState，供 dispose/deactivate/didUpdateWidget
  /// 与关闭路径共用）。
  void _resetPeek() {
    _peekCtl?.dispose();
    _peekCtl = null;
    _peek = null;
  }

  /// 关闭右栏预览（点标题栏 × 或 Go to REF）。
  void _closePeek() {
    if (_peek == null && _peekCtl == null) return;
    _resetPeek();
    if (mounted) setState(() {});
  }

  /// 打开/切换右栏预览：重建右栏跳转控制器，等右栏 CodeArea 挂载
  /// （监听挂好）后请求滚动到定义行。预览由用户显式关闭（× 或 Go to REF），
  /// 不随鼠标移出自动收起。
  void _openPeek(String name, CDefLocation loc) {
    if (_peek != null && _peek!.func == name && _peek!.loc == loc) return;
    _peekCtl?.dispose();
    final ctl = CodeAreaController();
    setState(() {
      _peek = (func: name, loc: loc);
      _peekCtl = ctl;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _peekCtl == ctl) ctl.jumpTo(loc.line);
    });
  }

  /// 代码区悬停命中：换算 (行, 字符偏移) → 取标识符 → 查定义索引，
  /// 命中后高亮该标识符并右栏预览其定义；未命中（空白/非索引标识符）
  /// 时保持现有高亮与预览不变（粘性：高亮只被下一次命中替换，
  /// 或内容过期时由 didUpdateWidget 清除）。
  void _onHover(PointerHoverEvent event) {
    final local = event.localPosition;
    final dx = local.dx - _gutterWidth - 10;
    // 纵向命中向下偏移半行：代码区光标是工字形，用户习惯用上下短横
    // 「框住」字符（视觉中心对准字符），而热点在图形上沿，实际指向比
    // 视觉瞄点高约半行；+半行偏移让框选式瞄准即可命中。代价是用光标
    // 尖沿精确指向某行字符的下半截时会落到下一行（该行无标识符则不
    // 响应，不影响框选手感）。
    final lineIdx = ((local.dy + _lineHeight / 2) / _lineHeight).floor();
    // 去抖：同一 (行, dx/4 桶) 不重复计算。
    final key = (lineIdx, dx ~/ 4);
    if (key == _lastHover) return;
    _lastHover = key;

    // 空白/越界/非索引标识符：保留旧高亮与预览，直接返回。
    if (dx < 0 || lineIdx < 0 || lineIdx >= _lines.length) return;
    final lineText = _lines[lineIdx];
    final hit = _identifierAt(lineText, dx);
    if (hit == null) return;
    final locations = widget.refIndex![hit.name];
    if (locations == null) return;
    // 命中已知函数/宏：黄底黑字高亮该标识符（范围不变时不重复 setState；
    // 命中新标识符时替换旧高亮）。
    final hl = (line: lineIdx, start: hit.start, end: hit.end);
    if (_hoverHl != hl) setState(() => _hoverHl = hl);
    // 同文件内的定义优先，否则取第一个。
    final loc = locations.firstWhere(
      (l) => l.file == widget.currentFile,
      orElse: () => locations.first,
    );
    // 定义处就是当前悬停行本身则不切换预览（左栏高亮照常更新）。
    if (loc.file == widget.currentFile && loc.line == lineIdx + 1) return;
    _openPeek(hit.name, loc);
  }

  /// 取 [lineText] 中横向 dx 处的标识符（向两侧扩展 `[A-Za-z_]\w*`），
  /// 返回名字与行内字符区间；dx 落在空白/标点或超出行宽时返回 null。
  ({String name, int start, int end})? _identifierAt(
    String lineText,
    double dx,
  ) {
    if (lineText.isEmpty) return null;
    // TextPainter 命中（行内有中文注释等非等宽字符时也准）。
    final painter = TextPainter(
      text: TextSpan(text: lineText, style: kCodeBrowserStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    try {
      if (dx > painter.width) return null;
      final pos = painter.getPositionForOffset(Offset(dx, _lineHeight / 2));
      var offset = pos.offset;
      bool isWord(int code) =>
          (code >= 0x30 && code <= 0x39) || // 0-9
          (code >= 0x41 && code <= 0x5A) || // A-Z
          (code >= 0x61 && code <= 0x7A) || // a-z
          code == 0x5F; // _
      // 落在标识符右边界时 getPositionForOffset 返回下一字符偏移，回退一格。
      if (offset >= lineText.length || !isWord(lineText.codeUnitAt(offset))) {
        if (offset > 0 && isWord(lineText.codeUnitAt(offset - 1))) {
          offset--;
        } else if (offset >= lineText.length ||
            !isWord(lineText.codeUnitAt(offset))) {
          return null;
        }
      }
      var start = offset;
      while (start > 0 && isWord(lineText.codeUnitAt(start - 1))) {
        start--;
      }
      var end = offset;
      while (end < lineText.length && isWord(lineText.codeUnitAt(end))) {
        end++;
      }
      final first = lineText.codeUnitAt(start);
      // 数字开头的片段不是标识符（如 0x1F 的尾部）。
      if (first >= 0x30 && first <= 0x39) return null;
      return (
        name: lineText.substring(start, end),
        start: start,
        end: end,
      );
    } finally {
      painter.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    // 行数从 span 文本里数（高亮按行产出，'\n' 分隔）。
    final lineCount =
        widget.spans.fold<int>(
          0,
          (n, s) => n + '\n'.allMatches(s.text ?? '').length,
        ) +
        1;
    final gutterWidth = lineCount.toString().length * 7.5 + 14;
    _gutterWidth = gutterWidth;
    // 高亮渲染：定义处目标（右栏预览传入，行号 1 起始）与左栏悬停命中
    // 标识符，均拆出独立段叠加黄底黑字（拆分不改 '\n' 计数）。
    var spans = widget.spans;
    final target = widget.highlightTarget;
    if (target != null) {
      final r = findIdentRangeInLine(spans, target.line - 1, target.name);
      if (r != null) {
        spans = applyIdentHighlight(
          spans,
          target.line - 1,
          r.$1,
          r.$2,
          kIdentHighlightStyle,
        );
      }
    }
    final hoverHl = _hoverHl;
    if (hoverHl != null) {
      spans = applyIdentHighlight(
        spans,
        hoverHl.line,
        hoverHl.start,
        hoverHl.end,
        kIdentHighlightStyle,
      );
    }
    const lineNoStyle = TextStyle(
      fontFamily: 'Consolas',
      fontFamilyFallback: ['Courier New', 'monospace'],
      fontSize: 12,
      height: 1.45,
      color: Color(0xFF858585),
    );
    Widget content = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: gutterWidth,
          // 行号列用单个 Text（行号 '\n' 连接）而非逐行 Text：与代码区
          // 同为单段落文本、同样式同 strut，行高由同一布局引擎逐行算出，
          // 不存在两套组件度量差异导致的累积错位。
          child: Text(
            [for (var i = 1; i <= lineCount; i++) '$i'].join('\n'),
            style: lineNoStyle,
            strutStyle: kCodeBrowserStrut,
            textAlign: TextAlign.right,
          ),
        ),
        const SizedBox(width: 10),
        SelectableText.rich(
          TextSpan(children: spans),
          style: kCodeBrowserStyle,
          strutStyle: kCodeBrowserStrut,
        ),
      ],
    );
    if (_hoverEnabled) {
      // MouseRegion 不拦截点击，SelectableText 的选择不受影响。
      content = MouseRegion(
        onHover: _onHover,
        onExit: (_) {
          // 只复位去抖（重新进入同一位置能再次命中）；
          // 高亮粘性保持，不清除（也不影响已打开的预览）。
          _lastHover = null;
        },
        child: content,
      );
    }
    final leftPane = Scrollbar(
      controller: _vController,
      thumbVisibility: true,
      child: SingleChildScrollView(
        controller: _vController,
        padding: const EdgeInsets.all(12),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: content,
        ),
      ),
    );
    // 未打开预览时布局与纯展示形态完全一致。
    if (_peek == null) return leftPane;
    // 打开预览：左栏现有代码区 + 分隔线 + 右栏定义预览，两栏等宽。
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: leftPane),
        Container(width: 1, color: const Color(0xFF3A3A3A)),
        Expanded(child: _buildPeek()),
      ],
    );
  }

  /// 右栏定义预览：标题栏（函数名 + 文件:行号 + Go to REF + 关闭）+
  /// 定义文件完整代码（嵌套 CodeArea 复用行号/高亮/滚动，不传悬停参数
  /// 避免递归预览）。
  Widget _buildPeek() {
    final peek = _peek!;
    final loc = peek.loc;
    final content = widget.refContents?[loc.file];
    // 预览由用户显式关闭（× 或 Go to REF），不随鼠标移出自动收起。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 24,
          decoration: const BoxDecoration(
            color: Color(0xFF252525),
            border: Border(bottom: BorderSide(color: Color(0xFF3A3A3A))),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              Flexible(
                child: Text(
                  peek.func,
                  style: const TextStyle(
                    fontFamily: 'Consolas',
                    fontSize: 11,
                    color: Colors.white70,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  '${loc.file}:${loc.line}',
                  style: const TextStyle(fontSize: 11, color: Colors.white70),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const Spacer(),
              // 正式跳转主视图并关闭预览。
              InkWell(
                onTap: () {
                  _closePeek();
                  widget.onGoToRef!(loc.file, loc.line);
                },
                borderRadius: BorderRadius.circular(3),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2D2D30),
                    borderRadius: BorderRadius.circular(3),
                    border: Border.all(color: const Color(0xFF3A3A3A)),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.north_east, size: 11, color: Colors.white70),
                      SizedBox(width: 4),
                      Text(
                        'Go to REF',
                        style: TextStyle(fontSize: 11, color: Colors.white70),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 6),
              // 仅关闭预览。
              InkWell(
                onTap: _closePeek,
                borderRadius: BorderRadius.circular(8),
                child: const Padding(
                  padding: EdgeInsets.all(3),
                  child: Icon(Icons.close, size: 12, color: Colors.grey),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: content == null
              ? const Center(
                  child: Text(
                    '无法加载定义',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                )
              : CodeArea(
                  spans: SyntaxHighlighter.highlightText(
                    content,
                    'c',
                    baseStyle: kCodeBrowserStyle,
                  ),
                  controller: _peekCtl,
                  // 定义行中该函数/宏名的第一个整词出现标黄底黑字。
                  highlightTarget: (line: loc.line, name: peek.func),
                ),
        ),
      ],
    );
  }
}

/// C 视图的文件层次列表：默认按 isp_common.* 前缀分「共享层」（多节点
/// 共用的类型/工具声明）与「本节点文件」两组；调用方也可经 [groups]
/// 指定任意分组（编组代码页：顶层 / 节点封装 / 算法参考）。小标题灰色，
/// 文件项选中高亮；底部附「导出代码」按钮，默认导出列表全部文件到
/// 指定文件夹，可经 [onExport] 替换为自定义导出逻辑。
class CFileList extends StatelessWidget {
  final List<String> files;
  final String selected;
  final ValueChanged<String> onSelect;

  /// 自定义分组（按列表顺序显示）；null 时用 isp_common 前缀两组默认形态。
  final List<CodeFileGroup>? groups;

  /// 自定义「导出代码」按钮行为；null 时默认把列表全部文件导出到所选目录。
  final Future<void> Function(BuildContext context)? onExport;

  /// 分组标题是否用亮蓝色高亮背景（编组代码页开启，让大类分组更醒目）；
  /// 默认 false 保持灰色小标题原样（节点代码页）。
  final bool highlightGroupTitles;

  const CFileList({
    super.key,
    required this.files,
    required this.selected,
    required this.onSelect,
    this.groups,
    this.onExport,
    this.highlightGroupTitles = false,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveGroups =
        groups ??
        [
          CodeFileGroup('共享层', [
            for (final f in files)
              if (f.startsWith('isp_common.')) f,
          ]),
          CodeFileGroup('本节点文件', [
            for (final f in files)
              if (!f.startsWith('isp_common.')) f,
          ]),
        ];
    return Container(
      color: const Color(0xFF202020),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 6),
              children: [
                for (final g in effectiveGroups)
                  if (g.files.isNotEmpty) ...[
                    _groupTitle(g),
                    for (final f in g.files) _fileItem(f),
                  ],
              ],
            ),
          ),
          _exportBar(context),
        ],
      ),
    );
  }

  /// 底部「导出代码」按钮：选择目标文件夹后导出列表中的全部文件。
  Widget _exportBar(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0xFF3A3A3A))),
      ),
      padding: const EdgeInsets.all(8),
      child: Row(
        children: [
          Expanded(
            child: _barButton(
              Icons.save_alt,
              '导出代码',
              () => onExport != null ? onExport!(context) : _exportAll(context),
            ),
          ),
        ],
      ),
    );
  }

  /// 操作条按钮：图标 + 文字，统一样式。
  Widget _barButton(IconData icon, String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(3),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFF2D2D30),
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: const Color(0xFF3A3A3A)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 13, color: Colors.white70),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(fontSize: 11, color: Colors.white70),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _exportAll(BuildContext context) async {
    final dir = await getDirectoryPath();
    if (dir == null || !context.mounted) return;
    final (ok, failed) = await exportCRefFiles(files, dir);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          failed.isEmpty
              ? '已导出 $ok 个文件到 $dir'
              : '已导出 $ok 个文件到 $dir；失败 ${failed.length} 个：${failed.join('、')}',
        ),
      ),
    );
  }

  Widget _groupTitle(CodeFileGroup group) {
    // 高亮形态：底色整行铺满 + 白字。分组自带 titleColor 时强制使用
    //（如「临时main调用（不导出）」红色标识，与 highlightGroupTitles 无关）；否则跟随
    // highlightGroupTitles（亮蓝 0xFF007ACC，与暗色主题协调）或灰色小标题。
    // 各形态字号与 padding 一致。
    final bg =
        group.titleColor ??
        (highlightGroupTitles ? const Color(0xFF007ACC) : null);
    if (bg != null) {
      return Container(
        width: double.infinity,
        decoration: BoxDecoration(color: bg),
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
        child: Text(
          group.label,
          style: const TextStyle(fontSize: 10, color: Colors.white),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
      child: Text(
        group.label,
        style: const TextStyle(fontSize: 10, color: Colors.grey),
      ),
    );
  }

  Widget _fileItem(String file) {
    final isSelected = file == selected;
    final isHeader = file.endsWith('.h');
    return InkWell(
      onTap: () => onSelect(file),
      child: Container(
        // 左侧在原 padding 10 上多缩进两个字符（字号 11 × 2 = 22），
        // 视觉上从属于上方的大类分组标题。
        padding: const EdgeInsets.fromLTRB(32, 4, 10, 4),
        color: isSelected ? const Color(0xFF37373D) : Colors.transparent,
        child: Row(
          children: [
            Icon(
              isHeader ? Icons.description_outlined : Icons.code,
              size: 12,
              color: isSelected ? Colors.white70 : Colors.grey,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                file,
                style: TextStyle(
                  fontSize: 11,
                  fontFamily: 'Consolas',
                  color: isSelected
                      ? const Color(0xFFD4D4D4)
                      : const Color(0xFF9D9D9D),
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 带编译验证的代码浏览区：工具栏（「编译」按钮，横跨内容区）+ 左栏
/// 文件清单 + 右侧代码区；编译时代码区下方切出 1/4 高度终端面板，
/// 流式打印编译过程。编组代码页与节点代码页（C 视图）共用。
///
/// 流程：点「编译」→ showGroupCompileDialog 选目标/编译器路径 →
/// [preCompileCheck]（可选，如编组导出校验）→ 打开终端清空重来 →
/// [filesLoader] 取「文件名→内容」→ [compileRunner]（缺省
/// compileGroupCFiles）流式编译 → 标题栏状态转成功/失败。
class CodeCompileArea extends StatefulWidget {
  /// 左侧文件清单面板（宽度固定 [leftWidth]）。
  final Widget leftPane;

  /// 右侧代码区（通常为一个 [CodeArea]）。
  final Widget codeArea;

  /// 「编译」按钮与终端面板的 key（调用方各自指定，便于测试区分）。
  final Key buttonKey;
  final Key terminalKey;

  /// 编译时取文件内容（文件名 → 内容）。在编组页为当前已生成的 map；
  /// 在节点页为 loadCRefFile 逐个读入。
  final Future<Map<String, String>> Function() filesLoader;

  /// top 层名（编组页传入，stub main 引用入口函数）；null 时 stub 为
  /// 空 main（节点页：只验证 c_ref 文件集合可编译链接）。
  final String? topName;

  /// 编译执行器注入点（测试替换为假实现；缺省为 compileGroupCFiles）。
  final GroupCompileRunner? compileRunner;

  /// 编译前校验（返回 false 则不打开终端，由校验方弹错误对话框）。
  final Future<bool> Function(BuildContext context)? preCompileCheck;

  final double leftWidth;

  const CodeCompileArea({
    super.key,
    required this.leftPane,
    required this.codeArea,
    required this.buttonKey,
    required this.terminalKey,
    required this.filesLoader,
    this.topName,
    this.compileRunner,
    this.preCompileCheck,
    this.leftWidth = 190,
  });

  @override
  State<CodeCompileArea> createState() => _CodeCompileAreaState();
}

class _CodeCompileAreaState extends State<CodeCompileArea> {
  /// 终端面板是否可见（点「编译」并确认目标后打开）。
  bool _terminalVisible = false;

  /// 编译进行中：此时「编译」按钮禁用、终端关闭按钮禁用。
  bool _compiling = false;

  /// 终端文本（每次编译清空重来）。
  final _terminalText = StringBuffer();

  final _terminalScroll = ScrollController();

  /// 当前/最近一次编译的目标与结果（标题栏状态用）。
  CCompileTarget _terminalTarget = CCompileTarget.x86;
  CCompileResult? _lastResult;

  @override
  void dispose() {
    _terminalScroll.dispose();
    super.dispose();
  }

  /// 流式输出回调：追加文本并自动滚动到底部。
  void _appendTerminal(String chunk) {
    if (!mounted) return;
    setState(() => _terminalText.write(chunk));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_terminalScroll.hasClients) {
        _terminalScroll.jumpTo(_terminalScroll.position.maxScrollExtent);
      }
    });
  }

  /// 点「编译」：弹目标选择对话框 → 校验 → 打开终端面板流式编译。
  Future<void> _startCompile() async {
    if (_compiling) return;
    final choice = await showGroupCompileDialog(context);
    if (choice == null || !mounted) return;
    // 校验不过时不打开终端（由校验方弹错误对话框）。
    if (widget.preCompileCheck != null &&
        !await widget.preCompileCheck!(context)) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _terminalVisible = true;
      _compiling = true;
      _lastResult = null;
      _terminalTarget = choice.target;
      _terminalText.clear();
    });
    final files = await widget.filesLoader();
    if (!mounted) return;
    final runner = widget.compileRunner ?? compileGroupCFiles;
    final result = await runner(
      files,
      choice.target,
      topName: widget.topName,
      compilerPath: choice.compilerPath.isEmpty ? null : choice.compilerPath,
      onOutput: _appendTerminal,
    );
    if (!mounted) return;
    setState(() {
      _compiling = false;
      _lastResult = result;
    });
  }

  /// 工具栏：编译入口（带图标按钮，编译中转进度态并禁用）。
  Widget _buildToolbar() {
    final fg = _compiling ? Colors.white38 : Colors.white70;
    return Container(
      height: 32,
      decoration: const BoxDecoration(
        color: Color(0xFF252525),
        border: Border(bottom: BorderSide(color: Color(0xFF3A3A3A))),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.centerLeft,
      child: InkWell(
        key: widget.buttonKey,
        onTap: _compiling ? null : _startCompile,
        borderRadius: BorderRadius.circular(3),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: const Color(0xFF2D2D30),
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: const Color(0xFF3A3A3A)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_compiling)
                const SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                // 自绘 VS「生成项目」风格图标（锤子 + 砖墙），禁用时降透明度。
                Opacity(
                  opacity: _compiling ? 0.5 : 1.0,
                  child: SvgPicture.asset(
                    'icons/build_project.svg',
                    width: 13,
                    height: 13,
                  ),
                ),
              const SizedBox(width: 6),
              Text(
                _compiling ? '编译中…' : '编译',
                style: TextStyle(fontSize: 11, color: fg),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 终端面板：标题栏（目标 + 状态 + 关闭）+ 可选中等宽输出区。
  Widget _buildTerminal() {
    final statusColor = _compiling
        ? const Color(0xFFD7BA7D)
        : (_lastResult?.success ?? false)
        ? const Color(0xFF4CAF50)
        : const Color(0xFFCF6679);
    final statusText = _compiling
        ? '编译中…'
        : (_lastResult?.success ?? false)
        ? '成功'
        : '失败';
    return Container(
      key: widget.terminalKey,
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
                  '编译 — ${switch (_terminalTarget) {
                    CCompileTarget.x86 => 'X86',
                    CCompileTarget.arm => 'ARM',
                    CCompileTarget.linuxCross => 'Linux 交叉',
                  }}',
                  style: const TextStyle(fontSize: 11, color: Colors.white70),
                ),
                const SizedBox(width: 8),
                Text(
                  statusText,
                  style: TextStyle(fontSize: 11, color: statusColor),
                ),
                const Spacer(),
                // 编译中禁用关闭（选择实现简单的方案，不做进程终止）。
                InkWell(
                  onTap: _compiling
                      ? null
                      : () => setState(() => _terminalVisible = false),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.all(3),
                    child: Icon(
                      Icons.close,
                      size: 12,
                      color: _compiling ? Colors.white24 : Colors.grey,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              controller: _terminalScroll,
              padding: const EdgeInsets.all(8),
              child: SelectableText(
                _terminalText.toString(),
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

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildToolbar(),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: widget.leftWidth, child: widget.leftPane),
              Container(width: 1, color: const Color(0xFF3A3A3A)),
              // 右侧：代码区 3/4 + 终端面板 1/4（终端关闭时代码区占满）。
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: 3, child: widget.codeArea),
                    if (_terminalVisible) ...[
                      Container(height: 1, color: const Color(0xFF3A3A3A)),
                      Expanded(flex: 1, child: _buildTerminal()),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
