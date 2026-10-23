/// IP 一键仿真的激励参数模型与激励图案生成（纯 Dart，无 Flutter 依赖）。
///
/// 一键仿真的 testbench/golden 不再写死 64×48 随机帧，而由用户在 IP 标签页
/// 工具栏「仿真激励参数」对话框中指定（帧尺寸/帧数/图案/随机种子/握手压力
/// 率），经 [IpSimStimulus] 传入 `buildGroupIpFiles` 烘焙进 tb 与 golden。
library;

/// 激励图案类型。
enum IpSimPattern {
  random('随机（LCG）'),
  hGradient('水平渐变'),
  vGradient('垂直渐变'),
  solid('纯色'),
  checker('棋盘格'),
  // 24 位色彩激励：三通道按字节序打包一个颜色值（HSL/RGB/YUV），与
  // 「仿真波形」标签页 Signal 右键菜单的色彩解码（背景色填充）对应——
  // 选同空间同字节序即可在波形上直接看到色彩块。高字节（H/R/Y）为默认
  // 字节序；高字节（L/B/V）为第一/第三通道互换。
  hsl24Hi('24位 HSL（高字节H）'),
  hsl24Lo('24位 HSL（高字节L）'),
  rgb24Hi('24位 RGB（高字节R）'),
  rgb24Lo('24位 RGB（高字节B）'),
  yuv24Hi('24位 YUV（高字节Y）'),
  yuv24Lo('24位 YUV（高字节V）');

  final String displayName;

  const IpSimPattern(this.displayName);

  /// 是否 24 位色彩激励（HSL/RGB/YUV 打包）。
  bool get isColor24 => index >= hsl24Hi.index;

  /// 色彩激励的色度空间（仅 isColor24 有意义）。
  String get colorSpace => switch (this) {
        hsl24Hi || hsl24Lo => 'HSL',
        rgb24Hi || rgb24Lo => 'RGB',
        yuv24Hi || yuv24Lo => 'YUV',
        _ => '',
      };

  /// 色彩激励的字节序：true = 高字节承载第一通道（H/R/Y，默认）；
  /// false = 高字节承载第三通道（L/B/V）。
  bool get colorHighByteFirst => this == hsl24Hi || this == rgb24Hi || this == yuv24Hi;
}

/// 一键仿真激励参数（默认值：64×8 × 6 帧、帧间隔 10 拍、CLK 100MHz、
/// LCG 随机、无握手压力——像素总数 3072 与历史固定行为相同，随机序列
/// 与 golden 哈希不变；帧数/帧间隔只改时序不改数据口径）。
class IpSimStimulus {
  /// 帧宽（像素）。
  final int width;

  /// 帧高（行）。
  final int height;

  /// 连续帧数（逐帧 sof/eol，多帧连续喂入）。
  final int frames;

  /// 帧间隔（时钟周期数）：前一帧最后一个像素接收后到下一帧首像素之间
  /// 插入的 in_valid 空闲拍数（0=帧间连续不停流，默认）。
  final int frameGapCycles;

  /// CLK 频率（MHz，默认 100）：烘焙进 tb 的时钟周期（半周期 =
  /// 500/clkMHz ns，见 [ipClkHalfNs]；只改时序不改 golden 数据口径）。
  final double clkMHz;

  /// 激励图案。
  final IpSimPattern pattern;

  /// 随机种子：随机图案的 LCG 种子；同时派生 tb 侧握手压力（输入气泡 /
  /// 输出背压）的随机序列，保证仿真可复现。
  final int seed;

  /// 输入气泡率（%）：每像素后以该概率插入 1 拍 in_valid 空闲（0=恒满流）。
  final int inGapPct;

  /// 输出背压率（%）：每拍以该概率拉低 out_ready（0=恒接收）。
  final int outStallPct;

  const IpSimStimulus({
    this.width = 64,
    this.height = 8,
    this.frames = 6,
    this.frameGapCycles = 10,
    this.clkMHz = 100,
    this.pattern = IpSimPattern.random,
    this.seed = 0x12345678,
    this.inGapPct = 0,
    this.outStallPct = 0,
  });

  /// 激励总像素数。
  int get pixelCount => width * height * frames;

  /// 工具栏摘要（如「64×48×1帧 隔0拍 随机（LCG） 泡0% 压0%」；
  /// CLK 非默认 100MHz 时追加「 CLKxxxM」）。
  String summary() =>
      '$width×$height×$frames帧 隔$frameGapCycles拍 ${pattern.displayName} 泡$inGapPct% 压$outStallPct%'
      '${clkMHz == 100 ? '' : ' CLK${fmtClkMHz(clkMHz)}M'}';

  /// 是否为默认参数（与历史固定行为一致）。
  bool get isDefault => this == const IpSimStimulus();

  /// 参数合法性校验；合法返回 null，否则返回错误说明。
  String? validate() {
    if (width < 1 || width > 8192) return '帧宽须在 1~8192 之间';
    if (height < 1 || height > 8192) return '帧高须在 1~8192 之间';
    if (frames < 1 || frames > 64) return '帧数须在 1~64 之间';
    if (frameGapCycles < 0 || frameGapCycles > 100000) {
      return '帧间隔须在 0~100000 拍之间';
    }
    if (!clkMHz.isFinite || clkMHz < 1 || clkMHz > 1000) {
      return 'CLK频率须在 1~1000 MHz 之间';
    }
    if (seed < 0 || seed > 0xFFFFFFFF) return '随机种子须在 0~0xFFFFFFFF 之间';
    if (inGapPct < 0 || inGapPct >= 100) return '输入气泡率须在 0~99 之间';
    if (outStallPct < 0 || outStallPct >= 100) return '输出背压率须在 0~99 之间';
    return null;
  }

