/// 编组导出目标 CPU（GroupCTarget）拆分测试：6 个目标的头注释块、
/// lut_fixed 行核 SIMD 变体分叉（ARM NEON / x86 SSE2）、SSE2 vs 标量
/// 逐位对拍（MSVC）、标签页 key 的 target 后缀管理。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/c_compile.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/group_c_export.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/group_c_export_bb.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/group_c_target.dart';
import 'package:debug_tool_set/modules/isp_studio/models/isp_graph.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';

void main() {
  /// 从磁盘读真实 c_ref 文件（测试不依赖 rootBundle 资产）。
  Future<String> readDisk(String path) => File(path).readAsString();

  /// 单节点 lut_fixed 均衡器编组（命中整行 <id>_row SIMD/标量双变体发射）。
  (IspGraph, IspNodeGroup) lutFixedGroup() {
    final graph = IspGraph();
    final eq = graph.addNode('multi_band_eq', 0, 0);
    graph.nodes[eq]!.name = 'mb';
    graph.nodes[eq]!.paramValues['codegenMode'] = 'lut_fixed';
    graph.nodes[eq]!.paramValues['b0_dh'] = 30.0;
    graph.groups.add(IspNodeGroup('g1', {eq}, name: 'n1'));
    return (graph, graph.groups.single);
  }

  group('目标 CPU 元数据与文件头注释块', () {
    test('6 个目标的 bb top .h 均含目标名与推荐编译选项', () async {
      final (graph, group) = lutFixedGroup();
      for (final t in GroupCTarget.values) {
        final files = await buildGroupBlackBoxCFiles(graph, group,
            readFile: readDisk,
            genTime: DateTime(2026, 1, 2, 3, 4, 5),
            target: t);
        final h = files['isp_pipe_n1_bb.h']!;
        expect(h, contains('目标 CPU：${t.displayName}'), reason: t.name);
        // cFlags 首段（去掉 x86 的中文括号注释部分）。
        expect(h, contains('推荐编译选项：${t.cFlags.split('（').first}'),
            reason: t.name);
        // FP64 SIMD 弱的小核目标附带 lut_fixed 建议，大核/x86 不带。
        if (t.fp64Weak) {
          expect(h, contains('codegenMode=lut_fixed'), reason: t.name);
        } else {
          expect(h, isNot(contains('codegenMode=lut_fixed（Q14')),
              reason: t.name);
        }
      }
    });

    test('整帧版 top .h 同样带头注释块（默认目标 cortexA53_55）', () async {
      final (graph, group) = lutFixedGroup();
      final files = await buildGroupCFiles(graph, group,
          readFile: readDisk, genTime: DateTime(2026, 1, 2, 3, 4, 5));
      expect(files['isp_pipeline_n1.h'], contains('目标 CPU：Cortex-A53/A55'));
      // 指定目标时头注释块随之切换。
      final x86 = await buildGroupCFiles(graph, group,
          readFile: readDisk,
          genTime: DateTime(2026, 1, 2, 3, 4, 5),
          target: GroupCTarget.x86);
      expect(x86['isp_pipeline_n1.h'], contains('目标 CPU：x86（SSE2）'));
    });
  });

  group('lut_fixed 行核 SIMD 变体按目标分叉', () {
    test('ARM 目标含 __ARM_NEON__ 守卫且不含 emmintrin.h', () async {
      final (graph, group) = lutFixedGroup();
      for (final t in GroupCTarget.values.where((t) => t.isArm)) {
        final files = await buildGroupBlackBoxCFiles(graph, group,
            readFile: readDisk,
            genTime: DateTime(2026, 1, 2, 3, 4, 5),
            target: t);
        final bb = files['isp_pipe_n1_bb.c']!;
        expect(bb, contains('#if defined(__ARM_NEON) || defined(__ARM_NEON__)'),
            reason: t.name);
        expect(bb, contains('vld3q_u16'), reason: t.name);
        expect(bb, isNot(contains('emmintrin.h')), reason: t.name);
        expect(bb, isNot(contains('__SSE2__')), reason: t.name);
      }
    });

    test('x86 目标含 __SSE2__/_M_X64 守卫与 emmintrin.h 且不含 arm_neon.h',
        () async {
      final (graph, group) = lutFixedGroup();
      final files = await buildGroupBlackBoxCFiles(graph, group,
          readFile: readDisk,
          genTime: DateTime(2026, 1, 2, 3, 4, 5),
          target: GroupCTarget.x86);
      final bb = files['isp_pipe_n1_bb.c']!;
      expect(bb, contains('__SSE2__'));
      expect(bb, contains('_M_X64'));
      expect(bb, contains('_M_IX86_FP'));
      expect(bb, contains('#include <emmintrin.h>'));
      expect(bb, contains('_mm_mul_epu32'));
      expect(bb, isNot(contains('arm_neon.h')));
      expect(bb, isNot(contains('__ARM_NEON')));
      // 标量回退段两目标共用。
      expect(bb, contains('bb_clamp_q14'));
    });
  });

  group('SSE2 行核 vs 标量行核逐位对拍（MSVC）', () {
    test('x86（SSE2 路径）与 cortexA53_55（标量路径）批模式哈希逐字节一致',
        () async {
      if (detectMsvc() == null) return; // 无 MSVC 环境自动跳过
      // 同一 lut_fixed 单节点编组分别按两目标生成：x86 在 MSVC/x64 下走
      // SSE2 路径（_M_X64 恒定义），ARM 目标在 MSVC 下走标量路径；两者
      // 必须与标量参考（fxExpectedHashes 同口径的批模式输出）逐位一致。
      Future<List<String>> hashesOf(GroupCTarget target) async {
        final (graph, group) = lutFixedGroup();
        final files = await buildGroupBlackBoxCFiles(graph, group,
            readFile: readDisk,
            genTime: DateTime(2026, 1, 2, 3, 4, 5),
            target: target);
        final result = await buildWinVerifyApp(files,
            topName: 'isp_pipe_n1_bb',
            inFormat: 'hsl',
            outFormat: 'hsl',
            hasScratch: false,
            maxValue: 1023);
        expect(result.success, isTrue, reason: result.output);
        final run = await Process.run(
            result.artifactPath!, ['--frames', '3', '--dump-hash']);
        expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
        return '${run.stdout}'
            .trim()
            .split('\n')
            .map((l) => l.trim())
            .where((l) => l.startsWith('frame '))
            .toList();
      }

      final x86 = await hashesOf(GroupCTarget.x86);
      final arm = await hashesOf(GroupCTarget.cortexA53_55);
      expect(x86.length, 3);
      expect(x86, equals(arm));
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  group('csc_rgb2yuv 行核 SIMD 变体按目标分叉', () {
    (IspGraph, IspNodeGroup) cscGroup() {
      final graph = IspGraph();
      final csc = graph.addNode('csc_rgb2yuv', 0, 0);
      graph.nodes[csc]!.name = 'csc';
      graph.groups.add(IspNodeGroup('g1', {csc}, name: 'c2y'));
      return (graph, graph.groups.single);
    }

    test('ARM 目标含 __ARM_NEON__ 守卫与 vmulq 且不含 emmintrin.h', () async {
      for (final t in GroupCTarget.values.where((t) => t.isArm)) {
        final (graph, group) = cscGroup();
        final files = await buildGroupBlackBoxCFiles(graph, group,
            readFile: readDisk,
            genTime: DateTime(2026, 1, 2, 3, 4, 5),
            target: t);
        final bb = files['isp_pipe_c2y_bb.c']!;
        expect(bb,
            contains('#if defined(__ARM_NEON) || defined(__ARM_NEON__)'),
            reason: t.name);
        expect(bb, contains('vld3q_u16'), reason: t.name);
        expect(bb, contains('vmulq_s32'), reason: t.name);
        expect(bb, isNot(contains('emmintrin.h')), reason: t.name);
        expect(bb, isNot(contains('__SSE2__')), reason: t.name);
      }
    });

    test('x86 目标含 __SSE2__ 守卫与 emmintrin.h 且不含 arm_neon.h', () async {
      final (graph, group) = cscGroup();
      final files = await buildGroupBlackBoxCFiles(graph, group,
          readFile: readDisk,
          genTime: DateTime(2026, 1, 2, 3, 4, 5),
          target: GroupCTarget.x86);
      final bb = files['isp_pipe_c2y_bb.c']!;
      expect(bb, contains('__SSE2__'));
      expect(bb, contains('_M_X64'));
      expect(bb, contains('#include <emmintrin.h>'));
      expect(bb, contains('_mm_mul_epu32'));
      expect(bb, isNot(contains('arm_neon.h')));
      expect(bb, isNot(contains('__ARM_NEON')));
    });
  });

  group('csc_rgb2yuv SSE2 行核 vs 标量行核逐位对拍（MSVC）', () {
    test('x86（SSE2 路径）与 cortexA53_55（标量路径）批模式哈希逐字节一致',
        () async {
      if (detectMsvc() == null) return; // 无 MSVC 环境自动跳过
      // 单节点 csc_rgb2yuv（BT.601 全范围，命中整行 <id>_row）：x86 在
      // MSVC/x64 下走 SSE2 路径（_M_X64 恒定义），ARM 目标在 MSVC 下走
      // 标量路径；两者必须逐字节一致。1023 走 SIMD 路径（max_value ≤
      // 32767），65535 走标量回退路径（SIMD 域守卫）。
      Future<List<String>> hashesOf(GroupCTarget target, int maxValue) async {
        final graph = IspGraph();
        final csc = graph.addNode('csc_rgb2yuv', 0, 0);
        graph.nodes[csc]!.name = 'csc';
        graph.groups.add(IspNodeGroup('g1', {csc}, name: 'c2y'));
        final files = await buildGroupBlackBoxCFiles(graph, graph.groups.single,
            readFile: readDisk,
            genTime: DateTime(2026, 1, 2, 3, 4, 5),
            target: target);
        final result = await buildWinVerifyApp(files,
            topName: 'isp_pipe_c2y_bb',
            inFormat: 'rgb',
            outFormat: 'rgb',
            hasScratch: false,
            maxValue: maxValue);
        expect(result.success, isTrue, reason: result.output);
        final run = await Process.run(
            result.artifactPath!, ['--frames', '3', '--dump-hash']);
        expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
        return '${run.stdout}'
            .trim()
            .split('\n')
            .map((l) => l.trim())
            .where((l) => l.startsWith('frame '))
            .toList();
      }

      for (final mv in [1023, 65535]) {
        final x86 = await hashesOf(GroupCTarget.x86, mv);
        final arm = await hashesOf(GroupCTarget.cortexA53_55, mv);
        expect(x86.length, 3, reason: 'maxValue=$mv');
        expect(x86, equals(arm), reason: 'maxValue=$mv');
      }
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  group('csc_yuv2rgb 行核 SIMD 变体与逐位对拍', () {
    test('x86（SSE2 路径）与 cortexA53_55（标量路径）批模式哈希逐字节一致',
        () async {
      if (detectMsvc() == null) return; // 无 MSVC 环境自动跳过
      // 单节点 csc_yuv2rgb：输入按 'rgb' 直装测试图案（逐位对拍只看 SSE2
      // vs 标量一致性，与 YUV 语义无关）。
      Future<(List<String>, String)> hashesAndSrc(
          GroupCTarget target, int maxValue) async {
        final graph = IspGraph();
        final csc = graph.addNode('csc_yuv2rgb', 0, 0);
        graph.nodes[csc]!.name = 'csc';
        graph.groups.add(IspNodeGroup('g1', {csc}, name: 'y2r'));
        final files = await buildGroupBlackBoxCFiles(graph, graph.groups.single,
            readFile: readDisk,
            genTime: DateTime(2026, 1, 2, 3, 4, 5),
            target: target);
        final result = await buildWinVerifyApp(files,
            topName: 'isp_pipe_y2r_bb',
            inFormat: 'rgb',
            outFormat: 'rgb',
            hasScratch: false,
            maxValue: maxValue);
        expect(result.success, isTrue, reason: result.output);
        final run = await Process.run(
            result.artifactPath!, ['--frames', '3', '--dump-hash']);
        expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
        final lines = '${run.stdout}'
            .trim()
            .split('\n')
            .map((l) => l.trim())
            .where((l) => l.startsWith('frame '))
            .toList();
        return (lines, files['isp_pipe_y2r_bb.c']!);
      }

      // 变体分叉内容检查。
      final (_, x86Src) = await hashesAndSrc(GroupCTarget.x86, 1023);
      expect(x86Src, contains('_mm_mul_epu32'));
      expect(x86Src, isNot(contains('arm_neon.h')));
      final (_, armSrc) = await hashesAndSrc(GroupCTarget.cortexA53_55, 1023);
      expect(armSrc, contains('vmulq_s32'));
      expect(armSrc, isNot(contains('emmintrin.h')));

      for (final mv in [1023, 65535]) {
        final (x86, _) = await hashesAndSrc(GroupCTarget.x86, mv);
        final (arm, _) = await hashesAndSrc(GroupCTarget.cortexA53_55, mv);
        expect(x86.length, 3, reason: 'maxValue=$mv');
        expect(x86, equals(arm), reason: 'maxValue=$mv');
      }
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  group('white_balance LUT 行核 SIMD 变体与逐位对拍', () {
    test('x86（SSE2 路径）与 cortexA53_55（标量路径）批模式哈希逐字节一致',
        () async {
      if (detectMsvc() == null) return; // 无 MSVC 环境自动跳过
      // 单节点 white_balance（manual + codegenMode=lut，rGain 1.5 / bGain
      // 0.8）：域匹配（maxValue=1023，lutDomainMaxOf 无上游回退）走 SIMD
      // gather；域失配（65535）标量回退，两条路径均须逐字节一致。
      Future<(List<String>, String)> hashesAndSrc(
          GroupCTarget target, int maxValue) async {
        final graph = IspGraph();
        final wb = graph.addNode('white_balance', 0, 0);
        graph.nodes[wb]!.name = 'wb';
        graph.nodes[wb]!.paramValues['mode'] = 'manual';
        graph.nodes[wb]!.paramValues['codegenMode'] = 'lut';
        graph.nodes[wb]!.paramValues['rGain'] = 1.5;
        graph.nodes[wb]!.paramValues['bGain'] = 0.8;
        graph.groups.add(IspNodeGroup('g1', {wb}, name: 'wb1'));
        final files = await buildGroupBlackBoxCFiles(graph, graph.groups.single,
            readFile: readDisk,
            genTime: DateTime(2026, 1, 2, 3, 4, 5),
            target: target);
        final result = await buildWinVerifyApp(files,
            topName: 'isp_pipe_wb1_bb',
            inFormat: 'rgb',
            outFormat: 'rgb',
            hasScratch: false,
            maxValue: maxValue);
        expect(result.success, isTrue, reason: result.output);
        final run = await Process.run(
            result.artifactPath!, ['--frames', '3', '--dump-hash']);
        expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
        final lines = '${run.stdout}'
            .trim()
            .split('\n')
            .map((l) => l.trim())
            .where((l) => l.startsWith('frame '))
            .toList();
        return (lines, files['isp_pipe_wb1_bb.c']!);
      }

      // 变体分叉内容检查（SIMD gather 路径确实发射）。
      final (_, x86Src) = await hashesAndSrc(GroupCTarget.x86, 1023);
      expect(x86Src, contains('_mm_storeu_si128'));
      expect(x86Src, isNot(contains('arm_neon.h')));
      final (_, armSrc) = await hashesAndSrc(GroupCTarget.cortexA53_55, 1023);
      expect(armSrc, contains('vld1q_u16'));
      expect(armSrc, isNot(contains('emmintrin.h')));

      for (final mv in [1023, 65535]) {
        final (x86, _) = await hashesAndSrc(GroupCTarget.x86, mv);
        final (arm, _) = await hashesAndSrc(GroupCTarget.cortexA53_55, mv);
        expect(x86.length, 3, reason: 'maxValue=$mv');
        expect(x86, equals(arm), reason: 'maxValue=$mv');
      }
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  group('ccm 行核 SIMD 变体与逐位对拍', () {
    test('x86（SSE2 路径）与 cortexA53_55（标量路径）批模式哈希逐字节一致',
        () async {
      if (detectMsvc() == null) return; // 无 MSVC 环境自动跳过
      // 单节点 ccm，非恒等矩阵（含负系数：覆盖 int64 累加、SSE2 的 2^63
      // 偏置还原算术 >>20 与 NEON vshrq_n_s64 两路径）。
      Future<(List<String>, String)> hashesAndSrc(
          GroupCTarget target, int maxValue) async {
        final graph = IspGraph();
        final ccm = graph.addNode('ccm', 0, 0);
        graph.nodes[ccm]!.name = 'ccm';
        graph.nodes[ccm]!.paramValues['matrix'] = [
          1.1, -0.05, 0.0,
          0.05, 0.95, -0.1,
          -0.03, 0.02, 1.05,
        ];
        graph.groups.add(IspNodeGroup('g1', {ccm}, name: 'cc1'));
        final files = await buildGroupBlackBoxCFiles(graph, graph.groups.single,
            readFile: readDisk,
            genTime: DateTime(2026, 1, 2, 3, 4, 5),
            target: target);
        final result = await buildWinVerifyApp(files,
            topName: 'isp_pipe_cc1_bb',
            inFormat: 'rgb',
            outFormat: 'rgb',
            hasScratch: false,
            maxValue: maxValue);
        expect(result.success, isTrue, reason: result.output);
        final run = await Process.run(
            result.artifactPath!, ['--frames', '3', '--dump-hash']);
        expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
        final lines = '${run.stdout}'
            .trim()
            .split('\n')
            .map((l) => l.trim())
            .where((l) => l.startsWith('frame '))
            .toList();
        return (lines, files['isp_pipe_cc1_bb.c']!);
      }

      // 变体分叉内容检查。
      final (_, x86Src) = await hashesAndSrc(GroupCTarget.x86, 1023);
      expect(x86Src, contains('_mm_mul_epu32'));
      expect(x86Src, contains('_mm_add_epi64'));
      expect(x86Src, isNot(contains('arm_neon.h')));
      final (_, armSrc) = await hashesAndSrc(GroupCTarget.cortexA53_55, 1023);
      expect(armSrc, contains('vmull_n_s32'));
      expect(armSrc, contains('vshrq_n_s64'));
      expect(armSrc, isNot(contains('emmintrin.h')));

      for (final mv in [1023, 65535]) {
        final (x86, _) = await hashesAndSrc(GroupCTarget.x86, mv);
        final (arm, _) = await hashesAndSrc(GroupCTarget.cortexA53_55, mv);
        expect(x86.length, 3, reason: 'maxValue=$mv');
        expect(x86, equals(arm), reason: 'maxValue=$mv');
      }
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  group('levels_curves 行核 SIMD 变体与逐位对拍', () {
    test('x86（SSE2 路径）与 cortexA53_55（标量路径）批模式哈希逐字节一致',
        () async {
      if (detectMsvc() == null) return; // 无 MSVC 环境自动跳过
      // 单节点 levels_curves（非恒等线性曲线）：4095 域匹配走 SIMD gather，
      // 1023 域失配标量回退（线性缩放往返）。
      Future<(List<String>, String)> hashesAndSrc(
          GroupCTarget target, int maxValue) async {
        final graph = IspGraph();
        final lv = graph.addNode('levels_curves', 0, 0);
        graph.nodes[lv]!.name = 'lv';
        graph.nodes[lv]!.paramValues['curveMode'] = 'linear';
        graph.nodes[lv]!.paramValues['points'] = [
          [0.0, 0.0],
          [2048.0, 3000.0],
          [4095.0, 4095.0],
        ];
        graph.groups.add(IspNodeGroup('g1', {lv}, name: 'lv1'));
        final files = await buildGroupBlackBoxCFiles(graph, graph.groups.single,
            readFile: readDisk,
            genTime: DateTime(2026, 1, 2, 3, 4, 5),
            target: target);
        final result = await buildWinVerifyApp(files,
            topName: 'isp_pipe_lv1_bb',
            inFormat: 'rgb',
            outFormat: 'rgb',
            hasScratch: false,
            maxValue: maxValue);
        expect(result.success, isTrue, reason: result.output);
        final run = await Process.run(
            result.artifactPath!, ['--frames', '3', '--dump-hash']);
        expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
        final lines = '${run.stdout}'
            .trim()
            .split('\n')
            .map((l) => l.trim())
            .where((l) => l.startsWith('frame '))
            .toList();
        return (lines, files['isp_pipe_lv1_bb.c']!);
      }

      // 变体分叉内容检查（SIMD gather 路径确实发射）。
      final (_, x86Src) = await hashesAndSrc(GroupCTarget.x86, 4095);
      expect(x86Src, contains('_mm_storeu_si128'));
      expect(x86Src, isNot(contains('arm_neon.h')));
      final (_, armSrc) = await hashesAndSrc(GroupCTarget.cortexA53_55, 4095);
      expect(armSrc, contains('vld3q_u16'));
      expect(armSrc, isNot(contains('emmintrin.h')));

      for (final mv in [4095, 1023]) {
        final (x86, _) = await hashesAndSrc(GroupCTarget.x86, mv);
        final (arm, _) = await hashesAndSrc(GroupCTarget.cortexA53_55, mv);
        expect(x86.length, 3, reason: 'maxValue=$mv');
        expect(x86, equals(arm), reason: 'maxValue=$mv');
      }
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  group('color_temp LUT 行核 SIMD 变体与逐位对拍', () {
    test('x86（SSE2 路径）与 cortexA53_55（标量路径）批模式哈希逐字节一致',
        () async {
      if (detectMsvc() == null) return; // 无 MSVC 环境自动跳过
      // 单节点 color_temp_adjuster（LUT 模式，4000K vs 6500K 参考，增益
      // 非恒等）：1023 域匹配走 SIMD gather，65535 域失配标量回退。
      Future<(List<String>, String)> hashesAndSrc(
          GroupCTarget target, int maxValue) async {
        final graph = IspGraph();
        final ct = graph.addNode('color_temp_adjuster', 0, 0);
        graph.nodes[ct]!.name = 'ct';
        graph.nodes[ct]!.paramValues['codegenMode'] = 'lut';
        graph.nodes[ct]!.paramValues['temperature'] = 4000.0;
        graph.nodes[ct]!.paramValues['measured_cct'] = 6500;
        graph.groups.add(IspNodeGroup('g1', {ct}, name: 'ct1'));
        final files = await buildGroupBlackBoxCFiles(graph, graph.groups.single,
            readFile: readDisk,
            genTime: DateTime(2026, 1, 2, 3, 4, 5),
            target: target);
        final result = await buildWinVerifyApp(files,
            topName: 'isp_pipe_ct1_bb',
            inFormat: 'rgb',
            outFormat: 'rgb',
            hasScratch: false,
            maxValue: maxValue);
        expect(result.success, isTrue, reason: result.output);
        final run = await Process.run(
            result.artifactPath!, ['--frames', '3', '--dump-hash']);
        expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
        final lines = '${run.stdout}'
            .trim()
            .split('\n')
            .map((l) => l.trim())
            .where((l) => l.startsWith('frame '))
            .toList();
        return (lines, files['isp_pipe_ct1_bb.c']!);
      }

      // 变体分叉内容检查（SIMD gather 路径确实发射）。
      final (_, x86Src) = await hashesAndSrc(GroupCTarget.x86, 1023);
      expect(x86Src, contains('_mm_storeu_si128'));
      expect(x86Src, isNot(contains('arm_neon.h')));
      final (_, armSrc) = await hashesAndSrc(GroupCTarget.cortexA53_55, 1023);
      expect(armSrc, contains('vld3q_u16'));
      expect(armSrc, isNot(contains('emmintrin.h')));

      for (final mv in [1023, 65535]) {
        final (x86, _) = await hashesAndSrc(GroupCTarget.x86, mv);
        final (arm, _) = await hashesAndSrc(GroupCTarget.cortexA53_55, mv);
        expect(x86.length, 3, reason: 'maxValue=$mv');
        expect(x86, equals(arm), reason: 'maxValue=$mv');
      }
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  group('pseudo_color LUT 行核 SIMD 变体与逐位对拍', () {
    test('x86（SSE2 路径）与 cortexA53_55（标量路径）批模式哈希逐字节一致',
        () async {
      if (detectMsvc() == null) return; // 无 MSVC 环境自动跳过
      // 单节点 pseudo_color（LUT 模式，hot 色表，gain 1.5；mono 输入 →
      // RGB 输出）：1023 域匹配走 SIMD gather，65535 域失配标量回退。
      Future<(List<String>, String)> hashesAndSrc(
          GroupCTarget target, int maxValue) async {
        final graph = IspGraph();
        final pc = graph.addNode('pseudo_color', 0, 0);
        graph.nodes[pc]!.name = 'pc';
        graph.nodes[pc]!.paramValues['codegenMode'] = 'lut';
        graph.nodes[pc]!.paramValues['colormap'] = 'hot';
        graph.nodes[pc]!.paramValues['gain'] = 1.5;
        graph.groups.add(IspNodeGroup('g1', {pc}, name: 'pc1'));
        final files = await buildGroupBlackBoxCFiles(graph, graph.groups.single,
            readFile: readDisk,
            genTime: DateTime(2026, 1, 2, 3, 4, 5),
            target: target);
        final result = await buildWinVerifyApp(files,
            topName: 'isp_pipe_pc1_bb',
            inFormat: 'rgb',
            outFormat: 'rgb',
            hasScratch: false,
            maxValue: maxValue);
        expect(result.success, isTrue, reason: result.output);
        final run = await Process.run(
            result.artifactPath!, ['--frames', '3', '--dump-hash']);
        expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
        final lines = '${run.stdout}'
            .trim()
            .split('\n')
            .map((l) => l.trim())
            .where((l) => l.startsWith('frame '))
            .toList();
        return (lines, files['isp_pipe_pc1_bb.c']!);
      }

      // 变体分叉内容检查（SIMD gather 路径确实发射）。
      final (_, x86Src) = await hashesAndSrc(GroupCTarget.x86, 1023);
      expect(x86Src, contains('_mm_storeu_si128'));
      expect(x86Src, isNot(contains('arm_neon.h')));
      final (_, armSrc) = await hashesAndSrc(GroupCTarget.cortexA53_55, 1023);
      expect(armSrc, contains('vld1q_u16'));
      expect(armSrc, isNot(contains('emmintrin.h')));

      for (final mv in [1023, 65535]) {
        final (x86, _) = await hashesAndSrc(GroupCTarget.x86, mv);
        final (arm, _) = await hashesAndSrc(GroupCTarget.cortexA53_55, mv);
        expect(x86.length, 3, reason: 'maxValue=$mv');
        expect(x86, equals(arm), reason: 'maxValue=$mv');
      }
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  group('highlight clip LUT 行核 SIMD 变体与逐位对拍', () {
    test('x86（SSE2 路径）与 cortexA53_55（标量路径）批模式哈希逐字节一致',
        () async {
      if (detectMsvc() == null) return; // 无 MSVC 环境自动跳过
      // 单节点 highlight（clip 模式 + LUT，knee 0.8；RAW 1 通道输入输出）：
      // 1023 域匹配走 SIMD gather，65535 域失配标量回退。
      Future<(List<String>, String)> hashesAndSrc(
          GroupCTarget target, int maxValue) async {
        final graph = IspGraph();
        final hl = graph.addNode('highlight', 0, 0);
        graph.nodes[hl]!.name = 'hl';
        graph.nodes[hl]!.paramValues['mode'] = 'clip';
        graph.nodes[hl]!.paramValues['codegenMode'] = 'lut';
        graph.nodes[hl]!.paramValues['knee'] = 0.8;
        graph.groups.add(IspNodeGroup('g1', {hl}, name: 'hl1'));
        final files = await buildGroupBlackBoxCFiles(graph, graph.groups.single,
            readFile: readDisk,
            genTime: DateTime(2026, 1, 2, 3, 4, 5),
            target: target);
        final result = await buildWinVerifyApp(files,
            topName: 'isp_pipe_hl1_bb',
            inFormat: 'rgb',
            outFormat: 'rgb',
            hasScratch: false,
            maxValue: maxValue);
        expect(result.success, isTrue, reason: result.output);
        final run = await Process.run(
            result.artifactPath!, ['--frames', '3', '--dump-hash']);
        expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
        final lines = '${run.stdout}'
            .trim()
            .split('\n')
            .map((l) => l.trim())
            .where((l) => l.startsWith('frame '))
            .toList();
        return (lines, files['isp_pipe_hl1_bb.c']!);
      }

      // 变体分叉内容检查（SIMD gather 路径确实发射）。
      final (_, x86Src) = await hashesAndSrc(GroupCTarget.x86, 1023);
      expect(x86Src, contains('_mm_storeu_si128'));
      expect(x86Src, isNot(contains('arm_neon.h')));
      final (_, armSrc) = await hashesAndSrc(GroupCTarget.cortexA53_55, 1023);
      expect(armSrc, contains('vld1q_u16'));
      expect(armSrc, isNot(contains('emmintrin.h')));

      for (final mv in [1023, 65535]) {
        final (x86, _) = await hashesAndSrc(GroupCTarget.x86, mv);
        final (arm, _) = await hashesAndSrc(GroupCTarget.cortexA53_55, mv);
        expect(x86.length, 3, reason: 'maxValue=$mv');
        expect(x86, equals(arm), reason: 'maxValue=$mv');
      }
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  group('gamma 行核 SIMD 变体与逐位对拍', () {
    test('x86（SSE2 路径）与 cortexA53_55（标量路径）批模式哈希逐字节一致',
        () async {
      if (detectMsvc() == null) return; // 无 MSVC 环境自动跳过
      // 单节点 gamma（16 位 RGB → 8 位 RGBA，运行期 LUT）：非默认参数
      // 覆盖 LUT 构建与 gather；输出 uint8×4 哈希对拍（缓冲清零保证确定）。
      Future<(List<String>, String)> hashesAndSrc(
          GroupCTarget target, int maxValue) async {
        final graph = IspGraph();
        final gm = graph.addNode('gamma', 0, 0);
        graph.nodes[gm]!.name = 'gm';
        graph.nodes[gm]!.paramValues['gamma'] = 2.2;
        graph.nodes[gm]!.paramValues['brightness'] = 0.1;
        graph.nodes[gm]!.paramValues['contrast'] = 1.1;
        graph.groups.add(IspNodeGroup('g1', {gm}, name: 'gm1'));
        final files = await buildGroupBlackBoxCFiles(graph, graph.groups.single,
            readFile: readDisk,
            genTime: DateTime(2026, 1, 2, 3, 4, 5),
            target: target);
        final result = await buildWinVerifyApp(files,
            topName: 'isp_pipe_gm1_bb',
            inFormat: 'rgb',
            outFormat: 'rgb',
            hasScratch: true,
            maxValue: maxValue);
        expect(result.success, isTrue, reason: result.output);
        final run = await Process.run(
            result.artifactPath!, ['--frames', '3', '--dump-hash']);
        expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
        final lines = '${run.stdout}'
            .trim()
            .split('\n')
            .map((l) => l.trim())
            .where((l) => l.startsWith('frame '))
            .toList();
        return (lines, files['isp_pipe_gm1_bb.c']!);
      }

      // 变体分叉内容检查（SIMD gather 路径确实发射）。
      final (_, x86Src) = await hashesAndSrc(GroupCTarget.x86, 1023);
      expect(x86Src, contains('_mm_unpacklo_epi8'));
      expect(x86Src, isNot(contains('arm_neon.h')));
      final (_, armSrc) = await hashesAndSrc(GroupCTarget.cortexA53_55, 1023);
      expect(armSrc, contains('vst4_u8'));
      expect(armSrc, isNot(contains('emmintrin.h')));

      for (final mv in [1023, 65535]) {
        final (x86, _) = await hashesAndSrc(GroupCTarget.x86, mv);
        final (arm, _) = await hashesAndSrc(GroupCTarget.cortexA53_55, mv);
        expect(x86.length, 3, reason: 'maxValue=$mv');
        expect(x86, equals(arm), reason: 'maxValue=$mv');
      }
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  group('FP64 HSL 行核（x86 专属）SIMD 变体与逐位对拍', () {
    test('csc_hsl2rgb：x86（isp_csc_sse 双像素）与 cortexA53_55（标量融合'
        '循环）批模式哈希逐字节一致', () async {
      if (detectMsvc() == null) return; // 无 MSVC 环境自动跳过
      Future<(List<String>, String)> hashesAndSrc(
          GroupCTarget target, int maxValue) async {
        final graph = IspGraph();
        final csc = graph.addNode('csc_hsl2rgb', 0, 0);
        graph.nodes[csc]!.name = 'h2r';
        graph.groups.add(IspNodeGroup('g1', {csc}, name: 'h2r1'));
        final files = await buildGroupBlackBoxCFiles(graph, graph.groups.single,
            readFile: readDisk,
            genTime: DateTime(2026, 1, 2, 3, 4, 5),
            target: target);
        final result = await buildWinVerifyApp(files,
            topName: 'isp_pipe_h2r1_bb',
            inFormat: 'hsl',
            outFormat: 'rgb',
            hasScratch: false,
            maxValue: maxValue);
        expect(result.success, isTrue, reason: result.output);
        final run = await Process.run(
            result.artifactPath!, ['--frames', '3', '--dump-hash']);
        expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
        final lines = '${run.stdout}'
            .trim()
            .split('\n')
            .map((l) => l.trim())
            .where((l) => l.startsWith('frame '))
            .toList();
        return (lines, files['isp_pipe_h2r1_bb.c']!);
      }

      // 变体分叉内容检查：x86 走 isp_csc_sse 双像素，ARM 不登记行核。
      final (_, x86Src) = await hashesAndSrc(GroupCTarget.x86, 1023);
      expect(x86Src, contains('isp_csc_hsl2_to_rgb6'));
      expect(x86Src, contains('isp_csc_sse.h'));
      final (_, armSrc) = await hashesAndSrc(GroupCTarget.cortexA53_55, 1023);
      expect(armSrc, isNot(contains('isp_csc_hsl2_to_rgb6')));

      for (final mv in [1023, 65535]) {
        final (x86, _) = await hashesAndSrc(GroupCTarget.x86, mv);
        final (arm, _) = await hashesAndSrc(GroupCTarget.cortexA53_55, mv);
        expect(x86.length, 3, reason: 'maxValue=$mv');
        expect(x86, equals(arm), reason: 'maxValue=$mv');
      }
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('csc_rgb2hsl：x86（isp_csc_sse 双像素）与 cortexA53_55（标量融合'
        '循环）批模式哈希逐字节一致', () async {
      if (detectMsvc() == null) return; // 无 MSVC 环境自动跳过
      Future<(List<String>, String)> hashesAndSrc(
          GroupCTarget target, int maxValue) async {
        final graph = IspGraph();
        final csc = graph.addNode('csc_rgb2hsl', 0, 0);
        graph.nodes[csc]!.name = 'r2h';
        graph.groups.add(IspNodeGroup('g1', {csc}, name: 'r2h1'));
        final files = await buildGroupBlackBoxCFiles(graph, graph.groups.single,
            readFile: readDisk,
            genTime: DateTime(2026, 1, 2, 3, 4, 5),
            target: target);
        final result = await buildWinVerifyApp(files,
            topName: 'isp_pipe_r2h1_bb',
            inFormat: 'rgb',
            outFormat: 'hsl',
            hasScratch: false,
            maxValue: maxValue);
        expect(result.success, isTrue, reason: result.output);
        final run = await Process.run(
            result.artifactPath!, ['--frames', '3', '--dump-hash']);
        expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
        final lines = '${run.stdout}'
            .trim()
            .split('\n')
            .map((l) => l.trim())
            .where((l) => l.startsWith('frame '))
            .toList();
        return (lines, files['isp_pipe_r2h1_bb.c']!);
      }

      final (_, x86Src) = await hashesAndSrc(GroupCTarget.x86, 1023);
      expect(x86Src, contains('isp_csc_rgb2_to_hsl6'));
      final (_, armSrc) = await hashesAndSrc(GroupCTarget.cortexA53_55, 1023);
      expect(armSrc, isNot(contains('isp_csc_rgb2_to_hsl6')));

      for (final mv in [1023, 65535]) {
        final (x86, _) = await hashesAndSrc(GroupCTarget.x86, mv);
        final (arm, _) = await hashesAndSrc(GroupCTarget.cortexA53_55, mv);
        expect(x86.length, 3, reason: 'maxValue=$mv');
        expect(x86, equals(arm), reason: 'maxValue=$mv');
      }
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  group('FP64 调节器行核（x86 专属）SIMD 变体与逐位对拍', () {
    test('sat_bright（rgb）：x86（SSE2 双像素）与 cortexA53_55（标量融合'
        '循环）批模式哈希逐字节一致', () async {
      if (detectMsvc() == null) return; // 无 MSVC 环境自动跳过
      Future<(List<String>, String)> hashesAndSrc(
          GroupCTarget target, int maxValue) async {
        final graph = IspGraph();
        final sb = graph.addNode('sat_bright_adjuster', 0, 0);
        graph.nodes[sb]!.name = 'sb';
        graph.nodes[sb]!.paramValues['sat_gain'] = 1.3;
        graph.nodes[sb]!.paramValues['bright_gain'] = 1.1;
        graph.groups.add(IspNodeGroup('g1', {sb}, name: 'sb1'));
        final files = await buildGroupBlackBoxCFiles(graph, graph.groups.single,
            readFile: readDisk,
            genTime: DateTime(2026, 1, 2, 3, 4, 5),
            target: target);
        final result = await buildWinVerifyApp(files,
            topName: 'isp_pipe_sb1_bb',
            inFormat: 'rgb',
            outFormat: 'rgb',
            hasScratch: false,
            maxValue: maxValue);
        expect(result.success, isTrue, reason: result.output);
        final run = await Process.run(
            result.artifactPath!, ['--frames', '3', '--dump-hash']);
        expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
        final lines = '${run.stdout}'
            .trim()
            .split('\n')
            .map((l) => l.trim())
            .where((l) => l.startsWith('frame '))
            .toList();
        return (lines, files['isp_pipe_sb1_bb.c']!);
      }

      final (_, x86Src) = await hashesAndSrc(GroupCTarget.x86, 1023);
      expect(x86Src, contains('_mm_cvtepi32_pd'));
      expect(x86Src, contains('isp_csc_clamp2'));
      final (_, armSrc) = await hashesAndSrc(GroupCTarget.cortexA53_55, 1023);
      expect(armSrc, isNot(contains('isp_csc_clamp2')));

      for (final mv in [1023, 65535]) {
        final (x86, _) = await hashesAndSrc(GroupCTarget.x86, mv);
        final (arm, _) = await hashesAndSrc(GroupCTarget.cortexA53_55, mv);
        expect(x86.length, 3, reason: 'maxValue=$mv');
        expect(x86, equals(arm), reason: 'maxValue=$mv');
      }
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('black_level（Bayer 四相位）：x86（SSE2 双像素）与 cortexA53_55'
        '（标量融合循环）批模式哈希逐字节一致', () async {
      if (detectMsvc() == null) return; // 无 MSVC 环境自动跳过
      Future<(List<String>, String)> hashesAndSrc(
          GroupCTarget target, int maxValue) async {
        final graph = IspGraph();
        final bl = graph.addNode('black_level', 0, 0);
        graph.nodes[bl]!.name = 'bl';
        graph.nodes[bl]!.paramValues['r'] = 8.0;
        graph.nodes[bl]!.paramValues['gr'] = 6.0;
        graph.nodes[bl]!.paramValues['gb'] = 7.0;
        graph.nodes[bl]!.paramValues['b'] = 10.0;
        graph.groups.add(IspNodeGroup('g1', {bl}, name: 'bl1'));
        final files = await buildGroupBlackBoxCFiles(graph, graph.groups.single,
            readFile: readDisk,
            genTime: DateTime(2026, 1, 2, 3, 4, 5),
            target: target);
        final result = await buildWinVerifyApp(files,
            topName: 'isp_pipe_bl1_bb',
            inFormat: 'rgb',
            outFormat: 'rgb',
            hasScratch: false,
            maxValue: maxValue);
        expect(result.success, isTrue, reason: result.output);
        final run = await Process.run(
            result.artifactPath!, ['--frames', '3', '--dump-hash']);
        expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
        final lines = '${run.stdout}'
            .trim()
            .split('\n')
            .map((l) => l.trim())
            .where((l) => l.startsWith('frame '))
            .toList();
        return (lines, files['isp_pipe_bl1_bb.c']!);
      }

      final (_, x86Src) = await hashesAndSrc(GroupCTarget.x86, 1023);
      expect(x86Src, contains('_mm_cmple_pd'));
      final (_, armSrc) = await hashesAndSrc(GroupCTarget.cortexA53_55, 1023);
      expect(armSrc, isNot(contains('_mm_cmple_pd')));

      for (final mv in [1023, 65535]) {
        final (x86, _) = await hashesAndSrc(GroupCTarget.x86, mv);
        final (arm, _) = await hashesAndSrc(GroupCTarget.cortexA53_55, mv);
        expect(x86.length, 3, reason: 'maxValue=$mv');
        expect(x86, equals(arm), reason: 'maxValue=$mv');
      }
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('color_controller（LUT）：x86（H int32 + S/L FP64 双像素）与'
        'cortexA53_55（标量融合循环）批模式哈希逐字节一致', () async {
      if (detectMsvc() == null) return; // 无 MSVC 环境自动跳过
      Future<(List<String>, String)> hashesAndSrc(
          GroupCTarget target, int maxValue) async {
        final graph = IspGraph();
        final cc = graph.addNode('color_controller', 0, 0);
        graph.nodes[cc]!.name = 'cc';
        graph.nodes[cc]!.paramValues['codegenMode'] = 'lut';
        graph.nodes[cc]!.paramValues['h_center'] = 0.0;
        graph.nodes[cc]!.paramValues['q'] = 2.0;
        graph.nodes[cc]!.paramValues['h_shift'] = 30.0;
        graph.nodes[cc]!.paramValues['s_gain'] = 1.2;
        graph.nodes[cc]!.paramValues['l_gain'] = 1.1;
        graph.groups.add(IspNodeGroup('g1', {cc}, name: 'cc1'));
        final files = await buildGroupBlackBoxCFiles(graph, graph.groups.single,
            readFile: readDisk,
            genTime: DateTime(2026, 1, 2, 3, 4, 5),
            target: target);
        final result = await buildWinVerifyApp(files,
            topName: 'isp_pipe_cc1_bb',
            inFormat: 'hsl',
            outFormat: 'hsl',
            hasScratch: false,
            maxValue: maxValue);
        expect(result.success, isTrue, reason: result.output);
        final run = await Process.run(
            result.artifactPath!, ['--frames', '3', '--dump-hash']);
        expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
        final lines = '${run.stdout}'
            .trim()
            .split('\n')
            .map((l) => l.trim())
            .where((l) => l.startsWith('frame '))
            .toList();
        return (lines, files['isp_pipe_cc1_bb.c']!);
      }

      final (_, x86Src) = await hashesAndSrc(GroupCTarget.x86, 1023);
      expect(x86Src, contains('_mm_cmpgt_epi32'));
      expect(x86Src, contains('isp_csc_clamp2'));
      final (_, armSrc) = await hashesAndSrc(GroupCTarget.cortexA53_55, 1023);
      expect(armSrc, isNot(contains('isp_csc_clamp2')));

      for (final mv in [1023, 65535]) {
        final (x86, _) = await hashesAndSrc(GroupCTarget.x86, mv);
        final (arm, _) = await hashesAndSrc(GroupCTarget.cortexA53_55, mv);
        expect(x86.length, 3, reason: 'maxValue=$mv');
        expect(x86, equals(arm), reason: 'maxValue=$mv');
      }
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  group('标签页 key 的目标后缀', () {
    test('同编组不同 target 开两个标签、同 target 复用激活', () {
      final state = IspStudioState();
      addTearDown(state.dispose);
      final g = state.graph.addNode('gamma', 0, 0);
      state.graph.groups.add(IspNodeGroup('g1', {g}, name: 'gg'));

      state.openGroupCodeTab('g1');
      expect(state.openCodeTabs, ['group:g1@cortexA53_55']);
      expect(state.activeTab, 1);

      // 不同 target：新开标签。
      state.openGroupCodeTab('g1', target: GroupCTarget.x86);
      expect(state.openCodeTabs,
          ['group:g1@cortexA53_55', 'group:g1@x86']);
      expect(state.activeTab, 2);

      // 同 target：复用激活不重复添加。
      state.openGroupCodeTab('g1');
      expect(state.openCodeTabs.length, 2);
      expect(state.activeTab, 1);

      // 黑盒标签同口径。
      state.openGroupBlackBoxCodeTab('g1', target: GroupCTarget.cortexA710_725);
      expect(state.openCodeTabs.last, 'gbb:g1@cortexA710_725');
      expect(state.activeTab, 3);

      // 解散编组：全部目标后缀的标签一并关闭。
      state.ungroup('g1');
      expect(state.openCodeTabs, isEmpty);
      expect(state.activeTab, 0);
    });
  });
}
