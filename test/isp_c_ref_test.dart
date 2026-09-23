import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/models/isp_node.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/node_c_code.dart';

void main() {
  const cRefDir = 'lib/modules/isp_studio/c_ref';

  test('每个嵌入式相关节点类型的映射文件在磁盘上存在', () {
    for (final entry in nodeCCodeFiles.entries) {
      expect(entry.value, isNotEmpty, reason: entry.key);
      for (final file in entry.value) {
        expect(
          File('$cRefDir/$file').existsSync(),
          isTrue,
          reason: '${entry.key} -> $file',
        );
      }
    }
  });

  test('C 映射与 PC 集合无交集、无游离条目，且并集覆盖注册表全部类型', () {
    final registered = IspNodeRegistry.types.keys.toSet();
    final cTypes = nodeCCodeFiles.keys.toSet();

    // 无交集。
    expect(cTypes.intersection(pcSideNodeTypes), isEmpty);

    // 无游离条目：两个集合中的 typeId 都必须是注册表中的真实类型。
    final unknown = (cTypes.union(pcSideNodeTypes)).difference(registered);
    expect(unknown, isEmpty, reason: '映射/集合中存在注册表没有的类型：$unknown');

    // 注册表每个 typeId 必须 ∈（nodeCCodeFiles ∪ pcSideNodeTypes）。
    final uncovered = registered.difference(cTypes.union(pcSideNodeTypes));
    expect(uncovered, isEmpty, reason: '注册表类型未归类：$uncovered');
  });

  test('loadCRefFile 注入 readFile 返回内容，映射中每个文件内容非空', () async {
    // 注入 readFile：按约定路径回调。
    final injected = await loadCRefFile(
      'isp_gamma.c',
      readFile: (path) async => '// fake: $path',
    );
    expect(injected, contains('$cRefDir/isp_gamma.c'));

    // 真实磁盘读取：映射中出现的每个文件（去重）内容非空。
    final files = nodeCCodeFiles.values.expand((l) => l).toSet();
    for (final file in files) {
      final content = await loadCRefFile(
        file,
        readFile: (path) => File(path).readAsString(),
      );
      expect(content.trim(), isNotEmpty, reason: file);
    }
  });

  test('nodeCCodeFileList 共享层 isp_common.h/.c 置于最前', () async {
    for (final typeId in nodeCCodeFiles.keys) {
      final files = nodeCCodeFileList(typeId);
      expect(files[0], 'isp_common.h', reason: typeId);
      expect(files[1], 'isp_common.c', reason: typeId);
      // 其余顺序与映射表一致（映射中若显式列出 isp_common.* 则去重）。
      final expectedRest = [
        for (final f in nodeCCodeFiles[typeId]!)
          if (f != 'isp_common.h' && f != 'isp_common.c') f,
      ];
      expect(files.sublist(2), expectedRest, reason: typeId);
    }
    // 未知类型 → 空列表。
    expect(nodeCCodeFileList('__nope__'), isEmpty);

    // 防漂移：列表中除 isp_common.h 外的每个 .h 都必须确实
    // #include "isp_common.h"（否则自动补全会失真）。
    final headers = nodeCCodeFiles.values
        .expand((l) => l)
        .toSet()
        .where((f) => f.endsWith('.h') && f != 'isp_common.h');
    for (final h in headers) {
      final content = await loadCRefFile(
        h,
        readFile: (path) => File(path).readAsString(),
      );
      expect(content, contains('isp_common.h'), reason: h);
    }
  });

  test('exportCRefFiles 把全部文件按原名写入目标目录', () async {
    final dir = await Directory.systemTemp.createTemp('isp_cref_export_');
    addTearDown(() => dir.delete(recursive: true));

    final files = ['isp_common.h', 'isp_gamma.h', 'isp_gamma.c'];
    final (ok, failed) = await exportCRefFiles(
      files,
      dir.path,
      readFile: (path) async => '// fake: $path',
    );
    expect(ok, files.length);
    expect(failed, isEmpty);
    for (final f in files) {
      final written = File('${dir.path}/$f');
      expect(written.existsSync(), isTrue, reason: f);
      expect(await written.readAsString(), contains('$cRefDir/$f'));
    }

    // 单个文件读取失败：不中断其余文件，计入失败列表。
    final (ok2, failed2) = await exportCRefFiles(
      files,
      dir.path,
      readFile: (path) async =>
          path.endsWith('isp_gamma.c') ? throw StateError('boom') : 'x',
    );
    expect(ok2, files.length - 1);
    expect(failed2, ['isp_gamma.c']);
  });

  test(
    'MSVC 语法检查（scripts/c_syntax_check.bat）',
    () async {
      final bat = File('scripts/c_syntax_check.bat');
      const msvcRoots = [
        r'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC',
        r'C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\VC\Tools\MSVC',
      ];
      final msvcOk = msvcRoots.any((root) =>
          Directory(root).existsSync() &&
          Directory(root).listSync().isNotEmpty);
      if (!bat.existsSync() || !msvcOk) {
        // 无 MSVC 环境（CI / 打包机）时跳过。
        return;
      }
      final cFiles = [
        for (final f in Directory(cRefDir).listSync().whereType<File>())
          if (f.path.endsWith('.c'))
            f.absolute.path.replaceAll('/', r'\'),
      ]..sort();
      expect(cFiles, isNotEmpty);
      final result = await Process.run(
        'cmd',
        ['/c', r'scripts\c_syntax_check.bat', ...cFiles],
        workingDirectory: Directory.current.path,
      );
      final output = '${result.stdout}\n${result.stderr}';
      expect(output, isNot(contains('error C')), reason: output);
    },
    // cl 逐个语法检查 20+ 个文件较慢，放宽超时。
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
