/// ISP Studio 嵌入式相关节点的 ANSI C99 参考实现映射与加载。
///
/// c_ref/ 下的 .h/.c 是面向嵌入式移植的参考实现（已通过 MSVC 语法检查），
/// 与 pipeline/ 的 Dart 实现数值语义对应；「查看代码」页对
/// [nodeCCodeFiles] 中的节点类型展示 C 文件树（左侧文件列表 + 右侧代码，
/// 见 widgets/node_code_page.dart），[pcSideNodeTypes] 中的 PC 侧节点
/// （仪器/评价/导入导出等，无嵌入式对应物）仍展示 Dart 源码。
/// 防漂移测试 test/isp_c_ref_test.dart 断言两个集合无交集、覆盖注册表
/// 全部类型且映射文件在磁盘上存在。
library;

import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

/// 节点类型 id → 关联的 C 参考实现文件（c_ref/ 下文件名，
/// 列表顺序即代码页文件树的显示顺序）。
/// 共享层 isp_common.h/.c 无需在此列出，由 [nodeCCodeFileList] 自动补齐。
const Map<String, List<String>> nodeCCodeFiles = {
  // ---- RAW 源（解包共享层 + 本节点文件）----
  'bayer_source': ['isp_unpack.h', 'isp_unpack.c'],
  'cis_bayer_rggb': ['isp_unpack.h', 'isp_unpack.c'],
  'cis_rccb_rccg': ['isp_unpack.h', 'isp_unpack.c'],
  'cis_rccc': ['isp_unpack.h', 'isp_unpack.c'],
  'cis_ryycy': ['isp_unpack.h', 'isp_unpack.c'],
  'cis_rgb_ir': ['isp_unpack.h', 'isp_unpack.c'],
  'cis_mono': ['isp_unpack.h', 'isp_unpack.c'],
  // ---- RAW 域算子 ----
  'black_level': ['isp_black_level.h', 'isp_black_level.c'],
  'dpc': ['isp_dpc.h', 'isp_dpc.c'],
  'fpn': ['isp_fpn.h', 'isp_fpn.c'],
  'lsc': ['isp_lsc.h', 'isp_lsc.c'],
  'grgb_balance': [
    'isp_grgb_balance.h',
    'isp_grgb_balance.c',
  ],
  'bayer_dnr': [
    'isp_bayer_dnr.h',
    'isp_bayer_dnr.c',
  ],
  'highlight': [
    'isp_highlight.h',
    'isp_highlight.c',
  ],
  // ---- 去马赛克 / RGB 域 ----
  'demosaic': [
    'isp_demosaic.h',
    'isp_demosaic.c',
    'isp_demosaic_adv.h',
    'isp_demosaic_adv.c',
  ],
  'white_balance': ['isp_white_balance.h', 'isp_white_balance.c'],
  'ccm': ['isp_ccm.h', 'isp_ccm.c'],
  'gamma': ['isp_gamma.h', 'isp_gamma.c'],
  'ahe': ['isp_clahe.h', 'isp_clahe.c'],
  'rgb_dnr': ['isp_rgb_dnr.h', 'isp_rgb_dnr.c'],
  'sharpen': ['isp_sharpen.h', 'isp_sharpen.c'],
  'gaussian_blur': ['isp_gaussian_blur.h', 'isp_gaussian_blur.c'],
  'morphology': ['isp_morphology.h', 'isp_morphology.c'],
  'edge_extract': ['isp_edge_extract.h', 'isp_edge_extract.c'],
  // ---- 色彩空间转换 ----
  // CSC 六向互转按变体拆分（原 isp_csc 全家桶已拆分为每变体一对文件
  // + 共享内部头 isp_csc_common.h）：单节点只引用实际用到的变体，
  // 编组导出/查看代码忠实还原流程图。
  'csc_rgb2yuv': ['isp_csc_common.h', 'isp_csc_rgb2yuv.h', 'isp_csc_rgb2yuv.c'],
  'csc_rgb2hsl': ['isp_csc_common.h', 'isp_csc_rgb2hsl.h', 'isp_csc_rgb2hsl.c'],
  'csc_yuv2rgb': ['isp_csc_common.h', 'isp_csc_yuv2rgb.h', 'isp_csc_yuv2rgb.c'],
  'csc_yuv2hsl': ['isp_csc_common.h', 'isp_csc_yuv2hsl.h', 'isp_csc_yuv2hsl.c'],
  'csc_hsl2rgb': ['isp_csc_common.h', 'isp_csc_hsl2rgb.h', 'isp_csc_hsl2rgb.c'],
  'csc_hsl2yuv': ['isp_csc_common.h', 'isp_csc_hsl2yuv.h', 'isp_csc_hsl2yuv.c'],
  // ---- 调节器 ----
  'hsl_debugger': ['isp_adjust.h', 'isp_adjust.c'],
  'rgb_debugger': ['isp_adjust.h', 'isp_adjust.c'],
  'yuv_debugger': ['isp_adjust.h', 'isp_adjust.c'],
  'sat_bright_adjuster': ['isp_adjust.h', 'isp_adjust.c'],
  'bright_contrast_adjuster': ['isp_adjust.h', 'isp_adjust.c'],
  'color_balance': ['isp_adjust.h', 'isp_adjust.c'],
  'color_controller': ['isp_color_controller.h', 'isp_color_controller.c'],
  'levels_curves': ['isp_levels.h', 'isp_levels.c'],
  'color_temp_adjuster': ['isp_color_temp.h', 'isp_color_temp.c'],
  // ---- 荧光 mono 域 ----
  'fluoro_leak': ['isp_fluoro.h', 'isp_fluoro.c'],
  'fluoro_background': ['isp_fluoro.h', 'isp_fluoro.c'],
  'fluoro_normalize': ['isp_fluoro.h', 'isp_fluoro.c'],
  'fluoro_temporal': ['isp_fluoro.h', 'isp_fluoro.c'],
  'pseudo_color': ['isp_fluoro.h', 'isp_fluoro.c'],
  'fluoro_fusion': ['isp_fluoro.h', 'isp_fluoro.c'],
  // ---- 混合 / 通路 ----
  'multiplier': ['isp_blend.h', 'isp_blend.c'],
  'adder': ['isp_blend.h', 'isp_blend.c'],
  'blender': ['isp_blend.h', 'isp_blend.c'],
  'mux4': ['isp_blend.h', 'isp_blend.c'],
  // ---- 分路 / 合路 ----
  'rgb_splitter': ['isp_split.h', 'isp_split.c'],
  'yuv_splitter': ['isp_split.h', 'isp_split.c'],
  'hsl_splitter': ['isp_split.h', 'isp_split.c'],
  'rgb_combiner': ['isp_split.h', 'isp_split.c'],
  'yuv_combiner': ['isp_split.h', 'isp_split.c'],
  'hsl_combiner': ['isp_split.h', 'isp_split.c'],
};

