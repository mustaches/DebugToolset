import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/models/isp_graph.dart';
import 'package:debug_tool_set/modules/isp_studio/models/isp_node.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/pipeline_runner.dart';

void main() {
  group('Datapath Category Node Types Registration', () {
    test('Registrations of all 6 Datapath splitters and combiners', () {
      final datapathTypes = [
        'rgb_splitter',
        'yuv_splitter',
        'hsl_splitter',
        'rgb_combiner',
        'yuv_combiner',
        'hsl_combiner',
      ];
      for (final typeId in datapathTypes) {
        final type = IspNodeRegistry.byId(typeId);
        expect(type, isNotNull, reason: 'NodeType $typeId should be registered');
      }
    });

    test('RGB Splitter ports specification', () {
      final type = IspNodeRegistry.byId('rgb_splitter')!;
      expect(type.displayName, equals('RGB 分路器'));
      expect(type.inputs.length, equals(1));
      expect(type.inputs.first.type, equals(IspPortType.rgb));

      expect(type.outputs.length, equals(3));
      expect(type.outputPort('out_r')?.type, equals(IspPortType.r));
      expect(type.outputPort('out_g')?.type, equals(IspPortType.g));
      expect(type.outputPort('out_b')?.type, equals(IspPortType.b));
    });

    test('YUV Splitter ports specification', () {
      final type = IspNodeRegistry.byId('yuv_splitter')!;
      expect(type.displayName, equals('YUV 分路器'));
      expect(type.inputs.length, equals(1));
      expect(type.inputs.first.type, equals(IspPortType.yuv));

      expect(type.outputs.length, equals(3));
      expect(type.outputPort('out_y')?.type, equals(IspPortType.y));
      expect(type.outputPort('out_u')?.type, equals(IspPortType.u));
      expect(type.outputPort('out_v')?.type, equals(IspPortType.v));
    });

    test('HSL Splitter ports specification', () {
      final type = IspNodeRegistry.byId('hsl_splitter')!;
      expect(type.displayName, equals('HSL 分路器'));
      expect(type.inputs.length, equals(1));
      expect(type.inputs.first.type, equals(IspPortType.hsl));

      expect(type.outputs.length, equals(3));
      expect(type.outputPort('out_h')?.type, equals(IspPortType.h));
      expect(type.outputPort('out_s')?.type, equals(IspPortType.s));
      expect(type.outputPort('out_l')?.type, equals(IspPortType.l));
    });

    test('RGB Combiner ports specification', () {
      final type = IspNodeRegistry.byId('rgb_combiner')!;
      expect(type.displayName, equals('RGB 合路器'));
      expect(type.inputs.length, equals(3));
      expect(type.inputPort('in_r')?.type, equals(IspPortType.r));
      expect(type.inputPort('in_g')?.type, equals(IspPortType.g));
      expect(type.inputPort('in_b')?.type, equals(IspPortType.b));

      expect(type.outputs.length, equals(1));
      expect(type.outputs.first.type, equals(IspPortType.rgb));
    });
  });

  group('Datapath Connections and Execution', () {
    test('Connect RGB Splitter to RGB Combiner and compile chain', () {
      final graph = IspGraph();
      final srcId = graph.addNode('image_source', 0, 0);
      final splitId = graph.addNode('rgb_splitter', 200, 0);
      final combId = graph.addNode('rgb_combiner', 400, 0);
      final previewId = graph.addNode('preview', 600, 0);

      expect(graph.connect(srcId, 'out_rgb', splitId, 'in'), isNull);
      expect(graph.connect(splitId, 'out_r', combId, 'in_r'), isNull);
      expect(graph.connect(splitId, 'out_g', combId, 'in_g'), isNull);
      expect(graph.connect(splitId, 'out_b', combId, 'in_b'), isNull);
      expect(graph.connect(combId, 'out', previewId, 'in'), isNull);

      final chain = compileChain(graph, previewId);
      expect(chain.length, equals(4));
      expect(chain[0]['typeId'], equals('image_source'));
      expect(chain[1]['typeId'], equals('rgb_splitter'));
      expect(chain[2]['typeId'], equals('rgb_combiner'));
      expect(chain[3]['typeId'], equals('preview'));
    });

    test('Connect YUV Splitter to YUV Combiner and compile chain', () {
      final graph = IspGraph();
      final srcId = graph.addNode('image_source', 0, 0);
      final splitId = graph.addNode('yuv_splitter', 200, 0);
      final combId = graph.addNode('yuv_combiner', 400, 0);
      final previewId = graph.addNode('preview', 600, 0);

      expect(graph.connect(srcId, 'out_yuv', splitId, 'in'), isNull);
      expect(graph.connect(splitId, 'out_y', combId, 'in_y'), isNull);
      expect(graph.connect(splitId, 'out_u', combId, 'in_u'), isNull);
      expect(graph.connect(splitId, 'out_v', combId, 'in_v'), isNull);
      expect(graph.connect(combId, 'out', previewId, 'in_yuv'), isNull);

      final chain = compileChain(graph, previewId);
      expect(chain.length, equals(4));
      expect(chain[0]['typeId'], equals('image_source'));
      expect(chain[1]['typeId'], equals('yuv_splitter'));
      expect(chain[2]['typeId'], equals('yuv_combiner'));
      expect(chain[3]['typeId'], equals('preview'));
    });

    test('Connect HSL Splitter to HSL Combiner and compile chain', () {
      final graph = IspGraph();
      final srcId = graph.addNode('image_source', 0, 0);
      final splitId = graph.addNode('hsl_splitter', 200, 0);
      final combId = graph.addNode('hsl_combiner', 400, 0);
      final previewId = graph.addNode('preview', 600, 0);

      expect(graph.connect(srcId, 'out_hsl', splitId, 'in'), isNull);
      expect(graph.connect(splitId, 'out_h', combId, 'in_h'), isNull);
      expect(graph.connect(splitId, 'out_s', combId, 'in_s'), isNull);
      expect(graph.connect(splitId, 'out_l', combId, 'in_l'), isNull);
      expect(graph.connect(combId, 'out', previewId, 'in_hsl'), isNull);

      final chain = compileChain(graph, previewId);
      expect(chain.length, equals(4));
      expect(chain[0]['typeId'], equals('image_source'));
      expect(chain[1]['typeId'], equals('hsl_splitter'));
      expect(chain[2]['typeId'], equals('hsl_combiner'));
      expect(chain[3]['typeId'], equals('preview'));
    });
  });
}
