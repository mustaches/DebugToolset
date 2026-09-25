import 'package:debug_tool_set/utils/build_info.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseCmakeGenerator', () {
    test('从典型 CMakeCache 文本中解析生成器', () {
      const text = '''
# This is the CMakeCache file.
CMAKE_HOME_DIRECTORY:INTERNAL=G:/DebugToolSet/windows
CMAKE_GENERATOR:INTERNAL=Visual Studio 18 2026
CMAKE_GENERATOR_INSTANCE:INTERNAL=C:/Program Files/Microsoft Visual Studio/18/Community
CMAKE_GENERATOR_PLATFORM:INTERNAL=x64
''';
      expect(parseCmakeGenerator(text), 'Visual Studio 18 2026');
    });

    test('旧版本生成器同样可解析', () {
      const text = 'CMAKE_GENERATOR:INTERNAL=Visual Studio 17 2022\n';
      expect(parseCmakeGenerator(text), 'Visual Studio 17 2022');
    });

    test('缺少该字段时返回 null', () {
      const text = 'CMAKE_HOME_DIRECTORY:INTERNAL=G:/DebugToolSet/windows\n';
      expect(parseCmakeGenerator(text), isNull);
    });

    test('空文本返回 null', () {
      expect(parseCmakeGenerator(''), isNull);
    });

    test('字段值为空时返回 null', () {
      expect(parseCmakeGenerator('CMAKE_GENERATOR:INTERNAL=\n'), isNull);
    });
  });
}
