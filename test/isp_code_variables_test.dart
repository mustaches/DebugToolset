import 'package:flutter_test/flutter_test.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/code_variables.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/node_code.dart';

CodeVariable? _find(List<CodeVariable> vars, String name) {
  for (final v in vars) {
    if (v.name == name) return v;
  }
  return null;
}

void main() {
  group('extractVariables', () {
    test('提取 final/var 声明并推断字面量类型', () {
      final vars = extractVariables('''
final pixels = width * height;
var sum = 0, count = 0;
final gamma = 2.2;
final name = 'demo';
final flag = true;
final buf = Uint16List(pixels);
final table = List<double>.filled(4, 0);
''');
      expect(_find(vars, 'pixels')!.type, 'final');
      expect(_find(vars, 'sum')!.type, 'int');
      expect(_find(vars, 'sum')!.value, '0');
      expect(_find(vars, 'count')!.type, 'int');
      expect(_find(vars, 'gamma')!.type, 'double');
      expect(_find(vars, 'name')!.type, 'String');
      expect(_find(vars, 'flag')!.type, 'bool');
      expect(_find(vars, 'buf')!.type, 'Uint16List');
      expect(_find(vars, 'table')!.type, 'List<double>');
    });

    test('数组字面量拆分为元素序列', () {
      final vars = extractVariables('''
const axial = [
  [-1, 0],
  [1, 0],
  [0, -1],
  [0, 1],
];
''');
      final v = _find(vars, 'axial')!;
      expect(v.type, 'List');
      expect(v.items, ['[-1, 0]', '[1, 0]', '[0, -1]', '[0, 1]']);
    });

    test('注释与字符串中的内容不会被误判', () {
      final vars = extractVariables('''
// final fake = 1;
/* var alsoFake = 2; */
final real = 3; // var trailing = 4;
final msg = 'var inString = 5';
''');
      expect(vars.map((v) => v.name), ['real', 'msg']);
    });

    test('解构与 const 字面量不产生变量', () {
      final vars = extractVariables('''
final (w, h) = await sourceDimensions(t, p);
int colorAt(int x, int y) {
  return const [0, 1, 1, 2][0];
}
''');
      expect(vars, isEmpty);
    });

    test('同名变量只保留首次出现', () {
      final vars = extractVariables('''
for (var i = 0; i < 3; i++) {}
for (var i = 0; i < 5; i++) {}
''');
      expect(vars.where((v) => v.name == 'i'), hasLength(1));
    });

    test('属性访问不误判为类型', () {
      final vars = extractVariables('final max = frame.maxValue;');
      expect(_find(vars, 'max')!.type, 'final');
    });

    test('每个内置节点片段都能解析出变量（或确认无变量）', () {
      // 冒烟测试：所有片段解析不抛异常；关键片段应含已知变量。
      for (final entry in nodeSourceCode.entries) {
        expect(() => extractVariables(entry.value), returnsNormally,
            reason: entry.key);
      }
      final bl = extractVariables(nodeSourceCode['black_level']!);
      expect(_find(bl, 'offsets'), isNotNull);
      final gamma = extractVariables(nodeSourceCode['gamma']!);
      expect(_find(gamma, 'lut')!.type, 'Uint8List');
      final demosaic = extractVariables(nodeSourceCode['demosaic']!);
      expect(_find(demosaic, '_axial')!.items, hasLength(4));
    });
  });

  group('groupNodeVariables（Input / Output / Inside）', () {
    test('每种节点类型都有 Input 与 Output 描述', () {
      for (final typeId in nodeSourceCode.keys) {
        final groups = groupNodeVariables(typeId, nodeSourceCode[typeId]!);
        expect(groups.inputs, isNotEmpty, reason: '$typeId 缺少 Input');
        expect(groups.outputs, isNotEmpty, reason: '$typeId 缺少 Output');
      }
    });

    test('Inside 不包含 Input/Output 同名变量', () {
      final groups =
          groupNodeVariables('demosaic', nodeSourceCode['demosaic']!);
      final ioNames = {
        ...groups.inputs.map((v) => v.name),
        ...groups.outputs.map((v) => v.name),
      };
      expect(ioNames, containsAll(['bayer', 'width', 'height', 'rgb']));
      for (final v in groups.inside) {
        expect(ioNames.contains(v.name), isFalse,
            reason: '${v.name} 不应出现在 Inside');
      }
      // 内部变量仍被解析出来。
      expect(_find(groups.inside, '_axial'), isNotNull);
    });

    test('黑电平的输入输出符合节点契约', () {
      final groups =
          groupNodeVariables('black_level', nodeSourceCode['black_level']!);
      expect(groups.inputs.map((v) => v.name),
          containsAll(['bayer', 'r', 'gr', 'gb', 'b', 'pattern']));
      expect(groups.outputs.single.name, 'bayer');
      expect(_find(groups.inside, 'offsets'), isNotNull);
    });
  });
}
