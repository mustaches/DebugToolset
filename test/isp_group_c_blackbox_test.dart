import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/c_compile.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/c_ident.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/group_c_export.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/group_c_export_bb.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/stream_plan.dart';
import 'package:debug_tool_set/modules/isp_studio/models/isp_graph.dart';

void main() {
  /// 从磁盘读真实 c_ref 文件（测试不依赖 rootBundle 资产）。
  Future<String> readDisk(String path) => File(path).readAsString();

  /// MSVC 探测（走 c_compile.dart 的 detectMsvc：vswhere 优先 + 目录枚举，
  /// 覆盖 VS2022/2019/2026；无 MSVC 时对拍/语法编译用例自动跳过）。
  bool msvcAvailable() => detectMsvc() != null;

  group('黑盒导出校验', () {
    test('分离趟算子（morphology/gaussian_blur）放行，混合不支持类型仍拒绝', () {
      final graph = IspGraph();
      final a = graph.addNode('morphology', 0, 0);
      final b = graph.addNode('gaussian_blur', 0, 0);
      final c = graph.addNode('gamma', 0, 0);
      graph.connect(a, 'out', b, 'in');
      graph.connect(b, 'out_rgb', c, 'in');
      graph.groups.add(IspNodeGroup('g1', {a, b, c}, name: 'g'));
      expect(validateGroupBlackBoxExport(graph, graph.groups.single), isNull);
      // 混入不支持类型：拒绝并列出该节点名。
      final d = graph.addNode('ahe', 0, 0);
      graph.nodes[d]!.name = 'clahe';
      graph.groups.add(IspNodeGroup('g2', {a, b, d}, name: 'g'));
      final error = validateGroupBlackBoxExport(graph, graph.groups.last);
      expect(error, isNotNull);
      expect(error, contains('clahe'));
    });

    test('demosaic 非 bilinear 算法拒绝（报错含节点名与参数值）', () {
      final graph = IspGraph();
      final a = graph.addNode('demosaic', 0, 0);
      final b = graph.addNode('white_balance', 0, 0);
      graph.nodes[a]!.name = 'dm';
      graph.nodes[a]!.paramValues['algorithm'] = 'amaze';
      graph.nodes[b]!.paramValues['mode'] = 'manual';
      graph.connect(a, 'out', b, 'in');
      graph.groups.add(IspNodeGroup('g1', {a, b}, name: 'g'));
      final error = validateGroupBlackBoxExport(graph, graph.groups.single);
      expect(error, isNotNull);
      expect(error, contains('dm'));
      expect(error, contains('amaze'));
      expect(error, contains('bilinear'));
      // 切回 bilinear 通过。
      graph.nodes[a]!.paramValues['algorithm'] = 'bilinear';
      expect(validateGroupBlackBoxExport(graph, graph.groups.single), isNull);
      // 空 algorithm（默认 bilinear）也通过。
      graph.nodes[a]!.paramValues.remove('algorithm');
      expect(validateGroupBlackBoxExport(graph, graph.groups.single), isNull);
    });

    test('demosaic 非 Bayer CFA 拒绝', () {
      final graph = IspGraph();
      final a = graph.addNode('demosaic', 0, 0);
      final b = graph.addNode('white_balance', 0, 0);
      graph.nodes[a]!.name = 'dm';
      graph.nodes[a]!.paramValues['cfaPattern'] = 'RCCB';
      graph.nodes[b]!.paramValues['mode'] = 'manual';
      graph.connect(a, 'out', b, 'in');
      graph.groups.add(IspNodeGroup('g1', {a, b}, name: 'g'));
      final error = validateGroupBlackBoxExport(graph, graph.groups.single);
      expect(error, isNotNull);
      expect(error, contains('dm'));
      expect(error, contains('RCCB'));
    });

    test('fpn 拒绝（整帧多遍统计）', () {
      final graph = IspGraph();
      final a = graph.addNode('fpn', 0, 0);
      final b = graph.addNode('black_level', 0, 0);
      graph.nodes[a]!.name = 'fpn1';
      graph.groups.add(IspNodeGroup('g1', {a, b}, name: 'g'));
      final error = validateGroupBlackBoxExport(graph, graph.groups.single);
      expect(error, isNotNull);
      expect(error, contains('fpn1'));
      expect(error, contains('整帧多遍'));
    });

    test('全帧统计节点拒绝：ahe / grgb_balance / fluoro_normalize / '
        'fluoro_background', () {
      for (final typeId in [
        'ahe',
        'grgb_balance',
        'fluoro_normalize',
        'fluoro_background',
      ]) {
        final graph = IspGraph();
        final a = graph.addNode(typeId, 0, 0);
        final b = graph.addNode('gamma', 0, 0);
        graph.nodes[a]!.name = 'node_$typeId';
        // 不接边也满足校验顺序（类型检查在连接检查之后，整帧版校验对
        // 单输入节点无强制连接要求）。
        graph.groups.add(IspNodeGroup('g1', {a, b}, name: 'g'));
        final error = validateGroupBlackBoxExport(graph, graph.groups.single);
        expect(error, isNotNull, reason: typeId);
        expect(error, contains('node_$typeId'), reason: typeId);
        expect(error, contains('全帧统计'), reason: typeId);
      }
    });

    test('fluoro_temporal（跨帧）与 fluoro_fusion（跨行采样）拒绝', () {
      final graph = IspGraph();
      final a = graph.addNode('fluoro_temporal', 0, 0);
      final b = graph.addNode('fluoro_fusion', 0, 0);
      graph.nodes[a]!.name = 'ft';
      graph.nodes[b]!.name = 'ff';
      graph.groups.add(IspNodeGroup('g1', {a, b}, name: 'g'));
      final error = validateGroupBlackBoxExport(graph, graph.groups.single);
      expect(error, isNotNull);
      expect(error, contains('ft'));
      expect(error, contains('跨帧'));
      expect(error, contains('ff'));
      expect(error, contains('跨行'));
    });

    test('混合可/不可导出的编组报错并只列出不支持节点', () {
      final graph = IspGraph();
      final a = graph.addNode('white_balance', 0, 0);
      final b = graph.addNode('ahe', 0, 0);
      graph.nodes[a]!.name = 'wb';
      graph.nodes[b]!.name = 'clahe';
      graph.groups.add(IspNodeGroup('g1', {a, b}, name: 'g'));
      final error = validateGroupBlackBoxExport(graph, graph.groups.single);
      expect(error, isNotNull);
      expect(error, contains('clahe'));
      expect(error, isNot(contains('wb（')));
    });

    test('white_balance auto 模式拒绝（增益估计需全帧统计）', () {
      final graph = IspGraph();
      final a = graph.addNode('white_balance', 0, 0);
      final b = graph.addNode('gamma', 0, 0);
      graph.nodes[a]!.name = 'wb';
      graph.nodes[a]!.paramValues['mode'] = 'auto';
      graph.connect(a, 'out', b, 'in');
      graph.groups.add(IspNodeGroup('g1', {a, b}, name: 'g'));
      final error = validateGroupBlackBoxExport(graph, graph.groups.single);
      expect(error, isNotNull);
      expect(error, contains('wb'));
      expect(error, contains('auto'));
      // manual 通过。
      graph.nodes[a]!.paramValues['mode'] = 'manual';
      expect(validateGroupBlackBoxExport(graph, graph.groups.single), isNull);
    });

    test('数据环（绕过 connect 环检查手动加边）拒绝并列出环上节点', () {
      final graph = IspGraph();
      final a = graph.addNode('rgb_debugger', 0, 0);
      final b = graph.addNode('rgb_debugger', 0, 0);
      graph.nodes[a]!.name = 'dbgA';
      graph.nodes[b]!.name = 'dbgB';
      // graph.connect 自带环检查，直接操作 connections 构造回环。
      graph.connections.add(IspConnection(
          id: 'cycle_ab',
          fromNodeId: a, fromPort: 'out', toNodeId: b, toPort: 'in'));
      graph.connections.add(IspConnection(
          id: 'cycle_ba',
          fromNodeId: b, fromPort: 'out', toNodeId: a, toPort: 'in'));
      graph.groups.add(IspNodeGroup('g1', {a, b}, name: 'g'));
      final error = validateGroupBlackBoxExport(graph, graph.groups.single);
      expect(error, isNotNull);
      expect(error, contains('数据环'));
      expect(error, contains('dbgA'));
      expect(error, contains('dbgB'));
    });

    test('整帧版校验不过时黑盒校验同样不过', () {
      final graph = IspGraph();
      final a = graph.addNode('bayer_source', 0, 0); // Source 类不支持
      final b = graph.addNode('gamma', 0, 0);
      graph.groups.add(IspNodeGroup('g1', {a, b}, name: 'g'));
      expect(validateGroupBlackBoxExport(graph, graph.groups.single),
          isNotNull);
    });
  });

  group('黑盒生成物', () {
    Future<Map<String, String>> buildPipe() async {
      final graph = IspGraph();
      final wb = graph.addNode('white_balance', 0, 0);
      final ccm = graph.addNode('ccm', 0, 0);
      final gamma = graph.addNode('gamma', 0, 0);
      graph.nodes[wb]!.name = 'wb';
      graph.nodes[ccm]!.name = 'ccm';
      graph.nodes[gamma]!.name = 'gamma';
      graph.nodes[wb]!.paramValues['mode'] = 'manual';
      graph.nodes[wb]!.paramValues['rGain'] = 1.3;
      graph.nodes[ccm]!.paramValues['matrix'] = [
        1.1, -0.05, -0.05, //
        -0.1, 1.2, -0.1, //
        -0.05, -0.05, 1.1,
      ];
      graph.connect(wb, 'out', ccm, 'in');
      graph.connect(ccm, 'out', gamma, 'in');
      graph.groups.add(IspNodeGroup('g1', {wb, ccm, gamma}, name: 'pipe'));
      return buildGroupBlackBoxCFiles(graph, graph.groups.single,
          readFile: readDisk, genTime: DateTime(2026, 1, 2, 3, 4, 5));
    }

    test('build 与写盘逐字节一致 + 文件清单', () async {
      final graph = IspGraph();
      final wb = graph.addNode('white_balance', 0, 0);
      final ccm = graph.addNode('ccm', 0, 0);
      final gamma = graph.addNode('gamma', 0, 0);
      graph.nodes[wb]!.name = 'wb';
      graph.nodes[wb]!.paramValues['mode'] = 'manual';
      graph.nodes[ccm]!.name = 'ccm';
      graph.connect(wb, 'out', ccm, 'in');
      graph.connect(ccm, 'out', gamma, 'in');
      graph.groups.add(IspNodeGroup('g1', {wb, ccm, gamma}, name: 'pipe'));

      final genTime = DateTime(2026, 1, 2, 3, 4, 5);
      final map = await buildGroupBlackBoxCFiles(graph, graph.groups.single,
          readFile: readDisk, genTime: genTime);
      // 黑盒只产 bb top + isp_common（像素数学自含，不拷其它 c_ref 文件）。
      expect(
          map.keys.toList(),
          equals([
            'isp_pipe_pipe_bb.h',
            'isp_pipe_pipe_bb.c',
            'isp_common.h',
            'isp_common.c',
          ]));

      final dir = await Directory.systemTemp.createTemp('isp_bb_w_');
      addTearDown(() => dir.delete(recursive: true));
      final result = await exportGroupBlackBoxCCode(
          graph, graph.groups.single, dir.path,
          readFile: readDisk, genTime: genTime);
      expect(result.topName, 'isp_pipe_pipe_bb');
      expect(result.files, equals(map.keys.toList()));
      for (final e in map.entries) {
        expect(await File('${dir.path}/${e.key}').readAsString(), e.value,
            reason: e.key);
      }
    });

    test('纯链：签名含 gamma LUT scratch、无中间边缓冲、融合行循环', () async {
      final map = await buildPipe();
      final h = map['isp_pipe_pipe_bb.h']!;
      final c = map['isp_pipe_pipe_bb.c']!;
      // gamma rgba 输出为 uint8_t *；scratch 形参在末尾（gamma LUT 区）。
      expect(
          h,
          contains('int isp_pipe_pipe_bb_run(const uint16_t *in0, int w, '
              'int h, int max_value, uint8_t *out0, void *scratch, '
              'size_t scratch_bytes);'));
      // scratch 宏只有 gamma LUT 一项（无 h 因子：不存整帧）。
      expect(h, contains('(size_t)(max_value + 1) * sizeof(uint8_t)'));
      expect(h, isNot(contains('(size_t)(h)')));
      // 全链融合：无扇出/外部中间流 → 无 e0 行缓冲。
      expect(c, isNot(contains('e0[')));
      expect(c, contains('for (y = 0; y < h; y++)'));
      expect(c, contains('for (x = 0; x < w; x++)'));
      // ccm 定点矩阵生成期烘焙（Q20）。
      expect(c, contains('static const int64_t ccm_m[9]'));
      expect(c, contains('>> 20'));
      // gamma LUT 运行期构建 + 查表。
      expect(c, contains('gamma_lut[v_] = (uint8_t)llround(c_ * 255.0);'));
      expect(c, contains('row_out0[(x) * 4 + 3] = 255;'));
    });

    test('无 gamma 无扇出的编组省略 scratch 形参', () async {
      final graph = IspGraph();
      final dbg = graph.addNode('rgb_debugger', 0, 0);
      final csc = graph.addNode('csc_rgb2yuv', 0, 0);
      graph.nodes[dbg]!.name = 'dbg';
      graph.nodes[dbg]!.paramValues['r_gain'] = 1.2;
      graph.connect(dbg, 'out', csc, 'in');
      graph.groups.add(IspNodeGroup('g1', {dbg, csc}, name: 'nos'));
      final map = await buildGroupBlackBoxCFiles(graph, graph.groups.single,
          readFile: readDisk, genTime: DateTime(2026, 1, 2, 3, 4, 5));
      final h = map['isp_pipe_nos_bb.h']!;
      expect(h, contains('int isp_pipe_nos_bb_run(const uint16_t *in0, int w, '
          'int h, int max_value, uint16_t *out0);'));
      expect(h, isNot(contains('SCRATCH_BYTES')));
      expect(h, isNot(contains('void *scratch')));
    });

    test('扇出流物化为 scratch 单行缓冲（不存整帧）', () async {
      final graph = IspGraph();
      final wb = graph.addNode('white_balance', 0, 0);
      final sp = graph.addNode('rgb_splitter', 0, 0);
      final cb = graph.addNode('rgb_combiner', 0, 0);
      final gamma = graph.addNode('gamma', 0, 0);
      graph.nodes[wb]!.name = 'wb';
      graph.nodes[wb]!.paramValues['mode'] = 'manual';
      graph.nodes[wb]!.paramValues['rGain'] = 1.3;
      graph.connect(wb, 'out', sp, 'in');
      // wb.out 同时连到组外 → 外部输出 + 组内消费者：物化单行缓冲。
      final outside = graph.addNode('rgb_debugger', 0, 0);
      graph.connect(wb, 'out', outside, 'in');
      graph.connect(sp, 'out_r', cb, 'in_r');
      graph.connect(sp, 'out_g', cb, 'in_g');
      graph.connect(sp, 'out_b', cb, 'in_b');
      graph.connect(cb, 'out', gamma, 'in');
      graph.groups.add(IspNodeGroup('g1', {wb, sp, cb, gamma}, name: 'fan'));
      final map = await buildGroupBlackBoxCFiles(graph, graph.groups.single,
          readFile: readDisk, genTime: DateTime(2026, 1, 2, 3, 4, 5));
      final h = map['isp_pipe_fan_bb.h']!;
      final c = map['isp_pipe_fan_bb.c']!;
      // 两个外部输出（wb.out 透传 + gamma rgba）；wb.out 物化为 e0 单行。
      expect(h, contains('uint16_t *out0'));
      expect(h, contains('uint8_t *out1'));
      expect(h, contains('(size_t)(w) * 3u * sizeof(uint16_t)'));
      expect(c, contains('uint16_t *e0 = (uint16_t *)isp_p;'));
      expect(c, contains('e0[(x) * 3 + 0] ='));
      // splitter 在后续阶段从 e0 读回。
      expect(c, contains('= e0[(x) * 3 + 0]'));
    });

    test('combiner 缺省通道发射常量填充（YUV U/V 缺省 max_value>>1）', () async {
      final graph = IspGraph();
      final wb = graph.addNode('white_balance', 0, 0);
      final csc = graph.addNode('csc_rgb2yuv', 0, 0);
      final sp = graph.addNode('yuv_splitter', 0, 0);
      final cb = graph.addNode('yuv_combiner', 0, 0);
      final gamma = graph.addNode('gamma', 0, 0);
      graph.nodes[wb]!.name = 'wb';
      graph.nodes[wb]!.paramValues['mode'] = 'manual';
      graph.nodes[wb]!.paramValues['rGain'] = 1.3;
      graph.connect(wb, 'out', csc, 'in');
      graph.connect(csc, 'out', sp, 'in');
      graph.connect(sp, 'out_y', cb, 'in_y'); // in_u/in_v 缺省
      graph.connect(cb, 'out', gamma, 'in');
      graph.groups
          .add(IspNodeGroup('g1', {wb, csc, sp, cb, gamma}, name: 'comb'));
      final map = await buildGroupBlackBoxCFiles(graph, graph.groups.single,
          readFile: readDisk, genTime: DateTime(2026, 1, 2, 3, 4, 5));
      final c = map['isp_pipe_comb_bb.c']!;
      expect(c, contains('((uint16_t)(max_value >> 1))'));
    });
  });

  // ---------------------------------------------------------------------------
  // 数值对拍：C harness 同时编译整帧版 top 与黑盒 bb，同一 LCG 输入逐字节比对
  // ---------------------------------------------------------------------------

  /// 生成对拍 harness 的 main.c：LCG 填充输入 → 整帧版 run → 黑盒 run →
  /// memcmp 全部输出。
  String abMainSource({
    required String fullTop,
    required String bbTop,
    required String fullMacro,
    required String bbMacro,
    required List<GroupCExtPort> inputs,
    required List<GroupCExtPort> outputs,
    required bool bbNeedsScratch,
    required List<String> wrapperHeaders,
  }) {
    final decls = <String>[
      for (final p in inputs)
        '  uint16_t *${p.name} = (uint16_t *)malloc(npix * ${p.channels}u * sizeof(uint16_t));',
      for (final p in outputs) ...[
        '  ${p.cType} *${p.name}_a = (${p.cType} *)malloc(npix * ${p.channels}u * sizeof(${p.cType}));',
        '  ${p.cType} *${p.name}_b = (${p.cType} *)malloc(npix * ${p.channels}u * sizeof(${p.cType}));',
      ],
    ];
    final fills = <String>[
      for (final p in inputs)
        '  for (i = 0; i < npix * ${p.channels}u; i++) ${p.name}[i] = lcg((uint32_t)max_value + 1u);',
    ];
    final fullArgs = [
      for (final p in inputs) p.name,
      'w', 'h', 'max_value',
      for (final p in outputs) '${p.name}_a',
      'scratch', 'sb',
    ].join(', ');
    final bbArgs = [
      for (final p in inputs) p.name,
      'w', 'h', 'max_value',
      for (final p in outputs) '${p.name}_b',
      if (bbNeedsScratch) ...['scratch', 'sb'],
    ].join(', ');
    final cmp = <String>[
      for (final p in outputs)
        '''
  if (memcmp(${p.name}_a, ${p.name}_b, npix * ${p.channels}u * sizeof(${p.cType})) != 0) {
    for (i = 0; i < npix * ${p.channels}u; i++) {
      if (${p.name}_a[i] != ${p.name}_b[i]) {
        printf("${p.name}[%u] full=%u bb=%u\\n", (unsigned)i,
               (unsigned)${p.name}_a[i], (unsigned)${p.name}_b[i]);
        break;
      }
    }
    fails++;
  }''',
    ];
    return '''
#include "$fullTop.h"
#include "$bbTop.h"
${[for (final w in wrapperHeaders) '#include "$w"'].join('\n')}

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* LCG（Numerical Recipes 常数，与 test/c_ref/compare_helper.dart 一致）。 */
static uint32_t s_state;
static uint16_t lcg(uint32_t mod) {
  s_state = s_state * 1664525u + 1013904223u;
  return (uint16_t)(((s_state >> 16) & 0xFFFFu) % mod);
}

int main(int argc, char **argv) {
  int w = argc > 1 ? atoi(argv[1]) : 16;
  int h = argc > 2 ? atoi(argv[2]) : 16;
  int max_value = argc > 3 ? atoi(argv[3]) : 1023;
  unsigned seed = argc > 4 ? (unsigned)atoi(argv[4]) : 7u;
  int rc = 0, fails = 0;
  size_t npix, i, sb;
  s_state = seed & 0xFFFFFFFFu;
  npix = (size_t)w * (size_t)h;
${decls.join('\n')}
${fills.join('\n')}
  /* 整帧版 run */
  sb = (size_t)${fullMacro}_SCRATCH_BYTES(w, h, max_value);
  {
    void *scratch = malloc(sb > 0 ? sb : 1);
    rc = ${fullTop}_run($fullArgs);
    free(scratch);
    if (rc != ISP_OK) { printf("full rc=%d\\n", rc); return 2; }
  }
  /* 黑盒 run */
  ${bbNeedsScratch ? 'sb = (size_t)${bbMacro}_SCRATCH_BYTES(w, h, max_value);' : 'sb = 0;'}
  {
    ${bbNeedsScratch ? 'void *scratch = malloc(sb > 0 ? sb : 1);' : ''}
    rc = ${bbTop}_run($bbArgs);
    ${bbNeedsScratch ? 'free(scratch);' : ''}
    if (rc != ISP_OK) { printf("bb rc=%d\\n", rc); return 3; }
  }
${cmp.join('\n')}
  if (fails) { printf("FAIL %d\\n", fails); return 1; }
  printf("PASS\\n");
  return 0;
}
''';
  }

  /// 一组图的 A/B 对拍：生成两侧代码 → 写盘 → cl 编译链接 → 尺寸矩阵运行。
  Future<void> runAbCompare(
    String label,
    IspGraph graph,
    IspNodeGroup group, {
    required List<(int, int)> sizes,
    required List<int> maxValues,
  }) async {
    final group2 = group;
    expect(validateGroupCExport(graph, group2), isNull, reason: label);
    expect(validateGroupBlackBoxExport(graph, group2), isNull, reason: label);
    final genTime = DateTime(2026, 1, 2, 3, 4, 5);
    final fullFiles = await buildGroupCFiles(graph, group2,
        readFile: readDisk, genTime: genTime);
    final bbFiles = await buildGroupBlackBoxCFiles(graph, group2,
        readFile: readDisk, genTime: genTime);
    final dir = await Directory.systemTemp.createTemp('isp_bb_ab_');
    addTearDown(() => dir.delete(recursive: true));
    for (final e in [...fullFiles.entries, ...bbFiles.entries]) {
      await File('${dir.path}/${e.key}').writeAsString(e.value);
    }
    final plan = planGroupC(graph, group2);
    final stream = planGroupStream(plan);
    final fullTop = groupCTopName(group2);
    final bbTop = groupBlackBoxTopName(group2);
    await File('${dir.path}/bb_ab_main.c').writeAsString(abMainSource(
      fullTop: fullTop,
      bbTop: bbTop,
      fullMacro: cMacroPrefix(fullTop),
      bbMacro: cMacroPrefix(bbTop),
      inputs: plan.extInputParams,
      outputs: plan.extOutputParams,
      bbNeedsScratch: stream.needsScratch,
      wrapperHeaders: [
        for (final id in plan.topo) '${plan.wrappers[id]!.fileName}.h',
      ],
    ));
    final cFiles = [
      for (final f in Directory(dir.path).listSync().whereType<File>())
        if (f.path.endsWith('.c')) f.absolute.path.replaceAll('/', r'\'),
    ]..sort();
    final exe = '${dir.path}\\bb_ab.exe';
    final build = await Process.run(
      'cmd',
      ['/c', r'scripts\c_link_check.bat', exe, ...cFiles],
      workingDirectory: Directory.current.path,
    );
    final buildOut = '${build.stdout}\n${build.stderr}';
    expect(buildOut, isNot(contains('error C')), reason: '$label: $buildOut');
    expect(build.exitCode, 0, reason: '$label: $buildOut');
    for (final (w, h) in sizes) {
      for (final mv in maxValues) {
        final r = await Process.run(exe, ['$w', '$h', '$mv', '7']);
        expect(r.exitCode, 0,
            reason: '$label ${w}x$h mv=$mv: ${r.stdout}${r.stderr}');
        expect('${r.stdout}', contains('PASS'),
            reason: '$label ${w}x$h mv=$mv');
      }
    }
  }

  group('黑盒 vs 整帧版数值对拍（MSVC）', () {
    final hasMsvc = msvcAvailable();

    test('WB→CCM→Gamma 纯链（含边界尺寸与 LUT 回退域）', () async {
      final graph = IspGraph();
      final wb = graph.addNode('white_balance', 0, 0);
      final ccm = graph.addNode('ccm', 0, 0);
      final gamma = graph.addNode('gamma', 0, 0);
      graph.nodes[wb]!.name = 'wb';
      graph.nodes[ccm]!.name = 'ccm';
      graph.nodes[wb]!.paramValues['mode'] = 'manual';
      graph.nodes[wb]!.paramValues['rGain'] = 1.3;
      graph.nodes[wb]!.paramValues['bGain'] = 0.7;
      graph.nodes[ccm]!.paramValues['matrix'] = [
        1.1, -0.05, -0.05, //
        -0.1, 1.2, -0.1, //
        -0.05, -0.05, 1.1,
      ];
      graph.nodes[gamma]!.paramValues['gamma'] = 2.4;
      graph.nodes[gamma]!.paramValues['brightness'] = 0.05;
      graph.nodes[gamma]!.paramValues['contrast'] = 1.1;
      graph.connect(wb, 'out', ccm, 'in');
      graph.connect(ccm, 'out', gamma, 'in');
      graph.groups.add(IspNodeGroup('g1', {wb, ccm, gamma}, name: 'pipe'));
      await runAbCompare('wb-ccm-gamma', graph, graph.groups.single,
          sizes: const [(16, 16), (1, 1), (1, 7), (2, 2), (3, 3), (5, 3)],
          maxValues: const [1023, 4095]);
    }, skip: hasMsvc ? false : '无 MSVC 环境');

    test('splitter→combiner 回环支路 + mono 支路 bright_contrast', () async {
      final graph = IspGraph();
      final wb = graph.addNode('white_balance', 0, 0);
      final sp = graph.addNode('rgb_splitter', 0, 0);
      final bc = graph.addNode('bright_contrast_adjuster', 0, 0);
      final cb = graph.addNode('rgb_combiner', 0, 0);
      final gamma = graph.addNode('gamma', 0, 0);
      graph.nodes[wb]!.paramValues['mode'] = 'manual';
      graph.nodes[wb]!.paramValues['rGain'] = 1.3;
      graph.nodes[wb]!.paramValues['bGain'] = 0.7;
      graph.nodes[bc]!.paramValues['bright'] = 110.0;
      graph.nodes[bc]!.paramValues['gain'] = 105.0;
      graph.connect(wb, 'out', sp, 'in');
      graph.connect(sp, 'out_r', cb, 'in_r');
      graph.connect(sp, 'out_g', bc, 'in_mono');
      graph.connect(bc, 'out_mono', cb, 'in_g');
      graph.connect(sp, 'out_b', cb, 'in_b');
      graph.connect(cb, 'out', gamma, 'in');
      graph.groups.add(IspNodeGroup('g2', {wb, sp, bc, cb, gamma}, name: 'sp'));
      await runAbCompare('split-combine', graph, graph.groups.single,
          sizes: const [(16, 16), (2, 2), (5, 3), (1, 1)],
          maxValues: const [1023]);
    }, skip: hasMsvc ? false : '无 MSVC 环境');

    test('bayer 链：black_level→lsc→fluoro_leak→pseudo_color→gamma'
        '（奇偶相位）', () async {
      final graph = IspGraph();
      final bl = graph.addNode('black_level', 0, 0);
      final lsc = graph.addNode('lsc', 0, 0);
      final fl = graph.addNode('fluoro_leak', 0, 0);
      final pc = graph.addNode('pseudo_color', 0, 0);
      final gamma = graph.addNode('gamma', 0, 0);
      graph.nodes[bl]!.paramValues['r'] = 10.0;
      graph.nodes[bl]!.paramValues['gr'] = 12.0;
      graph.nodes[bl]!.paramValues['gb'] = 13.0;
      graph.nodes[bl]!.paramValues['b'] = 14.0;
      graph.nodes[lsc]!.paramValues['strength'] = 0.8;
      graph.nodes[fl]!.paramValues['level'] = 100.0;
      graph.nodes[fl]!.paramValues['maxSub'] = 200.0;
      graph.connect(bl, 'out', lsc, 'in');
      graph.connect(lsc, 'out', fl, 'in_mono');
      graph.connect(fl, 'out_mono', pc, 'in_mono');
      graph.connect(pc, 'out', gamma, 'in');
      graph.groups
          .add(IspNodeGroup('g3', {bl, lsc, fl, pc, gamma}, name: 'raw'));
      await runAbCompare('raw-chain', graph, graph.groups.single,
          sizes: const [(16, 16), (2, 4), (2, 2), (1, 1), (3, 3), (5, 3)],
          maxValues: const [1023, 4095]);
    }, skip: hasMsvc ? false : '无 MSVC 环境');

    test('CSC 长链 + 调节器（rgb2yuv BT.709 有限范围/HSL 往返/debugger）',
        () async {
      final graph = IspGraph();
      final dbg = graph.addNode('rgb_debugger', 0, 0);
      final c2y = graph.addNode('csc_rgb2yuv', 0, 0);
      final ydbg = graph.addNode('yuv_debugger', 0, 0);
      final y2h = graph.addNode('csc_yuv2hsl', 0, 0);
      final hdbg = graph.addNode('hsl_debugger', 0, 0);
      final h2r = graph.addNode('csc_hsl2rgb', 0, 0);
      final sat = graph.addNode('sat_bright_adjuster', 0, 0);
      final ct = graph.addNode('color_temp_adjuster', 0, 0);
      final gamma = graph.addNode('gamma', 0, 0);
      graph.nodes[dbg]!.paramValues['r_gain'] = 1.2;
      graph.nodes[c2y]!.paramValues['standard'] = 'bt709';
      graph.nodes[c2y]!.paramValues['range'] = 'limited';
      graph.nodes[ydbg]!.paramValues['u_gain'] = 1.3;
      graph.nodes[hdbg]!.paramValues['h_shift'] = 45.0;
      graph.nodes[hdbg]!.paramValues['s_gain'] = 1.1;
      graph.nodes[sat]!.paramValues['sat_gain'] = 1.3;
      graph.nodes[sat]!.paramValues['bright_gain'] = 0.9;
      graph.nodes[ct]!.paramValues['temperature'] = 5000.0;
      graph.connect(dbg, 'out', c2y, 'in');
      graph.connect(c2y, 'out', ydbg, 'in');
      graph.connect(ydbg, 'out', y2h, 'in');
      graph.connect(y2h, 'out', hdbg, 'in');
      graph.connect(hdbg, 'out', h2r, 'in');
      graph.connect(h2r, 'out', sat, 'in');
      graph.connect(sat, 'out_rgb', ct, 'in');
      graph.connect(ct, 'out_rgb', gamma, 'in');
      graph.groups.add(IspNodeGroup('g4',
          {dbg, c2y, ydbg, y2h, hdbg, h2r, sat, ct, gamma}, name: 'csc'));
      await runAbCompare('csc-chain', graph, graph.groups.single,
          sizes: const [(16, 16), (5, 3), (1, 1)],
          maxValues: const [1023, 4095]);
    }, skip: hasMsvc ? false : '无 MSVC 环境');

    test('汇合节点：multiplier / adder（mono 双源运算）', () async {
      final graph = IspGraph();
      final wb = graph.addNode('white_balance', 0, 0);
      final sp = graph.addNode('rgb_splitter', 0, 0);
      final mul = graph.addNode('multiplier', 0, 0);
      final add = graph.addNode('adder', 0, 0);
      final cb = graph.addNode('rgb_combiner', 0, 0);
      final gamma = graph.addNode('gamma', 0, 0);
      graph.nodes[wb]!.paramValues['mode'] = 'manual';
      graph.nodes[wb]!.paramValues['rGain'] = 1.2;
      graph.nodes[mul]!.paramValues['offset1'] = 10.0;
      graph.nodes[mul]!.paramValues['offset2'] = 5.0;
      graph.nodes[add]!.paramValues['balance'] = 0.3;
      graph.connect(wb, 'out', sp, 'in');
      graph.connect(sp, 'out_r', mul, 'in_mono');
      graph.connect(sp, 'out_g', mul, 'in_mono2');
      graph.connect(mul, 'out_mono', add, 'in_mono');
      graph.connect(sp, 'out_b', add, 'in_mono2');
      graph.connect(add, 'out_mono', cb, 'in_r');
      graph.connect(sp, 'out_g', cb, 'in_g');
      graph.connect(mul, 'out_mono', cb, 'in_b');
      graph.connect(cb, 'out', gamma, 'in');
      graph.groups.add(
          IspNodeGroup('g5', {wb, sp, mul, add, cb, gamma}, name: 'join'));
      await runAbCompare('join', graph, graph.groups.single,
          sizes: const [(16, 16), (3, 3), (1, 1)], maxValues: const [1023]);
    }, skip: hasMsvc ? false : '无 MSVC 环境');

    test('blender 全连接（整帧版校验要求基图/混叠全部端口已连接）', () async {
      final graph = IspGraph();
      final wb = graph.addNode('white_balance', 0, 0);
      final c2y = graph.addNode('csc_rgb2yuv', 0, 0);
      final c2h = graph.addNode('csc_rgb2hsl', 0, 0);
      final sp = graph.addNode('rgb_splitter', 0, 0);
      final cb = graph.addNode('rgb_combiner', 0, 0);
      final blend = graph.addNode('blender', 0, 0);
      final gamma = graph.addNode('gamma', 0, 0);
      graph.nodes[wb]!.paramValues['mode'] = 'manual';
      graph.nodes[wb]!.paramValues['rGain'] = 1.2;
      graph.nodes[blend]!.paramValues['strength'] = 0.7;
      graph.connect(wb, 'out', c2y, 'in');
      graph.connect(wb, 'out', c2h, 'in');
      graph.connect(wb, 'out', sp, 'in');
      graph.connect(sp, 'out_r', cb, 'in_r');
      graph.connect(sp, 'out_g', cb, 'in_g');
      graph.connect(sp, 'out_b', cb, 'in_b');
      // blender 基图/混叠各为互斥输入组，graph.connect 拒绝同组多端口
      // 连接（UI 语义）；整帧版导出校验要求全部端口已连接，故绕过
      // connect 手动加边（planGroupC 直接读 connections）。
      var connSeq = 0;
      void rawConn(String from, String fromPort, String toPort) {
        graph.connections.add(IspConnection(
            id: 'raw_${connSeq++}',
            fromNodeId: from,
            fromPort: fromPort,
            toNodeId: blend,
            toPort: toPort));
      }

      rawConn(cb, 'out', 'in');
      rawConn(c2y, 'out', 'in_yuv');
      rawConn(c2h, 'out', 'in_hsl');
      rawConn(sp, 'out_r', 'in_mono');
      rawConn(sp, 'out_g', 'in_mask');
      rawConn(wb, 'out', 'in_blend');
      rawConn(c2y, 'out', 'in_blend_yuv');
      rawConn(c2h, 'out', 'in_blend_hsl');
      rawConn(sp, 'out_b', 'in_blend_mono');
      graph.connect(blend, 'out_rgb', gamma, 'in');
      graph.groups.add(IspNodeGroup(
          'g5b', {wb, c2y, c2h, sp, cb, blend, gamma}, name: 'blend'));
      await runAbCompare('blender', graph, graph.groups.single,
          sizes: const [(16, 16), (3, 3)], maxValues: const [1023]);
    }, skip: hasMsvc ? false : '无 MSVC 环境');

    test('mux4 选中支路透传 + 死支路裁剪', () async {
      final graph = IspGraph();
      final wb1 = graph.addNode('white_balance', 0, 0);
      final wb2 = graph.addNode('white_balance', 0, 0);
      final wbDead = graph.addNode('white_balance', 0, 0);
      final ccmDead = graph.addNode('ccm', 0, 0);
      final mux = graph.addNode('mux4', 0, 0);
      final gamma = graph.addNode('gamma', 0, 0);
      graph.nodes[wb1]!.name = 'wb1';
      graph.nodes[wb2]!.name = 'wb2';
      graph.nodes[wbDead]!.name = 'wb_dead';
      graph.nodes[wb1]!.paramValues['mode'] = 'manual';
      graph.nodes[wb1]!.paramValues['rGain'] = 1.3;
      graph.nodes[wb2]!.paramValues['mode'] = 'manual';
      graph.nodes[wb2]!.paramValues['bGain'] = 0.6;
      graph.nodes[wbDead]!.paramValues['mode'] = 'manual';
      graph.nodes[mux]!.paramValues['select'] = 2;
      graph.connect(wb1, 'out', mux, 'in1');
      graph.connect(wb2, 'out', mux, 'in2');
      graph.connect(wbDead, 'out', ccmDead, 'in');
      graph.connect(ccmDead, 'out', mux, 'in3');
      graph.connect(mux, 'out_rgb', gamma, 'in');
      graph.groups.add(
          IspNodeGroup('g6', {wb1, wb2, wbDead, ccmDead, mux, gamma},
              name: 'mux'));
      await runAbCompare('mux4', graph, graph.groups.single,
          sizes: const [(16, 16), (2, 2)], maxValues: const [1023]);
    }, skip: hasMsvc ? false : '无 MSVC 环境');

    test('combiner 缺省通道（rgb 缺省 0 / yuv 缺省 mid）', () async {
      // 未连接的通道端口：首要端口成为外部输入，次要端口填缺省常量
      //（整帧版传 NULL 由 c_ref 填同一缺省值）。
      final graph = IspGraph();
      final cb = graph.addNode('rgb_combiner', 0, 0);
      final gamma = graph.addNode('gamma', 0, 0);
      graph.connect(cb, 'out', gamma, 'in'); // in_r 外部输入，in_g/in_b 缺省
      graph.groups.add(IspNodeGroup('g7', {cb, gamma}, name: 'cb0'));
      await runAbCompare('combiner-default', graph, graph.groups.single,
          sizes: const [(8, 8), (1, 1), (3, 3)], maxValues: const [1023]);
    }, skip: hasMsvc ? false : '无 MSVC 环境');

    test('yuv_combiner 缺省 U/V（mid）经 csc_yuv2rgb 出图', () async {
      final graph = IspGraph();
      final cb = graph.addNode('yuv_combiner', 0, 0);
      final csc = graph.addNode('csc_yuv2rgb', 0, 0);
      final gamma = graph.addNode('gamma', 0, 0);
      graph.connect(cb, 'out', csc, 'in'); // in_y 外部输入，in_u/in_v 缺省 mid
      graph.connect(csc, 'out', gamma, 'in');
      graph.groups.add(IspNodeGroup('g7b', {cb, csc, gamma}, name: 'cbm'));
      await runAbCompare('combiner-yuv-default', graph, graph.groups.single,
          sizes: const [(8, 8), (1, 1)], maxValues: const [1023]);
    }, skip: hasMsvc ? false : '无 MSVC 环境');

    test('LUT 模式综合长链（查表路径 + 回退直算路径）', () async {
      final graph = IspGraph();
      String add(String typeId, Map<String, Object?> params) {
        final id = graph.addNode(typeId, 0, 0);
        graph.nodes[id]!.paramValues.addAll(params);
        return id;
      }

      final wb = add('white_balance',
          {'codegenMode': 'lut', 'mode': 'manual', 'rGain': 1.3, 'bGain': 0.7});
      final r2h = add('csc_rgb2hsl', {});
      final cc = add('color_controller',
          {'codegenMode': 'lut', 'h_center': 120.0, 'q': 4.0, 'h_shift': 30.0, 's_gain': 1.2, 'l_gain': 0.9});
      final h2r = add('csc_hsl2rgb', {});
      final bc = add('bright_contrast_adjuster',
          {'codegenMode': 'lut', 'bright': 120.0, 'baseline': 50.0, 'gain': 110.0});
      final lv = add('levels_curves', {'curveMode': 'gamma', 'gamma': 2.2});
      final ct = add('color_temp_adjuster',
          {'codegenMode': 'lut', 'temperature': 4500.0});
      final gamma = add('gamma', {});
      graph.connect(wb, 'out', r2h, 'in');
      graph.connect(r2h, 'out', cc, 'in');
      graph.connect(cc, 'out', h2r, 'in');
      graph.connect(h2r, 'out', bc, 'in');
      graph.connect(bc, 'out_rgb', lv, 'in');
      graph.connect(lv, 'out', ct, 'in');
      graph.connect(ct, 'out_rgb', gamma, 'in');
      graph.groups.add(IspNodeGroup(
          'g8', {wb, r2h, cc, h2r, bc, lv, ct, gamma}, name: 'lut'));
      await runAbCompare('lut-chain', graph, graph.groups.single,
          sizes: const [(16, 16), (3, 3)],
          maxValues: const [1023, 4095]); // 1023=查表；4095=回退直算
    }, skip: hasMsvc ? false : '无 MSVC 环境');

    test('multi_band_eq 串联三段（含恒等段）行核对拍', () async {
      final graph = IspGraph();
      String add(String typeId, [Map<String, Object?> p = const {}]) {
        final id = graph.addNode(typeId, 0, 0);
        graph.nodes[id]!.paramValues.addAll(p);
        return id;
      }

      final r2h = add('csc_rgb2hsl');
      final mb = add('multi_band_eq', {
        'band_count': 3,
        'band_mode': 'serial',
        'b0_h': 30.0, 'b0_q': 0.5, 'b0_dh': 45.0, 'b0_s': 1.3, 'b0_l': 1.1,
        'b1_h': 150.0, 'b1_q': 2.0, 'b1_dh': -70.0, 'b1_s': 0.8,
        // b2 全缺省 → 恒等段（串联级联中无贡献，锻炼缺键回退口径）。
      });
      final h2r = add('csc_hsl2rgb');
      final gamma = add('gamma');
      graph.connect(r2h, 'out', mb, 'in');
      graph.connect(mb, 'out', h2r, 'in');
      graph.connect(h2r, 'out', gamma, 'in');
      graph.groups.add(
          IspNodeGroup('g_mbs', {r2h, mb, h2r, gamma}, name: 'mbs'));
      await runAbCompare('mb-serial', graph, graph.groups.single,
          sizes: const [(16, 16), (3, 3)],
          maxValues: const [1023, 4095]);
    }, skip: hasMsvc ? false : '无 MSVC 环境');

    test('multi_band_eq 并联两段 LUT 模式（查表 + 回退直算）行核对拍', () async {
      final graph = IspGraph();
      String add(String typeId, [Map<String, Object?> p = const {}]) {
        final id = graph.addNode(typeId, 0, 0);
        graph.nodes[id]!.paramValues.addAll(p);
        return id;
      }

      final r2h = add('csc_rgb2hsl');
      final mb = add('multi_band_eq', {
        'band_count': 2,
        'band_mode': 'parallel',
        'codegenMode': 'lut',
        'b0_h': 0.0, 'b0_q': 2.0, 'b0_dh': 90.0,
        'b1_h': 90.0, 'b1_q': 2.0, 'b1_dh': 90.0, 'b1_s': 2.0,
      });
      final h2r = add('csc_hsl2rgb');
      final gamma = add('gamma');
      graph.connect(r2h, 'out', mb, 'in');
      graph.connect(mb, 'out', h2r, 'in');
      graph.connect(h2r, 'out', gamma, 'in');
      graph.groups.add(
          IspNodeGroup('g_mbp', {r2h, mb, h2r, gamma}, name: 'mbp'));
      await runAbCompare('mb-parallel-lut', graph, graph.groups.single,
          sizes: const [(16, 16), (3, 3)],
          maxValues: const [1023, 4095]); // 1023=查表；4095=回退直算
    }, skip: hasMsvc ? false : '无 MSVC 环境');

    test('HSL 域 color_balance（逐像素往返）+ sat_bright HSL 形态', () async {
      final graph = IspGraph();
      final r2h = graph.addNode('csc_rgb2hsl', 0, 0);
      final bal = graph.addNode('color_balance', 0, 0);
      final sat = graph.addNode('sat_bright_adjuster', 0, 0);
      final h2r = graph.addNode('csc_hsl2rgb', 0, 0);
      final gamma = graph.addNode('gamma', 0, 0);
      graph.nodes[bal]!.paramValues['cyan_red'] = 20.0;
      graph.nodes[bal]!.paramValues['magenta_green'] = -10.0;
      graph.nodes[bal]!.paramValues['yellow_blue'] = 15.0;
      graph.nodes[sat]!.paramValues['sat_gain'] = 1.3;
      graph.nodes[sat]!.paramValues['bright_gain'] = 0.85;
      graph.connect(r2h, 'out', bal, 'in_hsl');
      graph.connect(bal, 'out_hsl', sat, 'in_hsl');
      graph.connect(sat, 'out_hsl', h2r, 'in');
      graph.connect(h2r, 'out', gamma, 'in');
      graph.groups
          .add(IspNodeGroup('g9', {r2h, bal, sat, h2r, gamma}, name: 'hsl'));
      await runAbCompare('hsl-balance', graph, graph.groups.single,
          sizes: const [(16, 16), (5, 3)],
          maxValues: const [1023, 4095]);
    }, skip: hasMsvc ? false : '无 MSVC 环境');

    test('扇出流物化：wb.out 同时出组与供组内 splitter', () async {
      final graph = IspGraph();
      final wb = graph.addNode('white_balance', 0, 0);
      final sp = graph.addNode('rgb_splitter', 0, 0);
      final cb = graph.addNode('rgb_combiner', 0, 0);
      final gamma = graph.addNode('gamma', 0, 0);
      final outside = graph.addNode('rgb_debugger', 0, 0);
      graph.nodes[wb]!.paramValues['mode'] = 'manual';
      graph.nodes[wb]!.paramValues['rGain'] = 1.3;
      graph.nodes[wb]!.paramValues['bGain'] = 0.7;
      graph.connect(wb, 'out', sp, 'in');
      graph.connect(wb, 'out', outside, 'in'); // 组外 → 外部输出 + 扇出
      graph.connect(sp, 'out_r', cb, 'in_r');
      graph.connect(sp, 'out_g', cb, 'in_g');
      graph.connect(sp, 'out_b', cb, 'in_b');
      graph.connect(cb, 'out', gamma, 'in');
      graph.groups.add(IspNodeGroup('g10', {wb, sp, cb, gamma}, name: 'fan'));
      await runAbCompare('fanout', graph, graph.groups.single,
          sizes: const [(16, 16), (3, 3), (1, 1)],
          maxValues: const [1023, 4095]);
    }, skip: hasMsvc ? false : '无 MSVC 环境');

    test('窗口节点：WB→sharpen→Gamma（延迟 + 尾部冲刷 + 边界尺寸）', () async {
      final graph = IspGraph();
      final wb = graph.addNode('white_balance', 0, 0);
      final sh = graph.addNode('sharpen', 0, 0);
      final gamma = graph.addNode('gamma', 0, 0);
      graph.nodes[wb]!.paramValues['mode'] = 'manual';
      graph.nodes[wb]!.paramValues['rGain'] = 1.3;
      graph.nodes[sh]!.paramValues['amount'] = 0.8;
      graph.nodes[sh]!.paramValues['threshold'] = 5.0;
      graph.connect(wb, 'out', sh, 'in');
      graph.connect(sh, 'out', gamma, 'in');
      graph.groups.add(IspNodeGroup('w1', {wb, sh, gamma}, name: 'shp'));
      await runAbCompare('wb-sharpen-gamma', graph, graph.groups.single,
          sizes: const [
            (16, 16), (3, 3), (2, 2), (1, 1), (5, 3), (2, 4), (4, 2),
          ],
          maxValues: const [1023, 4095]);
    }, skip: hasMsvc ? false : '无 MSVC 环境');

    test('窗口后接点对点：sharpen→rgb_debugger→gamma（延迟后融合继续）',
        () async {
      final graph = IspGraph();
      final sh = graph.addNode('sharpen', 0, 0);
      final dbg = graph.addNode('rgb_debugger', 0, 0);
      final gamma = graph.addNode('gamma', 0, 0);
      graph.nodes[sh]!.paramValues['amount'] = 0.6;
      graph.nodes[dbg]!.paramValues['g_gain'] = 1.2;
      graph.connect(sh, 'out', dbg, 'in');
      graph.connect(dbg, 'out', gamma, 'in');
      graph.groups.add(IspNodeGroup('w2', {sh, dbg, gamma}, name: 'sf'));
      await runAbCompare('sharpen-then-p2p', graph, graph.groups.single,
          sizes: const [(16, 16), (3, 3), (1, 1), (2, 2)],
          maxValues: const [1023]);
    }, skip: hasMsvc ? false : '无 MSVC 环境');

    test('窗口在链首（外部输入整帧寻址）且在链尾（→gamma）', () async {
      final graph = IspGraph();
      final sh = graph.addNode('sharpen', 0, 0);
      final gamma = graph.addNode('gamma', 0, 0);
      graph.nodes[sh]!.paramValues['amount'] = 0.7;
      graph.connect(sh, 'out', gamma, 'in');
      graph.groups.add(IspNodeGroup('w3', {sh, gamma}, name: 'hd'));
      await runAbCompare('sharpen-head-tail', graph, graph.groups.single,
          sizes: const [(16, 16), (3, 3), (2, 2), (1, 1)],
          maxValues: const [1023]);
    }, skip: hasMsvc ? false : '无 MSVC 环境');

    test('延迟均衡：直连支路与 sharpen 支路在 blender 汇合（FIFO）',
        () async {
      final graph = IspGraph();
      final wb = graph.addNode('white_balance', 0, 0);
      final sh = graph.addNode('sharpen', 0, 0);
      final c2y = graph.addNode('csc_rgb2yuv', 0, 0);
      final c2h = graph.addNode('csc_rgb2hsl', 0, 0);
      final sp = graph.addNode('rgb_splitter', 0, 0);
      final blend = graph.addNode('blender', 0, 0);
      final gamma = graph.addNode('gamma', 0, 0);
      graph.nodes[wb]!.paramValues['mode'] = 'manual';
      graph.nodes[wb]!.paramValues['rGain'] = 1.2;
      graph.nodes[sh]!.paramValues['amount'] = 0.7;
      graph.nodes[blend]!.paramValues['strength'] = 0.6;
      graph.connect(wb, 'out', sh, 'in'); // 支路 B（延迟 1）
      graph.connect(wb, 'out', c2y, 'in');
      graph.connect(wb, 'out', c2h, 'in');
      graph.connect(wb, 'out', sp, 'in');
      graph.connect(blend, 'out_rgb', gamma, 'in');
      // blender 互斥输入组绕过 connect 手动加边（见前述 blender 用例）。
      var connSeq = 0;
      void rawConn(String from, String fromPort, String toPort) {
        graph.connections.add(IspConnection(
            id: 'raw_${connSeq++}',
            fromNodeId: from,
            fromPort: fromPort,
            toNodeId: blend,
            toPort: toPort));
      }

      rawConn(sh, 'out', 'in'); // 基图：延迟 1
      rawConn(c2y, 'out', 'in_yuv');
      rawConn(c2h, 'out', 'in_hsl');
      rawConn(sp, 'out_r', 'in_mono');
      rawConn(sp, 'out_g', 'in_mask'); // 蒙版：延迟 0 → FIFO(2 行)
      rawConn(wb, 'out', 'in_blend'); // 混叠图：延迟 0 → FIFO(2 行)
      rawConn(c2y, 'out', 'in_blend_yuv');
      rawConn(c2h, 'out', 'in_blend_hsl');
      rawConn(sp, 'out_b', 'in_blend_mono');
      graph.groups.add(IspNodeGroup(
          'w4', {wb, sh, c2y, c2h, sp, blend, gamma}, name: 'bal'));
      await runAbCompare('delay-balance', graph, graph.groups.single,
          sizes: const [(16, 16), (3, 3), (2, 2), (5, 3)],
          maxValues: const [1023]);
    }, skip: hasMsvc ? false : '无 MSVC 环境');

    test('demosaic(bilinear) 起头的 Bayer 全链（奇偶相位）', () async {
      final graph = IspGraph();
      final bl = graph.addNode('black_level', 0, 0);
      final dm = graph.addNode('demosaic', 0, 0);
      final wb = graph.addNode('white_balance', 0, 0);
      final ccm = graph.addNode('ccm', 0, 0);
      final gamma = graph.addNode('gamma', 0, 0);
      graph.nodes[bl]!.paramValues['r'] = 10.0;
      graph.nodes[bl]!.paramValues['gr'] = 12.0;
      graph.nodes[bl]!.paramValues['gb'] = 13.0;
      graph.nodes[bl]!.paramValues['b'] = 14.0;
      graph.nodes[wb]!.paramValues['mode'] = 'manual';
      graph.nodes[wb]!.paramValues['rGain'] = 1.3;
      graph.nodes[wb]!.paramValues['bGain'] = 0.7;
      graph.nodes[ccm]!.paramValues['matrix'] = [
        1.1, -0.05, -0.05, //
        -0.1, 1.2, -0.1, //
        -0.05, -0.05, 1.1,
      ];
      graph.connect(bl, 'out', dm, 'in');
      graph.connect(dm, 'out', wb, 'in');
      graph.connect(wb, 'out', ccm, 'in');
      graph.connect(ccm, 'out', gamma, 'in');
      graph.groups.add(IspNodeGroup('w5', {bl, dm, wb, ccm, gamma}, name: 'bayer'));
      await runAbCompare('demosaic-bayer-chain', graph, graph.groups.single,
          sizes: const [(16, 16), (2, 2), (2, 4), (3, 3), (5, 3), (1, 1), (1, 7)],
          maxValues: const [1023, 4095]);
    }, skip: hasMsvc ? false : '无 MSVC 环境');

    test('dpc（原地语义，Bayer 半径 2）→ demosaic 链', () async {
      final graph = IspGraph();
      final dpc = graph.addNode('dpc', 0, 0);
      final dm = graph.addNode('demosaic', 0, 0);
      final gamma = graph.addNode('gamma', 0, 0);
      graph.nodes[dpc]!.paramValues['threshold'] = 8.0;
      graph.connect(dpc, 'out', dm, 'in');
      graph.connect(dm, 'out', gamma, 'in');
      graph.groups.add(IspNodeGroup('w6', {dpc, dm, gamma}, name: 'dpc'));
      await runAbCompare('dpc-demosaic', graph, graph.groups.single,
          sizes: const [(16, 16), (2, 2), (3, 3), (5, 3), (2, 4), (1, 1)],
          maxValues: const [1023]);
    }, skip: hasMsvc ? false : '无 MSVC 环境');

    test('dpc directional + mono 形态（半径 1）', () async {
      final graph = IspGraph();
      final fl = graph.addNode('fluoro_leak', 0, 0);
      final dpc = graph.addNode('dpc', 0, 0);
      final pc = graph.addNode('pseudo_color', 0, 0);
      final gamma = graph.addNode('gamma', 0, 0);
      graph.nodes[fl]!.paramValues['level'] = 60.0;
      graph.nodes[fl]!.paramValues['maxSub'] = 200.0;
      graph.nodes[dpc]!.paramValues['threshold'] = 6.0;
      graph.nodes[dpc]!.paramValues['mode'] = 'directional';
      graph.connect(fl, 'out_mono', dpc, 'in_mono');
      graph.connect(dpc, 'out_mono', pc, 'in_mono');
      graph.connect(pc, 'out', gamma, 'in');
      graph.groups.add(IspNodeGroup('w6b', {fl, dpc, pc, gamma}, name: 'dpcm'));
      await runAbCompare('dpc-mono-directional', graph, graph.groups.single,
          sizes: const [(16, 16), (3, 3), (2, 2), (1, 1)],
          maxValues: const [1023]);
    }, skip: hasMsvc ? false : '无 MSVC 环境');

    test('rgb_dnr → edge_extract（双输出）→ gamma', () async {
      final graph = IspGraph();
      final dnr = graph.addNode('rgb_dnr', 0, 0);
      final edge = graph.addNode('edge_extract', 0, 0);
      final gamma = graph.addNode('gamma', 0, 0);
      final outside = graph.addNode('pseudo_color', 0, 0);
      graph.nodes[dnr]!.paramValues['luma'] = 0.7;
      graph.nodes[dnr]!.paramValues['chroma'] = 0.5;
      graph.nodes[edge]!.paramValues['gain'] = 2.0;
      graph.nodes[edge]!.paramValues['threshold'] = 30.0;
      graph.connect(dnr, 'out', edge, 'in');
      graph.connect(edge, 'out_rgb', gamma, 'in');
      // out_mono 连到组外 → 暴露为第二外部输出（整帧版尾节点语义要求
      // 组内多出端口全部暴露或全部成边）。
      graph.connect(edge, 'out_mono', outside, 'in_mono');
      graph.groups.add(IspNodeGroup('w7', {dnr, edge, gamma}, name: 'dnr'));
      await runAbCompare('rgbdnr-edge', graph, graph.groups.single,
          sizes: const [(16, 16), (3, 3), (2, 2), (1, 1), (5, 3)],
          maxValues: const [1023, 4095]);
    }, skip: hasMsvc ? false : '无 MSVC 环境');

    test('bayer_dnr（半径 2）→ highlight(recover) → demosaic → gamma',
        () async {
      final graph = IspGraph();
      final dnr = graph.addNode('bayer_dnr', 0, 0);
      final hl = graph.addNode('highlight', 0, 0);
      final dm = graph.addNode('demosaic', 0, 0);
      final gamma = graph.addNode('gamma', 0, 0);
      graph.nodes[dnr]!.paramValues['strength'] = 0.6;
      graph.nodes[hl]!.paramValues['mode'] = 'recover';
      graph.nodes[hl]!.paramValues['knee'] = 0.85;
      graph.connect(dnr, 'out', hl, 'in');
      graph.connect(hl, 'out', dm, 'in');
      graph.connect(dm, 'out', gamma, 'in');
      graph.groups.add(IspNodeGroup('w8', {dnr, hl, dm, gamma}, name: 'bdnr'));
      await runAbCompare('bayerdnr-highlight', graph, graph.groups.single,
          sizes: const [(16, 16), (2, 2), (3, 3), (5, 3), (2, 4)],
          maxValues: const [1023]);
    }, skip: hasMsvc ? false : '无 MSVC 环境');

    test('highlight clip（纯逐像素形态）→ gamma', () async {
      final graph = IspGraph();
      final bl = graph.addNode('black_level', 0, 0);
      final hl = graph.addNode('highlight', 0, 0);
      final dm = graph.addNode('demosaic', 0, 0);
      final gamma = graph.addNode('gamma', 0, 0);
      graph.nodes[bl]!.paramValues['r'] = 8.0;
      graph.nodes[hl]!.paramValues['mode'] = 'clip';
      graph.nodes[hl]!.paramValues['knee'] = 0.8;
      graph.connect(bl, 'out', hl, 'in');
      graph.connect(hl, 'out', dm, 'in');
      graph.connect(dm, 'out', gamma, 'in');
      graph.groups.add(IspNodeGroup('w9', {bl, hl, dm, gamma}, name: 'clip'));
      await runAbCompare('highlight-clip', graph, graph.groups.single,
          sizes: const [(16, 16), (3, 3), (2, 2)],
          maxValues: const [1023, 4095]);
    }, skip: hasMsvc ? false : '无 MSVC 环境');

    test('morphology：腐蚀/膨胀 × 不同半径（rgb 与 mono 形态）', () async {
      // 腐蚀 r=1（rgb）→ 膨胀 r=2（rgb）串联。
      final graph = IspGraph();
      final er = graph.addNode('morphology', 0, 0);
      final di = graph.addNode('morphology', 0, 0);
      final gamma = graph.addNode('gamma', 0, 0);
      graph.nodes[er]!.paramValues['mode'] = 'erode';
      graph.nodes[er]!.paramValues['radius'] = 1;
      graph.nodes[di]!.paramValues['mode'] = 'dilate';
      graph.nodes[di]!.paramValues['radius'] = 2;
      graph.connect(er, 'out', di, 'in');
      graph.connect(di, 'out', gamma, 'in');
      graph.groups.add(IspNodeGroup('s1', {er, di, gamma}, name: 'morph'));
      await runAbCompare('morph-rgb', graph, graph.groups.single,
          sizes: const [(16, 16), (3, 3), (2, 2), (1, 1), (4, 4), (5, 3)],
          maxValues: const [1023]);
    }, skip: hasMsvc ? false : '无 MSVC 环境');

    test('morphology mono 形态 r=3（h ≤ 2r 小图）', () async {
      final graph = IspGraph();
      final fl = graph.addNode('fluoro_leak', 0, 0);
      final mo = graph.addNode('morphology', 0, 0);
      final pc = graph.addNode('pseudo_color', 0, 0);
      final gamma = graph.addNode('gamma', 0, 0);
      graph.nodes[fl]!.paramValues['level'] = 60.0;
      graph.nodes[fl]!.paramValues['maxSub'] = 200.0;
      graph.nodes[mo]!.paramValues['mode'] = 'dilate';
      graph.nodes[mo]!.paramValues['radius'] = 3;
      graph.connect(fl, 'out_mono', mo, 'in_mono');
      graph.connect(mo, 'out_mono', pc, 'in_mono');
      graph.connect(pc, 'out', gamma, 'in');
      graph.groups.add(IspNodeGroup('s2', {fl, mo, pc, gamma}, name: 'morm'));
      await runAbCompare('morph-mono-r3', graph, graph.groups.single,
          sizes: const [(16, 16), (4, 4), (3, 3), (2, 2), (1, 1)],
          maxValues: const [1023]);
    }, skip: hasMsvc ? false : '无 MSVC 环境');

    test('gaussian_blur：σ=1（r=3）与 σ=2.5（r=8，h ≤ 2r 小图）', () async {
      final graph = IspGraph();
      final wb = graph.addNode('white_balance', 0, 0);
      final g1 = graph.addNode('gaussian_blur', 0, 0);
      final g2 = graph.addNode('gaussian_blur', 0, 0);
      final gamma = graph.addNode('gamma', 0, 0);
      graph.nodes[wb]!.paramValues['mode'] = 'manual';
      graph.nodes[wb]!.paramValues['rGain'] = 1.2;
      graph.nodes[g1]!.paramValues['sigma'] = 1.0;
      graph.nodes[g1]!.paramValues['strength'] = 0.8;
      graph.nodes[g2]!.paramValues['sigma'] = 2.5;
      graph.nodes[g2]!.paramValues['strength'] = 1.0;
      graph.connect(wb, 'out', g1, 'in');
      graph.connect(g1, 'out_rgb', g2, 'in');
      graph.connect(g2, 'out_rgb', gamma, 'in');
      graph.groups.add(IspNodeGroup('s3', {wb, g1, g2, gamma}, name: 'gauss'));
      await runAbCompare('gaussian-chain', graph, graph.groups.single,
          sizes: const [(16, 16), (8, 8), (3, 3), (2, 2), (1, 1), (5, 3)],
          maxValues: const [1023, 4095]);
    }, skip: hasMsvc ? false : '无 MSVC 环境');

    test('gaussian_blur mono 形态 + 派生环与窗口混合链', () async {
      final graph = IspGraph();
      final fl = graph.addNode('fluoro_leak', 0, 0);
      final mo = graph.addNode('morphology', 0, 0);
      final gb = graph.addNode('gaussian_blur', 0, 0);
      final dpc = graph.addNode('dpc', 0, 0);
      final pc = graph.addNode('pseudo_color', 0, 0);
      final gamma = graph.addNode('gamma', 0, 0);
      graph.nodes[fl]!.paramValues['level'] = 60.0;
      graph.nodes[fl]!.paramValues['maxSub'] = 200.0;
      graph.nodes[mo]!.paramValues['mode'] = 'erode';
      graph.nodes[mo]!.paramValues['radius'] = 2;
      graph.nodes[gb]!.paramValues['sigma'] = 0.7;
      graph.nodes[gb]!.paramValues['strength'] = 0.9;
      graph.nodes[dpc]!.paramValues['threshold'] = 6.0;
      graph.connect(fl, 'out_mono', mo, 'in_mono');
      graph.connect(mo, 'out_mono', gb, 'in_mono');
      graph.connect(gb, 'out_mono', dpc, 'in_mono');
      graph.connect(dpc, 'out_mono', pc, 'in_mono');
      graph.connect(pc, 'out', gamma, 'in');
      graph.groups.add(
          IspNodeGroup('s4', {fl, mo, gb, dpc, pc, gamma}, name: 'mixw'));
      await runAbCompare('sep-window-mix', graph, graph.groups.single,
          sizes: const [(16, 16), (4, 4), (3, 3), (2, 2), (1, 1)],
          maxValues: const [1023]);
    }, skip: hasMsvc ? false : '无 MSVC 环境');

    test('分离趟支路与直连支路汇合（morphology r=2 延迟均衡 FIFO）',
        () async {
      final graph = IspGraph();
      final wb = graph.addNode('white_balance', 0, 0);
      final mo = graph.addNode('morphology', 0, 0);
      final c2y = graph.addNode('csc_rgb2yuv', 0, 0);
      final c2h = graph.addNode('csc_rgb2hsl', 0, 0);
      final sp = graph.addNode('rgb_splitter', 0, 0);
      final blend = graph.addNode('blender', 0, 0);
      final gamma = graph.addNode('gamma', 0, 0);
      graph.nodes[wb]!.paramValues['mode'] = 'manual';
      graph.nodes[wb]!.paramValues['rGain'] = 1.2;
      graph.nodes[mo]!.paramValues['mode'] = 'erode';
      graph.nodes[mo]!.paramValues['radius'] = 2;
      graph.nodes[blend]!.paramValues['strength'] = 0.6;
      graph.connect(wb, 'out', mo, 'in'); // 支路 B（延迟 2）
      graph.connect(wb, 'out', c2y, 'in');
      graph.connect(wb, 'out', c2h, 'in');
      graph.connect(wb, 'out', sp, 'in');
      graph.connect(blend, 'out_rgb', gamma, 'in');
      var connSeq = 0;
      void rawConn(String from, String fromPort, String toPort) {
        graph.connections.add(IspConnection(
            id: 'raw_${connSeq++}',
            fromNodeId: from,
            fromPort: fromPort,
            toNodeId: blend,
            toPort: toPort));
      }

      rawConn(mo, 'out', 'in'); // 基图：延迟 2
      rawConn(c2y, 'out', 'in_yuv');
      rawConn(c2h, 'out', 'in_hsl');
      rawConn(sp, 'out_r', 'in_mono');
      rawConn(sp, 'out_g', 'in_mask'); // 蒙版：延迟 0 → FIFO(3 行)
      rawConn(wb, 'out', 'in_blend'); // 混叠图：延迟 0 → FIFO(3 行)
      rawConn(c2y, 'out', 'in_blend_yuv');
      rawConn(c2h, 'out', 'in_blend_hsl');
      rawConn(sp, 'out_b', 'in_blend_mono');
      graph.groups.add(IspNodeGroup(
          's5', {wb, mo, c2y, c2h, sp, blend, gamma}, name: 'sepb'));
      await runAbCompare('sep-delay-balance', graph, graph.groups.single,
          sizes: const [(16, 16), (4, 4), (3, 3), (5, 3)],
          maxValues: const [1023]);
    }, skip: hasMsvc ? false : '无 MSVC 环境');

    test('分离趟 scratch 宏逐项可见（double 环 + 权重核）', () async {
      final graph = IspGraph();
      final gb = graph.addNode('gaussian_blur', 0, 0);
      final mo = graph.addNode('morphology', 0, 0);
      final gamma = graph.addNode('gamma', 0, 0);
      graph.nodes[gb]!.paramValues['sigma'] = 1.0; // r=3 → k_len=7
      graph.nodes[mo]!.paramValues['radius'] = 2;
      graph.connect(gb, 'out_rgb', mo, 'in');
      graph.connect(mo, 'out', gamma, 'in');
      graph.groups.add(IspNodeGroup('s6', {gb, mo, gamma}, name: 'sz'));
      final map = await buildGroupBlackBoxCFiles(graph, graph.groups.single,
          readFile: readDisk, genTime: DateTime(2026, 1, 2, 3, 4, 5));
      final h = map['isp_pipe_sz_bb.h']!;
      // gaussian 输入为外部帧（整帧直寻址，不占环形）；水平趟 double 环
      // 7 行 + 权重核 7 个 double；morphology 输入环（gb.out）uint16 5
      // 行 + 水平趟环 5 行。
      expect(h, contains('(size_t)(w) * 3u * 7u * sizeof(double)'));
      expect(h, contains('(size_t)7u * sizeof(double)'));
      expect(h, contains('(size_t)(w) * 3u * 5u * sizeof(uint16_t)'));
      expect(h, isNot(contains('(size_t)(h)')));
    });
  });
}
