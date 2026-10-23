/// ISP Studio「仿真波形」标签页：Flutter 原生数字波形查看器（轻量版
/// GTKWave，渲染风格与示波器模块一致）。
///
/// 一键仿真产出的 wave.vcd 由 [SimWaveStore] 登记并广播代次，本页经
/// vcd_parser 解析后 CustomPaint 绘制：左栏信号名 + 光标处取值，右侧
/// 时间尺 + 数字波形（标量 0/1/x 电平线、总线十六进制块）。交互：
/// 拖动平移、滚轮缩放（以指针位置为锚点）、单击置光标、双击 Zoom Fit。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../providers/isp_studio_state.dart';
import '../codegen/ip_target.dart';
import '../codegen/sim_wave_store.dart';
import '../codegen/vcd_parser.dart';
import '../models/bus_color_decode.dart';
import 'tab_toolbar.dart';

/// 单个信号的边沿计数标注：起点（皮秒）与边沿方向（false=上升沿，
/// true=下降沿）。
typedef WaveCounter = ({int startPs, bool falling});

/// 波形显示行：整个信号行（bit=null）或总线展开后的单个位行。
/// 位行的 [signal] 是从总线派生的 1 位标量信号
///（name 形如 `data [3]`，path 形如 `tb.dut.data[3]`）。
/// [spacer] 为等效模拟通道的占位行：模拟波形占 N 个数字行高时，
/// 主行之后插入 N-1 个占位行保持行索引与纵向坐标对齐。
/// [separator] 为分隔符行（Signal 面板右键插入）：占半个通道高度，
/// 信号面板画分割线、波形区画通栏横线；[signal] 为 null，[sepId]
/// 为唯一标识（列表 key 用）。
class WaveRow {
  final VcdSignal? signal;
  final int? bit;
  final bool spacer;
  final bool separator;
  final String? sepId;

  /// 位展开的分组间隔行（总线 >8 位时每 8 位一道，6px 空白，
  /// 不画线——分组阅读用）。
  final bool gap;
  const WaveRow(this.signal, [this.bit])
      : spacer = false,
        separator = false,
        sepId = null,
        gap = false;
  const WaveRow.spacer(this.signal)
      : bit = null,
        spacer = true,
        separator = false,
        sepId = null,
        gap = false;
  const WaveRow.separator(this.sepId)
      : signal = null,
        bit = null,
        spacer = false,
        separator = true,
        gap = false;
  const WaveRow.gap()
      : signal = null,
        bit = null,
        spacer = false,
        separator = false,
        sepId = null,
        gap = true;
}

/// 分隔符行高（半个通道）。
const double kWaveSeparatorHeight = 12;

/// 位展开分组间隔行高（半通道，空白无线——与带线的分隔符行同高区分
/// 仅靠有无横线）。
const double kWaveGapHeight = 12;

/// 总线数据显示格式（Signal 面板右键菜单设定，按信号路径保存）。
enum BusDisplayFormat { hex, decimal, binary, ascii }

/// 总线位串按格式转文本：hex=0x…（高位 0 补全到信号位宽），decimal=
/// 十进制（高位 0 补全到最大值位数），binary=每 4 位空一格（左侧补 0
/// 到 4 的倍数），ascii=逐字节字符（不可打印显示 ·）。[width] 为信号
/// 位宽（缺省取位串长度）：VCD 值的高位 0 可能被省略，按位宽补齐显示。
/// 含 x/z 时：binary 原样分组（保留 x/z 字符），其余显示 x。
String formatBusBits(String bits, BusDisplayFormat fmt, {int? width}) {
  final unknown = bits.contains('x') || bits.contains('z');
  if (unknown && fmt != BusDisplayFormat.binary) return 'x';
  final w = width ?? bits.length;
  final padded = bits.length < w ? bits.padLeft(w, '0') : bits;
  switch (fmt) {
    case BusDisplayFormat.hex:
      return '0x${bitsToHex(padded).toUpperCase()}';
    case BusDisplayFormat.decimal:
      final maxDigits = w >= bits.length
          ? ((BigInt.one << w) - BigInt.one).toString().length
          : 0;
      final v = BigInt.parse(bits, radix: 2).toString();
      return maxDigits > 0 ? v.padLeft(maxDigits, '0') : v;
    case BusDisplayFormat.binary:
      return _groupBits(padded, unknown);
    case BusDisplayFormat.ascii:
      return _bitsToAscii(bits);
  }
}

/// 左侧补齐到 4 的倍数后每 4 位空一格。
String _groupBits(String bits, bool unknown) {
  final pad = (4 - bits.length % 4) % 4;
  final s = bits.padLeft(bits.length + pad, unknown ? 'x' : '0');
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && i % 4 == 0) buf.write(' ');
    buf.write(s[i]);
  }
  return buf.toString();
}

/// 左侧补 0 到 8 的倍数，逐字节转 ASCII（不可打印字节显示 ·）。
String _bitsToAscii(String bits) {
  final pad = (8 - bits.length % 8) % 8;
  final s = bits.padLeft(bits.length + pad, '0');
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i += 8) {
    final b = int.parse(s.substring(i, i + 8), radix: 2);
    buf.write(b >= 32 && b <= 126 ? String.fromCharCode(b) : '·');
  }
  return buf.toString();
}

/// 总线值输入解析为位串（Bus Search 对话框用；与 [formatBusBits]
/// 显示侧互逆：显示按位宽补零，输入截取低 [width] 位）。缺省十六
/// 进制（可带 0x 前缀，x 字符表示整组 4 位未知）；0b 前缀按二进制
///（允许 x/z）。空串/非法字符/长度越界返回 null。
String? parseBusValueInput(String input, int width) {
  var s = input.trim().toLowerCase();
  if (s.isEmpty || width <= 0) return null;
  if (s.startsWith('0b')) {
    final b = s.substring(2);
    if (b.isEmpty || b.length > width) return null;
    if (!RegExp(r'^[01xz]+$').hasMatch(b)) return null;
    return b.padLeft(width, '0');
  }
  if (s.startsWith('0x')) s = s.substring(2);
  if (s.isEmpty || !RegExp(r'^[0-9a-fx]+$').hasMatch(s)) return null;
  final buf = StringBuffer();
  for (final c in s.split('')) {
    if (c == 'x') {
      buf.write('xxxx');
    } else {
      buf.write(int.parse(c, radix: 16).toRadixString(2).padLeft(4, '0'));
    }
  }
  var bits = buf.toString();
  if (bits.length > width) bits = bits.substring(bits.length - width);
  return bits.padLeft(width, '0');
}

/// 皮秒格式化：`000,000,000,000ps`（12 位补零、千分位逗号）。
String fmtPsGrouped(int ps) {
  final s = ps.toString().padLeft(12, '0');
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return '${buf}ps';
}

/// 皮秒格式化：`000,000,000,000 ps`（12 位补零、千分位逗号，数值与
/// 单位之间空一格；Mcursor.time 与 M 光标时间标签同口径）。
String fmtPsSpaced(int ps) {
  final grouped = fmtPsGrouped(ps);
  return '${grouped.substring(0, grouped.length - 2)} ps';
}

/// 默认展示的信号（时钟/复位 + IP I/O 一批）。
const kWaveSignalNames = [
  'clk',
  'rst_n',
  'in_valid',
  'in_ready',
  'in_sof',
  'in_eol',
  'out_valid',
  'out_ready',
  'out_sof',
  'out_eol',
  'in_data',
  'out_data',
];

class SimWaveTab extends StatefulWidget {
  const SimWaveTab({super.key});

  @override
  State<SimWaveTab> createState() => _SimWaveTabState();
}

class _SimWaveTabState extends State<SimWaveTab> {
  StreamSubscription? _waveSub;

  /// 已解析的 VCD 与对应代次。
  VcdFile? _vcd;
  int _parsedGeneration = -1;

  // 视图状态（时间单位：皮秒）。
  double _psPerPixel = 1000;
  double _startPs = 0;
  int? _cursorPs;
  bool _fitted = false;

  /// M 光标的时间标签（光标顶部红色徽章显示 `M  12.34ns`；右键菜单
  ///「M光标时间标签」开关，关闭时徽章只显示 M）。随 UI.cfg 存取。
  bool _mCursorLabelVisible = true;

  /// M 光标可见性（右键菜单「隐藏M光标」开关）：隐藏时光标位置保留，
  /// 但画布光标线与标签、全局图时间显示均隐藏，依赖 M 光标的菜单
  /// 放置项禁用；左键重新放置光标自动恢复显示。随 UI.cfg 存取。
  bool _mCursorVisible = true;

  /// Find Pre/Next Matches 命中后显示的匹配信息（当前序号/总数，
  /// 序号 1 起；附匹配信号名与格式化值；[edge] 为标量段起点的跳变
  /// 方向：1=上升沿、0=下降沿（以图标显示），总线或 x/z 为 null）。
  /// 手动移动 M 光标、换选信号、载入新波形时清除。
  ({int index, int total, String name, String value, int? edge})?
      _matchInfo;

  /// 工具栏 Go to 序号输入框（显示「当前/总数」，可编辑后点 Go to
  /// 直达第 N 个匹配）；与 [_matchInfo] 同步置空。
  final TextEditingController _gotoCtrl = TextEditingController();

  /// 序号输入框的焦点节点（聚焦时边框变琥珀色）。
  final FocusNode _gotoFocus = FocusNode();

  /// 右键「从M光标线放置时间线」放置的时间线标记（皮秒），按放置顺序编号 T1/T2…。
  final List<int> _timelinesPs = [];

  /// 时间线标签的纵向拖动偏移（键=时间线皮秒值，值=标签顶 y）。
  /// 未拖动的标签按编号轮转默认位。
  final Map<int, double> _tlLabelDy = {};

  /// Dimension 标注：竖线时刻列表（皮秒，全部按时间升序）。
  final List<int> _dimLinesPs = [];

  /// 标注段（from→to 均为竖线时刻，from<to；row 为纵向拖动覆盖的
  /// 行号，null = 自动分配——按 from 升序贪心分配到首个不重叠的行，
  /// 端点相接不算重叠，链式段可同一行）。基线标注法放置的段 from =
  /// 最早竖线（t0），连续标注法放置的段 from = 时间序列上前一条
  /// 竖线——两种标注法在同一竖线体系上混合共存。
  final List<({int from, int to, int? row})> _dimSpans = [];

  /// 标注编辑模式进行中（左键在波形区放线，右键退出）；
  /// [_dimActiveContinue] 仅决定新放线的标注风格（true=连续法：
  /// 前一条线为基线；false=基线法：最早竖线 t0 为基线）。既有段
  /// 不受影响，交互（悬停/拖动/删除）作用于整个体系。
  bool _dimActive = false;
  bool _dimActiveContinue = false;

  /// 右键「从M光标线放置上升/下降沿计数值」的边沿计数，按信号路径
  /// 各自保存：更换信号放置互不影响，仅在同一信号上重新放置时替换。
  final Map<String, WaveCounter> _counters = {};

  /// 左栏选中的信号名（null = 无选中）。
  String? _selectedSignal;

  /// 展开显示每个位的总线（信号路径集合），经 Signal 面板箭头切换。
  final Set<String> _expandedBuses = {};

  /// 总线数据显示格式（Signal 面板总线右键菜单设定，按路径保存；
  /// 缺省 hex）。与等效模拟通道设定一样跨仿真保留。
  final Map<String, BusDisplayFormat> _busFormats = {};

  /// 以等效模拟通道显示的总线（信号路径集合）。
  final Set<String> _analogBuses = {};

  /// 模拟波形纵向占用的数字行数（路径 → 1/10/20，缺省 1），
  /// 经总线右键菜单 X10/X20 设定。
  final Map<String, int> _analogSpan = {};

  /// 总线色彩解码（背景色填充）的色度空间（Signal 面板总线右键菜单
  /// 设定，键=信号路径，缺省关闭）。与总线格式设定一样跨仿真保留。
  final Map<String, BusColorSpace> _busColorSpaces = {};

  /// 色彩解码字节顺序：路径在集合内 = 高字节承载第三通道（L/B/V）；
  /// 缺省高字节 = 第一通道（H/R/Y）。
  final Set<String> _busColorLowFirst = {};

  /// Signal 面板右键菜单控制器与目标信号路径（总线格式/模拟通道/
  /// 分隔符插入共用）；命中分隔符行时 [_menuSepId] 非空。
  final MenuController _busMenuController = MenuController();

  /// Signal 面板空白处（无信号行）右键菜单控制器：列出 Variables
  /// 当前 scope 下未加入显示的信号，点选即加入。
  final MenuController _addSigMenuController = MenuController();
  String? _menuSignalPath;
  String? _menuSepId;

  /// 总线位行派生缓存（path → bit → 派生的 1 位标量信号），新波形时清空。
  final Map<String, Map<int, VcdSignal>> _bitSignalCache = {};

  /// 信号名面板拖动重排：被拖信号路径与累计位移（每满一行高与相邻
  /// 信号交换一次位置）。任意信号行点住即可拖动。
  String? _dragSignalPath;
  double _dragAccum = 0;

  /// 左键按住的信号路径：按下期间信号名文字变亮黄，释放恢复。
  String? _pressedSignalPath;

  /// 显示中的信号路径列表（null = 默认 12 个：时钟/复位 + IP I/O）。
  /// 经 Variables 面板增删后物化。
  List<String>? _displayedPaths;

  /// Scopes 面板中选中的 scope 路径（默认 testbench 顶层）。
  String _selectedScopePath = '';

  /// Scopes 树中折叠的 scope 路径集合（默认全部展开）。
  final Set<String> _collapsedScopes = {};

  @override
  void initState() {
    super.initState();
    _waveSub = SimWaveStore.instance.onWave.listen((_) {
      setState(() => _fitted = false); // 新波形重新 Zoom Fit
    });
    // 序号输入框聚焦/失焦时重绘边框色。
    _gotoFocus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _waveSub?.cancel();
    _namesScroll.dispose();
    _gotoCtrl.dispose();
    _gotoFocus.dispose();
    super.dispose();
  }

  VcdFile? _ensureParsed() {
    final store = SimWaveStore.instance;
    if (_parsedGeneration != store.generation) {
      final bytes = store.currentVcd;
      _vcd = bytes == null ? null : parseVcd(String.fromCharCodes(bytes));
      _parsedGeneration = store.generation;
      // 新波形：恢复默认显示信号与默认选中 scope
      _displayedPaths = null;
      _timelinesPs.clear();
      _counters.clear();
      _matchInfo = null;
      _gotoCtrl.text = '';
      _dimLinesPs.clear();
      _dimSpans.clear();
      _dimActive = false;
      _dimActiveContinue = false;
      _expandedBuses.clear();
      _bitSignalCache.clear();
      final r = _vcd?.root;
      _selectedScopePath = (r != null && r.children.isNotEmpty)
          ? r.children.first.path
          : '';
    }
    return _vcd;
  }

  List<VcdSignal> _displaySignals(VcdFile vcd) {
    final paths = _displayedPaths;
    if (paths == null) {
      final tops = vcd.topScopeSignals();
      final byName = {for (final s in tops) s.name: s};
      final picked = [
        for (final n in kWaveSignalNames)
          if (byName.containsKey(n)) byName[n]!,
      ];
      return picked.isNotEmpty ? picked : tops;
    }
    final byPath = {for (final s in vcd.signals) s.path: s};
    return [
      for (final p in paths)
        if (byPath.containsKey(p)) byPath[p]!,
    ];
  }

  /// 从总线派生单个位的 1 位标量信号（带缓存）。位串高位在前：
  /// bit i（0=LSB）位于倒数第 i+1 字符；x/z 位按 x 处理。
  VcdSignal _bitSignal(VcdSignal bus, int bit) {
    final byBit = _bitSignalCache.putIfAbsent(bus.path, () => {});
    return byBit.putIfAbsent(bit, () {
      final sig = VcdSignal(
        path: '${bus.path}[$bit]',
        name: '${bus.name} [$bit]',
        id: bus.id,
        width: 1,
        vcdType: bus.vcdType,
      );
      for (final c in bus.changes) {
        // iverilog 转储总线会去掉前导零（如 b0）：位串短于总线宽度时
        // 缺失的高位按 0 补齐（与 bitsToHex 的解析口径一致）。
        final idx = c.bits.length - 1 - bit;
        final ch = idx < 0 ? '0' : c.bits[idx];
        final v = ch == '1' ? '1' : (ch == '0' ? '0' : 'x');
        // 该位值未变时不产生条目——否则绘制侧在每次总线跳变都画一条
        // 全高沿竖线，位行上出现大量假"尖峰"（实测 24 位总线每条位行
        // 约 7 成条目为值未变的幻沿）。
        if (sig.changes.isNotEmpty && sig.changes.last.bits == v) continue;
        sig.changes.add(VcdChange(c.time, v));
      }
      return sig;
    });
  }

  /// 分隔符序号（生成 `#sep:` 标记的唯一后缀；无需归零）。
  int _sepCounter = 0;

  /// 在当前信号上方/下方插入分隔符（显示列表未物化时先物化）。
  /// 分隔符以 `#sep:<n>` 标记存进显示路径列表，拖动重排随列表移动。
  void _insertSeparator(String signalPath, bool above) {
    setState(() {
      final cur =
          _displayedPaths ?? _displaySignals(_vcd!).map((x) => x.path).toList();
      final idx = cur.indexOf(signalPath);
      if (idx < 0) return;
      cur.insert(above ? idx : idx + 1, '#sep:${_sepCounter++}');
      _displayedPaths = cur;
    });
  }

  /// 显示行列表：整个信号行 + 模拟通道占位行 + 展开总线的逐位行
  ///（高位在前）+ 分隔符行（`#sep:` 标记）。显示列表已物化时按
  /// 路径顺序走（含分隔符），否则取默认信号集。
  List<WaveRow> _displayRows(VcdFile vcd) {
    List<WaveRow> signalRows(VcdSignal s) => [
          WaveRow(s),
          if (s.isBus && _analogBuses.contains(s.path))
            for (var k = 1; k < (_analogSpan[s.path] ?? 1); k++)
              WaveRow.spacer(s),
          // 位展开：超过 8 位的总线按每 8 位插一道分组间隔（空白行）。
          if (s.isBus && _expandedBuses.contains(s.path))
            for (var b = s.width - 1; b >= 0; b--) ...[
              if (s.width > 8 && (b + 1) % 8 == 0 && b < s.width - 1)
                const WaveRow.gap(),
              WaveRow(_bitSignal(s, b), b),
            ],
        ];
    final paths = _displayedPaths;
    if (paths == null) {
      return [for (final s in _displaySignals(vcd)) ...signalRows(s)];
    }
    final byPath = {for (final s in vcd.signals) s.path: s};
    return [
      for (final p in paths)
        if (p.startsWith('#sep:'))
          WaveRow.separator(p)
          else if (byPath.containsKey(p))
            ...signalRows(byPath[p]!),
    ];
  }

  void _zoomFit(VcdFile vcd, double width) {
    final span = math.max(vcd.endTime, 1);
    setState(() {
      // 与全局图（ppp = span / w）同口径：主视图终止时间恰为 endTime。
      _psPerPixel = span / math.max(width, 1);
      _startPs = 0;
    });
    _fitted = true;
  }

  @override
  Widget build(BuildContext context) {
    final vcd = _ensureParsed();
    return Container(
      color: const Color(0xFF1E1E1E),
      child: Column(
        children: [
          _buildToolbar(),
          Expanded(
            child: vcd == null
                ? const Center(
                    child: Text(
                      '暂无波形：先在 IP 标签页运行「一键仿真」',
                      style: TextStyle(fontSize: 13, color: Colors.grey),
                    ),
                  )
                : _buildWaveArea(vcd),
          ),
        ],
      ),
    );
  }

