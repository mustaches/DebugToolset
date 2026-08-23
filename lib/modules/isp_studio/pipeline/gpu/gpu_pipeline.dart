/// GPU 链执行器：把 CPU 流水线（pipeline_runner.dart）中已编译的算子链
/// 搬到 GPU 上执行——帧数据以「16 位打包纹理」（uint16 小端字节流原样
/// 视为 RGBA8888 纹理，每纹素装 2 个 16 位值）驻留 GPU，每个算子一个
/// FragmentShader 全屏 pass，节点间零回读；仅源头上传一次，汇点（显示
/// 图 / 仪器馈源 / AHE 统计 / 调试采样）才回读。
///
/// 限制（与 CPU 路径的差异）：
/// - 只能在 UI isolate 使用（依赖 dart:ui）；播放路径的 worker isolate
///   仍走 CPU。
/// - 中间运算为 float32（CPU 为 double / 64 位定点），结果可能有
///   ±1 LSB 差；14bit 源数据本身在 float32 中精确无损。
/// - 仅支持 [supportedOps] 中的算子与特定连接形态（见
///   [GpuPipeline.isSupportedChain]）；不支持时调用方回退 CPU 路径。
///
/// 逐节点耗时为 UI isolate 侧墙钟时间（含 pass 提交与采样回读同步），
/// 与 CPU 路径的 isolate 内耗时口径不同，仅用于节点卡片展示。
library;

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../isp_kernels.dart';
import '../pipeline_runner.dart';

/// GPU 链执行结果。
class GpuChainResult {
  /// 主汇点显示图（链末色调映射，RGBA8，GPU 驻留）。
  final ui.Image image;
  final int width;
  final int height;

  /// nodeId → 执行耗时（微秒）。
  final Map<String, int> timingsUs;

  /// nodeId → 调试变量表采样（'format'/'length'/'width'/'height'/'sample'），
  /// 与 CPU 路径 runChainFrameWithProgress 的 captures 同构。
  final Map<String, Map<String, Object?>> captures;

  /// displayCaptures 各 key 的显示图（前缀覆盖捕获的其它预览节点）。
  final Map<String, ui.Image> displayImages;

  /// rgbaReadbackPorts 各端口（'nodeId:port'）的色调映射 RGBA8 回读，
  /// 供仪器（直方图等）馈源。
  final Map<String, Uint8List> portRgba;

  GpuChainResult({
    required this.image,
    required this.width,
    required this.height,
    required this.timingsUs,
    required this.captures,
    required this.displayImages,
    required this.portRgba,
  });
}

/// 端口数据引用：[tex] 为打包纹理；[channel] 非空表示该端口是
/// 三通道纹理的单个通道（分路器 out_u/out_v 的情形，零拷贝引用）。
final class _Port {
  ui.Image tex;
  final int texW, texH;
  final String format; // 'mosaic'|'mono'|'rgb'|'yuv'|'hsl'
  final int? channel;
  _Port(this.tex, this.texW, this.texH, this.format, [this.channel]);
}

/// GPU 链执行器。经 [tryCreate] 获取（全部 shader 加载成功才可用）。
class GpuPipeline {
  final Map<String, ui.FragmentProgram> _progs;

  GpuPipeline._(this._progs);

  /// 有 GPU shader 实现的算子。
  static const supportedOps = {
    'black_level',
    'grgb_balance',
    'demosaic',
    'white_balance',
    'csc_rgb2hsl',
    'csc_rgb2yuv',
    'csc_yuv2hsl',
    'csc_hsl2rgb',
    'hsl_debugger',
    'csc_hsl2yuv',
    'yuv_splitter',
    'ahe',
    'yuv_combiner',
    'csc_yuv2rgb',
    'gamma',
    'preview',
    'histogram',
    'dpc',
    'fpn',
    'lsc',
    'bayer_dnr',
    'highlight',
    'ccm',
    'rgb_dnr',
    'sharpen',
  };

  static const _shaderAssets = {
    'black_level': 'shaders/isp/isp_black_level.frag',
    'grgb_balance': 'shaders/isp/isp_grgb_balance.frag',
    'demosaic': 'shaders/isp/isp_demosaic_bilinear.frag',
    'apply_gains': 'shaders/isp/isp_apply_gains.frag',
    'rgb2hsl': 'shaders/isp/isp_rgb2hsl.frag',
    'hsl_adjust': 'shaders/isp/isp_hsl_adjust.frag',
    'hsl2yuv': 'shaders/isp/isp_hsl2yuv.frag',
    'extract_channel': 'shaders/isp/isp_extract_channel.frag',
    'clahe_apply': 'shaders/isp/isp_clahe_apply.frag',
    'combine_yuv': 'shaders/isp/isp_combine_yuv.frag',
    'yuv2rgb': 'shaders/isp/isp_yuv2rgb.frag',
    'tonemap': 'shaders/isp/isp_tonemap.frag',
    'passthrough': 'shaders/isp/isp_passthrough.frag',
    'dpc': 'shaders/isp/isp_dpc.frag',
    'bayer_dnr': 'shaders/isp/isp_bayer_dnr.frag',
    'highlight': 'shaders/isp/isp_highlight.frag',
    'lsc': 'shaders/isp/isp_lsc.frag',
    'ccm': 'shaders/isp/isp_ccm.frag',
    'rgb2yuv': 'shaders/isp/isp_rgb2yuv.frag',
    'rgb_dnr_luma': 'shaders/isp/isp_rgb_dnr_luma.frag',
    'rgb_dnr_chroma': 'shaders/isp/isp_rgb_dnr_chroma.frag',
    'luma_extract': 'shaders/isp/isp_luma_extract.frag',
    'sharpen_apply': 'shaders/isp/isp_sharpen_apply.frag',
    'yuv2hsl': 'shaders/isp/isp_yuv2hsl.frag',
    'hsl2rgb': 'shaders/isp/isp_hsl2rgb.frag',
  };

