// 一次性脚本：从剪贴板截图提取「连续」「基线」两个尺寸标注图标为 ico。
// 红框为人工标注（剔除），深色底转透明，保留原双色（白线+蓝箭头）。
import 'dart:io';

import 'package:image/image.dart' as img;

void main() {
  final shot =
      img.decodePng(File('scratch/clipboard_img.png').readAsBytesSync())!;
  final w = shot.width, h = shot.height;

  bool isRed(img.Pixel p) => p.r > 200 && p.g < 80 && p.b < 80;

  // 红框的行/列命中计数，连片区即框线。
  final rowHits = List.filled(h, 0);
  final colHits = List.filled(w, 0);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (isRed(shot.getPixel(x, y))) {
        rowHits[y]++;
        colHits[x]++;
      }
    }
  }
  List<(int, int)> ranges(List<int> hits, int minCount) {
    final out = <(int, int)>[];
    var start = -1;
    for (var i = 0; i < hits.length; i++) {
      if (hits[i] >= minCount) {
        if (start < 0) start = i;
      } else if (start >= 0) {
        out.add((start, i - 1));
        start = -1;
      }
    }
    if (start >= 0) out.add((start, hits.length - 1));
    return out;
  }

  // 框线：水平线为长横条（>=60px 命中），竖线为长竖条。
  final hLines = ranges(rowHits, 60);
  final vLines = ranges(colHits, 60);
  // ignore: avoid_print
  print('水平框线: $hLines');
  // ignore: avoid_print
  print('垂直框线: $vLines');
  if (hLines.length < 4 || vLines.length < 2) {
    stderr.writeln('红框识别失败');
    exitCode = 1;
    return;
  }

  // 两个红框：左/右竖线取第一个框的（两框共用 x 范围），行线两两一组。
  final left = vLines.first.$2 + 2; // 框线右沿 +2
  final right = vLines.last.$1 - 2;
  final boxes = [
    (top: hLines[0].$2 + 2, bottom: hLines[1].$1 - 2),
    (top: hLines[2].$2 + 2, bottom: hLines[3].$1 - 2),
  ];
  final names = ['Dim-Continue', 'Dim-Base'];

  for (var i = 0; i < 2; i++) {
    final box = boxes[i];
    final cw = right - left + 1, ch = box.bottom - box.top + 1;
    final crop = img.copyCrop(shot,
        x: left, y: box.top, width: cw, height: ch);
    // 深色底转透明：以四角均值为底色，颜色距离线性映射 alpha。
    num bgR = 0, bgG = 0, bgB = 0;
    for (final c in [
      crop.getPixel(0, 0),
      crop.getPixel(cw - 1, 0),
      crop.getPixel(0, ch - 1),
      crop.getPixel(cw - 1, ch - 1),
    ]) {
      bgR += c.r;
      bgG += c.g;
      bgB += c.b;
    }
    bgR ~/= 4;
    bgG ~/= 4;
    bgB ~/= 4;
    for (final p in crop) {
      final d = ((p.r - bgR).abs() + (p.g - bgG).abs() + (p.b - bgB).abs()) / 3;
      // 距离 <=8 全透明，>=48 全不透明，之间线性（抗锯齿过渡）。
      p.a = d <= 8 ? 0 : d >= 48 ? 255 : ((d - 8) / 40 * 255).round();
    }
    final icon = img.copyResize(crop,
        width: 128, height: 128, interpolation: img.Interpolation.cubic);
    final path = 'codicons-ico-multi/${names[i]}.ico';
    File(path).writeAsBytesSync(img.encodeIco(icon));
    // 预览：深灰底上看效果。
    final preview = img.Image(width: 128, height: 128);
    img.fill(preview, color: img.ColorRgb8(37, 37, 37));
    img.compositeImage(preview, icon);
    File('scratch/${names[i]}_preview.png')
        .writeAsBytesSync(img.encodePng(preview));
    // ignore: avoid_print
    print('$path 裁剪=(${left},${box.top}) ${cw}x$ch 底色=($bgR,$bgG,$bgB)');
  }
}
