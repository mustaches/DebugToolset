/// ISP Studio 各节点类型的「查看代码」内容与变量描述。
///
/// 代码内容不再手工维护摘录：pipeline/ 下的真实 .dart 源码作为 Flutter
/// 资产打包（见 pubspec.yaml 的 assets），运行时由 [loadNodeCode] 经
/// rootBundle 加载，按 [nodeCodeSpec] 中登记的入口符号从真实源码提取
/// 真实函数体，并自动补齐调用闭包内的全部子函数（提取器与声明索引见
/// source_extract.dart）。修改实现文件里被引用的符号名时，防漂移测试
/// test/isp_node_code_test.dart 会报错提示。
library;

import 'package:flutter/services.dart' show rootBundle;

import 'code_variables.dart';
import 'source_extract.dart';

/// 一个代码段：从 [file]（lib/modules/isp_studio/pipeline/ 下相对路径）
/// 提取 [symbols] 中每个符号（'case:xxx' 前缀表示 switch case 分支）。
class NodeCodeSeg {
  final String file;
  final List<String> symbols;

  const NodeCodeSeg(this.file, this.symbols);
}

/// 节点类型 id → 入口代码段列表。注册表中的每种类型都必须有对应条目。
/// 这里只登记入口符号（'case:xxx' 前缀表示 switch case 分支）；被入口
/// 调用的子函数由 [loadNodeCode] 按调用闭包自动补齐，无需手工列出。
const Map<String, List<NodeCodeSeg>> nodeCodeSpec = {
  // ---- RAW / 图像 / 视频源 ----
  'bayer_source': [
    NodeCodeSeg('isp_kernels.dart',
        ['BayerPattern', 'bayerMaxValue', 'frameByteSize', 'unpackBayer']),
  ],
  'cis_bayer_rggb': [
    NodeCodeSeg('isp_kernels.dart',
        ['BayerPattern', 'bayerMaxValue', 'frameByteSize', 'unpackBayer']),
  ],
  'cis_rccb_rccg': [
    NodeCodeSeg('isp_kernels.dart', ['_rccbAt', '_rccgAt', 'unpackBayer']),
  ],
  'cis_rccc': [
    NodeCodeSeg('isp_kernels.dart', ['_rcccAt', 'unpackBayer']),
  ],
  'cis_ryycy': [
    NodeCodeSeg('isp_kernels.dart', ['_ryycyAt', 'unpackBayer']),
  ],
  'cis_rgb_ir': [
    NodeCodeSeg('isp_kernels.dart', ['_rgbIrAt', 'unpackBayer']),
  ],
  'cis_mono': [
    NodeCodeSeg('isp_kernels.dart', ['unpackBayer']),
    // MONO 无 CFA 的入链分支在 _decodeRawSource 内部（无独立 case）。
    NodeCodeSeg('pipeline_runner.dart', ['_decodeRawSource']),
  ],
  'image_source': [
    NodeCodeSeg('image_source.dart', ['decodeImageFileToRgb16']),
  ],
  'video_source': [
    NodeCodeSeg('video_source.dart', ['decodeVideoFrameToRgb16']),
  ],
  // ---- RAW 域算子 ----
  'black_level': [NodeCodeSeg('isp_kernels.dart', ['applyBlackLevel'])],
  'dpc': [NodeCodeSeg('isp_kernels.dart', ['applyDpc'])],
  'fpn': [NodeCodeSeg('isp_kernels.dart', ['applyFpn'])],
  'lsc': [NodeCodeSeg('isp_kernels.dart', ['applyLsc'])],
  'grgb_balance': [NodeCodeSeg('isp_kernels.dart', ['applyGrGbBalance'])],
  'bayer_dnr': [NodeCodeSeg('isp_kernels.dart', ['applyBayerDenoise'])],
  'highlight': [NodeCodeSeg('isp_kernels.dart', ['applyHighlightRecovery'])],
  // ---- RGB/YUV/HSL 域算子 ----
  'rgb_dnr': [NodeCodeSeg('isp_kernels.dart', ['applyRgbDenoise'])],
  'sharpen': [NodeCodeSeg('isp_kernels.dart', ['applySharpen'])],
  'gaussian_blur': [NodeCodeSeg('isp_kernels.dart', ['applyGaussianBlur'])],
  'morphology': [NodeCodeSeg('isp_kernels.dart', ['applyMorphology'])],
  'edge_extract': [NodeCodeSeg('isp_kernels.dart', ['extractHighFreq'])],
  // ---- 色彩空间转换 ----
  'csc_rgb2yuv': [NodeCodeSeg('isp_kernels.dart', ['convertRgbToYuvCsc'])],
  'csc_rgb2hsl': [NodeCodeSeg('isp_kernels.dart', ['rgbToHsl'])],
  'csc_yuv2rgb': [NodeCodeSeg('isp_kernels.dart', ['yuvToRgb'])],
  'csc_yuv2hsl': [NodeCodeSeg('isp_kernels.dart', ['yuvToHsl'])],
  'csc_hsl2rgb': [NodeCodeSeg('isp_kernels.dart', ['hslToRgb'])],
  'csc_hsl2yuv': [NodeCodeSeg('isp_kernels.dart', ['hslToYuv'])],
  // ---- 调节器 ----
  'hsl_debugger': [NodeCodeSeg('isp_kernels.dart', ['adjustHsl'])],
  'color_controller': [NodeCodeSeg('isp_kernels.dart', ['adjustHslBand'])],
  'rgb_debugger': [NodeCodeSeg('isp_kernels.dart', ['adjustRgb'])],
  'yuv_debugger': [NodeCodeSeg('isp_kernels.dart', ['adjustYuv'])],
  'sat_bright_adjuster': [NodeCodeSeg('isp_kernels.dart', ['adjustSatBright'])],
  'bright_contrast_adjuster': [NodeCodeSeg('isp_kernels.dart', ['adjustBrightContrast'])],
  'levels_curves': [
    NodeCodeSeg('levels_curve.dart', ['levelsCurveLut']),
    NodeCodeSeg('isp_kernels.dart', ['applyLevelsCurve']),
  ],
  'color_balance': [NodeCodeSeg('isp_kernels.dart', ['applyColorBalance'])],
  'color_temp_adjuster': [
    NodeCodeSeg('color_temp.dart', ['colorTempGains']),
    NodeCodeSeg('isp_kernels.dart', ['adjustRgb']),
  ],
  // ---- 荧光 mono 域 ----
  'fluoro_leak': [NodeCodeSeg('isp_kernels.dart', ['applyFluoroLeak'])],
  'fluoro_background': [NodeCodeSeg('isp_kernels.dart', ['applyFluoroBackground'])],
  'fluoro_normalize': [NodeCodeSeg('isp_kernels.dart', ['applyFluoroNormalize'])],
  'fluoro_temporal': [NodeCodeSeg('isp_kernels.dart', ['applyTemporalIir'])],
  'pseudo_color': [NodeCodeSeg('isp_kernels.dart', ['monoPseudoColor'])],
  'fluoro_fusion': [NodeCodeSeg('isp_kernels.dart', ['fuseFluorescence'])],
  'multiplier': [NodeCodeSeg('isp_kernels.dart', ['multiplyMono'])],
  'adder': [NodeCodeSeg('isp_kernels.dart', ['blendMono'])],
  'blender': [NodeCodeSeg('isp_kernels.dart', ['blendMaskMono'])],
  // ---- 通路 ----
  'mux4': [NodeCodeSeg('pipeline_runner.dart', ['case:mux4'])],
  'demosaic': [
    NodeCodeSeg('pipeline_runner.dart', ['case:demosaic']),
    NodeCodeSeg('isp_kernels.dart', [
      'demosaicBilinear',
      'demosaicRccb',
      'demosaicRccc',
      'demosaicRyycy',
      'demosaicRgbIr',
    ]),
    NodeCodeSeg('demosaic_advanced.dart', [
      'demosaicMhc',
      'demosaicAahd',
      'demosaicAmaze',
      'demosaicLmmse',
      'demosaicIgv',
    ]),
  ],
  'white_balance': [NodeCodeSeg('isp_kernels.dart', ['autoWhiteBalanceGains', 'applyWhiteBalance'])],
  'ccm': [NodeCodeSeg('isp_kernels.dart', ['applyCcm'])],
  'gamma': [NodeCodeSeg('isp_kernels.dart', ['tonemapToRgba'])],
  'ahe': [NodeCodeSeg('isp_kernels.dart', ['applyClahe', 'applyClaheMono'])],
  'preview': [NodeCodeSeg('pipeline_runner.dart', ['case:preview'])],
  // ---- 仪器 ----
  'histogram': [NodeCodeSeg('instruments.dart', ['histogramRgb'])],
  'waveform': [NodeCodeSeg('instruments.dart', ['waveformRgb'])],
  'vectorscope': [NodeCodeSeg('instruments.dart', ['vectorscope'])],
  'psnr': [NodeCodeSeg('instruments.dart', ['psnrRgba'])],
  'ssim': [NodeCodeSeg('instruments.dart', ['ssimRgba'])],
  'msssim': [NodeCodeSeg('instruments.dart', ['msssimRgba'])],
  'fsim': [NodeCodeSeg('instruments.dart', ['fsimRgba'])],
  'minmax': [NodeCodeSeg('instruments.dart', ['minmaxMono'])],
  // ---- 无参考评价 ----
  'niqe': [NodeCodeSeg('niqe.dart', ['niqeScore'])],
  'brisque': [NodeCodeSeg('brisque.dart', ['brisqueScore'])],
  'ilniqe': [NodeCodeSeg('ilniqe.dart', ['ilniqeScore'])],
  'piqe': [NodeCodeSeg('piqe.dart', ['piqeScore'])],
  // ---- 深度评价（进程内 Dart 实现）----
  'lpips': [NodeCodeSeg('metrics/lpips_dart.dart', ['lpipsScore'])],
  'dists': [NodeCodeSeg('metrics/dists_dart.dart', ['distsScore'])],
  'fid': [
    NodeCodeSeg('metrics/fid_kid_dart.dart', ['fidScoreFromFeatures']),
  ],
  'kid': [
    // KidGramAccum 是视频逐帧评分的增量核矩阵路径，与 kidCompute 并列入口。
    NodeCodeSeg('metrics/fid_kid_dart.dart', ['kidCompute', 'KidGramAccum']),
  ],
  'musiq': [NodeCodeSeg('metrics/musiq_dart.dart', ['musiqScore'])],
  'clipiqa': [
    NodeCodeSeg('metrics/clipiqa_dart.dart', ['clipiqaScore', 'clipiqaScoreFromFeat']),
  ],
  // ---- 输出 ----
  'image_output': [
    // 不含 encodeFrameInIsolate：它是后台导出时在 isolate 里重跑整条链
    // 的包装，若作为入口，闭包会把整个流水线（runChainFrame 全分发）
    // 拉进本节点页。
    NodeCodeSeg('exporters.dart',
        ['encodePngRgba', 'encodeJpgRgba', 'encodeJpgFfmpeg']),
  ],
  'video_output': [NodeCodeSeg('exporters.dart', ['exportMp4'])],
  // ---- 音频 ----
  'audio_level': [NodeCodeSeg('audio_analysis.dart', ['audioLevels'])],
  'audio_waveform': [NodeCodeSeg('audio_analysis.dart', ['audioWaveform'])],
  'audio_eq': [
    // audioEqBandCenterHz 是界面标注频段中心频率的 API，与 audioEqBands 并列入口。
    NodeCodeSeg('audio_analysis.dart', ['audioEqBandCenterHz', 'audioEqBands']),
  ],
  // ---- 分路 / 合路 ----
  'rgb_splitter': [NodeCodeSeg('pipeline_runner.dart', ['case:rgb_splitter'])],
  'yuv_splitter': [NodeCodeSeg('pipeline_runner.dart', ['case:yuv_splitter'])],
  'hsl_splitter': [NodeCodeSeg('pipeline_runner.dart', ['case:hsl_splitter'])],
  'rgb_combiner': [NodeCodeSeg('pipeline_runner.dart', ['case:rgb_combiner'])],
  'yuv_combiner': [NodeCodeSeg('pipeline_runner.dart', ['case:yuv_combiner'])],
  'hsl_combiner': [NodeCodeSeg('pipeline_runner.dart', ['case:hsl_combiner'])],
};

