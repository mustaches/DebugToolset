import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/c_compile.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/c_ident.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/group_c_export.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/group_c_export_bb.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/node_c_gen.dart';
import 'package:debug_tool_set/modules/isp_studio/models/isp_graph.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/isp_kernels.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/levels_curve.dart';

void main() {
  /// 从磁盘读真实 c_ref 文件（测试不依赖 rootBundle 资产）。
  Future<String> readDisk(String path) => File(path).readAsString();

  group('C 标识符净化', () {
    test('sanitizeCIdent 基本规则', () {
      expect(sanitizeCIdent('Gamma#1'), 'gamma_1');
      expect(sanitizeCIdent('a__b'), 'a_b');
      expect(sanitizeCIdent('_lead'), 'lead');
      expect(sanitizeCIdent('2abc'), 'n2abc'); // 数字开头补 n
      expect(sanitizeCIdent('编组#1'), 'n1'); // 非 ASCII 剥离后剩数字
      expect(sanitizeCIdent('!!!'), isNull); // 全剥离 → null
    });

    test('uniqueCIdent 冲突去重与回退', () {
      final taken = <String>{};
      expect(uniqueCIdent('Gamma#1', 'node_n1', taken), 'gamma_1');
      expect(uniqueCIdent('gamma 1', 'node_n2', taken), 'gamma_1_2');
      expect(uniqueCIdent('!!!', 'node_n3', taken), 'node_n3');
    });
  });

  group('编组导出校验', () {
    test('含不支持类型时报错并列出节点', () {
      final graph = IspGraph();
      final a = graph.addNode('bayer_source', 0, 0); // Source 类暂不支持
      final b = graph.addNode('gamma', 0, 0);
      graph.groups.add(IspNodeGroup('g1', {a, b}, name: 'g'));

      final error = validateGroupCExport(graph, graph.groups.single);
      expect(error, isNotNull);
      expect(error, contains('暂不支持'));
      expect(error, contains(graph.nodes[a]!.name));
    });

    test('混合可/不可导出 C 的编组同样报错', () {
      final graph = IspGraph();
      final a = graph.addNode('histogram', 0, 0); // PC 侧节点
      final b = graph.addNode('gamma', 0, 0);
      graph.groups.add(IspNodeGroup('g1', {a, b}, name: 'g'));
      expect(validateGroupCExport(graph, graph.groups.single), isNotNull);
    });

    test('单节点编组：多段色彩均衡器与整行行核类型放行，其余拒绝', () async {
      final graph = IspGraph();
      final eq = graph.addNode('multi_band_eq', 0, 0);
      graph.nodes[eq]!.name = 'mb';
      graph.groups.add(IspNodeGroup('g1', {eq}, name: 'eq'));
      expect(validateGroupCExport(graph, graph.groups.single), isNull);

      // 单节点编组可完整导出：节点封装 + top 层 + c_ref 并集。
      final map = await buildGroupCFiles(graph, graph.groups.single,
          readFile: readDisk, genTime: DateTime(2026, 1, 2, 3, 4, 5));
      expect(map.keys, containsAll(['mb.h', 'mb.c',
          'isp_pipeline_eq.h', 'isp_pipeline_eq.c',
          'isp_multi_band_eq.h', 'isp_multi_band_eq.c']));

      // 有整行行核的类型（csc_rgb2yuv）同样放行。
      final graph3 = IspGraph();
      final csc = graph3.addNode('csc_rgb2yuv', 0, 0);
      graph3.groups.add(IspNodeGroup('g1', {csc}, name: 'c2y'));
      expect(validateGroupCExport(graph3, graph3.groups.single), isNull);

      // 其它类型单节点仍拒绝（rgb_debugger 无整行行核）。
      final graph2 = IspGraph();
      final g = graph2.addNode('rgb_debugger', 0, 0);
      graph2.groups.add(IspNodeGroup('g1', {g}, name: 'g'));
      expect(validateGroupCExport(graph2, graph2.groups.single),
          contains('不足'));
    });

    test('multiplier 双输入未接全时报错', () {
      final graph = IspGraph();
      final f = graph.addNode('fluoro_leak', 0, 0);
      final m = graph.addNode('multiplier', 0, 0);
      expect(graph.connect(f, 'out_mono', m, 'in_mono'), isNull);
      graph.groups.add(IspNodeGroup('g1', {f, m}, name: 'g'));

      final error = validateGroupCExport(graph, graph.groups.single);
      expect(error, contains('未连接'));
      // 接全后通过。
      expect(graph.connect(f, 'out_mono', m, 'in_mono2'), isNull);
      expect(validateGroupCExport(graph, graph.groups.single), isNull);
    });

    test('mux4 选中支路未连接时报错', () {
      final graph = IspGraph();
      final a = graph.addNode('rgb_debugger', 0, 0);
      final m = graph.addNode('mux4', 0, 0);
      graph.nodes[m]!.paramValues['select'] = 2; // 选中第 2 路，但未连接
      expect(graph.connect(a, 'out', m, 'in1'), isNull); // 只接第 1 路
      graph.groups.add(IspNodeGroup('g1', {a, m}, name: 'g'));

      final error = validateGroupCExport(graph, graph.groups.single);
      expect(error, contains('第 2 路'));
      // 接上第 2 路后通过。
      expect(graph.connect(a, 'out', m, 'in2'), isNull);
      expect(validateGroupCExport(graph, graph.groups.single), isNull);
    });
  });

  group('编组导出生成物', () {
    test('buildGroupCFiles 与 exportGroupCCode 写盘结果一致', () async {
      final graph = IspGraph();
      final wb = graph.addNode('white_balance', 0, 0);
      final ccm = graph.addNode('ccm', 0, 0);
      final gamma = graph.addNode('gamma', 0, 0);
      graph.nodes[wb]!.name = 'wb';
      graph.nodes[ccm]!.name = 'ccm';
      graph.nodes[gamma]!.name = 'gamma';
      expect(graph.connect(wb, 'out', ccm, 'in'), isNull);
      expect(graph.connect(ccm, 'out', gamma, 'in'), isNull);
      graph.groups.add(IspNodeGroup('g1', {wb, ccm, gamma}, name: 'pipe'));

      // 两次调用注入同一固定时间戳，保证文件头注释逐字节一致。
      final genTime = DateTime(2026, 1, 2, 3, 4, 5);
      final map = await buildGroupCFiles(graph, graph.groups.single,
          readFile: readDisk, genTime: genTime);
      // 导出物不含编译 stub main.c（main.c 仅供查看代码页「临时main调用（不导出）」
      // 分组展示与编译临时目录使用）。
      expect(map.keys, isNot(contains('main.c')));
      // 节点封装（拓扑序）在最前，随后是 top 层，最后是 c_ref 并集。
      expect(
          map.keys.take(8).toList(),
          equals([
            'wb.h', 'wb.c', 'ccm.h', 'ccm.c', 'gamma.h', 'gamma.c',
            'isp_pipeline_pipe.h', 'isp_pipeline_pipe.c',
          ]));
      for (final f in [
        'isp_common.h', 'isp_common.c',
        'isp_white_balance.h', 'isp_white_balance.c',
        'isp_ccm.h', 'isp_ccm.c', 'isp_gamma.h', 'isp_gamma.c',
      ]) {
        expect(map.containsKey(f), isTrue, reason: f);
      }
      // 微架构说明随整帧版一并导出，且注明「整帧版为标量参考实现」。
      expect(map.containsKey('cortex_a53_55_code_micro.md'), isTrue);
      expect(map['cortex_a53_55_code_micro.md'],
          contains('整帧版'));

      // 生成的 .h/.c（节点封装 + top 层）顶部带自动生成块注释与生成时间；
      // c_ref 算法参考文件原样拷贝，不含自动生成注释。
      for (final f in map.keys.take(8)) {
        expect(map[f], startsWith('/* 本文件由 DebugToolSet ISP Studio 自动生成'),
            reason: f);
        expect(map[f], contains('生成时间：2026-01-02 03:04:05'), reason: f);
      }
      for (final f in map.keys.skip(8)) {
        // 微架构说明 .md 是生成物（含「自动生成」），c_ref 算法文件原样
        // 拷贝（不含）。
        if (f.endsWith('.md')) continue;
        expect(map[f], isNot(contains('自动生成')), reason: f);
      }

      final dir = await Directory.systemTemp.createTemp('isp_grp_export_');
      addTearDown(() => dir.delete(recursive: true));
      final result = await exportGroupCCode(
          graph, graph.groups.single, dir.path,
          readFile: readDisk, genTime: genTime);

      // 文件集合与顺序一致、内容逐文件一致。
      expect(result.topName, 'isp_pipeline_pipe');
      expect(result.files, map.keys.toList());
      for (final e in map.entries) {
        expect(await File('${dir.path}/${e.key}').readAsString(), e.value,
            reason: e.key);
      }
    });

    test('白平衡→CCM→Gamma 链：文件清单/宏烘焙/拓扑序/外部端口', () async {
      final graph = IspGraph();
      final wb = graph.addNode('white_balance', 0, 0);
      final ccm = graph.addNode('ccm', 0, 0);
      final gamma = graph.addNode('gamma', 0, 0);
      graph.nodes[wb]!.name = 'wb';
      graph.nodes[ccm]!.name = 'ccm';
      graph.nodes[gamma]!.name = 'gamma';
      expect(graph.connect(wb, 'out', ccm, 'in'), isNull);
      expect(graph.connect(ccm, 'out', gamma, 'in'), isNull);
      graph.groups.add(IspNodeGroup('g1', {wb, ccm, gamma}, name: 'pipe'));

      final dir = await Directory.systemTemp.createTemp('isp_grp_export_');
      addTearDown(() => dir.delete(recursive: true));
      final result = await exportGroupCCode(
          graph, graph.groups.single, dir.path,
          readFile: readDisk);

      expect(result.topName, 'isp_pipeline_pipe');
      for (final f in [
        'wb.h', 'wb.c', 'ccm.h', 'ccm.c', 'gamma.h', 'gamma.c',
        'isp_pipeline_pipe.h', 'isp_pipeline_pipe.c',
        'isp_common.h', 'isp_common.c',
        'isp_white_balance.h', 'isp_white_balance.c',
        'isp_ccm.h', 'isp_ccm.c', 'isp_gamma.h', 'isp_gamma.c',
      ]) {
        expect(File('${dir.path}/$f').existsSync(), isTrue, reason: f);
      }

      // gamma 参数烘焙（默认值）+ scratch 宏。
      final gammaH = await File('${dir.path}/gamma.h').readAsString();
      expect(gammaH, contains('#define ISP_GAMMA_GAMMA 2.2'));
      expect(gammaH, contains('ISP_GAMMA_SCRATCH_BYTES'));

      // ccm 矩阵烘焙为 static const 数组。
      final ccmC = await File('${dir.path}/ccm.c').readAsString();
      expect(ccmC, contains('static const double ccm_matrix[9]'));

      final topH =
          await File('${dir.path}/isp_pipeline_pipe.h').readAsString();
      final topC =
          await File('${dir.path}/isp_pipeline_pipe.c').readAsString();

      // 外部端口：wb 无上游 → const uint16_t *in0；gamma rgba → uint8_t。
      expect(topH, contains('const uint16_t *in0'));
      expect(topH, contains('uint8_t *out0'));
      expect(topH, contains('ISP_PIPELINE_PIPE_SCRATCH_BYTES'));

      // 拓扑序：wb → ccm → gamma；边缓冲 e0/e1 串联。
      expect(topC, contains('wb_run(in0, w, h, max_value, e0)'));
      expect(topC, contains('ccm_run(e0, w, h, max_value, e1)'));
      expect(
          topC, contains('gamma_run(e1, w, h, max_value, out0, node_scratch)'));
      expect(topC.indexOf('wb_run('), lessThan(topC.indexOf('ccm_run(')));
      expect(
          topC.indexOf('ccm_run('), lessThan(topC.indexOf('gamma_run(')));
    });

    test('分路→合路回环：边缓冲按生产者端口一一对应', () async {
      final graph = IspGraph();
      final s = graph.addNode('rgb_splitter', 0, 0);
      final c = graph.addNode('rgb_combiner', 0, 0);
      graph.nodes[s]!.name = 'split';
      graph.nodes[c]!.name = 'comb';
      expect(graph.connect(s, 'out_r', c, 'in_r'), isNull);
      expect(graph.connect(s, 'out_g', c, 'in_g'), isNull);
      expect(graph.connect(s, 'out_b', c, 'in_b'), isNull);
      graph.groups.add(IspNodeGroup('g1', {s, c}, name: 'loop'));

      final dir = await Directory.systemTemp.createTemp('isp_grp_export_');
      addTearDown(() => dir.delete(recursive: true));
      await exportGroupCCode(graph, graph.groups.single, dir.path,
          readFile: readDisk);

      final topC =
          await File('${dir.path}/isp_pipeline_loop.c').readAsString();
      // splitter 三输出各写一条边；combiner 按同序读回。
      expect(topC,
          contains('split_run(in0, w, h, max_value, e0, e1, e2)'));
      expect(topC,
          contains('comb_run(e0, e1, e2, w, h, max_value, out0)'));
    });

    test('格式推导：yuv 输入的 sat_bright 烘焙 YUV 格式宏', () async {
      final graph = IspGraph();
      final y = graph.addNode('yuv_debugger', 0, 0);
      final s = graph.addNode('sat_bright_adjuster', 0, 0);
      graph.nodes[s]!.name = 'sat';
      expect(graph.connect(y, 'out', s, 'in_yuv'), isNull);
      graph.groups.add(IspNodeGroup('g1', {y, s}, name: 'fmt'));

      final dir = await Directory.systemTemp.createTemp('isp_grp_export_');
      addTearDown(() => dir.delete(recursive: true));
      await exportGroupCCode(graph, graph.groups.single, dir.path,
          readFile: readDisk);

      final satH = await File('${dir.path}/sat.h').readAsString();
      expect(satH, contains('ISP_ADJ_FMT_YUV'));
      expect(satH, contains('*in_yuv'));
    });

    test('ColorTrans：csc_rgb2yuv 烘焙标准/范围枚举并生成转换调用', () async {
      final graph = IspGraph();
      final a = graph.addNode('csc_rgb2yuv', 0, 0);
      final b = graph.addNode('csc_yuv2hsl', 0, 0);
      graph.nodes[a]!.name = 'to_yuv';
      graph.nodes[b]!.name = 'to_hsl';
      expect(graph.connect(a, 'out', b, 'in'), isNull);
      graph.groups.add(IspNodeGroup('g1', {a, b}, name: 'csc'));

      final dir = await Directory.systemTemp.createTemp('isp_grp_export_');
      addTearDown(() => dir.delete(recursive: true));
      await exportGroupCCode(graph, graph.groups.single, dir.path,
          readFile: readDisk);

      final h = await File('${dir.path}/to_yuv.h').readAsString();
      expect(h, contains('ISP_CSC_BT601'));
      expect(h, contains('ISP_CSC_RANGE_FULL'));
      final c = await File('${dir.path}/to_yuv.c').readAsString();
      expect(c, contains('isp_csc_rgb_to_yuv(in, w, h, max_value,'));
      // top 链：to_yuv → to_hsl。
      final topC =
          await File('${dir.path}/isp_pipeline_csc.c').readAsString();
      expect(topC, contains('to_yuv_run(in0, w, h, max_value, e0)'));
      expect(topC, contains('to_hsl_run(e0, w, h, max_value, out0)'));
    });

    test('mux4 未选中支路裁剪：死边上游不生成、无多余缓冲与形参', () async {
      // 选中支路：wb_sel → mux.in1（select=1 默认选中）→ gamma 出组；
      // 死支路：wb_dead → ccm_dead → mux.in2（未选中）。与 Dart 预览
      // compileChain 一致，死支路不追溯、不计算。
      final graph = IspGraph();
      final wbSel = graph.addNode('white_balance', 0, 0);
      final wbDead = graph.addNode('white_balance', 0, 0);
      final ccmDead = graph.addNode('ccm', 0, 0);
      final mux = graph.addNode('mux4', 0, 0);
      final gamma = graph.addNode('gamma', 0, 0);
      graph.nodes[wbSel]!.name = 'wb_sel';
      graph.nodes[wbDead]!.name = 'wb_dead';
      graph.nodes[ccmDead]!.name = 'ccm_dead';
      graph.nodes[mux]!.name = 'mux';
      graph.nodes[gamma]!.name = 'gamma';
      expect(graph.connect(wbSel, 'out', mux, 'in1'), isNull);
      expect(graph.connect(wbDead, 'out', ccmDead, 'in'), isNull);
      expect(graph.connect(ccmDead, 'out', mux, 'in2'), isNull);
      expect(graph.connect(mux, 'out_rgb', gamma, 'in'), isNull);
      graph.groups.add(IspNodeGroup(
          'g1', {wbSel, wbDead, ccmDead, mux, gamma},
          name: 'prune'));
      // 选中支路已连接，校验通过（裁剪与校验不冲突）。
      expect(validateGroupCExport(graph, graph.groups.single), isNull);

      final map = await buildGroupCFiles(graph, graph.groups.single,
          readFile: readDisk);
      // 死支路两个节点的封装不生成；活管线三个节点 + top 层在列。
      expect(map.keys, containsAll(['wb_sel.h', 'mux.h', 'gamma.h']));
      expect(map.keys, isNot(contains('wb_dead.h')));
      expect(map.keys, isNot(contains('ccm_dead.h')));
      expect(map.keys, isNot(contains('wb_dead.c')));
      expect(map.keys, isNot(contains('ccm_dead.c')));

      final topH = map['isp_pipeline_prune.h']!;
      final topC = map['isp_pipeline_prune.c']!;
      // top 层只调用活管线，无死支路调用。
      expect(topC, contains('wb_sel_run('));
      expect(topC, contains('mux_run('));
      expect(topC, contains('gamma_run('));
      expect(topC, isNot(contains('wb_dead_run(')));
      expect(topC, isNot(contains('ccm_dead_run(')));
      // 死支路不占边缓冲：仅 wb_sel→mux 与 mux→gamma 两条活边（e0/e1）。
      expect(topC, isNot(contains('e2')));
      // 不为死槽位（in2 组外/组内来源）生成 run() 形参：只有 in0/out0。
      expect(topH, isNot(contains('in1')));
      // mux 封装只暴露选中槽位：isp_mux4_select 其余槽位传 NULL。
      expect(map['mux.c']!, contains('in1, NULL, NULL, NULL'));
    });

    test('单 HSL→RGB CSC 节点：生成物不含其它 CSC 变体（忠实还原流程图）', () async {
      // isp_csc 全家桶已按变体拆分：编组里只有 csc_hsl2rgb 时，生成物只
      // 含该变体的文件与符号，不带其它五个变体。
      final graph = IspGraph();
      final csc = graph.addNode('csc_hsl2rgb', 0, 0);
      final gamma = graph.addNode('gamma', 0, 0);
      graph.nodes[csc]!.name = 'to_rgb';
      graph.nodes[gamma]!.name = 'gamma';
      expect(graph.connect(csc, 'out', gamma, 'in'), isNull);
      graph.groups.add(IspNodeGroup('g1', {csc, gamma}, name: 'csc_only'));

      final map = await buildGroupCFiles(graph, graph.groups.single,
          readFile: readDisk);
      // 用到的：变体文件对 + 共享内部头（无对应 .c）。
      expect(map.keys, containsAll([
        'isp_csc_hsl2rgb.h', 'isp_csc_hsl2rgb.c', 'isp_csc_common.h',
      ]));
      // 未用到的五个变体与旧全家桶文件一律不在生成物中。
      for (final f in [
        'isp_csc.h', 'isp_csc.c', 'isp_csc_common.c',
        'isp_csc_rgb2yuv.h', 'isp_csc_rgb2yuv.c',
        'isp_csc_rgb2hsl.h', 'isp_csc_rgb2hsl.c',
        'isp_csc_yuv2rgb.h', 'isp_csc_yuv2rgb.c',
        'isp_csc_yuv2hsl.h', 'isp_csc_yuv2hsl.c',
        'isp_csc_hsl2yuv.h', 'isp_csc_hsl2yuv.c',
      ]) {
        expect(map.keys, isNot(contains(f)), reason: f);
      }
      // 变体实现里只有本变体入口符号，无其它五个变体入口。
      final impl = map['isp_csc_hsl2rgb.c']!;
      expect(impl, contains('isp_csc_hsl_to_rgb('));
      for (final sym in [
        'isp_csc_rgb_to_yuv(',
        'isp_csc_rgb_to_hsl(',
        'isp_csc_yuv_to_rgb(',
        'isp_csc_yuv_to_hsl(',
        'isp_csc_hsl_to_yuv(',
      ]) {
        expect(impl, isNot(contains(sym)), reason: sym);
      }
      // wrapper 头文件的 #include 只引用实际用到的变体头 + 共享内部头。
      final wrapper = map['to_rgb.h']!;
      expect(wrapper, contains('#include "isp_csc_hsl2rgb.h"'));
      expect(wrapper, contains('#include "isp_csc_common.h"'));
      for (final h in [
        'isp_csc_rgb2yuv.h', 'isp_csc_rgb2hsl.h', 'isp_csc_yuv2rgb.h',
        'isp_csc_yuv2hsl.h', 'isp_csc_hsl2yuv.h',
      ]) {
        expect(wrapper, isNot(contains(h)), reason: h);
      }
      // wrapper 源文件调用本变体入口。
      expect(map['to_rgb.c']!,
          contains('isp_csc_hsl_to_rgb(in, w, h, max_value,'));
    });

    test('真实 ispflow：荧光融合处理器（荧光 mono 链 + fusion 合流）导出',
        () async {
      // 回归：fluoro mono 节点 wrapper 端口名与注册表 in_mono/out_mono
      // 不一致导致「既不是组内边也不是组输出」StateError（查看代码页
      // 卡「生成中…」）。修复后应完整生成。
      final m = jsonDecode(
          await File('IspFlow/ICG荧光融合ISP流程.ispflow').readAsString());
      final graph = IspGraph.fromJson(m as Map<String, dynamic>);
      final group = graph.groups.single;
      expect(group.name, '荧光融合处理器');
      expect(validateGroupCExport(graph, group), isNull);

      final map = await buildGroupCFiles(graph, graph.groups.single,
          readFile: readDisk);
      // top 层名按组 id（组名全非 C 字符回退 g100）。
      expect(map.keys, contains('isp_pipeline_g100.h'));
      expect(map.keys, contains('isp_pipeline_g100.c'));
      // 荧光 c_ref 并集在列。
      expect(map.keys, containsAll(['isp_fluoro.h', 'isp_fluoro.c']));
      // 荧光 mono 链的 wrapper 使用注册表端口名 out_mono；
      // fusion wrapper 引用 in_fluoro 变量。
      final wrappers = [
        for (final e in map.entries)
          if (!e.key.startsWith('isp_')) e.value,
      ];
      expect(wrappers.any((c) => c.contains('out_mono')), isTrue);
      expect(wrappers.any((c) => c.contains('in_fluoro')), isTrue);
      // 时域 IIR 的持久区 history 在 top 层分配。
      expect(map['isp_pipeline_g100.c'], contains('hist_'));
      // 无 NULL 当作正常输入传给 fusion（双路输入都来自组内边）。
      expect(map['isp_pipeline_g100.c'], isNot(contains('(NULL,')));

      // MSVC 语法编译（无 MSVC 自动 skip）。
      // 探测走 c_compile.dart 的 detectMsvc（vswhere 优先 + 目录枚举，
      // 覆盖 VS2022/2019/2026）。
      final msvcOk = detectMsvc() != null;
      if (msvcOk) {
        final dir = await Directory.systemTemp.createTemp('isp_grp_export_');
        addTearDown(() => dir.delete(recursive: true));
        await exportGroupCCode(graph, graph.groups.single, dir.path,
            readFile: readDisk);
        final cFiles = [
          for (final f in Directory(dir.path).listSync().whereType<File>())
            if (f.path.endsWith('.c'))
              f.absolute.path.replaceAll('/', r'\'),
        ]..sort();
        final result = await Process.run(
          'cmd',
          ['/c', r'scripts\c_syntax_check.bat', ...cFiles],
          workingDirectory: Directory.current.path,
        );
        final output = '${result.stdout}\n${result.stderr}';
        expect(output, isNot(contains('error C')), reason: output);
      }
    });

    test('white_balance LUT 模式：烘焙 static const 表 + 查表主循环', () async {
      final graph = IspGraph();
      final wb = graph.addNode('white_balance', 0, 0);
      final gamma = graph.addNode('gamma', 0, 0);
      graph.nodes[wb]!.name = 'wb';
      graph.nodes[gamma]!.name = 'gamma';
      graph.nodes[wb]!.paramValues['mode'] = 'manual';
      graph.nodes[wb]!.paramValues['rGain'] = 1.3;
      graph.nodes[wb]!.paramValues['bGain'] = 0.7;
      graph.nodes[wb]!.paramValues['codegenMode'] = 'lut';
      expect(graph.connect(wb, 'out', gamma, 'in'), isNull);
      graph.groups.add(IspNodeGroup('g1', {wb, gamma}, name: 'lut'));

      final map = await buildGroupCFiles(graph, graph.groups.single,
          readFile: readDisk);
      final wrapper = map['wb.c']!;
      // 生成期烘焙的双通道 static const 表（无上游源节点，烘焙域回退
      // 1023，表长 1024）。
      expect(wrapper, contains('static const uint16_t wb_lut_r[1024]'));
      expect(wrapper, contains('static const uint16_t wb_lut_b[1024]'));
      // 表内容 = Dart 建表函数逐值结果（位级一致抽查两端）。
      final lutR = whiteBalanceGainLut(1.3, 1023);
      final lutB = whiteBalanceGainLut(0.7, 1023);
      expect(wrapper, contains('${lutR[512]}'));
      expect(wrapper, contains('${lutB[512]}'));
      // 运行时一致走纯查表，不一致回退直算（函数方式同公式）。
      expect(wrapper, contains('if (max_value == 1023)'));
      expect(wrapper, contains('isp_white_balance_lut_apply'));
      expect(wrapper, contains('isp_white_balance_apply'));

      // MSVC 语法编译（无 MSVC 自动 skip）。
      // 探测走 c_compile.dart 的 detectMsvc（vswhere 优先 + 目录枚举，
      // 覆盖 VS2022/2019/2026）。
      final msvcOk = detectMsvc() != null;
      if (msvcOk) {
        final dir = await Directory.systemTemp.createTemp('isp_grp_export_');
        addTearDown(() => dir.delete(recursive: true));
        await exportGroupCCode(graph, graph.groups.single, dir.path,
            readFile: readDisk);
        final cFiles = [
          for (final f in Directory(dir.path).listSync().whereType<File>())
            if (f.path.endsWith('.c'))
              f.absolute.path.replaceAll('/', r'\'),
        ]..sort();
        final result = await Process.run(
          'cmd',
          ['/c', r'scripts\c_syntax_check.bat', ...cFiles],
          workingDirectory: Directory.current.path,
        );
        final output = '${result.stdout}\n${result.stderr}';
        expect(output, isNot(contains('error C')), reason: output);
      }
    });

    test('levels_curves：按图表曲线烘焙 4096 级 LUT + 恒等直通', () async {
      final graph = IspGraph();
      final lv = graph.addNode('levels_curves', 0, 0);
      final gamma = graph.addNode('gamma', 0, 0);
      graph.nodes[lv]!.name = 'lv';
      graph.nodes[gamma]!.name = 'gamma';
      // 非恒等样条曲线：中间加一个提亮控制点。
      final points = [
        [0.0, 0.0],
        [2048.0, 3072.0],
        [4095.0, 4095.0],
      ];
      graph.nodes[lv]!.paramValues['points'] = points;
      expect(graph.connect(lv, 'out', gamma, 'in'), isNull);
      graph.groups.add(IspNodeGroup('g1', {lv, gamma}, name: 'lut'));

      final map =
          await buildGroupCFiles(graph, graph.groups.single, readFile: readDisk);
      final wrapper = map['lv.c']!;
      // 生成期烘焙的 4096 级 static const LUT（与节点图表曲线同一求值口径）。
      expect(wrapper,
          contains('static const uint16_t lv_lut[ISP_LEVELS_LUT_SIZE]'));
      // 表内容 = Dart levelsCurveLut 逐值结果（位级一致抽查）。
      final lut = levelsCurveLut(levelsPointsFromParam(points),
          mode: levelsCurveModeFromParam('spline'), gamma: 1.0);
      for (final x in [0, 512, 2048, 3072, 4095]) {
        expect(wrapper, contains('${lut[x]}'));
      }
      // 运行时纯查表：无 scratch 宏、无运行时规范化/建表调用。
      expect(wrapper, contains('isp_levels_apply_rgb'));
      expect(wrapper, isNot(contains('isp_levels_curve_lut')));
      expect(wrapper, isNot(contains('isp_levels_normalize_points')));
      expect(map['lv.h']!, isNot(contains('SCRATCH_BYTES')));

      // 恒等曲线（默认参数）：直通拷贝，不烘焙表。
      final graph2 = IspGraph();
      final id = graph2.addNode('levels_curves', 0, 0);
      graph2.nodes[id]!.name = 'lv';
      graph2.groups.add(IspNodeGroup('g2', {id}, name: 'id'));
      final map2 = await buildGroupCFiles(graph2, graph2.groups.single,
          readFile: readDisk);
      expect(map2['lv.c']!, isNot(contains('_lut')));
      expect(map2['lv.c']!, contains('memcpy'));

      // MSVC 语法编译（无 MSVC 自动 skip）。
      // 探测走 c_compile.dart 的 detectMsvc（vswhere 优先 + 目录枚举，
      // 覆盖 VS2022/2019/2026）。
      final msvcOk = detectMsvc() != null;
      if (msvcOk) {
        final dir = await Directory.systemTemp.createTemp('isp_grp_export_');
        addTearDown(() => dir.delete(recursive: true));
        await exportGroupCCode(graph, graph.groups.single, dir.path,
            readFile: readDisk);
        final cFiles = [
          for (final f in Directory(dir.path).listSync().whereType<File>())
            if (f.path.endsWith('.c'))
              f.absolute.path.replaceAll('/', r'\'),
        ]..sort();
        final result = await Process.run(
          'cmd',
          ['/c', r'scripts\c_syntax_check.bat', ...cFiles],
          workingDirectory: Directory.current.path,
        );
        final output = '${result.stdout}\n${result.stderr}';
        expect(output, isNot(contains('error C')), reason: output);
      }
    });

    test('六节点 LUT 模式综合：烘焙表 + 查表主循环 + MSVC 编译', () async {
      // 六节点全部 LUT 模式（无上游源节点，烘焙域回退 1023）。
      final graph = IspGraph();
      String add(String typeId, String name, Map<String, Object?> params) {
        final id = graph.addNode(typeId, 0, 0);
        graph.nodes[id]!.name = name;
        graph.nodes[id]!.paramValues.addAll(params);
        return id;
      }

      add('white_balance', 'wb',
          {'mode': 'manual', 'rGain': 1.3, 'bGain': 0.7, 'codegenMode': 'lut'});
      add('color_temp_adjuster', 'ct',
          {'temperature': 5000.0, 'measured_cct': 6500, 'codegenMode': 'lut'});
      add('pseudo_color', 'pc',
          {'colormap': 'hot', 'gain': 2.0, 'codegenMode': 'lut'});
      add('highlight', 'hl',
          {'mode': 'clip', 'knee': 0.85, 'codegenMode': 'lut'});
      add('bright_contrast_adjuster', 'bc',
          {'bright': 110.0, 'gain': 130.0, 'codegenMode': 'lut'});
      add('color_controller', 'cc', {
        'h_center': 120.0,
        'h_shift': 30.0,
        's_gain': 0.8,
        'codegenMode': 'lut'
      });
      final gamma = graph.addNode('gamma', 0, 0);
      graph.nodes[gamma]!.name = 'gamma';
      expect(graph.connect(
          graph.nodes.keys.first, 'out', gamma, 'in'), isNull);
      graph.groups.add(IspNodeGroup(
          'g1', {...graph.nodes.keys}, name: 'lutall'));

      final map = await buildGroupCFiles(graph, graph.groups.single,
          readFile: readDisk);

      // wb：双通道增益表 + 查表。
      expect(map['wb.c'], contains('static const uint16_t wb_lut_r[1024]'));
      expect(map['wb.c'], contains('static const uint16_t wb_lut_b[1024]'));
      expect(map['wb.c'], contains('isp_white_balance_lut_apply'));
      // color_temp：三通道增益表。
      expect(map['ct.c'], contains('static const uint16_t ct_lut_g[1024]'));
      expect(map['ct.c'], contains('isp_adjust_lut3_apply'));
      // pseudo_color：三张色表。
      expect(map['pc.c'], contains('static const uint16_t pc_lut_g[1024]'));
      expect(map['pc.c'],
          contains('isp_fluoro_pseudo_color_lut_apply'));
      // highlight clip：膝点压缩表。
      expect(map['hl.c'],
          contains('static const uint16_t hl_clip_lut[1024]'));
      expect(map['hl.c'], contains('isp_highlight_clip_lut_apply'));
      // bright_contrast：adjust 映射表（无比例表，除法保留）。
      expect(map['bc.c'], contains('static const uint16_t bc_adj_lut[1024]'));
      expect(map['bc.c'], contains('isp_adjust_bc_lut_apply'));
      expect(map['bc.c'], isNot(contains('ratio_lut')));
      // color_controller：H 域三表，wrapper 主循环无 exp。
      expect(map['cc.c'],
          contains('static const int32_t cc_shift_lut[1024]'));
      expect(map['cc.c'], contains('static const double cc_s_mul_lut[1024]'));
      expect(map['cc.c'],
          contains('isp_color_controller_lut_apply'));
      expect(map['cc.c'], isNot(contains('exp(')));
      // 全部带运行时守卫回退。
      for (final f in ['wb.c', 'ct.c', 'pc.c', 'hl.c', 'bc.c', 'cc.c']) {
        expect(map[f], contains('if (max_value == 1023)'), reason: f);
      }

      // MSVC 语法编译（无 MSVC 自动 skip）。
      // 探测走 c_compile.dart 的 detectMsvc（vswhere 优先 + 目录枚举，
      // 覆盖 VS2022/2019/2026）。
      final msvcOk = detectMsvc() != null;
      if (msvcOk) {
        final dir = await Directory.systemTemp.createTemp('isp_grp_export_');
        addTearDown(() => dir.delete(recursive: true));
        await exportGroupCCode(graph, graph.groups.single, dir.path,
            readFile: readDisk);
        final cFiles = [
          for (final f in Directory(dir.path).listSync().whereType<File>())
            if (f.path.endsWith('.c'))
              f.absolute.path.replaceAll('/', r'\'),
        ]..sort();
        final result = await Process.run(
          'cmd',
          ['/c', r'scripts\c_syntax_check.bat', ...cFiles],
          workingDirectory: Directory.current.path,
        );
        final output = '${result.stdout}\n${result.stderr}';
        expect(output, isNot(contains('error C')), reason: output);
      }
    });

    test('multi_band_eq 封装：func 直算 / lut 烘焙三表 + MSVC 语法编译',
        () async {
      final graph = IspGraph();
      String add(String typeId, String name, Map<String, Object?> params) {
        final id = graph.addNode(typeId, 0, 0);
        graph.nodes[id]!.name = name;
        graph.nodes[id]!.paramValues.addAll(params);
        return id;
      }

      final f = add('multi_band_eq', 'mbf', {
        'band_count': 3,
        'band_mode': 'serial',
        'b0_h': 30.0, 'b0_q': 0.5, 'b0_dh': 45.0, 'b0_s': 1.3,
        'b1_h': 150.0, 'b1_q': 2.0, 'b1_dh': -70.0,
        // b2 全缺省 → 恒等段（缺键回退口径）。
      });
      final l = add('multi_band_eq', 'mbl', {
        'band_count': 2,
        'band_mode': 'parallel',
        'codegenMode': 'lut',
        'b0_h': 0.0, 'b0_q': 2.0, 'b0_dh': 90.0,
        'b1_h': 90.0, 'b1_q': 2.0, 'b1_dh': 90.0, 'b1_s': 2.0,
      });
      expect(graph.connect(f, 'out', l, 'in'), isNull);
      graph.groups.add(IspNodeGroup('g_mb', {f, l}, name: 'mbeq'));

      final map = await buildGroupCFiles(graph, graph.groups.single,
          readFile: readDisk);
      // func：段参数烘焙为 static const 数组 + 直算调用，无烘焙表。
      expect(map['mbf.c'],
          contains('static const IspMultiBandEqBand mbf_bands[3]'));
      expect(map['mbf.c'], contains('isp_multi_band_eq_apply'));
      expect(map['mbf.h'], contains('ISP_MBF_SERIAL 1'));
      expect(map['mbf.c'], isNot(contains('_shift_lut')));
      // lut：三表烘焙 + 查表调用 + 运行时守卫回退，wrapper 主循环无 exp。
      expect(map['mbl.c'],
          contains('static const int32_t mbl_shift_lut[1024]'));
      expect(map['mbl.c'],
          contains('static const double mbl_s_mul_lut[1024]'));
      expect(map['mbl.c'], contains('isp_multi_band_eq_lut_apply'));
      expect(map['mbl.c'], contains('if (max_value == 1023)'));
      expect(map['mbl.c'], isNot(contains('exp(')));

      // MSVC 语法编译（无 MSVC 自动 skip；探测同 detectMsvc 口径）。
      final msvcOk = detectMsvc() != null;
      if (msvcOk) {
        final dir = await Directory.systemTemp.createTemp('isp_grp_export_');
        addTearDown(() => dir.delete(recursive: true));
        await exportGroupCCode(graph, graph.groups.single, dir.path,
            readFile: readDisk);
        final cFiles = [
          for (final f in Directory(dir.path).listSync().whereType<File>())
            if (f.path.endsWith('.c'))
              f.absolute.path.replaceAll('/', r'\'),
        ]..sort();
        final result = await Process.run(
          'cmd',
          ['/c', r'scripts\c_syntax_check.bat', ...cFiles],
          workingDirectory: Directory.current.path,
        );
        final output = '${result.stdout}\n${result.stderr}';
        expect(output, isNot(contains('error C')), reason: output);
      }
    });

    test('生成代码无未初始化声明（指针 NULL 化、标量零值）', () async {
      // 全 49 类型编组，扫描 wrapper 与 top 层（c_ref 为资产不检查）。
      final graph = IspGraph();
      final ids = <String, String>{
        for (final t in cExportSupportedTypeIds) t: graph.addNode(t, 0, 0),
      };
      expect(graph.connect(ids['white_balance']!, 'out', ids['ccm']!, 'in'),
          isNull);
      expect(graph.connect(ids['ccm']!, 'out', ids['gamma']!, 'in'), isNull);
      expect(
          graph.connect(
              ids['rgb_splitter']!, 'out_r', ids['rgb_combiner']!, 'in_r'),
          isNull);
      expect(
          graph.connect(
              ids['rgb_splitter']!, 'out_g', ids['rgb_combiner']!, 'in_g'),
          isNull);
      expect(
          graph.connect(
              ids['rgb_splitter']!, 'out_b', ids['rgb_combiner']!, 'in_b'),
          isNull);
      expect(
          graph.connect(ids['yuv_debugger']!, 'out', ids['sat_bright_adjuster']!,
              'in_yuv'),
          isNull);
      graph.groups.add(IspNodeGroup('g1', ids.values.toSet(), name: 'init'));
      final map = await buildGroupCFiles(graph, graph.groups.single,
          readFile: readDisk);

      // 未初始化指针声明（`uint16_t *e0;` 形态）：应一律带初始化。
      final uninitPtr = RegExp(
          r'^\s*(?:const\s+)?(?:u?int(?:8|16|32|64)_t|size_t|double|float|bool|int|char|void)\s*\*\s*\w+\s*;\s*$',
          multiLine: true);
      // 未初始化标量/数组声明（`int rc;` / `double gains[3];` 形态）。
      final uninitScalar = RegExp(
          r'^\s*(?:u?int(?:8|16|32|64)_t|size_t|double|float|bool|int|char)\s+\w+(?:\[[^\]]*\])?\s*;\s*$',
          multiLine: true);
      for (final e in map.entries) {
        final isTop = e.key.startsWith('isp_pipeline_');
        final isWrapper = !e.key.startsWith('isp_');
        if (!isTop && !isWrapper) continue; // c_ref 参考实现资产不检查
        expect(uninitPtr.hasMatch(e.value), isFalse, reason: e.key);
        expect(uninitScalar.hasMatch(e.value), isFalse, reason: e.key);
      }
    });
  });

  test(
    '全部 49 类型导出 + MSVC 语法编译',
    () async {
      // 探测走 c_compile.dart 的 detectMsvc（vswhere 优先 + 目录枚举，
      // 覆盖 VS2022/2019/2026）。
      final msvcOk = detectMsvc() != null;
      if (!msvcOk) {
        // ignore: avoid_print
        print('未检测到 MSVC，跳过生成代码语法编译');
        return;
      }

      final graph = IspGraph();
      final ids = <String, String>{
        for (final t in cExportSupportedTypeIds) t: graph.addNode(t, 0, 0),
      };
      // 主链与回环：锻炼边缓冲、格式推导、gamma 链尾。
      expect(graph.connect(ids['white_balance']!, 'out', ids['ccm']!, 'in'),
          isNull);
      expect(graph.connect(ids['ccm']!, 'out', ids['gamma']!, 'in'), isNull);
      expect(
          graph.connect(
              ids['rgb_splitter']!, 'out_r', ids['rgb_combiner']!, 'in_r'),
          isNull);
      expect(
          graph.connect(
              ids['rgb_splitter']!, 'out_g', ids['rgb_combiner']!, 'in_g'),
          isNull);
      expect(
          graph.connect(
              ids['rgb_splitter']!, 'out_b', ids['rgb_combiner']!, 'in_b'),
          isNull);
      expect(
          graph.connect(ids['yuv_debugger']!, 'out', ids['sat_bright_adjuster']!,
              'in_yuv'),
          isNull);
      graph.groups.add(
          IspNodeGroup('g1', ids.values.toSet(), name: 'all'));

      final dir = await Directory.systemTemp.createTemp('isp_grp_export_');
      addTearDown(() => dir.delete(recursive: true));
      await exportGroupCCode(graph, graph.groups.single, dir.path,
          readFile: readDisk);

      final cFiles = [
        for (final f in Directory(dir.path).listSync().whereType<File>())
          if (f.path.endsWith('.c'))
            f.absolute.path.replaceAll('/', r'\'),
      ]..sort();
      // 48 封装 + 1 top + c_ref 实现，数量下限检查。
      expect(cFiles.length, greaterThan(48));
      final result = await Process.run(
        'cmd',
        ['/c', r'scripts\c_syntax_check.bat', ...cFiles],
        workingDirectory: Directory.current.path,
      );
      final output = '${result.stdout}\n${result.stderr}';
      expect(output, isNot(contains('error C')), reason: output);
    },
    // 逐文件 cl 语法检查较慢，放宽超时。
    timeout: const Timeout(Duration(minutes: 10)),
  );

  group('Win32 可运行验证程序（main_win.c）', () {
    /// FNV-1a 32（与 main_win.c 的批模式哈希同口径；小端字节流）。
    int fnv1a(Uint8List bytes) {
      var h = 0x811c9dc5;
      for (final c in bytes) {
        h ^= c;
        h = (h * 16777619) & 0xFFFFFFFF;
      }
      return h;
    }

    /// Dart 侧期望哈希：整数测试图案 → 按量化域缩放 → rgbToHsl → 均衡器
    /// LUT → FNV-1a（与 main_win.c 的图案/装帧（`* MAXV / 255` 缩放）/
    /// 批模式同口径，ΔH=+30 非恒等段；max=255 时缩放为恒等）。
    List<String> eqExpectedHashes(int frames, {int max = 255}) {
      const w = 640, h = 360;
      final (shift, sMul, lMul) = multiBandLuts(
          [(h: 0.0, q: 2.0, dh: 30.0, s: 1.0, l: 1.0)],
          serial: false, maxValue: max);
      final expected = <String>[];
      for (var f = 0; f < frames; f++) {
        final rgb = Uint16List(w * h * 3);
        final bx = (f * 3) % (w + 80) - 40;
        var i = 0;
        for (var y = 0; y < h; y++) {
          for (var x = 0; x < w; x++, i += 3) {
            var r = (x * 255) ~/ (w - 1);
            var g = (y * 255) ~/ (h - 1);
            var b = ((x + y) * 255) ~/ (w + h - 2);
            if (x >= bx && x < bx + 80 && y >= h ~/ 3 && y < h ~/ 3 + 80) {
              r = (f * 5) & 255;
              g = (255 - (f * 5)) & 255;
              b = (f * 5 + 128) & 255;
            }
            rgb[i] = r * max ~/ 255;
            rgb[i + 1] = g * max ~/ 255;
            rgb[i + 2] = b * max ~/ 255;
          }
        }
        final hsl = rgbToHsl(rgb, maxValue: max);
        final out = applyHslBandLuts(hsl, 0, hsl.length ~/ 3,
            maxValue: max, shiftLut: shift, sMulLut: sMul, lMulLut: lMul);
        expected.add(
            'frame $f: ${fnv1a(out.buffer.asUint8List()).toRadixString(16).padLeft(8, '0')}');
      }
      return expected;
    }

    test('stubMainWinSource 内容：双模式/批模式/签名/HSL 转换', () {
      final src = stubMainWinSource(
          topName: 'isp_pipeline_eq', inFormat: 'hsl', outFormat: 'hsl');
      expect(src, contains('isp_pipeline_eq_run(g_in, g_w, g_h, MAXV, g_out'));
      expect(src, contains('ISP_PIPELINE_EQ_SCRATCH_BYTES'));
      expect(src, contains('模式: 单视频'));
      expect(src, contains('模式: 并列'));
      expect(src, contains('--dump-hash'));
      expect(src, contains('isp_csc_rgb_to_hsl_px'));
      expect(src, contains('isp_csc_hsl_to_rgb_px'));
      // rgb 端口不引入 csc 转换头。
      final rgb = stubMainWinSource(topName: 'isp_pipeline_eq');
      expect(rgb, isNot(contains('isp_csc_common.h')));
    });

    test('MSVC 集成：构建 + 批模式哈希与 Dart 管线逐位一致', () async {
      if (detectMsvc() == null) return; // 无 MSVC 环境自动跳过
      // 单节点多段色彩均衡器编组（单节点编组放行），ΔH=+30 非恒等段。
      final graph = IspGraph();
      final eq = graph.addNode('multi_band_eq', 0, 0);
      graph.nodes[eq]!.name = 'mb';
      graph.nodes[eq]!.paramValues['b0_dh'] = 30.0;
      graph.groups.add(IspNodeGroup('g1', {eq}, name: 'eq'));
      expect(validateGroupCExport(graph, graph.groups.single), isNull);
      final files = await buildGroupCFiles(graph, graph.groups.single,
          readFile: readDisk, genTime: DateTime(2026, 1, 2, 3, 4, 5));

      final result = await buildWinVerifyApp(files,
          topName: 'isp_pipeline_eq', inFormat: 'hsl', outFormat: 'hsl');
      expect(result.success, isTrue, reason: result.output);
      final run = await Process.run(
          result.artifactPath!, ['--frames', '3', '--dump-hash']);
      expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
      final lines = '${run.stdout}'
          .trim()
          .split('\n')
          .map((l) => l.trim())
          .toList();
      expect(lines.take(3).toList(), equals(eqExpectedHashes(3)));
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('黑盒（无 scratch 签名）MSVC 集成：构建 + 批模式哈希一致', () async {
      if (detectMsvc() == null) return; // 无 MSVC 环境自动跳过
      // 单节点多段色彩均衡器黑盒编组：无环形缓冲需求时 bb top run 不带
      // scratch 参数（此前 main_win.c 按整帧版签名传参导致 C2197 报错）。
      final graph = IspGraph();
      final eq = graph.addNode('multi_band_eq', 0, 0);
      graph.nodes[eq]!.name = 'mb';
      graph.nodes[eq]!.paramValues['b0_dh'] = 30.0;
      graph.groups.add(IspNodeGroup('g1', {eq}, name: 'n1'));
      expect(validateGroupBlackBoxExport(graph, graph.groups.single), isNull);
      final files = await buildGroupBlackBoxCFiles(
          graph, graph.groups.single,
          readFile: readDisk, genTime: DateTime(2026, 1, 2, 3, 4, 5));
      final topName = groupBlackBoxTopName(graph.groups.single);
      final hasScratch =
          (files['$topName.h'] ?? '').contains('void *scratch');
      expect(hasScratch, isFalse, reason: '该编组黑盒 top 应无 scratch 参数');

      final result = await buildWinVerifyApp(files,
          topName: topName,
          inFormat: 'hsl',
          outFormat: 'hsl',
          hasScratch: hasScratch);
      expect(result.success, isTrue, reason: result.output);
      final run = await Process.run(
          result.artifactPath!, ['--frames', '2', '--dump-hash']);
      expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
      final lines = '${run.stdout}'
          .trim()
          .split('\n')
          .map((l) => l.trim())
          .toList();
      expect(lines.take(2).toList(), equals(eqExpectedHashes(2)));
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('LUT 模式 maxValue=1023：构建 + 批模式哈希与 Dart 查表逐位一致',
        () async {
      if (detectMsvc() == null) return; // 无 MSVC 环境自动跳过
      // LUT 模式单节点编组：lutDomainMaxOf 无上游回退 1023，验证程序
      // maxValue 同域传入——查表快路径命中（255 会失配回退直算，本测试
      // 同时锁定该口径）。
      final graph = IspGraph();
      final eq = graph.addNode('multi_band_eq', 0, 0);
      graph.nodes[eq]!.name = 'mb';
      graph.nodes[eq]!.paramValues['b0_dh'] = 30.0;
      graph.nodes[eq]!.paramValues['codegenMode'] = 'lut';
      graph.groups.add(IspNodeGroup('g1', {eq}, name: 'n1'));
      expect(validateGroupBlackBoxExport(graph, graph.groups.single), isNull);
      final files = await buildGroupBlackBoxCFiles(
          graph, graph.groups.single,
          readFile: readDisk, genTime: DateTime(2026, 1, 2, 3, 4, 5));
      final topName = groupBlackBoxTopName(graph.groups.single);
      final hasScratch =
          (files['$topName.h'] ?? '').contains('void *scratch');
      // 单节点 lut 独占阶段应走整行 <id>_row + omp 行域并行（守卫——否则
      // 本用例走融合行核，失去对整行函数路径的校验意义）。
      expect(files['$topName.c'], contains('_row(row_'));
      expect(files['$topName.c'], contains('#pragma omp parallel for'));

      final result = await buildWinVerifyApp(files,
          topName: topName,
          inFormat: 'hsl',
          outFormat: 'hsl',
          hasScratch: hasScratch,
          maxValue: 1023);
      expect(result.success, isTrue, reason: result.output);
      final run = await Process.run(
          result.artifactPath!, ['--frames', '2', '--dump-hash']);
      expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
      final lines = '${run.stdout}'
          .trim()
          .split('\n')
          .map((l) => l.trim())
          .toList();
      expect(lines.take(2).toList(), equals(eqExpectedHashes(2, max: 1023)));
      // 查表路径产物应输出 max=1023（批模式收尾 frames= 行）。
      expect('${run.stdout}', contains('max=1023'));
    }, timeout: const Timeout(Duration(minutes: 5)));

    /// Q14 定点钳位（bb_clamp_q14 的 Dart 参考实现）。
    int fxClampQ14(int v, double mul, int maxV) {
      final q = (mul * 16384.0).round();
      final r = (v * q + 8192) >> 14;
      return r < 0 ? 0 : (r > maxV ? maxV : r);
    }

    /// lut_fixed 期望哈希：图案 → 缩放 → rgbToHsl → H 表回绕（与 FP64
    /// 同路径，整数精确）+ Q14 定点 S/L → FNV-1a。
    List<String> fxExpectedHashes(int frames, {int max = 1023}) {
      const w = 640, h = 360;
      final (shift, sMul, lMul) = multiBandLuts(
          [(h: 0.0, q: 2.0, dh: 30.0, s: 1.0, l: 1.0)],
          serial: false, maxValue: max);
      final expected = <String>[];
      final m = max + 1;
      for (var f = 0; f < frames; f++) {
        final rgb = Uint16List(w * h * 3);
        final bx = (f * 3) % (w + 80) - 40;
        var i = 0;
        for (var y = 0; y < h; y++) {
          for (var x = 0; x < w; x++, i += 3) {
            var r = (x * 255) ~/ (w - 1);
            var g = (y * 255) ~/ (h - 1);
            var b = ((x + y) * 255) ~/ (w + h - 2);
            if (x >= bx && x < bx + 80 && y >= h ~/ 3 && y < h ~/ 3 + 80) {
              r = (f * 5) & 255;
              g = (255 - (f * 5)) & 255;
              b = (f * 5 + 128) & 255;
            }
            rgb[i] = r * max ~/ 255;
            rgb[i + 1] = g * max ~/ 255;
            rgb[i + 2] = b * max ~/ 255;
          }
        }
        final hsl = rgbToHsl(rgb, maxValue: max);
        final out = Uint16List(hsl.length);
        var maxDev = 0;
        for (var px = 0; px < hsl.length ~/ 3; px++) {
          final j = px * 3;
          var hv = hsl[j];
          if (hv > max) hv = max;
          var hnew = hv + shift[hv];
          if (hnew > max) {
            hnew -= m;
          } else if (hnew < 0) {
            hnew += m;
          }
          out[j] = hnew;
          out[j + 1] = fxClampQ14(hsl[j + 1], sMul[hv], max);
          out[j + 2] = fxClampQ14(hsl[j + 2], lMul[hv], max);
        }
        // 与 FP64 查表路径逐像素对比：偏差必须 ≤1 LSB。
        final fp64 = applyHslBandLuts(hsl, 0, hsl.length ~/ 3,
            maxValue: max, shiftLut: shift, sMulLut: sMul, lMulLut: lMul);
        for (var j = 0; j < out.length; j++) {
          final dev = (out[j] - fp64[j]).abs();
          if (dev > maxDev) maxDev = dev;
        }
        expect(maxDev, lessThanOrEqualTo(1),
            reason: 'lut_fixed 与 FP64 偏差超 1 LSB（帧 $f）');
        expected.add(
            'frame $f: ${fnv1a(out.buffer.asUint8List()).toRadixString(16).padLeft(8, '0')}');
      }
      return expected;
    }

    test('lut_fixed 定点模式：构建 + 与 Dart Q14 逐位一致 + 与 FP64 偏差 ≤1',
        () async {
      if (detectMsvc() == null) return; // 无 MSVC 环境自动跳过
      final graph = IspGraph();
      final eq = graph.addNode('multi_band_eq', 0, 0);
      graph.nodes[eq]!.name = 'mb';
      graph.nodes[eq]!.paramValues['b0_dh'] = 30.0;
      graph.nodes[eq]!.paramValues['codegenMode'] = 'lut_fixed';
      graph.groups.add(IspNodeGroup('g1', {eq}, name: 'n1'));
      expect(validateGroupBlackBoxExport(graph, graph.groups.single), isNull);
      final files = await buildGroupBlackBoxCFiles(
          graph, graph.groups.single,
          readFile: readDisk, genTime: DateTime(2026, 1, 2, 3, 4, 5));
      final topName = groupBlackBoxTopName(graph.groups.single);
      final hasScratch =
          (files['$topName.h'] ?? '').contains('void *scratch');
      expect(files['$topName.c'], contains('bb_clamp_q14'));
      expect(files['$topName.c'], contains('_s_mul_q14'));

      final result = await buildWinVerifyApp(files,
          topName: topName,
          inFormat: 'hsl',
          outFormat: 'hsl',
          hasScratch: hasScratch,
          maxValue: 1023);
      expect(result.success, isTrue, reason: result.output);
      final run = await Process.run(
          result.artifactPath!, ['--frames', '2', '--dump-hash']);
      expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
      final lines = '${run.stdout}'
          .trim()
          .split('\n')
          .map((l) => l.trim())
          .toList();
      expect(lines.take(2).toList(), equals(fxExpectedHashes(2)));
    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}
