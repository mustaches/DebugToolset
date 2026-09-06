// FPN 差异定位：flutter run -d windows -t scratch/debug_fpn.dart
// 用真实 RAW 跑到 FPN 前的链状态，然后：
// 1) 内联复制的 CPU applyFpn（导出每行/列 corr）；
// 2) GPU stats 回读 + runner 中位数逻辑（导出 GPU corr）；
// 3) 对比 corr 数组与最终帧，定位分歧环节。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:debug_tool_set/modules/isp_studio/pipeline/gpu/gpu_pipeline.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/isp_kernels.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/pipeline_runner.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

// ---- CPU applyFpn 的内联复制（从 isp_kernels.dart 逐字拷贝，导出 corr）----
Uint8List _gradientEdge(Uint16List buf, int w, int h, double thresh,
    {required bool vertical}) {
  final out = Uint8List(w * h);
  if (vertical) {
    for (var y = 1; y < h - 1; y++) {
      final base = y * w;
      for (var x = 0; x < w; x++) {
        if ((buf[base + w + x] - buf[base - w + x]).abs() > thresh) {
          out[base + x] = 1;
        }
      }
    }
  } else {
    for (var y = 0; y < h; y++) {
      final base = y * w;
      for (var x = 1; x < w - 1; x++) {
        if ((buf[base + x + 1] - buf[base + x - 1]).abs() > thresh) {
          out[base + x] = 1;
        }
      }
    }
  }
  return out;
}

Uint8List _dilateMask(Uint8List edge, int w, int h, int radius,
    {required bool vertical}) {
  final out = Uint8List(w * h);
  if (vertical) {
    for (var x = 0; x < w; x++) {
      var cnt = 0;
      for (var y = 0; y <= radius && y < h; y++) {
        cnt += edge[y * w + x];
      }
      for (var y = 0; y < h; y++) {
        out[y * w + x] = cnt > 0 ? 1 : 0;
        final add = y + radius + 1;
        final del = y - radius;
        if (add < h) cnt += edge[add * w + x];
        if (del >= 0) cnt -= edge[del * w + x];
      }
    }
  } else {
    var rowBase = 0;
    for (var y = 0; y < h; y++, rowBase += w) {
      var cnt = 0;
      for (var x = 0; x <= radius && x < w; x++) {
        cnt += edge[rowBase + x];
      }
      for (var x = 0; x < w; x++) {
        out[rowBase + x] = cnt > 0 ? 1 : 0;
        final add = x + radius + 1;
        final del = x - radius;
        if (add < w) cnt += edge[rowBase + add];
        if (del >= 0) cnt -= edge[rowBase + del];
      }
    }
  }
  return out;
}

Float32List _verticalBoxMean(Uint16List buf, int w, int h, int radius) {
  final out = Float32List(w * h);
  for (var x = 0; x < w; x++) {
    var sum = 0, count = 0;
    for (var y = 0; y <= radius && y < h; y++) {
      sum += buf[y * w + x];
      count++;
    }
    for (var y = 0; y < h; y++) {
      out[y * w + x] = sum / count;
      final add = y + radius + 1;
      final del = y - radius;
      if (add < h) {
        sum += buf[add * w + x];
        count++;
      }
      if (del >= 0) {
        sum -= buf[del * w + x];
        count--;
      }
    }
  }
  return out;
}

Float32List _horizontalBoxMean(Uint16List buf, int w, int h, int radius) {
  final out = Float32List(w * h);
  var rowBase = 0;
  for (var y = 0; y < h; y++, rowBase += w) {
    var sum = 0, count = 0;
    for (var x = 0; x <= radius && x < w; x++) {
      sum += buf[rowBase + x];
      count++;
    }
    for (var x = 0; x < w; x++) {
      out[rowBase + x] = sum / count;
      final add = x + radius + 1;
      final del = x - radius;
      if (add < w) {
        sum += buf[rowBase + add];
        count++;
      }
      if (del >= 0) {
        sum -= buf[rowBase + del];
        count--;
      }
    }
  }
  return out;
}

int _medianOf(List<int> vals) {
  if (vals.isEmpty) return 0;
  vals.sort();
  return vals[vals.length ~/ 2];
}

/// 逐字复制 applyFpn，rowCorrs/colCorrs 导出校正量。
Uint16List fpnRef(Uint16List buf,
    {required int width,
    required int height,
    bool row = true,
    bool col = true,
    double maxCorr = 64,
    int radius = 8,
    List<int>? rowCorrs,
    List<int>? colCorrs}) {
  double clampCorr(num c) =>
      c < -maxCorr ? -maxCorr : (c > maxCorr ? maxCorr : c).toDouble();
  final edgeThresh = 2 * maxCorr;
  final res = <int>[];
  if (row) {
    final low = _verticalBoxMean(buf, width, height, radius);
    final mask = _dilateMask(
        _gradientEdge(buf, width, height, edgeThresh, vertical: true),
        width, height, radius,
        vertical: true);
    for (var y = 0; y < height; y++) {
      res.clear();
      final base = y * width;
      for (var x = 0; x < width; x++) {
        if (mask[base + x] != 0) continue;
        res.add(buf[base + x] - low[base + x].round());
      }
      final corr = clampCorr(_medianOf(res));
      rowCorrs?.add(corr.round());
      if (corr == 0) continue;
      for (var x = 0; x < width; x++) {
        final i = base + x;
        final v = buf[i] - corr;
        buf[i] = v <= 0 ? 0 : v.round();
      }
    }
  }
  if (col) {
    final low = _horizontalBoxMean(buf, width, height, radius);
    final mask = _dilateMask(
        _gradientEdge(buf, width, height, edgeThresh, vertical: false),
        width, height, radius,
        vertical: false);
    for (var x = 0; x < width; x++) {
      res.clear();
      for (var y = 0; y < height; y++) {
        if (mask[y * width + x] != 0) continue;
        res.add(buf[y * width + x] - low[y * width + x].round());
      }
      final corr = clampCorr(_medianOf(res));
      colCorrs?.add(corr.round());
      if (corr == 0) continue;
      for (var y = 0; y < height; y++) {
        final i = y * width + x;
        final v = buf[i] - corr;
        buf[i] = v <= 0 ? 0 : v.round();
      }
    }
  }
  return buf;
}

