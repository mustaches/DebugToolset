import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/raw_sidecar.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';

void main() {
  group('readRawSidecarBlackLevels', () {
    Future<File> writeTxt(String rawPath, String content) async {
      final f = File(rawPath.replaceAll('.raw', '.txt'));
      await f.writeAsString(content);
      return f;
    }

    test('解析 [common] 节黑电平并除以 16', () async {
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final raw = File('${Directory.systemTemp.path}/sidecar_$stamp.raw');
      await raw.writeAsBytes([0]);
      final txt = await writeTxt(raw.path, '''
[common]
Width=3840
BlackLevel_R=804
BlackLevel_Gr=806
BlackLevel_Gb=804
BlackLevel_B=805
[Frame0]
BlackLevel_R=9999
''');
      try {
        final levels = await readRawSidecarBlackLevels(raw.path);
        expect(levels, isNotNull);
        expect(levels!.$1, closeTo(50.25, 1e-9));
        expect(levels.$2, closeTo(50.375, 1e-9));
        expect(levels.$3, closeTo(50.25, 1e-9));
        expect(levels.$4, closeTo(50.3125, 1e-9));
      } finally {
        await raw.delete();
        await txt.delete();
      }
    });

    test('txt 不存在或缺字段返回 null', () async {
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final missing =
          '${Directory.systemTemp.path}/sidecar_none_$stamp.raw';
      expect(await readRawSidecarBlackLevels(missing), isNull);

      final raw = File('${Directory.systemTemp.path}/sidecar_bad_$stamp.raw');
      await raw.writeAsBytes([0]);
      final txt = await writeTxt(raw.path, '[common]\nWidth=3840\n');
      try {
        expect(await readRawSidecarBlackLevels(raw.path), isNull);
      } finally {
        await raw.delete();
        await txt.delete();
      }
    });
  });

  group('IspStudioState 黑电平自动填充', () {
    test('设置 RAW 源文件后，宽高与下游黑电平被同名 txt 填充', () async {
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final raw = File('${Directory.systemTemp.path}/autofill_$stamp.raw');
      await raw.writeAsBytes([0]);
      final txt = File(raw.path.replaceAll('.raw', '.txt'));
      await txt.writeAsString('[common]\n'
          'Width=640\nHeight=480\n'
          'BlackLevel_R=804\nBlackLevel_Gr=806\n'
          'BlackLevel_Gb=804\nBlackLevel_B=805\n');
      try {
        final state = IspStudioState(); // 默认图：源→黑电平→…
        final srcId = state.graph.nodes.entries
            .firstWhere((e) => e.value.typeId == 'bayer_source')
            .key;
        final blId = state.graph.nodes.entries
            .firstWhere((e) => e.value.typeId == 'black_level')
            .key;

        state.setParam(srcId, 'filePath', raw.path);
        await state.autoFillFromSidecar(srcId);

        // 源节点宽高被 txt 更新（默认 3840x2160 → 640x480）。
        final src = state.graph.nodes[srcId]!.paramValues;
        expect(src['width'], 640);
        expect(src['height'], 480);
        // 下游黑电平节点被填充（16 倍刻度 ÷ 16）。
        final bl = state.graph.nodes[blId]!.paramValues;
        expect(bl['r'], closeTo(50.25, 1e-9));
        expect(bl['gr'], closeTo(50.375, 1e-9));
        expect(bl['gb'], closeTo(50.25, 1e-9));
        expect(bl['b'], closeTo(50.3125, 1e-9));
        expect(state.statusMessage, contains('640x480'));
      } finally {
        await raw.delete();
        await txt.delete();
      }
    });

    test('同名 txt 缺失时保持节点参数不变', () async {
      final state = IspStudioState();
      final srcId = state.graph.nodes.entries
          .firstWhere((e) => e.value.typeId == 'bayer_source')
          .key;
      final blId = state.graph.nodes.entries
          .firstWhere((e) => e.value.typeId == 'black_level')
          .key;
      state.setParam(srcId, 'filePath', '/nonexistent/x.raw');
      await state.autoFillFromSidecar(srcId);
      expect(state.graph.nodes[blId]!.paramValues['r'], 0.0);
      expect(state.graph.nodes[srcId]!.paramValues['width'], 3840);
    });
  });
}