/// pipeline/ 下源文件内容缓存（资产打包后内容只读，无需失效）。
/// 仅默认的 rootBundle 读取走缓存；自定义 [readFile]（测试读真实文件）
/// 每次现读。
final Map<String, Future<String>> _assetCache = {};

/// 打包为资产的 pipeline 源文件清单（pipeline/ 与 pipeline/metrics/
/// 下的全部 .dart，相对 pipeline/ 的路径）。闭包解析跨文件引用时按
/// 此顺序查找；防漂移测试断言它与目录实际内容一致，新增/删除源文件
/// 时需同步更新。
const List<String> pipelineSourceFiles = [
  'audio_analysis.dart',
  'audio_player.dart',
  'brisque.dart',
  'brisque_model.dart',
  'c_def_index.dart',
  'code_variables.dart',
  'color_temp.dart',
  'demosaic_advanced.dart',
  'dng_source.dart',
  'export_progress.dart',
  'export_segments.dart',
  'exporters.dart',
  'ffmpeg_pipe_win.dart',
  'frame3d.dart',
  'hsl_band_pool.dart',
  'ilniqe.dart',
  'ilniqe_model.dart',
  'image_source.dart',
  'instrument_worker.dart',
  'instruments.dart',
  'isp_kernels.dart',
  'levels_curve.dart',
  'niqe.dart',
  'niqe_model.dart',
  'node_c_code.dart',
  'node_code.dart',
  'pipeline_runner.dart',
  'pipeline_worker.dart',
  'piqe.dart',
  'pyiqa_worker.dart',
  'raw_sidecar.dart',
  'source_extract.dart',
  'video_source.dart',
  'metrics/clip_rn50_dart.dart',
  'metrics/clip_rn50_gpu.dart',
  'metrics/clipiqa_dart.dart',
  'metrics/dists_dart.dart',
  'metrics/fid_kid_dart.dart',
  'metrics/inception_dart.dart',
  'metrics/inception_v3_gpu.dart',
  'metrics/kid_score_worker.dart',
  'metrics/lpips_dart.dart',
  'metrics/musiq_dart.dart',
  'metrics/vgg16_dart.dart',
  'metrics/vgg16_gpu.dart',
];

/// 各源文件的顶层声明索引缓存（文件名 → 符号名 → 声明文本）。
/// 资产打包后内容只读，测试读取的也是稳定的仓库文件，无需失效。
final Map<String, Map<String, String>> _declIndexCache = {};

/// 加载 [typeId] 节点的展示代码：按 [nodeCodeSpec] 提取入口符号后，
/// 自动补齐调用闭包内的全部子函数（见 [loadCodeWithClosure]）；
/// 整个 typeId 无规格时返回 `'// 该节点类型暂无可展示的代码'`。
///
/// [readFile] 默认用 rootBundle 加载资产（pubspec.yaml 已声明
/// pipeline/ 与 pipeline/metrics/ 目录资产）；测试可注入文件读取。
/// [keysOut] 非空时回填展示文本包含的全部符号键（'file:name'，入口
/// case 分支为 'file:case:label'），供测试验证闭包收敛。
Future<String> loadNodeCode(
  String typeId, {
  Future<String> Function(String path)? readFile,
  Set<String>? keysOut,
}) {
  final segs = nodeCodeSpec[typeId];
  if (segs == null) {
    return Future.value('// 该节点类型暂无可展示的代码');
  }
  return loadCodeWithClosure(segs, readFile: readFile, keysOut: keysOut);
}