  IpSimStimulus copyWith({
    int? width,
    int? height,
    int? frames,
    int? frameGapCycles,
    double? clkMHz,
    IpSimPattern? pattern,
    int? seed,
    int? inGapPct,
    int? outStallPct,
  }) {
    return IpSimStimulus(
      width: width ?? this.width,
      height: height ?? this.height,
      frames: frames ?? this.frames,
      frameGapCycles: frameGapCycles ?? this.frameGapCycles,
      clkMHz: clkMHz ?? this.clkMHz,
      pattern: pattern ?? this.pattern,
      seed: seed ?? this.seed,
      inGapPct: inGapPct ?? this.inGapPct,
      outStallPct: outStallPct ?? this.outStallPct,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is IpSimStimulus &&
      other.width == width &&
      other.height == height &&
      other.frames == frames &&
      other.frameGapCycles == frameGapCycles &&
      other.clkMHz == clkMHz &&
      other.pattern == pattern &&
      other.seed == seed &&
      other.inGapPct == inGapPct &&
      other.outStallPct == outStallPct;

  @override
  int get hashCode => Object.hash(width, height, frames, frameGapCycles,
      clkMHz, pattern, seed, inGapPct, outStallPct);
}

/// CLK 频率（MHz）显示格式：整数不带小数点（100 → '100'，74.25 →
/// '74.25'）。工具栏摘要与 tb 注释共用。
String fmtClkMHz(double clkMHz) => clkMHz == clkMHz.roundToDouble()
    ? clkMHz.toInt().toString()
    : clkMHz.toString();

/// tb 时钟半周期（ns，timescale 1ns/1ps）：500 / clkMHz。默认 100MHz
/// 输出 '5'（与历史 `always #5 clk = ~clk;` 逐字节一致）；否则最多 3 位
/// 小数（1ps 精度）并去尾零（148.5MHz → '3.367'）。
String ipClkHalfNs(double clkMHz) {
  if (clkMHz == 100) return '5';
  var s = (500 / clkMHz).toStringAsFixed(3);
  while (s.endsWith('0')) {
    s = s.substring(0, s.length - 1);
  }
  if (s.endsWith('.')) s = s.substring(0, s.length - 1);
  return s;
}

/// 每编组会话缓存的激励参数（与 sessionIpGenOptions 同口径，随会话存续）。
final Map<String, IpSimStimulus> sessionIpSimStimulus = {};

/// 激励像素生成器：按 [IpSimStimulus.pattern] 产出第 (x, y) 像素的三通道
/// 激励值（各 0..maxValue）。随机图案内部持有 LCG 状态（跨帧连续推进，
/// 默认种子下与历史固定生成序列逐位一致），须按光栅顺序逐像素调用。
class IpStimulusGen {
  final IpSimStimulus stim;
  final int maxValue;
  int _state;

  IpStimulusGen(this.stim, this.maxValue) : _state = stim.seed & 0xFFFFFFFF;

  int _next() {
    _state = (_state * 1664525 + 1013904223) & 0xFFFFFFFF;
    return _state;
  }

  /// 返回 (H, S, L) 三通道激励值。
  (int, int, int) next(int x, int y) {
    final mv = maxValue;
    switch (stim.pattern) {
      case IpSimPattern.random:
        // 与历史固定行为同口径：每像素 3 次 LCG 采样，取高 16 位截到域。
        return ((_next() >> 16) & mv, (_next() >> 16) & mv,
            (_next() >> 16) & mv);
      case IpSimPattern.hGradient:
        final d = stim.width > 1 ? stim.width - 1 : 1;
        final v = (x * mv) ~/ d;
        return (v, mv - v, v);
      case IpSimPattern.vGradient:
        final d = stim.height > 1 ? stim.height - 1 : 1;
        final v = (y * mv) ~/ d;
        return (v, v, mv - v);
      case IpSimPattern.solid:
        return (mv ~/ 3, mv ~/ 2, (2 * mv) ~/ 3);
      case IpSimPattern.checker:
        final v = (((x >> 3) + (y >> 3)) & 1) == 0 ? mv : 0;
        return (v, v, v);
      // 24 位色彩激励：产生可视化彩色渐变（HSL=色相水平扫描彩虹；
      // RGB/YUV=第一通道水平渐变、第二通道垂直渐变、第三通道中性中值），
      // 字节序 Lo 时第一/第三通道互换（高字节承载 L/B/V）。
      case IpSimPattern.hsl24Hi || IpSimPattern.hsl24Lo:
        final d = stim.width > 1 ? stim.width - 1 : 1;
        return _pack24((x * mv) ~/ d, mv, mv ~/ 2);
      case IpSimPattern.rgb24Hi || IpSimPattern.rgb24Lo:
        final dw = stim.width > 1 ? stim.width - 1 : 1;
        final dh = stim.height > 1 ? stim.height - 1 : 1;
        return _pack24((x * mv) ~/ dw, (y * mv) ~/ dh, mv ~/ 2);
      case IpSimPattern.yuv24Hi || IpSimPattern.yuv24Lo:
        final dw = stim.width > 1 ? stim.width - 1 : 1;
        final dh = stim.height > 1 ? stim.height - 1 : 1;
        return _pack24((x * mv) ~/ dw, (y * mv) ~/ dh, mv ~/ 2);
    }
  }

  /// 按图案字节序打包色彩通道：Hi = (第一, 中间, 第三)；Lo 互换首尾
  ///（高字节承载第三通道 L/B/V）。
  (int, int, int) _pack24(int first, int mid, int third) =>
      stim.pattern.colorHighByteFirst ? (first, mid, third) : (third, mid, first);
}
