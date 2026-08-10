import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:debug_tool_set/modules/isp_studio/models/isp_node.dart';
import 'package:debug_tool_set/modules/isp_studio/models/isp_graph.dart';

void main() {
  group('IspNodeRegistry', () {
    test('包含全部 20 种节点类型', () {
      const expected = [
        'bayer_source',
        'cis_bayer_rggb',
        'cis_rccb_rccg',
        'cis_rccc',
        'cis_ryycy',
        'cis_rgb_ir',
        'cis_mono',
        'image_source',
        'video_source',
        'black_level',
        'demosaic',
        'white_balance',
        'ccm',
        'gamma',
        'preview',
        'histogram',
        'waveform',
        'vectorscope',
        'image_output',
        'video_output',
      ];
      for (final id in expected) {
        expect(IspNodeRegistry.byId(id), isNotNull, reason: id);
      }
      expect(IspNodeRegistry.types.length, 20);
    });

    test('端口类型符合预期', () {
      IspPortType? inType(String typeId) =>
          IspNodeRegistry.byId(typeId)!.inputs.first.type;
      IspPortType? outType(String typeId) =>
          IspNodeRegistry.byId(typeId)!.outputs.first.type;

      expect(IspNodeRegistry.byId('bayer_source')!.inputs, isEmpty);
      expect(outType('bayer_source'), IspPortType.bayer);

      expect(inType('black_level'), IspPortType.bayer);
      expect(outType('black_level'), IspPortType.bayer);

      expect(inType('demosaic'), IspPortType.bayer);
      expect(outType('demosaic'), IspPortType.rgb);

      for (final id in ['white_balance', 'ccm', 'gamma', 'preview']) {
        expect(inType(id), IspPortType.rgb, reason: id);
        expect(outType(id), IspPortType.rgb, reason: id);
      }

      for (final id in ['image_output', 'video_output']) {
        expect(inType(id), IspPortType.rgb, reason: id);
        expect(IspNodeRegistry.byId(id)!.outputs, isEmpty, reason: id);
      }
    });

    test('IspNode.create 按默认值初始化参数', () {
      final node = IspNode.create(
          IspNodeRegistry.byId('bayer_source')!, 'n1', 0, 0);
      expect(node.paramValues['width'], 3840);
      expect(node.paramValues['height'], 2160);
      expect(node.paramValues['bitDepth'], '10');
      expect(node.paramValues['packing'], 'unpacked_lsb');
      expect(node.paramValues['bayerPattern'], 'RGGB');
      expect(node.paramValues['littleEndian'], true);
      expect(node.paramValues['frameIndex'], 0);
    });

    test('ccm 矩阵默认值为单位矩阵', () {
      final node =
          IspNode.create(IspNodeRegistry.byId('ccm')!, 'n1', 0, 0);
      expect(node.paramValues['matrix'],
          <double>[1, 0, 0, 0, 1, 0, 0, 0, 1]);
    });
  });

  group('IspGraph', () {
    test('addNode 返回递增 id，removeNode 级联删除连接', () {
      final g = IspGraph();
      final a = g.addNode('bayer_source', 0, 0);
      final b = g.addNode('black_level', 0, 0);
      final c = g.addNode('demosaic', 0, 0);
      expect(a, 'n1');
      expect(b, 'n2');
      expect(c, 'n3');
      expect(g.connect(a, 'out', b, 'in'), isNull);
      expect(g.connect(b, 'out', c, 'in'), isNull);
      expect(g.connections, hasLength(2));

      g.removeNode(b);
      expect(g.nodes.containsKey(b), isFalse);
      expect(g.connections, isEmpty);
    });

    test('端口类型不匹配被拒绝', () {
      final g = IspGraph();
      final demosaic = g.addNode('demosaic', 0, 0);
      final blc = g.addNode('black_level', 0, 0);
      // demosaic 输出 rgb，black_level 输入 bayer → 应失败。
      expect(g.connect(demosaic, 'out', blc, 'in'), '端口类型不匹配');
      expect(g.connections, isEmpty);
      // bayer → bayer 合法。
      final src = g.addNode('bayer_source', 0, 0);
      expect(g.connect(src, 'out', blc, 'in'), isNull);
      // bayer → rgb（demosaic）合法。
      expect(g.connect(blc, 'out', demosaic, 'in'), isNull);
    });

    test('节点或端口不存在返回错误', () {
      final g = IspGraph();
      final a = g.addNode('bayer_source', 0, 0);
      expect(g.connect(a, 'out', 'nX', 'in'), '节点不存在');
      expect(g.connect(a, 'nope', a, 'in'), isNotNull);
    });

    test('输入端口已有连接时替换旧连接', () {
      final g = IspGraph();
      final s1 = g.addNode('bayer_source', 0, 0);
      final s2 = g.addNode('bayer_source', 0, 0);
      final blc = g.addNode('black_level', 0, 0);
      expect(g.connect(s1, 'out', blc, 'in'), isNull);
      final first = g.connectionAt(blc, 'in');
      expect(first!.fromNodeId, s1);

      expect(g.connect(s2, 'out', blc, 'in'), isNull);
      expect(g.connections, hasLength(1));
      final second = g.connectionAt(blc, 'in');
      expect(second!.fromNodeId, s2);
    });

    test('拒绝自连与环路', () {
      final g = IspGraph();
      final a = g.addNode('white_balance', 0, 0);
      final b = g.addNode('gamma', 0, 0);
      expect(g.connect(a, 'out', a, 'in'), '不允许节点连接自身');
      expect(g.connect(a, 'out', b, 'in'), isNull);
      expect(g.connect(b, 'out', a, 'in'), '不允许形成环路');
      // 失败后原连接保持不变。
      expect(g.connectionAt(b, 'in')!.fromNodeId, a);
    });

    test('topologicalOrder 是 defaultGraph 的合法线性化', () {
      final g = defaultGraph();
      final order = g.topologicalOrder();
      expect(order, hasLength(g.nodes.length));
      final pos = {for (var i = 0; i < order.length; i++) order[i]: i};
      for (final c in g.connections) {
        expect(pos[c.fromNodeId]! < pos[c.toNodeId]!, isTrue,
            reason: '${c.fromNodeId} -> ${c.toNodeId}');
      }
    });

    test('topologicalOrder 在存在环路时返回空', () {
      // 通过直接操作 connections 构造环路（绕过 connect 的环路检查）。
      final g = IspGraph();
      final a = g.addNode('white_balance', 0, 0);
      final b = g.addNode('gamma', 0, 0);
      g.connections.addAll([
        IspConnection(
            id: 'c1', fromNodeId: a, fromPort: 'out', toNodeId: b, toPort: 'in'),
        IspConnection(
            id: 'c2', fromNodeId: b, fromPort: 'out', toNodeId: a, toPort: 'in'),
      ]);
      expect(g.topologicalOrder(), isEmpty);
    });

    test('upstreamOf 返回直接和间接上游', () {
      final g = defaultGraph();
      final gammaId = g.nodes.entries
          .firstWhere((e) => e.value.typeId == 'gamma')
          .key;
      final upstream = g.upstreamOf(gammaId);
      expect(upstream, hasLength(5));
      final upstreamTypes =
          upstream.map((id) => g.nodes[id]!.typeId).toSet();
      expect(
          upstreamTypes,
          containsAll([
            'bayer_source',
            'black_level',
            'demosaic',
            'white_balance',
            'ccm',
          ]));
      final imageOutId = g.nodes.entries
          .firstWhere((e) => e.value.typeId == 'image_output')
          .key;
      // 图片输出接在预览之后，上游为整条链（源 + 5 级处理 + 预览）。
      expect(g.upstreamOf(imageOutId), hasLength(7));
    });

    test('validate 标记未连接的预览和空的源文件路径', () {
      final g = IspGraph();
      g.addNode('bayer_source', 0, 0);
      g.addNode('preview', 0, 0);
      final errors = g.validate();
      expect(errors, contains(contains('预览')));
      expect(errors, contains(contains('文件路径')));
      expect(errors, hasLength(2));
    });

    test('defaultGraph 的 validate 只报告源路径，预览与图片输出已连接', () {
      final g = defaultGraph();
      final errors = g.validate();
      expect(errors.any((e) => e.contains('文件路径')), isTrue);
      // 图片输出已连接预览，不应报错。
      expect(errors.any((e) => e.contains('图片输出')), isFalse);
      // 预览已连接，不应报错。
      expect(errors.any((e) => e.contains('预览')), isFalse);
    });

    test('disconnect 与 disconnectInput', () {
      final g = IspGraph();
      final a = g.addNode('bayer_source', 0, 0);
      final b = g.addNode('black_level', 0, 0);
      g.connect(a, 'out', b, 'in');
      final conn = g.connectionAt(b, 'in')!;
      g.disconnect(conn.id);
      expect(g.connections, isEmpty);

      g.connect(a, 'out', b, 'in');
      g.disconnectInput(b, 'in');
      expect(g.connections, isEmpty);
    });
  });

  group('IspGraph 序列化', () {
    test('toJson/fromJson 往返保持节点、连接、参数与 nextId', () {
      final g = defaultGraph();
      // 改一些参数与几何，验证都被保留。
      final srcId = g.nodes.entries
          .firstWhere((e) => e.value.typeId == 'bayer_source')
          .key;
      g.nodes[srcId]!.paramValues['filePath'] = 'a/b.raw';
      g.nodes[srcId]!.paramValues['width'] = 3840;
      g.nodes[srcId]!.x = 123.5;
      final ccmId = g.nodes.entries
          .firstWhere((e) => e.value.typeId == 'ccm')
          .key;
      g.nodes[ccmId]!.paramValues['matrix'] = [1.0, 0.1, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0];

      // 经过 JSON 编解码（模拟写盘再读回，类型擦除为 dynamic）。
      final decoded =
          jsonDecode(jsonEncode(g.toJson())) as Map<String, dynamic>;
      final restored = IspGraph.fromJson(decoded.cast<String, Object?>());

      expect(restored.nodes.length, g.nodes.length);
      expect(restored.connections.length, g.connections.length);
      expect(restored.nextId, g.nextId);
      final src = restored.nodes[srcId]!;
      expect(src.paramValues['filePath'], 'a/b.raw');
      expect(src.paramValues['width'], 3840);
      expect(src.x, 123.5);
      expect(restored.nodes[ccmId]!.paramValues['matrix'],
          [1.0, 0.1, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]);
      // 拓扑序与连接关系一致。
      expect(restored.topologicalOrder(), g.topologicalOrder());
    });

    test('fromJson 拒绝未知节点类型，跳过引用缺失节点的连接', () {
      expect(
        () => IspGraph.fromJson({
          'nodes': [
            {'id': 'n1', 'typeId': 'no_such_type', 'x': 0, 'y': 0},
          ],
        }),
        throwsFormatException,
      );
      final g = IspGraph.fromJson({
        'nodes': [
          {'id': 'n1', 'typeId': 'bayer_source', 'x': 0, 'y': 0},
        ],
        'connections': [
          {'id': 'c9', 'from': 'n1', 'fromPort': 'out', 'to': 'nX', 'toPort': 'in'},
        ],
      });
      expect(g.connections, isEmpty);
      // 缺 nextId 时按 id 后缀推导（n1 → 2）。
      expect(g.nextId, 2);
    });
  });
}
