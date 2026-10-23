// 一次性脚本：按 terminal.ico 风格重绘全部自绘图标。
// 风格基准（terminal.ico 实测）：6 帧 16/20/24/32/48/64、深灰
// (68,68,68)、内容区距四边 ~20%（高方向一致）、笔画 ~0.05S。
// 4x 超采样抗锯齿；fillPolygon 顶点必须整数（image 4.3.0 小数顶点
// 光栅化错误的教训）。
import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;

const sizes = [16, 20, 24, 32, 48, 64];
final glyphColor = img.ColorRgb8(68, 68, 68); // terminal.ico 同款深灰

const m = 0.2; // 四边留白比例（terminal 64px 帧内容 (13,13)-(50,50)）
const strokeRatio = 0.05; // 笔画宽 / S

img.Image newCanvas(int s) => img.Image(width: s, height: s, numChannels: 4);

void vBar(img.Image c, double x, double y0, double y1, double w) {
  img.fillRect(c,
      x1: (x - w / 2).round(),
      y1: y0.round(),
      x2: (x + w / 2).round(),
      y2: y1.round(),
      color: glyphColor);
}

void hBar(img.Image c, double x0, double x1, double y, double w) {
  img.fillRect(c,
      x1: x0.round(),
      y1: (y - w / 2).round(),
      x2: x1.round(),
      y2: (y + w / 2).round(),
      color: glyphColor);
}

void seg(img.Image c, double x0, double y0, double x1, double y1, double w) {
  img.drawLine(c,
      x1: x0.round(),
      y1: y0.round(),
      x2: x1.round(),
      y2: y1.round(),
      color: glyphColor,
      thickness: w);
}

void tri(img.Image c, double ax, double ay, double bx, double by, double cx,
    double cy) {
  img.fillPolygon(c,
      vertices: [
        img.Point(ax.round(), ay.round()),
        img.Point(bx.round(), by.round()),
        img.Point(cx.round(), cy.round()),
      ],
      color: glyphColor);
}

/// 双向箭头（尺寸标注）：杆 + 两端实心三角，头部尺寸随段长封顶。
void arrow(img.Image c, double x0, double x1, double y, double w) {
  final segLen = x1 - x0;
  final hl = math.min(w * 2.6, segLen * 0.36);
  final hw = hl * 0.55;
  seg(c, x0 + hl * 0.5, y, x1 - hl * 0.5, y, w * 0.45);
  tri(c, x0, y, x0 + hl, y - hw, x0 + hl, y + hw);
  tri(c, x1, y, x1 - hl, y - hw, x1 - hl, y + hw);
}

/// 单向向上箭头（上升沿竖杆顶端）。
void triUp(img.Image c, double cx, double apexY, double baseY, double hw) {
  tri(c, cx, apexY, cx - hw, baseY, cx + hw, baseY);
}

/// 单向向下箭头。
void triDown(img.Image c, double cx, double apexY, double baseY, double hw) {
  tri(c, cx, apexY, cx - hw, baseY, cx + hw, baseY);
}

// ---- 各图标字形（S 为画布边长，内容区 0.2S..0.8S） ----

/// dimension：两条竖线 + 中间双向箭头。
img.Image drawDimension(int s) {
  final c = newCanvas(s);
  final w = s * strokeRatio;
  final x0 = s * m, x1 = s * (1 - m);
  final y0 = s * m, y1 = s * (1 - m);
  vBar(c, x0, y0, y1, w);
  vBar(c, x1, y0, y1, w);
  arrow(c, x0 + w * 0.5, x1 - w * 0.5, s / 2, w);
  return c;
}

/// Dim-Continue（连续标注）：3 条竖线 + 相邻间双向箭头。
img.Image drawDimContinue(int s) {
  final c = newCanvas(s);
  final w = s * strokeRatio;
  final x0 = s * m, x1 = s * (1 - m);
  final y0 = s * m, y1 = s * (1 - m);
  final midY = s / 2;
  const n = 3; // 竖线数（3 条：段更宽，箭头清晰）
  final step = (x1 - x0) / (n - 1);
  for (var i = 0; i < n; i++) {
    vBar(c, x0 + i * step, y0, y1, w);
  }
  for (var i = 0; i < n - 1; i++) {
    arrow(c, x0 + i * step + w * 0.5, x0 + (i + 1) * step - w * 0.5, midY, w);
  }
  return c;
}

/// Dim-Base（基线标注）：左通高基线 + 两条不同高度箭头 + 下垂短竖线。
img.Image drawDimBase(int s) {
  final c = newCanvas(s);
  final w = s * strokeRatio;
  final x0 = s * m, x1 = s * (1 - m);
  final y0 = s * m, y1 = s * (1 - m);
  final arrow1Y = y0 + (y1 - y0) * 0.28;
  final arrow2Y = y0 + (y1 - y0) * 0.62;
  final xMid = x0 + (x1 - x0) * 0.58;
  vBar(c, x0, y0, y1, w);
  vBar(c, xMid, arrow2Y, y1, w);
  vBar(c, x1, arrow1Y, y1, w);
  arrow(c, x0 + w * 0.5, x1 - w * 0.5, arrow1Y, w);
  arrow(c, x0 + w * 0.5, xMid - w * 0.5, arrow2Y, w);
  return c;
}

