import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:debug_tool_set/modules/isp_studio/models/isp_node.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/node_code.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/source_extract.dart';

/// 用真实文件读取注入加载器（flutter test 的工作目录是工程根）。
Future<String> _diskRead(String path) => File(path).readAsString();

Future<String> _loadFromDisk(String typeId) =>
    loadNodeCode(typeId, readFile: _diskRead);

void main() {
  group('extractSymbol', () {
    test('普通函数（含 /// 文档注释）', () {
      const src = '''
import 'dart:math';

/// 计算两数之和。
/// 第二行文档。
int add(int a, int b) {
  return a + b;
}

int sub(int a, int b) => a - b;
''';
      final code = extractSymbol(src, 'add')!;
      expect(code, startsWith('/// 计算两数之和。'));
      expect(code, contains('return a + b;'));
      expect(code.trimRight(), endsWith('}'));
      // 不包含后面的函数。
      expect(code, isNot(contains('sub')));
    });

    test('多行签名函数', () {
      const src = '''
Uint16List unpackBayer(
  Uint8List bytes, {
  required int width,
  required int height,
}) {
  final out = Uint16List(width * height);
  return out;
}
''';
      final code = extractSymbol(src, 'unpackBayer')!;
      expect(code, contains('required int width,'));
      expect(code.trimRight(), endsWith('}'));
    });

    test('表达式体函数（含多行列表字面量）', () {
      const src = '''
List<double> colorTempCcm(List<double> gains) => [
      gains[0], 0, 0,
      0, gains[1], 0,
    ];

int get workers => math.max(2, 4);
''';
      final ccm = extractSymbol(src, 'colorTempCcm')!;
      expect(ccm, contains('gains[1]'));
      expect(ccm.trimRight(), endsWith('];'));
      final workers = extractSymbol(src, 'workers')!;
      expect(workers.trimRight(), endsWith(';'));
    });

    test('枚举与 const 列表', () {
      const src = '''
enum BayerPattern {
  /// (0,0)=R
  rggb,

  /// (0,0)=B
  bggr;
}

const axial = [
  [-1, 0],
  [1, 0],
];
''';
      final pat = extractSymbol(src, 'BayerPattern')!;
      expect(pat, contains('bggr;'));
      expect(pat.trimRight(), endsWith('}'));
      final axial = extractSymbol(src, 'axial')!;
      expect(axial, contains('[1, 0],'));
      expect(axial.trimRight(), endsWith('];'));
    });

    test('包装声明 => 调用不会被误判为目标符号', () {
      const src = '''
double lpipsScoreInIsolate(Map<String, Object?> msg) => lpipsScore(
    msg['a'] as Uint8List, msg['b'] as Uint8List, 4, 4);

double lpipsScore(Uint8List a, Uint8List b, int width, int height) {
  return 0;
}
''';
      final code = extractSymbol(src, 'lpipsScore')!;
      expect(code, startsWith('double lpipsScore(Uint8List a'));
    });

    test('找不到返回 null', () {
      expect(extractSymbol('int foo() => 1;', 'bar'), isNull);
    });
  });

  group('extractSwitchCase', () {
    test('普通分支捕获到下一个 case 之前', () {
      const src = '''
    switch (typeId) {
      case 'mux4':
        final sel = 1;
        break;
      case 'demosaic':
        doDemosaic();
      default:
        throw StateError('x');
    }
''';
      final code = extractSwitchCase(src, 'mux4')!;
      expect(code, contains("case 'mux4':"));
      expect(code, contains('final sel = 1;'));
      expect(code, isNot(contains('demosaic')));
    });

    test('空贯穿标签组（preview 风格）整组捕获', () {
      const src = '''
      case 'preview':
      case 'histogram':
      case 'waveform':
        final monoData = getPortData(op, 'in_mono');
        if (monoData != null) {
          use(monoData);
        }
        break;
      case 'audio_level':
      case 'audio_waveform':
        // 音频汇点，不改变数据。
        break;
      default:
        throw StateError('未知节点类型');
''';
      final code = extractSwitchCase(src, 'preview')!;
      expect(code, contains("case 'histogram':"));
      expect(code, contains("case 'waveform':"));
      expect(code, contains('final monoData'));
      expect(code, isNot(contains('audio_level')));
    });

    test('带语句的标签行是下一组的开始', () {
      const src = '''
      case 'a':
        doA();
        break;
      case 'b':        frame.requireHsl('HSL调节器');
        doB();
        break;
''';
      final code = extractSwitchCase(src, 'a')!;
      expect(code, contains('doA();'));
      expect(code, isNot(contains('requireHsl')));
    });

    test('找不到返回 null', () {
      expect(extractSwitchCase("case 'a':\n  break;", 'zzz'), isNull);
    });
  });

  group('indexDeclarations', () {
    test('索引全部顶层声明（类成员不入索引）', () {
      const src = '''
import 'dart:math';

/// 文档。
const double kFoo = 1.5;

final table = List<double>.filled(4, 0);

enum Kind { a, b }

class Helper {
  int method() => 1;
}

int topFn(int x) => x + 1;

typedef Callback = void Function(int v);
''';
      final idx = indexDeclarations(src);
      expect(
          idx.keys,
          containsAll(
              ['kFoo', 'table', 'Kind', 'Helper', 'topFn', 'Callback']));
      expect(idx.containsKey('method'), isFalse);
      expect(idx.containsKey('math'), isFalse);
      expect(idx['kFoo'], startsWith('/// 文档。'));
    });

    test('record 返回值与泛型返回值的函数名解析', () {
      const src = '''
(double, double) gains(Uint16List rgb, {int stride = 16}) => (1, 2);

Future<(int, int)> load(String path) async => (1, 2);
''';
      final idx = indexDeclarations(src);
      expect(idx.keys, containsAll(['gains', 'load']));
    });
  });

  group('loadCodeWithClosure（调用闭包）', () {
    final sources = {
      'a.dart': '''
int entry(int x) {
  return helperA(x) + helperB(x) + unknownSdk(x);
}

/// helper A 的文档。
int helperA(int x) => x * 2;

int helperB(int x) {
  return helperA(x - 1) + leaf(x);
}

int leaf(int x) => x - 1;
''',
      'b.dart': '''
int shared(int x) => x + 100;
''',
      'c.dart': '''
int shared(int x) => x + 1;

int useShared(int x) => shared(x);

int fx(int v) => v > 0 ? gx(v - 1) : 0;

int gx(int v) => fx(v);
''',
    };

    Future<String> fakeRead(String path) async =>
        sources[path.split('/').last]!;

    const universe = ['a.dart', 'b.dart', 'c.dart'];

    test('多级调用闭包收敛、去重、BFS 顺序', () async {
      final keys = <String>{};
      final code = await loadCodeWithClosure(
        [const NodeCodeSeg('a.dart', ['entry'])],
        readFile: fakeRead,
        sourceFiles: universe,
        keysOut: keys,
      );
      // 入口在前，helperA/helperB/leaf 按发现顺序附后。
      const order = [
        'int entry(int x)',
        'int helperA(int x)',
        'int helperB(int x)',
        'int leaf(int x)',
      ];
      var pos = 0;
      for (final marker in order) {
        final i = code.indexOf(marker, pos);
        expect(i, greaterThanOrEqualTo(pos), reason: '$marker 缺失或顺序错误');
        pos = i;
      }
      // 去重：helperA 被 entry 与 helperB 各调用一次，只出现一次。
      expect('int helperA(int x)'.allMatches(code).length, 1);
      // 自动补齐的段带符号名与 (被引用) 标记，且保留文档注释。
      expect(code, contains('helperA (被引用)'));
      expect(code, contains('/// helper A 的文档。'));
      expect(
          keys,
          containsAll({
            'a.dart:entry',
            'a.dart:helperA',
            'a.dart:helperB',
            'a.dart:leaf',
          }));
      // 索引中不存在的名字（SDK 等）不产生段落。
      expect(code, isNot(contains('shared')));
    });

    test('循环调用收敛', () async {
      final code = await loadCodeWithClosure(
        [const NodeCodeSeg('c.dart', ['fx'])],
        readFile: fakeRead,
        sourceFiles: universe,
      );
      expect(code, contains('int gx(int v)'));
      expect('int fx(int v)'.allMatches(code).length, 1);
      expect('int gx(int v)'.allMatches(code).length, 1);
    });

    test('跨文件同名优先取引用者所在文件', () async {
      final code = await loadCodeWithClosure(
        [const NodeCodeSeg('c.dart', ['useShared'])],
        readFile: fakeRead,
        sourceFiles: universe,
      );
      expect(code, contains('int shared(int x) => x + 1;'));
      expect(code, isNot(contains('x + 100')));
    });

    test('入口符号缺失时插入占位注释而不是静默丢弃', () async {
      final code = await loadCodeWithClosure(
        [const NodeCodeSeg('a.dart', ['notExist'])],
        readFile: fakeRead,
        sourceFiles: universe,
      );
      expect(code, contains('// 未能在 a.dart 中定位符号 notExist'));
    });
  });

  group('nodeCodeSpec 防漂移（对照真实源码）', () {
    test('注册表中的每种节点类型都有规格，且无游离条目', () {
      for (final typeId in IspNodeRegistry.types.keys) {
        expect(nodeCodeSpec.containsKey(typeId), isTrue,
            reason: '$typeId 缺少 nodeCodeSpec 条目');
      }
      for (final key in nodeCodeSpec.keys) {
        expect(IspNodeRegistry.types.containsKey(key), isTrue,
            reason: '$key 不是已注册的节点类型');
      }
    });

    test('pipelineSourceFiles 与资产目录实际内容一致', () {
      String base(String p) => p.split(RegExp(r'[\\/]')).last;
      final dir = Directory('lib/modules/isp_studio/pipeline');
      final actual = <String>[
        for (final f in dir.listSync().whereType<File>())
          if (f.path.endsWith('.dart')) base(f.path),
        for (final f
            in Directory('${dir.path}/metrics').listSync().whereType<File>())
          if (f.path.endsWith('.dart')) 'metrics/${base(f.path)}',
      ]..sort();
      expect([...pipelineSourceFiles]..sort(), actual,
          reason: 'pipeline/ 源文件有增删时需同步 pipelineSourceFiles');
    });

    test('规格中的每个入口符号都能从对应真实文件中提取到非空内容', () {
      for (final entry in nodeCodeSpec.entries) {
        for (final seg in entry.value) {
          final file = File('lib/modules/isp_studio/pipeline/${seg.file}');
          expect(file.existsSync(), isTrue, reason: '${seg.file} 不存在');
          final source = file.readAsStringSync();
          for (final sym in seg.symbols) {
            final text = sym.startsWith('case:')
                ? extractSwitchCase(source, sym.substring(5))
                : extractSymbol(source, sym);
            expect(text, isNotNull,
                reason: '${entry.key}: 未能在 ${seg.file} 中定位符号 $sym');
            expect(text!.trim(), isNotEmpty,
                reason: '${entry.key}: 符号 $sym 提取内容为空');
          }
        }
      }
    });

    test('每个节点的最终展示文本闭包收敛（无「调用了但没提取」的索引符号）',
        () async {
      // 全局索引名字集（与加载器使用同一份真实源码）。
      final globalNames = <String>{};
      for (final f in pipelineSourceFiles) {
        final file = File('lib/modules/isp_studio/pipeline/$f');
        globalNames.addAll(indexDeclarations(file.readAsStringSync()).keys);
      }
      for (final typeId in IspNodeRegistry.types.keys) {
        final keys = <String>{};
        final code =
            await loadNodeCode(typeId, readFile: _diskRead, keysOut: keys);
        final included = {
          for (final k in keys) k.substring(k.indexOf(':') + 1),
        };
        for (final id in scanIdentifiers(code)) {
          if (globalNames.contains(id)) {
            expect(included.contains(id), isTrue,
                reason: '$typeId: 引用了索引符号 $id 但未包含进展示文本');
          }
        }
      }
    });

    test('loadNodeCode 产出真实函数体与来源分隔注释', () async {
      final code = await _loadFromDisk('black_level');
      expect(code, contains('// ── 来自 pipeline/isp_kernels.dart ──'));
      expect(code, contains('void applyBlackLevel('));
      expect(code, contains('final offsets = List<double>.filled(4, 0);'));
    });

    test('整个 typeId 无规格时返回默认占位', () async {
      expect(await _loadFromDisk('__no_such_type__'),
          '// 该节点类型暂无可展示的代码');
    });

    test('抽查：helper 经闭包自动包含', () async {
      // demosaic：_demosaicPixel → _avgNeighbors / _axial。
      final demosaic = await _loadFromDisk('demosaic');
      expect(demosaic, contains('void _demosaicPixel('));
      expect(demosaic, contains('int _avgNeighbors('));
      expect(demosaic, contains('const _axial'));
      // ahe：applyClahe → _claheTileLuts / _claheBilinear。
      final ahe = await _loadFromDisk('ahe');
      expect(ahe, contains('Float64List _claheTileLuts('));
      expect(ahe, contains('double _claheBilinear('));
      // sharpen：applySharpen → _clampTo。
      final sharpen = await _loadFromDisk('sharpen');
      expect(sharpen, contains('void applySharpen('));
      expect(sharpen, contains('int _clampTo('));
      // vectorscope：vectorscope → _aaSegment → _kAaFullWeight。
      final vectorscope = await _loadFromDisk('vectorscope');
      expect(vectorscope, contains('void _aaSegment('));
      expect(vectorscope, contains('const int _kAaFullWeight'));
      // csc_yuv2rgb：yuvToRgb 自包含（无 helper）。
      final yuv2rgb = await _loadFromDisk('csc_yuv2rgb');
      expect(yuv2rgb, contains('Uint16List yuvToRgb('));
      // dpc：applyDpc → _phaseNeighbors / _sortedValues（闭包带出真实 helper）。
      final dpc = await _loadFromDisk('dpc');
      expect(dpc, contains('List<int> _phaseNeighbors('));
      expect(dpc, contains('List<int> _sortedValues('));
    });
  });
}