/// 节点的完整 C 文件列表：所有节点 .h 都 #include "isp_common.h"，
/// 共享层 isp_common.h/.c 自动补到最前（与显示分组一致），其余顺序
/// 与映射表一致。
List<String> nodeCCodeFileList(String typeId) {
  final files = nodeCCodeFiles[typeId];
  if (files == null) return const [];
  return [
    'isp_common.h',
    'isp_common.c',
    for (final f in files)
      if (f != 'isp_common.h' && f != 'isp_common.c') f,
  ];
}

/// PC 侧节点类型（仪器 / 评价 / 导入导出 / 音视频分析等，
/// 无嵌入式 C 参考实现，代码页仍展示 Dart 源码并附说明横幅）。
const Set<String> pcSideNodeTypes = {
  'image_source',
  'video_source',
  'preview',
  'histogram',
  'waveform',
  'vectorscope',
  'psnr',
  'ssim',
  'msssim',
  'fsim',
  'niqe',
  'brisque',
  'ilniqe',
  'piqe',
  'lpips',
  'dists',
  'fid',
  'kid',
  'musiq',
  'clipiqa',
  'minmax',
  'image_output',
  'video_output',
  'audio_level',
  'audio_waveform',
  'audio_eq',
};

/// c_ref/ 文件内容缓存（资产打包后内容只读，无需失效）。
/// 仅默认的 rootBundle 读取走缓存；自定义 readFile（测试读真实文件）
/// 每次现读。
final Map<String, Future<String>> _cRefAssetCache = {};

/// 加载 c_ref/ 下 [fileName] 的文本内容。
///
/// 默认用 rootBundle 加载资产（pubspec.yaml 已声明 c_ref/ 目录资产）；
/// 测试可注入 [readFile] 直接读磁盘文件。
Future<String> loadCRefFile(
  String fileName, {
  Future<String> Function(String path)? readFile,
}) {
  final path = 'lib/modules/isp_studio/c_ref/$fileName';
  if (readFile != null) return readFile(path);
  return _cRefAssetCache[path] ??= rootBundle.loadString(path);
}

/// 把 [files] 中的全部 c_ref 文件导出到 [dir] 目录（按原文件名平铺），
/// 返回 (成功数, 失败文件名列表)。单个文件失败不中断其余文件。
Future<(int, List<String>)> exportCRefFiles(
  List<String> files,
  String dir, {
  Future<String> Function(String path)? readFile,
}) async {
  var ok = 0;
  final failed = <String>[];
  for (final f in files) {
    try {
      final content = await loadCRefFile(f, readFile: readFile);
      await File('$dir/$f').writeAsString(content);
      ok++;
    } catch (_) {
      failed.add(f);
    }
  }
  return (ok, failed);
}