  /// 加载全部 shader；任一失败返回 null（调用方回退 CPU 路径）。
  static Future<GpuPipeline?> tryCreate() async {
    try {
      final progs = <String, ui.FragmentProgram>{};
      for (final e in _shaderAssets.entries) {
        progs[e.key] = await ui.FragmentProgram.fromAsset(e.value);
      }
      return GpuPipeline._(progs);
    } catch (e) {
      // ignore: avoid_print
      print('[GpuPipeline] shader 加载失败: $e');
      return null;
    }
  }

  /// 按名取 shader 程序（供逐算子对比测试使用）。
  ui.FragmentProgram progForTest(String name) => _progs[name]!;

  static double _num(Map<String, Object?> p, String key) =>
      (p[key] as num?)?.toDouble() ?? 0.0;

  static String _str(Map<String, Object?> p, String key) =>
      p[key]?.toString() ?? '';

  /// 链是否可被 GPU 路径完整执行（仅为快速预判；运行期遇到未预料的
  /// 形态仍会抛异常，由调用方回退 CPU）。
  static bool isSupportedChain(List<Map<String, Object?>> chain) {
    if (chain.length < 2) return false;
    // 源：仅 Bayer RAW 源（bayer_source / cis_bayer_rggb），宽高为偶数。
    final first = chain.first;
    final ft = first['typeId'] as String;
    if (ft != 'bayer_source' && ft != 'cis_bayer_rggb') return false;
    final sp = (first['params'] as Map?)?.cast<String, Object?>() ?? const {};
    final w = (sp['width'] as num?)?.toInt() ?? 0;
    final h = (sp['height'] as num?)?.toInt() ?? 0;
    if (w < 4 || h < 4 || w.isOdd || h.isOdd) return false;

    final byId = {for (final op in chain) op['nodeId'] as String: op};
    var seenGamma = false;
    for (var i = 1; i < chain.length; i++) {
      final op = chain[i];
      final typeId = op['typeId'] as String;
      if (!supportedOps.contains(typeId)) return false;
      final isLast = i == chain.length - 1;
      switch (typeId) {
        case 'preview':
        case 'histogram':
          // 汇点仅允许在链末。
          if (!isLast) return false;
        case 'gamma':
          // gamma 之后只允许汇点（CPU 语义下 gamma 后的算子不影响出图，
          // GPU 路径不模拟该角落行为）。
          if (seenGamma) return false;
          seenGamma = true;
        default:
          if (seenGamma) return false;
      }
      final p = (op['params'] as Map?)?.cast<String, Object?>() ?? const {};
      switch (typeId) {
        case 'demosaic':
          final algo = _str(p, 'algorithm');
          if (algo.isNotEmpty && algo != 'bilinear') return false;
        case 'dpc':
          // 仅支持 median 模式（directional 模式回退 CPU）。
          final mode = _str(p, 'mode');
          if (mode.isNotEmpty && mode != 'median') return false;
        case 'ahe':
          // 仅支持 in_mono 支路（Y 通道 CLAHE）；RGB 主帧 CLAHE 暂不支持。
          final inputs = op['inputs'] as Map<String, Object?>?;
          if (inputs?['in_mono'] == null) return false;
        case 'yuv_splitter':
        case 'yuv_combiner':
          // 连接形态在运行期校验（分路器 out_u/out_v 必须直连合路器）。
          break;
      }
      // 合路器的 U/V 必须来自分路器（或留空）。
      if (typeId == 'yuv_combiner') {
        final inputs = op['inputs'] as Map<String, Object?>?;
        for (final port in ['in_u', 'in_v']) {
          final conn = inputs?[port] as Map<String, Object?>?;
          if (conn == null) continue;
          final from = byId[conn['fromNodeId']];
          if (from == null ||
              from['typeId'] != 'yuv_splitter' ||
              (conn['fromPort'] != 'out_u' && conn['fromPort'] != 'out_v')) {
            return false;
          }
        }
      }
    }
    return true;
  }

  // ------------------------------------------------------------------
  // 低层 GPU 原语（public 供测试逐算子对比复用）
  // ------------------------------------------------------------------

  /// 把 16 位帧（交织 [channels] 通道）零拷贝上传为打包纹理。
  static Future<ui.Image> uploadPacked(
      Uint16List data, int width, int height, int channels) {
    final texW = width * channels ~/ 2;
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(data.buffer.asUint8List(), texW, height,
        ui.PixelFormat.rgba8888, completer.complete);
    return completer.future;
  }

  /// 全屏 pass：绑定 float uniform（按声明顺序）与 sampler，离屏渲染
  /// 到 [outW]×[outH] 纹理并返回（GPU 驻留）。
  static ui.Image runPass(ui.FragmentProgram prog, List<double> uniforms,
      List<ui.Image> samplers, int outW, int outH) {
    final shader = prog.fragmentShader();
    for (var i = 0; i < uniforms.length; i++) {
      shader.setFloat(i, uniforms[i]);
    }
    for (var i = 0; i < samplers.length; i++) {
      shader.setImageSampler(i, samplers[i]);
    }
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawRect(
        ui.Rect.fromLTWH(0, 0, outW.toDouble(), outH.toDouble()),
        ui.Paint()..shader = shader);
    final picture = recorder.endRecording();
    final img = picture.toImageSync(outW, outH);
    picture.dispose();
    return img;
  }

  /// 回读纹理字节（RGBA8 → 原字节流）。
  static Future<Uint8List> readbackBytes(ui.Image img) async {
    final bd = await img.toByteData();
    return bd!.buffer.asUint8List();
  }

  // ------------------------------------------------------------------
  // 链执行
  // ------------------------------------------------------------------