/// rising-edge：低位平线 → 竖直上升沿 → 高位平线，沿顶向上三角。
img.Image drawRisingEdge(int s) {
  final c = newCanvas(s);
  final w = s * strokeRatio;
  final x0 = s * m, x1 = s * (1 - m);
  final y0 = s * m, y1 = s * (1 - m);
  final yHi = y0 + (y1 - y0) * 0.22, yLo = y0 + (y1 - y0) * 0.78;
  final xM = x0 + (x1 - x0) * 0.44;
  hBar(c, x0, xM, yLo, w);
  vBar(c, xM, yHi, yLo, w);
  hBar(c, xM, x1, yHi, w);
  // 上升沿顶端向上箭头（apex 顶到内容区上沿）。
  triUp(c, xM, y0, yHi + w * 1.2, (y1 - y0) * 0.16);
  return c;
}

/// falling-edge：rising 的垂直镜像（高位平线 → 下降沿 → 低位平线，
/// 沿底向下三角）。
img.Image drawFallingEdge(int s) {
  final c = newCanvas(s);
  final w = s * strokeRatio;
  final x0 = s * m, x1 = s * (1 - m);
  final y0 = s * m, y1 = s * (1 - m);
  final yHi = y0 + (y1 - y0) * 0.22, yLo = y0 + (y1 - y0) * 0.78;
  final xM = x0 + (x1 - x0) * 0.44;
  hBar(c, x0, xM, yHi, w);
  vBar(c, xM, yHi, yLo, w);
  hBar(c, xM, x1, yLo, w);
  triDown(c, xM, y1, yLo - w * 1.2, (y1 - y0) * 0.16);
  return c;
}

/// oscilloscope：圆角屏幕 + 内部脉冲波形 + 两条腿 + 底座线。
img.Image drawOscilloscope(int s) {
  final c = newCanvas(s);
  final w = s * strokeRatio;
  final x0 = s * m, x1 = s * (1 - m);
  final y0 = s * m, y1 = s * (1 - m);
  final scrBottom = y0 + (y1 - y0) * 0.72;
  img.drawRect(c,
      x1: x0.round(),
      y1: y0.round(),
      x2: x1.round(),
      y2: scrBottom.round(),
      color: glyphColor,
      thickness: w,
      radius: s * 0.06);
  // 脉冲波形：平 → 升峰 → 深降 → 回升小鼓包 → 平。
  final midY = y0 + (scrBottom - y0) * 0.52;
  final pts = [
    (x0 + (x1 - x0) * 0.10, midY),
    (x0 + (x1 - x0) * 0.30, midY),
    (x0 + (x1 - x0) * 0.38, y0 + (scrBottom - y0) * 0.16),
    (x0 + (x1 - x0) * 0.48, y0 + (scrBottom - y0) * 0.86),
    (x0 + (x1 - x0) * 0.58, y0 + (scrBottom - y0) * 0.34),
    (x0 + (x1 - x0) * 0.66, midY),
    (x1 - (x1 - x0) * 0.10, midY),
  ];
  for (var i = 0; i < pts.length - 1; i++) {
    seg(c, pts[i].$1, pts[i].$2, pts[i + 1].$1, pts[i + 1].$2, w);
  }
  // 两条腿 + 底座线。
  final legY1 = y1 - (y1 - y0) * 0.06;
  vBar(c, x0 + (x1 - x0) * 0.24, scrBottom, legY1, w);
  vBar(c, x1 - (x1 - x0) * 0.24, scrBottom, legY1, w);
  hBar(c, x0 + (x1 - x0) * 0.12, x1 - (x1 - x0) * 0.12, legY1, w);
  return c;
}

