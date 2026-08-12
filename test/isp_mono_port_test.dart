import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/models/isp_graph.dart';
import 'package:debug_tool_set/modules/isp_studio/models/isp_node.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/pipeline_runner.dart';

void main() {
  group('Mono Port Registration', () {
    test('preview, histogram, waveform, vectorscope have in_mono input port', () {
      final nodeTypes = ['preview', 'histogram', 'waveform', 'vectorscope', 'image_output', 'video_output'];
      for (final typeId in nodeTypes) {
        final type = IspNodeRegistry.byId(typeId);
        expect(type, isNotNull);
        final monoPort = type!.inputPort('in_mono');
        expect(monoPort, isNotNull, reason: '$typeId should have in_mono input port');
        expect(monoPort!.type, equals(IspPortType.mono));
      }
    });

    test('preview has out_mono output port', () {
      final type = IspNodeRegistry.byId('preview')!;
      final outMono = type.outputPort('out_mono');
      expect(outMono, isNotNull);
      expect(outMono!.type, equals(IspPortType.mono));
    });
  });

  group('Mono Port Connections', () {
    test('Connect RGB Splitter out_r to Preview in_mono', () {
      final graph = IspGraph();
      final srcId = graph.addNode('image_source', 0, 0);
      final splitId = graph.addNode('rgb_splitter', 200, 0);
      final prevId = graph.addNode('preview', 400, 0);

      expect(graph.connect(srcId, 'out_rgb', splitId, 'in'), isNull);
      expect(graph.connect(splitId, 'out_r', prevId, 'in_mono'), isNull);

      final chain = compileChain(graph, prevId);
      expect(chain.length, equals(3));
      expect(chain[0]['typeId'], equals('image_source'));
      expect(chain[1]['typeId'], equals('rgb_splitter'));
      expect(chain[2]['typeId'], equals('preview'));
    });

    test('Connect YUV Splitter out_y to Histogram in_mono', () {
      final graph = IspGraph();
      final srcId = graph.addNode('image_source', 0, 0);
      final splitId = graph.addNode('yuv_splitter', 200, 0);
      final histId = graph.addNode('histogram', 400, 0);

      expect(graph.connect(srcId, 'out_yuv', splitId, 'in'), isNull);
      expect(graph.connect(splitId, 'out_y', histId, 'in_mono'), isNull);

      final chain = compileChain(graph, histId);
      expect(chain.length, equals(3));
      expect(chain[0]['typeId'], equals('image_source'));
      expect(chain[1]['typeId'], equals('yuv_splitter'));
      expect(chain[2]['typeId'], equals('histogram'));
    });

    test('Connect HSL Splitter out_l to Waveform in_mono', () {
      final graph = IspGraph();
      final srcId = graph.addNode('image_source', 0, 0);
      final splitId = graph.addNode('hsl_splitter', 200, 0);
      final waveId = graph.addNode('waveform', 400, 0);

      expect(graph.connect(srcId, 'out_hsl', splitId, 'in'), isNull);
      expect(graph.connect(splitId, 'out_l', waveId, 'in_mono'), isNull);

      final chain = compileChain(graph, waveId);
      expect(chain.length, equals(3));
      expect(chain[0]['typeId'], equals('image_source'));
      expect(chain[1]['typeId'], equals('hsl_splitter'));
      expect(chain[2]['typeId'], equals('waveform'));
    });

    test('Single-input exclusivity blocks second connection when in_mono connected', () {
      final graph = IspGraph();
      final srcId = graph.addNode('image_source', 0, 0);
      final splitId = graph.addNode('rgb_splitter', 200, 0);
      final prevId = graph.addNode('preview', 400, 0);

      expect(graph.connect(splitId, 'out_r', prevId, 'in_mono'), isNull);
      // Attempting to connect RGB input while Mono is connected should fail
      final err = graph.connect(srcId, 'out_rgb', prevId, 'in');
      expect(err, contains('只能接入一路'));
    });

    test('Execution of R, G, B mono split preview outputs distinct pixel values', () async {
      // Test execution logic directly
      final chainR = <Map<String, Object?>>[
        {'typeId': 'image_source', 'nodeId': 'src', 'params': {}},
        {'typeId': 'rgb_splitter', 'nodeId': 'split', 'params': {}, 'inputs': {'in': {'fromNodeId': 'src', 'fromPort': 'out_rgb'}}},
        {'typeId': 'preview', 'nodeId': 'prev', 'params': {}, 'inputs': {'in_mono': {'fromNodeId': 'split', 'fromPort': 'out_r'}}},
      ];
      final chainG = <Map<String, Object?>>[
        {'typeId': 'image_source', 'nodeId': 'src', 'params': {}},
        {'typeId': 'rgb_splitter', 'nodeId': 'split', 'params': {}, 'inputs': {'in': {'fromNodeId': 'src', 'fromPort': 'out_rgb'}}},
        {'typeId': 'preview', 'nodeId': 'prev', 'params': {}, 'inputs': {'in_mono': {'fromNodeId': 'split', 'fromPort': 'out_g'}}},
      ];
      final chainB = <Map<String, Object?>>[
        {'typeId': 'image_source', 'nodeId': 'src', 'params': {}},
        {'typeId': 'rgb_splitter', 'nodeId': 'split', 'params': {}, 'inputs': {'in': {'fromNodeId': 'src', 'fromPort': 'out_rgb'}}},
        {'typeId': 'preview', 'nodeId': 'prev', 'params': {}, 'inputs': {'in_mono': {'fromNodeId': 'split', 'fromPort': 'out_b'}}},
      ];

      // Injected RGB source: R=200, G=100, B=50 (width 1, height 1)
      final srcRgba = Uint8List.fromList([200, 100, 50, 255]);
      final rgbaR = await runChainFrame(chainR, 0, sourceRgba: srcRgba, sourceWidth: 1, sourceHeight: 1);
      final rgbaG = await runChainFrame(chainG, 0, sourceRgba: srcRgba, sourceWidth: 1, sourceHeight: 1);
      final rgbaB = await runChainFrame(chainB, 0, sourceRgba: srcRgba, sourceWidth: 1, sourceHeight: 1);

      // R channel output -> R=200, G=200, B=200
      expect(rgbaR[0], equals(200));
      expect(rgbaR[1], equals(200));
      expect(rgbaR[2], equals(200));

      // G channel output -> R=100, G=100, B=100
      expect(rgbaG[0], equals(100));
      expect(rgbaG[1], equals(100));
      expect(rgbaG[2], equals(100));

      // B channel output -> R=50, G=50, B=50
      expect(rgbaB[0], equals(50));
      expect(rgbaB[1], equals(50));
      expect(rgbaB[2], equals(50));
    });
  });
}