/// 通用闭包加载：从 [entries]（按顺序的入口代码段）提取入口符号文本
/// （含 `case:` 分支），然后扫描其中的标识符，凡在源文件声明索引中
/// 存在的名字即视为内部引用，递归提取并入展示，直到闭包收敛。
///
/// - 去重 + 环路保护：符号键 'file:name' 只输出一次；
/// - 名字跨文件冲突时优先取引用者所在文件的同名符号，其次按
///   [sourceFiles]（默认 [pipelineSourceFiles]）顺序取首个含该名的文件；
/// - Dart SDK 类型/函数不在索引中，自然被忽略；
/// - 展示顺序：入口符号在前（按 [entries] 顺序），子函数按发现顺序
///   （BFS）附后；每段前加 `// ── 来自 pipeline/xxx.dart ──` 分隔注释，
///   自动补齐的段标题带符号名与 `(被引用)` 标记；
/// - 某符号提取失败时插入占位注释而不是静默丢弃。
Future<String> loadCodeWithClosure(
  List<NodeCodeSeg> entries, {
  Future<String> Function(String path)? readFile,
  List<String>? sourceFiles,
  Set<String>? keysOut,
}) async {
  final universe = sourceFiles ?? pipelineSourceFiles;
  final sources = <String, String>{}; // file → 源码（已加载）
  final indexes = <String, Map<String, String>>{}; // file → 声明索引
  final missing = <String>{}; // 读取失败的文件

  Future<String?> sourceOf(String file) async {
    if (missing.contains(file)) return null;
    final cached = sources[file];
    if (cached != null) return cached;
    final path = 'lib/modules/isp_studio/pipeline/$file';
    try {
      final s = await (readFile != null
          ? readFile(path)
          : (_assetCache[path] ??= rootBundle.loadString(path)));
      sources[file] = s;
      return s;
    } catch (_) {
      missing.add(file);
      return null;
    }
  }

  Future<Map<String, String>?> indexOf(String file) async {
    final cached = indexes[file] ?? _declIndexCache[file];
    if (cached != null) return indexes[file] ??= cached;
    final s = await sourceOf(file);
    if (s == null) return null;
    final idx = indexDeclarations(s);
    _declIndexCache[file] = idx;
    return indexes[file] = idx;
  }

  /// 解析标识符 [name] 的声明所在文件：优先 [fromFile]，其次按
  /// [universe] 顺序首个含该名的文件；索引中不存在返回 null。
  Future<String?> resolve(String name, String fromFile) async {
    final local = await indexOf(fromFile);
    if (local != null && local.containsKey(name)) return fromFile;
    for (final f in universe) {
      if (f == fromFile) continue;
      final idx = await indexOf(f);
      if (idx != null && idx.containsKey(name)) return f;
    }
    return null;
  }

  final buf = StringBuffer();
  final emitted = <String>{}; // 已输出的符号键
  final queued = <String>{}; // 已入队的符号键（环路保护）
  final queue = <({String file, String name})>[];

  /// 扫描 [text] 中的标识符，把索引内存在的引用入队。
  Future<void> scanRefs(String text, String fromFile) async {
    for (final id in scanIdentifiers(text)) {
      final f = await resolve(id, fromFile);
      if (f == null) continue;
      if (queued.add('$f:$id')) queue.add((file: f, name: id));
    }
  }

  // 1. 入口符号：按 entries 顺序输出。
  for (final seg in entries) {
    final source = await sourceOf(seg.file);
    if (source == null) {
      buf.writeln('// 无法读取 lib/modules/isp_studio/pipeline/${seg.file}');
      continue;
    }
    buf.writeln('// ── 来自 pipeline/${seg.file} ──');
    for (final sym in seg.symbols) {
      final text = sym.startsWith('case:')
          ? extractSwitchCase(source, sym.substring(5))
          : extractSymbol(source, sym);
      if (text == null) {
        buf.writeln('// 未能在 ${seg.file} 中定位符号 $sym');
        buf.writeln();
        continue;
      }
      buf.writeln(text);
      buf.writeln();
      final key = '${seg.file}:$sym';
      emitted.add(key);
      queued.add(key);
      keysOut?.add(key);
      await scanRefs(text, seg.file);
    }
  }

  // 2. BFS 闭包：子函数按发现顺序附后。
  while (queue.isNotEmpty) {
    final item = queue.removeAt(0);
    final key = '${item.file}:${item.name}';
    if (!emitted.add(key)) continue; // 入口已含
    final text = (await indexOf(item.file))?[item.name];
    if (text == null) continue;
    buf.writeln(
        '// ── 来自 pipeline/${item.file}：${item.name} (被引用) ──');
    buf.writeln(text);
    buf.writeln();
    keysOut?.add(key);
    await scanRefs(text, item.file);
  }
  return buf.toString().trimRight();
}

/// ---------------------------------------------------------------------------
/// 节点输入/输出变量描述（调试器视角：传入节点的变量 = Input，
/// 节点产出的变量 = Output，其余声明为 Inside 内部变量）。
/// ---------------------------------------------------------------------------

/// RAW 源节点共用输入（文件字节 + 解包参数）。
const List<CodeVariable> _rawSourceInputs = [
  CodeVariable(name: 'bytes', type: 'Uint8List', value: 'RAW 文件字节'),
  CodeVariable(name: 'width', type: 'int', value: '帧宽（节点参数）'),
  CodeVariable(name: 'height', type: 'int', value: '帧高（节点参数）'),
  CodeVariable(name: 'bitDepth', type: 'int', value: '位深 8/10/12/16'),
  CodeVariable(
      name: 'packing',
      type: 'BayerPacking',
      value: 'unpackedLsb / unpackedMsb / mipi'),
  CodeVariable(name: 'littleEndian', type: 'bool', value: '字节序（默认 true）'),
  CodeVariable(name: 'byteOffset', type: 'int', value: '帧起始偏移（默认 0）'),
];

/// RAW 源节点共用输出：解包后的马赛克帧。
const List<CodeVariable> _rawSourceOutputs = [
  CodeVariable(name: 'out', type: 'Uint16List', value: '马赛克帧（w*h）'),
];

/// 仪器节点共用输入（链末端显示帧 + 帧尺寸）。
const List<CodeVariable> _instrumentInputs = [
  CodeVariable(name: 'rgba', type: 'Uint8List', value: '链末端 RGBA8888 显示帧'),
  CodeVariable(name: 'width', type: 'int', value: '帧宽'),
  CodeVariable(name: 'height', type: 'int', value: '帧高'),
];

/// 双输入评价数字表（LPIPS/DISTS/FID/KID）共用输入：参考/测试两路
/// 链末端显示帧 + 帧尺寸（两路一致）。
const List<CodeVariable> _dualEvalInputs = [
  CodeVariable(
      name: 'refRgba', type: 'Uint8List', value: '参考图链末端 RGBA8888 显示帧'),
  CodeVariable(
      name: 'testRgba', type: 'Uint8List', value: '测试图链末端 RGBA8888 显示帧'),
  CodeVariable(name: 'width', type: 'int', value: '帧宽（两路一致）'),
  CodeVariable(name: 'height', type: 'int', value: '帧高（两路一致）'),
];

/// RAW 域算子（dpc/fpn/lsc/grgb_balance/bayer_dnr/highlight）共用输入：
/// Bayer 马赛克或 16 位 mono 帧（二选一接入）+ 帧尺寸与节点参数。
const List<CodeVariable> _rawDualInputsVars = [
  CodeVariable(
      name: 'buf', type: 'Uint16List', value: 'RAW 帧（w*h，mosaic 或 mono）'),
  CodeVariable(name: 'width', type: 'int', value: '帧宽'),
  CodeVariable(name: 'height', type: 'int', value: '帧高'),
  CodeVariable(
      name: 'pattern', type: 'BayerPattern?', value: 'CFA 图案（mono 为 null）'),
  CodeVariable(name: 'maxValue', type: 'int', value: '采样最大值'),
];

