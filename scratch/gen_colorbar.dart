// 生成 1920x1080 标准八色彩条：PNG + Bayer RGGB RAW（10bit unpacked LSB）+ 同名 txt。
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

void main() {
  const w = 1920, h = 1080;
  // 标准八色彩条（8-bit RGB）。
  const bars = [
    (255, 255, 255), // 白
    (255, 255, 0), // 黄
    (0, 255, 255), // 青
    (0, 255, 0), // 绿
    (255, 0, 255), // 品红
    (255, 0, 0), // 红
    (0, 0, 255), // 蓝
    (0, 0, 0), // 黑
  ];
  const barWidth = w ~/ 8; // 240

  (int, int, int) pixelAt(int x) => bars[x ~/ barWidth];

  // ---- PNG（RGBA8）----
  final rgba = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    var i = y * w * 4;
    for (var x = 0; x < w; x++, i += 4) {
      final (r, g, b) = pixelAt(x);
      rgba[i] = r;
      rgba[i + 1] = g;
      rgba[i + 2] = b;
      rgba[i + 3] = 255;
    }
  }
  final image = img.Image.fromBytes(
      width: w,
      height: h,
      bytes: rgba.buffer,
      numChannels: 4,
      order: img.ChannelOrder.rgba);
  File('BayerRGGB/ColorBars_1920x1080.png').writeAsBytesSync(img.encodePng(image));

  // ---- Bayer RGGB RAW（10bit 线性，unpacked LSB，16bit 小端）----
  // RGGB 相位：(0,0)=R (1,0)=Gr / (0,1)=Gb (1,1)=B；8bit 值左移 2 位到 10bit。
  final raw = Uint16List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final (r, g, b) = pixelAt(x);
      final phase = ((y & 1) << 1) | (x & 1);
      final v8 = switch (phase) {
        0 => r, // R
        3 => b, // B
        _ => g, // Gr / Gb
      };
      raw[y * w + x] = v8 << 2;
    }
  }
  final rawPath = 'BayerRGGB/RAW_1920x1080_10bits_RGGB_Linear_1frame.raw';
  final out = ByteData(raw.length * 2);
  for (var i = 0; i < raw.length; i++) {
    out.setUint16(i * 2, raw[i], Endian.little);
  }
  File(rawPath).writeAsBytesSync(out.buffer.asUint8List());

  // ---- 同名 txt（黑电平 0，16 倍刻度）----
  File(rawPath.replaceAll('.raw', '.txt')).writeAsStringSync('''
[common]
Width=1920
Height=1080
Bits=10
Bayer=RGGB
BlackLevel_R=0
BlackLevel_Gr=0
BlackLevel_Gb=0
BlackLevel_B=0
''');

  print('PNG  : BayerRGGB/ColorBars_1920x1080.png');
  print('RAW  : $rawPath (${w * h * 2} bytes)');
  print('TXT  : ${rawPath.replaceAll('.raw', '.txt')}');
}
