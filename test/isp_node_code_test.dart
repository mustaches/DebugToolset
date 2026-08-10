import 'package:flutter_test/flutter_test.dart';
import 'package:debug_tool_set/modules/isp_studio/models/isp_node.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/node_code.dart';

void main() {
  group('nodeSourceCode', () {
    test('注册表中的每种节点类型都有只读代码片段', () {
      for (final typeId in IspNodeRegistry.types.keys) {
        final code = nodeSourceCode[typeId];
        expect(code, isNotNull, reason: '$typeId 缺少代码片段');
        expect(code!.trim(), isNotEmpty, reason: '$typeId 代码片段为空');
      }
    });

    test('不含游离的多余条目', () {
      for (final key in nodeSourceCode.keys) {
        expect(IspNodeRegistry.types.containsKey(key), isTrue,
            reason: '$key 不是已注册的节点类型');
      }
    });
  });
}