  /// 在 UI isolate 执行一帧。
  ///
  /// [displayCaptures]：key → 节点 id，处理到该节点时对其输出帧做默认
  /// 色调映射（gamma 2.2）出图，供「链是主链前缀」的其它预览节点复用。
  /// [rgbaReadbackPorts]：'nodeId:port' 集合，对这些端口做默认色调映射
  /// 并回读 RGBA8（仪器馈源）。
  Future<GpuChainResult> run(
    List<Map<String, Object?>> chain,
    int frameIndex, {
    void Function(String nodeId)? onNodeStart,
    Map<String, String> displayCaptures = const {},
    Set<String> rgbaReadbackPorts = const {},
  }) async {
    final timings = <String, int>{};
    final captures = <String, Map<String, Object?>>{};
    final displayImages = <String, ui.Image>{};
    final portRgba = <String, Uint8List>{};

    // ---- 源节点：CPU 解码（与链内语义一致）→ 上传打包纹理 ----
    final first = chain.first;
    final firstNodeId = first['nodeId'] as String;
    final sp = (first['params'] as Map).cast<String, Object?>();
    onNodeStart?.call(firstNodeId);
    var sw = Stopwatch()..start();
    final src = await decodeRawSourceFrame(
        first['typeId'] as String, sp, frameIndex);
    final w = src.width, h = src.height, maxValue = src.maxValue;
    if (w.isOdd || h.isOdd) {
      throw StateError('GPU 路径要求偶数宽高（当前 $w x $h）');
    }
    final srcFormat = src.format; // 'mosaic' | 'mono'
    final srcTex = await uploadPacked(src.data, w, h, 1);
    timings[firstNodeId] = sw.elapsedMicroseconds;

    // Bayer 相位颜色（0=R,1=G,2=B），供黑电平/GrGb/去马赛克。
    final pattern = src.bayerPattern;
    final pc = pattern == null
        ? const [0, 1, 1, 2]
        : [for (var ph = 0; ph < 4; ph++) pattern.colorAt(ph & 1, ph >> 1)];

    // 主帧（链上流动的帧）与端口表。
    _Port frame = _Port(srcTex, w ~/ 2, h, srcFormat);
    final ports = <String, _Port>{'$firstNodeId:out': frame};

    // 捕获点反查：节点 id → displayCaptures 的 key 列表。
    final captureAtNode = <String, List<String>>{};
    displayCaptures.forEach((key, nodeId) {
      captureAtNode.putIfAbsent(nodeId, () => []).add(key);
    });

    ui.Image? display; // gamma 节点或链末色调映射产生的显示图
    // 算子内部产生的临时纹理（非链上帧，如 rgb_dnr 的 YUV 中间产物）：
    // pass 光栅化是异步的，不能用完即 dispose，统一在末端回收。
    final transients = <ui.Image>[];

    Future<void> captureDisplays(String nodeId) async {
      final keys = captureAtNode[nodeId];
      if (keys == null) return;
      for (final key in keys) {
        displayImages[key] = _tonemap(frame, w, h, maxValue, 2.2, 0, 1.0);
      }
    }

    await captureDisplays(firstNodeId); // 源节点输出处的捕获（如 RAW 直显预览）

    // 逐算子执行。
    for (var i = 1; i < chain.length; i++) {
      final op = chain[i];
      final typeId = op['typeId'] as String;
      final nodeId = op['nodeId'] as String;
      final p = (op['params'] as Map?)?.cast<String, Object?>() ?? const {};
      final inputs = (op['inputs'] as Map?)?.cast<String, Object?>() ?? const {};
      onNodeStart?.call(nodeId);
      sw = Stopwatch()..start();

      _Port port(String name) {
        final conn = inputs[name] as Map<String, Object?>?;
        final ref = conn == null
            ? null
            : ports['${conn['fromNodeId']}:${conn['fromPort']}'];
        if (conn != null && ref == null) {
          throw StateError('GPU 路径：端口数据缺失 $name ← $conn');
        }
        return ref!;
      }

      // Bypass（Process 类节点的直通开关）：主帧原样下传；in_mono 支路
      // 数据直通 out_mono。
      if (p['bypass'] == true) {
        ports['$nodeId:out'] = frame;
        if (frame.format == 'mono') ports['$nodeId:out_mono'] = frame;
        if (inputs['in_mono'] != null) {
          ports['$nodeId:out_mono'] = port('in_mono');
        }
        await captureDisplays(nodeId);
        captures[nodeId] =
            await _sampleCapture(frame, display, w, h, maxValue);
        timings[nodeId] = sw.elapsedMicroseconds;
        continue;
      }
      switch (typeId) {
        case 'black_level':
          final isMono = frame.format == 'mono';
          double off0 = _num(p, 'r'), off1 = off0, off2 = off0, off3 = off0;
          if (!isMono) {
            // 与 applyBlackLevel 一致：按相位颜色解析四个偏移。
            final offs = List<double>.filled(4, 0);
            for (var ph = 0; ph < 4; ph++) {
              final color = pc[ph];
              if (color == 0) {
                offs[ph] = _num(p, 'r');
              } else if (color == 2) {
                offs[ph] = _num(p, 'b');
              } else {
                offs[ph] = pc[ph ^ 1] == 0 ? _num(p, 'gr') : _num(p, 'gb');
              }
            }
            off0 = offs[0];
            off1 = offs[1];
            off2 = offs[2];
            off3 = offs[3];
          }
          if (off0 == 0 && off1 == 0 && off2 == 0 && off3 == 0) {
            ports['$nodeId:out'] = frame; // 直通
            break;
          }
          frame = _Port(
            runPass(_progs['black_level']!, [
              frame.texW.toDouble(), frame.texH.toDouble(), w.toDouble(),
              isMono ? 1.0 : 0.0, off0, off1, off2, off3,
            ], [frame.tex], frame.texW, frame.texH),
            frame.texW, frame.texH, frame.format);
          ports['$nodeId:out'] = frame;
        case 'grgb_balance':
          final strength = _num(p, 'strength');
          if (frame.format != 'mosaic' || strength <= 0) {
            ports['$nodeId:out'] = frame; // mono/关闭直通
            break;
          }
          // 回读当前帧做统计（前序可能有 dpc/fpn 等修改，源数据已不代表
          // 当前帧）；抽样统计与 CPU 全帧统计的增益差在亚 LSB 量级。
          final grgbBytes = await readbackBytes(frame.tex);
          final (gainGr, gainGb) = _grGbGains(
              grgbBytes.buffer.asUint16List(), w, h, pc, strength);
          if (gainGr == 1.0 && gainGb == 1.0) {
            ports['$nodeId:out'] = frame;
            break;
          }
          frame = _Port(
            runPass(_progs['grgb_balance']!, [
              frame.texW.toDouble(), frame.texH.toDouble(), w.toDouble(),
              gainGr, gainGb,
              pc[0].toDouble(), pc[1].toDouble(),
              pc[2].toDouble(), pc[3].toDouble(),
            ], [frame.tex], frame.texW, frame.texH),
            frame.texW, frame.texH, frame.format);
          ports['$nodeId:out'] = frame;
        case 'dpc':
          // median 模式（directional 已在 isSupportedChain 排除）。
          final thr = _num(p, 'threshold') / 100 * maxValue;
          frame = _Port(
            runPass(_progs['dpc']!, [
              frame.texW.toDouble(), frame.texH.toDouble(),
              w.toDouble(), h.toDouble(),
              frame.format == 'mosaic' ? 2.0 : 1.0, thr,
            ], [frame.tex], frame.texW, frame.texH),
            frame.texW, frame.texH, frame.format);
          ports['$nodeId:out'] = frame;
        case 'fpn':
          final doRow = p['row'] != false;
          final doCol = p['col'] != false;
          final maxCorr = _num(p, 'maxCorr');
          if ((!doRow && !doCol) || maxCorr <= 0) {
            ports['$nodeId:out'] = frame; // 直通
            break;
          }
          // CPU 桥接：FPN 的行/列中位数是聚集操作，FragmentShader 无
          // scatter，GPU 化统计实测反而更慢（见
          // scratch/bench_fpn_gpu.dart）；最优是回读一次 → 优化后的
          // CPU applyFpn（quickselect 中位数）→ 重新上传。GPU 队列在
          // 回读处自然排空，计时不再吸收前序 pass。
          {
            final bytes = await readbackBytes(frame.tex);
            final data = bytes.buffer.asUint16List();
            applyFpn(data,
                width: w,
                height: h,
                pattern: frame.format == 'mosaic' ? pattern : null,
                row: doRow,
                col: doCol,
                maxCorr: maxCorr);
            final tex = await uploadPacked(data, w, h, 1);
            frame = _Port(tex, frame.texW, frame.texH, frame.format);
          }
          ports['$nodeId:out'] = frame;
        case 'lsc':
          final strength = _num(p, 'strength');
          if (strength == 0) {
            ports['$nodeId:out'] = frame;
            break;
          }
          final cx = _num(p, 'centerX') * (w - 1);
          final cy = _num(p, 'centerY') * (h - 1);
          final ex = cx > w - 1 - cx ? cx : (w - 1 - cx).toDouble();
          final ey = cy > h - 1 - cy ? cy : (h - 1 - cy).toDouble();
          final rMax2 = ex * ex + ey * ey;
          if (rMax2 <= 0) {
            ports['$nodeId:out'] = frame;
            break;
          }
          frame = _Port(
            runPass(_progs['lsc']!, [
              frame.texW.toDouble(), frame.texH.toDouble(),
              w.toDouble(), h.toDouble(), cx, cy, rMax2, strength,
              maxValue.toDouble(),
            ], [frame.tex], frame.texW, frame.texH),
            frame.texW, frame.texH, frame.format);
          ports['$nodeId:out'] = frame;
        case 'bayer_dnr':
          final strength = _num(p, 'strength');
          if (strength <= 0) {
            ports['$nodeId:out'] = frame;
            break;
          }
          frame = _Port(
            runPass(_progs['bayer_dnr']!, [
              frame.texW.toDouble(), frame.texH.toDouble(),
              w.toDouble(), h.toDouble(),
              frame.format == 'mosaic' ? 2.0 : 1.0, strength,
            ], [frame.tex], frame.texW, frame.texH),
            frame.texW, frame.texH, frame.format);
          ports['$nodeId:out'] = frame;
        case 'highlight':
          final kneePt =
              _num(p, 'knee').clamp(0.0, 1.0) * maxValue.toDouble();
          final mode = _str(p, 'mode');
          frame = _Port(
            runPass(_progs['highlight']!, [
              frame.texW.toDouble(), frame.texH.toDouble(),
              w.toDouble(), h.toDouble(),
              frame.format == 'mosaic' ? 2.0 : 1.0,
              mode == 'clip' ? 1.0 : 0.0, kneePt, maxValue.toDouble(),
            ], [frame.tex], frame.texW, frame.texH),
            frame.texW, frame.texH, frame.format);
          ports['$nodeId:out'] = frame;
        case 'ccm':
          _requireFormat(frame, 'rgb', 'CCM');
          final m = (p['matrix'] as List?)
                  ?.map((e) => (e as num).toDouble())
                  .toList() ??
              const [1.0, 0, 0, 0, 1.0, 0, 0, 0, 1.0];
          if (m.length != 9) throw StateError('CCM 矩阵必须为 9 元素');
          const ident = [1.0, 0, 0, 0, 1.0, 0, 0, 0, 1.0];
          var isIdentity = true;
          for (var i = 0; i < 9; i++) {
            if (m[i] != ident[i]) {
              isIdentity = false;
              break;
            }
          }
          if (!isIdentity) {
            frame = _Port(
              runPass(_progs['ccm']!, [
                frame.texW.toDouble(), frame.texH.toDouble(), w.toDouble(),
                maxValue.toDouble(), ...m,
              ], [frame.tex], frame.texW, frame.texH),
              frame.texW, frame.texH, 'rgb');
          }
          ports['$nodeId:out'] = frame;
        case 'rgb_dnr':
          _requireFormat(frame, 'rgb', 'RGB 降噪');
          final luma = _num(p, 'luma');
          final chroma = _num(p, 'chroma');
          if (luma <= 0 && chroma <= 0) {
            ports['$nodeId:out'] = frame;
            break;
          }
          // rgb→yuv →（亮度保边）→（色度盒式混合）→ yuv→rgb。
          var yuvTex = runPass(_progs['rgb2yuv']!, [
            frame.texW.toDouble(), frame.texH.toDouble(), w.toDouble(),
            maxValue.toDouble(),
            ..._rgb2yuvCscUniforms('bt601', 'full', maxValue),
          ], [frame.tex], frame.texW, frame.texH);
          if (luma > 0) {
            final out = runPass(_progs['rgb_dnr_luma']!, [
              frame.texW.toDouble(), frame.texH.toDouble(),
              w.toDouble(), h.toDouble(), luma, maxValue.toDouble(),
            ], [yuvTex], frame.texW, frame.texH);
            transients.add(yuvTex);
            yuvTex = out;
          }
          if (chroma > 0) {
            final blend = chroma.clamp(0.0, 1.0);
            final out = runPass(_progs['rgb_dnr_chroma']!, [
              frame.texW.toDouble(), frame.texH.toDouble(),
              w.toDouble(), h.toDouble(), blend, maxValue.toDouble(),
            ], [yuvTex], frame.texW, frame.texH);
            transients.add(yuvTex);
            yuvTex = out;
          }
          final rgbTex = runPass(_progs['yuv2rgb']!, [
            frame.texW.toDouble(), frame.texH.toDouble(), w.toDouble(),
            maxValue.toDouble(), (maxValue >> 1).toDouble(),
          ], [yuvTex], frame.texW, frame.texH);
          transients.add(yuvTex);
          frame = _Port(rgbTex, frame.texW, frame.texH, 'rgb');
          ports['$nodeId:out'] = frame;
        case 'sharpen':
          _requireFormat(frame, 'rgb', '锐化');
          final amount = _num(p, 'amount');
          if (amount == 0) {
            ports['$nodeId:out'] = frame;
            break;
          }
          final yTex = runPass(_progs['luma_extract']!, [
            frame.texW.toDouble(), frame.texH.toDouble(), w.toDouble(),
            (w ~/ 2).toDouble(),
          ], [frame.tex], w ~/ 2, h);
          final sharpTex = runPass(_progs['sharpen_apply']!, [
            frame.texW.toDouble(), frame.texH.toDouble(),
            (w ~/ 2).toDouble(), h.toDouble(),
            w.toDouble(), h.toDouble(),
            amount, _num(p, 'threshold'), maxValue.toDouble(),
          ], [frame.tex, yTex], frame.texW, frame.texH);
          transients.add(yTex);
          frame = _Port(sharpTex, frame.texW, frame.texH, 'rgb');
          ports['$nodeId:out'] = frame;
        case 'demosaic':
          if (frame.format != 'mosaic') {
            throw StateError('GPU 路径：去马赛克需要马赛克输入');
          }
          final outTexW = w * 3 ~/ 2;
          frame = _Port(
            runPass(_progs['demosaic']!, [
              frame.texW.toDouble(), frame.texH.toDouble(),
              w.toDouble(), h.toDouble(), outTexW.toDouble(),
              pc[0].toDouble(), pc[1].toDouble(),
              pc[2].toDouble(), pc[3].toDouble(),
            ], [frame.tex], outTexW, h),
            outTexW, h, 'rgb');
          ports['$nodeId:out'] = frame;
        case 'white_balance':
          var rGain = _num(p, 'rGain'), bGain = _num(p, 'bGain');
          if (_str(p, 'mode') == 'auto') {
            // 与 CPU 完全同源的灰度世界统计：回读当前（去马赛克后）RGB
            // 帧，直接调 autoWhiteBalanceGains。GPU 去马赛克与 CPU 逐点
            // 一致（e2e 验证 maxDiff=0），故增益与 CPU 路径严格相同。
            final rgbBytes = await readbackBytes(frame.tex);
            final (r, b) =
                autoWhiteBalanceGains(rgbBytes.buffer.asUint16List());
            rGain = r;
            bGain = b;
          }
          if (rGain <= 0) rGain = 1.0;
          if (bGain <= 0) bGain = 1.0;
          if (rGain == 1.0 && bGain == 1.0) {
            ports['$nodeId:out'] = frame; // 直通
            break;
          }
          frame = _Port(
            runPass(_progs['apply_gains']!, [
              frame.texW.toDouble(), frame.texH.toDouble(), w.toDouble(),
              maxValue.toDouble(), rGain, bGain,
            ], [frame.tex], frame.texW, frame.texH),
            frame.texW, frame.texH, frame.format);
          ports['$nodeId:out'] = frame;
        case 'csc_rgb2yuv':
          _requireFormat(frame, 'rgb', 'RGB→YUV 转换');
          frame = _Port(
            runPass(_progs['rgb2yuv']!, [
              frame.texW.toDouble(), frame.texH.toDouble(), w.toDouble(),
              maxValue.toDouble(),
              ..._rgb2yuvCscUniforms(_str(p, 'standard'), _str(p, 'range'),
                  maxValue),
            ], [frame.tex], frame.texW, frame.texH),
            frame.texW, frame.texH, 'yuv');
          ports['$nodeId:out'] = frame;
        case 'csc_yuv2hsl':
          _requireFormat(frame, 'yuv', 'YUV→HSL 转换');
          frame = _Port(
            runPass(_progs['yuv2hsl']!, [
              frame.texW.toDouble(), frame.texH.toDouble(), w.toDouble(),
              maxValue.toDouble(), (maxValue >> 1).toDouble(),
            ], [frame.tex], frame.texW, frame.texH),
            frame.texW, frame.texH, 'hsl');
          ports['$nodeId:out'] = frame;
        case 'csc_hsl2rgb':
          _requireFormat(frame, 'hsl', 'HSL→RGB 转换');
          frame = _Port(
            runPass(_progs['hsl2rgb']!, [
              frame.texW.toDouble(), frame.texH.toDouble(), w.toDouble(),
              maxValue.toDouble(),
            ], [frame.tex], frame.texW, frame.texH),
            frame.texW, frame.texH, 'rgb');
          ports['$nodeId:out'] = frame;
        case 'csc_rgb2hsl':
          _requireFormat(frame, 'rgb', 'RGB→HSL 转换');
          frame = _Port(
            runPass(_progs['rgb2hsl']!, [
              frame.texW.toDouble(), frame.texH.toDouble(),
              w.toDouble(), maxValue.toDouble(),
            ], [frame.tex], frame.texW, frame.texH),
            frame.texW, frame.texH, 'hsl');
          ports['$nodeId:out'] = frame;
        case 'hsl_debugger':
          _requireFormat(frame, 'hsl', 'HSL调试器');
          final hShift = _num(p, 'h_shift');
          final sGain = (p['s_gain'] as num?)?.toDouble() ?? 1.0;
          final lGain = (p['l_gain'] as num?)?.toDouble() ?? 1.0;
          if (hShift != 0 || sGain != 1.0 || lGain != 1.0) {
            final shift = (hShift / 360 * maxValue).roundToDouble();
            frame = _Port(
              runPass(_progs['hsl_adjust']!, [
                frame.texW.toDouble(), frame.texH.toDouble(), w.toDouble(),
                maxValue.toDouble(), shift, sGain, lGain,
              ], [frame.tex], frame.texW, frame.texH),
              frame.texW, frame.texH, 'hsl');
          }
          ports['$nodeId:out'] = frame;
        case 'csc_hsl2yuv':
          _requireFormat(frame, 'hsl', 'HSL→YUV 转换');
          frame = _Port(
            runPass(_progs['hsl2yuv']!, [
              frame.texW.toDouble(), frame.texH.toDouble(), w.toDouble(),
              maxValue.toDouble(), (maxValue >> 1).toDouble(),
            ], [frame.tex], frame.texW, frame.texH),
            frame.texW, frame.texH, 'yuv');
          ports['$nodeId:out'] = frame;
        case 'yuv_splitter':
          if (frame.format != 'yuv') {
            throw StateError('GPU 路径：YUV 分路器需要 YUV 输入');
          }
          // Y 抽取为独立 mono 纹理（下游 AHE/合路器/仪器取用）；
          // U/V 零拷贝引用主帧纹理（channel 标记）。
          final yTex = runPass(_progs['extract_channel']!, [
            frame.texW.toDouble(), frame.texH.toDouble(), w.toDouble(),
            0.0, (w ~/ 2).toDouble(),
          ], [frame.tex], w ~/ 2, h);
          ports['$nodeId:out_y'] = _Port(yTex, w ~/ 2, h, 'mono');
          ports['$nodeId:out_u'] = _Port(frame.tex, frame.texW, frame.texH, 'yuv', 1);
          ports['$nodeId:out_v'] = _Port(frame.tex, frame.texW, frame.texH, 'yuv', 2);
          ports['$nodeId:out'] = frame;
        case 'ahe':
          final monoIn = inputs['in_mono'] != null ? port('in_mono') : null;
          final strength = _num(p, 'strength');
          var blockSize = (p['blockSize'] as num?)?.toInt() ?? 32;
          if (blockSize < 2) blockSize = 32;
          var clipLimit = _num(p, 'clipLimit');
          if (clipLimit <= 0) clipLimit = 1.0;
          if (monoIn != null) {
            if (monoIn.format != 'mono' || monoIn.channel != null) {
              throw StateError('GPU 路径：AHE 的 in_mono 需要单通道输入');
            }
            if (strength <= 0) {
              ports['$nodeId:out_mono'] = monoIn; // 直通（不拷贝，纹理所见略同）
            } else {
              ports['$nodeId:out_mono'] = await _claheMono(monoIn.tex, w, h,
                  blockSize, clipLimit, strength, maxValue);
            }
            ports['$nodeId:out'] = frame; // 主帧透传
          } else if (frame.format == 'mono') {
            if (strength > 0) {
              frame = await _claheMono(frame.tex, w, h, blockSize, clipLimit,
                  strength, maxValue);
            }
            ports['$nodeId:out'] = frame;
            ports['$nodeId:out_mono'] = frame;
          } else {
            throw StateError('GPU 路径：AHE 仅支持 in_mono 或 mono 主帧');
          }
        case 'yuv_combiner':
          final yIn = inputs['in_y'] != null ? port('in_y') : null;
          final uIn = inputs['in_u'] != null ? port('in_u') : null;
          final vIn = inputs['in_v'] != null ? port('in_v') : null;
          ui.Image? uvTex;
          var uvTexW = 0, uvTexH = 0;
          if (uIn != null && vIn != null) {
            if (!identical(uIn.tex, vIn.tex) ||
                uIn.channel == null ||
                vIn.channel == null) {
              throw StateError('GPU 路径：合路器 U/V 必须同源（分路器直连）');
            }
            uvTex = uIn.tex;
            uvTexW = uIn.texW;
            uvTexH = uIn.texH;
          } else if (uIn != null || vIn != null) {
            throw StateError('GPU 路径：合路器 U/V 需同时连接或同时留空');
          }
          final hasY = yIn != null;
          final hasUv = uvTex != null;
          final outTexW = w * 3 ~/ 2;
          frame = _Port(
            runPass(_progs['combine_yuv']!, [
              (hasY ? yIn.texW : 1).toDouble(),
              (hasY ? yIn.texH : 1).toDouble(),
              uvTexW.toDouble(), uvTexH.toDouble(), w.toDouble(),
              hasY ? 1.0 : 0.0, hasUv ? 1.0 : 0.0,
              (maxValue >> 1).toDouble(), outTexW.toDouble(),
            ], [
              hasY ? yIn.tex : frame.tex, // 占位 sampler（uHasY=0 不采样）
              hasUv ? uvTex : frame.tex,
            ], outTexW, h),
            outTexW, h, 'yuv');
          ports['$nodeId:out'] = frame;
        case 'csc_yuv2rgb':
          _requireFormat(frame, 'yuv', 'YUV→RGB 转换');
          frame = _Port(
            runPass(_progs['yuv2rgb']!, [
              frame.texW.toDouble(), frame.texH.toDouble(), w.toDouble(),
              maxValue.toDouble(), (maxValue >> 1).toDouble(),
            ], [frame.tex], frame.texW, frame.texH),
            frame.texW, frame.texH, 'rgb');
          ports['$nodeId:out'] = frame;
        case 'gamma':
          _requireFormat(frame, 'rgb', 'Gamma');
          final gamma = _num(p, 'gamma') <= 0 ? 2.2 : _num(p, 'gamma');
          final contrast = _num(p, 'contrast') <= 0 ? 1.0 : _num(p, 'contrast');
          display = _tonemap(
              frame, w, h, maxValue, gamma, _num(p, 'brightness'), contrast);
          ports['$nodeId:out'] = frame; // 主帧不变（CPU 同）
        case 'preview':
        case 'histogram':
          // 汇点：主帧透传，链末统一出图。mono 仪器端口登记引用。
          final monoIn =
              inputs['in_mono'] != null ? ports['${(inputs['in_mono'] as Map)['fromNodeId']}:${(inputs['in_mono'] as Map)['fromPort']}'] : null;
          if (monoIn != null) ports['$nodeId:out_mono'] = monoIn;
          ports['$nodeId:out'] = frame;
        default:
          throw StateError('GPU 路径不支持的节点: $typeId');
      }

      // 该节点输出处的显示捕获（前缀覆盖的其它预览节点）。
      await captureDisplays(nodeId);
      // 调试变量表采样（微回读，同时充当逐节点 GPU 同步点）。
      captures[nodeId] = await _sampleCapture(frame, display, w, h, maxValue);
      timings[nodeId] = sw.elapsedMicroseconds;
    }

    // ---- 链末出图：gamma 已出图则用之，否则默认色调映射（RAW 源 gamma 2.2）----
    sw = Stopwatch()..start();
    display ??= _tonemap(frame, w, h, maxValue, 2.2, 0, 1.0);
    final sinkNodeId = chain.last['nodeId'] as String;
    timings[sinkNodeId] = (timings[sinkNodeId] ?? 0) + sw.elapsedMicroseconds;
    captures[sinkNodeId] = await _sampleCapture(frame, display, w, h, maxValue);

    // ---- 仪器馈源端口回读（默认色调映射 RGBA8）----
    for (final key in rgbaReadbackPorts) {
      final ref = ports[key];
      if (ref == null) continue;
      var mono = ref;
      if (ref.channel != null) {
        // 三通道纹理的单通道端口：先抽取。
        final ex = runPass(_progs['extract_channel']!, [
          ref.texW.toDouble(), ref.texH.toDouble(), w.toDouble(),
          ref.channel!.toDouble(), (w ~/ 2).toDouble(),
        ], [ref.tex], w ~/ 2, h);
        mono = _Port(ex, w ~/ 2, h, 'mono');
      }
      final img = _tonemap(mono, w, h, maxValue, 2.2, 0, 1.0);
      portRgba[key] = await readbackBytes(img);
      img.dispose();
      if (!identical(mono.tex, ref.tex)) mono.tex.dispose();
    }

    // 纹理回收（显示图交给调用方，不在此 dispose）。
    final disposed = <ui.Image>{};
    for (final ref in ports.values) {
      if (disposed.add(ref.tex)) ref.tex.dispose();
    }
    if (disposed.add(frame.tex)) frame.tex.dispose();
    if (disposed.add(srcTex)) srcTex.dispose();
    for (final t in transients) {
      if (disposed.add(t)) t.dispose();
    }

    return GpuChainResult(
      image: display,
      width: w,
      height: h,
      timingsUs: timings,
      captures: captures,
      displayImages: displayImages,
      portRgba: portRgba,
    );
  }