/// 节点类型 id → Input 变量（传入节点的数据与参数）。
const Map<String, List<CodeVariable>> nodeInputVars = {
  'bayer_source': _rawSourceInputs,
  'cis_bayer_rggb': _rawSourceInputs,
  'cis_rccb_rccg': _rawSourceInputs,
  'cis_rccc': _rawSourceInputs,
  'cis_ryycy': _rawSourceInputs,
  'cis_rgb_ir': _rawSourceInputs,
  'cis_mono': _rawSourceInputs,
  'image_source': [
    CodeVariable(name: 'path', type: 'String', value: '图片文件路径（节点参数）'),
    CodeVariable(name: 'maxValue', type: 'int', value: '16 位量级最大值'),
  ],
  'video_source': [
    CodeVariable(name: 'path', type: 'String', value: '视频文件路径（节点参数）'),
    CodeVariable(name: 'frameIndex', type: 'int', value: '帧序号（0 起）'),
    CodeVariable(name: 'maxValue', type: 'int', value: '16 位量级最大值'),
    CodeVariable(
        name: 'ffmpegPath', type: 'String', value: 'ffmpeg 路径（节点参数）'),
  ],
  'black_level': [
    CodeVariable(name: 'bayer', type: 'Uint16List', value: '马赛克帧（w*h）'),
    CodeVariable(name: 'width', type: 'int', value: '帧宽'),
    CodeVariable(name: 'height', type: 'int', value: '帧高'),
    CodeVariable(name: 'pattern', type: 'BayerPattern', value: 'CFA 图案'),
    CodeVariable(name: 'r', type: 'double', value: 'R 相偏移（节点参数；mono 时为统一偏移）'),
    CodeVariable(name: 'gr', type: 'double', value: 'Gr 相偏移（节点参数）'),
    CodeVariable(name: 'gb', type: 'double', value: 'Gb 相偏移（节点参数）'),
    CodeVariable(name: 'b', type: 'double', value: 'B 相偏移（节点参数）'),
  ],
  'dpc': _rawDualInputsVars,
  'fpn': _rawDualInputsVars,
  'lsc': _rawDualInputsVars,
  'grgb_balance': _rawDualInputsVars,
  'bayer_dnr': _rawDualInputsVars,
  'highlight': _rawDualInputsVars,
  'rgb_dnr': [
    CodeVariable(name: 'rgb', type: 'Uint16List', value: 'RGB 帧（w*h*3）'),
    CodeVariable(name: 'width', type: 'int', value: '帧宽'),
    CodeVariable(name: 'height', type: 'int', value: '帧高'),
    CodeVariable(name: 'luma', type: 'double', value: '亮度保边强度（节点参数）'),
    CodeVariable(name: 'chroma', type: 'double', value: '色度低通强度（节点参数）'),
    CodeVariable(name: 'maxValue', type: 'int', value: '采样最大值'),
  ],
  'sharpen': [
    CodeVariable(name: 'rgb', type: 'Uint16List', value: 'RGB 帧（w*h*3）'),
    CodeVariable(name: 'width', type: 'int', value: '帧宽'),
    CodeVariable(name: 'height', type: 'int', value: '帧高'),
    CodeVariable(name: 'amount', type: 'double', value: '锐化强度（节点参数）'),
    CodeVariable(name: 'threshold', type: 'double', value: '噪声门限（节点参数）'),
    CodeVariable(name: 'maxValue', type: 'int', value: '采样最大值'),
  ],
  'gaussian_blur': [
    CodeVariable(
        name: 'data',
        type: 'Uint16List',
        value: '帧数据（RGB/YUV/HSL 交织 w*h*3，Mono 单通道 w*h）'),
    CodeVariable(name: 'width', type: 'int', value: '帧宽'),
    CodeVariable(name: 'height', type: 'int', value: '帧高'),
    CodeVariable(name: 'channels', type: 'int', value: '通道数（mono=1，其余=3）'),
    CodeVariable(name: 'sigma', type: 'double', value: '高斯 σ（节点参数）'),
    CodeVariable(name: 'strength', type: 'double', value: '混合强度（节点参数）'),
  ],
  'morphology': [
    CodeVariable(
        name: 'data',
        type: 'Uint16List',
        value: '输入帧（RGB 为 w*h*3 交织，Mono 为 w*h 单通道）'),
    CodeVariable(name: 'width', type: 'int', value: '帧宽'),
    CodeVariable(name: 'height', type: 'int', value: '帧高'),
    CodeVariable(name: 'channels', type: 'int', value: '通道数（RGB=3，Mono=1）'),
    CodeVariable(
        name: 'erode', type: 'bool', value: 'true=腐蚀 / false=膨胀（节点参数 mode）'),
    CodeVariable(name: 'radius', type: 'int', value: '结构元半径（节点参数）'),
  ],
  'edge_extract': [
    CodeVariable(name: 'data', type: 'Uint16List', value: '输入帧（w*h*3，格式见 format）'),
    CodeVariable(name: 'width', type: 'int', value: '帧宽'),
    CodeVariable(name: 'height', type: 'int', value: '帧高'),
    CodeVariable(name: 'format', type: 'String', value: 'rgb / yuv / hsl（按接入端口）'),
    CodeVariable(name: 'gain', type: 'double', value: '边缘增益（节点参数）'),
    CodeVariable(name: 'threshold', type: 'double', value: '噪声门限（节点参数）'),
    CodeVariable(name: 'maxValue', type: 'int', value: '采样最大值'),
  ],
  'csc_rgb2yuv': [
    CodeVariable(name: 'rgb', type: 'Uint16List', value: 'RGB 帧（w*h*3）'),
    CodeVariable(name: 'standard', type: 'String', value: 'bt601 / bt709（节点参数）'),
    CodeVariable(name: 'range', type: 'String', value: 'full / limited（节点参数）'),
    CodeVariable(name: 'maxValue', type: 'int', value: '采样最大值'),
  ],
  'csc_rgb2hsl': [
    CodeVariable(name: 'rgb', type: 'Uint16List', value: 'RGB 帧（w*h*3）'),
    CodeVariable(name: 'maxValue', type: 'int', value: '采样最大值'),
  ],
  'csc_yuv2rgb': [
    CodeVariable(name: 'yuv', type: 'Uint16List', value: 'YUV 帧（w*h*3）'),
    CodeVariable(name: 'maxValue', type: 'int', value: '采样最大值'),
  ],
  'csc_yuv2hsl': [
    CodeVariable(name: 'yuv', type: 'Uint16List', value: 'YUV 帧（w*h*3）'),
    CodeVariable(name: 'maxValue', type: 'int', value: '采样最大值'),
  ],
  'csc_hsl2rgb': [
    CodeVariable(name: 'hsl', type: 'Uint16List', value: 'HSL 帧（w*h*3）'),
    CodeVariable(name: 'maxValue', type: 'int', value: '采样最大值'),
  ],
  'csc_hsl2yuv': [
    CodeVariable(name: 'hsl', type: 'Uint16List', value: 'HSL 帧（w*h*3）'),
    CodeVariable(name: 'maxValue', type: 'int', value: '采样最大值'),
  ],
  'hsl_debugger': [
    CodeVariable(name: 'hsl', type: 'Uint16List', value: 'HSL 帧（w*h*3）'),
    CodeVariable(
        name: 'hShiftDeg', type: 'double', value: '色相偏移角度（节点参数 h_shift）'),
    CodeVariable(
        name: 'sGain', type: 'double', value: '饱和度增益（节点参数 s_gain）'),
    CodeVariable(
        name: 'lGain', type: 'double', value: '亮度增益（节点参数 l_gain）'),
    CodeVariable(name: 'maxValue', type: 'int', value: '采样最大值'),
  ],
  'color_controller': [
    CodeVariable(name: 'hsl', type: 'Uint16List', value: 'HSL 帧（w*h*3）'),
    CodeVariable(
        name: 'hCenterDeg', type: 'double', value: '色相中心（节点参数 h_center）'),
    CodeVariable(
        name: 'q', type: 'double', value: 'Q 值（带宽，节点参数 q）'),
    CodeVariable(
        name: 'hShiftDeg', type: 'double', value: '色相调整角度 ±180°（节点参数 h_shift）'),
    CodeVariable(
        name: 'sGain', type: 'double', value: '饱和度增益（节点参数 s_gain）'),
    CodeVariable(
        name: 'lGain', type: 'double', value: '亮度增益（节点参数 l_gain）'),
    CodeVariable(name: 'maxValue', type: 'int', value: '采样最大值'),
  ],
  'rgb_debugger': [
    CodeVariable(name: 'rgb', type: 'Uint16List', value: 'RGB 帧（w*h*3）'),
    CodeVariable(
        name: 'rGain', type: 'double', value: 'R 增益（节点参数 r_gain）'),
    CodeVariable(
        name: 'gGain', type: 'double', value: 'G 增益（节点参数 g_gain）'),
    CodeVariable(
        name: 'bGain', type: 'double', value: 'B 增益（节点参数 b_gain）'),
    CodeVariable(name: 'maxValue', type: 'int', value: '采样最大值'),
  ],
  'yuv_debugger': [
    CodeVariable(name: 'yuv', type: 'Uint16List', value: 'YUV 帧（w*h*3）'),
    CodeVariable(
        name: 'yGain', type: 'double', value: 'Y 增益（节点参数 y_gain）'),
    CodeVariable(
        name: 'uGain', type: 'double', value: 'U 色度增益（节点参数 u_gain）'),
    CodeVariable(
        name: 'vGain', type: 'double', value: 'V 色度增益（节点参数 v_gain）'),
    CodeVariable(name: 'maxValue', type: 'int', value: '采样最大值'),
  ],
  'sat_bright_adjuster': [
    CodeVariable(
        name: 'data', type: 'Uint16List', value: 'RGB/YUV/HSL 帧（w*h*3，格式随输入端口）'),
    CodeVariable(name: 'format', type: 'String', value: '帧格式（rgb/yuv/hsl）'),
    CodeVariable(
        name: 'satGain', type: 'double', value: '色饱和度增益（节点参数 sat_gain）'),
    CodeVariable(
        name: 'brightGain', type: 'double', value: '亮度增益（节点参数 bright_gain）'),
    CodeVariable(name: 'maxValue', type: 'int', value: '采样最大值'),
  ],
  'bright_contrast_adjuster': [
    CodeVariable(
        name: 'data', type: 'Uint16List', value: 'RGB/YUV/HSL 帧（w*h*3，格式随输入端口）'),
    CodeVariable(name: 'format', type: 'String', value: '帧格式（rgb/yuv/hsl）'),
    CodeVariable(
        name: 'brightPct', type: 'double', value: '亮度百分比（节点参数 bright）'),
    CodeVariable(
        name: 'baselinePct', type: 'double', value: '基线百分比（节点参数 baseline）'),
    CodeVariable(
        name: 'gainPct', type: 'double', value: '增益百分比（节点参数 gain）'),
    CodeVariable(name: 'maxValue', type: 'int', value: '采样最大值'),
  ],
  'levels_curves': [
    CodeVariable(name: 'rgb', type: 'Uint16List', value: 'RGB 帧（w*h*3）'),
    CodeVariable(
        name: 'lut',
        type: 'Uint16List',
        value: '传递函数 LUT（4096 级，由控制点参数 points 单调三次样条生成）'),
    CodeVariable(name: 'maxValue', type: 'int', value: '采样最大值'),
  ],
  'color_balance': [
    CodeVariable(
        name: 'data', type: 'Uint16List', value: 'RGB/YUV/HSL 帧（w*h*3，格式随输入端口）'),
    CodeVariable(name: 'format', type: 'String', value: '帧格式（rgb/yuv/hsl）'),
    CodeVariable(
        name: 'cyanRed', type: 'double', value: '青↔红偏移（节点参数 cyan_red，-100~100）'),
    CodeVariable(
        name: 'magentaGreen',
        type: 'double',
        value: '洋红↔绿偏移（节点参数 magenta_green，-100~100）'),
    CodeVariable(
        name: 'yellowBlue', type: 'double', value: '黄↔蓝偏移（节点参数 yellow_blue，-100~100）'),
    CodeVariable(name: 'maxValue', type: 'int', value: '采样最大值'),
  ],
  'color_temp_adjuster': [
    CodeVariable(name: 'rgb', type: 'Uint16List', value: 'RGB 帧（w*h*3）'),
    CodeVariable(
        name: 'temperature',
        type: 'double',
        value: '目标色温 K（节点参数，1800~12000）'),
    CodeVariable(
        name: 'measuredCct',
        type: 'int',
        value: '参考色温 K（隐式参数 measured_cct，运行时自动测量写入，缺省 6500）'),
    CodeVariable(name: 'maxValue', type: 'int', value: '采样最大值'),
  ],
  'fluoro_leak': [
    CodeVariable(name: 'mono', type: 'Uint16List', value: '荧光 mono 帧（w*h）'),
    CodeVariable(name: 'level', type: 'double', value: '扣除电平（节点参数）'),
    CodeVariable(name: 'maxSub', type: 'double', value: '最大扣除限幅（节点参数）'),
  ],
  'fluoro_background': [
    CodeVariable(name: 'mono', type: 'Uint16List', value: '荧光 mono 帧（w*h）'),
    CodeVariable(name: 'width', type: 'int', value: '帧宽'),
    CodeVariable(name: 'height', type: 'int', value: '帧高'),
    CodeVariable(name: 'blockSize', type: 'int', value: '背景估计块大小（节点参数）'),
    CodeVariable(name: 'strength', type: 'double', value: '扣除强度（节点参数）'),
  ],
  'fluoro_normalize': [
    CodeVariable(name: 'mono', type: 'Uint16List', value: '荧光 mono 帧（w*h）'),
    CodeVariable(name: 'reference', type: 'double', value: '参考电平（节点参数）'),
    CodeVariable(name: 'epsilon', type: 'double', value: '除法下限（节点参数）'),
    CodeVariable(name: 'maxValue', type: 'int', value: '采样最大值'),
  ],
  'fluoro_temporal': [
    CodeVariable(name: 'mono', type: 'Uint16List', value: '荧光 mono 帧（w*h）'),
    CodeVariable(name: 'history', type: 'Uint16List?', value: '上一帧输出（时域缓存）'),
    CodeVariable(name: 'alpha', type: 'double', value: '当前帧权重（节点参数）'),
    CodeVariable(name: 'motionAdapt', type: 'bool', value: '运动自适应开关（节点参数）'),
    CodeVariable(name: 'maxValue', type: 'int', value: '采样最大值'),
  ],
  'pseudo_color': [
    CodeVariable(name: 'mono', type: 'Uint16List', value: '荧光 mono 帧（w*h）'),
    CodeVariable(name: 'colormap', type: 'String', value: 'green / magenta / hot'),
    CodeVariable(name: 'gain', type: 'double', value: '增益（节点参数）'),
    CodeVariable(name: 'maxValue', type: 'int', value: '采样最大值'),
  ],
  'fluoro_fusion': [
    CodeVariable(name: 'rgbWl', type: 'Uint16List', value: '白光 RGB 帧（w*h*3）'),
    CodeVariable(name: 'monoFl', type: 'Uint16List', value: '荧光 mono 帧（w*h）'),
    CodeVariable(name: 'width', type: 'int', value: '帧宽'),
    CodeVariable(name: 'height', type: 'int', value: '帧高'),
    CodeVariable(name: 'mode', type: 'String', value: 'alpha / contour（节点参数）'),
    CodeVariable(name: 'threshold', type: 'double', value: '荧光门限（节点参数）'),
    CodeVariable(name: 'alphaMax', type: 'double', value: '最大 α（节点参数）'),
    CodeVariable(name: 'offsetX', type: 'double', value: '配准偏移 X（节点参数）'),
    CodeVariable(name: 'offsetY', type: 'double', value: '配准偏移 Y（节点参数）'),
  ],
  'multiplier': [
    CodeVariable(name: 'a', type: 'Uint16List', value: '输入源1 mono 帧（w*h）'),
    CodeVariable(name: 'b', type: 'Uint16List', value: '输入源2 mono 帧（w*h，分辨率同源1）'),
    CodeVariable(name: 'offset1', type: 'double', value: '源1 偏移（节点参数）'),
    CodeVariable(name: 'offset2', type: 'double', value: '源2 偏移（节点参数）'),
    CodeVariable(name: 'maxValue', type: 'int', value: '采样最大值'),
  ],
  'adder': [
    CodeVariable(name: 'a', type: 'Uint16List', value: '输入源1 mono 帧（w*h）'),
    CodeVariable(name: 'b', type: 'Uint16List', value: '输入源2 mono 帧（w*h，分辨率同源1）'),
    CodeVariable(
        name: 'balance', type: 'double', value: '平衡增益（节点参数，源1 权重，源2 = 1−balance）'),
    CodeVariable(name: 'maxValue', type: 'int', value: '采样最大值'),
  ],
  'blender': [
    CodeVariable(
        name: 'base',
        type: 'Uint16List',
        value: '基图帧（RGB/YUV/HSL 为 w*h*3 交织，Mono 为 w*h）'),
    CodeVariable(
        name: 'blend',
        type: 'Uint16List',
        value: '混叠图帧（mono 为 w*h，RGB/YUV/HSL 为 w*h*3 交织）'),
    CodeVariable(name: 'mask', type: 'Uint16List', value: '蒙版 mono 帧（w*h）'),
    CodeVariable(
        name: 'format',
        type: 'String',
        value: '基图格式 rgb / yuv / hsl / mono（决定 mono 混叠图的叠加目标通道）'),
    CodeVariable(
        name: 'blendChannels', type: 'int', value: '混叠图通道数（1 / 3）'),
    CodeVariable(name: 'strength', type: 'double', value: '混叠强度（节点参数）'),
    CodeVariable(name: 'maxValue', type: 'int', value: '采样最大值'),
  ],
  'mux4': [
    CodeVariable(
        name: 'select', type: 'int', value: '选择源 1~4（节点参数/单选开关）'),
    CodeVariable(
        name: 'in1~in4',
        type: 'Uint16List',
        value: '四路源输入帧（各 RGB/YUV/HSL/Mono 四域选一，只透传选中一路）'),
  ],
  'demosaic': [
    CodeVariable(name: 'bayer', type: 'Uint16List', value: '马赛克帧（w*h）'),
    CodeVariable(name: 'width', type: 'int', value: '帧宽'),
    CodeVariable(name: 'height', type: 'int', value: '帧高'),
    CodeVariable(
        name: 'pattern', type: 'BayerPattern', value: 'CFA 图案（Bayer 时）'),
    CodeVariable(
        name: 'algorithm',
        type: 'String',
        value: 'bilinear/mhc/aahd/amaze/lmmse/igv（节点参数，Bayer 时）'),
    CodeVariable(
        name: 'maxValue', type: 'int', value: '采样最大值（非 Bayer CFA）'),
    CodeVariable(
        name: 'irSubtraction', type: 'double', value: 'IR 扣除比例（RGB-IR）'),
  ],
  'white_balance': [
    CodeVariable(name: 'rgb', type: 'Uint16List', value: 'RGB 帧（w*h*3）'),
    CodeVariable(name: 'rGain', type: 'double', value: 'R 增益（节点参数）'),
    CodeVariable(name: 'bGain', type: 'double', value: 'B 增益（节点参数）'),
    CodeVariable(name: 'maxValue', type: 'int', value: '采样最大值'),
    CodeVariable(name: 'mode', type: 'String', value: 'manual / auto'),
  ],
  'ccm': [
    CodeVariable(name: 'rgb', type: 'Uint16List', value: 'RGB 帧（w*h*3）'),
    CodeVariable(
        name: 'matrix', type: 'List<double>', value: '3x3 校正矩阵（9 元素）'),
    CodeVariable(name: 'maxValue', type: 'int', value: '采样最大值'),
  ],
  'gamma': [
    CodeVariable(name: 'rgb', type: 'Uint16List', value: 'RGB 帧（w*h*3）'),
    CodeVariable(name: 'maxValue', type: 'int', value: '采样最大值'),
    CodeVariable(name: 'gamma', type: 'double', value: '伽马值（节点参数）'),
    CodeVariable(name: 'brightness', type: 'double', value: '亮度（节点参数）'),
    CodeVariable(name: 'contrast', type: 'double', value: '对比度（节点参数）'),
  ],
  'ahe': [
    CodeVariable(
        name: 'rgb', type: 'Uint16List', value: 'RGB 帧（w*h*3，in 通路）'),
    CodeVariable(
        name: 'mono', type: 'Uint16List', value: 'Mono 帧（w*h，in_mono 通路）'),
    CodeVariable(name: 'width', type: 'int', value: '帧宽'),
    CodeVariable(name: 'height', type: 'int', value: '帧高'),
    CodeVariable(name: 'blockSize', type: 'int', value: '分块大小（节点参数）'),
    CodeVariable(name: 'clipLimit', type: 'double', value: '对比度限幅（节点参数）'),
    CodeVariable(name: 'strength', type: 'double', value: '强度（节点参数）'),
    CodeVariable(name: 'maxValue', type: 'int', value: '采样最大值'),
  ],
  'preview': [
    CodeVariable(
        name: 'frame', type: 'Uint16List', value: '链末端帧数据（rgb/yuv/hsl）'),
    CodeVariable(name: 'maxValue', type: 'int', value: '采样最大值'),
  ],
  'histogram': _instrumentInputs,
  'waveform': _instrumentInputs,
  'vectorscope': _instrumentInputs,
  'psnr': [
    CodeVariable(
        name: 'refRgba', type: 'Uint8List', value: '参考图链末端 RGBA8888 显示帧'),
    CodeVariable(
        name: 'testRgba', type: 'Uint8List', value: '测试图链末端 RGBA8888 显示帧'),
    CodeVariable(name: 'width', type: 'int', value: '帧宽（两路一致）'),
    CodeVariable(name: 'height', type: 'int', value: '帧高（两路一致）'),
  ],
  'ssim': [
    CodeVariable(
        name: 'refRgba', type: 'Uint8List', value: '参考图链末端 RGBA8888 显示帧'),
    CodeVariable(
        name: 'testRgba', type: 'Uint8List', value: '测试图链末端 RGBA8888 显示帧'),
    CodeVariable(name: 'width', type: 'int', value: '帧宽（两路一致）'),
    CodeVariable(name: 'height', type: 'int', value: '帧高（两路一致）'),
  ],
  'msssim': [
    CodeVariable(
        name: 'refRgba', type: 'Uint8List', value: '参考图链末端 RGBA8888 显示帧'),
    CodeVariable(
        name: 'testRgba', type: 'Uint8List', value: '测试图链末端 RGBA8888 显示帧'),
    CodeVariable(name: 'width', type: 'int', value: '帧宽（两路一致）'),
    CodeVariable(name: 'height', type: 'int', value: '帧高（两路一致）'),
  ],
  'fsim': [
    CodeVariable(
        name: 'refRgba', type: 'Uint8List', value: '参考图链末端 RGBA8888 显示帧'),
    CodeVariable(
        name: 'testRgba', type: 'Uint8List', value: '测试图链末端 RGBA8888 显示帧'),
    CodeVariable(name: 'width', type: 'int', value: '帧宽（两路一致）'),
    CodeVariable(name: 'height', type: 'int', value: '帧高（两路一致）'),
  ],
  'niqe': _instrumentInputs,
  'brisque': _instrumentInputs,
  'ilniqe': _instrumentInputs,
  'piqe': _instrumentInputs,
  'lpips': _dualEvalInputs,
  'dists': _dualEvalInputs,
  'fid': _dualEvalInputs,
  'kid': _dualEvalInputs,
  'musiq': _instrumentInputs,
  'clipiqa': _instrumentInputs,
  'minmax': _instrumentInputs,
  'image_output': [
    CodeVariable(name: 'rgba', type: 'Uint8List', value: 'RGBA8888 帧（w*h*4）'),
    CodeVariable(name: 'width', type: 'int', value: '帧宽'),
    CodeVariable(name: 'height', type: 'int', value: '帧高'),
    CodeVariable(name: 'format', type: 'String', value: 'jpg / png（节点参数）'),
    CodeVariable(name: 'quality', type: 'int', value: 'JPG 质量 1-100'),
  ],
  'video_output': [
    CodeVariable(name: 'frame', type: 'Uint8List', value: '逐帧 RGBA8888 数据'),
    CodeVariable(name: 'width', type: 'int', value: '帧宽'),
    CodeVariable(name: 'height', type: 'int', value: '帧高'),
    CodeVariable(name: 'fps', type: 'int', value: '帧率（节点参数）'),
    CodeVariable(name: 'crf', type: 'int', value: 'x264 质量 0-51'),
  ],
  'audio_level': _audioInstrumentInputs,
  'audio_waveform': _audioInstrumentInputs,
  'audio_eq': _audioInstrumentInputs,
  'rgb_splitter': [
    CodeVariable(name: 'frame', type: 'Uint16List', value: '交织 RGB 帧（w*h*3）'),
    CodeVariable(name: 'width', type: 'int', value: '帧宽'),
    CodeVariable(name: 'height', type: 'int', value: '帧高'),
  ],
  'yuv_splitter': [
    CodeVariable(name: 'frame', type: 'Uint16List', value: '交织 YUV 帧（w*h*3）'),
    CodeVariable(name: 'width', type: 'int', value: '帧宽'),
    CodeVariable(name: 'height', type: 'int', value: '帧高'),
  ],
  'hsl_splitter': [
    CodeVariable(name: 'frame', type: 'Uint16List', value: '交织 HSL 帧（w*h*3）'),
    CodeVariable(name: 'width', type: 'int', value: '帧宽'),
    CodeVariable(name: 'height', type: 'int', value: '帧高'),
  ],
  'rgb_combiner': [
    CodeVariable(name: 'rData', type: 'Uint16List?', value: 'R 平面（w*h，可空）'),
    CodeVariable(name: 'gData', type: 'Uint16List?', value: 'G 平面（w*h，可空）'),
    CodeVariable(name: 'bData', type: 'Uint16List?', value: 'B 平面（w*h，可空）'),
  ],
  'yuv_combiner': [
    CodeVariable(name: 'yData', type: 'Uint16List?', value: 'Y 平面（w*h，可空）'),
    CodeVariable(name: 'uData', type: 'Uint16List?', value: 'U 平面（w*h，可空）'),
    CodeVariable(name: 'vData', type: 'Uint16List?', value: 'V 平面（w*h，可空）'),
  ],
  'hsl_combiner': [
    CodeVariable(name: 'hData', type: 'Uint16List?', value: 'H 平面（w*h，可空）'),
    CodeVariable(name: 'sData', type: 'Uint16List?', value: 'S 平面（w*h，可空）'),
    CodeVariable(name: 'lData', type: 'Uint16List?', value: 'L 平面（w*h，可空）'),
  ],
};