Future<void> debug() async {
  final gpu = (await GpuPipeline.tryCreate())!;
  final frame0 = await decodeRawSourceFrame('cis_bayer_rggb', {
    'filePath': 'IspFlow/BayerRGGB/RAW_1920x1080_10bits_RGGB_Linear_1frame.raw',
    'width': 1920,
    'height': 1080,
    'bitDepth': '10',
    'packing': 'unpacked_lsb',
    'bayerPattern': 'RGGB',
    'littleEndian': true,
    'frameIndex': 0,
  }, 0);
  final w = frame0.width, h = frame0.height;
  // 链状态：black_level(全0,无操作) → dpc。
  applyDpc(frame0.data,
      width: w, height: h,
      pattern: BayerPattern.rggb, threshold: 5.0, mode: 'median',
      maxValue: frame0.maxValue);

  // CPU 参考（导出 corr）。
  final rowCorrs = <int>[];
  final colCorrs = <int>[];
  final cpuFrame = fpnRef(Uint16List.fromList(frame0.data),
      width: w, height: h, maxCorr: 64, rowCorrs: rowCorrs, colCorrs: colCorrs);

  // GPU 路径（runner 逻辑）。
  var tex = await GpuPipeline.uploadPacked(frame0.data, w, h, 1);
  final gpuRowCorrs = <int>[];
  final gpuColCorrs = <int>[];
  for (var axis = 0; axis < 2; axis++) {
    final statsTex = GpuPipeline.runPass(gpu.progForTest('fpn_stats'), [
      (w / 2).toDouble(), h.toDouble(), w.toDouble(), h.toDouble(),
      axis.toDouble(), 128.0,
    ], [tex], w ~/ 2, h);
    final packed =
        (await GpuPipeline.readbackBytes(statsTex)).buffer.asUint16List();
    statsTex.dispose();
    final lines = axis == 0 ? h : w;
    final lineLen = axis == 0 ? w : h;
    final corr = Uint16List(lines);
    final res = <int>[];
    for (var ln = 0; ln < lines; ln++) {
      res.clear();
      for (var t = 0; t < lineLen; t++) {
        final pv = axis == 0 ? packed[ln * w + t] : packed[t * w + ln];
        if (pv & 1 != 0) continue;
        res.add((pv & ~1) - 32768);
      }
      if (res.isEmpty) {
        corr[ln] = 32768;
        (axis == 0 ? gpuRowCorrs : gpuColCorrs).add(0);
        continue;
      }
      res.sort();
      var c = res[res.length ~/ 2];
      if (c < -64) c = -64;
      if (c > 64) c = 64;
      corr[ln] = (c + 32768).clamp(0, 65535);
      (axis == 0 ? gpuRowCorrs : gpuColCorrs).add(c);
    }
    final corrTex = await GpuPipeline.uploadPacked(corr, lines, 1, 1);
    final out = GpuPipeline.runPass(gpu.progForTest('fpn_apply'), [
      (w / 2).toDouble(), h.toDouble(), w.toDouble(), axis.toDouble(),
      (lines / 2).toDouble(), 1.0,
    ], [tex, corrTex], w ~/ 2, h);
    corrTex.dispose();
    tex.dispose();
    tex = out;
  }
  final gpuBytes = await GpuPipeline.readbackBytes(tex);
  final gpuFrame = gpuBytes.buffer.asUint16List();

  // 对比 corr。
  var rowDiff = 0, colDiff = 0;
  for (var i = 0; i < h; i++) {
    if (rowCorrs[i] != gpuRowCorrs[i]) {
      if (rowDiff < 10) {
        print('FPN rowCorr[$i]: CPU=${rowCorrs[i]} GPU=${gpuRowCorrs[i]}');
      }
      rowDiff++;
    }
  }
  for (var i = 0; i < w; i++) {
    if (colCorrs[i] != gpuColCorrs[i]) {
      if (colDiff < 10) {
        print('FPN colCorr[$i]: CPU=${colCorrs[i]} GPU=${gpuColCorrs[i]}');
      }
      colDiff++;
    }
  }
  print('FPN corr 差异: 行 $rowDiff/$h, 列 $colDiff/$w');
  // 对比最终帧。
  var maxDiff = 0, over2 = 0;
  for (var i = 0; i < gpuFrame.length; i++) {
    final d = (gpuFrame[i] - cpuFrame[i]).abs();
    if (d > maxDiff) maxDiff = d;
    if (d > 2) over2++;
  }
  print('FPN 帧对比: maxDiff=$maxDiff over2=$over2/${gpuFrame.length}');
  tex.dispose();
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(
      home: Scaffold(body: Center(child: Text('fpn debug')))));
  SchedulerBinding.instance.addPostFrameCallback((_) async {
    try {
      await debug();
    } catch (e, st) {
      print('FPN_ERROR $e\n$st');
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    exit(0);
  });
}