  static void _requireFormat(_Port frame, String format, String opName) {
    if (frame.format != format) {
      throw StateError('GPU 路径：$opName需要 $format 输入（当前 ${frame.format}）');
    }
  }

  /// csc_rgb2yuv 的浮点系数 uniforms（uHalf 起，与 convertRgbToYuvCsc
  /// 的 16 位定点系数同源：系数/65536）。
  static List<double> _rgb2yuvCscUniforms(
      String standard, String range, int maxValue) {
    const q = 1.0 / 65536;
    var cyR = 19595 * q, cyG = 38470 * q, cyB = 7471 * q;
    var cuR = -11058 * q, cuG = -21710 * q, cvG = -27439 * q, cvB = -5329 * q;
    if (standard == 'bt709') {
      cyR = 13933 * q;
      cyG = 46871 * q;
      cyB = 4732 * q;
      cuR = -7509 * q;
      cuG = -25260 * q;
      cvG = -29759 * q;
      cvB = -3009 * q;
    }
    final offY = ((maxValue * 16 + 127) ~/ 255).toDouble();
    return [
      (maxValue >> 1).toDouble(),
      cyR, cyG, cyB, cuR, cuG, cvG, cvB,
      offY, range == 'limited' ? 1.0 : 0.0,
    ];
  }

