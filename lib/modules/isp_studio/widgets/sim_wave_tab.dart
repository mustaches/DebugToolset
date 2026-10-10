/// ISP Studio「仿真波形」标签页：Flutter 原生数字波形查看器（轻量版
/// GTKWave，渲染风格与示波器模块一致）。
///
/// 一键仿真产出的 wave.vcd 由 [SimWaveStore] 登记并广播代次，本页经
/// vcd_parser 解析后 CustomPaint 绘制：左栏信号名 + 光标处取值，右侧
/// 时间尺 + 数字波形（标量 0/1/x 电平线、总线十六进制块）。交互：
/// 拖动平移、滚轮缩放（以指针位置为锚点）、单击置光标、双击 Zoom Fit。
/// 工具栏「用外部查看器打开」回退 Surfer/GTKWave。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../codegen/iverilog_sim.dart';
import '../codegen/sim_wave_store.dart';
import '../codegen/vcd_parser.dart';
import 'tab_toolbar.dart';

/// 单个信号的边沿计数标注：起点（皮秒）与边沿方向（false=上升沿，
/// true=下降沿）。
typedef WaveCounter = ({int startPs, bool falling});

/// 波形显示行：整个信号行（bit=null）或总线展开后的单个位行。
/// 位行的 [signal] 是从总线派生的 1 位标量信号
///（name 形如 `data [3]`，path 形如 `tb.dut.data[3]`）。
/// [spacer] 为等效模拟通道的占位行：模拟波形占 N 个数字行高时，
/// 主行之后插入 N-1 个占位行保持行索引与纵向坐标对齐。
class WaveRow {
  final VcdSignal signal;
  final int? bit;
  final bool spacer;
  const WaveRow(this.signal, [this.bit]) : spacer = false;
  const WaveRow.spacer(this.signal) : bit = null, spacer = true;
}

/// 总线数据显示格式（Signal 面板右键菜单设定，按信号路径保存）。
enum BusDisplayFormat { hex, decimal, binary, ascii }

