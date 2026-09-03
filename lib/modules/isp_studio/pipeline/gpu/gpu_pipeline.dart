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

import '../image_source.dart';
import '../isp_kernels.dart';
import '../levels_curve.dart';
import '../pipeline_runner.dart';
import '../video_source.dart';

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

/// 端口数据引用：[tex] 为打包纹理。
final class _Port {
  ui.Image tex;
  final int texW, texH;
  final String format; // 'mosaic'|'mono'|'rgb'|'yuv'|'hsl'
  _Port(this.tex, this.texW, this.texH, this.format);
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
    'rgb_debugger',
    'color_temp_adjuster',
    'yuv_debugger',
    'csc_hsl2yuv',
    'yuv_splitter',
    'ahe',
    'yuv_combiner',
    'hsl_splitter',
    'hsl_combiner',
    'rgb_splitter',
    'rgb_combiner',
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
    'edge_extract',
    'morphology',
    'gaussian_blur',
    'multiplier',
    'adder',
    'mux4',
    'blender',
    'bright_contrast_adjuster',
    'levels_curves',
    'fluoro_leak',
    'fluoro_background',
    'fluoro_normalize',
    'fluoro_temporal',
    'pseudo_color',
    'fluoro_fusion',
  };

  /// 时域降噪的历史帧纹理（nodeId → 记录）：跨 run() 存活，有效性口径
  /// 与 CPU 路径 pipeline_runner._temporalHistory 一致（帧序连续 +
  /// 尺寸/参数不变才复用）。
  final Map<
      String,
      ({
        ui.Image tex,
        int frame,
        int w,
        int h,
        double alpha,
        bool motion
      })> _temporalHistory = {};

  /// 视频格式输入组端口名（与 CPU 路径 pipeline_runner 一致）：
  /// 分支感知取帧时按此顺序找第一个已连接的视频组输入。
  static const _kVideoInputPorts = ['in', 'in_yuv', 'in_hsl', 'in_mono', 'in_raw'];

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
    'combine_3ch': 'shaders/isp/isp_combine_3ch.frag',
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
    'yuv_gains': 'shaders/isp/isp_yuv_gains.frag',
    'edge_extract': 'shaders/isp/isp_edge_extract.frag',
    'morphology': 'shaders/isp/isp_morphology.frag',
    'gaussian_blur': 'shaders/isp/isp_gaussian_blur.frag',
    'multiply_mono': 'shaders/isp/isp_multiply_mono.frag',
    'blend_mono': 'shaders/isp/isp_blend_mono.frag',
    'blender': 'shaders/isp/isp_blender.frag',
    'bright_contrast': 'shaders/isp/isp_bright_contrast.frag',
    'levels_curve': 'shaders/isp/isp_levels_curve.frag',
    'fluoro_leak': 'shaders/isp/isp_fluoro_leak.frag',
    'fluoro_gain': 'shaders/isp/isp_fluoro_gain.frag',
    'fluoro_bg_sub': 'shaders/isp/isp_fluoro_bg_sub.frag',
    'fluoro_temporal': 'shaders/isp/isp_fluoro_temporal.frag',
    'pseudo_color': 'shaders/isp/isp_pseudo_color.frag',
    'fluoro_fusion': 'shaders/isp/isp_fluoro_fusion.frag',
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
    // 源：RAW 源（bayer_source / 各 cis_* 变体，宽高为偶数；mono 源
    // 可带荧光 mono 链）或图片/视频源（image_source / video_source，
    // 尺寸由解码决定，偶数宽在运行时校验）。非 Bayer CFA 的 mosaic
    // 链运行期由算子格式校验拦截（抛异常回退 CPU）。
    final first = chain.first;
    final ft = first['typeId'] as String;
    final sp = (first['params'] as Map?)?.cast<String, Object?>() ?? const {};
    if (ft == 'image_source' || ft == 'video_source') {
      // 视频源仅单帧预览路径（ffmpeg 解码当前帧后上传；播放仍走 CPU
      // worker）。尺寸由解码决定，偶数宽在运行时校验。
      if (_str(sp, 'filePath').isEmpty) return false;
    } else if (rawSourceTypes.contains(ft)) {
      final w = (sp['width'] as num?)?.toInt() ?? 0;
      final h = (sp['height'] as num?)?.toInt() ?? 0;
      if (w < 4 || h < 4 || w.isOdd || h.isOdd) return false;
    } else {
      return false;
    }

    var seenGamma = false;
    for (var i = 1; i < chain.length; i++) {
      final op = chain[i];
      final typeId = op['typeId'] as String;
      // 荧光/乘法器支路的第二个 RAW 源节点（compileChain 已校验最多 2
      // 个源）：宽高为偶数即可，分辨率/位深一致性在运行期校验。
      if (rawSourceTypes.contains(typeId)) {
        final sp2 = (op['params'] as Map?)?.cast<String, Object?>() ?? const {};
        final w2 = (sp2['width'] as num?)?.toInt() ?? 0;
        final h2 = (sp2['height'] as num?)?.toInt() ?? 0;
        if (w2 < 4 || h2 < 4 || w2.isOdd || h2.isOdd) return false;
        if (seenGamma) return false;
        continue;
      }
      if (!supportedOps.contains(typeId)) return false;
      switch (typeId) {
        case 'preview':
        case 'histogram':
          // 链末：汇点出图；链中：纯透传（为更长链提供 out_mono 端口
          // 引用，如 分路器→预览→乘法器 的单源分支链）。
          break;
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
  /// 色调映射出图（RAW 源 gamma 2.2，图片源 gamma 1.0 直通），供「链是
  /// 主链前缀」的其它预览节点复用。
  /// [rgbaReadbackPorts]：'nodeId:port' 集合，对这些端口做默认色调映射
  /// 并回读 RGBA8（仪器馈源）。
  /// [imageSources]：图片源的共享解码帧（nodeId → RGBA8+宽高，与 CPU
  /// 路径的 sourceRgba 注入同一来源），命中时跳过链内重复解码。
  Future<GpuChainResult> run(
    List<Map<String, Object?>> chain,
    int frameIndex, {
    void Function(String nodeId)? onNodeStart,
    Map<String, String> displayCaptures = const {},
    Set<String> rgbaReadbackPorts = const {},
    Map<String, (Uint8List, int, int)> imageSources = const {},
  }) async {
    final timings = <String, int>{};
    final captures = <String, Map<String, Object?>>{};
    final displayImages = <String, ui.Image>{};
    final portRgba = <String, Uint8List>{};

    // ---- 源节点：CPU 解码（与链内语义一致）→ 上传打包纹理 ----
    final first = chain.first;
    final firstNodeId = first['nodeId'] as String;
    final firstType = first['typeId'] as String;
    final sp = (first['params'] as Map).cast<String, Object?>();
    onNodeStart?.call(firstNodeId);
    var sw = Stopwatch()..start();
    late final int w, h, maxValue;
    late _Port frame;
    late final ui.Image srcTex;
    BayerPattern? pattern;
    if (firstType == 'image_source' || firstType == 'video_source') {
      // 图片/视频源：CPU 解码（图片可注入共享解码帧；视频源仅单帧预览
      // 路径，经 ffmpeg 解码当前帧）→ 16 位 RGB 三通道上传。
      // 两者本身都是 sRGB 显示数据，出图默认 gamma 1.0 直通（见链末）。
      final maxV = bayerMaxValue(
          int.parse(_str(sp, 'bitDepth').isEmpty ? '8' : _str(sp, 'bitDepth')));
      final injected = imageSources[firstNodeId];
      final (rgb, w0, h0) = injected != null
          ? rgba8ToRgb16(injected.$1, injected.$2, injected.$3, maxV)
          : firstType == 'image_source'
              ? await decodeImageFileToRgb16(_str(sp, 'filePath'),
                  maxValue: maxV)
              : await decodeVideoFrameToRgb16(_str(sp, 'filePath'), frameIndex,
                  maxValue: maxV, ffmpegPath: _str(sp, 'ffmpegPath'));
      if (w0.isOdd) {
        throw StateError('GPU 路径要求偶数宽（当前 $w0 x $h0）');
      }
      w = w0;
      h = h0;
      maxValue = maxV;
      srcTex = await uploadPacked(rgb, w, h, 3);
      frame = _Port(srcTex, w * 3 ~/ 2, h, 'rgb');
      // 与 CPU 一致：按源出边端口（compileChain 附加的 outFormat）在源头
      // 转换色彩空间——out_hsl/out_yuv 直连的下游算子（如 HSL 调节器）
      // 拿到的帧格式与 CPU 路径相同。
      final outFormat = first['outFormat'] as String? ?? 'rgb';
      if (outFormat == 'hsl') {
        frame = _Port(
          runPass(_progs['rgb2hsl']!, [
            frame.texW.toDouble(), frame.texH.toDouble(),
            w.toDouble(), maxValue.toDouble(),
          ], [srcTex], frame.texW, frame.texH),
          frame.texW, frame.texH, 'hsl');
      } else if (outFormat == 'yuv') {
        frame = _Port(
          runPass(_progs['rgb2yuv']!, [
            frame.texW.toDouble(), frame.texH.toDouble(), w.toDouble(),
            maxValue.toDouble(),
            ..._rgb2yuvCscUniforms('bt601', 'full', maxValue),
          ], [srcTex], frame.texW, frame.texH),
          frame.texW, frame.texH, 'yuv');
      }
    } else {
      final src =
          await decodeRawSourceFrame(firstType, sp, frameIndex);
      w = src.width;
      h = src.height;
      maxValue = src.maxValue;
      if (w.isOdd || h.isOdd) {
        throw StateError('GPU 路径要求偶数宽高（当前 $w x $h）');
      }
      pattern = src.bayerPattern;
      srcTex = await uploadPacked(src.data, w, h, 1);
      frame = _Port(srcTex, w ~/ 2, h, src.format); // 'mosaic' | 'mono'
    }
    timings[firstNodeId] = sw.elapsedMicroseconds;
    // 链末默认色调映射 gamma：图片/视频源已是 sRGB 显示数据，gamma 1.0
    // 直通；RAW 源为线性数据，gamma 2.2 编码（与 CPU 路径一致）。
    final defaultGamma =
        firstType == 'image_source' || firstType == 'video_source' ? 1.0 : 2.2;

    // Bayer 相位颜色（0=R,1=G,2=B），供黑电平/GrGb/去马赛克。
    final pc = pattern == null
        ? const [0, 1, 1, 2]
        : [for (var ph = 0; ph < 4; ph++) pattern.colorAt(ph & 1, ph >> 1)];

    // 端口表：源节点的格式端口别名指向同一帧（与 CPU 路径一致，
    // 由下游算子按需自行转换）。
    final ports = <String, _Port>{
      '$firstNodeId:out': frame,
      '$firstNodeId:out_rgb': frame,
      '$firstNodeId:out_yuv': frame,
      '$firstNodeId:out_hsl': frame,
    };

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
        // 顺带测量捕获 pass 耗时：被覆盖的前缀预览（key 为预览节点 id）
        // 自身不在主链上，其耗时栏只能来自这里。'id#in' 输入链 key 与
        // CPU 路径口径一致不计耗时。注意若 key 恰为主链节点（分支出图
        // 的汇点预览），此处 += 后会被本节点算子耗时覆盖——算子墙钟
        // 已包含该捕获，语义不丢。
        final csw = Stopwatch()..start();
        displayImages[key] = _tonemap(frame, w, h, maxValue, defaultGamma, 0, 1.0);
        if (!key.endsWith('#in')) {
          timings[key] = (timings[key] ?? 0) + csw.elapsedMicroseconds;
        }
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

      // 第二个源节点（荧光/乘法器支路的 RAW 源，compileChain 已校验
      // 最多 2 个源）：解码上传。分辨率/位深须与主源一致（GPU 链全程
      // 共享 w/h/maxValue），不一致抛异常由调用方回退 CPU。
      if (rawSourceTypes.contains(typeId)) {
        final src2 = await decodeRawSourceFrame(typeId, p, frameIndex);
        if (src2.width != w || src2.height != h) {
          throw StateError('GPU 路径：双源分辨率必须一致'
              '（主源 $w×$h，支路 ${src2.width}×${src2.height}）');
        }
        if (src2.maxValue != maxValue) {
          throw StateError('GPU 路径：双源位深必须一致');
        }
        final tex2 = await uploadPacked(src2.data, w, h, 1);
        frame = _Port(tex2, w ~/ 2, h, src2.format); // 'mosaic' | 'mono'
        ports['$nodeId:out'] = frame;
        if (src2.format == 'mono') ports['$nodeId:out_mono'] = frame;
        await captureDisplays(nodeId);
        captures[nodeId] =
            await _sampleCapture(frame, display, w, h, maxValue);
        timings[nodeId] = sw.elapsedMicroseconds;
        continue;
      }

      // 分支感知取帧（与 CPU 路径一致）：按视频组输入连接取上游端口
      // 帧——单源分支链中拓扑前驱可能属于另一分支，盲目继承主帧会
      // 错拿数据（如分路器拿到边缘图）。线性链中连接的上游即拓扑
      // 前驱，行为不变。
      for (final vp in _kVideoInputPorts) {
        final conn = inputs[vp] as Map<String, Object?>?;
        if (conn == null) continue;
        final ref = ports['${conn['fromNodeId']}:${conn['fromPort']}'];
        if (ref != null) {
          frame = ref;
          break;
        }
      }

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
        // ---- 高频边缘提取：三域亮度高通黑底白线（edge_extract shader，
        // 与 CPU extractHighFreq 同公式）；out_mono 为单通道边缘图 ----
        case 'edge_extract':
          final edgeFmt = frame.format;
          if (edgeFmt != 'rgb' && edgeFmt != 'yuv' && edgeFmt != 'hsl') {
            throw StateError('GPU 路径：高频边缘提取需要 RGB/YUV/HSL 输入');
          }
          if (w.isOdd) {
            throw StateError('GPU 路径：高频边缘提取要求偶数宽（mono 输出）');
          }
          final edgeGain = (p['gain'] as num?)?.toDouble() ?? 1.0;
          final edgeThr = (p['threshold'] as num?)?.toDouble() ?? 4.0;
          frame = _Port(
            runPass(_progs['edge_extract']!, [
              frame.texW.toDouble(), frame.texH.toDouble(), w.toDouble(),
              edgeFmt == 'rgb' ? 0.0 : (edgeFmt == 'yuv' ? 1.0 : 2.0),
              edgeGain, edgeThr / maxValue, maxValue.toDouble(),
            ], [frame.tex], frame.texW, frame.texH),
            frame.texW, frame.texH, edgeFmt);
          ports['$nodeId:out'] = frame;
          // 三格式输出端口同名别名（帧格式同输入，与 CPU 一致）。
          ports['$nodeId:out_rgb'] = frame;
          ports['$nodeId:out_yuv'] = frame;
          ports['$nodeId:out_hsl'] = frame;
          // out_mono：边缘亮度单通道（rgb/yuv 在 0 通道，hsl 在 L=2 通道）。
          final edgeMono = runPass(_progs['extract_channel']!, [
            frame.texW.toDouble(), frame.texH.toDouble(), w.toDouble(),
            edgeFmt == 'hsl' ? 2.0 : 0.0, (w ~/ 2).toDouble(),
          ], [frame.tex], w ~/ 2, h);
          ports['$nodeId:out_mono'] = _Port(edgeMono, w ~/ 2, h, 'mono');
        // ---- 腐蚀/膨胀：可分离两趟（水平+垂直）逐通道极小/极大滤波
        // （morphology shader 跑两遍，uDir 0/1，与 CPU applyMorphology
        // 同口径；RGB 三通道独立 / Mono 单通道）----
        case 'morphology':
          final erode = _str(p, 'mode') != 'dilate';
          var radius = (p['radius'] as num?)?.toInt() ?? 1;
          if (radius < 1) radius = 1;
          _Port morphPass(_Port src, int channels) {
            final base = [
              src.texW.toDouble(), src.texH.toDouble(), w.toDouble(),
              channels.toDouble(),
            ];
            final hTex = runPass(_progs['morphology']!, [
              ...base, 0.0, erode ? 1.0 : 0.0, radius.toDouble(),
            ], [src.tex], src.texW, src.texH);
            final vTex = runPass(_progs['morphology']!, [
              ...base, 1.0, erode ? 1.0 : 0.0, radius.toDouble(),
            ], [hTex], src.texW, src.texH);
            transients.add(hTex);
            return _Port(vTex, src.texW, src.texH, src.format);
          }
          final monoIn = inputs['in_mono'] != null ? port('in_mono') : null;
          if (monoIn != null) {
            // in_mono 侧支路（如边缘提取 out_mono）：处理端口纹理，结果
            // 登记 out_mono，主帧透传（与 CPU 一致）。
            if (monoIn.format != 'mono') {
              throw StateError('GPU 路径：腐蚀/膨胀的 in_mono 需要单通道输入');
            }
            ports['$nodeId:out_mono'] = morphPass(monoIn, 1);
            ports['$nodeId:out'] = frame; // 主帧透传
          } else if (frame.format == 'rgb') {
            frame = morphPass(frame, 3);
            ports['$nodeId:out'] = frame;
          } else if (frame.format == 'mono') {
            frame = morphPass(frame, 1);
            ports['$nodeId:out'] = frame;
            ports['$nodeId:out_mono'] = frame;
          } else {
            throw StateError('GPU 路径：腐蚀/膨胀需要 RGB 或 Mono 输入');
          }
        // ---- 高斯模糊：可分离两趟高斯卷积（gaussian_blur shader 跑两遍，
        // uDir 0/1，与 CPU applyGaussianBlur 同口径；垂直趟以原帧纹理做
        // 强度混合）。RGB/YUV/HSL 三通道 / Mono 单通道 ----
        case 'gaussian_blur':
          final gSigma = (p['sigma'] as num?)?.toDouble() ?? 1.0;
          final gStrength = (p['strength'] as num?)?.toDouble() ?? 1.0;
          _Port blurPass(_Port src, int channels) {
            final base = [
              src.texW.toDouble(), src.texH.toDouble(), w.toDouble(),
              channels.toDouble(),
            ];
            // 水平趟：单输入（不混合）；垂直趟：读水平趟结果 + 原帧
            // （uTexOrig）做强度混合。
            final hTex = runPass(_progs['gaussian_blur']!, [
              ...base, 0.0, gSigma, gStrength,
            ], [src.tex, src.tex], src.texW, src.texH);
            final vTex = runPass(_progs['gaussian_blur']!, [
              ...base, 1.0, gSigma, gStrength,
            ], [hTex, src.tex], src.texW, src.texH);
            transients.add(hTex);
            return _Port(vTex, src.texW, src.texH, src.format);
          }
          if (frame.format == 'mono') {
            frame = blurPass(frame, 1);
            ports['$nodeId:out'] = frame;
            ports['$nodeId:out_mono'] = frame;
          } else if (frame.format == 'rgb' ||
              frame.format == 'yuv' ||
              frame.format == 'hsl') {
            frame = blurPass(frame, 3);
            ports['$nodeId:out'] = frame;
            // 三格式输出端口同名别名（帧格式同输入，与 CPU 一致）。
            ports['$nodeId:out_rgb'] = frame;
            ports['$nodeId:out_yuv'] = frame;
            ports['$nodeId:out_hsl'] = frame;
            // out_mono：输出帧亮度通道（rgb/yuv 在 0 通道，hsl 在 L=2
            // 通道），与 CPU 口径一致；extract_channel 打包要求偶数宽。
            if (w.isOdd) {
              throw StateError('GPU 路径：高斯模糊 mono 输出要求偶数宽');
            }
            final blurMono = runPass(_progs['extract_channel']!, [
              frame.texW.toDouble(), frame.texH.toDouble(), w.toDouble(),
              frame.format == 'hsl' ? 2.0 : 0.0, (w ~/ 2).toDouble(),
            ], [frame.tex], w ~/ 2, h);
            ports['$nodeId:out_mono'] = _Port(blurMono, w ~/ 2, h, 'mono');
          } else {
            throw StateError('GPU 路径：高斯模糊需要 RGB/YUV/HSL/Mono 输入');
          }
        // ---- 乘法器：(源1+offset1)×(源2+offset2)/maxValue，两路 mono
        // 纹理逐像素相乘；分辨率必须一致 ----
        case 'multiplier':
          // in_mono 缺省时回退主帧（与 CPU 一致）。
          final mulA = inputs['in_mono'] != null ? port('in_mono') : frame;
          if (mulA.format != 'mono') {
            throw StateError('GPU 路径：乘法器需要 Mono 输入（源1）');
          }
          if (inputs['in_mono2'] == null) {
            throw StateError('乘法器需要接入输入源2（in_mono2 端口）');
          }
          final mulB = port('in_mono2');
          if (mulB.format != 'mono') {
            throw StateError('GPU 路径：乘法器需要 Mono 输入（源2）');
          }
          if (mulA.texW != mulB.texW || mulA.texH != mulB.texH) {
            throw StateError('乘法器两路输入分辨率必须一致');
          }
          frame = _Port(
            runPass(_progs['multiply_mono']!, [
              mulA.texW.toDouble(), mulA.texH.toDouble(),
              _num(p, 'offset1'), _num(p, 'offset2'), maxValue.toDouble(),
            ], [mulA.tex, mulB.tex], mulA.texW, mulA.texH),
            mulA.texW, mulA.texH, 'mono');
          ports['$nodeId:out'] = frame;
          ports['$nodeId:out_mono'] = frame;
        // ---- 加法器：源1×balance + 源2×(1−balance)，两路 mono 纹理
        // 逐像素平衡加权混合（增益总和恒为 1）；分辨率必须一致 ----
        case 'adder':
          // in_mono 缺省时回退主帧（与 CPU 一致）。
          final addA = inputs['in_mono'] != null ? port('in_mono') : frame;
          if (addA.format != 'mono') {
            throw StateError('GPU 路径：加法器需要 Mono 输入（源1）');
          }
          if (inputs['in_mono2'] == null) {
            throw StateError('加法器需要接入输入源2（in_mono2 端口）');
          }
          final addB = port('in_mono2');
          if (addB.format != 'mono') {
            throw StateError('GPU 路径：加法器需要 Mono 输入（源2）');
          }
          if (addA.texW != addB.texW || addA.texH != addB.texH) {
            throw StateError('加法器两路输入分辨率必须一致');
          }
          frame = _Port(
            runPass(_progs['blend_mono']!, [
              addA.texW.toDouble(), addA.texH.toDouble(),
              // 缺省按平衡中点 0.5（与 CPU 一致）。
              (p['balance'] as num?)?.toDouble() ?? 0.5,
              maxValue.toDouble(),
            ], [addA.tex, addB.tex], addA.texW, addA.texH),
            addA.texW, addA.texH, 'mono');
          ports['$nodeId:out'] = frame;
          ports['$nodeId:out_mono'] = frame;
        // ---- 多路选择器（4选1）：select 选中的那路源输入透传到输出
        // （零 pass 纯路由；输出四域同名别名，格式同所选输入）----
        case 'mux4':
          final sel = ((p['select'] as num?)?.toInt() ?? 1).clamp(1, 4);
          _Port? picked;
          for (final suffix in const ['', '_yuv', '_hsl', '_mono']) {
            final name = 'in$sel$suffix';
            if (inputs[name] != null) {
              picked = port(name);
              break;
            }
          }
          if (picked == null) {
            throw StateError('多路选择器的源$sel 未接入输入');
          }
          frame = picked;
          ports['$nodeId:out'] = frame;
          ports['$nodeId:out_rgb'] = frame;
          ports['$nodeId:out_yuv'] = frame;
          ports['$nodeId:out_hsl'] = frame;
          if (frame.format == 'mono') ports['$nodeId:out_mono'] = frame;
        // ---- 混叠器：基图 + 混叠图×蒙版/maxValue×混叠强度（blender
        // shader，三路采样；mono 混叠图按基图格式选目标通道，三通道
        // 混叠图逐通道对应叠加，与 CPU blendMaskMono 一致）----
        case 'blender':
          final blFmt = frame.format;
          if (blFmt != 'rgb' && blFmt != 'yuv' && blFmt != 'hsl' &&
              blFmt != 'mono') {
            throw StateError('GPU 路径：混叠器需要 RGB/YUV/HSL/Mono 基图输入');
          }
          if (inputs['in_mask'] == null) {
            throw StateError('混叠器需要接入蒙版（in_mask 端口）');
          }
          final maskP = port('in_mask');
          if (maskP.format != 'mono') {
            throw StateError('GPU 路径：混叠器的蒙版需要 Mono 输入');
          }
          _Port? blendP;
          for (final bp in const [
            'in_blend', 'in_blend_yuv', 'in_blend_hsl', 'in_blend_mono']) {
            if (inputs[bp] != null) {
              blendP = port(bp);
              break;
            }
          }
          if (blendP == null) {
            throw StateError('混叠器需要接入混叠图（in_blend 端口）');
          }
          // 混叠图通道数按打包纹理宽度判定（w*3/2 → 三通道，w/2 →
          // mono），兼容旧流程 in_blend 直接接 mono 的连法。
          final blendChs = blendP.texW * 2 == w * 3
              ? 3
              : blendP.texW * 2 == w
                  ? 1
                  : 0;
          if (maskP.texW * 2 != w ||
              maskP.texH != h ||
              blendP.texH != h ||
              blendChs == 0) {
            throw StateError('混叠器蒙版/混叠图分辨率必须与基图一致');
          }
          frame = _Port(
            runPass(_progs['blender']!, [
              frame.texW.toDouble(), blendP.texW.toDouble(),
              maskP.texW.toDouble(), frame.texH.toDouble(), w.toDouble(),
              blFmt == 'mono' ? 1.0 : 3.0, blendChs.toDouble(),
              blFmt == 'rgb'
                  ? 0.0
                  : blFmt == 'yuv'
                      ? 1.0
                      : blFmt == 'hsl'
                          ? 2.0
                          : 3.0,
              // 缺省按全强度 1.0（与 CPU 一致）。
              (p['strength'] as num?)?.toDouble() ?? 1.0,
              maxValue.toDouble(),
            ], [frame.tex, blendP.tex, maskP.tex], frame.texW, frame.texH),
            frame.texW, frame.texH, blFmt);
          ports['$nodeId:out'] = frame;
          ports['$nodeId:out_rgb'] = frame;
          ports['$nodeId:out_yuv'] = frame;
          ports['$nodeId:out_hsl'] = frame;
          if (blFmt == 'mono') ports['$nodeId:out_mono'] = frame;
        // （bright_contrast shader，与 CPU adjustBrightContrast 同公式；
        // bright=100 且 gain=100 恒等直通）----
        case 'bright_contrast_adjuster':
          final bcFmt = frame.format;
          if (bcFmt != 'rgb' && bcFmt != 'yuv' && bcFmt != 'hsl' &&
              bcFmt != 'mono') {
            throw StateError('GPU 路径：亮度/对比度调节器需要 RGB/YUV/HSL/Mono 输入');
          }
          final bright = (p['bright'] as num?)?.toDouble() ?? 100.0;
          final baseline = (p['baseline'] as num?)?.toDouble() ?? 50.0;
          final gain = (p['gain'] as num?)?.toDouble() ?? 100.0;
          if (bright != 100.0 || gain != 100.0) {
            frame = _Port(
              runPass(_progs['bright_contrast']!, [
                frame.texW.toDouble(), frame.texH.toDouble(), w.toDouble(),
                bcFmt == 'mono' ? 1.0 : 3.0,
                bcFmt == 'rgb' ? 0.0 : (bcFmt == 'yuv' ? 1.0 : 2.0),
                bright / 100, baseline / 100 * maxValue, gain / 100,
                maxValue.toDouble(),
              ], [frame.tex], frame.texW, frame.texH),
              frame.texW, frame.texH, bcFmt);
          }
          ports['$nodeId:out'] = frame;
          // 四格式输出端口同名别名（帧格式同输入，与 CPU 一致）。
          ports['$nodeId:out_rgb'] = frame;
          ports['$nodeId:out_yuv'] = frame;
          ports['$nodeId:out_hsl'] = frame;
          if (bcFmt == 'mono') {
            ports['$nodeId:out_mono'] = frame;
          } else {
            // out_mono：非 mono 输入时取输出帧亮度通道（yuv/hsl 抽通道、
            // rgb 求 BT.601 亮度，与 CPU 一致），供蒙版等 mono 侧端口消费。
            if (w.isOdd) {
              throw StateError('GPU 路径：亮度/对比度调节器的 out_mono 要求偶数宽');
            }
            final bcMono = bcFmt == 'rgb'
                ? runPass(_progs['luma_extract']!, [
                    frame.texW.toDouble(), frame.texH.toDouble(),
                    w.toDouble(), (w ~/ 2).toDouble(),
                  ], [frame.tex], w ~/ 2, h)
                : runPass(_progs['extract_channel']!, [
                    frame.texW.toDouble(), frame.texH.toDouble(),
                    w.toDouble(), bcFmt == 'hsl' ? 2.0 : 0.0,
                    (w ~/ 2).toDouble(),
                  ], [frame.tex], w ~/ 2, h);
            ports['$nodeId:out_mono'] = _Port(bcMono, w ~/ 2, h, 'mono');
          }
        // ---- 激发泄漏扣除：mono 逐像素 v' = max(0, v − min(level,
        // maxSub))（fluoro_leak shader，与 CPU applyFluoroLeak 一致）----
        case 'fluoro_leak':
          if (frame.format != 'mono') {
            throw StateError('GPU 路径：激发泄漏扣除需要 Mono 输入');
          }
          var leakSub = _num(p, 'level');
          final leakMaxSub = _num(p, 'maxSub');
          if (leakMaxSub < leakSub) leakSub = leakMaxSub;
          if (leakSub > 0) {
            frame = _Port(
              runPass(_progs['fluoro_leak']!, [
                frame.texW.toDouble(), frame.texH.toDouble(), leakSub,
              ], [frame.tex], frame.texW, frame.texH),
              frame.texW, frame.texH, 'mono');
          }
          ports['$nodeId:out'] = frame;
          ports['$nodeId:out_mono'] = frame;
        // ---- 背景扣除：块均值是聚集统计，CPU 桥接计算（同 CLAHE 的
        // LUT 路径）打包上传，GPU 逐像素扣除 strength × bg ----
        case 'fluoro_background':
          if (frame.format != 'mono') {
            throw StateError('GPU 路径：背景扣除需要 Mono 输入');
          }
          final bgStrength = _num(p, 'strength');
          if (bgStrength <= 0) {
            ports['$nodeId:out'] = frame;
            ports['$nodeId:out_mono'] = frame;
            break;
          }
          var bgBs = (p['blockSize'] as num?)?.toInt() ?? 0;
          if (bgBs < 2) bgBs = 2;
          {
            final bytes = await readbackBytes(frame.tex);
            final data = bytes.buffer.asUint16List();
            final bx = (w + bgBs - 1) ~/ bgBs, by = (h + bgBs - 1) ~/ bgBs;
            final bw = bx + (bx & 1); // 打包纹理要求偶数列
            final means = Uint16List(bw * by);
            for (var byi = 0; byi < by; byi++) {
              for (var bxi = 0; bxi < bx; bxi++) {
                var sum = 0, count = 0;
                final y0 = byi * bgBs;
                final y1 = y0 + bgBs < h ? y0 + bgBs : h;
                final x0 = bxi * bgBs;
                final x1 = x0 + bgBs < w ? x0 + bgBs : w;
                for (var yy = y0; yy < y1; yy++) {
                  for (var xx = x0; xx < x1; xx++) {
                    sum += data[yy * w + xx];
                    count++;
                  }
                }
                // 均值量化为 16 位（CPU 为 double 均值）：引入的误差
                // ≤ 0.5×strength，亚 LSB 量级（同 CLAHE LUT 量化先例）。
                means[byi * bx + bxi] = count > 0 ? (sum / count).round() : 0;
              }
            }
            final meansTex = await uploadPacked(means, bw, by, 1);
            transients.add(meansTex);
            frame = _Port(
              runPass(_progs['fluoro_bg_sub']!, [
                frame.texW.toDouble(), frame.texH.toDouble(), w.toDouble(),
                bgBs.toDouble(), bx.toDouble(), bgStrength,
                (bw ~/ 2).toDouble(), by.toDouble(),
              ], [frame.tex, meansTex], frame.texW, frame.texH),
              frame.texW, frame.texH, 'mono');
          }
          ports['$nodeId:out'] = frame;
          ports['$nodeId:out_mono'] = frame;
        // ---- 激发归一化：全帧均值统计 CPU 桥接（同 GrGb/自动白平衡），
        // GPU 施加增益 v' = clamp(v × reference/mean, 0, maxValue) ----
        case 'fluoro_normalize':
          if (frame.format != 'mono') {
            throw StateError('GPU 路径：激发归一化需要 Mono 输入');
          }
          final reference = _num(p, 'reference');
          if (reference <= 0) {
            ports['$nodeId:out'] = frame;
            ports['$nodeId:out_mono'] = frame;
            break;
          }
          {
            final bytes = await readbackBytes(frame.tex);
            final data = bytes.buffer.asUint16List();
            var sum = 0;
            for (final v in data) {
              sum += v;
            }
            final mean = data.isEmpty ? 0.0 : sum / data.length;
            if (mean >= _num(p, 'epsilon')) {
              final gain = reference / mean;
              if (gain != 1.0) {
                frame = _Port(
                  runPass(_progs['fluoro_gain']!, [
                    frame.texW.toDouble(), frame.texH.toDouble(), gain,
                    maxValue.toDouble(),
                  ], [frame.tex], frame.texW, frame.texH),
                  frame.texW, frame.texH, 'mono');
              }
            }
          }
          ports['$nodeId:out'] = frame;
          ports['$nodeId:out_mono'] = frame;
        // ---- 时域 IIR 降噪：历史帧纹理存 GpuPipeline 实例（跨 run
        // 存活，有效性口径同 CPU _temporalHistory）；历史副本独立成
        // 纹理（链上 frame 在 run 末端统一回收），旧历史延迟回收 ----
        case 'fluoro_temporal':
          if (frame.format != 'mono') {
            throw StateError('GPU 路径：时域降噪需要 Mono 输入');
          }
          final alpha = _num(p, 'alpha').clamp(0.0, 1.0).toDouble();
          final motion = p['motionAdapt'] != false;
          final hist = _temporalHistory[nodeId];
          final histValid = hist != null &&
              hist.frame == frameIndex - 1 &&
              hist.w == w &&
              hist.h == h &&
              hist.alpha == alpha &&
              hist.motion == motion;
          if (histValid) {
            frame = _Port(
              runPass(_progs['fluoro_temporal']!, [
                frame.texW.toDouble(), frame.texH.toDouble(),
                alpha, motion ? maxValue / 16 : 1e9,
              ], [frame.tex, hist.tex], frame.texW, frame.texH),
              frame.texW, frame.texH, 'mono');
          }
          final histTex = runPass(
              _progs['passthrough']!,
              [frame.texW.toDouble(), frame.texH.toDouble()],
              [frame.tex],
              frame.texW,
              frame.texH);
          if (hist != null) transients.add(hist.tex); // 旧历史延迟回收
          _temporalHistory[nodeId] = (
            tex: histTex,
            frame: frameIndex,
            w: w,
            h: h,
            alpha: alpha,
            motion: motion,
          );
          ports['$nodeId:out'] = frame;
          ports['$nodeId:out_mono'] = frame;
        // ---- 伪彩映射：mono → 三通道 RGB（pseudo_color shader，
        // 与 CPU monoPseudoColor 同三张色表）----
        case 'pseudo_color':
          if (frame.format != 'mono') {
            throw StateError('GPU 路径：伪彩映射需要 Mono 输入');
          }
          final pcTexW = w * 3 ~/ 2;
          frame = _Port(
            runPass(_progs['pseudo_color']!, [
              frame.texW.toDouble(), frame.texH.toDouble(), w.toDouble(),
              switch (_str(p, 'colormap')) {
                'magenta' => 1.0,
                'hot' => 2.0,
                _ => 0.0,
              },
              _num(p, 'gain'), maxValue.toDouble(), pcTexW.toDouble(),
            ], [frame.tex], pcTexW, h),
            pcTexW, h, 'rgb');
          ports['$nodeId:out'] = frame;
        // ---- 荧光融合：白光 RGB × 荧光 mono（fluoro_fusion shader）；
        // 荧光输入未连接或尺寸不符：白光直通（与 CPU 一致）----
        case 'fluoro_fusion':
          _requireFormat(frame, 'rgb', '荧光融合');
          final flIn = inputs['in_fluoro'] != null ? port('in_fluoro') : null;
          if (flIn == null ||
              flIn.format != 'mono' ||
              flIn.texW != w ~/ 2 ||
              flIn.texH != h) {
            ports['$nodeId:out'] = frame;
            break;
          }
          frame = _Port(
            runPass(_progs['fluoro_fusion']!, [
              frame.texW.toDouble(), frame.texH.toDouble(),
              w.toDouble(), h.toDouble(), flIn.texW.toDouble(),
              _str(p, 'mode') == 'contour' ? 1.0 : 0.0,
              _num(p, 'threshold'), _num(p, 'alphaMax'),
              switch (_str(p, 'colormap')) {
                'magenta' => 1.0,
                'hot' => 2.0,
                _ => 0.0,
              },
              _num(p, 'offsetX'), _num(p, 'offsetY'), maxValue.toDouble(),
            ], [frame.tex, flIn.tex], frame.texW, frame.texH),
            frame.texW, frame.texH, 'rgb');
          ports['$nodeId:out'] = frame;
        // ---- 曲线调节器：RGB 逐通道 LUT 映射。LUT（4096 级）由 CPU 侧
        // levelsCurveLut 生成（与 CPU 同一函数，四种曲线公式一致），
        // 打包上传后 GPU 逐像素查表（levels_curve shader）----
        case 'levels_curves':
          _requireFormat(frame, 'rgb', '曲线调节器');
          final lvPoints = levelsPointsFromParam(p['points']);
          final lvMode = levelsCurveModeFromParam(p['curveMode']);
          final lvGamma = (p['gamma'] as num?)?.toDouble() ?? 1.0;
          // gamma 模式以 γ==1 为恒等；其余模式以控制点是否全在
          // 对角线上判定（与 CPU 一致）。
          final lvIdentity = lvMode == LevelsCurveMode.gamma
              ? lvGamma == 1.0
              : levelsCurveIsIdentity(lvPoints);
          if (!lvIdentity) {
            final lut =
                levelsCurveLut(lvPoints, mode: lvMode, gamma: lvGamma);
            final lutTex = await uploadPacked(lut, kLevelsMax + 1, 1, 1);
            transients.add(lutTex);
            frame = _Port(
              runPass(_progs['levels_curve']!, [
                frame.texW.toDouble(), frame.texH.toDouble(),
                maxValue.toDouble(), ((kLevelsMax + 1) ~/ 2).toDouble(),
              ], [frame.tex, lutTex], frame.texW, frame.texH),
              frame.texW, frame.texH, 'rgb');
          }
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
              maxValue.toDouble(), rGain, 1.0, bGain,
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
          _requireFormat(frame, 'hsl', 'HSL调节器');
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
        case 'rgb_debugger':
          _requireFormat(frame, 'rgb', 'RGB调节器');
          final rGain = (p['r_gain'] as num?)?.toDouble() ?? 1.0;
          final gGain = (p['g_gain'] as num?)?.toDouble() ?? 1.0;
          final bGain = (p['b_gain'] as num?)?.toDouble() ?? 1.0;
          if (rGain != 1.0 || gGain != 1.0 || bGain != 1.0) {
            frame = _Port(
              runPass(_progs['apply_gains']!, [
                frame.texW.toDouble(), frame.texH.toDouble(), w.toDouble(),
                maxValue.toDouble(), rGain, gGain, bGain,
              ], [frame.tex], frame.texW, frame.texH),
              frame.texW, frame.texH, 'rgb');
          }
          ports['$nodeId:out'] = frame;
        case 'color_temp_adjuster':
          _requireFormat(frame, 'rgb', '色温调节器');
          // von Kries 对角增益（color_temp.dart），复用白平衡/RGB 调节器
          // 的 apply_gains shader（与 CPU 的 adjustRgb 同一语义）。
          final gains = colorTempGains(
              (p['temperature'] as num?)?.toDouble() ?? kColorTempDefault,
              (p['measured_cct'] as num?)?.toInt() ?? 0);
          if (gains[0] != 1.0 || gains[1] != 1.0 || gains[2] != 1.0) {
            frame = _Port(
              runPass(_progs['apply_gains']!, [
                frame.texW.toDouble(), frame.texH.toDouble(), w.toDouble(),
                maxValue.toDouble(), gains[0], gains[1], gains[2],
              ], [frame.tex], frame.texW, frame.texH),
              frame.texW, frame.texH, 'rgb');
          }
          ports['$nodeId:out'] = frame;
          // 声明端口名为 out_rgb：同时按声明名注册，供下游端口查找。
          ports['$nodeId:out_rgb'] = frame;
        case 'yuv_debugger':
          _requireFormat(frame, 'yuv', 'YUV调节器');
          final yGain = (p['y_gain'] as num?)?.toDouble() ?? 1.0;
          final uGain = (p['u_gain'] as num?)?.toDouble() ?? 1.0;
          final vGain = (p['v_gain'] as num?)?.toDouble() ?? 1.0;
          if (yGain != 1.0 || uGain != 1.0 || vGain != 1.0) {
            frame = _Port(
              runPass(_progs['yuv_gains']!, [
                frame.texW.toDouble(), frame.texH.toDouble(), w.toDouble(),
                maxValue.toDouble(), (maxValue >> 1).toDouble(),
                yGain, uGain, vGain,
              ], [frame.tex], frame.texW, frame.texH),
              frame.texW, frame.texH, 'yuv');
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
          if (frame.format == 'rgb') {
            // 与 CPU 一致：RGB 输入先内部转 YUV（BT.601 全范围）。
            frame = _Port(
              runPass(_progs['rgb2yuv']!, [
                frame.texW.toDouble(), frame.texH.toDouble(), w.toDouble(),
                maxValue.toDouble(),
                ..._rgb2yuvCscUniforms('bt601', 'full', maxValue),
              ], [frame.tex], frame.texW, frame.texH),
              frame.texW, frame.texH, 'yuv');
          }
          if (frame.format != 'yuv') {
            throw StateError('GPU 路径：YUV 分路器需要 YUV 输入');
          }
          // Y/U/V 各抽取为独立 mono 纹理（下游 AHE/预览/仪器/合路器
          // 取用；与 HSL/RGB 分路器同一形态，下游可任意中转）。
          const yuvOutPorts = ['out_y', 'out_u', 'out_v'];
          for (var ch = 0; ch < 3; ch++) {
            final tex = runPass(_progs['extract_channel']!, [
              frame.texW.toDouble(), frame.texH.toDouble(), w.toDouble(),
              ch.toDouble(), (w ~/ 2).toDouble(),
            ], [frame.tex], w ~/ 2, h);
            ports['$nodeId:${yuvOutPorts[ch]}'] =
                _Port(tex, w ~/ 2, h, 'mono');
          }
          ports['$nodeId:out'] = frame;
        case 'ahe':
          final monoIn = inputs['in_mono'] != null ? port('in_mono') : null;
          final strength = _num(p, 'strength');
          var blockSize = (p['blockSize'] as num?)?.toInt() ?? 32;
          if (blockSize < 2) blockSize = 32;
          var clipLimit = _num(p, 'clipLimit');
          if (clipLimit <= 0) clipLimit = 1.0;
          if (monoIn != null) {
            if (monoIn.format != 'mono') {
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
        // ---- YUV 合路器：三路 mono 打包纹理交织为 YUV 三通道帧
        // （combine_3ch shader；Y 未连接填 0、U/V 未连接填色度中点，
        // 与 CPU 一致）----
        case 'yuv_combiner':
          final yIn = inputs['in_y'] != null ? port('in_y') : null;
          final uIn = inputs['in_u'] != null ? port('in_u') : null;
          final vIn = inputs['in_v'] != null ? port('in_v') : null;
          for (final chIn in [yIn, uIn, vIn]) {
            if (chIn == null) continue;
            if (chIn.format != 'mono') {
              throw StateError('GPU 路径：YUV 合路器需要 Mono 输入');
            }
            if (chIn.texW != w ~/ 2 || chIn.texH != h) {
              throw StateError('YUV 合路器三路输入分辨率必须一致');
            }
          }
          final yuvOutTexW = w * 3 ~/ 2;
          final uMid = (maxValue >> 1).toDouble();
          frame = _Port(
            runPass(_progs['combine_3ch']!, [
              (w ~/ 2).toDouble(), h.toDouble(),
              yIn != null ? 1.0 : 0.0,
              uIn != null ? 1.0 : 0.0,
              vIn != null ? 1.0 : 0.0,
              0.0, uMid, uMid,
              yuvOutTexW.toDouble(),
            ], [
              yIn?.tex ?? frame.tex, // 占位 sampler（uHas=0 不采样）
              uIn?.tex ?? frame.tex,
              vIn?.tex ?? frame.tex,
            ], yuvOutTexW, h),
            yuvOutTexW, h, 'yuv');
          ports['$nodeId:out'] = frame;
        // ---- HSL 分路器：RGB 输入先内部转 HSL（与 CPU 一致），H/S/L
        // 各抽取为独立 mono 纹理（下游预览/仪器/合路器取用）----
        case 'hsl_splitter':
          if (frame.format == 'rgb') {
            frame = _Port(
              runPass(_progs['rgb2hsl']!, [
                frame.texW.toDouble(), frame.texH.toDouble(),
                w.toDouble(), maxValue.toDouble(),
              ], [frame.tex], frame.texW, frame.texH),
              frame.texW, frame.texH, 'hsl');
          }
          if (frame.format != 'hsl') {
            throw StateError('GPU 路径：HSL 分路器需要 HSL 输入');
          }
          const hslOutPorts = ['out_h', 'out_s', 'out_l'];
          for (var ch = 0; ch < 3; ch++) {
            final tex = runPass(_progs['extract_channel']!, [
              frame.texW.toDouble(), frame.texH.toDouble(), w.toDouble(),
              ch.toDouble(), (w ~/ 2).toDouble(),
            ], [frame.tex], w ~/ 2, h);
            ports['$nodeId:${hslOutPorts[ch]}'] =
                _Port(tex, w ~/ 2, h, 'mono');
          }
          ports['$nodeId:out'] = frame;
        // ---- HSL 合路器：三路 mono 打包纹理交织为 HSL 三通道帧
        // （combine_hsl shader；未连接通道填 0，与 CPU 一致）----
        case 'hsl_combiner':
          final hIn = inputs['in_h'] != null ? port('in_h') : null;
          final sIn = inputs['in_s'] != null ? port('in_s') : null;
          final lIn = inputs['in_l'] != null ? port('in_l') : null;
          for (final chIn in [hIn, sIn, lIn]) {
            if (chIn == null) continue;
            if (chIn.format != 'mono') {
              throw StateError('GPU 路径：HSL 合路器需要 Mono 输入');
            }
            if (chIn.texW != w ~/ 2 || chIn.texH != h) {
              throw StateError('HSL 合路器三路输入分辨率必须一致');
            }
          }
          final outTexW = w * 3 ~/ 2;
          frame = _Port(
            runPass(_progs['combine_3ch']!, [
              (w ~/ 2).toDouble(), h.toDouble(),
              hIn != null ? 1.0 : 0.0,
              sIn != null ? 1.0 : 0.0,
              lIn != null ? 1.0 : 0.0,
              0.0, 0.0, 0.0, // 未连接通道填 0（HSL 语义）
              outTexW.toDouble(),
            ], [
              hIn?.tex ?? frame.tex, // 占位 sampler（uHas=0 不采样）
              sIn?.tex ?? frame.tex,
              lIn?.tex ?? frame.tex,
            ], outTexW, h),
            outTexW, h, 'hsl');
          ports['$nodeId:out'] = frame;
        // ---- RGB 分路器：YUV/HSL 输入先转 RGB（与 CPU 一致），R/G/B
        // 各抽取为独立 mono 纹理（extract_channel，同 HSL 分路器）----
        case 'rgb_splitter':
          if (frame.format == 'yuv') {
            frame = _Port(
              runPass(_progs['yuv2rgb']!, [
                frame.texW.toDouble(), frame.texH.toDouble(), w.toDouble(),
                maxValue.toDouble(), (maxValue >> 1).toDouble(),
              ], [frame.tex], frame.texW, frame.texH),
              frame.texW, frame.texH, 'rgb');
          } else if (frame.format == 'hsl') {
            frame = _Port(
              runPass(_progs['hsl2rgb']!, [
                frame.texW.toDouble(), frame.texH.toDouble(),
                w.toDouble(), maxValue.toDouble(),
              ], [frame.tex], frame.texW, frame.texH),
              frame.texW, frame.texH, 'rgb');
          }
          if (frame.format != 'rgb') {
            throw StateError('GPU 路径：RGB 分路器需要 RGB 输入');
          }
          const rgbOutPorts = ['out_r', 'out_g', 'out_b'];
          for (var ch = 0; ch < 3; ch++) {
            final tex = runPass(_progs['extract_channel']!, [
              frame.texW.toDouble(), frame.texH.toDouble(), w.toDouble(),
              ch.toDouble(), (w ~/ 2).toDouble(),
            ], [frame.tex], w ~/ 2, h);
            ports['$nodeId:${rgbOutPorts[ch]}'] =
                _Port(tex, w ~/ 2, h, 'mono');
          }
          ports['$nodeId:out'] = frame;
        // ---- RGB 合路器：三路 mono 打包纹理交织为 RGB 三通道帧
        // （combine_3ch shader；未连接通道填 0，与 CPU 一致）----
        case 'rgb_combiner':
          final rIn = inputs['in_r'] != null ? port('in_r') : null;
          final gIn = inputs['in_g'] != null ? port('in_g') : null;
          final bIn = inputs['in_b'] != null ? port('in_b') : null;
          for (final chIn in [rIn, gIn, bIn]) {
            if (chIn == null) continue;
            if (chIn.format != 'mono') {
              throw StateError('GPU 路径：RGB 合路器需要 Mono 输入');
            }
            if (chIn.texW != w ~/ 2 || chIn.texH != h) {
              throw StateError('RGB 合路器三路输入分辨率必须一致');
            }
          }
          final rgbOutTexW = w * 3 ~/ 2;
          frame = _Port(
            runPass(_progs['combine_3ch']!, [
              (w ~/ 2).toDouble(), h.toDouble(),
              rIn != null ? 1.0 : 0.0,
              gIn != null ? 1.0 : 0.0,
              bIn != null ? 1.0 : 0.0,
              0.0, 0.0, 0.0, // 未连接通道填 0（RGB 语义）
              rgbOutTexW.toDouble(),
            ], [
              rIn?.tex ?? frame.tex, // 占位 sampler（uHas=0 不采样）
              gIn?.tex ?? frame.tex,
              bIn?.tex ?? frame.tex,
            ], rgbOutTexW, h),
            rgbOutTexW, h, 'rgb');
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

      // 与 CPU 一致的通用端口登记：mono 帧同时提供 out_mono 别名，供
      // 下游 in_mono/in_fluoro 分支感知取帧——双源链的交错拓扑序下，
      // 缺别名将回退「继承上一节点帧」，可能错拿另一分支的异格式帧。
      ports.putIfAbsent('$nodeId:out', () => frame);
      if (frame.format == 'mono') {
        ports.putIfAbsent('$nodeId:out_mono', () => frame);
      }

      // 该节点输出处的显示捕获（前缀覆盖的其它预览节点）。
      await captureDisplays(nodeId);
      // 调试变量表采样（微回读，同时充当逐节点 GPU 同步点）。
      captures[nodeId] = await _sampleCapture(frame, display, w, h, maxValue);
      timings[nodeId] = sw.elapsedMicroseconds;
    }

    // ---- 链末出图：gamma 已出图则用之，否则默认色调映射（RAW 源
    // gamma 2.2，图片源 gamma 1.0 直通）----
    sw = Stopwatch()..start();
    display ??= _tonemap(frame, w, h, maxValue, defaultGamma, 0, 1.0);
    final sinkNodeId = chain.last['nodeId'] as String;
    timings[sinkNodeId] = (timings[sinkNodeId] ?? 0) + sw.elapsedMicroseconds;
    captures[sinkNodeId] = await _sampleCapture(frame, display, w, h, maxValue);

    // ---- 仪器馈源端口回读（默认色调映射 RGBA8）----
    for (final key in rgbaReadbackPorts) {
      final ref = ports[key];
      if (ref == null) continue;
      final img = _tonemap(ref, w, h, maxValue, defaultGamma, 0, 1.0);
      portRgba[key] = await readbackBytes(img);
      img.dispose();
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