  /// 色调映射出图 pass（RGBA8，w×h，可直接作为预览 ui.Image）。
  ui.Image _tonemap(_Port frame, int w, int h, int maxValue, double gamma,
      double brightness, double contrast) {
    final format = switch (frame.format) {
      'rgb' => 0.0,
      'mono' || 'mosaic' => 1.0,
      'yuv' => 2.0,
      'hsl' => 3.0,
      _ => throw StateError('GPU 路径：未知格式 ${frame.format}'),
    };
    return runPass(_progs['tonemap']!, [
      frame.texW.toDouble(), frame.texH.toDouble(), w.toDouble(),
      maxValue.toDouble(), format, 1.0 / gamma, brightness, contrast,
      (maxValue >> 1).toDouble(),
    ], [frame.tex], w, h);
  }

  /// 单通道 CLAHE：回读 mono（CPU 算 tile 直方图/CDF）→ LUT 打包上传 →
  /// GPU 逐像素双线性插值。返回新的 mono 端口。
  Future<_Port> _claheMono(ui.Image monoTex, int w, int h, int blockSize,
      double clipLimit, double strength, int maxValue) async {
    final bytes = await readbackBytes(monoTex);
    final ys = bytes.buffer.asUint16List();
    final tilesX = (w + blockSize - 1) ~/ blockSize;
    final tilesY = (h + blockSize - 1) ~/ blockSize;
    final luts = claheTileLuts(ys, w, h, blockSize, clipLimit, maxValue);
    // LUT（double, 0..maxValue）量化为 16 位打包上传：线性下标
    // tileLinear*256+bin，纹理按 1024 纹素宽平铺（尾部补零到整行）。
    const lutTexW = 1024;
    final lutCount = tilesX * tilesY * 256;
    final lutTexH = (lutCount ~/ 2 + lutTexW - 1) ~/ lutTexW;
    final lut16 = Uint16List(lutTexH * lutTexW * 2);
    for (var i = 0; i < lutCount; i++) {
      final v = luts[i].round();
      lut16[i] = v < 0 ? 0 : (v > 65535 ? 65535 : v);
    }
    final lutTex = await uploadPacked(lut16, lutTexW * 2, lutTexH, 1);
    final out = runPass(_progs['clahe_apply']!, [
      (w ~/ 2).toDouble(), h.toDouble(), w.toDouble(), h.toDouble(),
      blockSize.toDouble(), tilesX.toDouble(), tilesY.toDouble(),
      strength, maxValue.toDouble(),
      lutTexW.toDouble(), lutTexH.toDouble(),
    ], [monoTex, lutTex], w ~/ 2, h);
    lutTex.dispose();
    return _Port(out, w ~/ 2, h, 'mono');
  }

