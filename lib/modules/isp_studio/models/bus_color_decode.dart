/// 总线色彩解码（背景色填充）：把总线 24 位数值按 HSL/RGB/YUV 色度空间
/// 解码为 RGB 颜色，供「仿真波形」标签页的总线数据块填充背景（如 FPGA
/// 图像通路的像素总线直观显色）。纯 Dart，无 Flutter 依赖。
library;

/// 色度解码空间。
enum BusColorSpace {
  none('关闭', '', ''),
  hsl('HSL', 'H', 'L'),
  rgb('RGB', 'R', 'B'),
  yuv('YUV', 'Y', 'V');

  final String displayName;

  /// 高字节默认承载的通道名（H/R/Y）。
  final String firstChannel;

  /// 字节顺序切换后高字节承载的通道名（L/B/V）。
  final String thirdChannel;

  const BusColorSpace(this.displayName, this.firstChannel, this.thirdChannel);
}

/// 把 24 位总线数值解码为 (R, G, B)（各 0..255）；[space] 为 none 返回
/// null（不填充）。
///
/// 字节布局：[highByteFirst] 为 true（默认）时高字节（bit16..23）= 第一
/// 通道（H/R/Y）、bit8..15 = 中间通道（S/G/U）、低字节 = 第三通道
/// （L/B/V）；false 时第一/第三通道字节互换（高字节 = L/B/V）。
///
/// - HSL：H 字节映射 0..360°，S/L 映射 0..1，标准 HSL→RGB 转换；
/// - YUV：BT.601  studio-swing（U/V 以 128 为中心），结果钳位到 0..255。
(int, int, int)? decodeBusColor24(BusColorSpace space, int value,
    {bool highByteFirst = true}) {
  if (space == BusColorSpace.none) return null;
  final v = value & 0xFFFFFF;
  final b2 = (v >> 16) & 0xFF;
  final b1 = (v >> 8) & 0xFF;
  final b0 = v & 0xFF;
  final first = highByteFirst ? b2 : b0;
  final mid = b1;
  final third = highByteFirst ? b0 : b2;

  switch (space) {
    case BusColorSpace.none:
      return null;
    case BusColorSpace.rgb:
      return (first, mid, third);
    case BusColorSpace.hsl:
      return _hslToRgb(first / 255.0, mid / 255.0, third / 255.0);
    case BusColorSpace.yuv:
      final y = first.toDouble();
      final u = mid - 128.0;
      final w = third - 128.0;
      return (
        _clamp8(y + 1.402 * w),
        _clamp8(y - 0.344136 * u - 0.714136 * w),
        _clamp8(y + 1.772 * u),
      );
  }
}

/// 填充背景上的文本色：按亮度取黑/白保证可读性。
/// [r]/[g]/[b] 为 0..255；亮度阈值 140。
bool isLightColor(int r, int g, int b) =>
    0.299 * r + 0.587 * g + 0.114 * b > 140;

/// HSL→RGB：h/s/l 均 0..1（h=1 等价 360°≡0°），返回 0..255 整数。
(int, int, int) _hslToRgb(double h, double s, double l) {
  final c = (1 - (2 * l - 1).abs()) * s;
  final hp = (h * 6) % 6;
  final x = c * (1 - (hp % 2 - 1).abs());
  final m = l - c / 2;
  final (r1, g1, b1) = switch (hp.floor()) {
    0 => (c, x, 0.0),
    1 => (x, c, 0.0),
    2 => (0.0, c, x),
    3 => (0.0, x, c),
    4 => (x, 0.0, c),
    _ => (c, 0.0, x),
  };
  return (_clamp8((r1 + m) * 255), _clamp8((g1 + m) * 255),
      _clamp8((b1 + m) * 255));
}

int _clamp8(double v) => v < 0 ? 0 : (v > 255 ? 255 : v.round());
