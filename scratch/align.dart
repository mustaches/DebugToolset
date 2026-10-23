import 'dart:io';

// 逐帧内容对齐：每个录屏帧在源视频里找最相似帧（单调窗内 MAD 最小），
// 输出 录屏帧号 源帧号 MAD，并统计重复/跳帧/回退。
void main(List<String> args) {
  const fb = 480 * 270;
  final ref = File(args[0]).readAsBytesSync();
  final cap = File(args[1]).readAsBytesSync();
  final refN = ref.length ~/ fb, capN = cap.length ~/ fb;
  int mad(int a, int b) {
    var s = 0;
    for (var i = 0; i < fb; i += 4) {
      s += (cap[a * fb + i] - ref[b * fb + i]).abs();
    }
    return s;
  }

  var best = 0;
  final out = StringBuffer();
  var dup = 0, jump = 0, back = 0, madSum = 0;
  final series = <int>[];
  for (var c = 0; c < capN; c++) {
    var bestMad = 1 << 62, bestIdx = best;
    final end = (best + 6).clamp(0, refN - 1);
    for (var r = best; r <= end; r++) {
      final m = mad(c, r);
      if (m < bestMad) {
        bestMad = m;
        bestIdx = r;
      }
    }
    if (bestIdx > best) {
      if (bestIdx - best >= 2) jump++;
    } else if (bestIdx == best && c > 0) {
      dup++;
    }
    if (bestIdx < best) back++;
    best = bestIdx;
    series.add(bestIdx);
    madSum += bestMad;
    out.writeln('$c $bestIdx ${bestMad ~/ (fb ~/ 4)}');
  }
  File(args[2]).writeAsStringSync(out.toString());
  final uniq = series.toSet().length;
  print('${args[1]}: 录屏帧=$capN 覆盖源帧 ${series.first}..${series.last} '
      '唯一源帧=$uniq 重复(停在同帧)=$dup 跳帧(前进≥2)=$jump 回退=$back '
      '平均MAD=${madSum ~/ capN}');
}