  /// 调试变量表采样：微回读前 256 个值（512 字节 = 128 纹素的一条 1px
  /// 横带；gamma 之后的 RGBA 为 256 字节）。与 CPU captures 同构。
  Future<Map<String, Object?>> _sampleCapture(_Port frame, ui.Image? display,
      int w, int h, int maxValue) async {
    if (display != null) {
      // gamma 已出图：节点输出视为 RGBA。
      final band = runPass(_progs['passthrough']!,
          [w.toDouble(), h.toDouble()], [display], 64, 1);
      final bytes = await readbackBytes(band);
      band.dispose();
      return {
        'format': 'rgba',
        'length': w * h * 4,
        'width': w,
        'height': h,
        'sample': List<int>.of(bytes.sublist(0, 256)),
      };
    }
    final channels = frame.format == 'mono' || frame.format == 'mosaic' ? 1 : 3;
    final total = w * h * channels;
    final values = total < 256 ? total : 256;
    final band = runPass(_progs['passthrough']!,
        [frame.texW.toDouble(), frame.texH.toDouble()], [frame.tex],
        values ~/ 2, 1);
    final bytes = await readbackBytes(band);
    band.dispose();
    final sample = bytes.buffer.asUint16List().sublist(0, values);
    return {
      'format': frame.format,
      'length': total,
      'width': w,
      'height': h,
      'sample': List<int>.of(sample),
    };
  }

