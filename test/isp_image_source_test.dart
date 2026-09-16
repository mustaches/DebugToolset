// 图片源解码与馈源短路的位级一致性测试（优化 13）：
// - decodeImageFileToRgba8 快速通道（3/4 通道直通）与旧 convert 路径位级一致；
// - rgba8ToRgb16 + tonemapToRgba 在 maxValue=255/gamma=1.0 下恒等
//   （8 位单节点 out_rgb 链短路的安全依据）。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:debug_tool_set/modules/isp_studio/pipeline/image_source.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/isp_kernels.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/video_source.dart';

/// 旧实现口径（convert 通用路径），作为快速通道的对照基准。
Uint8List legacyDecodeToRgba8(Uint8List bytes) {
  var image = img.decodeImage(bytes)!;
  image = image.convert(format: img.Format.uint8, numChannels: 4);
  return image.toUint8List();
}

/// 生成确定性测试图（伪随机 but 固定公式）。
img.Image makeImage(int w, int h, int numChannels) {
  final image = img.Image(width: w, height: h, numChannels: numChannels);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = y * w + x;
      image.setPixelRgb(x, y, (i * 37) % 256, (i * 61 + 7) % 256,
          (i * 13 + 200) % 256);
    }
  }
  return image;
}

void main() {
  group('decodeImageFileToRgba8 快速通道', () {
    test('3 通道 PNG 与旧 convert 路径位级一致', () async {
      final png = img.encodePng(makeImage(37, 23, 3));
      final f = File(
          '${Directory.systemTemp.path}/isp_img_src_test_rgb.png');
      await f.writeAsBytes(png);
      try {
        final (rgba, w, h) = await decodeImageFileToRgba8(f.path);
        expect((w, h), (37, 23));
        expect(rgba, legacyDecodeToRgba8(png));
      } finally {
        await f.delete();
      }
    });

    test('4 通道 PNG 与旧 convert 路径位级一致', () async {
      final png = img.encodePng(makeImage(41, 19, 4));
      final f = File(
          '${Directory.systemTemp.path}/isp_img_src_test_rgba.png');
      await f.writeAsBytes(png);
      try {
        final (rgba, w, h) = await decodeImageFileToRgba8(f.path);
        expect((w, h), (41, 19));
        expect(rgba, legacyDecodeToRgba8(png));
      } finally {
        await f.delete();
      }
    });

    test('JPEG 与旧 convert 路径位级一致', () async {
      final jpg = img.encodeJpg(makeImage(33, 27, 3));
      final f = File(
          '${Directory.systemTemp.path}/isp_img_src_test.jpg');
      await f.writeAsBytes(jpg);
      try {
        final (rgba, w, h) = await decodeImageFileToRgba8(f.path);
        expect((w, h), (33, 27));
        expect(rgba, legacyDecodeToRgba8(jpg));
      } finally {
        await f.delete();
      }
    });
  });

  group('8 位单节点链短路依据', () {
    test('rgba8ToRgb16 + tonemapToRgba 在 maxValue=255/gamma=1.0 恒等',
        () {
      const w = 61, h = 17;
      final rgba = Uint8List(w * h * 4);
      for (var i = 0; i < rgba.length; i += 4) {
        rgba[i] = (i * 7) % 256;
        rgba[i + 1] = (i * 3 + 11) % 256;
        rgba[i + 2] = (i * 5 + 251) % 256;
        rgba[i + 3] = 255;
      }
      final (rgb16, rw, rh) = rgba8ToRgb16(rgba, w, h, 255);
      expect((rw, rh), (w, h));
      final back = tonemapToRgba(rgb16, maxValue: 255, gamma: 1.0);
      expect(back, rgba);
    });
  });
}
