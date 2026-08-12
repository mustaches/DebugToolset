import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/pipeline_worker.dart';

void main() {
  group('PipelineWorkerPool Parallel Isolate Execution Tests', () {
    late PipelineWorkerPool pool;

    setUp(() {
      pool = PipelineWorkerPool(count: 4);
    });

    tearDown(() {
      pool.dispose();
    });

    test('runParallel executes multiple preview chains across isolate worker pool', () async {
      final chain1 = [
        {
          'typeId': 'video_source',
          'params': {'width': 100, 'height': 100},
          'nodeId': 'src1'
        },
        {'typeId': 'preview', 'params': {}, 'nodeId': 'p1'}
      ];

      final chain2 = [
        {
          'typeId': 'video_source',
          'params': {'width': 100, 'height': 100},
          'nodeId': 'src2'
        },
        {'typeId': 'preview', 'params': {}, 'nodeId': 'p2'}
      ];

      final validChains = {
        'p1': chain1,
        'p2': chain2,
      };

      final sourceRgba = Uint8List(100 * 100 * 4);
      final results = await pool.runParallel(
        validChains,
        0,
        sourceRgba: sourceRgba,
        sourceWidth: 100,
        sourceHeight: 100,
      );

      expect(results.containsKey('p1'), true);
      expect(results.containsKey('p2'), true);
      expect(results['p1']!.length, 100 * 100 * 4);
      expect(results['p2']!.length, 100 * 100 * 4);
    });
  });
}