  /// 工具栏（GTKWave 风格文本按钮）：Open/Save VCD │ Import/Save
  /// UI.cfg │ Zoom In/Out/Fit │ Place TimeLine、Jump to Pre/Next
  /// TimeLine │ Find Pre/Next Matches（对应方向匹配到头时置灰）│
  /// 序号输入框（显示「当前/总数」，输入序号回车直达第 N 个匹配）。
  Widget _buildToolbar() {
    // Place TimeLine 仅当 M 光标在当前显示区域内时可用（区域外放置
    // 会放到看不见的位置；「隐藏M光标」隐藏时按无光标处理）。
    final cursor = _mCursorVisible ? _cursorPs : null;
    final cursorInView = cursor != null &&
        cursor >= _startPs &&
        cursor <= _startPs + _lastWaveWidth * _psPerPixel;
    final hasTimeline = _timelinesPs.isNotEmpty;
    // Find Pre/Next Matches：M 光标在视口内且有选中信号，且对应方向
    // 上还有匹配跳变起点（到头置灰）。
    final vcd = _vcd;
    final findSig = (vcd == null || _selectedSignal == null)
        ? null
        : vcd.signals.where((s) => s.name == _selectedSignal).firstOrNull;
    final canFindPre = cursorInView &&
        findSig != null &&
        hasMatchInDirection(findSig, _cursorPs!, false);
    final canFindNext = cursorInView &&
        findSig != null &&
        hasMatchInDirection(findSig, _cursorPs!, true);
    // Go to：光标在视口内且选中信号有变化记录即可（直达任意序号，
    // 不受方向到头限制）。
    final canGoTo =
        cursorInView && findSig != null && findSig.changes.isNotEmpty;
    return ispTabToolbarRow(
      children: [
        _textBtn('Open VCD', _openVcd, 'icons/folder-opened.png'),
        _textBtn('Save VCD', _vcd == null ? null : _saveVcd,
            'icons/save.png'),
        _toolbarSep(),
        _textBtn('Import UI.cfg', _vcd == null ? null : _importUiCfg,
            'icons/voice-mode-download.png'),
        _textBtn('Save UI.cfg', _vcd == null ? null : _saveUiCfg,
            'icons/right-panel-hide.png'),
        _toolbarSep(),
        _textBtn('Zoom In', () => _zoomStep(1 / 1.5), 'icons/zoom-in.png'),
        _textBtn('Zoom Out', () => _zoomStep(1.5), 'icons/zoom-out.png'),
        _textBtn('Zoom Fit', () {
          final vcd = _vcd;
          if (vcd != null) _zoomFit(vcd, _lastWaveWidth);
        }, 'icons/screen-full.png'),
        _toolbarSep(),
        _textBtn('Place TimeLine', cursorInView ? _placeTimeline : null,
            'icons/git-commit.png'),
        _textBtn('Jump to Pre TimeLine',
            hasTimeline ? () => _jumpTimeline(false) : null,
            'icons/reply.png'),
        _textBtn('Jump to Next TimeLine',
            hasTimeline ? () => _jumpTimeline(true) : null,
            'icons/forward.png'),
        _toolbarSep(),
        _textBtn('Find Pre Matches',
            canFindPre ? () => _findMatch(false) : null,
            'icons/chevron-left.png'),
        _textBtn('Find Next Matches',
            canFindNext ? () => _findMatch(true) : null,
            'icons/chevron-right.png'),
        const SizedBox(width: 4),
        // 「当前/总数」序号输入框（与 Find Pre/Next 同组）：显示匹配
        // 进度，直接输入序号后回车直达第 N 个匹配位置。边框由外层
        // Container 绘制（InputDecorator 边框的纵向定位随主题/内容
        // 高度浮动），保证在工具栏行高内严格居中。
        Container(
          // 宽度按 15 个 14px Consolas 字符（≈7.7px/字符）+ 光标余量；
          // 高度 22（上下各内缩 2px，行内保持居中）。
          width: 120,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border.all(
              color: !canGoTo
                  ? const Color(0xFF2A2A2A)
                  : _gotoFocus.hasFocus
                      ? const Color(0xFFFFB300)
                      : const Color(0xFF3A3A3A),
            ),
            borderRadius: BorderRadius.circular(2),
          ),
          child: Transform.translate(
            // 文本在框内整体上移 4px（视觉校准）。
            offset: const Offset(0, -4),
            child: TextField(
              controller: _gotoCtrl,
              focusNode: _gotoFocus,
              enabled: canGoTo,
              textAlignVertical: TextAlignVertical.center,
              style: const TextStyle(
                fontSize: 14,
                fontFamily: 'Consolas',
                color: Colors.white,
              ),
              textAlign: TextAlign.center,
              decoration: const InputDecoration(
                // 装饰器塌缩到恰好包裹文字（无标签/边框的顶部预留），
                // 文字由外层 Container 在框内居中。
                isCollapsed: true,
                border: InputBorder.none,
                hintText: '0/0',
                hintStyle: TextStyle(fontSize: 14, color: Colors.white24),
                contentPadding: EdgeInsets.zero,
              ),
              onSubmitted: canGoTo ? (_) => _gotoMatch() : null,
            ),
          ),
        ),
        // Bus search：弹出 Bus Search 对话框（总线信号下拉 + 值输入，
        // 实时匹配计数；确认跳转首个匹配并同步匹配信息显示）。
        _textBtn('Bus search', _vcd == null ? null : _openBusSearch,
            'icons/search.png'),
        _toolbarSep(),
        // Dimension Baseline：进入基线标注模式（实心黄线跟随鼠标，
        // 左键依次放基准线/测量线，右键退出）。
        _textBtn(
            'Dimension Baseline',
            _vcd == null ? null : _startDimBaseline,
            'icons/dim-base.png'),
        // Dimension Continue：进入连续标注模式（与基线标注同交互，
        // 相邻两线成组：前一条线为后一条线的基线）。
        _textBtn(
            'Dimension Continue',
            _vcd == null ? null : _startDimContinue,
            'icons/dim-continue.png'),
        _toolbarSep(),
        const Spacer(),
        // 时间线按钮区：每放置一条时间线自动生成一个 T 按钮（琥珀色，
        // 与画布标记同色），点击跳转居中。
        for (var i = 0; i < _timelinesPs.length; i++) _timelineBtn(i),
      ],
    );
  }

  /// 时间线按钮（琥珀色 Tn，与画布时间线标记同色）：点击跳转居中，
  /// Tooltip 显示完整时间。
  Widget _timelineBtn(int i) {
    final t = _timelinesPs[i];
    return Tooltip(
      message: 'T${i + 1}  ${fmtPsGrouped(t)}',
      child: InkWell(
        onTap: () => _centerOn(t),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Text(
            'T${i + 1}',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              fontFamily: 'Consolas',
              color: _WaveOverlayPainter._tlColor,
            ),
          ),
        ),
      ),
    );
  }

  /// 图标按钮（codicon 图标，与代码页工具栏同规格 28px 无内边距；
  /// 文字说明在 Tooltip 气泡；禁用置灰）。
  Widget _textBtn(String label, VoidCallback? onPressed, String icon) {
    final dim = onPressed == null;
    return Tooltip(
      message: label,
      child: InkWell(
        onTap: onPressed,
        child: Image.asset(
          icon,
          width: 28,
          height: 28,
          color: dim ? Colors.white24 : null,
        ),
      ),
    );
  }

  /// 工具栏分隔线（1px 竖线）。
  Widget _toolbarSep() => Container(
        width: 1,
        height: 16,
        margin: const EdgeInsets.symmetric(horizontal: 4),
        color: const Color(0xFF3A3A3A),
      );

  // ---- 工具栏动作 ----

  /// Open VCD：打开 VCD 文件并显示（经 SimWaveStore 广播新代次）。
  Future<void> _openVcd() async {
    final file = await openFile(acceptedTypeGroups: [
      const XTypeGroup(label: 'VCD 波形', extensions: ['vcd']),
    ]);
    if (file == null) return;
    SimWaveStore.instance.registerWave(await File(file.path).readAsBytes());
  }

  /// Save VCD：当前波形字节写盘。
  Future<void> _saveVcd() async {
    final bytes = SimWaveStore.instance.currentVcd;
    if (bytes == null) return;
    final loc = await getSaveLocation(
      suggestedName: 'wave.vcd',
      acceptedTypeGroups: [
        const XTypeGroup(label: 'VCD 波形', extensions: ['vcd']),
      ],
    );
    if (loc == null) return;
    await File(loc.path).writeAsBytes(bytes);
  }

  /// UI 配置（显示信号顺序/选中/总线展开与格式/模拟通道/计数器/时间线/
  /// 视图位置）存取为 JSON（.cfg）。
  Future<void> _saveUiCfg() async {
    final loc = await getSaveLocation(
      suggestedName: 'UI.cfg',
      acceptedTypeGroups: [
        const XTypeGroup(label: 'UI 配置', extensions: ['cfg']),
      ],
    );
    if (loc == null) return;
    final json = <String, Object?>{
      'displayedPaths': _displayedPaths,
      'selectedSignal': _selectedSignal,
      'selectedScopePath': _selectedScopePath,
      'expandedBuses': [..._expandedBuses],
      'busFormats': {for (final e in _busFormats.entries) e.key: e.value.name},
      'analogBuses': [..._analogBuses],
      'analogSpans': _analogSpan,
      'busColorSpaces': {
        for (final e in _busColorSpaces.entries) e.key: e.value.name
      },
      'busColorLowFirst': [..._busColorLowFirst],
      'timelinesPs': _timelinesPs,
      'mCursorLabel': _mCursorLabelVisible,
      'mCursorVisible': _mCursorVisible,
      'dimLinesPs': _dimLinesPs,
      'dimSpans': [
        for (final s in _dimSpans)
          {'from': s.from, 'to': s.to, if (s.row != null) 'row': s.row},
      ],
      'tlLabelDy': {
        for (final e in _tlLabelDy.entries) '${e.key}': e.value
      },
      'counters': {
        for (final e in _counters.entries)
          e.key: {'startPs': e.value.startPs, 'falling': e.value.falling},
      },
      'cursorPs': _cursorPs,
      'psPerPixel': _psPerPixel,
      'startPs': _startPs,
    };
    await File(loc.path).writeAsString(jsonEncode(json));
  }

  /// 导入 UI.cfg（缺键保持现状；路径不存在的信号自然不显示）。
  Future<void> _importUiCfg() async {
    final file = await openFile(acceptedTypeGroups: [
      const XTypeGroup(label: 'UI 配置', extensions: ['cfg']),
    ]);
    if (file == null) return;
    try {
      final m = jsonDecode(await File(file.path).readAsString())
          as Map<String, Object?>;
      setState(() {
        if (m['displayedPaths'] is List) {
          _displayedPaths = [
            for (final p in m['displayedPaths'] as List) '$p'
          ];
        }
        _selectedSignal = m['selectedSignal'] as String?;
        if (m['selectedScopePath'] is String) {
          _selectedScopePath = m['selectedScopePath'] as String;
        }
        if (m['expandedBuses'] is List) {
          _expandedBuses
            ..clear()
            ..addAll([for (final p in m['expandedBuses'] as List) '$p']);
        }
        if (m['busFormats'] is Map) {
          _busFormats
            ..clear()
            ..addAll({
              for (final e in (m['busFormats'] as Map).entries)
                '${e.key}':
                    BusDisplayFormat.values.asNameMap()['${e.value}'] ??
                        BusDisplayFormat.hex,
            });
        }
        if (m['analogBuses'] is List) {
          _analogBuses
            ..clear()
            ..addAll([for (final p in m['analogBuses'] as List) '$p']);
        }
        if (m['analogSpans'] is Map) {
          _analogSpan
            ..clear()
            ..addAll({
              for (final e in (m['analogSpans'] as Map).entries)
                '${e.key}': (e.value as num).toInt(),
            });
        }
        if (m['busColorSpaces'] is Map) {
          _busColorSpaces
            ..clear()
            ..addAll({
              for (final e in (m['busColorSpaces'] as Map).entries)
                '${e.key}':
                    BusColorSpace.values.asNameMap()['${e.value}'] ??
                        BusColorSpace.none,
            });
          _busColorSpaces.removeWhere((_, v) => v == BusColorSpace.none);
        }
        if (m['busColorLowFirst'] is List) {
          _busColorLowFirst
            ..clear()
            ..addAll([for (final p in m['busColorLowFirst'] as List) '$p']);
        }
        if (m['timelinesPs'] is List) {
          _timelinesPs
            ..clear()
            ..addAll(
                [for (final t in m['timelinesPs'] as List) (t as num).toInt()]);
        }
        if (m['mCursorLabel'] is bool) {
          _mCursorLabelVisible = m['mCursorLabel'] as bool;
        }
        if (m['mCursorVisible'] is bool) {
          _mCursorVisible = m['mCursorVisible'] as bool;
        }
        if (m['dimLinesPs'] is List) {
          _dimLinesPs
            ..clear()
            ..addAll(
                [for (final t in m['dimLinesPs'] as List) (t as num).toInt()])
            ..sort();
        }
        // 标注段（旧版 cfg 的 dimArrowY 组偏移口径已废弃，忽略）。
        if (m['dimSpans'] is List) {
          _dimSpans
            ..clear()
            ..addAll([
              for (final s in m['dimSpans'] as List)
                (
                  from: ((s as Map)['from'] as num).toInt(),
                  to: ((s)['to'] as num).toInt(),
                  row: ((s)['row'] as num?)?.toInt(),
                ),
            ]);
        }
        if (m['tlLabelDy'] is Map) {
          _tlLabelDy
            ..clear()
            ..addAll({
              for (final e in (m['tlLabelDy'] as Map).entries)
                int.parse('${e.key}'): (e.value as num).toDouble(),
            });
        }
        if (m['counters'] is Map) {
          _counters
            ..clear()
            ..addAll({
              for (final e in (m['counters'] as Map).entries)
                '${e.key}': (
                  startPs: ((e.value as Map)['startPs'] as num).toInt(),
                  falling: (e.value)['falling'] == true,
                ),
            });
        }
        _cursorPs = (m['cursorPs'] as num?)?.toInt();
        _matchInfo = null; // 光标被恢复值覆盖：匹配序号失效
        _gotoCtrl.text = '';
        if (m['psPerPixel'] is num) {
          _psPerPixel = (m['psPerPixel'] as num).toDouble();
        }
        if (m['startPs'] is num) {
          _startPs = (m['startPs'] as num).toDouble();
        }
      });
    } catch (_) {
      // 解析失败：忽略（状态不变）。
    }
  }

  /// 以视口中心为锚点缩放（Zoom In/Out 共用）。
  void _zoomStep(double factor) {
    final vcd = _vcd;
    if (vcd == null) return;
    setState(() {
      final w = math.max(_lastWaveWidth, 1.0);
      final span = vcd.endTime.toDouble();
      final maxPpp = span / w;
      final newPpp = (_psPerPixel * factor).clamp(0.5, maxPpp);
      final ratio = newPpp / _psPerPixel;
      final anchor = _startPs + w / 2 * _psPerPixel;
      _startPs = (anchor - (anchor - _startPs) * ratio)
          .clamp(0.0, math.max(0.0, span - w * newPpp))
          .toDouble();
      _psPerPixel = newPpp;
    });
  }

  /// Place TimeLine：在 M 光标处放置时间线（与右键菜单同口径）。
  void _placeTimeline() {
    final c = _cursorPs;
    if (c != null) setState(() => _timelinesPs.add(c));
  }

  /// 视图中心对齐到指定时间（时间线跳转共用）。
  void _centerOn(int ps) {
    final vcd = _vcd;
    if (vcd == null) return;
    setState(() {
      final span = vcd.endTime.toDouble();
      _startPs = (ps - _lastWaveWidth * _psPerPixel / 2)
          .clamp(0.0, math.max(0.0, span - _lastWaveWidth * _psPerPixel))
          .toDouble();
    });
  }

  /// Dimension Baseline：进入标注编辑模式（基线标注法）。已有标注
  /// 保留供调整（悬停高亮 + Del 删除）；模式下实心黄线跟随鼠标
  /// 移动，左键放置竖线并从最早竖线（t0）到新线生成标注段（双头
  /// 横线 + ΔT 标注），右键退出。与连续标注法放置的段混合共存于
  /// 同一竖线体系。
  void _startDimBaseline() {
    if (_vcd == null) return;
    setState(() {
      _dimActive = true;
      _dimActiveContinue = false;
    });
  }

  /// Dimension Continue：进入标注编辑模式（连续标注法，与基线法
  /// 同一套交互）：左键放置竖线并从时间序列上前一条竖线到新线
  /// 生成标注段（前一条线为后一条线的基线）。
  void _startDimContinue() {
    if (_vcd == null) return;
    setState(() {
      _dimActive = true;
      _dimActiveContinue = true;
    });
  }

  /// 左键放置竖线并按当前标注风格生成标注段：基线法段从最早竖线
  ///（t0）起，连续法段从时间序列上前一条竖线起（首条线/新的最早
  /// 线只作基准不产生段）。同一时刻已有竖线时不重复放置。
  void _dimPlaceLine(int ps) {
    setState(() {
      if (_dimLinesPs.contains(ps)) return;
      _dimLinesPs.add(ps);
      _dimLinesPs.sort();
      if (_dimActiveContinue) {
        final i = _dimLinesPs.indexOf(ps);
        if (i > 0) {
          _dimSpans.add((from: _dimLinesPs[i - 1], to: ps, row: null));
        }
      } else {
        final t0 = _dimLinesPs.first;
        if (ps != t0) _dimSpans.add((from: t0, to: ps, row: null));
      }
    });
  }

  /// 拖动竖线到新的时刻（已吸附跳变沿）：关联标注段的端点跟随
  ///（跨过相邻线导致端点交换时起止归一化为 from<to）；排序在拖动
  /// 结束时统一进行（[_dimSortLines]）。
  void _dimMoveLine(int index, int ps) {
    setState(() {
      final old = _dimLinesPs[index];
      if (old == ps) return;
      _dimLinesPs[index] = ps;
      for (var i = 0; i < _dimSpans.length; i++) {
        final s = _dimSpans[i];
        if (s.from != old && s.to != old) continue;
        var from = s.from == old ? ps : s.from;
        var to = s.to == old ? ps : s.to;
        if (from > to) {
          final t = from;
          from = to;
          to = t;
        }
        _dimSpans[i] = (from: from, to: to, row: s.row);
      }
    });
  }

  /// 竖线按时间升序（拖动竖线结束时调用；放置时已即时排序）。
  /// 标注段以时刻值为端点，排序不影响段本身。
  void _dimSortLines() => _dimLinesPs.sort();

  /// Del 删除高亮竖线：以其为端点的标注段一并删除。
  void _dimDeleteLine(int index) {
    setState(() {
      final ps = _dimLinesPs.removeAt(index);
      _dimSpans.removeWhere((s) => s.from == ps || s.to == ps);
    });
  }

  /// Del 删除高亮标注段（竖线保留）。
  void _dimDeleteSpan(int index) {
    setState(() => _dimSpans.removeAt(index));
  }

  /// 标注段纵向拖动：覆盖行号（自动分配见
  /// [_WaveOverlayPainter.dimSpanRows]）。
  void _dimSetSpanRow(int index, int row) {
    setState(() {
      final s = _dimSpans[index];
      _dimSpans[index] = (from: s.from, to: s.to, row: row);
    });
  }

  /// 右键菜单「删除标注」：清除全部标注（竖线与标注段）。
  void _dimClearAll() {
    setState(() {
      _dimLinesPs.clear();
      _dimSpans.clear();
    });
  }

  /// Bus search：弹出 Bus Search 对话框（下拉选定总线信号——含位域
  /// 显示，输入总线值，实时显示匹配数量）。确认后选中该信号并跳转
  /// 首个匹配（匹配信息区与序号输入框同步显示，与 Find Pre/Next
  /// Matches 同口径）。
  void _openBusSearch() {
    final vcd = _vcd;
    if (vcd == null) return;
    final buses = [for (final s in _displaySignals(vcd)) if (s.isBus) s];
    final selPath = _selectedSignal == null
        ? null
        : buses.where((s) => s.name == _selectedSignal).firstOrNull?.path;
    showDialog(
      context: context,
      builder: (_) => _BusSearchDialog(
        buses: buses,
        initialPath: selPath,
        onApply: (sig, bits, matches) {
          setState(() => _selectedSignal = sig.name);
          _gotoMatchIndex(matches, 1, sig, bits, sig.name);
        },
      ),
    );
  }

  /// Jump to Pre/Next TimeLine：以视口中心为参照找上一条/下一条
  /// 时间线，环绕取首尾。
  void _jumpTimeline(bool next) {
    if (_timelinesPs.isEmpty) return;
    final center = _startPs + _lastWaveWidth / 2 * _psPerPixel;
    final sorted = [..._timelinesPs]..sort();
    final target = next
        ? sorted.firstWhere((t) => t > center, orElse: () => sorted.first)
        : sorted.lastWhere((t) => t < center, orElse: () => sorted.last);
    _centerOn(target);
  }

  /// 选中信号上「值等于 [target]」的全部跳变起点（升序；Go to 与
  /// Find Pre/Next Matches、Bus Search 的匹配集口径）。位串比较经
  /// [busBitsEqual] 规范化——兼容 VCD 省略高位的短记法（用户照显示
  /// 补全输入的值与 `b0 "` 这类短记法存储也能匹配）。
  static List<int> _matchTimesOf(VcdSignal sig, String target) {
    final changes = sig.changes;
    return [
      for (var i = 0; i < changes.length; i++)
        if (busBitsEqual(changes[i].bits, target) &&
            (i == 0 || !busBitsEqual(changes[i - 1].bits, target)))
          changes[i].time,
    ];
  }

  /// 匹配值的显示文本：总线按 Signal 右键菜单设定的格式（缺省 hex，
  /// 高位 0 按位宽补全）；标量仅 x/z 经此文本（0/1 段起点为跳变沿，
  /// 以边沿图标显示，见 [_gotoMatchIndex] 的 edge）。
  String _matchValueText(VcdSignal sig, String target) => sig.isBus
      ? formatBusBits(
          target,
          _busFormats[sig.path] ?? BusDisplayFormat.hex,
          width: sig.width,
        )
      : target;

  /// Go to：把光标移到第 [index]（1 起）个匹配跳变起点并居中，
  /// 同步匹配信息区与序号输入框。
  void _gotoMatchIndex(List<int> matches, int index, VcdSignal sig,
      String target, String name) {
    final found = matches[index - 1];
    // 匹配信号名：总线附位宽（与 Signal 面板 `name [w-1:0]` 同风格）。
    final displayName = sig.isBus ? '$name [${sig.width - 1}:0]' : name;
    setState(() {
      _cursorPs = found;
      _matchInfo = (
        index: index,
        total: matches.length,
        name: displayName,
        value: _matchValueText(sig, target),
        // 标量段起点即跳变沿：值 1 上升沿、值 0 下降沿（图标显示）。
        edge: sig.isBus ? null : (target == '1' ? 1 : target == '0' ? 0 : null),
      );
      _gotoCtrl.text = '$index/${matches.length}';
    });
    _centerOn(found);
  }

  /// Go to 按钮/回车：解析输入框的匹配序号（取 '/' 前的整数，越界
  /// 钳位到 1..总数），跳到目标匹配位置。
  void _gotoMatch() {
    final vcd = _vcd;
    final cursor = _cursorPs;
    final name = _selectedSignal;
    if (vcd == null || cursor == null || name == null) return;
    final sig = vcd.signals.where((s) => s.name == name).firstOrNull;
    if (sig == null || sig.changes.isEmpty) return;
    final target = valueAt(sig, cursor);
    final matches = _matchTimesOf(sig, target);
    if (matches.isEmpty) return;
    // 输入解析：取 '/' 前部分；无数字（如空串）默认当前序号或 1。
    final raw = _gotoCtrl.text.split('/').first.trim();
    var n = int.tryParse(raw) ?? _matchInfo?.index ?? 1;
    n = n.clamp(1, matches.length);
    FocusManager.instance.primaryFocus?.unfocus();
    _gotoMatchIndex(matches, n, sig, target, name);
  }

  /// Find Pre/Next Matches：从 M 光标起找选中信号上一个/下一个
  /// 「等于光标处取值」的跳变起点（不环绕：该方向到端点仍找不到则
  /// 不动作），命中后光标移去并居中显示。
  void _findMatch(bool forward) {
    final vcd = _vcd;
    final cursor = _cursorPs;
    final name = _selectedSignal;
    if (vcd == null || cursor == null || name == null) return;
    final sig = vcd.signals.where((s) => s.name == name).firstOrNull;
    if (sig == null || sig.changes.isEmpty) return;
    final target = valueAt(sig, cursor);
    final changes = sig.changes;
    // 跳变起点：值等于目标且前一时刻不等于目标（排除值保持的重复
    // 记录，保证落在新值段的开始沿上；位串比较经 busBitsEqual
    // 规范化——兼容 VCD 省略高位的短记法）。
    bool isStart(int i) =>
        busBitsEqual(changes[i].bits, target) &&
        (i == 0 || !busBitsEqual(changes[i - 1].bits, target));
    int? found;
    if (forward) {
      for (var i = 0; i < changes.length; i++) {
        final t = changes[i].time;
        if (t <= cursor) continue;
        if (isStart(i)) {
          found = t;
          break;
        }
      }
    } else {
      for (var i = changes.length - 1; i >= 0; i--) {
        final t = changes[i].time;
        if (t >= cursor) continue;
        if (isStart(i)) {
          found = t;
          break;
        }
      }
    }
    if (found != null) {
      final matches = _matchTimesOf(sig, target);
      _gotoMatchIndex(
          matches, matches.indexOf(found) + 1, sig, target, name);
    }
  }

  // 面板尺寸（边界可拖动调整，见 _vDragHandle/_hDragHandle）。
  double _scopesWidth = 190;
  double _namesWidth = 170;
  static const double _kOverviewHeight = 64;

  /// Scopes 树占左上面板的高度比例（横边界拖动调整）。
  double _scopesRatio = 0.45;

  /// 最近一次布局的波形区宽度（工具栏 Zoom/时间线跳转的视口宽度来源）。
  double _lastWaveWidth = 800;

  /// 信号名列表与波形区的共享垂直滚动控制器：列表滚动经
  /// CustomPainter(repaint:) 驱动波形行偏移重绘，无需 setState。
  final ScrollController _namesScroll = ScrollController();

  /// 全局图拖动：指针相对窗口左沿的时间偏移（窗口外按下时取窗口中心）。
  double _grabOffsetPs = 0;

  Widget _buildWaveArea(VcdFile vcd) {
    final signals = _displaySignals(vcd);
    final rows = _displayRows(vcd);
    return LayoutBuilder(
      builder: (context, constraints) {
        final waveWidth =
            constraints.maxWidth - _namesWidth - _scopesWidth - 14;
        _lastWaveWidth = waveWidth;
        if (!_fitted && waveWidth > 0) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !_fitted) _zoomFit(vcd, waveWidth);
          });
        }
        return Column(
          children: [
            SizedBox(
              height: _kOverviewHeight,
              child: Row(
                children: [
                  // 全局图左侧单元格：无匹配信息时整格显示 M 光标时间；
                  // Find Pre/Next Matches 命中后切分为左右等宽两部——
                  // 左侧 M 光标时间，右侧上行为「Matched 序号/总数」、
                  // 下行为匹配信号名与匹配值（白色，中对齐），两侧字体
                  // 一致。
                  SizedBox(
                    width: _scopesWidth + _namesWidth + 14,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 10, right: 10),
                      child: Row(
                        children: [
                          // 左部：MCur 时间（两行：首行「MCur.T」红底
                          // 徽章标签，次行时间值；垂直居中）。
                          Expanded(
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  // 「Mcursor」徽章：红底改为字形的红色
                                  // 2px 描边（描边层在下、白色填充在上，
                                  // 与总线数值描边同法；与波形上 M 标识
                                  // 同色）。
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Stack(
                                        children: [
                                          Text(
                                            'Mcursor',
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontFamily: 'Consolas',
                                              height: 1.0,
                                              foreground: Paint()
                                                ..style =
                                                    PaintingStyle.stroke
                                                ..strokeWidth = 2
                                                ..strokeJoin =
                                                    StrokeJoin.round
                                                ..color = const Color(
                                                    0xFFFF1744),
                                            ),
                                          ),
                                          const Text(
                                            'Mcursor',
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontFamily: 'Consolas',
                                              height: 1.0,
                                              color: Colors.white,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const Text(
                                        '.time',
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontFamily: 'Consolas',
                                          height: 1.0,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ],
                                  ),
                                  // 行间距 3px。
                                  const SizedBox(height: 3),
                                  Text(
                                    _cursorPs == null || !_mCursorVisible
                                        ? ''
                                        : fmtPsSpaced(_cursorPs!),
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontFamily: 'Consolas',
                                      height: 1.0,
                                      color: Colors.white,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          if (_matchInfo != null) ...[
                            // 分区竖线。
                            Container(
                              width: 1,
                              height: _kOverviewHeight - 24,
                              color: const Color(0xFF3A3A3A),
                            ),
                            // 右部：匹配数量 + 信号名与匹配值（中对齐，
                            // 字体与左部一致）。
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8),
                                child: Column(
                                  mainAxisAlignment:
                                      MainAxisAlignment.center,
                                  crossAxisAlignment:
                                      CrossAxisAlignment.center,
                                  children: [
                                    Text(
                                      'Matched ${_matchInfo!.index}'
                                      '/${_matchInfo!.total}',
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 12,
                                        fontFamily: 'Consolas',
                                        height: 1.0,
                                        color: Colors.white,
                                      ),
                                    ),
                                    // 行间距 3px（与左部一致）。
                                    const SizedBox(height: 3),
                                    // 第二行：信号名 + 匹配值；标量 0/1
                                    // 段起点为跳变沿，以上升/下降沿图标
                                    // 代替文字。
                                    if (_matchInfo!.edge != null)
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Flexible(
                                            child: Text(
                                              '${_matchInfo!.name}  ',
                                              overflow:
                                                  TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontSize: 12,
                                                fontFamily: 'Consolas',
                                                height: 1.0,
                                                color: Colors.white,
                                              ),
                                            ),
                                          ),
                                          Image.asset(
                                            _matchInfo!.edge == 1
                                                ? 'icons/rising-edge.png'
                                                : 'icons/falling-edge.png',
                                            width: 18,
                                            height: 18,
                                            color: Colors.white,
                                          ),
                                          const SizedBox(width: 4),
                                          Text(
                                            _matchInfo!.edge == 1
                                                ? '上升沿'
                                                : '下降沿',
                                            style: const TextStyle(
                                              fontSize: 12,
                                              fontFamily: 'Consolas',
                                              height: 1.0,
                                              color: Colors.white,
                                            ),
                                          ),
                                        ],
                                      )
                                    else
                                      Text(
                                        '${_matchInfo!.name}  '
                                        '${_matchInfo!.value}',
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 12,
                                          fontFamily: 'Consolas',
                                          height: 1.0,
                                          color: Colors.white,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  Expanded(
                    // 拖分隔条时只有本区尺寸变化需要重绘；隔离重绘避免
                    // 牵连左侧面板。
                    child: RepaintBoundary(
                      child: _buildOverview(vcd, signals, waveWidth),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Row(
                children: [
                  SizedBox(width: _scopesWidth, child: _buildScopesPanel(vcd)),
                  // 分隔条与代码页同款：1px 线 + 两侧隐形热区（7px）。
                  IspVerticalDragDivider(
                    onDelta: (dx) => setState(
                      () => _scopesWidth = (_scopesWidth + dx).clamp(
                        120.0,
                        420.0,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: _namesWidth,
                    child: _buildNamesPanel(rows),
                  ),
                  IspVerticalDragDivider(
                    onDelta: (dx) => setState(
                      () =>
                          _namesWidth = (_namesWidth + dx).clamp(100.0, 400.0),
                    ),
                  ),
                  Expanded(
                    // 拖分隔条/面板交互时隔离重绘（波形画布自身尺寸
                    // 变化仍会重绘，但不牵连左侧树/信号名面板）。
                    child: RepaintBoundary(
                      child: _WaveCanvas(
                        vcd: vcd,
                        signals: signals,
                        rows: rows,
                        psPerPixel: _psPerPixel,
                        startPs: _startPs,
                        cursorPs: _cursorPs,
                        selectedIndex: _selectedSignal == null
                            ? null
                            : signals.indexWhere(
                                (s) => s.name == _selectedSignal,
                              ),
                        selectedRowIndex: _selectedSignal == null
                            ? null
                            : rows.indexWhere(
                                (r) =>
                                    r.bit == null &&
                                    !r.spacer &&
                                    !r.separator &&
                                    r.signal!.name == _selectedSignal,
                              ),
                        scrollController: _namesScroll,
                        onPan: (dPs) => setState(() {
                          final span = vcd.endTime.toDouble();
                          _startPs = (_startPs + dPs).clamp(
                            0.0,
                            math.max(0.0, span - waveWidth * _psPerPixel),
                          );
                        }),
                        onZoom: (factor, anchorPs) => setState(() {
                          final span = vcd.endTime.toDouble();
                          // 缩小上限 = Zoom Fit（视图恰好容纳全帧），
                          // 不允许继续缩小到波形之外。
                          final maxPpp = span / math.max(waveWidth, 1.0);
                          final newPpp = (_psPerPixel * factor).clamp(
                            0.5,
                            maxPpp,
                          );
                          final ratio = newPpp / _psPerPixel;
                          _startPs = (anchorPs - (anchorPs - _startPs) * ratio)
                              .clamp(
                                0.0,
                                math.max(0.0, span - waveWidth * newPpp),
                              )
                              .toDouble();
                          _psPerPixel = newPpp;
                        }),
                        onCursor: (ps) => setState(() {
                          _cursorPs = ps;
                          // 放置/拖动光标即恢复显示（此前被「隐藏M光标」
                          // 隐藏时）。
                          _mCursorVisible = true;
                          _matchInfo = null; // 手动移动光标：清除匹配序号显示
                          _gotoCtrl.text = '';
                        }),
                        onZoomRange: (t0, t1) => setState(() {
                          // 右键框选区间放大到充满主视图。
                          final span = vcd.endTime.toDouble();
                          final maxPpp = span / math.max(waveWidth, 1.0);
                          _psPerPixel = ((t1 - t0) / math.max(waveWidth, 1.0))
                              .clamp(0.5, maxPpp);
                          _startPs = t0
                              .clamp(
                                0.0,
                                math.max(0.0, span - waveWidth * _psPerPixel),
                              )
                              .toDouble();
                        }),
                        // 不可变副本：绘制器 old/new 参数比较依赖内容差异。
                        timelines: List.unmodifiable(_timelinesPs),
                        counters: Map.unmodifiable(_counters),
                        busFormats: Map.unmodifiable(_busFormats),
                        analogBuses: Set.unmodifiable(_analogBuses),
                        analogSpans: Map.unmodifiable(_analogSpan),
                        busColorSpaces: Map.unmodifiable(_busColorSpaces),
                        busColorLowFirst: Set.unmodifiable(_busColorLowFirst),
                        onPlaceTimeline: (ps) =>
                            setState(() => _timelinesPs.add(ps)),
                        // 右键菜单「M光标时间标签」开关。
                        mCursorLabelVisible: _mCursorLabelVisible,
                        // 右键菜单「隐藏M光标」开关（隐藏时光标线与标签/
                        // 全局图时间隐藏，位置保留）。
                        mCursorVisible: _mCursorVisible,
                        onToggleMCursorVisible: () => setState(
                            () => _mCursorVisible = !_mCursorVisible),
                        onToggleMCursorLabel: () => setState(() =>
                            _mCursorLabelVisible = !_mCursorLabelVisible),
                        onPlaceCounter: (ps, path, falling) => setState(
                          () => _counters[path] = (
                            startPs: ps,
                            falling: falling,
                          ),
                        ),
                        // 右键「删除当前信号计数值」。
                        onRemoveCounter: (path) =>
                            setState(() => _counters.remove(path)),
                        // 波形区左键点击/右键：自动选中光标所在行的信号。
                        onSelectSignal: (name) => setState(() {
                          _selectedSignal = name;
                          _matchInfo = null; // 换选信号：匹配序号失效
                          _gotoCtrl.text = '';
                        }),
                        // 右键菜单「查找上一个/下一个匹配项」（与工具栏
                        // Find Pre/Next Matches 同功能）。
                        onFindMatch: _findMatch,
                        // Dimension 标注：单一竖线体系 + 标注段（两种
                        // 标注法的段混合共存）；编辑模式状态与交互回调。
                        dimLines: List.unmodifiable(_dimLinesPs),
                        dimSpans: List.unmodifiable(_dimSpans),
                        dimActive: _dimActive,
                        dimActiveContinue: _dimActiveContinue,
                        onDimPlaceLine: _dimPlaceLine,
                        onDimExit: () => setState(() => _dimActive = false),
                        onDimMoveLine: _dimMoveLine,
                        // 竖线拖动结束：按时间重排。
                        onDimDragEnd: () => setState(_dimSortLines),
                        // Del 删除悬停高亮的竖线/标注段。
                        onDimDeleteLine: _dimDeleteLine,
                        onDimDeleteSpan: _dimDeleteSpan,
                        // 标注段纵向拖动（覆盖行号）。
                        onDimSpanRow: _dimSetSpanRow,
                        // 右键菜单「删除标注」：清除全部标注。
                        onDimClearAll: _dimClearAll,
                        // 右键菜单「进入基线标注模式」（同工具栏按钮）。
                        onDimEnter: _startDimBaseline,
                        // 右键菜单「进入连续标注模式」（同工具栏按钮）。
                        onDimEnterContinue: _startDimContinue,
                        // 菜单点选时间线：平移视图使其居中显示。
                        onJumpToTimeline: (ps) => setState(() {
                          final span = vcd.endTime.toDouble();
                          _startPs =
                              (ps - waveWidth * _psPerPixel / 2).clamp(
                                0.0,
                                math.max(0.0, span - waveWidth * _psPerPixel),
                              );
                        }),
                        // 清除时间线：index<0 全部清除，否则删单条。
                        onRemoveTimeline: (index) => setState(() {
                          if (index < 0) {
                            _tlLabelDy.clear();
                            _timelinesPs.clear();
                          } else if (index < _timelinesPs.length) {
                            _tlLabelDy.remove(_timelinesPs[index]);
                            _timelinesPs.removeAt(index);
                          }
                        }),
                        // 时间线标签上下拖动（键=时间线皮秒值）。
                        tlLabelDy: Map.unmodifiable(_tlLabelDy),
                        onTlLabelDrag: (ps, dy) =>
                            setState(() => _tlLabelDy[ps] = dy),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  /// 全局图：全波形压缩视图 + 可视窗口框；点击居中窗口，按住拖动窗口
  /// 在全局波形里快速移动（窗口内按下保持抓取偏移，窗口外按下居中）。
  Widget _buildOverview(
    VcdFile vcd,
    List<VcdSignal> signals,
    double waveWidth,
  ) {
    final span = math.max(vcd.endTime.toDouble(), 1.0);
    return LayoutBuilder(
      builder: (context, cons) {
        final w = math.max(cons.maxWidth, 1.0);
        final ppp = span / w;
        final viewSpan = waveWidth * _psPerPixel;
        double timeAtX(double x) => (x * ppp).clamp(0.0, span).toDouble();
        void jump(double newStart) => setState(() {
          _startPs = newStart
              .clamp(0.0, math.max(0.0, span - viewSpan))
              .toDouble();
        });
        return GestureDetector(
          onTapDown: (d) => jump(timeAtX(d.localPosition.dx) - viewSpan / 2),
          onPanStart: (d) {
            final t = timeAtX(d.localPosition.dx);
            final inWindow = t >= _startPs && t <= _startPs + viewSpan;
            _grabOffsetPs = inWindow ? t - _startPs : viewSpan / 2;
            if (!inWindow) jump(t - viewSpan / 2);
          },
          onPanUpdate: (d) => jump(timeAtX(d.localPosition.dx) - _grabOffsetPs),
          child: ClipRect(
            child: CustomPaint(
              size: Size.infinite,
              painter: WavePainter(
                vcd: vcd,
                rows: [for (final s in signals) WaveRow(s)],
                psPerPixel: ppp,
                startPs: 0,
                overview: true,
              ),
              foregroundPainter: OverviewWindowPainter(
                startPs: _startPs,
                viewSpanPs: viewSpan,
                totalPs: span,
                cursorPs: _cursorPs,
                timelines: List.unmodifiable(_timelinesPs),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Scopes 树 + Variables 列表面板（Surfer 同款）：树中点选 scope，
  /// 下方列出该 scope 的信号，＋/− 加入或移出波形显示。
  /// Scopes/Variables 之间的高度比例可拖动调整。
  Widget _buildScopesPanel(VcdFile vcd) {
    return Container(
      color: Colors.black,
      child: LayoutBuilder(
        builder: (context, cons) {
          final h = cons.maxHeight;
          final scopeTreeH = (h * _scopesRatio)
              .clamp(80.0, math.max(80.0, h - 120))
              .toDouble();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _panelHeader('Scopes'),
              SizedBox(
                height: scopeTreeH,
                child: ListView(
                  children: [
                    for (final c in _sortedScopes(vcd.root.children))
                      ..._scopeRows(c, 0),
                  ],
                ),
              ),
              // 水平分隔条与代码页竖条同款风格（1px 线 + 7px 热区）。
              IspHorizontalDragDivider(
                onDelta: (dy) => setState(
                  () => _scopesRatio = (_scopesRatio + dy / h)
                      .clamp(0.15, 0.85)
                      .toDouble(),
                ),
              ),
              _panelHeader('Variables'),
              Expanded(child: _buildVariablesList(vcd)),
            ],
          );
        },
      ),
    );
  }

  Widget _panelHeader(String title) {
    return Container(
      height: 24,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Color(0xFF3A3A3A)),
          top: BorderSide(color: Color(0xFF3A3A3A)),
        ),
      ),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.bold,
          color: Colors.white,
        ),
      ),
    );
  }

  /// 按名称升序排序（不改动原列表）。
  List<VcdScope> _sortedScopes(List<VcdScope> scopes) {
    final list = [...scopes];
    list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return list;
  }

  List<Widget> _scopeRows(VcdScope scope, int depth) {
    final collapsed = _collapsedScopes.contains(scope.path);
    final selected = _selectedScopePath == scope.path;
    // Surfer 同款：parameter 类信号归入该 scope 下的「Parameters」
    // 虚拟分组（显示在子 scope 之前）。
    final paramsPath = '${scope.path}#params';
    final hasParams = scope.signals.any((s) => s.vcdType == 'parameter');
    final paramsSelected = _selectedScopePath == paramsPath;
    return [
      InkWell(
        onTap: () => setState(() => _selectedScopePath = scope.path),
        child: Container(
          color: selected ? const Color(0xFF1E1E1E) : Colors.transparent,
          height: 22,
          child: Row(
            children: [
              SizedBox(width: 4 + depth * 12.0),
              InkWell(
                onTap: () => setState(() {
                  if (collapsed) {
                    _collapsedScopes.remove(scope.path);
                  } else {
                    _collapsedScopes.add(scope.path);
                  }
                }),
                child: Icon(
                  collapsed ? Icons.chevron_right : Icons.expand_more,
                  size: 14,
                  color: scope.children.isEmpty && !hasParams
                      ? Colors.transparent
                      : Colors.grey,
                ),
              ),
              Expanded(
                child: Text(
                  scope.name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    color: selected ? Colors.white : const Color(0xFFCCCCCC),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      if (!collapsed) ...[
        if (hasParams)
          InkWell(
            onTap: () => setState(() => _selectedScopePath = paramsPath),
            child: Container(
              color: paramsSelected
                  ? const Color(0xFF1E1E1E)
                  : Colors.transparent,
              height: 22,
              child: Row(
                children: [
                  SizedBox(width: 4 + (depth + 1) * 12.0),
                  const Icon(Icons.label_outline, size: 13, color: Colors.grey),
                  const SizedBox(width: 2),
                  Expanded(
                    child: Text(
                      'Parameters',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        color: paramsSelected
                            ? Colors.white
                            : const Color(0xFFCCCCCC),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        for (final c in _sortedScopes(scope.children)) ..._scopeRows(c, depth + 1),
      ],
    ];
  }

  VcdScope? _findScope(VcdScope scope, String path) {
    if (scope.path == path) return scope;
    for (final c in scope.children) {
      final r = _findScope(c, path);
      if (r != null) return r;
    }
    return null;
  }

  Widget _buildVariablesList(VcdFile vcd) {
    const paramsSuffix = '#params';
    final paramsMode = _selectedScopePath.endsWith(paramsSuffix);
    final scopePath = paramsMode
        ? _selectedScopePath.substring(
            0,
            _selectedScopePath.length - paramsSuffix.length,
          )
        : _selectedScopePath;
    final scope = _findScope(vcd.root, scopePath);
    if (scope == null) return const SizedBox.shrink();
    final scopeSignals = [
      for (final s in scope.signals)
        if (paramsMode ? s.vcdType == 'parameter' : s.vcdType != 'parameter') s,
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final displayed = _displayedPaths;
    bool isDisplayed(VcdSignal s) => displayed == null
        ? kWaveSignalNames.contains(s.name) && s.path.split('.').length == 2
        : displayed.contains(s.path);
    return ListView(
      children: [
        for (final s in scopeSignals)
          SizedBox(
            height: 22,
            child: Row(
              children: [
                const SizedBox(width: 18),
                Expanded(
                  child: Text(
                    // 参数行显示常量值（与 Surfer 的 Variables 一致）
                    paramsMode
                        ? '${s.name}: ${_paramValueText(s)}'
                        : (s.isBus ? '${s.name} [${s.width - 1}:0]' : s.name),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      color: isDisplayed(s)
                          ? const Color(0xFF4EC9B0)
                          : const Color(0xFFCCCCCC),
                    ),
                  ),
                ),
                InkWell(
                  onTap: () => _toggleDisplayed(vcd, s),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.all(3),
                    child: Icon(
                      isDisplayed(s) ? Icons.remove : Icons.add,
                      size: 14,
                      color: isDisplayed(s) ? Colors.orange : Colors.grey,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
              ],
            ),
          ),
      ],
    );
  }

  /// 参数的常量值文本（位串转十进制；含 x/z 时原样显示）。
  String _paramValueText(VcdSignal s) {
    if (s.changes.isEmpty) return '?';
    final bits = s.changes.first.bits;
    if (bits.contains('x') || bits.contains('z')) return bits;
    return BigInt.parse(bits, radix: 2).toString();
  }

  /// Variables 面板 ＋/−：加入/移出波形显示（首次操作时以当前显示的
  /// 默认 12 个信号为底物化列表）。
  void _toggleDisplayed(VcdFile vcd, VcdSignal s) {
    setState(() {
      final cur =
          _displayedPaths ?? _displaySignals(vcd).map((x) => x.path).toList();
      if (cur.contains(s.path)) {
        cur.remove(s.path);
      } else {
        cur.add(s.path);
      }
      _displayedPaths = cur;
    });
  }

  /// Signal 面板右键：命中行为整信号行时弹出菜单（总线含格式/模拟
  /// 通道项；所有整信号行含分隔符插入/删除当前信号项；位行/分隔符行
  /// 无菜单）；空白处（无信号行）弹出「加入信号」菜单（Variables
  /// 当前 scope 下未显示的信号）。
  void _onNamesSecondaryDown(PointerDownEvent e, List<WaveRow> rows) {
    if (e.buttons != kSecondaryButton) return;
    final scrollY = _namesScroll.hasClients ? _namesScroll.offset : 0.0;
    final y = e.localPosition.dy + scrollY;
    // 可变行高（分隔符 12px、位分组间隔 6px）：累计行高定位命中行。
    WaveRow? hit;
    var acc = 0.0;
    for (final r in rows) {
      final rh = r.gap
          ? kWaveGapHeight
          : r.separator
              ? kWaveSeparatorHeight
              : _WaveCanvas.rowHeight;
      if (y >= acc && y < acc + rh) {
        hit = r;
        break;
      }
      acc += rh;
    }
    if (hit == null) {
      // 空白处：加入信号菜单（Variables 中未显示的信号）。
      _addSigMenuController.open(position: e.localPosition);
      return;
    }
    final hitRow = hit;
    // 间隔行（位分组空白）无菜单；分隔符行：菜单仅「删除分隔符」；
    // 位行无菜单。
    if (hitRow.gap) return;
    if (hitRow.separator) {
      setState(() {
        _menuSepId = hitRow.sepId;
        _menuSignalPath = null;
      });
      _busMenuController.open(position: e.localPosition);
      return;
    }
    final sig = hitRow.signal!;
    if (hitRow.bit != null) return; // 位行无菜单
    // 模拟占位行落在其宿主总线上（菜单仍指向宿主）。
    setState(() {
      _menuSignalPath = sig.path;
      _menuSepId = null;
    });
    _busMenuController.open(position: e.localPosition);
  }

  /// Signal 右键菜单「跳转到Verilog」：打开波形来源编组的 IP 标签页，
  /// 并在所有用到该信号的 .v 文件里高亮信号名（经
  /// [IspStudioState.setIpCodeHighlight]）。
  void _jumpToVerilog(String signalName) {
    final store = SimWaveStore.instance;
    final groupId = store.sourceGroupId;
    if (groupId == null) return;
    final state = context.read<IspStudioState>();
    final options = sessionIpGenOptions[groupId] ??
        IpGenOptions(vendor: store.sourceVendor ?? IpVendor.generic);
    state.openGroupIpTab(groupId, options);
    state.setIpCodeHighlight(signalName);
  }

  /// 删除分隔符（从显示路径列表移除 `#sep:` 标记）。
  void _deleteSeparator(String sepId) {
    setState(() => _displayedPaths?.remove(sepId));
  }

  /// 删除当前信号（Signal 面板右键菜单）：从显示列表移除（未物化时
  /// 先物化），并清理其派生状态（选中/匹配信息/边沿计数/总线格式/
  /// 展开/模拟通道/色彩解码/位缓存）。
  void _deleteSignal(String path) {
    final vcd = _vcd;
    if (vcd == null) return;
    setState(() {
      final cur =
          _displayedPaths ?? _displaySignals(vcd).map((x) => x.path).toList();
      if (!cur.remove(path)) return;
      _displayedPaths = cur;
      final sig = vcd.signals.where((s) => s.path == path).firstOrNull;
      if (sig != null && _selectedSignal == sig.name) {
        _selectedSignal = null;
        _matchInfo = null;
        _gotoCtrl.text = '';
      }
      _counters.remove(path);
      _expandedBuses.remove(path);
      _busFormats.remove(path);
      _analogBuses.remove(path);
      _analogSpan.remove(path);
      _busColorSpaces.remove(path);
      _busColorLowFirst.remove(path);
      _bitSignalCache.remove(path);
    });
  }

  /// Signal 面板右键菜单：分隔符行仅「删除分隔符」；总线行含数据
  /// 格式（十进制/十六进制/二进制/ASCII，勾选当前项）+ 等效模拟通道
  /// + X10/X20 + 色彩解码（关闭/HSL/RGB/YUV + 字节顺序）；所有整信号
  /// 行尾部含「在当前信号上方/下方插入分隔符」与「删除当前信号」。
  List<Widget> _namesMenuChildren() {
    const labelStyle = TextStyle(fontSize: 12);
    final itemStyle = MenuItemButton.styleFrom(
      visualDensity: const VisualDensity(vertical: -4),
      minimumSize: const Size(0, 28),
      padding: const EdgeInsets.symmetric(horizontal: 12),
    );
    final sepId = _menuSepId;
    if (sepId != null) {
      return [
        MenuItemButton(
          onPressed: () => _deleteSeparator(sepId),
          style: itemStyle,
          child: const Text('删除分隔符', style: labelStyle),
        ),
      ];
    }
    final path = _menuSignalPath;
    if (path == null) return const [];
    final vcd = _vcd;
    final sig = vcd?.signals.where((s) => s.path == path).firstOrNull;
    final isBus = sig?.isBus ?? false;
    // 「跳转到Verilog」：打开波形来源编组的 IP 标签页并在所有用到该
    // 信号的文件中高亮信号名（波形非一键仿真来源——Open VCD——或
    // 编组已解散时置灰）。
    Widget jumpItem() {
      final store = SimWaveStore.instance;
      final gid = store.sourceGroupId;
      final canJump = sig != null &&
          gid != null &&
          context.read<IspStudioState>().graph.groups.any((g) => g.id == gid);
      return MenuItemButton(
        onPressed: canJump ? () => _jumpToVerilog(sig.name) : null,
        style: itemStyle,
        child: const Text('跳转到Verilog（高亮信号名）', style: labelStyle),
      );
    }

    Widget sepItem(String label, bool above) => MenuItemButton(
          onPressed: () => _insertSeparator(path, above),
          style: itemStyle,
          child: Text(label, style: labelStyle),
        );
    Widget deleteItem() => MenuItemButton(
          onPressed: () => _deleteSignal(path),
          style: itemStyle,
          child: const Text('删除当前信号', style: labelStyle),
        );
    if (!isBus) {
      return [
        jumpItem(),
        const Divider(height: 6),
        sepItem('在当前信号上方插入分隔符', true),
        sepItem('在当前信号下方插入分隔符', false),
        const Divider(height: 6),
        deleteItem(),
      ];
    }
    final fmt = _busFormats[path] ?? BusDisplayFormat.hex;
    final analog = _analogBuses.contains(path);
    final span = _analogSpan[path] ?? 1;
    Widget checkIcon(bool on) =>
        on ? const Icon(Icons.check, size: 14) : const SizedBox(width: 14);
    Widget fmtItem(BusDisplayFormat f, String label) => MenuItemButton(
      leadingIcon: checkIcon(fmt == f),
      onPressed: () => setState(() => _busFormats[path] = f),
      style: itemStyle,
      child: Text(label, style: labelStyle),
    );
    return [
      jumpItem(),
      const Divider(height: 6),
      fmtItem(BusDisplayFormat.decimal, '十进制'),
      fmtItem(BusDisplayFormat.hex, '十六进制'),
      fmtItem(BusDisplayFormat.binary, '二进制'),
      fmtItem(BusDisplayFormat.ascii, 'ASCII'),
      const Divider(height: 6),
      MenuItemButton(
        leadingIcon: checkIcon(analog),
        onPressed: () => setState(() {
          if (!_analogBuses.remove(path)) _analogBuses.add(path);
        }),
        style: itemStyle,
        child: const Text('等效模拟通道', style: labelStyle),
      ),
      // 模拟波形纵向占 N 个数字行高（仅模拟通道开启时可用；
      // 再点已勾选项恢复 X1）。
      MenuItemButton(
        leadingIcon: checkIcon(analog && span == 10),
        onPressed: analog
            ? () => setState(() => _analogSpan[path] = span == 10 ? 1 : 10)
            : null,
        style: itemStyle,
        child: const Text('X10', style: labelStyle),
      ),
      MenuItemButton(
        leadingIcon: checkIcon(analog && span == 20),
        onPressed: analog
            ? () => setState(() => _analogSpan[path] = span == 20 ? 1 : 20)
            : null,
        style: itemStyle,
        child: const Text('X20', style: labelStyle),
      ),
      const Divider(height: 6),
      // 色彩解码（背景色填充）：24 位数值按 HSL/RGB/YUV 解码为颜色填充
      // 总线数据块背景；字节顺序决定高字节承载 H/R/Y（默认）还是 L/B/V。
      MenuItemButton(
        onPressed: null,
        style: itemStyle,
        child: const Text('色彩解码（24位 → 背景填充）',
            style: TextStyle(fontSize: 11, color: Colors.grey)),
      ),
      for (final s in BusColorSpace.values)
        MenuItemButton(
          leadingIcon: checkIcon(
              (_busColorSpaces[path] ?? BusColorSpace.none) == s),
          onPressed: () => setState(() {
            if (s == BusColorSpace.none) {
              _busColorSpaces.remove(path);
            } else {
              _busColorSpaces[path] = s;
            }
          }),
          style: itemStyle,
          child: Text(
            s == BusColorSpace.none
                ? '关闭'
                : '${s.displayName}（高字节=${s.firstChannel}）',
            style: labelStyle,
          ),
        ),
      MenuItemButton(
        leadingIcon: checkIcon(!_busColorLowFirst.contains(path)),
        onPressed: (_busColorSpaces[path] ?? BusColorSpace.none) ==
                BusColorSpace.none
            ? null
            : () => setState(() => _busColorLowFirst.remove(path)),
        style: itemStyle,
        child: const Text('高字节 = H/R/Y（默认）', style: labelStyle),
      ),
      MenuItemButton(
        leadingIcon: checkIcon(_busColorLowFirst.contains(path)),
        onPressed: (_busColorSpaces[path] ?? BusColorSpace.none) ==
                BusColorSpace.none
            ? null
            : () => setState(() => _busColorLowFirst.add(path)),
        style: itemStyle,
        child: const Text('高字节 = L/B/V', style: labelStyle),
      ),
      const Divider(height: 6),
      sepItem('在当前信号上方插入分隔符', true),
      sepItem('在当前信号下方插入分隔符', false),
      const Divider(height: 6),
      deleteItem(),
    ];
  }

  /// Signal 面板空白处右键菜单（「加入信号」）：列出 Variables 面板
  /// 当前 scope 下未加入显示的信号（与 Variables 同口径——参数模式
  /// 列参数、否则列信号，按名字排序；总线名带位宽），点选即加入
  /// Signal 列表末尾；菜单首行为标题「可添加信号」，无候选时附置灰
  /// 提示项。
  List<Widget> _addSignalMenuChildren() {
    const labelStyle = TextStyle(fontSize: 12);
    final itemStyle = MenuItemButton.styleFrom(
      visualDensity: const VisualDensity(vertical: -4),
      minimumSize: const Size(0, 28),
      padding: const EdgeInsets.symmetric(horizontal: 12),
    );
    final vcd = _vcd;
    if (vcd == null) return const [];
    // 与 Variables 面板同口径的候选集（含参数模式）。
    const paramsSuffix = '#params';
    final paramsMode = _selectedScopePath.endsWith(paramsSuffix);
    final scopePath = paramsMode
        ? _selectedScopePath.substring(
            0, _selectedScopePath.length - paramsSuffix.length)
        : _selectedScopePath;
    final scope = _findScope(vcd.root, scopePath);
    if (scope == null) return const [];
    final displayed = _displayedPaths;
    bool isDisplayed(VcdSignal s) => displayed == null
        ? kWaveSignalNames.contains(s.name) && s.path.split('.').length == 2
        : displayed.contains(s.path);
    final candidates = [
      for (final s in scope.signals)
        if ((paramsMode
                ? s.vcdType == 'parameter'
                : s.vcdType != 'parameter') &&
            !isDisplayed(s))
          s,
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    // 菜单标题（置灰不可点击；白色大字 + 下方分割线）。
    final header = MenuItemButton(
      onPressed: null,
      style: itemStyle,
      child: const Text('可添加信号',
          style: TextStyle(fontSize: 13, color: Colors.white)),
    );
    const headerDivider = Divider(height: 6);
    if (candidates.isEmpty) {
      return [
        header,
        headerDivider,
        MenuItemButton(
          onPressed: null,
          style: itemStyle,
          child: const Text('（没有可加入的信号）',
              style: TextStyle(fontSize: 12, color: Colors.grey)),
        ),
      ];
    }
    return [
      header,
      headerDivider,
      for (final s in candidates)
        MenuItemButton(
          onPressed: () => _toggleDisplayed(vcd, s),
          style: itemStyle,
          child: Text(
            s.isBus ? '${s.name} [${s.width - 1}:0]' : s.name,
            style: labelStyle,
          ),
        ),
    ];
  }

  /// 拖动中的信号与相邻信号交换位置（dir=+1 下移、-1 上移）。
  bool _moveDraggedSignal(int dir) {
    final paths = _displayedPaths;
    final p = _dragSignalPath;
    if (paths == null || p == null) return false;
    final i = paths.indexOf(p);
    final j = i + dir;
    if (i < 0 || j < 0 || j >= paths.length) return false;
    setState(() {
      final tmp = paths[i];
      paths[i] = paths[j];
      paths[j] = tmp;
    });
    return true;
  }

  Widget _buildNamesPanel(List<WaveRow> rows) {
    final cursorPs = _cursorPs;
    return Container(
      color: Colors.black,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: _WaveCanvas.rulerHeight,
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Color(0xFF3A3A3A))),
            ),
            child: const Text(
              'Signal',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ),
          // 行数超出显示高度时经滚动条上下滚动；波形区经共享控制器
          // 同步行偏移（见 _WaveCanvas.scrollController）。Listener 负责
          // 总线行的右键菜单（1x1 锚点避免组内点击吞掉外部点击关闭）。
          Expanded(
            child: Scrollbar(
              controller: _namesScroll,
              thumbVisibility: true,
              child: Stack(
                children: [
                  Listener(
                    behavior: HitTestBehavior.translucent,
                    onPointerDown: (e) => _onNamesSecondaryDown(e, rows),
                    child: ListView(
                      controller: _namesScroll,
                      padding: EdgeInsets.zero,
                      children: [
                        for (final r in rows)
                          r.gap
                              // 位分组间隔行：面板留空（6px）
                              ? const SizedBox(height: kWaveGapHeight)
                              : r.separator
                              ? _buildSepRow(r)
                              : r.spacer
                              // 模拟通道占位行：面板留空（行高与波形一致）
                              ? const SizedBox(height: _WaveCanvas.rowHeight)
                              : r.bit != null
                              ? _buildBitNameRow(r, cursorPs)
                              : _buildSignalNameRow(r.signal!, cursorPs),
                      ],
                    ),
                  ),
                  Positioned(
                    left: 0,
                    top: 0,
                    child: MenuAnchor(
                      controller: _busMenuController,
                      menuChildren: _namesMenuChildren(),
                      child: const SizedBox(width: 1, height: 1),
                    ),
                  ),
                  // 空白处右键的「加入信号」菜单锚点（1x1 同上）。
                  Positioned(
                    left: 0,
                    top: 0,
                    child: MenuAnchor(
                      controller: _addSigMenuController,
                      menuChildren: _addSignalMenuChildren(),
                      child: const SizedBox(width: 1, height: 1),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 分隔符行（半通道高 12px：居中 1px 分割线；波形区同位置有通栏
  /// 横线）。不参与选中/拖动。
  Widget _buildSepRow(WaveRow r) {
    return SizedBox(
      key: ValueKey(r.sepId),
      height: kWaveSeparatorHeight,
      child: const Padding(
        padding: EdgeInsets.symmetric(vertical: 5),
        child: Divider(height: 1, thickness: 1, color: Color(0xFF3A3A3A)),
      ),
    );
  }

  /// 总线展开后的位行（仅显示：位名 + 光标处位值；不参与选中/拖动）。
  /// 背景按每 4 位分组交替（半透明白 ≈ #202020 / 黑，LSB 组起），配合
  /// 每 8 位的间隔行分组阅读。
  Widget _buildBitNameRow(WaveRow r, int? cursorPs) {
    final s = r.signal!;
    final shade = (r.bit! ~/ 4) % 2 == 0
        ? Colors.white.withValues(alpha: 0.12)
        : null;
    return SizedBox(
      key: ValueKey(s.path),
      height: _WaveCanvas.rowHeight,
      child: Container(
        color: shade,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            // 与整信号行的箭头列对齐，位名再缩进一级。
            const SizedBox(width: 26),
            Expanded(
              child: Text(
                s.name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14, color: Color(0xFFCCCCCC)),
              ),
            ),
            if (cursorPs != null)
              Text(
                valueAt(s, cursorPs),
                style: TextStyle(
                  fontSize: 13,
                  fontFamily: 'Consolas',
                  color: valueAt(s, cursorPs).contains('x')
                      ? Colors.red
                      : Colors.white,
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 整信号行：可选中/可拖动重排；总线行左侧带展开箭头
  ///（与 Scopes 树同款：展开显示每个位，再点收起）。
  Widget _buildSignalNameRow(VcdSignal s, int? cursorPs) {
    return SizedBox(
      // key 让元素跟随信号而不是位置：拖动交换位置后手势识别器
              // 仍在被拖行上，否则换一次位置拖动即中断（无法连续拖动）。
              key: ValueKey(s.path),
              height: _WaveCanvas.rowHeight,
              // 点住任意信号行上下拖动：每满一行高与相邻信号交换
              // 位置（首次拖动时物化显示列表以支持重排）。Listener
              // 跟踪左键按下/释放：按住期间信号名文字变亮黄。
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: (e) {
                  if (e.buttons == kPrimaryButton) {
                    setState(() => _pressedSignalPath = s.path);
                  }
                },
                onPointerUp: (_) =>
                    setState(() => _pressedSignalPath = null),
                onPointerCancel: (_) =>
                    setState(() => _pressedSignalPath = null),
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onVerticalDragStart: (_) {
                    _dragSignalPath = s.path;
                    _dragAccum = 0;
                    _displayedPaths ??= _displaySignals(
                      _vcd!,
                    ).map((x) => x.path).toList();
                  },
                  onVerticalDragUpdate: (d) {
                    _dragAccum += d.delta.dy;
                    while (_dragAccum >= _WaveCanvas.rowHeight) {
                      if (!_moveDraggedSignal(1)) break;
                      _dragAccum -= _WaveCanvas.rowHeight;
                    }
                    while (_dragAccum <= -_WaveCanvas.rowHeight) {
                      if (!_moveDraggedSignal(-1)) break;
                      _dragAccum += _WaveCanvas.rowHeight;
                    }
                  },
                  onVerticalDragEnd: (_) => setState(() {
                    _dragSignalPath = null;
                    _pressedSignalPath = null;
                  }),
                  onVerticalDragCancel: () => setState(() {
                    _dragSignalPath = null;
                    _pressedSignalPath = null;
                  }),
                  child: InkWell(
                    onTap: () => setState(() {
                      // 点击信号名：选中（该行与对应波形背景由全黑变
                      // 暗蓝 #094771），再点一次取消选中。
                      _selectedSignal = _selectedSignal == s.name ? null : s.name;
                      _matchInfo = null; // 换选信号：匹配序号失效
                      _gotoCtrl.text = '';
                    }),
                    child: Container(
                      color: _selectedSignal == s.name
                          ? const Color(0xFF094771)
                          : Colors.transparent,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  // 总线：展开/收起箭头（与 Scopes 树同款，点击展开到
                  // 每个位，再点收起位域）；标量：占位对齐。
                  if (s.isBus)
                    InkWell(
                      onTap: () => setState(() {
                        if (!_expandedBuses.remove(s.path)) {
                          _expandedBuses.add(s.path);
                        }
                      }),
                      child: Icon(
                        _expandedBuses.contains(s.path)
                            ? Icons.expand_more
                            : Icons.chevron_right,
                        size: 14,
                        color: Colors.grey,
                      ),
                    )
                  else
                    const SizedBox(width: 14),
                  const SizedBox(width: 2),
                  Expanded(
                    child: Text(
                      // 总线信号名带位宽（与 Surfer/Variables 面板一致）
                      s.isBus ? '${s.name} [${s.width - 1}:0]' : s.name,
                          overflow: TextOverflow.ellipsis,
                          // 左键按住（含拖动重排中）文字变亮黄，释放恢复
                          style: TextStyle(
                            fontSize: 14,
                            color: _pressedSignalPath == s.path
                                ? const Color(0xFFFFFF00)
                                : const Color(0xFFCCCCCC),
                          ),
                        ),
                      ),
                  if (cursorPs != null)
                    // 非 flex 子件：Expanded 名称吸走全部剩余空间，
                    // 数值按本征宽度自然贴右缘；maxWidth 防长数值溢出。
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: math.max(48.0, _namesWidth - 80),
                      ),
                      child: Text(
                        // 总线数值按右键菜单设定的格式显示（缺省 hex）
                        s.isBus
                            ? formatBusBits(
                                valueAt(s, cursorPs),
                                _busFormats[s.path] ?? BusDisplayFormat.hex,
                                width: s.width,
                              )
                            : valueAt(s, cursorPs),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontFamily: 'Consolas',
                          color: valueAt(s, cursorPs).contains('x')
                              ? Colors.red
                              : Colors.white,
                        ),
                      ),
                    ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      );
  }
}

/// Bus Search 对话框：下拉选定总线信号（含位域显示 `name [w-1:0]`）
/// + 输入总线值（缺省十六进制，0b 前缀二进制），随输入实时显示匹配
/// 数量；「查找」确认（有匹配才可用）回调跳转首个匹配。
class _BusSearchDialog extends StatefulWidget {
  /// 候选总线（当前显示中的总线信号）。
  final List<VcdSignal> buses;

  /// 初始选中的信号路径（当前选中信号为总线时回填）。
  final String? initialPath;

  /// 「查找」确认（matches 保证非空）：跳转首个匹配。
  final void Function(VcdSignal sig, String bits, List<int> matches)
      onApply;

  const _BusSearchDialog({
    required this.buses,
    this.initialPath,
    required this.onApply,
  });

  @override
  State<_BusSearchDialog> createState() => _BusSearchDialogState();
}

class _BusSearchDialogState extends State<_BusSearchDialog> {
  late String? _path = widget.initialPath != null &&
          widget.buses.any((s) => s.path == widget.initialPath)
      ? widget.initialPath
      : (widget.buses.isNotEmpty ? widget.buses.first.path : null);
  final TextEditingController _valueCtrl = TextEditingController();

  @override
  void dispose() {
    _valueCtrl.dispose();
    super.dispose();
  }

  VcdSignal? get _sig {
    for (final s in widget.buses) {
      if (s.path == _path) return s;
    }
    return null;
  }

  /// 当前输入解析出的位串（null=无法解析/未选信号）。
  String? get _bits {
    final s = _sig;
    if (s == null) return null;
    return parseBusValueInput(_valueCtrl.text, s.width);
  }

  /// 匹配数量（null=输入无法解析）。
  int? get _matchCount {
    final s = _sig, b = _bits;
    if (s == null || b == null) return null;
    return _SimWaveTabState._matchTimesOf(s, b).length;
  }

  void _apply() {
    final s = _sig, b = _bits;
    if (s == null || b == null) return;
    final matches = _SimWaveTabState._matchTimesOf(s, b);
    if (matches.isEmpty) return;
    widget.onApply(s, b, matches);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final count = _matchCount;
    return AlertDialog(
      title: const Text('Bus Search'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.buses.isEmpty)
              const Text(
                '当前显示信号中没有总线',
                style: TextStyle(fontSize: 13, color: Colors.grey),
              )
            else ...[
              DropdownButtonFormField<String>(
                initialValue: _path,
                isDense: true,
                decoration: const InputDecoration(
                  labelText: '总线信号',
                  isDense: true,
                ),
                items: [
                  for (final s in widget.buses)
                    DropdownMenuItem(
                      value: s.path,
                      child: Text(
                        '${s.name} [${s.width - 1}:0]',
                        style: const TextStyle(
                            fontSize: 13, fontFamily: 'Consolas'),
                      ),
                    ),
                ],
                onChanged: (v) => setState(() => _path = v),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _valueCtrl,
                autofocus: true,
                style:
                    const TextStyle(fontSize: 13, fontFamily: 'Consolas'),
                decoration: const InputDecoration(
                  labelText: '总线值（缺省十六进制，0b 前缀二进制）',
                  hintText: '0x000000',
                  isDense: true,
                ),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _apply(),
              ),
              const SizedBox(height: 10),
              // 匹配数量实时显示：可解析时显示计数（>0 绿色/0 灰色），
              // 无法解析时提示。
              if (_valueCtrl.text.trim().isNotEmpty)
                count != null
                    ? Text(
                        '匹配数量：$count',
                        style: TextStyle(
                          fontSize: 12,
                          fontFamily: 'Consolas',
                          color: count > 0
                              ? const Color(0xFF4EC9B0)
                              : Colors.grey,
                        ),
                      )
                    : const Text(
                        '输入无法解析',
                        style: TextStyle(
                            fontSize: 12, color: Color(0xFFFFB300)),
                      ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: (count != null && count > 0) ? _apply : null,
          child: const Text('查找'),
        ),
      ],
    );
  }
}

/// 波形画布：时间尺 + 逐信号数字轨迹 + 手势。
/// 左键放置/拖动 M 光标（16px 内吸附最近跳变沿，半径外跟随鼠标）；
/// 右键弹出菜单（并自动选中光标所在行信号）。
/// （上升沿计数值 / 下降沿计数值 / 时间线，均以 M 光标线为锚点）；
/// Ctrl+左键快速平移；Alt+左键框选区间放大；滚轮平移、Ctrl+滚轮缩放。
class _WaveCanvas extends StatefulWidget {
  static const double rulerHeight = 20;
  static const double rowHeight = 24;

  final VcdFile vcd;
  final List<VcdSignal> signals;

  /// 显示行（含总线展开的位行）：波形绘制/光标边沿吸附/右键命中按行
  /// 对应信号。
  final List<WaveRow> rows;
  final double psPerPixel;
  final double startPs;
  final int? cursorPs;

  /// 选中信号在 signals 中的序号（右键菜单用）。
  final int? selectedIndex;

  /// 选中信号的显示行号（波形行背景高亮用；总线展开会插入位行，
  /// 与 selectedIndex 不是同一坐标系）。
  final int? selectedRowIndex;
  final void Function(double dPs) onPan;
  final void Function(double factor, double anchorPs) onZoom;
  final void Function(int ps) onCursor;
  final void Function(double t0Ps, double t1Ps) onZoomRange;

  /// 时间线标记（皮秒，按放置顺序编号 T1/T2…）。
  final List<int> timelines;

  /// M 光标时间标签显示开关（右键菜单「M光标时间标签」切换）：
  /// true = 光标顶部红色徽章显示 `M  时间`，false = 只显示 M。
  final bool mCursorLabelVisible;

  /// 右键菜单「M光标时间标签」：切换 M 光标时间标签显示。
  final VoidCallback? onToggleMCursorLabel;

  /// M 光标可见性（右键菜单「隐藏M光标」切换）：false 时光标线/标签
  /// 与依赖光标的菜单放置项全部隐藏（位置保留）。
  final bool mCursorVisible;

  /// 右键菜单「隐藏M光标」/「显示M光标」：切换 M 光标可见性。
  final VoidCallback? onToggleMCursorVisible;

  /// 各信号的边沿计数标注（键=信号路径）：更换信号放置互不影响。
  final Map<String, WaveCounter> counters;
  final void Function(int ps) onPlaceTimeline;
  final void Function(int ps, String signalPath, bool falling) onPlaceCounter;

  /// 右键菜单「删除当前信号计数值」：移除选中信号的边沿计数标注。
  final void Function(String signalPath) onRemoveCounter;

  /// 右键菜单点选时间线：跳转视图使该时间线居中显示。
  final void Function(int ps) onJumpToTimeline;

  /// 时间线标签的纵向位置覆盖（键=时间线皮秒值，值=标签顶 y）与拖动
  /// 回调：点住标签上下拖动改变其显示位置。
  final Map<int, double> tlLabelDy;
  final void Function(int ps, double dy)? onTlLabelDrag;

  /// 波形区左键点击/右键时自动选中光标所在行的信号（信号名；与左栏
  /// 点击选中同口径）。
  final void Function(String signalName)? onSelectSignal;

  /// 右键菜单「查找上一个/下一个匹配项」（与工具栏 Find Pre/Next
  /// Matches 同功能）：false=上一个，true=下一个。
  final void Function(bool forward)? onFindMatch;

  /// Dimension 标注：竖线时刻列表（皮秒，全部按时间升序）与标注段
  ///（from→to 均为竖线时刻，from<to；row=纵向拖动覆盖的行号，
  /// null=自动分配）。基线/连续两种标注法放置的段混合共存于同一
  /// 竖线体系。
  final List<int> dimLines;
  final List<({int from, int to, int? row})> dimSpans;

  /// 标注编辑模式进行中（左键在波形区放线，右键退出）；
  /// [dimActiveContinue] 仅决定新放线的标注风格（true=连续法：
  /// 前一条线为基线；false=基线法：t0 为基线），既有段不受影响，
  /// 交互（悬停/拖动/删除）作用于整个体系。
  final bool dimActive;
  final bool dimActiveContinue;

  /// 标注编辑模式中左键放置竖线（已按 16px 半径吸附跳变沿；按当前
  /// 标注风格生成标注段）。
  final void Function(int ps)? onDimPlaceLine;

  /// 标注编辑模式中右键退出。
  final VoidCallback? onDimExit;

  /// 拖动竖线左右移动（已吸附跳变沿；关联标注段端点跟随）。
  final void Function(int index, int ps)? onDimMoveLine;

  /// 竖线拖动结束（按时间重排用）。
  final VoidCallback? onDimDragEnd;

  /// Del 删除悬停高亮的竖线（以其为端点的标注段一并删除）。
  final void Function(int index)? onDimDeleteLine;

  /// Del 删除悬停高亮的标注段（竖线保留）。
  final void Function(int index)? onDimDeleteSpan;

  /// 标注段纵向拖动（覆盖行号；段按行号绘制，行间距 34）。
  final void Function(int index, int row)? onDimSpanRow;

  /// 右键菜单「删除标注」：清除全部标注（竖线与标注段）。
  final VoidCallback? onDimClearAll;

  /// 右键菜单「进入基线标注模式」（与工具栏 Dimension Baseline
  /// 按钮同功能）。
  final VoidCallback? onDimEnter;

  /// 右键菜单「进入连续标注模式」（与工具栏 Dimension Continue
  /// 按钮同功能）。
  final VoidCallback? onDimEnterContinue;

  /// 右键菜单「清除时间线」：index<0 清除全部，否则删除第 index 条。
  final void Function(int index) onRemoveTimeline;

  /// 与信号名列表共享的垂直滚动控制器（波形行偏移由其 offset 驱动，
  /// 经 CustomPainter(repaint:) 免重建重绘）。
  final ScrollController? scrollController;

  /// 总线数据显示格式与等效模拟通道设定（Signal 面板右键菜单，
  /// 键=信号路径）。
  final Map<String, BusDisplayFormat> busFormats;
  final Set<String> analogBuses;

  /// 模拟波形纵向占用的数字行数（键=信号路径，缺省 1）。
  final Map<String, int> analogSpans;

  /// 总线色彩解码设定（Signal 面板右键菜单，键=信号路径，缺省关闭）；
  /// [busColorLowFirst] 内路径的高字节承载第三通道（L/B/V）。
  final Map<String, BusColorSpace> busColorSpaces;
  final Set<String> busColorLowFirst;

  const _WaveCanvas({
    required this.vcd,
    required this.signals,
    required this.rows,
    required this.psPerPixel,
    required this.startPs,
    required this.cursorPs,
    this.selectedIndex,
    this.selectedRowIndex,
    this.scrollController,
    this.busFormats = const {},
    this.analogBuses = const {},
    this.analogSpans = const {},
    this.busColorSpaces = const {},
    this.busColorLowFirst = const {},
    required this.onPan,
    required this.onZoom,
    required this.onCursor,
    required this.onZoomRange,
    required this.timelines,
    this.mCursorLabelVisible = true,
    this.onToggleMCursorLabel,
    this.mCursorVisible = true,
    this.onToggleMCursorVisible,
    this.counters = const {},
    required this.onPlaceTimeline,
    required this.onPlaceCounter,
    required this.onRemoveCounter,
    required this.onJumpToTimeline,
    this.tlLabelDy = const {},
    this.onTlLabelDrag,
    this.onSelectSignal,
    this.onFindMatch,
    this.dimLines = const [],
    this.dimSpans = const [],
    this.dimActive = false,
    this.dimActiveContinue = false,
    this.onDimPlaceLine,
    this.onDimExit,
    this.onDimMoveLine,
    this.onDimDragEnd,
    this.onDimDeleteLine,
    this.onDimDeleteSpan,
    this.onDimSpanRow,
    this.onDimClearAll,
    this.onDimEnter,
    this.onDimEnterContinue,
    required this.onRemoveTimeline,
  });

  @override
  State<_WaveCanvas> createState() => _WaveCanvasState();
}

class _WaveCanvasState extends State<_WaveCanvas> {
  double? _selStartX;
  double? _selCurrentX;
  bool _ctrlDown = false;
  bool _altDown = false;

  /// 最近一次布局的画布宽度（右键菜单的光标在视口内判定用）。
  double _lastCanvasWidth = 0;

  /// 最近一次布局的画布高度（标注组基准 y 钳位用）。
  double _lastCanvasHeight = 0;

  /// 吸附半径（像素）：距最近跳变沿超过该距离时不吸附，跟随鼠标。
  static const double _kSnapRadiusPx = 16;

  @override
  void initState() {
    super.initState();
    // 监听 Ctrl/Alt 按下松开，实时切换光标形态（不等鼠标移动）。
    HardwareKeyboard.instance.addHandler(_onKeyEvent);
  }

  bool _onKeyEvent(KeyEvent e) {
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    final ctrl =
        keys.contains(LogicalKeyboardKey.controlLeft) ||
        keys.contains(LogicalKeyboardKey.controlRight);
    final alt =
        keys.contains(LogicalKeyboardKey.altLeft) ||
        keys.contains(LogicalKeyboardKey.altRight);
    if ((ctrl != _ctrlDown || alt != _altDown) && mounted) {
      setState(() {
        _ctrlDown = ctrl;
        _altDown = alt;
      });
    }
    return false;
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKeyEvent);
    _keyFocus.dispose();
    super.dispose();
  }

  /// 各显示行对应的信号（跳过模拟占位行与分隔符行）：边沿吸附用。
  List<VcdSignal> get _rowSignals => [
    for (final r in widget.rows)
      if (!r.spacer && r.signal != null) r.signal!,
  ];

  /// 显示行的总底沿（画布局部 y）：时间尺高 + 各行累计高。基线标注
  /// 模式的 tn 标签自动调整到 Signal 列表下方用。
  double _rowsBottom() {
    var acc = _WaveCanvas.rulerHeight.toDouble();
    for (final r in widget.rows) {
      acc += r.gap
          ? kWaveGapHeight
          : r.separator
              ? kWaveSeparatorHeight
              : _WaveCanvas.rowHeight;
    }
    return acc;
  }

  /// 画布 x 坐标 → 时刻（16px 半径内吸附最近跳变沿，半径外原值）。
  int _snapPs(double dx) {
    final t = widget.startPs + dx * widget.psPerPixel;
    final radiusPs = _kSnapRadiusPx * widget.psPerPixel;
    var best = t;
    var bestDist = radiusPs;
    for (final s in _rowSignals) {
      final edge = _nearestEdge(s, t);
      if (edge == null) continue;
      final dist = (edge - t).abs();
      if (dist <= bestDist) {
        bestDist = dist;
        best = edge;
      }
    }
    return best.round();
  }

  /// 左键放置/拖动：光标吸附到任意显示信号的最近跳变沿（16px 吸附半径内），
  /// 半径外精确跟随鼠标。
  void _snapCursorTo(double dx) {
    widget.onCursor(_snapPs(dx));
  }

  double get _dimScrollY => widget.scrollController != null &&
          widget.scrollController!.hasClients
      ? widget.scrollController!.offset
      : 0.0;

  /// 标注段第 0 行的基准 y（Signal 列表下方，滚动跟随 + 画布高度
  /// 钳位；与绘制共用 [_WaveOverlayPainter] 的静态口径）。
  double _dimBaseY() => _WaveOverlayPainter.dimGroupsBaseYAt(
      _rowsBottom(), _dimScrollY, _lastCanvasHeight);

  /// 标注段纵向拖动的目标行号：目标 y 先钳位到可达范围（上极限 =
  /// Signal 列表底 + 标签高度余量——不允许拖到波形上面；下极限 =
  /// 画布底），再按行间距 34 取整（最小第 0 行）。
  int _dimRowAtY(double desiredY) {
    final topLim = _rowsBottom() - _dimScrollY + 36;
    final bottomLim = _lastCanvasHeight - 8;
    final y = desiredY.clamp(topLim, bottomLim);
    return math.max(0, ((y - _dimBaseY()) / 34).round());
  }

  /// 命中标注段（标签矩形或箭头线 ±4px）：返回（段索引, 抓取点距
  /// 箭头线的纵向偏移），未命中 null。布局与绘制共用
  /// [_WaveOverlayPainter.dimSpanRows]/[_WaveOverlayPainter.dimSpanLayout]。
  (int, double)? _hitDimSpan(Offset pos) {
    final spans = widget.dimSpans;
    if (spans.isEmpty) return null;
    final rows = _WaveOverlayPainter.dimSpanRows(spans);
    final baseY = _dimBaseY();
    for (var i = 0; i < spans.length; i++) {
      final lay = _WaveOverlayPainter.dimSpanLayout(
          i, spans, rows, widget.startPs, widget.psPerPixel, baseY,
          width: _lastCanvasWidth);
      if (lay.labelRect.inflate(2).contains(pos) ||
          lay.arrowRect.contains(pos)) {
        return (i, pos.dy - lay.arrowY);
      }
    }
    return null;
  }

  /// 命中标注竖线（±4px，时间尺以下）：返回线索引，未命中 null。
  int? _hitDimLine(Offset pos) {
    if (pos.dy < _WaveCanvas.rulerHeight) return null;
    final lines = widget.dimLines;
    for (var i = lines.length - 1; i >= 0; i--) {
      final x = (lines[i] - widget.startPs) / widget.psPerPixel;
      if ((pos.dx - x).abs() <= 4) return i;
    }
    return null;
  }

  /// 标注拖动状态：竖线索引 / 标注段索引 / 标注段抓取点纵向偏移。
  int? _dimDragLine;
  int? _dimDragSpan;
  double _dimDragGrabDy = 0;

  /// 标注编辑模式中跟随鼠标的预览竖线时刻（吸附后；null = 不在
  /// 画布内）。
  int? _dimHoverPs;

  /// 标注编辑模式中鼠标悬停的竖线索引（null=未悬停到既有竖线）。
  int? _dimHoverLine;

  /// 标注编辑模式中鼠标悬停的标注段索引（null=未悬停到标注段）。
  int? _dimHoverSpan;

  /// Del 删除高亮标注用的键盘焦点（按下/进入模式时夺取）。
  final FocusNode _keyFocus = FocusNode();

  final MenuController _menuController = MenuController();

  /// 右键菜单（MenuAnchor 实现，「跳转到时间线」「清除时间线」为二级
  /// 菜单）：放置项均以 M 光标线为锚点。「从M光标线放置上升沿计数值」/
  /// 「从M光标线放置下降沿计数值」对左栏选中的标量信号，从 M 光标
  /// 时刻起在对应边沿右侧标注计数 1,2,3…；「查找上一个/下一个匹配项」
  /// 与工具栏 Find Pre/Next Matches 同功能（找选中信号上等于 M 光标
  /// 处取值的上一个/下一个跳变起点，光标移去并居中）；「从M光标线
  /// 放置时间线」
  /// 在 M 光标处放置时间线标记 T1/T2…；「跳转到时间线」二级菜单列出
  /// 全部时间线，点选即跳转视图使其居中显示；「清除时间线」二级菜单
  /// 首项清除全部，分割线下删除单条。未放置 M 光标时放置项置灰；
  /// 无选中信号或选中总线时计数项置灰；「删除当前信号计数值」在选中
  /// 信号已有计数标注时可用；无时间线时两个二级菜单置灰；M 光标不在
  /// 视口内、无选中信号或对应方向匹配到头时查找匹配项置灰；「M光标
  /// 时间标签」切换光标顶部徽章的时间值显示（勾选态）；「隐藏M光标」
  /// 切换光标可见性（隐藏时光标线/标签与依赖光标的放置项全部禁用，
  /// 位置保留，左键重新放置自动恢复）；「进入基线标注模式」「进入连续
  /// 标注模式」分别与工具栏 Dimension Baseline / Dimension Continue
  /// 按钮同功能（两种标注法放置的段混合共存于同一竖线体系）；「删除
  /// 标注」清除全部标注（无标注时置灰）。
  List<Widget> _buildMenuChildren() {
    // M 光标被「隐藏M光标」隐藏时，放置项/查找项按无光标处理。
    final cursorPs = widget.mCursorVisible ? widget.cursorPs : null;
    // M 光标在当前显示区域内才允许放置时间线（区域外放到看不见的
    // 位置；与工具栏 Place TimeLine 同口径）。宽度来自最近一次布局
    // （本方法在 build 期间被调用，不能读 context.size）。
    final cursorInView = cursorPs != null &&
        cursorPs >= widget.startPs &&
        cursorPs <= widget.startPs + _lastCanvasWidth * widget.psPerPixel;
    final sel = widget.selectedIndex;
    final selSignal = (sel != null && sel >= 0 && sel < widget.signals.length)
        ? widget.signals[sel]
        : null;
    final canCounter =
        cursorPs != null && selSignal != null && !selSignal.isBus;
    // 查找匹配项：与工具栏 Find Pre/Next Matches 同口径（M 光标在视口
    // 内且有选中信号；总线也可匹配整段取值），且对应方向上还有匹配
    // 跳变起点（到头置灰）。
    final canFindPre = cursorInView &&
        selSignal != null &&
        hasMatchInDirection(selSignal, cursorPs, false);
    final canFindNext = cursorInView &&
        selSignal != null &&
        hasMatchInDirection(selSignal, cursorPs, true);
    // 选中信号已有计数标注时才可删除。
    final hasCounter =
        selSignal != null && widget.counters.containsKey(selSignal.path);
    final tls = widget.timelines;
    const labelStyle = TextStyle(fontSize: 12);
    const tlStyle = TextStyle(
      fontSize: 12,
      color: _WaveOverlayPainter._tlColor,
    );
    // 二级菜单箭头：SubmenuButton 默认箭头为硬编码 24px
    // （_kDefaultSubmenuIconSize，不吃 IconTheme），会把行高撑得与
    // 普通菜单项不一致，显式换成 14px。
    const submenuArrow = WidgetStatePropertyAll<Widget?>(
      Icon(Icons.play_arrow, size: 14),
    );
    // 行高压到紧凑密度默认值（~40px）的 70%（28px）。
    final itemStyle = MenuItemButton.styleFrom(
      visualDensity: const VisualDensity(vertical: -4),
      minimumSize: const Size(0, 28),
      padding: const EdgeInsets.symmetric(horizontal: 12),
    );
    void placeCounter(bool falling) {
      final c = cursorPs, s = selSignal;
      if (c != null && s != null) widget.onPlaceCounter(c, s.path, falling);
    }

    void placeTimeline() {
      final c = cursorPs;
      if (c != null) widget.onPlaceTimeline(c);
    }

    return [
      MenuItemButton(
        onPressed: canCounter ? () => placeCounter(false) : null,
        style: itemStyle,
        child: const Text('从M光标线放置上升沿计数值', style: labelStyle),
      ),
      MenuItemButton(
        onPressed: canCounter ? () => placeCounter(true) : null,
        style: itemStyle,
        child: const Text('从M光标线放置下降沿计数值', style: labelStyle),
      ),
      MenuItemButton(
        onPressed: hasCounter
            ? () => widget.onRemoveCounter(selSignal.path)
            : null,
        style: itemStyle,
        child: const Text('删除当前信号计数值', style: labelStyle),
      ),
      const Divider(height: 6),
      MenuItemButton(
        onPressed: canFindPre ? () => widget.onFindMatch?.call(false) : null,
        style: itemStyle,
        child: const Text('查找上一个匹配项', style: labelStyle),
      ),
      MenuItemButton(
        onPressed: canFindNext ? () => widget.onFindMatch?.call(true) : null,
        style: itemStyle,
        child: const Text('查找下一个匹配项', style: labelStyle),
      ),
      const Divider(height: 6),
      MenuItemButton(
        onPressed: cursorInView ? placeTimeline : null,
        style: itemStyle,
        child: const Text('从M光标线放置时间线', style: labelStyle),
      ),
      // 无时间线时：空子菜单（悬停不展开）+ 灰色前景，等效置灰。
      SubmenuButton(
        submenuIcon: submenuArrow,
        style: tls.isEmpty
            ? MenuItemButton.styleFrom(
                visualDensity: const VisualDensity(vertical: -4),
                minimumSize: const Size(0, 28),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                foregroundColor: Colors.grey,
              )
            : itemStyle,
        menuChildren: tls.isEmpty
            ? const <Widget>[]
            : [
                for (var i = 0; i < tls.length; i++)
                  MenuItemButton(
                    onPressed: () => widget.onJumpToTimeline(tls[i]),
                    style: itemStyle,
                    child: Text(
                      'T${i + 1}  ${fmtPsGrouped(tls[i])}',
                      style: tlStyle,
                    ),
                  ),
              ],
        child: const Text('跳转到时间线', style: labelStyle),
      ),
      SubmenuButton(
        submenuIcon: submenuArrow,
        style: tls.isEmpty
            ? MenuItemButton.styleFrom(
                visualDensity: const VisualDensity(vertical: -4),
                minimumSize: const Size(0, 28),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                foregroundColor: Colors.grey,
              )
            : itemStyle,
        menuChildren: tls.isEmpty
            ? const <Widget>[]
            : [
                MenuItemButton(
                  onPressed: () => widget.onRemoveTimeline(-1),
                  style: itemStyle,
                  child: const Text('全部时间线', style: labelStyle),
                ),
                const Divider(height: 6),
                for (var i = 0; i < tls.length; i++)
                  MenuItemButton(
                    onPressed: () => widget.onRemoveTimeline(i),
                    style: itemStyle,
                    child: Text(
                      'T${i + 1}  ${fmtPsGrouped(tls[i])}',
                      style: tlStyle,
                    ),
                  ),
              ],
        child: const Text('清除时间线', style: labelStyle),
      ),
      const Divider(height: 6),
      // M 光标时间标签开关（勾选态；光标顶部徽章显示/隐藏时间值）。
      MenuItemButton(
        onPressed: () => widget.onToggleMCursorLabel?.call(),
        style: itemStyle,
        trailingIcon: widget.mCursorLabelVisible
            ? const Icon(Icons.check, size: 14)
            : null,
        child: const Text('M光标时间标签', style: labelStyle),
      ),
      // M 光标可见性开关：隐藏时光标线/标签与依赖光标的放置项全部
      // 禁用（位置保留，左键重新放置自动恢复）。
      MenuItemButton(
        onPressed: () => widget.onToggleMCursorVisible?.call(),
        style: itemStyle,
        child: Text(widget.mCursorVisible ? '隐藏M光标' : '显示M光标',
            style: labelStyle),
      ),
      const Divider(height: 6),
      // 进入基线标注模式（与工具栏 Dimension Baseline 按钮同功能）。
      MenuItemButton(
        onPressed: () => widget.onDimEnter?.call(),
        style: itemStyle,
        child: const Text('进入基线标注模式', style: labelStyle),
      ),
      // 进入连续标注模式（与工具栏 Dimension Continue 按钮同功能）。
      MenuItemButton(
        onPressed: () => widget.onDimEnterContinue?.call(),
        style: itemStyle,
        child: const Text('进入连续标注模式', style: labelStyle),
      ),
      // 删除标注：清除全部标注（竖线与标注段；无标注时置灰）。
      MenuItemButton(
        onPressed: widget.dimLines.isNotEmpty || widget.dimSpans.isNotEmpty
            ? () => widget.onDimClearAll?.call()
            : null,
        style: itemStyle,
        child: const Text('删除标注', style: labelStyle),
      ),
    ];
  }

  /// 信号上距 [t] 最近的跳变沿时刻（二分查找插入点后比较两侧）。
  static double? _nearestEdge(VcdSignal s, double t) {
    final ch = s.changes;
    if (ch.isEmpty) return null;
    var lo = 0, hi = ch.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (ch[mid].time <= t) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    double? best;
    if (lo < ch.length) best = ch[lo].time.toDouble();
    if (lo > 0) {
      final cand = ch[lo - 1].time.toDouble();
      if (best == null || (cand - t).abs() < (best - t).abs()) best = cand;
    }
    return best;
  }

  /// 左键点击/右键时按 y 坐标命中显示行并选中其信号（整信号行/位行
  /// 命中其宿主信号；分隔符/位分组间隔/模拟占位行不改动选中）。可变
  /// 行高（分隔符 12px、位分组间隔 6px）累计定位，与左栏右键命中
  /// 同口径。
  void _selectSignalAt(double localY) {
    final cb = widget.onSelectSignal;
    if (cb == null) return;
    final scrollY = widget.scrollController != null &&
            widget.scrollController!.hasClients
        ? widget.scrollController!.offset
        : 0.0;
    final y = localY - _WaveCanvas.rulerHeight + scrollY;
    if (y < 0) return;
    var acc = 0.0;
    for (final r in widget.rows) {
      final rh = r.gap
          ? kWaveGapHeight
          : r.separator
              ? kWaveSeparatorHeight
              : _WaveCanvas.rowHeight;
      if (y >= acc && y < acc + rh) {
        if (!r.gap && !r.separator && !r.spacer && r.signal != null) {
          var sig = r.signal!;
          if (r.bit != null) {
            // 位行的 signal 是从总线派生的 1 位信号（不在显示列表
            // 中，直接上报其名字会选中落空——整表 indexWhere 失配）：
            // 命中宿主总线信号。
            final cut = sig.path.lastIndexOf('[');
            final hostPath = cut > 0 ? sig.path.substring(0, cut) : sig.path;
            final host =
                widget.signals.where((s) => s.path == hostPath).firstOrNull;
            if (host == null) return;
            sig = host;
          }
          cb(sig.name);
        }
        return;
      }
      acc += rh;
    }
  }

  /// 时间线标签拖动：被拖标签的时间线皮秒值与抓取点相对标签顶的
  /// 偏移（null = 未在拖）。
  int? _tlDragPs;
  double _tlDragGrabDy = 0;

  /// 命中时间线标签（布局与绘制共用 [_WaveOverlayPainter.tlLabelLayout]）：
  /// 命中返回（时间线 ps, 抓取点距标签顶偏移），未命中 null。
  (int, double)? _hitTlLabel(Offset pos) {
    for (var i = 0; i < widget.timelines.length; i++) {
      final lay = _WaveOverlayPainter.tlLabelLayout(
        i,
        widget.timelines[i],
        widget.startPs,
        widget.psPerPixel,
        widget.cursorPs,
        _lastCanvasWidth,
        widget.tlLabelDy,
      );
      if (lay != null && lay.$1.contains(pos)) {
        return (widget.timelines[i], pos.dy - lay.$1.top);
      }
    }
    return null;
  }

  @override
  void didUpdateWidget(covariant _WaveCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 进入基线标注模式时夺取键盘焦点（悬停 + Del 删除不依赖先点击
    // 画布——否则焦点还在工具栏按钮上）。
    if (widget.dimActive && !oldWidget.dimActive) {
      _keyFocus.requestFocus();
    }
  }

  /// Del：删除悬停高亮目标（标注段优先 → 仅该段；否则竖线 → 该线
  /// 与以其为端点的标注段）。仅标注编辑模式进行中有效。删除后清除
  /// 悬停状态（目标已不存在，否则残留的悬停序号会让后续新放的线
  /// 误高亮）。
  KeyEventResult _onDimKeyEvent(FocusNode node, KeyEvent e) {
    if (e is KeyDownEvent &&
        e.logicalKey == LogicalKeyboardKey.delete &&
        widget.dimActive) {
      if (_dimHoverSpan != null) {
        widget.onDimDeleteSpan?.call(_dimHoverSpan!);
      } else if (_dimHoverLine != null) {
        widget.onDimDeleteLine?.call(_dimHoverLine!);
      } else {
        return KeyEventResult.ignored;
      }
      setState(() {
        _dimHoverLine = null;
        _dimHoverSpan = null;
      });
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    // 记录画布宽度（右键菜单的光标在视口内判定用；build 期间不能
    // 读 context.size，布局后经此字段取用）。
    return Focus(
      focusNode: _keyFocus,
      onKeyEvent: _onDimKeyEvent,
      child: LayoutBuilder(
      builder: (context, cons) {
        _lastCanvasWidth = cons.maxWidth;
        _lastCanvasHeight = cons.maxHeight;
        return Stack(
      children: [
        Listener(
          behavior: HitTestBehavior.translucent,
      onPointerDown: (e) {
        // 夺取键盘焦点：Del 删除高亮标注依赖画布持焦。
        _keyFocus.requestFocus();
        // 左键按住时间线标签：上下拖动标签位置（优先于框选/光标）。
        if (e.buttons == kPrimaryButton && !_altDown && !_ctrlDown) {
          // 标注的拖动（标注段整行上下、竖线左右带吸附）仅在标注
          // 编辑模式进行中可用——退出模式后标注不可改动。
          if (widget.dimActive) {
            // 标注段（标签/箭头线）：整行上下拖动（优先于竖线）。
            final s = _hitDimSpan(e.localPosition);
            if (s != null) {
              setState(() {
                _dimDragSpan = s.$1;
                _dimDragGrabDy = s.$2;
              });
              return;
            }
            // 标注竖线：左右拖动（跳变沿吸附，关联段端点跟随）。
            final li = _hitDimLine(e.localPosition);
            if (li != null) {
              setState(() => _dimDragLine = li);
              return;
            }
          }
          final hit = _hitTlLabel(e.localPosition);
          if (hit != null) {
            setState(() {
              _tlDragPs = hit.$1;
              _tlDragGrabDy = hit.$2;
            });
            return;
          }
        }
        // Alt + 左键：框选放大（原右键框选迁移至此）。
        if (e.buttons == kPrimaryButton && _altDown) {
          setState(() {
            _selStartX = e.localPosition.dx;
            _selCurrentX = _selStartX;
          });
        } else if (e.buttons == kSecondaryButton) {
          // 标注编辑模式中右键：退出模式（不弹菜单）。
          if (widget.dimActive) {
            widget.onDimExit?.call();
            return;
          }
          // 右键：先自动选中光标所在行的信号（分隔符/间隔行不动），
          // 再弹出菜单（计数值/时间线放置、清除时间线、时间线跳转）。
          _selectSignalAt(e.localPosition.dy);
          _menuController.open(position: e.localPosition);
        }
      },
      onPointerMove: (e) {
        // 标注段拖动中：目标 y 钳位后按行间距取整，回写覆盖行号。
        if (_dimDragSpan != null) {
          final desiredY = math.max(_WaveCanvas.rulerHeight + 18,
              e.localPosition.dy - _dimDragGrabDy);
          widget.onDimSpanRow
              ?.call(_dimDragSpan!, _dimRowAtY(desiredY));
          return;
        }
        // 标注竖线拖动中：吸附跳变沿更新时刻（关联段端点跟随）。
        if (_dimDragLine != null) {
          widget.onDimMoveLine
              ?.call(_dimDragLine!, _snapPs(e.localPosition.dx));
          return;
        }
        // 时间线标签拖动中：更新标签顶 y（钳位不超出画布上缘）。
        if (_tlDragPs != null) {
          widget.onTlLabelDrag?.call(
            _tlDragPs!,
            math.max(0.0, e.localPosition.dy - _tlDragGrabDy),
          );
          return;
        }
        if (_selStartX != null) {
          setState(() => _selCurrentX = e.localPosition.dx);
        }
      },
      onPointerUp: (e) {
        if (_dimDragSpan != null || _dimDragLine != null) {
          final wasLineDrag = _dimDragLine != null;
          setState(() {
            _dimDragSpan = null;
            _dimDragLine = null;
          });
          // 竖线拖动结束：按时间重排。
          if (wasLineDrag) widget.onDimDragEnd?.call();
          return;
        }
        if (_tlDragPs != null) {
          setState(() => _tlDragPs = null);
          return;
        }
        final x0 = _selStartX, x1 = _selCurrentX;
        if (x0 != null && x1 != null) {
          setState(() {
            _selStartX = null;
            _selCurrentX = null;
          });
          if ((x0 - x1).abs() >= 10) {
            final left = math.min(x0, x1);
            final right = math.max(x0, x1);
            widget.onZoomRange(
              widget.startPs + left * widget.psPerPixel,
              widget.startPs + right * widget.psPerPixel,
            );
          }
        }
      },
      onPointerCancel: (_) {
        if (_tlDragPs != null) setState(() => _tlDragPs = null);
        if (_dimDragSpan != null || _dimDragLine != null) {
          setState(() {
            _dimDragSpan = null;
            _dimDragLine = null;
          });
        }
      },
      onPointerSignal: (e) {
        if (e is PointerScrollEvent) {
          // 与示波器模块完全一致的手势：
          // Shift+滚轮忽略；Ctrl+滚轮缩放（exp 平滑曲线、鼠标位置锚点）；
          // 普通滚轮左右平移。
          final keys = HardwareKeyboard.instance.logicalKeysPressed;
          if (keys.contains(LogicalKeyboardKey.shiftLeft) ||
              keys.contains(LogicalKeyboardKey.shiftRight)) {
            return;
          }
          final isCtrl =
              keys.contains(LogicalKeyboardKey.controlLeft) ||
              keys.contains(LogicalKeyboardKey.controlRight);
          if (isCtrl) {
            // 示波器域 scale=px/点、缩小即拉远；本域 psPerPixel 相反，
            // 指数取正（dy>0 向下滚 → 拉远）。
            final factor = math.exp(e.scrollDelta.dy / 500.0);
            final anchorPs =
                widget.startPs + e.localPosition.dx * widget.psPerPixel;
            widget.onZoom(factor, anchorPs);
          } else {
            widget.onPan(e.scrollDelta.dy * widget.psPerPixel);
          }
        }
      },
      child: MouseRegion(
        // Ctrl：左右箭头（快速平移）；Alt：十字准星（框选放大）。
        // （Flutter 系统光标无矩形框图标，以准星代替。）
        // 标注编辑模式：悬停标注段（时间标注/双头横线）→ 上下箭头
        //（可整行上下拖动）；悬停竖线 → 左右箭头（可左右拖动）；拖动
        // 中保持对应光标；空白处十字准星（左键放线）。
        cursor: _ctrlDown
            ? SystemMouseCursors.resizeLeftRight
            : _altDown
            ? SystemMouseCursors.precise
            : widget.dimActive
                ? _dimDragSpan != null || _dimHoverSpan != null
                    ? SystemMouseCursors.resizeUpDown
                    : _dimDragLine != null || _dimHoverLine != null
                        ? SystemMouseCursors.resizeLeftRight
                        : SystemMouseCursors.precise
                : MouseCursor.defer,
        // 标注编辑模式：实心黄线跟随鼠标（吸附跳变沿后的预览位置）；
        // 悬停到既有标注段（时间标注+双头横线）或竖线时记录高亮目标
        //（段优先），跟随黄线让位。
        onHover: (e) {
          if (widget.dimActive) {
            final s = _hitDimSpan(e.localPosition)?.$1;
            if (s != _dimHoverSpan) setState(() => _dimHoverSpan = s);
            final li = s != null ? null : _hitDimLine(e.localPosition);
            if (li != _dimHoverLine) setState(() => _dimHoverLine = li);
            final ps = _snapPs(e.localPosition.dx);
            if (ps != _dimHoverPs) setState(() => _dimHoverPs = ps);
          }
        },
        onExit: (_) {
          if (_dimHoverPs != null ||
              _dimHoverLine != null ||
              _dimHoverSpan != null) {
            setState(() {
              _dimHoverPs = null;
              _dimHoverLine = null;
              _dimHoverSpan = null;
            });
          }
        },
        child: GestureDetector(
          // 左键：放置/拖动 M 光标线（16px 内吸附最近跳变沿）；Ctrl+左键：
          // 3 倍速快速平移；Alt 框选期间不平移不置光标；标注编辑模式中
          // 不移动光标（左键用于放置竖线）。
          onHorizontalDragUpdate: (d) {
            if (_tlDragPs != null ||
                _dimDragSpan != null ||
                _dimDragLine != null ||
                _selStartX != null ||
                _altDown) {
              return;
            }
            if (_ctrlDown) {
              widget.onPan(-d.delta.dx * 3.0 * widget.psPerPixel);
            } else if (!widget.dimActive) {
              _snapCursorTo(d.localPosition.dx);
            }
          },
          // 按在时间线标签上时不放光标（标签拖动优先；Listener 的命中
          // 在 GestureDetector 之后处理，这里需自行判一次）。点击同时
          // 选中所在行信号（分隔符/间隔行不动），与右键命中同口径。
          // 标注编辑模式：左键在空白处放置竖线（跳变沿吸附，按当前
          // 标注风格生成标注段）；点在既有标注（竖线/标注段拖动把手）
          // 上不放置。
          onTapDown: (d) {
            _selectSignalAt(d.localPosition.dy);
            if (widget.dimActive) {
              if (_dimDragSpan == null &&
                  _dimDragLine == null &&
                  _hitDimSpan(d.localPosition) == null &&
                  _hitDimLine(d.localPosition) == null) {
                widget.onDimPlaceLine?.call(_snapPs(d.localPosition.dx));
              }
              return;
            }
            if (_hitTlLabel(d.localPosition) == null) {
              _snapCursorTo(d.localPosition.dx);
            }
          },
          child: ClipRect(
            child: CustomPaint(
              size: Size.infinite,
              painter: WavePainter(
                vcd: widget.vcd,
                rows: widget.rows,
                psPerPixel: widget.psPerPixel,
                startPs: widget.startPs,
                selectedIndex: widget.selectedRowIndex,
                counters: widget.counters,
                scrollController: widget.scrollController,
                busFormats: widget.busFormats,
                analogBuses: widget.analogBuses,
                analogSpans: widget.analogSpans,
                busColorSpaces: widget.busColorSpaces,
                busColorLowFirst: widget.busColorLowFirst,
                // 标注竖线绘制在底层（波形之上层透出）；悬停高亮仅
                // 编辑模式进行中生效。
                dimLines: widget.dimLines,
                dimSpans: widget.dimSpans,
                dimHoverLine: widget.dimActive ? _dimHoverLine : null,
                dimRowsBottom: _rowsBottom(),
              ),
              // M 光标线/时间线标记/标注与框选高亮放前景层：拖动
              // 光标/框选时波形本体（数据遍历绘制）完全不重绘，只画这
              // 几条线。
              foregroundPainter: _WaveOverlayPainter(
                // M 光标被「隐藏M光标」隐藏时按无光标绘制（位置保留）。
                cursorPs: widget.mCursorVisible ? widget.cursorPs : null,
                cursorLabelVisible: widget.mCursorLabelVisible,
                startPs: widget.startPs,
                psPerPixel: widget.psPerPixel,
                selStartX: _selStartX,
                selCurrentX: _selCurrentX,
                timelines: widget.timelines,
                tlLabelDy: widget.tlLabelDy,
                dimLines: widget.dimLines,
                dimSpans: widget.dimSpans,
                dimHoverPs: widget.dimActive ? _dimHoverPs : null,
                dimHoverLine: widget.dimActive ? _dimHoverLine : null,
                dimHoverSpan: widget.dimActive ? _dimHoverSpan : null,
                dimRowsBottom: _rowsBottom(),
                scrollController: widget.scrollController,
              ),
            ),
          ),
        ),
      ),
        ),
        // 右键菜单锚点：1x1 置于画布左上角（坐标系与画布一致，
        // open(position:) 直接用画布坐标）。锚点子组件必须尽量小：
        // RawMenuAnchor 会把锚点子组件包进与菜单同组的 TapRegion，
        // 若锚点覆盖整个画布，画布上的点击全部被误判为「组内点击」，
        // 菜单永远不会因外部点击而关闭。
        Positioned(
          left: 0,
          top: 0,
          child: MenuAnchor(
            controller: _menuController,
            menuChildren: _buildMenuChildren(),
            child: const SizedBox(width: 1, height: 1),
          ),
        ),
      ],
      );
    },
    ),
    );
  }
}

/// 画 1px 竖直虚线（M 光标用，GTKWave 风格：4px 实 / 4px 空）。
/// [avoid] 非空时跳过与其中矩形相交的段（M 光标线避让标注元素：
/// tn 徽章/标注段横线与标签/时间线标签）。
void drawDashedVLine(Canvas canvas, double x, double height, Paint paint,
    [List<Rect> avoid = const []]) {
  const dash = 4.0, gap = 4.0;
  for (var y = 0.0; y < height; y += dash + gap) {
    if (avoid.isNotEmpty) {
      final seg = Rect.fromLTWH(x - 0.5, y, 1, math.min(dash, height - y));
      var blocked = false;
      for (final r in avoid) {
        if (seg.overlaps(r)) {
          blocked = true;
          break;
        }
      }
      if (blocked) continue;
    }
    canvas.drawLine(
      Offset(x, y),
      Offset(x, math.min(y + dash, height)),
      paint,
    );
  }
}

/// 前景层：M 光标线（M 标签可带时间值，自动避开波形与标注）+
/// 时间线标记（T1/T2… 虚线与时间标签）+ Alt 框选的区间高亮。
/// 与波形本体分层后，拖动 M 光标不再触发波形数据的重绘遍历。
class _WaveOverlayPainter extends CustomPainter {
  final int? cursorPs;

  /// M 光标时间标签显示开关：true = 顶部红色徽章显示 `M  时间`，
  /// false = 只显示 M。
  final bool cursorLabelVisible;
  final double startPs;
  final double psPerPixel;
  final double? selStartX;
  final double? selCurrentX;

  /// 时间线标记（皮秒，按放置顺序编号 T1/T2…）。
  final List<int> timelines;

  /// 标签纵向位置覆盖（键=时间线皮秒值，值=标签顶 y；点住标签上下
  /// 拖动设定）。无覆盖时按编号轮转默认位。
  final Map<int, double> tlLabelDy;

  /// Dimension 标注的竖线时刻（皮秒，全部按时间升序）与标注段
  ///（from→to 均为竖线时刻；row=纵向拖动覆盖的行号，null=自动
  /// 分配）。基线/连续两种标注法放置的段混合共存于同一竖线体系。
  final List<int> dimLines;
  final List<({int from, int to, int? row})> dimSpans;

  /// 标注编辑模式中跟随鼠标的预览竖线时刻（实心黄线；null = 鼠标
  /// 不在画布内或模式未开启）。
  final int? dimHoverPs;

  /// 悬停高亮的黄色（与预览跟随线同色）。
  static const dimHoverColor = Color(0xFFFFFF00);

  /// 模式中鼠标悬停的竖线索引（该线与以其为端点的标注段高亮；
  /// null=未悬停——显示跟随黄线）。
  final int? dimHoverLine;

  /// 模式中鼠标悬停的标注段索引（仅该段时间标注与双头横线高亮，
  /// 跟随黄线消失；null=未悬停到标注段）。
  final int? dimHoverSpan;

  /// 显示行的总底沿（未减滚动偏移）：标注组基准与徽章位置的依据。
  final double dimRowsBottom;

  /// 垂直滚动控制器（读取滚动偏移使「Signal 列表下方」跟随滚动；
  /// 本体层的 repaint 监听带动本层重绘）。
  final ScrollController? scrollController;

  /// 时间线标记的琥珀色（虚线；标签底色为半透明黑，见 paint）。
  static const _tlColor = Color(0xFFFFB300);

  /// 基线标注的白色（箭头线/时间标注/tn 徽章同款；竖线为 30 度灰
  /// [dimLineColor]）。
  static const dimColor = Colors.white;

  /// 基线/测量竖线的 30 度灰（1px；波形底层的标注线不抢眼；tn 徽章
  /// 下方段改用白色 [dimColor]）。
  static const dimLineColor = Color(0xFF4D4D4D);

  _WaveOverlayPainter({
    required this.cursorPs,
    this.cursorLabelVisible = true,
    required this.startPs,
    required this.psPerPixel,
    this.selStartX,
    this.selCurrentX,
    this.timelines = const [],
    this.tlLabelDy = const {},
    this.dimLines = const [],
    this.dimSpans = const [],
    this.dimHoverPs,
    this.dimHoverLine,
    this.dimHoverSpan,
    this.dimRowsBottom = 0,
    this.scrollController,
  });

  /// 皮秒转紧凑时间文本（时间线标签用）。
  static String _fmtT(double ps) {
    final ns = ps / 1000;
    if (ns >= 1000) return '${(ns / 1000).toStringAsFixed(3)}us';
    return '${ns.toStringAsFixed(2)}ns';
  }

  /// 时间线标签的布局（绘制与命中测试共用）：屏外返回 null。
  /// 返回标签矩形与文本（标签文本含时间值，有 M 光标时附 ΔT）。
  static (Rect, TextPainter)? tlLabelLayout(
    int index,
    int ps,
    double startPs,
    double psPerPixel,
    int? cursorPs,
    double width,
    Map<int, double> labelDy,
  ) {
    final tx = (ps - startPs) / psPerPixel;
    if (tx < 0 || tx > width) return null;
    final tPs = ps.toDouble();
    final buf = StringBuffer('T${index + 1}  ${_fmtT(tPs)}');
    if (cursorPs != null) {
      final d = tPs - cursorPs;
      buf.write('\nΔ${d >= 0 ? '+' : '-'}${_fmtT(d.abs())}');
    }
    final tp = TextPainter(
      text: TextSpan(
        text: buf.toString(),
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.bold,
          color: Colors.white,
          fontFamily: 'Consolas',
          height: 1.25,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    // 标签纵坐标：拖动覆盖优先，否则按编号轮转避免相邻遮挡。
    final ly = labelDy[ps] ?? (1.0 + (index % 3) * (tp.height + 5));
    final lx =
        tx + 2 + tp.width + 6 <= width ? tx + 2 : tx - tp.width - 8;
    return (Rect.fromLTWH(lx, ly, tp.width + 6, tp.height + 3), tp);
  }

  /// 皮秒格式化（千分位逗号，不补零）：基线标注 ΔT 用（`2,446 ps`）。
  static String _fmtPsGroup(int ps) {
    final s = ps.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }

  /// 标注组箭头线的基准 y（Signal 列表下方，滚动跟随）。
  static double dimGroupsBaseY(double rowsBottom, double scrollY) =>
      rowsBottom - scrollY + 60;

  /// 含画布高度钳位的基准 y（绘制/命中共用）。
  static double dimGroupsBaseYAt(
      double rowsBottom, double scrollY, double height) {
    return dimGroupsBaseY(rowsBottom, scrollY)
        .clamp(_WaveCanvas.rulerHeight + 8, height - 40)
        .toDouble();
  }

  /// 标注段的行分配（绘制/命中/截断共用）：返回每段的行号（0 起，
  /// 行间距 34）。手动行覆盖（row != null）优先占位；其余按 from
  /// 升序（同 from 按 to 升序——短段在上）贪心分配到首个不重叠的
  /// 行（端点相接不算重叠——链式段可同一行）。
  static List<int> dimSpanRows(List<({int from, int to, int? row})> spans) {
    final lastTo = <int>[];
    final result = List<int>.filled(spans.length, 0);
    for (var i = 0; i < spans.length; i++) {
      final r = spans[i].row;
      if (r == null) continue;
      while (lastTo.length <= r) {
        lastTo.add(-1);
      }
      lastTo[r] = math.max(lastTo[r], spans[i].to);
      result[i] = r;
    }
    final order = [
      for (var i = 0; i < spans.length; i++)
        if (spans[i].row == null) i,
    ]..sort((a, b) => spans[a].from != spans[b].from
        ? spans[a].from.compareTo(spans[b].from)
        : spans[a].to.compareTo(spans[b].to));
    for (final i in order) {
      var r = 0;
      for (;;) {
        while (lastTo.length <= r) {
          lastTo.add(-1);
        }
        if (lastTo[r] <= spans[i].from) break;
        r++;
      }
      lastTo[r] = spans[i].to;
      result[i] = r;
    }
    return result;
  }

  /// 标注段的布局（绘制/命中/截断共用）：箭头线 y = baseY + 行号*34，
  /// 标签居中于横线上方（下沿 = 箭头线 y - 3）。返回箭头线 y、箭头
  /// 线命中矩形（±4px）与标签矩形/文本（ΔT 值）。
  /// 标签水平位置：**线段与视口可见区（[width]）交集的中心**——波形
  /// 放大/平移使线段自然中点移出屏幕时，时间标注仍显示在可见部分的
  /// 中心（随视口边缘滑动），标签矩形钳位进视口（窄交集不探出屏外）；
  /// 交集为空（线段完全屏外）时标签保持屏外的自然中点位置——不显示
  ///（钳位只用于非空交集，否则屏外标签会被吸到屏幕边缘叠到相邻线段
  /// 上）。
  static ({double arrowY, Rect arrowRect, Rect labelRect, TextPainter tp})
      dimSpanLayout(
    int index,
    List<({int from, int to, int? row})> spans,
    List<int> rows,
    double startPs,
    double psPerPixel,
    double baseY, {
    double width = double.infinity,
  }) {
    final s = spans[index];
    final xa = (s.from - startPs) / psPerPixel;
    final xb = (s.to - startPs) / psPerPixel;
    final arrowY = baseY + rows[index] * 34;
    final tp = TextPainter(
      text: TextSpan(
        text: '${_fmtPsGroup(s.to - s.from)} ps',
        style: const TextStyle(
          fontSize: 13,
          fontStyle: FontStyle.italic,
          color: dimColor,
          fontFamily: 'Consolas',
          height: 0.97,
        ),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout();
    // 可见区中心定位：自然中点屏外时标签贴在可见部分中心；线段
    // 完全屏外时标签保持屏外（不显示——钳位只用于非空交集，否则会
    // 把屏外标签吸到屏幕边缘叠到相邻线段上）。
    final left = math.min(xa, xb), right = math.max(xa, xb);
    final visL = left.clamp(0.0, width), visR = right.clamp(0.0, width);
    final lw = tp.width + 6;
    final double llx;
    if (visR > visL) {
      final midX = (visL + visR) / 2;
      llx = (midX - lw / 2)
          .clamp(1.0, math.max(1.0, width - lw - 1))
          .toDouble();
    } else {
      llx = (xa + xb) / 2 - lw / 2;
    }
    final labelRect = Rect.fromLTWH(
      llx,
      arrowY - 3 - tp.height - 1,
      lw,
      tp.height + 2,
    );
    final arrowRect =
        Rect.fromLTWH(math.min(xa, xb), arrowY - 4, (xb - xa).abs(), 8);
    return (arrowY: arrowY, arrowRect: arrowRect, labelRect: labelRect, tp: tp);
  }

  /// tn 徽章的布局（本体层截断竖线与覆盖层画徽章共用）：圆角矩形
  ///（文字 +8px 宽、+3px 高），水平与竖线中对齐。
  static (Rect, TextPainter) dimBadgeLayout(
      int index, double x, double? labelY, double width, Color color) {
    final tp = TextPainter(
      text: TextSpan(
        text: 't$index',
        style: TextStyle(
          fontSize: 11,
          fontStyle: FontStyle.italic,
          color: color,
          fontFamily: 'Consolas',
          height: 1.25,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final bw = tp.width + 8;
    final bx =
        (x - bw / 2).clamp(1.0, math.max(1.0, width - bw - 1)).toDouble();
    final by = labelY ?? _WaveCanvas.rulerHeight + 2;
    return (Rect.fromLTWH(bx, by, bw, tp.height + 3), tp);
  }

  /// 绘制 Dimension 标注（覆盖层）：tn 徽章 + 标注段（双头横线 +
  /// ΔT 标注，两种标注法的段混合共存）+ 跟随黄线。竖线由本体层
  ///（WavePainter）在波形之下绘制（竖线自动截断的段布局口径与本层
  /// 一致）。
  /// 悬停高亮：悬停竖线 → 该线与以其为端点的标注段黄；悬停标注段
  /// → 仅该段黄；两者都让位掉跟随黄线。
  void _paintDimBaseline(Canvas canvas, Size size) {
    // 悬停高亮判定（越界防护：删除后悬停索引可能滞后一拍）。
    final hover =
        dimHoverLine != null && dimHoverLine! < dimLines.length
            ? dimHoverLine
            : null;
    final hoverSpan =
        dimHoverSpan != null && dimHoverSpan! < dimSpans.length
            ? dimHoverSpan
            : null;
    // 滚动偏移（垂直滚动时 Signal 列表下方位置跟随）。
    final scrollY = scrollController != null && scrollController!.hasClients
        ? scrollController!.offset
        : 0.0;
    // tn 徽章位置：Signal 列表下方（滚动跟随；与模式无关——退出标注
    // 模式后不回到时间尺下沿）。
    final labelY = (dimRowsBottom - scrollY + 4)
        .clamp(_WaveCanvas.rulerHeight + 2, size.height - 16)
        .toDouble();
    final baseY = dimGroupsBaseYAt(dimRowsBottom, scrollY, size.height);
    final rows = dimSpanRows(dimSpans);
    // tn 徽章（圆角矩形 + 中对齐，描边/文字随线色）。
    for (var i = 0; i < dimLines.length; i++) {
      final x = (dimLines[i] - startPs) / psPerPixel;
      if (x < -2 || x > size.width + 2) continue;
      final color = hover == i ? dimHoverColor : dimColor;
      final (badgeRect, tp) =
          dimBadgeLayout(i, x, labelY, size.width, color);
      canvas
        ..drawRRect(
          RRect.fromRectAndRadius(badgeRect, const Radius.circular(5)),
          Paint()..color = Colors.black.withValues(alpha: 0.6),
        )
        ..drawRRect(
          RRect.fromRectAndRadius(badgeRect, const Radius.circular(5)),
          Paint()
            ..color = color
            ..strokeWidth = 1
            ..style = PaintingStyle.stroke,
        );
      tp.paint(canvas, Offset(badgeRect.left + 4, badgeRect.top + 1.5));
    }
    // 标注段：双头横线 + 标签（半透明黑底压住竖线即「截断」效果）。
    for (var i = 0; i < dimSpans.length; i++) {
      final s = dimSpans[i];
      final lay = dimSpanLayout(
          i, dimSpans, rows, startPs, psPerPixel, baseY,
          width: size.width);
      // 悬停段本身，或悬停竖线是以其为端点的线。
      final highlighted = hoverSpan == i ||
          (hover != null &&
              (s.from == dimLines[hover] || s.to == dimLines[hover]));
      final spanColor = highlighted ? dimHoverColor : dimColor;
      final xa = (s.from - startPs) / psPerPixel;
      final xb = (s.to - startPs) / psPerPixel;
      final y = lay.arrowY;
      final arrowPaint = Paint()
        ..color = spanColor
        ..strokeWidth = 1;
      canvas.drawLine(Offset(xa, y), Offset(xb, y), arrowPaint);
      // 两端实心三角箭头（指向外侧竖线）。
      const hl = 6.0, hw = 3.5;
      final left = math.min(xa, xb), right = math.max(xa, xb);
      canvas.drawPath(
          Path()
            ..moveTo(left, y)
            ..lineTo(left + hl, y - hw)
            ..lineTo(left + hl, y + hw)
            ..close(),
          arrowPaint);
      canvas.drawPath(
          Path()
            ..moveTo(right, y)
            ..lineTo(right - hl, y - hw)
            ..lineTo(right - hl, y + hw)
            ..close(),
          arrowPaint);
      // 标签：半透明黑底（压住竖线即「截断」效果；无描边）。
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          lay.labelRect,
          topRight: const Radius.circular(5),
          bottomRight: const Radius.circular(5),
        ),
        Paint()..color = Colors.black.withValues(alpha: 0.6),
      );
      // 高亮时标签文字换黄色（标签文本在布局阶段绘制，此处覆盖重绘，
      // 样式与布局阶段一致）。
      if (spanColor == dimColor) {
        lay.tp.paint(
            canvas, Offset(lay.labelRect.left + 3, lay.labelRect.top + 1));
      } else {
        final tp = TextPainter(
          text: TextSpan(
            text: lay.tp.text!.toPlainText(),
            style: const TextStyle(
              fontSize: 13,
              fontStyle: FontStyle.italic,
              color: dimHoverColor,
              fontFamily: 'Consolas',
              height: 0.97,
            ),
          ),
          textAlign: TextAlign.center,
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(
            canvas, Offset(lay.labelRect.left + 3, lay.labelRect.top + 1));
      }
    }
    // 模式下跟随鼠标的黄色虚线（1px，吸附后的预览位置，画在最上层；
    // 悬停到既有竖线或标注段时让位给高亮）。
    final hoverPs = dimHoverPs;
    if (hoverPs != null && hover == null && hoverSpan == null) {
      final x = (hoverPs - startPs) / psPerPixel;
      if (x >= 0 && x <= size.width) {
        drawDashedVLine(
          canvas,
          x,
          size.height,
          Paint()
            ..color = dimHoverColor
            ..strokeWidth = 1,
        );
      }
    }
  }

  /// 标注占用矩形（M 标签避让与 M 光标线截断共用）：tn 徽章 + 标注段
  /// 标签/横线 + 时间线标签。
  static List<Rect> dimOccupiedRects(
    double rowsBottom,
    double scrollY,
    double height,
    double width,
    List<int> dimLines,
    List<({int from, int to, int? row})> dimSpans,
    List<int> timelines,
    Map<int, double> tlLabelDy,
    int? cursorPs,
    double startPs,
    double psPerPixel,
  ) {
    final occupied = <Rect>[];
    final labelY = (rowsBottom - scrollY + 4)
        .clamp(_WaveCanvas.rulerHeight + 2, height - 16)
        .toDouble();
    for (var i = 0; i < dimLines.length; i++) {
      final x = (dimLines[i] - startPs) / psPerPixel;
      occupied.add(dimBadgeLayout(i, x, labelY, width, dimColor).$1);
    }
    if (dimSpans.isNotEmpty) {
      final baseY = dimGroupsBaseYAt(rowsBottom, scrollY, height);
      final rows = dimSpanRows(dimSpans);
      for (var i = 0; i < dimSpans.length; i++) {
        final lay = dimSpanLayout(
            i, dimSpans, rows, startPs, psPerPixel, baseY,
            width: width);
        occupied
          ..add(lay.labelRect)
          ..add(lay.arrowRect);
      }
    }
    for (var i = 0; i < timelines.length; i++) {
      final lay = tlLabelLayout(
          i, timelines[i], startPs, psPerPixel, cursorPs, width, tlLabelDy);
      if (lay != null) occupied.add(lay.$1);
    }
    return occupied;
  }

  /// M 光标标签的布局（绘制用）：避让所有波形行与标注元素——候选
  /// 位置从 Signal 列表下方的标注区顶（rowsBottom - scrollY + 4）
  /// 开始逐行（标签高 + 4）下移，取首个不与 tn 徽章、标注段（横线/
  /// 标签）、时间线标签的占用矩形相交且仍在画布内的位置；标注区
  /// 不可见（列表滚出）或全被占用时退回时间尺顶（y=1）。
  /// 水平位置：光标线右侧（放不下时翻转到左侧）。
  static Rect mLabelLayout(
    double cx,
    double w,
    double h,
    double width,
    double height,
    double rowsBottom,
    double scrollY,
    List<int> dimLines,
    List<({int from, int to, int? row})> dimSpans,
    List<int> timelines,
    Map<int, double> tlLabelDy,
    int? cursorPs,
    double startPs,
    double psPerPixel,
  ) {
    final lx = cx + 2 + w <= width ? cx + 2 : cx - w - 2;
    Rect rectAt(double top) => Rect.fromLTWH(lx, top, w, h);
    final zoneTop = rowsBottom - scrollY + 4;
    final maxTop = height - h - 2;
    if (zoneTop >= _WaveCanvas.rulerHeight && zoneTop <= maxTop) {
      final occupied = dimOccupiedRects(rowsBottom, scrollY, height, width,
          dimLines, dimSpans, timelines, tlLabelDy, cursorPs, startPs,
          psPerPixel);
      for (var top = zoneTop; top <= maxTop; top += h + 4) {
        final r = rectAt(top);
        var hit = false;
        for (final o in occupied) {
          if (r.overlaps(o)) {
            hit = true;
            break;
          }
        }
        if (!hit) return r;
      }
    }
    // 无空位：退回时间尺顶（原位置；仅标注区不可见/全满时发生）。
    return rectAt(1);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final cur = cursorPs;
    // Dimension 标注（徽章 + 标注段）：在时间线/M 光标之下。
    _paintDimBaseline(canvas, size);
    // 时间线标记：琥珀色虚线 + 顶部 Tn 标签（时间值；有 M 光标时附 ΔT）。
    // 标签纵坐标按编号轮转，避免相邻标记的标签互相遮挡。
    for (var i = 0; i < timelines.length; i++) {
      final tx = (timelines[i] - startPs) / psPerPixel;
      if (tx < 0 || tx > size.width) continue;
      drawDashedVLine(
        canvas,
        tx,
        size.height,
        Paint()
          ..color = _tlColor
          ..strokeWidth = 1,
      );
      final lay = tlLabelLayout(
          i, timelines[i], startPs, psPerPixel, cur, size.width, tlLabelDy);
      if (lay == null) continue;
      final (rect, tp) = lay;
      // 标签底色更暗的半透明黑（不遮挡波形），右侧圆角（页面标签
      // 风格），白色 1px 描边，文字白色。
      final rrect = RRect.fromRectAndCorners(
        rect,
        topRight: const Radius.circular(6),
        bottomRight: const Radius.circular(6),
      );
      canvas
        ..drawRRect(
          rrect,
          Paint()..color = Colors.black.withValues(alpha: 0.6),
        )
        ..drawRRect(
          rrect,
          Paint()
            ..color = Colors.white
            ..strokeWidth = 1
            ..style = PaintingStyle.stroke,
        );
      tp.paint(canvas, Offset(rect.left + 3, rect.top + 1.5));
    }
    final sx0 = selStartX, sx1 = selCurrentX;
    if (sx0 != null && sx1 != null) {
      final x0 = math.min(sx0, sx1);
      final x1 = math.max(sx0, sx1);
      final rect = Rect.fromLTWH(x0, 0, x1 - x0, size.height);
      canvas.drawRect(
        rect,
        Paint()..color = Colors.white.withValues(alpha: 0.10),
      );
      canvas.drawRect(
        rect,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.7)
          ..strokeWidth = 1
          ..style = PaintingStyle.stroke,
      );
    }
    if (cur != null) {
      final cx = (cur - startPs) / psPerPixel;
      if (cx >= 0 && cx <= size.width) {
        final scrollY = scrollController != null &&
                scrollController!.hasClients
            ? scrollController!.offset
            : 0.0;
        // M 光标线：1px 亮红虚线，跳过所有标注占用矩形（避让 tn 徽章/
        // 标注段横线与标签/时间线标签——与 Dimension 竖线「止于最先
        // 碰到的标注元素」同口径；与 M 标签避让共用占用矩形）。
        drawDashedVLine(
          canvas,
          cx,
          size.height,
          Paint()
            ..color = const Color(0xFFFF1744)
            ..strokeWidth = 1,
          dimOccupiedRects(dimRowsBottom, scrollY, size.height, size.width,
              dimLines, dimSpans, timelines, tlLabelDy, cursorPs, startPs,
              psPerPixel),
        );
        // M 标签（开启时间标签时显示 `M  000,000,005,000 ps`——12 位
        // 补零千分位格式，与 Mcursor.time 同口径）。标签避让所有波形
        // 与标注（布局见 mLabelLayout）。
        final tp = TextPainter(
          text: TextSpan(
            text: cursorLabelVisible ? 'M  ${fmtPsSpaced(cur)}' : 'M',
            style: const TextStyle(
              // 字号为原 10 的 1.2 倍（15 的 0.8 倍）。
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        final rect = mLabelLayout(
          cx,
          tp.width + 6,
          tp.height + 3,
          size.width,
          size.height,
          dimRowsBottom,
          scrollY,
          dimLines,
          dimSpans,
          timelines,
          tlLabelDy,
          cursorPs,
          startPs,
          psPerPixel,
        );
        // 徽章：右侧圆角（与时间线 Tn 标签同风格）；翻转到光标线左侧
        // 时改为左侧圆角（文字同步内缩避开圆角）。
        final onRight = rect.left >= cx;
        canvas.drawRRect(
          RRect.fromRectAndCorners(
            rect,
            topLeft: onRight ? Radius.zero : const Radius.circular(6),
            bottomLeft: onRight ? Radius.zero : const Radius.circular(6),
            topRight: onRight ? const Radius.circular(6) : Radius.zero,
            bottomRight: onRight ? const Radius.circular(6) : Radius.zero,
          ),
          Paint()..color = const Color(0xFFFF1744),
        );
        tp.paint(canvas, Offset(rect.left + (onRight ? 3 : 5), rect.top + 1));
      }
    }
  }

  @override
  bool shouldRepaint(_WaveOverlayPainter old) =>
      old.cursorPs != cursorPs ||
      old.cursorLabelVisible != cursorLabelVisible ||
      old.startPs != startPs ||
      old.psPerPixel != psPerPixel ||
      old.selStartX != selStartX ||
      old.selCurrentX != selCurrentX ||
      !mapEquals(old.tlLabelDy, tlLabelDy) ||
      !listEquals(old.timelines, timelines) ||
      !listEquals(old.dimLines, dimLines) ||
      !listEquals(old.dimSpans, dimSpans) ||
      old.dimHoverPs != dimHoverPs ||
      old.dimHoverLine != dimHoverLine ||
      old.dimHoverSpan != dimHoverSpan ||
      old.dimRowsBottom != dimRowsBottom;
}

class WavePainter extends CustomPainter {
  final VcdFile vcd;

  /// 显示行（含总线位行与模拟占位行）：行号 i 对应 y0 = yBase + i*rowH。
  final List<WaveRow> rows;
  final double psPerPixel;
  final double startPs;

  /// 选中信号的显示行号（左栏点击信号名）：该行背景高亮暗蓝。
  final int? selectedIndex;

  /// 全局图模式：不画时间尺，行高压缩到全信号铺满画布，总线不写数值。
  final bool overview;

  /// 各信号的边沿计数标注（右键菜单「…上升/下降沿计数值」，
  /// 键=信号路径）。仅主视图绘制，全局图忽略。
  final Map<String, WaveCounter> counters;

  /// 与信号名列表共享的垂直滚动控制器：行偏移绘制（null = 不滚动，
  /// 全局图用）。同时作为 repaint Listenable，滚动时免重建重绘。
  final ScrollController? scrollController;

  /// 总线数据显示格式与等效模拟通道设定（键=信号路径）。
  final Map<String, BusDisplayFormat> busFormats;
  final Set<String> analogBuses;

  /// 模拟波形纵向占用的数字行数（键=信号路径，缺省 1）。
  final Map<String, int> analogSpans;

  /// 总线色彩解码设定（键=信号路径，缺省关闭）；[busColorLowFirst]
  /// 内路径的高字节承载第三通道（L/B/V）。仅主视图填充，全局图忽略。
  final Map<String, BusColorSpace> busColorSpaces;
  final Set<String> busColorLowFirst;

  /// Dimension 标注：竖线时刻列表与标注段绘制在底层（波形之上层在
  /// 半透明处透出竖线；标注段的横线/标签与 tn 徽章仍在覆盖层）。
  /// 两种标注法的段混合共存于同一竖线体系。
  final List<int> dimLines;
  final List<({int from, int to, int? row})> dimSpans;

  /// 悬停竖线索引（高亮黄色）。
  final int? dimHoverLine;

  /// 显示行的总底沿（未减滚动偏移）：标注段基准与徽章位置的依据。
  final double dimRowsBottom;

  WavePainter({
    required this.vcd,
    required this.rows,
    required this.psPerPixel,
    required this.startPs,
    this.selectedIndex,
    this.overview = false,
    this.counters = const {},
    this.scrollController,
    this.busFormats = const {},
    this.analogBuses = const {},
    this.analogSpans = const {},
    this.busColorSpaces = const {},
    this.busColorLowFirst = const {},
    this.dimLines = const [],
    this.dimSpans = const [],
    this.dimHoverLine,
    this.dimRowsBottom = 0,
  }) : super(repaint: scrollController);

  static const _trace = Color(0xFF4EC9B0);
  static const _bus = Color(0xFFCE9178);
  static const _xColor = Color(0xFFFF5555);
  static const _grid = Color(0xFF2D2D2D);
  static const _text = Color(0xFFFFFFFF);

  double _x(double ps) => (ps - startPs) / psPerPixel;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.black);
    final rowH = overview
        ? size.height / math.max(rows.length, 1)
        : _WaveCanvas.rowHeight;
    // 垂直滚动行偏移：与信号名列表共享控制器（仅主视图）。
    final scrollY =
        (!overview && scrollController != null && scrollController!.hasClients)
        ? scrollController!.offset
        : 0.0;
    final yBase = overview ? 0.0 : _WaveCanvas.rulerHeight - scrollY;
    if (!overview) _paintRuler(canvas, size);
    // 行区裁剪：垂直滚动时行内容上移，不得覆盖时间尺。
    if (!overview) {
      canvas.save();
      canvas.clipRect(
        Rect.fromLTWH(
          0,
          _WaveCanvas.rulerHeight,
          size.width,
          size.height - _WaveCanvas.rulerHeight,
        ),
      );
    }
    // 选中行背景高亮（暗蓝 #094771，与信号名行同款）。可变行高
    //（分隔符 12px、位分组间隔 6px）：累计行高定位选中行。
    final sel = selectedIndex;
    if (!overview && sel != null && sel >= 0 && sel < rows.length) {
      var selY = yBase;
      for (var i = 0; i < sel; i++) {
        selY += rows[i].separator
            ? kWaveSeparatorHeight
            : rows[i].gap
                ? kWaveGapHeight
                : _WaveCanvas.rowHeight;
      }
      canvas.drawRect(
        Rect.fromLTWH(0, selY, size.width, _WaveCanvas.rowHeight),
        Paint()..color = const Color(0xFF094771),
      );
    }
    // 基线标注竖线绘制在底层：先于波形轨迹，波形（半透明块/轨迹）
    // 盖在线上方。
    _paintDimLines(canvas, size, scrollY);
    final viewEnd = startPs + size.width * psPerPixel;
    // 可变行高（分隔符 12px、位分组间隔 6px）：累计行高推进 y0。
    var yRow = yBase;
    for (var i = 0; i < rows.length; i++) {
      final r = rows[i];
      final rh = r.gap
          ? kWaveGapHeight
          : r.separator
              ? kWaveSeparatorHeight
              : rowH;
      final y0 = yRow;
      yRow += rh;
      if (y0 > size.height) break;
      if (y0 + rh < (overview ? 0.0 : _WaveCanvas.rulerHeight)) continue;
      if (r.spacer) continue; // 模拟通道占位行：波形已随主行跨行绘制
      if (r.gap) continue; // 位分组间隔行：波形区留空（不画线）
      // 分隔符行：通栏横线（半通道高居中）。
      if (r.separator) {
        canvas.drawLine(
          Offset(0, y0 + rh / 2),
          Offset(size.width, y0 + rh / 2),
          Paint()..color = const Color(0xFF3A3A3A),
        );
        continue;
      }
      // 位行底色按每 4 位分组交替（半透明白 ≈ #202020，波形/标注线
      // 可透出；与信号面板同款）。
      if (!overview && r.bit != null && (r.bit! ~/ 4) % 2 == 0) {
        canvas.drawRect(
          Rect.fromLTWH(0, y0, size.width, rh),
          Paint()..color = Colors.white.withValues(alpha: 0.12),
        );
      }
      final s = r.signal!;
      if (s.isBus) {
        if (analogBuses.contains(s.path)) {
          // 模拟波形纵向占 N 个数字行高（X10/X20，占位行与其对齐）。
          _paintAnalog(
            canvas,
            s,
            y0,
            viewEnd,
            rowH * (analogSpans[s.path] ?? 1),
          );
        } else {
          _paintBus(canvas, s, y0, viewEnd, rowH);
        }
      } else {
        _paintScalar(canvas, s, y0, viewEnd, rowH);
        final counter = counters[s.path];
        if (!overview && counter != null) {
          _paintCounter(canvas, s, y0, viewEnd, counter);
        }
      }
    }
    if (!overview) canvas.restore();
  }

  /// 边沿计数标注（右键菜单「…上升/下降沿计数值」）：从起点时刻起，
  /// 在该信号每个对应边沿（上升：非1→1；下降：非0→0）右侧写序号
  /// 1,2,3…，随平移/缩放联动。
  void _paintCounter(
    Canvas canvas,
    VcdSignal s,
    double y0,
    double viewEnd,
    WaveCounter counter,
  ) {
    final start = counter.startPs.toDouble();
    final ch = s.changes;
    if (ch.isEmpty) return;
    final tp = TextPainter(textDirection: TextDirection.ltr);
    // 上升沿亮黄、下降沿亮绿。
    final style = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.bold,
      color: counter.falling
          ? const Color(0xFF00FF00)
          : const Color(0xFFFFFF00),
      fontFamily: 'Consolas',
    );
    var n = 0;
    final from = _startIndex(ch, start);
    for (var i = from; i < ch.length; i++) {
      final t = ch[i].time.toDouble();
      if (t > viewEnd) break;
      if (t < start) continue;
      final prev = i == 0 ? null : ch[i - 1].bits;
      final isEdge = counter.falling
          ? ch[i].bits == '0' && prev != '0'
          : ch[i].bits == '1' && prev != '1';
      if (isEdge) {
        n++;
        final x = _x(t);
        if (x >= -8) {
          tp.text = TextSpan(text: '$n', style: style);
          tp.layout();
          tp.paint(canvas, Offset(x + 5, y0 + 6));
        }
      }
    }
  }

  /// 段起点：最后一个 time <= startPs 的变化下标（二分；changes 按时间
  /// 有序）。替代逐次线性扫描——大 VCD 下原线性扫描每次绘制都从头部
  /// 走过全部历史变化。
  static int _startIndex(List<VcdChange> changes, double startPs) {
    var lo = 0, hi = changes.length - 1, ans = 0;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (changes[mid].time <= startPs) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans;
  }

  /// 亚像素段跳过：返回 [from] 起最后一个 time < boundaryPs 的变化下标
  ///（调用方保证 changes[from] 本身满足条件，故返回值 ≥ from）。
  /// 同像素内的连续跳变肉眼不可分辨，无需逐次遍历。
  static int _skipToPixelEnd(List<VcdChange> changes, int from, double boundaryPs) {
    var lo = from, hi = changes.length - 1, ans = from;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (changes[mid].time < boundaryPs) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans;
  }

  /// 标注竖线（底层，波形绘制之前调用）：每条线越过自身作为端点的
  /// 标注段最低箭头线 8px 截断（无关联段的线上下贯穿；不以其为
  /// 端点的段的标签/横线仍止于最先碰到者，口径与覆盖层一致）；
  /// 竖线被 tn 徽章覆盖处截断。
  void _paintDimLines(Canvas canvas, Size size, double scrollY) {
    if (overview || dimLines.isEmpty) return;
    // tn 徽章 y：Signal 列表下方（滚动跟随；与模式无关——退出标注
    // 模式后不回到时间尺下沿）。
    final labelY = (dimRowsBottom - scrollY + 4)
        .clamp(_WaveCanvas.rulerHeight + 2, size.height - 16)
        .toDouble();
    // 各段布局（截断判定用；基准 y 与覆盖层同口径）。
    final baseY = _WaveOverlayPainter.dimGroupsBaseYAt(
        dimRowsBottom, scrollY, size.height);
    final rows = _WaveOverlayPainter.dimSpanRows(dimSpans);
    final lays = [
      for (var i = 0; i < dimSpans.length; i++)
        _WaveOverlayPainter.dimSpanLayout(
            i, dimSpans, rows, startPs, psPerPixel, baseY,
            width: size.width),
    ];
    for (var i = 0; i < dimLines.length; i++) {
      final ps = dimLines[i];
      final x = _x(ps.toDouble());
      if (x < -2 || x > size.width + 2) continue;
      // 自身作为端点的段：越过其中最低的箭头线多画 8px（无关联段
      // 上下贯穿）。
      var bottom = size.height;
      double? ownLowest;
      for (var j = 0; j < dimSpans.length; j++) {
        final s = dimSpans[j];
        if (s.from == ps || s.to == ps) {
          final ay = lays[j].arrowY;
          ownLowest = ownLowest == null ? ay : math.max(ownLowest, ay);
        }
      }
      if (ownLowest != null) {
        bottom = ownLowest + 8;
        // 外来段（不以本线为端点）的标签/横线：止于最先碰到者。
        for (var j = 0; j < dimSpans.length; j++) {
          final s = dimSpans[j];
          if (s.from == ps || s.to == ps) continue;
          final lay = lays[j];
          if (x >= lay.labelRect.left - 2 && x <= lay.labelRect.right + 2) {
            bottom = math.min(bottom, lay.labelRect.top - 2);
          }
          if (x >= lay.arrowRect.left && x <= lay.arrowRect.right) {
            bottom = math.min(bottom, lay.arrowY - 2);
          }
        }
        // 至少露出时间尺下一小截。
        bottom = math.max(bottom, _WaveCanvas.rulerHeight + 8);
      }
      final hovered = dimHoverLine == i;
      final color = hovered
          ? _WaveOverlayPainter.dimHoverColor
          : _WaveOverlayPainter.dimLineColor;
      // tn 徽章下方的竖线段用白色（徽章上方段保持 30 度灰）。
      final belowColor = hovered
          ? _WaveOverlayPainter.dimHoverColor
          : _WaveOverlayPainter.dimColor;
      final (badgeRect, _) = _WaveOverlayPainter.dimBadgeLayout(
          i, x, labelY, size.width, color);
      // 竖线被徽章覆盖处截断：分段绘制。
      final linePaint = Paint()
        ..color = color
        ..strokeWidth = 1;
      final belowPaint = Paint()
        ..color = belowColor
        ..strokeWidth = 1;
      const top = _WaveCanvas.rulerHeight;
      if (badgeRect.top > top && badgeRect.top <= bottom) {
        canvas.drawLine(
            Offset(x, top), Offset(x, badgeRect.top - 1), linePaint);
        if (bottom > badgeRect.bottom) {
          canvas.drawLine(
              Offset(x, badgeRect.bottom + 1), Offset(x, bottom), belowPaint);
        }
      } else if (badgeRect.top <= top && badgeRect.bottom > top) {
        canvas.drawLine(
            Offset(x, badgeRect.bottom + 1), Offset(x, bottom), belowPaint);
      } else {
        canvas.drawLine(Offset(x, top), Offset(x, bottom), linePaint);
      }
    }
  }

  void _paintRuler(Canvas canvas, Size size) {
    final linePaint = Paint()
      ..color = _grid
      ..strokeWidth = 1;
    canvas.drawLine(
      const Offset(0, _WaveCanvas.rulerHeight - 0.5),
      Offset(size.width, _WaveCanvas.rulerHeight - 0.5),
      linePaint,
    );

    // 目标刻度间距 ≥ 80px，步长取 1/2/5 × 10^n（单位 ns）。
    final nsPerPixel = psPerPixel / 1000;
    var stepNs = 1.0;
    while (stepNs / nsPerPixel < 80) {
      stepNs *= 10;
    }
    if (stepNs / 2 / nsPerPixel >= 80) stepNs /= 2; // 5×10^(n-1)
    if (stepNs / 2.5 / nsPerPixel >= 80) stepNs /= 2.5; // 2×10^(n-1)
    final stepPs = stepNs * 1000;
    final firstTick = (startPs / stepPs).ceilToDouble() * stepPs;
    final textPainter = TextPainter(textDirection: TextDirection.ltr);
    for (
      var t = firstTick;
      t <= startPs + size.width * psPerPixel;
      t += stepPs
    ) {
      final x = _x(t);
      canvas.drawLine(
        Offset(x, _WaveCanvas.rulerHeight - 6),
        Offset(x, _WaveCanvas.rulerHeight),
        linePaint,
      );
      textPainter.text = TextSpan(
        text: _fmtNs(t / 1000),
        style: const TextStyle(fontSize: 9, color: _text),
      );
      textPainter.layout();
      textPainter.paint(canvas, Offset(x + 2, 4));
    }
  }

  String _fmtNs(double ns) {
    if (ns >= 1000 && ns % 1000 == 0) {
      return '${(ns / 1000).toStringAsFixed(0)}us';
    }
    if (ns == ns.roundToDouble()) return '${ns.toStringAsFixed(0)}ns';
    return '${ns.toStringAsFixed(1)}ns';
  }

  /// 等效模拟通道（总线右键菜单设定）：总线无符号值按满量程
  ///（0..2^width-1）映射为行内纵坐标的阶梯波形；x/z 段红色中带。
  /// 与 _paintScalar 同款亚像素段合并，低缩放下不逐段遍历。
  void _paintAnalog(
    Canvas canvas,
    VcdSignal s,
    double y0,
    double viewEnd,
    double rowH,
  ) {
    final pad = math.min(2.0, rowH * 0.1);
    final top = y0 + pad;
    final bottom = y0 + rowH - pad;
    final mid0 = y0 + rowH / 2 - 3;
    final mid1 = y0 + rowH / 2 + 3;
    final changes = s.changes;
    final line = Paint()
      ..color = const Color(0xFFFFD54F)
      ..strokeWidth = 1.4;
    final xPaint = Paint()..color = _xColor.withValues(alpha: 0.55);
    // 满量程 2^width（值域 0..2^width-1 映射到 bottom..top）。
    final fullScale = BigInt.one << s.width;
    double yFor(String bits) =>
        bottom -
        (BigInt.parse(bits, radix: 2) / fullScale).toDouble() * (bottom - top);

    if (changes.isEmpty) {
      canvas.drawRect(Rect.fromLTRB(0, mid0, _x(viewEnd), mid1), xPaint);
      return;
    }
    final idx = _startIndex(changes, startPs);
    var curVal = changes[idx].bits;
    var curTime = math.max(startPs, changes[idx].time.toDouble());
    double? prevY;
    var i = idx + 1;
    while (i <= changes.length) {
      final nextTime = i < changes.length
          ? changes[i].time.toDouble()
          : viewEnd;
      final x0 = _x(curTime);
      final x1 = _x(nextTime);
      if (x1 - x0 < 0.5 && i < changes.length) {
        // 亚像素段：二分跳到本像素内最后一次变化，只画一条合并沿。
        final boundaryPs = startPs + (x1.floor() + 1) * psPerPixel;
        final last = _skipToPixelEnd(changes, i, boundaryPs);
        final ex = _x(changes[last].time.toDouble());
        final newVal = changes[last].bits;
        if (!newVal.contains('x') &&
            !newVal.contains('z') &&
            !curVal.contains('x') &&
            !curVal.contains('z')) {
          final newY = yFor(newVal);
          if (ex >= 0 && prevY != null && (newY - prevY).abs() > 0.5) {
            canvas.drawLine(Offset(ex, prevY), Offset(ex, newY), line);
          }
          prevY = newY;
        } else {
          prevY = null;
        }
        curVal = newVal;
        curTime = changes[last].time.toDouble();
        i = last + 1;
        continue;
      }
      final unknown = curVal.contains('x') || curVal.contains('z');
      if (unknown) {
        canvas.drawRect(
          Rect.fromLTRB(math.max(x0, -1.0), mid0, x1, mid1),
          xPaint,
        );
        prevY = null;
      } else {
        final y = yFor(curVal);
        canvas.drawLine(Offset(math.max(x0, -1.0), y), Offset(x1, y), line);
        // 段首跳变沿竖线（前一段纵坐标 → 本段纵坐标）。
        if (prevY != null && x0 >= 0) {
          canvas.drawLine(Offset(x0, prevY), Offset(x0, y), line);
        }
        prevY = y;
      }
      if (nextTime >= viewEnd) break;
      curVal = changes[i].bits;
      curTime = nextTime;
      i++;
    }
  }

  /// 标量：0/1 电平折线，x/z 红色中带。只绘制与可视区相交的段。
  void _paintScalar(
    Canvas canvas,
    VcdSignal s,
    double y0,
    double viewEnd,
    double rowH,
  ) {
    final pad = math.min(4.0, rowH * 0.2);
    final hi = y0 + pad;
    final lo = y0 + rowH - pad;
    final mid0 = y0 + rowH / 2 - 3;
    final mid1 = y0 + rowH / 2 + 3;
    final changes = s.changes;
    final tracePaint = Paint()
      ..color = _trace
      ..strokeWidth = 1.4;
    final xPaint = Paint()..color = _xColor.withValues(alpha: 0.55);

    // 段起点：最后一个 time <= startPs 的变化（没有则用"x"起始）。
    if (changes.isEmpty) {
      canvas.drawRect(Rect.fromLTRB(0, mid0, _x(viewEnd), mid1), xPaint);
      return;
    }
    final idx = _startIndex(changes, startPs);
    var curVal = changes[idx].bits;
    var curTime = math.max(startPs, changes[idx].time.toDouble());
    // 低缩放（全帧/全局图）下 clk 等高频信号每像素十几次跳变：按像素
    // 合并——亚像素段不画水平线（不可见），同像素跳变沿只画一条竖线；
    // 同像素内的中间变化经二分直接跳过（不逐次遍历）。
    // 这是拖动全局图小窗流畅度的关键（否则全帧每帧上万次 drawCall）。
    var lastEdgePx = -2;
    var i = idx + 1;
    while (i <= changes.length) {
      final nextTime = i < changes.length
          ? changes[i].time.toDouble()
          : viewEnd;
      final x0 = _x(curTime);
      final x1 = _x(nextTime);
      if (x1 - x0 < 0.5 && i < changes.length) {
        // 亚像素段：二分跳到本像素内最后一次变化，只画一条合并沿
        //（位置取像素内最后变化处，亚像素差异不可见）。
        final boundaryPs = startPs + (x1.floor() + 1) * psPerPixel;
        final last = _skipToPixelEnd(changes, i, boundaryPs);
        final ex = _x(changes[last].time.toDouble());
        if (ex >= 0 && ex.floor() != lastEdgePx) {
          canvas.drawLine(Offset(ex, hi), Offset(ex, lo), tracePaint);
          lastEdgePx = ex.floor();
        }
        curVal = changes[last].bits;
        curTime = changes[last].time.toDouble();
        i = last + 1;
        continue;
      }
      _drawScalarSegment(
        canvas,
        curVal,
        x0,
        x1,
        hi,
        lo,
        mid0,
        mid1,
        tracePaint,
        xPaint,
      );
      if (i < changes.length) {
        // 跳变沿竖线
        final ex = x1;
        if (ex >= 0 && ex.floor() != lastEdgePx) {
          canvas.drawLine(Offset(ex, hi), Offset(ex, lo), tracePaint);
          lastEdgePx = ex.floor();
        }
        curVal = changes[i].bits;
        curTime = nextTime;
      }
      if (nextTime >= viewEnd) break;
      i++;
    }
  }

  void _drawScalarSegment(
    Canvas canvas,
    String v,
    double x0,
    double x1,
    double hi,
    double lo,
    double mid0,
    double mid1,
    Paint tracePaint,
    Paint xPaint,
  ) {
    final left = math.max(x0, -1.0);
    final right = math.min(x1, 1 << 30).toDouble();
    if (right <= left) return;
    if (v == '1') {
      canvas.drawLine(Offset(left, hi), Offset(right, hi), tracePaint);
    } else if (v == '0') {
      canvas.drawLine(Offset(left, lo), Offset(right, lo), tracePaint);
    } else {
      canvas.drawRect(Rect.fromLTRB(left, mid0, right, mid1), xPaint);
    }
  }

  /// 总线：稳定段画块（梯形沿），宽足够时写十六进制；含 x/z 段红色。
  void _paintBus(
    Canvas canvas,
    VcdSignal s,
    double y0,
    double viewEnd,
    double rowH,
  ) {
    final pad = math.min(3.0, rowH * 0.15);
    final top = y0 + pad;
    final bottom = y0 + rowH - pad;
    final changes = s.changes;
    // Surfer/GTKWave 经典总线风格：段内只画上下水平线，跳变处画 X 交叉
    // 过渡线（bowtie），段宽足够时写十六进制；含 x/z 段红色填充。
    final line = Paint()
      ..color = _bus
      ..strokeWidth = 1.2;
    final xFill = Paint()..color = _xColor.withValues(alpha: 0.45);
    final segFill = Paint();
    final textPainter = TextPainter(textDirection: TextDirection.ltr);
    // 数值描边层：同位置先画黑色 3px 描边文本再压白色填充，段内背景
    // 线/色彩解码填充上数值更易读。
    final outlinePainter = TextPainter(textDirection: TextDirection.ltr);
    final outlinePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeJoin = StrokeJoin.round
      ..color = Colors.black;

    // 色彩解码（背景色填充，Signal 右键菜单设定）：段值低 24 位按
    // HSL/RGB/YUV 解码为 RGB；含 x/z 与全局图模式不解码。
    final colorSpace = busColorSpaces[s.path] ?? BusColorSpace.none;
    final colorHighFirst = !busColorLowFirst.contains(s.path);
    // 色彩解码开启时，块轮廓与跳变沿 X 过渡线改用 50 度灰 1px 前景线
    //（压在填充之上，经典总线块风格）；未开启保持总线色 1.2px。
    final edgeLine = !overview && colorSpace != BusColorSpace.none
        ? (Paint()
          ..color = const Color(0xFF808080)
          ..strokeWidth = 1.0)
        : line;
    (int, int, int)? segColorOf(String bits) {
      if (overview || colorSpace == BusColorSpace.none) return null;
      if (bits.isEmpty || bits.contains('x') || bits.contains('z')) {
        return null;
      }
      final v = (BigInt.parse(bits, radix: 2) & BigInt.from(0xFFFFFF)).toInt();
      return decodeBusColor24(colorSpace, v, highByteFirst: colorHighFirst);
    }

    if (changes.isEmpty) {
      canvas.drawRect(Rect.fromLTRB(0, top, _x(viewEnd), bottom), xFill);
      return;
    }
    var idx = _startIndex(changes, startPs);
    final d = (bottom - top) * 0.35; // X 过渡半宽
    var curVal = changes[idx].bits;
    var curTime = math.max(startPs, changes[idx].time.toDouble());
    // 段左端是否为真实跳变沿（被可视区起点截断的首段不内缩）。
    var leftIsEdge = changes[idx].time.toDouble() >= startPs && idx > 0;
    // 低缩放下亚像素段按像素合并（同像素只画一次），避免全帧视图
    // 每帧数千次 drawCall；X 过渡线同样按像素合并；同像素内的中间
    // 变化经二分直接跳过（不逐次遍历）。
    var lastSegPx = -2;
    var lastXPx = -2;
    var i = idx + 1;
    while (i <= changes.length) {
      final nextTime = i < changes.length
          ? changes[i].time.toDouble()
          : viewEnd;
      final x0 = _x(curTime);
      final x1 = _x(nextTime);
      if (x1 - x0 < 0.75 && i < changes.length) {
        // 亚像素段：二分跳到本像素内最后一次变化。水平线本就被 X 半宽
        // 内缩裁掉无需绘制；x/z 填充与 X 过渡线各按像素画一次。
        final boundaryPs = startPs + (x1.floor() + 1) * psPerPixel;
        final last = _skipToPixelEnd(changes, i, boundaryPs);
        final ex = _x(changes[last].time.toDouble());
        final px = ex.floor();
        if (px != lastSegPx) {
          lastSegPx = px;
          if (curVal.contains('x') || curVal.contains('z')) {
            canvas.drawRect(
              Rect.fromLTRB(x0, top, math.max(ex, x0 + 1), bottom),
              xFill,
            );
          } else {
            // 亚像素段的色彩解码填充（同像素只画一次）。
            final rgb = segColorOf(curVal);
            if (rgb != null) {
              segFill.color = Color.fromARGB(0xB0, rgb.$1, rgb.$2, rgb.$3);
              canvas.drawRect(
                Rect.fromLTRB(x0, top, math.max(ex, x0 + 1), bottom),
                segFill,
              );
            }
          }
        }
        if (ex > -d && px != lastXPx) {
          lastXPx = px;
          final rightW = last + 1 < changes.length
              ? (changes[last + 1].time - changes[last].time) / psPerPixel
              : double.infinity;
          final dEff = math.min(d, math.min(ex - x0, rightW) / 2);
          if (dEff > 0.3) {
            canvas.drawLine(
              Offset(ex - dEff, top),
              Offset(ex + dEff, bottom),
              edgeLine,
            );
            canvas.drawLine(
              Offset(ex - dEff, bottom),
              Offset(ex + dEff, top),
              edgeLine,
            );
          }
        }
        curVal = changes[last].bits;
        curTime = changes[last].time.toDouble();
        leftIsEdge = true;
        i = last + 1;
        continue;
      }
      final rightIsEdge = i < changes.length;
      // 宽段（≥0.75px）即使与前段同像素也照常绘制；亚像素段同像素只画一次。
      if (x1 > 0 && (x1 - x0 >= 0.75 || x0.floor() != lastSegPx)) {
        lastSegPx = x0.floor();
        final unknown = curVal.contains('x') || curVal.contains('z');
        // 色彩解码：经典总线块风格——梯形沿六边形块填充解码色并同色
        // 描边轮廓（跳变沿处收尖，相邻块合成沙漏分隔；被可视区截断的
        // 端不切角）。描边含上下沿，故填充时跳过单独的水平线。
        final segRgb = unknown ? null : segColorOf(curVal);
        // 水平线在跳变沿处断开：两端各内缩一个 X 半宽。
        final lx = leftIsEdge ? x0 + d : x0;
        final rx = rightIsEdge ? x1 - d : x1;
        if (segRgb != null) {
          final mid = (top + bottom) / 2;
          final wEff = math.max(x1 - x0, 0.0);
          // 窄块收缩沿宽防路径自交。
          final dl = leftIsEdge ? math.min(d, wEff / 2) : 0.0;
          final dr = rightIsEdge ? math.min(d, wEff / 2) : 0.0;
          final bp = Path();
          if (leftIsEdge) {
            bp.moveTo(x0, mid);
            bp.lineTo(x0 + dl, top);
          } else {
            bp.moveTo(x0, top);
          }
          if (rightIsEdge) {
            bp.lineTo(x1 - dr, top);
            bp.lineTo(x1, mid);
            bp.lineTo(x1 - dr, bottom);
          } else {
            bp.lineTo(x1, top);
            bp.lineTo(x1, bottom);
          }
          if (leftIsEdge) {
            bp.lineTo(x0 + dl, bottom);
          } else {
            bp.lineTo(x0, bottom);
          }
          bp.close();
          segFill.color =
              Color.fromARGB(0xB0, segRgb.$1, segRgb.$2, segRgb.$3);
          canvas.drawPath(bp, segFill);
          canvas.drawPath(bp, edgeLine..style = PaintingStyle.stroke);
        }
        if (unknown) {
          canvas.drawRect(
            Rect.fromLTRB(x0, top, math.max(x1, x0 + 1), bottom),
            xFill,
          );
        } else if (segRgb == null && rx > lx) {
          canvas.drawLine(Offset(lx, top), Offset(rx, top), line);
          canvas.drawLine(Offset(lx, bottom), Offset(rx, bottom), line);
        }
        if (!overview && !unknown) {
          // 段内居中显示格式化数值（格式经总线右键菜单设定，缺省 hex，
          // 高位 0 按信号位宽补全）；空间不足（文本超出段宽）不绘制。
          // 总线值白色填充 + 黑色 3px 描边。
          final text = formatBusBits(
            curVal,
            busFormats[s.path] ?? BusDisplayFormat.hex,
            width: s.width,
          );
          textPainter.text = TextSpan(
            text: text,
            style: const TextStyle(
              fontSize: 14,
              color: Colors.white,
              fontFamily: 'Consolas',
            ),
          );
          outlinePainter.text = TextSpan(
            text: text,
            style: TextStyle(
              fontSize: 14,
              fontFamily: 'Consolas',
              foreground: outlinePaint,
            ),
          );
          textPainter.layout();
          if (textPainter.width + 6 <= x1 - x0) {
            final off = Offset(
              x0 + (x1 - x0 - textPainter.width) / 2,
              top + (bottom - top - textPainter.height) / 2,
            );
            outlinePainter
              ..layout()
              ..paint(canvas, off);
            textPainter.paint(canvas, off);
          }
        }
      }
      if (i < changes.length) {
        // X 交叉过渡线：半宽随相邻段宽收缩（缩小时段宽只有几像素，
        // 固定半宽会溢出到相邻段与可视区之外）。
        final bx = x1;
        if (bx > -d && bx.floor() != lastXPx) {
          lastXPx = bx.floor();
          final leftW = x1 - x0;
          final rightW = i + 1 < changes.length
              ? (changes[i + 1].time - changes[i].time) / psPerPixel
              : double.infinity;
          final dEff = math.min(d, math.min(leftW, rightW) / 2);
          if (dEff > 0.3) {
            canvas.drawLine(
              Offset(bx - dEff, top),
              Offset(bx + dEff, bottom),
              edgeLine,
            );
            canvas.drawLine(
              Offset(bx - dEff, bottom),
              Offset(bx + dEff, top),
              edgeLine,
            );
          }
        }
        curVal = changes[i].bits;
        curTime = nextTime;
        leftIsEdge = true; // 后续段左端均为真实跳变沿
      }
      if (nextTime >= viewEnd) break;
      i++;
    }
  }

  @override
  bool shouldRepaint(WavePainter old) =>
      old.vcd != vcd ||
      old.rows != rows ||
      old.psPerPixel != psPerPixel ||
      old.startPs != startPs ||
      old.selectedIndex != selectedIndex ||
      !mapEquals(old.counters, counters) ||
      !mapEquals(old.busFormats, busFormats) ||
      !setEquals(old.analogBuses, analogBuses) ||
      !mapEquals(old.analogSpans, analogSpans) ||
      !mapEquals(old.busColorSpaces, busColorSpaces) ||
      !setEquals(old.busColorLowFirst, busColorLowFirst) ||
      !listEquals(old.dimLines, dimLines) ||
      !listEquals(old.dimSpans, dimSpans) ||
      old.dimHoverLine != dimHoverLine ||
      old.dimRowsBottom != dimRowsBottom;
}

/// 全局图上的可视窗口框：窗外压暗 + 白色半透明窗体描边（与示波器
/// minimap 同款观感）。
class OverviewWindowPainter extends CustomPainter {
  final double startPs;
  final double viewSpanPs;
  final double totalPs;

  /// M 光标（画在前景层，拖动光标时全局图波形本体不重绘）。
  final int? cursorPs;

  /// 时间线标记（皮秒；全局图只画虚线不写标签）。
  final List<int> timelines;

  OverviewWindowPainter({
    required this.startPs,
    required this.viewSpanPs,
    required this.totalPs,
    this.cursorPs,
    this.timelines = const [],
  });

  @override
  void paint(Canvas canvas, Size size) {
    final x0 = (startPs / totalPs * size.width).clamp(0.0, size.width);
    final x1 = ((startPs + viewSpanPs) / totalPs * size.width).clamp(
      0.0,
      size.width,
    );
    final dim = Paint()..color = Colors.black.withValues(alpha: 0.45);
    if (x0 > 0) canvas.drawRect(Rect.fromLTWH(0, 0, x0, size.height), dim);
    if (x1 < size.width) {
      canvas.drawRect(Rect.fromLTWH(x1, 0, size.width - x1, size.height), dim);
    }
    final rect = Rect.fromLTWH(x0, 0.5, math.max(x1 - x0, 2), size.height - 1);
    canvas.drawRect(
      rect,
      Paint()..color = Colors.white.withValues(alpha: 0.12),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.75)
        ..strokeWidth = 1
        ..style = PaintingStyle.stroke,
    );
    final cur = cursorPs;
    if (cur != null) {
      final cx = cur / totalPs * size.width;
      if (cx >= 0 && cx <= size.width) {
        drawDashedVLine(
          canvas,
          cx,
          size.height,
          Paint()
            ..color = const Color(0xFFFF1744)
            ..strokeWidth = 1,
        );
      }
    }
    for (final t in timelines) {
      final tx = t / totalPs * size.width;
      if (tx < 0 || tx > size.width) continue;
      drawDashedVLine(
        canvas,
        tx,
        size.height,
        Paint()
          ..color = const Color(0xFFFFB300)
          ..strokeWidth = 1,
      );
    }
  }

  @override
  bool shouldRepaint(OverviewWindowPainter old) =>
      old.startPs != startPs ||
      old.viewSpanPs != viewSpanPs ||
      old.totalPs != totalPs ||
      old.cursorPs != cursorPs ||
      !listEquals(old.timelines, timelines);
}
