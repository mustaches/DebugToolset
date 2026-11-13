import 'dart:typed_data';

import 'isp_kernels.dart';

int _divRound(int num, int den) {
  if (den <= 0) return 0;
  if (num >= 0) return (num + (den >> 1)) ~/ den;
  return -((-num + (den >> 1)) ~/ den);
}

int _clamp(int v, int maxValue) => v.clamp(0, maxValue);

int _q14Norm(int v, int maxValue) => _divRound(v * 16384, maxValue);

int _q14Mul(int a, int b) => (a * b + 8192) >> 14;

List<int> _rgbToHslQ14(int r, int g, int b, int maxValue) {
  var mx = g > b ? g : b;
  var mn = g < b ? g : b;
  mx = r > mx ? r : mx;
  mn = r < mn ? r : mn;
  final l = (mx + mn) >> 1;
  final d = mx - mn;
  var s = 0;
  var h = 0;
  if (d > 0) {
    final den = l > 8192 ? 32768 - mx - mn : mx + mn;
    s = _divRound(d * 16384, den);
    int t;
    if (mx == r) {
      t = _divRound((g - b) * 16384, d);
      if (t < 0) t += 98304;
    } else if (mx == g) {
      t = _divRound((b - r) * 16384, d) + 32768;
    } else {
      t = _divRound((r - g) * 16384, d) + 65536;
    }
    h = _divRound(t, 6);
  }
  return [
    _clamp(_divRound(h * maxValue, 16384), maxValue),
    _clamp(_divRound(s * maxValue, 16384), maxValue),
    _clamp(_divRound(l * maxValue, 16384), maxValue),
  ];
}

int _hueQ14(int p, int q, int t) {
  if (t < 0) t += 49152;
  if (t > 49152) t -= 49152;
  if (t < 8192) return p + _divRound((q - p) * t, 8192);
  if (t < 24576) return q;
  if (t < 32768) return p + _divRound((q - p) * (32768 - t), 8192);
  return p;
}

List<int> _hslToRgbQ14(int h, int s, int l, int maxValue) {
  h %= 16384;
  if (h < 0) h += 16384;
  int r, g, b;
  if (s == 0) {
    r = g = b = l;
  } else {
    final q = l < 8192 ? l + _q14Mul(l, s) : l + s - _q14Mul(l, s);
    final p = 2 * l - q;
    final h3 = h * 3;
    r = _hueQ14(p, q, h3 + 16384);
    g = _hueQ14(p, q, h3);
    b = _hueQ14(p, q, h3 - 16384);
  }
  return [
    _clamp(_divRound(r * maxValue, 16384), maxValue),
    _clamp(_divRound(g * maxValue, 16384), maxValue),
    _clamp(_divRound(b * maxValue, 16384), maxValue),
  ];
}

List<int> cscFixedPixel(
  String typeId,
  int a,
  int b,
  int c,
  int maxValue, {
  String standard = 'bt601',
  String range = 'full',
}) {
  Uint16List call(Uint16List input) => Uint16List.fromList(input);
  Uint16List pixel(int a, int b, int c) => call(Uint16List.fromList([a, b, c]));
  switch (typeId) {
    case 'csc_rgb2yuv':
      return convertRgbToYuvCsc(
        pixel(a, b, c),
        width: 1,
        height: 1,
        maxValue: maxValue,
        standard: standard,
        range: range,
      );
    case 'csc_yuv2rgb':
      return yuvToRgb(pixel(a, b, c), maxValue: maxValue, standard: standard);
    case 'csc_rgb2hsl':
      return _rgbToHslQ14(
        _q14Norm(a, maxValue),
        _q14Norm(b, maxValue),
        _q14Norm(c, maxValue),
        maxValue,
      );
    case 'csc_hsl2rgb':
      return _hslToRgbQ14(
        _q14Norm(a, maxValue),
        _q14Norm(b, maxValue),
        _q14Norm(c, maxValue),
        maxValue,
      );
    case 'csc_yuv2hsl':
      final rgb = yuvToRgb(
        pixel(a, b, c),
        maxValue: maxValue,
        standard: standard,
      );
      return _rgbToHslQ14(
        _q14Norm(rgb[0], maxValue),
        _q14Norm(rgb[1], maxValue),
        _q14Norm(rgb[2], maxValue),
        maxValue,
      );
    case 'csc_hsl2yuv':
      final rgb = _hslToRgbQ14(
        _q14Norm(a, maxValue),
        _q14Norm(b, maxValue),
        _q14Norm(c, maxValue),
        maxValue,
      );
      return convertRgbToYuvCsc(
        pixel(rgb[0], rgb[1], rgb[2]),
        width: 1,
        height: 1,
        maxValue: maxValue,
        standard: standard,
      );
    default:
      throw ArgumentError('未知 ColorTrans 类型: $typeId');
  }
}