/// 总线位串按格式转文本：hex=0x…，decimal=十进制，binary=每 4 位空一格，
/// ascii=逐字节字符（不可打印显示 ·）。含 x/z 时：binary 原样分组（保留
/// x/z 字符），其余显示 x。
String formatBusBits(String bits, BusDisplayFormat fmt) {
  final unknown = bits.contains('x') || bits.contains('z');
  if (unknown && fmt != BusDisplayFormat.binary) return 'x';
  switch (fmt) {
    case BusDisplayFormat.hex:
      return '0x${bitsToHex(bits).toUpperCase()}';
    case BusDisplayFormat.decimal:
      return BigInt.parse(bits, radix: 2).toString();
    case BusDisplayFormat.binary:
      return _groupBits(bits, unknown);
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

/// 默认展示的信号（与 wave.sucl / wave.gtkw 同一批：时钟/复位 + IP I/O）。
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

  /// 右键「从M光标线放置时间线」放置的时间线标记（皮秒），按放置顺序编号 T1/T2…。
  final List<int> _timelinesPs = [];

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

  /// 总线右键菜单控制器与目标信号路径。
  final MenuController _busMenuController = MenuController();
  String? _busMenuPath;

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
  }

  @override
  void dispose() {
    _waveSub?.cancel();
    _namesScroll.dispose();
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
        sig.changes.add(
          VcdChange(c.time, ch == '1' ? '1' : (ch == '0' ? '0' : 'x')),
        );
      }
      return sig;
    });
  }

  /// 显示行列表：整个信号行 + 模拟通道占位行 + 展开总线的逐位行
  ///（高位在前）。
  List<WaveRow> _displayRows(List<VcdSignal> signals) {
    return [
      for (final s in signals) ...[
        WaveRow(s),
        if (s.isBus && _analogBuses.contains(s.path))
          for (var k = 1; k < (_analogSpan[s.path] ?? 1); k++)
            WaveRow.spacer(s),
        if (s.isBus && _expandedBuses.contains(s.path))
          for (var b = s.width - 1; b >= 0; b--) WaveRow(_bitSignal(s, b), b),
      ],
    ];
  }

  Future<void> _openExternal() async {
    final store = SimWaveStore.instance;
    final vcd = store.currentVcd;
    if (vcd == null) return;
    final name = await launchWaveformExternally(
      vcd,
      sucl: store.currentSucl,
      gtkw: store.currentGtkw,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(name == null ? '未检测到波形查看器' : '已用 $name 打开波形')),
    );
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

  Widget _buildToolbar() {
    return ispTabToolbarRow(
      children: [
        const Icon(Icons.show_chart, size: 15, color: Colors.grey),
        const SizedBox(width: 6),
        const Text('仿真波形', style: TextStyle(fontSize: 12, color: Colors.grey)),
        const Spacer(),
        _toolButton(Icons.fit_screen, 'Zoom Fit（显示全帧）', () {
          final vcd = _vcd;
          if (vcd != null) {
            final w = context.size?.width ?? 800;
            _zoomFit(vcd, w - _namesWidth - _scopesWidth - 14);
          }
        }),
        _toolButton(Icons.open_in_new, '用外部查看器打开', _openExternal),
      ],
    );
  }

  Widget _toolButton(IconData icon, String tooltip, VoidCallback onPressed) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: Icon(icon, size: 15, color: Colors.grey),
        ),
      ),
    );
  }

  // 面板尺寸（边界可拖动调整，见 _vDragHandle/_hDragHandle）。
  double _scopesWidth = 190;
  double _namesWidth = 170;
  static const double _kOverviewHeight = 64;

  /// Scopes 树占左上面板的高度比例（横边界拖动调整）。
  double _scopesRatio = 0.45;

  /// 信号名列表与波形区的共享垂直滚动控制器：列表滚动经
  /// CustomPainter(repaint:) 驱动波形行偏移重绘，无需 setState。
  final ScrollController _namesScroll = ScrollController();

  /// 全局图拖动：指针相对窗口左沿的时间偏移（窗口外按下时取窗口中心）。
  double _grabOffsetPs = 0;

  Widget _buildWaveArea(VcdFile vcd) {
    final signals = _displaySignals(vcd);
    final rows = _displayRows(signals);
    return LayoutBuilder(
      builder: (context, constraints) {
        final waveWidth =
            constraints.maxWidth - _namesWidth - _scopesWidth - 14;
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
                  // 全局图左侧单元格：M 光标时间显示。
                  SizedBox(
                    width: _scopesWidth + _namesWidth + 14,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 10),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text.rich(
                          // 「MCursor」与波形上 M 标识同款红底白字。
                          TextSpan(
                            children: [
                              const TextSpan(
                                text: 'MCursor',
                                style: TextStyle(
                                  color: Colors.white,
                                  backgroundColor: Color(0xFFFF1744),
                                ),
                              ),
                              TextSpan(
                                text: _cursorPs == null
                                    ? '.Time'
                                    : '.Time  ${_fmtPs(_cursorPs!)}',
                                style: const TextStyle(color: Colors.white),
                              ),
                            ],
                          ),
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            fontFamily: 'Consolas',
                          ),
                        ),
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
                                    r.signal.name == _selectedSignal,
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
                        onCursor: (ps) => setState(() => _cursorPs = ps),
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
                        onPlaceTimeline: (ps) =>
                            setState(() => _timelinesPs.add(ps)),
                        onPlaceCounter: (ps, path, falling) => setState(
                          () => _counters[path] = (
                            startPs: ps,
                            falling: falling,
                          ),
                        ),
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
                            _timelinesPs.clear();
                          } else if (index < _timelinesPs.length) {
                            _timelinesPs.removeAt(index);
                          }
                        }),
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

  /// 皮秒格式化：`000,000,000,000ps`（12 位补零、千分位逗号）。
  String _fmtPs(int ps) => fmtPsGrouped(ps);

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
          fontSize: 14,
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
                    fontSize: 12,
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
                        fontSize: 12,
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
                      fontSize: 12,
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

  /// Signal 面板右键：命中行为总线整行时弹出格式/模拟通道菜单。
  void _onNamesSecondaryDown(PointerDownEvent e, List<WaveRow> rows) {
    if (e.buttons != kSecondaryButton) return;
    final scrollY = _namesScroll.hasClients ? _namesScroll.offset : 0.0;
    final idx = ((e.localPosition.dy + scrollY) / _WaveCanvas.rowHeight)
        .floor();
    if (idx < 0 || idx >= rows.length) return;
    final r = rows[idx];
    if (r.bit != null || !r.signal.isBus) return;
    setState(() => _busMenuPath = r.signal.path);
    _busMenuController.open(position: e.localPosition);
  }

  /// 总线右键菜单：数据格式（十进制/十六进制/二进制/ASCII，勾选当前项）
  /// + 等效模拟通道开关（勾选态）。
  List<Widget> _busMenuChildren() {
    final path = _busMenuPath;
    if (path == null) return const [];
    final fmt = _busFormats[path] ?? BusDisplayFormat.hex;
    final analog = _analogBuses.contains(path);
    final span = _analogSpan[path] ?? 1;
    const labelStyle = TextStyle(fontSize: 12);
    final itemStyle = MenuItemButton.styleFrom(
      visualDensity: const VisualDensity(vertical: -4),
      minimumSize: const Size(0, 28),
      padding: const EdgeInsets.symmetric(horizontal: 12),
    );
    Widget checkIcon(bool on) =>
        on ? const Icon(Icons.check, size: 14) : const SizedBox(width: 14);
    Widget fmtItem(BusDisplayFormat f, String label) => MenuItemButton(
      leadingIcon: checkIcon(fmt == f),
      onPressed: () => setState(() => _busFormats[path] = f),
      style: itemStyle,
      child: Text(label, style: labelStyle),
    );
    return [
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
                fontSize: 14,
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
                      itemExtent: _WaveCanvas.rowHeight,
                      children: [
                        for (final r in rows)
                          r.spacer
                              // 模拟通道占位行：面板留空（行高与波形一致）
                              ? const SizedBox(height: _WaveCanvas.rowHeight)
                              : r.bit != null
                              ? _buildBitNameRow(r, cursorPs)
                              : _buildSignalNameRow(r.signal, cursorPs),
                      ],
                    ),
                  ),
                  Positioned(
                    left: 0,
                    top: 0,
                    child: MenuAnchor(
                      controller: _busMenuController,
                      menuChildren: _busMenuChildren(),
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

  /// 总线展开后的位行（仅显示：位名 + 光标处位值；不参与选中/拖动）。
  Widget _buildBitNameRow(WaveRow r, int? cursorPs) {
    final s = r.signal;
    return SizedBox(
      key: ValueKey(s.path),
      height: _WaveCanvas.rowHeight,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            // 与整信号行的箭头列对齐，位名再缩进一级。
            const SizedBox(width: 26),
            Expanded(
              child: Text(
                s.name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: Color(0xFFCCCCCC)),
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
                            fontSize: 12,
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

/// 波形画布：时间尺 + 逐信号数字轨迹 + 手势。
/// 左键放置/拖动 M 光标（吸附最近跳变沿）；右键弹出菜单
/// （上升沿计数值 / 下降沿计数值 / 时间线，均以 M 光标线为锚点）；
/// Ctrl+左键快速平移；Alt+左键框选区间放大；滚轮平移、Ctrl+滚轮缩放。
class _WaveCanvas extends StatefulWidget {
  static const double rulerHeight = 20;
  static const double rowHeight = 24;

  final VcdFile vcd;
  final List<VcdSignal> signals;

  /// 显示行（含总线展开的位行）：波形绘制与光标边沿吸附按行对应信号。
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

  /// 各信号的边沿计数标注（键=信号路径）：更换信号放置互不影响。
  final Map<String, WaveCounter> counters;
  final void Function(int ps) onPlaceTimeline;
  final void Function(int ps, String signalPath, bool falling) onPlaceCounter;

  /// 右键菜单点选时间线：跳转视图使该时间线居中显示。
  final void Function(int ps) onJumpToTimeline;

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
    required this.onPan,
    required this.onZoom,
    required this.onCursor,
    required this.onZoomRange,
    required this.timelines,
    this.counters = const {},
    required this.onPlaceTimeline,
    required this.onPlaceCounter,
    required this.onJumpToTimeline,
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
    super.dispose();
  }

  /// 各显示行对应的信号（跳过模拟占位行）：边沿吸附用。
  List<VcdSignal> get _rowSignals => [
    for (final r in widget.rows)
      if (!r.spacer) r.signal,
  ];

  /// 左键放置/拖动：光标吸附到任意显示信号的最近跳变沿（16px 吸附半径内），
  /// 半径外跟随鼠标。
  void _snapCursorTo(double dx) {
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
    widget.onCursor(best.round());
  }

  final MenuController _menuController = MenuController();

  /// 右键菜单（MenuAnchor 实现，「跳转到时间线」「清除时间线」为二级
  /// 菜单）：放置项均以 M 光标线为锚点。「从M光标线放置上升沿计数值」/
  /// 「从M光标线放置下降沿计数值」对左栏选中的标量信号，从 M 光标
  /// 时刻起在对应边沿右侧标注计数 1,2,3…；「从M光标线放置时间线」
  /// 在 M 光标处放置时间线标记 T1/T2…；「跳转到时间线」二级菜单列出
  /// 全部时间线，点选即跳转视图使其居中显示；「清除时间线」二级菜单
  /// 首项清除全部，分割线下删除单条。未放置 M 光标时放置项置灰；
  /// 无选中信号或选中总线时计数项置灰；无时间线时两个二级菜单置灰。
  List<Widget> _buildMenuChildren() {
    final cursorPs = widget.cursorPs;
    final sel = widget.selectedIndex;
    final selSignal = (sel != null && sel >= 0 && sel < widget.signals.length)
        ? widget.signals[sel]
        : null;
    final canCounter =
        cursorPs != null && selSignal != null && !selSignal.isBus;
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
        onPressed: cursorPs != null ? placeTimeline : null,
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

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Listener(
          behavior: HitTestBehavior.translucent,
      onPointerDown: (e) {
        // Alt + 左键：框选放大（原右键框选迁移至此）。
        if (e.buttons == kPrimaryButton && _altDown) {
          setState(() {
            _selStartX = e.localPosition.dx;
            _selCurrentX = _selStartX;
          });
        } else if (e.buttons == kSecondaryButton) {
          // 右键：弹出菜单（计数值/时间线放置、清除时间线、时间线跳转）。
          _menuController.open(position: e.localPosition);
        }
      },
      onPointerMove: (e) {
        if (_selStartX != null) {
          setState(() => _selCurrentX = e.localPosition.dx);
        }
      },
      onPointerUp: (e) {
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
      onPointerCancel: (_) {},
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
        cursor: _ctrlDown
            ? SystemMouseCursors.resizeLeftRight
            : _altDown
            ? SystemMouseCursors.precise
            : MouseCursor.defer,
        child: GestureDetector(
          // 左键：放置/拖动 M 光标线（自动吸附最近跳变沿）；Ctrl+左键：
          // 3 倍速快速平移；Alt 框选期间不平移不置光标。
          onHorizontalDragUpdate: (d) {
            if (_selStartX != null || _altDown) return;
            if (_ctrlDown) {
              widget.onPan(-d.delta.dx * 3.0 * widget.psPerPixel);
            } else {
              _snapCursorTo(d.localPosition.dx);
            }
          },
          onTapDown: (d) => _snapCursorTo(d.localPosition.dx),
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
              ),
              // M 光标线/时间线标记与框选高亮放前景层：拖动光标/框选时
              // 波形本体（数据遍历绘制）完全不重绘，只画这几条线。
              foregroundPainter: _WaveOverlayPainter(
                cursorPs: widget.cursorPs,
                startPs: widget.startPs,
                psPerPixel: widget.psPerPixel,
                selStartX: _selStartX,
                selCurrentX: _selCurrentX,
                timelines: widget.timelines,
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
  }
}

/// 画 1px 竖直虚线（M 光标用，GTKWave 风格：4px 实 / 4px 空）。
void drawDashedVLine(Canvas canvas, double x, double height, Paint paint) {
  const dash = 4.0, gap = 4.0;
  for (var y = 0.0; y < height; y += dash + gap) {
    canvas.drawLine(
      Offset(x, y),
      Offset(x, math.min(y + dash, height)),
      paint,
    );
  }
}

/// 前景层：M 光标线（含顶部 M 标签）+ 时间线标记（T1/T2… 虚线与
/// 时间标签）+ Alt 框选的区间高亮。
/// 与波形本体分层后，拖动 M 光标不再触发波形数据的重绘遍历。
class _WaveOverlayPainter extends CustomPainter {
  final int? cursorPs;
  final double startPs;
  final double psPerPixel;
  final double? selStartX;
  final double? selCurrentX;

  /// 时间线标记（皮秒，按放置顺序编号 T1/T2…）。
  final List<int> timelines;

  /// 时间线标记的琥珀色（线与标签底色）。
  static const _tlColor = Color(0xFFFFB300);

  _WaveOverlayPainter({
    required this.cursorPs,
    required this.startPs,
    required this.psPerPixel,
    this.selStartX,
    this.selCurrentX,
    this.timelines = const [],
  });

  /// 皮秒转紧凑时间文本（时间线标签用）。
  static String _fmtT(double ps) {
    final ns = ps / 1000;
    if (ns >= 1000) return '${(ns / 1000).toStringAsFixed(3)}us';
    return '${ns.toStringAsFixed(2)}ns';
  }

  @override
  void paint(Canvas canvas, Size size) {
    final cur = cursorPs;
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
      final tPs = timelines[i].toDouble();
      final buf = StringBuffer('T${i + 1}  ${_fmtT(tPs)}');
      if (cur != null) {
        final d = tPs - cur;
        buf.write('\nΔ${d >= 0 ? '+' : '-'}${_fmtT(d.abs())}');
      }
      final tp = TextPainter(
        text: TextSpan(
          text: buf.toString(),
          style: const TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.bold,
            color: Colors.black,
            fontFamily: 'Consolas',
            height: 1.25,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final ly = 1.0 + (i % 3) * (tp.height + 5);
      final lx = tx + 2 + tp.width + 6 <= size.width
          ? tx + 2
          : tx - tp.width - 8;
      canvas.drawRect(
        Rect.fromLTWH(lx, ly, tp.width + 6, tp.height + 3),
        Paint()..color = _tlColor,
      );
      tp.paint(canvas, Offset(lx + 3, ly + 1.5));
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
        // M 光标线：1px 亮红虚线 + 顶部 M 标签
        drawDashedVLine(
          canvas,
          cx,
          size.height,
          Paint()
            ..color = const Color(0xFFFF1744)
            ..strokeWidth = 1,
        );
        final tp = TextPainter(
          text: const TextSpan(
            text: 'M',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        final lx = cx + 2 + tp.width + 6 <= size.width
            ? cx + 2
            : cx - tp.width - 8;
        canvas.drawRect(
          Rect.fromLTWH(lx, 1, tp.width + 6, tp.height + 3),
          Paint()..color = const Color(0xFFFF1744),
        );
        tp.paint(canvas, Offset(lx + 3, 2));
      }
    }
  }

  @override
  bool shouldRepaint(_WaveOverlayPainter old) =>
      old.cursorPs != cursorPs ||
      old.startPs != startPs ||
      old.psPerPixel != psPerPixel ||
      old.selStartX != selStartX ||
      old.selCurrentX != selCurrentX ||
      !listEquals(old.timelines, timelines);
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
  }) : super(repaint: scrollController);

  static const _trace = Color(0xFF4EC9B0);
  static const _bus = Color(0xFFCE9178);
  static const _xColor = Color(0xFFFF5555);
  static const _grid = Color(0xFF2D2D2D);
  static const _text = Color(0xFFAAAAAA);

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
    // 选中行背景高亮（暗蓝 #094771，与信号名行同款）。
    final sel = selectedIndex;
    if (!overview && sel != null && sel >= 0 && sel < rows.length) {
      final y0 = yBase + sel * _WaveCanvas.rowHeight;
      canvas.drawRect(
        Rect.fromLTWH(0, y0, size.width, _WaveCanvas.rowHeight),
        Paint()..color = const Color(0xFF094771),
      );
    }
    final viewEnd = startPs + size.width * psPerPixel;
    for (var i = 0; i < rows.length; i++) {
      final y0 = yBase + i * rowH;
      if (y0 > size.height) break;
      if (y0 + rowH < (overview ? 0.0 : _WaveCanvas.rulerHeight)) continue;
      final r = rows[i];
      if (r.spacer) continue; // 模拟通道占位行：波形已随主行跨行绘制
      final s = r.signal;
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
    final textPainter = TextPainter(textDirection: TextDirection.ltr);

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
              line,
            );
            canvas.drawLine(
              Offset(ex - dEff, bottom),
              Offset(ex + dEff, top),
              line,
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
        // 水平线在跳变沿处断开：两端各内缩一个 X 半宽。
        final lx = leftIsEdge ? x0 + d : x0;
        final rx = rightIsEdge ? x1 - d : x1;
        if (unknown) {
          canvas.drawRect(
            Rect.fromLTRB(x0, top, math.max(x1, x0 + 1), bottom),
            xFill,
          );
        } else if (rx > lx) {
          canvas.drawLine(Offset(lx, top), Offset(rx, top), line);
          canvas.drawLine(Offset(lx, bottom), Offset(rx, bottom), line);
        }
        if (!overview && !unknown) {
          // 段内居中显示格式化数值（格式经总线右键菜单设定，缺省 hex）；
          // 空间不足（文本超出段宽）不绘制
          final text = formatBusBits(
            curVal,
            busFormats[s.path] ?? BusDisplayFormat.hex,
          );
          textPainter.text = TextSpan(
            text: text,
            style: const TextStyle(
              fontSize: 13,
              color: Colors.white,
              fontFamily: 'Consolas',
            ),
          );
          textPainter.layout();
          if (textPainter.width + 6 <= x1 - x0) {
            textPainter.paint(
              canvas,
              Offset(
                x0 + (x1 - x0 - textPainter.width) / 2,
                top + (bottom - top - textPainter.height) / 2,
              ),
            );
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
              line,
            );
            canvas.drawLine(
              Offset(bx - dEff, bottom),
              Offset(bx + dEff, top),
              line,
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
      !mapEquals(old.analogSpans, analogSpans);
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
