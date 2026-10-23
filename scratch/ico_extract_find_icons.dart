// 一次性脚本：提取查找匹配候选图标为纯白 64x64 PNG 并拼对比图。
// 用法：dart run scratch/ico_extract_find_icons.dart
import 'dart:io';

import 'package:image/image.dart' as img;

const candidates = [
  'arrow-left',
  'arrow-right',
  'arrow-small-left',
  'arrow-small-right',
  'arrow-circle-left',
  'arrow-circle-right',
  'chevron-left',
  'chevron-right',
  'chevron-left-compact',
  'chevron-right-compact',
];

img.Image? extract(String name) {
  final bytes = File('codicons-ico-multi/$name.ico').readAsBytesSync();
  final dec = img.IcoDecoder();
  if (dec.startDecode(bytes) == null) return null;
  img.Image? frame;
  for (var i = 0; i < dec.numFrames(); i++) {
    final f = dec.decodeFrame(i);
    if (f != null && (frame == null || f.width > frame.width)) frame = f;
  }
  if (frame == null) return null;
  if (frame.width > 64) {
    frame = img.copyResize(frame, width: 64, height: 64);
  }
  for (final p in frame) {
    p
      ..r = 255
      ..g = 255
      ..b = 255;
  }
  return frame;
}

void main() {
  const cell = 96;
  final n = candidates.length;
  final sheet = img.Image(width: cell * (n ~/ 2), height: cell * 2 + 24 * 2);
  img.fill(sheet, color: img.ColorRgb8(30, 30, 30)); // 应用暗色底
  for (var i = 0; i < n; i++) {
    final icon = extract(candidates[i]);
    if (icon == null) {
      stderr.writeln('提取失败: ${candidates[i]}');
      continue;
    }
    File('scratch/find_icon_${candidates[i]}.png')
        .writeAsBytesSync(img.encodePng(icon));
    final col = i % (n ~/ 2), row = i ~/ (n ~/ 2);
    final x = col * cell + (cell - icon.width) ~/ 2;
    final y = row * (cell + 24) + (cell - icon.height) ~/ 2;
    img.compositeImage(sheet, icon, dstX: x, dstY: y);
    img.drawString(sheet, candidates[i],
        font: img.arial14, x: col * cell + 2, y: row * (cell + 24) + cell + 4);
  }
  File('scratch/find_icon_sheet.png').writeAsBytesSync(img.encodePng(sheet));
  stdout.writeln('done: scratch/find_icon_sheet.png');
}
