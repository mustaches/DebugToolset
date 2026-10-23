// 一次性：逐个加载 IspFlow/*.ispflow 计时，定位打开卡顿是否在数据层。
import 'dart:convert';
import 'dart:io';

import 'package:debug_tool_set/modules/isp_studio/models/isp_graph.dart';

Future<void> main() async {
  final dir = Directory('IspFlow');
  await for (final f in dir.list()) {
    if (!f.path.endsWith('.ispflow')) continue;
    final sw = Stopwatch()..start();
    final text = await File(f.path).readAsString();
    final readMs = sw.elapsedMilliseconds;
    sw.reset();
    final json = jsonDecode(text);
    final jsonMs = sw.elapsedMilliseconds;
    sw.reset();
    final g = IspGraph.fromJson((json as Map).cast<String, Object?>());
    final graphMs = sw.elapsedMilliseconds;
    print('${f.path.split(Platform.pathSeparator).last}: '
        'read=${readMs}ms json=${jsonMs}ms graph=${graphMs}ms '
        'nodes=${g.nodes.length} size=${(text.length / 1024).toStringAsFixed(0)}KB');
  }
}
