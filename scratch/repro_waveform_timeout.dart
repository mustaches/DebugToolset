/// 临时复现：白光ISP流程 + 波形仪器节点的单次运行仪器路径计时。
/// 模拟 _runInstruments 的 else 分支：compileChain → 主 isolate
/// runChainFrame → InstrumentAnalyzer.analyze，分段计时。
import 'dart:convert';
import 'dart:io';

import 'package:debug_tool_set/modules/isp_studio/models/isp_graph.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/instrument_worker.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/isp_kernels.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/pipeline_runner.dart';

Future<void> main() async {
  final json = jsonDecode(
      await File('IspFlow/白光ISP流程.ispflow').readAsString())
      as Map<String, Object?>;
  final graph = IspGraph.fromJson(json);
  // 用户在画布上加的波形节点：接到 gamma 输出。
  final wf = graph.addNode('waveform', 0, 0);
  print('waveform 节点: $wf');
  print('connect: ${graph.connect('n14', 'out', wf, 'in')}');

  final sw = Stopwatch()..start();
  final chain = compileChain(graph, wf);
  print('compileChain: ${sw.elapsedMilliseconds}ms, 链长 ${chain.length}');

  sw.reset();
  final rgba = await runChainFrame(chain, 0);
  print('runChainFrame(主 isolate): ${sw.elapsedMilliseconds}ms, '
      'RGBA ${rgba.length} 字节');

  sw.reset();
  final (down, dw, dh) = downsampleRgba82x(rgba, 1920, 1080);
  print('downsampleRgba82x: ${sw.elapsedMilliseconds}ms -> ${dw}x$dh');

  final analyzer = InstrumentAnalyzer();
  sw.reset();
  try {
    final result = await analyzer.analyze(down, dw, dh, 'waveform');
    print('analyze(waveform, 含首次 spawn 池): ${sw.elapsedMilliseconds}ms, '
        'keys=${result.keys.toList()}');
  } catch (e) {
    print('analyze 失败: $e (${sw.elapsedMilliseconds}ms)');
  }

  sw.reset();
  try {
    final result = await analyzer.analyze(down, dw, dh, 'waveform');
    print('analyze(waveform, 热): ${sw.elapsedMilliseconds}ms, '
        'keys=${result.keys.toList()}');
  } catch (e) {
    print('analyze 热路径失败: $e (${sw.elapsedMilliseconds}ms)');
  }
  analyzer.dispose();
  exit(0);
}