/// timing-diagram：上下两条相位错开的方波 + 底部小双向箭头。
img.Image drawTimingDiagram(int s) {
  final c = newCanvas(s);
  final w = s * strokeRatio;
  final x0 = s * m, x1 = s * (1 - m);
  final y0 = s * m, y1 = s * (1 - m);
  // 上方波：低起，0.34S 升、0.50S 降、0.62S 升、0.72S 降。
  final uHi = y0 + (y1 - y0) * 0.06, uLo = y0 + (y1 - y0) * 0.28;
  final uEdges = [0.34, 0.50, 0.62, 0.72];
  var y = uLo;
  var px = x0;
  for (final f in uEdges) {
    final ex = x0 + (x1 - x0) * f;
    hBar(c, px, ex, y, w);
    vBar(c, ex, y == uLo ? uHi : uLo, y == uLo ? uLo : uHi, w);
    y = y == uLo ? uHi : uLo;
    px = ex;
  }
  hBar(c, px, x1, y, w);
  // 下方波：低起，0.46S 升、0.66S 降。
  final lHi = y0 + (y1 - y0) * 0.56, lLo = y0 + (y1 - y0) * 0.78;
  final lEdges = [0.46, 0.66];
  y = lLo;
  px = x0;
  for (final f in lEdges) {
    final ex = x0 + (x1 - x0) * f;
    hBar(c, px, ex, y, w);
    vBar(c, ex, y == lLo ? lHi : lLo, y == lLo ? lLo : lHi, w);
    y = y == lLo ? lHi : lLo;
    px = ex;
  }
  hBar(c, px, x1, y, w);
  // 底部小双向箭头（标注两条波形的相位差）。
  arrow(c, x0 + (x1 - x0) * 0.40, x0 + (x1 - x0) * 0.60,
      y0 + (y1 - y0) * 0.94, w);
  return c;
}

/// tabler__wave-saw-tool：平 → 缓降斜坡 → 陡升 → 缓降到右沿。
img.Image drawWaveSaw(int s) {
  final c = newCanvas(s);
  final w = s * strokeRatio;
  final x0 = s * m, x1 = s * (1 - m);
  final y0 = s * m, y1 = s * (1 - m);
  final yHi = y0 + (y1 - y0) * 0.08, yLo = y0 + (y1 - y0) * 0.92;
  final yMid = y0 + (y1 - y0) * 0.44;
  final xA = x0 + (x1 - x0) * 0.22; // 平线段右端
  final xB = x0 + (x1 - x0) * 0.66; // 陡升位置
  hBar(c, x0, xA, yMid, w);
  seg(c, xA, yMid, xB, yLo, w); // 缓降斜坡
  vBar(c, xB, yHi, yLo, w); // 陡升
  seg(c, xB, yHi, x1, yMid, w); // 缓降到右沿
  return c;
}

List<int> buildIco(List<img.Image> frames) {
  final pngs = [for (final f in frames) img.encodePng(f)];
  final bd = BytesBuilder();
  final count = frames.length;
  bd.add([0, 0, 1, 0, count & 0xFF, count >> 8]);
  var offset = 6 + 16 * count;
  for (var i = 0; i < count; i++) {
    final s = frames[i].width;
    final len = pngs[i].length;
    bd.add([
      s >= 256 ? 0 : s, s >= 256 ? 0 : s, 0, 0, 1, 0, 32, 0,
      len & 0xFF, (len >> 8) & 0xFF, (len >> 16) & 0xFF, (len >> 24) & 0xFF,
      offset & 0xFF, (offset >> 8) & 0xFF, (offset >> 16) & 0xFF,
      (offset >> 24) & 0xFF,
    ]);
    offset += len;
  }
  for (final p in pngs) {
    bd.add(p);
  }
  return bd.toBytes();
}

void main() {
  final jobs = <String, img.Image Function(int)>{
    'dimension': drawDimension,
    'Dim-Continue': drawDimContinue,
    'Dim-Base': drawDimBase,
    'rising-edge': drawRisingEdge,
    'falling-edge': drawFallingEdge,
    'oscilloscope': drawOscilloscope,
    'timing-diagram': drawTimingDiagram,
    'tabler__wave-saw-tool': drawWaveSaw,
  };
  for (final e in jobs.entries) {
    final frames = [
      for (final s in sizes)
        img.copyResize(e.value(s * 4),
            width: s, height: s, interpolation: img.Interpolation.cubic),
    ];
    File('codicons-ico-multi/${e.key}.ico').writeAsBytesSync(buildIco(frames));
    // ignore: avoid_print
    print('codicons-ico-multi/${e.key}.ico (${sizes.length} 帧)');
  }

  // 对比预览：terminal 64px 帧 + 全部新图标（白底，原色）。
  final dec = img.IcoDecoder();
  dec.startDecode(File('codicons-ico-multi/terminal.ico').readAsBytesSync());
  final term = dec.decodeFrame(dec.numFrames() - 1)!;
  final all = [
    term,
    for (final d in jobs.values) d(64),
  ];
  final row = img.Image(width: 64 * all.length + 8 * all.length, height: 64,
      numChannels: 4);
  img.fill(row, color: img.ColorRgb8(255, 255, 255));
  var x = 0;
  for (final f in all) {
    img.compositeImage(row, f, dstX: x, dstY: 0);
    x += 72;
  }
  final zoom = img.copyResize(row,
      width: row.width * 3, height: 192,
      interpolation: img.Interpolation.nearest);
  File('scratch/dim_style_preview.png').writeAsBytesSync(img.encodePng(zoom));
}