/// 音频仪器共用输入（音轨 PCM + 分析位置）。
const List<CodeVariable> _audioInstrumentInputs = [
  CodeVariable(
      name: 'pcm', type: 'WavPcm', value: '视频音轨（44.1kHz 立体声 s16）'),
  CodeVariable(name: 'seconds', type: 'double', value: '当前播放位置（秒）'),
];

/// RAW 域算子共用输出：原地修改后的同格式帧。
const List<CodeVariable> _rawDualOutputVars = [
  CodeVariable(
      name: 'buf', type: 'Uint16List', value: '处理后 RAW 帧（原地修改）'),
];

/// 荧光 mono 域原地修改类算子共用输出。
const List<CodeVariable> _monoInPlaceOutputVars = [
  CodeVariable(
      name: 'mono', type: 'Uint16List', value: '处理后 mono 帧（原地修改）'),
];

/// 节点类型 id → Output 变量（节点产出的数据）。
const Map<String, List<CodeVariable>> nodeOutputVars = {
  'bayer_source': _rawSourceOutputs,
  'cis_bayer_rggb': _rawSourceOutputs,
  'cis_rccb_rccg': _rawSourceOutputs,
  'cis_rccc': _rawSourceOutputs,
  'cis_ryycy': _rawSourceOutputs,
  'cis_rgb_ir': _rawSourceOutputs,
  'cis_mono': [
    CodeVariable(
        name: 'mono', type: 'Uint16List', value: '16 位单通道帧（w*h）'),
  ],
  'image_source': [
    CodeVariable(
        name: 'out', type: 'Uint16List', value: '交织 RGB（w*h*3，16 位量级）'),
    CodeVariable(name: 'w', type: 'int', value: '图片宽'),
    CodeVariable(name: 'h', type: 'int', value: '图片高'),
  ],
  'video_source': [
    CodeVariable(
        name: 'out', type: 'Uint16List', value: '交织 RGB（w*h*3，16 位量级）'),
    CodeVariable(name: 'w', type: 'int', value: '视频帧宽'),
    CodeVariable(name: 'h', type: 'int', value: '视频帧高'),
  ],
  'black_level': [
    CodeVariable(
        name: 'bayer', type: 'Uint16List', value: '黑电平校正后（原地修改）'),
  ],
  'dpc': _rawDualOutputVars,
  'fpn': _rawDualOutputVars,
  'lsc': _rawDualOutputVars,
  'grgb_balance': _rawDualOutputVars,
  'bayer_dnr': _rawDualOutputVars,
  'highlight': _rawDualOutputVars,
  'rgb_dnr': [
    CodeVariable(name: 'rgb', type: 'Uint16List', value: '降噪后（原地修改）'),
  ],
  'sharpen': [
    CodeVariable(name: 'rgb', type: 'Uint16List', value: '锐化后（原地修改）'),
  ],
  'gaussian_blur': [
    CodeVariable(
        name: 'data', type: 'Uint16List', value: '高斯模糊后（原地修改，格式同输入）'),
    CodeVariable(
        name: 'out_mono', type: 'Uint16List', value: '亮度单通道（非 mono 输入时提取登记）'),
  ],
  'morphology': [
    CodeVariable(
        name: 'data', type: 'Uint16List', value: '腐蚀/膨胀后（原地修改，格式同输入）'),
  ],
  'edge_extract': [
    CodeVariable(
        name: 'out', type: 'Uint16List', value: '黑底白线边缘图（w*h*3，gain×√rel×maxValue，格式同输入）'),
    CodeVariable(
        name: 'out_mono', type: 'Uint16List', value: '单通道边缘亮度图（w*h，out_mono 端口）'),
  ],
  'csc_rgb2yuv': [
    CodeVariable(name: 'out', type: 'Uint16List', value: '交织 YUV（w*h*3）'),
  ],
  'csc_rgb2hsl': [
    CodeVariable(name: 'out', type: 'Uint16List', value: '交织 HSL（w*h*3）'),
  ],
  'csc_yuv2rgb': [
    CodeVariable(name: 'out', type: 'Uint16List', value: '交织 RGB（w*h*3）'),
  ],
  'csc_yuv2hsl': [
    CodeVariable(name: 'out', type: 'Uint16List', value: '交织 HSL（w*h*3）'),
  ],
  'csc_hsl2rgb': [
    CodeVariable(name: 'out', type: 'Uint16List', value: '交织 RGB（w*h*3）'),
  ],
  'csc_hsl2yuv': [
    CodeVariable(name: 'out', type: 'Uint16List', value: '交织 YUV（w*h*3）'),
  ],
  'hsl_debugger': [
    CodeVariable(
        name: 'out', type: 'Uint16List', value: '调整后交织 HSL（w*h*3）'),
  ],
  'color_controller': [
    CodeVariable(
        name: 'out', type: 'Uint16List', value: '带内调整后交织 HSL（w*h*3）'),
  ],
  'rgb_debugger': [
    CodeVariable(
        name: 'out', type: 'Uint16List', value: '调整后交织 RGB（w*h*3）'),
  ],
  'yuv_debugger': [
    CodeVariable(
        name: 'out', type: 'Uint16List', value: '调整后交织 YUV（w*h*3）'),
  ],
  'sat_bright_adjuster': [
    CodeVariable(
        name: 'out', type: 'Uint16List', value: '调整后帧（w*h*3，格式同输入）'),
  ],
  'bright_contrast_adjuster': [
    CodeVariable(
        name: 'out', type: 'Uint16List', value: '亮度/对比度调整后帧（w*h*3，格式同输入）'),
  ],
  'levels_curves': [
    CodeVariable(
        name: 'out', type: 'Uint16List', value: '传递函数映射后交织 RGB（w*h*3）'),
  ],
  'color_balance': [
    CodeVariable(
        name: 'out',
        type: 'Uint16List',
        value: '色彩平衡调整后帧（w*h*3，格式同输入端口）'),
  ],
  'color_temp_adjuster': [
    CodeVariable(
        name: 'out', type: 'Uint16List', value: '色温调整后交织 RGB（w*h*3）'),
  ],
  'fluoro_leak': _monoInPlaceOutputVars,
  'fluoro_background': _monoInPlaceOutputVars,
  'fluoro_normalize': _monoInPlaceOutputVars,
  'fluoro_temporal': [
    CodeVariable(name: 'out', type: 'Uint16List', value: 'IIR 滤波后 mono 帧'),
    CodeVariable(name: 'newHistory', type: 'Uint16List', value: '新历史帧（时域缓存）'),
  ],
  'pseudo_color': [
    CodeVariable(name: 'out', type: 'Uint16List', value: '伪彩 RGB（w*h*3）'),
  ],
  'fluoro_fusion': [
    CodeVariable(name: 'out', type: 'Uint16List', value: '融合 RGB（w*h*3）'),
  ],
  'multiplier': [
    CodeVariable(
        name: 'out', type: 'Uint16List', value: '归一化相乘后 mono 帧（w*h）'),
  ],
  'adder': [
    CodeVariable(
        name: 'out', type: 'Uint16List', value: '平衡加权混合后 mono 帧（w*h）'),
  ],
  'blender': [
    CodeVariable(
        name: 'out',
        type: 'Uint16List',
        value: '混叠叠加后帧（格式同基图：RGB/YUV/HSL 为 w*h*3，Mono 为 w*h）'),
  ],
  'mux4': [
    CodeVariable(
        name: 'out', type: 'Uint16List', value: '所选源输入帧（透传，格式同输入）'),
  ],
  'demosaic': [
    CodeVariable(name: 'rgb', type: 'Uint16List', value: '插值 RGB（w*h*3）'),
  ],
  'white_balance': [
    CodeVariable(name: 'rgb', type: 'Uint16List', value: '增益后（原地修改）'),
    CodeVariable(
        name: 'rGain', type: 'double', value: 'auto 模式的实际 R 增益'),
    CodeVariable(
        name: 'bGain', type: 'double', value: 'auto 模式的实际 B 增益'),
  ],
  'ccm': [
    CodeVariable(name: 'rgb', type: 'Uint16List', value: '矩阵校正后（原地修改）'),
  ],
  'gamma': [
    CodeVariable(
        name: 'out', type: 'Uint8List', value: '色调映射 RGBA（w*h*4）'),
  ],
  'ahe': [
    CodeVariable(
        name: 'rgb', type: 'Uint16List', value: '均衡后 RGB（原地修改）'),
    CodeVariable(
        name: 'mono', type: 'Uint16List', value: '均衡后 Mono（原地修改）'),
  ],
  'preview': [
    CodeVariable(name: 'rgba', type: 'Uint8List', value: 'RGBA8888 显示帧'),
  ],
  'histogram': [
    CodeVariable(name: 'r', type: 'Uint32List', value: 'R 直方图（256 桶）'),
    CodeVariable(name: 'g', type: 'Uint32List', value: 'G 直方图（256 桶）'),
    CodeVariable(name: 'b', type: 'Uint32List', value: 'B 直方图（256 桶）'),
    CodeVariable(name: 'y', type: 'Uint32List', value: 'Y 直方图（256 桶）'),
  ],
  'waveform': [
    CodeVariable(
        name: 'r/g/b/y',
        type: 'Uint32List',
        value: 'RGB+Y 波形计数（级*列数+列）'),
    CodeVariable(name: 'columns', type: 'int', value: '降采样后的列数'),
  ],
  'vectorscope': [
    CodeVariable(
        name: 'counts', type: 'Uint32List', value: 'Cb/Cr 计数（256x256）'),
  ],
  'psnr': [
    CodeVariable(name: 'psnr', type: 'double', value: '峰值信噪比（dB，完全相同为 ∞）'),
    CodeVariable(name: 'mse', type: 'double', value: 'RGB 三通道均方误差'),
  ],
  'ssim': [
    CodeVariable(name: 'ssim', type: 'double', value: '结构相似度（0..1，完全相同为 1.0）'),
    CodeVariable(name: 'ssimR', type: 'double', value: 'R 通道 SSIM'),
    CodeVariable(name: 'ssimG', type: 'double', value: 'G 通道 SSIM'),
    CodeVariable(name: 'ssimB', type: 'double', value: 'B 通道 SSIM'),
  ],
  'msssim': [
    CodeVariable(name: 'ssim', type: 'double', value: '多尺度结构相似度（0..1，完全相同为 1.0）'),
    CodeVariable(name: 'ssimR', type: 'double', value: 'R 通道 MS-SSIM'),
    CodeVariable(name: 'ssimG', type: 'double', value: 'G 通道 MS-SSIM'),
    CodeVariable(name: 'ssimB', type: 'double', value: 'B 通道 MS-SSIM'),
  ],
  'fsim': [
    CodeVariable(name: 'fsim', type: 'double', value: '特征相似度（0..1，完全相同为 1.0）'),
    CodeVariable(name: 'fsimR', type: 'double', value: 'R 通道 FSIM'),
    CodeVariable(name: 'fsimG', type: 'double', value: 'G 通道 FSIM'),
    CodeVariable(name: 'fsimB', type: 'double', value: 'B 通道 FSIM'),
  ],
  'niqe': [
    CodeVariable(name: 'niqe', type: 'double', value: 'NIQE 质量分（无参考，越小越好；无法计算为 NaN）'),
  ],
  'brisque': [
    CodeVariable(name: 'brisque', type: 'double', value: 'BRISQUE 质量分（无参考，0..100 越小越好；无法计算为 NaN）'),
  ],
  'ilniqe': [
    CodeVariable(name: 'ilniqe', type: 'double', value: 'ILNIQE 质量分（无参考，越大越差；无法计算为 NaN）'),
  ],
  'piqe': [
    CodeVariable(name: 'piqe', type: 'double', value: 'PIQE 质量分（无参考，0..100 越小越好）'),
  ],
  'lpips': [
    CodeVariable(name: 'lpips', type: 'double', value: 'LPIPS 感知差异（0..~1，越小越好）'),
  ],
  'dists': [
    CodeVariable(name: 'dists', type: 'double', value: 'DISTS 深度结构/纹理差异（0..~1，越小越好）'),
  ],
  'fid': [
    CodeVariable(name: 'fid', type: 'double', value: 'FID 分布距离（≥0，越小越好；样本不足时不出分）'),
    CodeVariable(name: 'n_ref', type: 'int', value: '参考侧累计样本数（299² 图像块）'),
    CodeVariable(name: 'n_test', type: 'int', value: '测试侧累计样本数（299² 图像块）'),
  ],
  'kid': [
    CodeVariable(name: 'kid', type: 'double', value: 'KID 分布距离（≥0，越小越好；样本不足时不出分）'),
    CodeVariable(name: 'n_ref', type: 'int', value: '参考侧累计样本数（299² 图像块）'),
    CodeVariable(name: 'n_test', type: 'int', value: '测试侧累计样本数（299² 图像块）'),
  ],
  'musiq': [
    CodeVariable(name: 'musiq', type: 'double', value: 'MUSIQ 质量分（无参考，~0..100，越大越好）'),
  ],
  'clipiqa': [
    CodeVariable(name: 'clipiqa', type: 'double', value: 'CLIPIQA 质量分（无参考，0..1，越大越好）'),
  ],
  'minmax': [
    CodeVariable(name: 'min', type: 'int', value: '当前帧最小值（0..255）'),
    CodeVariable(name: 'max', type: 'int', value: '当前帧最大值（0..255）'),
    CodeVariable(name: 'holdMin', type: 'int', value: '跨帧保持最小值（UI 侧累计）'),
    CodeVariable(name: 'holdMax', type: 'int', value: '跨帧保持最大值（UI 侧累计）'),
  ],
  'image_output': [
    CodeVariable(
        name: 'bytes', type: 'Uint8List', value: '编码后的 JPG/PNG 文件字节'),
  ],
  'video_output': [
    CodeVariable(
        name: 'outputPath', type: 'String', value: '写出的 MP4 文件'),
  ],
  'audio_level': [
    CodeVariable(name: 'left', type: 'double', value: '左声道峰值电平 0..1'),
    CodeVariable(name: 'right', type: 'double', value: '右声道峰值电平 0..1'),
  ],
  'audio_waveform': [
    CodeVariable(name: 'l', type: 'Float32List', value: '左声道降采样点 -1..1'),
    CodeVariable(name: 'r', type: 'Float32List', value: '右声道降采样点 -1..1'),
    CodeVariable(name: 'sampleRate', type: 'int', value: '采样率（Hz）'),
    CodeVariable(name: 'bits', type: 'int', value: '采样深度（位）'),
  ],
  'audio_eq': [
    CodeVariable(
        name: 'left',
        type: 'Float64List',
        value: '左声道 31 段幅度 0..1（20Hz–20kHz 1/3 倍频程等距分布）'),
    CodeVariable(
        name: 'right',
        type: 'Float64List',
        value: '右声道 31 段幅度 0..1（20Hz–20kHz 1/3 倍频程等距分布）'),
  ],
  'rgb_splitter': [
    CodeVariable(name: 'rData', type: 'Uint16List', value: 'R 平面（w*h）'),
    CodeVariable(name: 'gData', type: 'Uint16List', value: 'G 平面（w*h）'),
    CodeVariable(name: 'bData', type: 'Uint16List', value: 'B 平面（w*h）'),
  ],
  'yuv_splitter': [
    CodeVariable(name: 'yData', type: 'Uint16List', value: 'Y 平面（w*h）'),
    CodeVariable(name: 'uData', type: 'Uint16List', value: 'U 平面（w*h）'),
    CodeVariable(name: 'vData', type: 'Uint16List', value: 'V 平面（w*h）'),
  ],
  'hsl_splitter': [
    CodeVariable(name: 'hData', type: 'Uint16List', value: 'H 平面（w*h）'),
    CodeVariable(name: 'sData', type: 'Uint16List', value: 'S 平面（w*h）'),
    CodeVariable(name: 'lData', type: 'Uint16List', value: 'L 平面（w*h）'),
  ],
  'rgb_combiner': [
    CodeVariable(name: 'combined', type: 'Uint16List', value: '交织 RGB（w*h*3）'),
  ],
  'yuv_combiner': [
    CodeVariable(name: 'combined', type: 'Uint16List', value: '交织 YUV（w*h*3）'),
  ],
  'hsl_combiner': [
    CodeVariable(name: 'combined', type: 'Uint16List', value: '交织 HSL（w*h*3）'),
  ],
};

/// 调试器视角的变量分组：Input（传入）、Output（产出）、Inside（内部）。
class NodeVariableGroups {
  final List<CodeVariable> inputs;
  final List<CodeVariable> outputs;
  final List<CodeVariable> inside;

  const NodeVariableGroups({
    required this.inputs,
    required this.outputs,
    required this.inside,
  });
}

/// 按 Input / Output / Inside 分组 [typeId] 节点代码 [code] 中的变量。
///
/// Input / Output 来自上面的静态描述；Inside 为代码片段中解析出的、
/// 不属于输入输出的其余变量声明。
NodeVariableGroups groupNodeVariables(String typeId, String code) {
  final inputs = nodeInputVars[typeId] ?? const <CodeVariable>[];
  final outputs = nodeOutputVars[typeId] ?? const <CodeVariable>[];
  final ioNames = <String>{
    for (final v in inputs) v.name,
    for (final v in outputs) v.name,
  };
  final inside = [
    for (final v in extractVariables(code))
      if (!ioNames.contains(v.name)) v,
  ];
  return NodeVariableGroups(inputs: inputs, outputs: outputs, inside: inside);
}