  /// Gr/Gb 增益统计（CPU 侧，对当前帧按绿相位抽 1/8 样）：与
  /// applyGrGbBalance 的全帧双均值逻辑统计等效（增益差亚 LSB）。
  static (double, double) _grGbGains(
      Uint16List src, int w, int h, List<int> pc, double strength) {
    var sumGr = 0, cntGr = 0, sumGb = 0, cntGb = 0;
    // 逐相位抽样：绿相位行 step 2、列 step 4（1/8 密度，两绿相位全覆盖）。
    for (var ph = 0; ph < 4; ph++) {
      if (pc[ph] != 1) continue;
      final isGr = pc[ph ^ 1] == 0;
      final px = ph & 1, py = ph >> 1;
      for (var y = py; y < h; y += 2) {
        var i = y * w + px;
        for (var x = px; x < w; x += 4, i += 4) {
          if (isGr) {
            sumGr += src[i];
            cntGr++;
          } else {
            sumGb += src[i];
            cntGb++;
          }
        }
      }
    }
    if (cntGr == 0 || cntGb == 0) return (1.0, 1.0);
    final meanGr = sumGr / cntGr, meanGb = sumGb / cntGb;
    if (meanGr <= 0 || meanGb <= 0) return (1.0, 1.0);
    final target = (meanGr + meanGb) / 2;
    return (
      1 + (target / meanGr - 1) * strength,
      1 + (target / meanGb - 1) * strength
    );
  }
}
