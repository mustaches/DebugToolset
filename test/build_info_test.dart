import 'package:debug_tool_set/utils/build_info.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseCmakeGenerator', () {
    test('解析 CMAKE_GENERATOR:INTERNAL 行', () {
      const cache = '''
# This is the CMakeCache file.
CMAKE_HOME_DIRECTORY:INTERNAL=G:/DebugToolSet/windows
CMAKE_GENERATOR:INTERNAL=Visual Studio 18 2026
CMAKE_GENERATOR_PLATFORM:INTERNAL=x64
''';
      expect(parseCmakeGenerator(cache), 'Visual Studio 18 2026');
    });

    test('缺失或为空时返回 null', () {
      expect(parseCmakeGenerator('CMAKE_HOME_DIRECTORY:INTERNAL=C:/x'), isNull);
      expect(parseCmakeGenerator('CMAKE_GENERATOR:INTERNAL='), isNull);
    });
  });

  group('resolveCmakeGenerator', () {
    test('烘焙值优先于 CMakeCache', () {
      expect(
        resolveCmakeGenerator(
          baked: 'Visual Studio 18 2026',
          cmakeCacheText: 'CMAKE_GENERATOR:INTERNAL=Ninja',
        ),
        'Visual Studio 18 2026',
      );
    });

    test('烘焙值为空时回退 CMakeCache', () {
      expect(
        resolveCmakeGenerator(
          baked: '',
          cmakeCacheText: 'CMAKE_GENERATOR:INTERNAL=Visual Studio 18 2026',
        ),
        'Visual Studio 18 2026',
      );
    });

    test('两者都没有时返回 null', () {
      expect(resolveCmakeGenerator(baked: ''), isNull);
      expect(resolveCmakeGenerator(baked: null, cmakeCacheText: ''), isNull);
    });
  });
}
