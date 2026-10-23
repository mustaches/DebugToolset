// 一次性脚本：从 codicons-ico-multi 的 .ico 提取最大帧，重着色为纯白
// （保留 alpha），输出 64x64 PNG 到 icons/。用法：dart run scratch/ico_extract.dart
import 'dart:io';

import 'package:image/image.dart' as img;

void main() {
  const jobs = {
    'codicons-ico-multi/folder-opened-compact.ico': 'icons/folder-opened.png',
    'codicons-ico-multi/save.ico': 'icons/save.png',
    'codicons-ico-multi/gear.ico': 'icons/gear.png',
    'codicons-ico-multi/go-to-file.ico': 'icons/go-to-file.png',
    'codicons-ico-multi/code-oss.ico': 'icons/code-oss.png',
    'codicons-ico-multi/screen-full.ico': 'icons/screen-full.png',
    'codicons-ico-multi/screen-normal.ico': 'icons/screen-normal.png',
    'codicons-ico-multi/book.ico': 'icons/book.png',
    'codicons-ico-multi/add-small.ico': 'icons/add-small.png',
    'codicons-ico-multi/remove-small.ico': 'icons/remove-small.png',
    'codicons-ico-multi/diff-added.ico': 'icons/diff-added.png',
    'codicons-ico-multi/diff-removed.ico': 'icons/diff-removed.png',
    'codicons-ico-multi/layout-sidebar-right-dock.ico':
        'icons/layout-sidebar-right-dock.png',
    'codicons-ico-multi/voice-mode-download.ico':
        'icons/voice-mode-download.png',
    'codicons-ico-multi/right-panel-hide.ico': 'icons/right-panel-hide.png',
    'codicons-ico-multi/zoom-in.ico': 'icons/zoom-in.png',
    'codicons-ico-multi/zoom-out.ico': 'icons/zoom-out.png',
    'codicons-ico-multi/git-commit.ico': 'icons/git-commit.png',
    'codicons-ico-multi/reply.ico': 'icons/reply.png',
    'codicons-ico-multi/forward.ico': 'icons/forward.png',
    'codicons-ico-multi/search-sparkle.ico': 'icons/search-sparkle.png',
    'codicons-ico-multi/chevron-left.ico': 'icons/chevron-left.png',
    'codicons-ico-multi/chevron-right.ico': 'icons/chevron-right.png',
    'codicons-ico-multi/rising-edge.ico': 'icons/rising-edge.png',
    'codicons-ico-multi/falling-edge.ico': 'icons/falling-edge.png',
    'codicons-ico-multi/search.ico': 'icons/search.png',
    'codicons-ico-multi/oscilloscope.ico': 'icons/oscilloscope.png',
    'codicons-ico-multi/Dim-Base.ico': 'icons/dim-base.png',
    'codicons-ico-multi/Dim-Continue.ico': 'icons/dim-continue.png',
  };
  jobs.forEach((src, dst) {
    final bytes = File(src).readAsBytesSync();
    final dec = img.IcoDecoder();
    if (dec.startDecode(bytes) == null) {
      stderr.writeln('解码失败: $src');
      exitCode = 1;
      return;
    }
    // 多帧 ico 取最大尺寸帧，>64 则缩到 64x64。
    img.Image? frame;
    for (var i = 0; i < dec.numFrames(); i++) {
      final f = dec.decodeFrame(i);
      if (f != null && (frame == null || f.width > frame.width)) frame = f;
    }
    if (frame == null) {
      stderr.writeln('无有效帧: $src');
      exitCode = 1;
      return;
    }
    final raw = frame;
    img.Image cur = raw.width > 64
        ? img.copyResize(raw, width: 64, height: 64)
        : raw;
    for (final p in cur) {
      p
        ..r = 255
        ..g = 255
        ..b = 255;
    }
    // 线条加粗（alpha 膨胀）：3x3 邻域取最大 alpha，按目标文件配置
    // 膨胀趟数（示波器图标线条过细的教训；terminal 风格重绘后暂无
    // 需要加粗的图标）。
    final dilateTimes = dilateTimesOf[dst] ?? 0;
    for (var i = 0; i < dilateTimes; i++) {
      cur = dilateAlpha(cur);
    }
    File(dst).writeAsBytesSync(img.encodePng(cur));
    stdout.writeln('$src -> $dst (${cur.width}x${cur.height})');
  });
}

/// 需要 alpha 膨胀加粗的目标文件 → 膨胀趟数（每趟线条约粗 2px/
/// 64px 基准）。
const dilateTimesOf = <String, int>{};

/// alpha 膨胀一趟：3x3 邻域取最大 alpha（RGB 恒白）。
img.Image dilateAlpha(img.Image src) {
  final w = src.width, h = src.height;
  final dst = img.Image.from(src);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var maxA = 0;
      for (var dy = -1; dy <= 1; dy++) {
        final yy = y + dy;
        if (yy < 0 || yy >= h) continue;
        for (var dx = -1; dx <= 1; dx++) {
          final xx = x + dx;
          if (xx < 0 || xx >= w) continue;
          final a = src.getPixel(xx, yy).a.toInt();
          if (a > maxA) maxA = a;
        }
      }
      dst.setPixelRgba(x, y, 255, 255, 255, maxA);
    }
  }
  return dst;
}
