import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';

void main() {
  group('IspStudioState 标签页', () {
    test('初始化时为空白画布（不加载任何流程图）', () async {
      final state = IspStudioState();
      expect(state.graph.nodes, isEmpty);
      expect(state.graph.connections, isEmpty);
      // 运行预览有兜底提示而不是崩溃。
      await state.runPreview();
      expect(state.statusMessage, contains('预览节点'));
    });

    test('默认流程图标签标题为「缺省流程」', () {
      final state = IspStudioState.withDefaultGraph();
      expect(state.graphTabTitle, '缺省流程');
      expect(state.activeTab, 0);
      expect(state.openCodeTabs, isEmpty);
    });

    test('设置工程名后标签标题使用工程名', () {
      final state = IspStudioState.withDefaultGraph();
      state.graphName = '我的流水线';
      expect(state.graphTabTitle, '我的流水线');
      state.graphName = '';
      expect(state.graphTabTitle, '缺省流程');
    });

    test('openCodeTab 打开并激活，重复打开仅激活', () {
      final state = IspStudioState.withDefaultGraph();
      final ids = state.graph.nodes.keys.toList();
      state.openCodeTab(ids[0]);
      state.openCodeTab(ids[1]);
      expect(state.openCodeTabs, [ids[0], ids[1]]);
      expect(state.activeTab, 2);

      state.openCodeTab(ids[0]);
      expect(state.openCodeTabs, hasLength(2));
      expect(state.activeTab, 1);
    });

    test('openCodeTab 忽略不存在的节点', () {
      final state = IspStudioState.withDefaultGraph();
      state.openCodeTab('n999');
      expect(state.openCodeTabs, isEmpty);
      expect(state.activeTab, 0);
    });

    test('closeCodeTab 关闭活动标签后落到相邻标签', () {
      final state = IspStudioState.withDefaultGraph();
      final ids = state.graph.nodes.keys.toList();
      for (final id in ids.take(3)) {
        state.openCodeTab(id);
      }
      // 关闭中间的活动标签（activeTab=3 → 关 ids[2] 先把它激活）。
      state.setActiveTab(2);
      state.closeCodeTab(ids[1]);
      expect(state.openCodeTabs, [ids[0], ids[2]]);
      expect(state.activeTab, 1); // 左邻居

      // 关闭末尾活动标签后钳制到最后一个。
      state.setActiveTab(2);
      state.closeCodeTab(ids[2]);
      expect(state.activeTab, 1);

      // 关闭非活动标签不影响活动索引。
      state.closeCodeTab(ids[0]);
      expect(state.openCodeTabs, isEmpty);
      expect(state.activeTab, 0);
    });

    test('setActiveTab 越界会被钳制', () {
      final state = IspStudioState.withDefaultGraph();
      state.setActiveTab(10);
      expect(state.activeTab, 0);
      state.setActiveTab(-1);
      expect(state.activeTab, 0);
    });

    test('removeNode 级联关闭其代码标签页', () {
      final state = IspStudioState.withDefaultGraph();
      final id = state.graph.nodes.keys.first;
      state.openCodeTab(id);
      expect(state.activeTab, 1);
      state.removeNode(id);
      expect(state.openCodeTabs, isEmpty);
      expect(state.activeTab, 0);
    });
  });

  group('IspStudioState 流程保存/打开', () {
    test('保存到临时文件再打开，图与工程名还原', () async {
      final tmp = File(
          '${Directory.systemTemp.path}/isp_flow_${DateTime.now().microsecondsSinceEpoch}.ispflow');
      try {
        final a = IspStudioState.withDefaultGraph();
        a.graph.nodes.values.first.paramValues['filePath'] = 'x.raw';
        a.graphName = '我的流程';
        await a.saveGraphToFile(tmp.path);
        expect(a.statusMessage, contains('流程已保存'));

        final b = IspStudioState.withDefaultGraph();
        b.openCodeTab(b.graph.nodes.keys.first); // 打开后应被清空
        // 预设视口：验证打开流程后自动适配全屏。
        b.canvasViewport = const Size(800, 600);
        await b.importGraphFromFile(tmp.path);
        expect(b.statusMessage, contains('已打开流程'));
        expect(b.graphName, '我的流程');
        expect(b.graph.nodes.length, a.graph.nodes.length);
        expect(b.graph.connections.length, a.graph.connections.length);
        expect(b.graph.nodes.values.first.paramValues['filePath'], 'x.raw');
        expect(b.openCodeTabs, isEmpty);
        expect(b.activeTab, 0);
        // 默认图横向约 1800 宽，800 宽视口下应已自动缩小适配。
        expect(b.canvasZoom, lessThan(1.0));
      } finally {
        if (tmp.existsSync()) await tmp.delete();
      }
    });

    test('直方图与波形示波器通道切换：Y 与 R/G/B 互斥、关Y默认全开、支持单选与多选', () {
      final state = IspStudioState.withDefaultGraph();
      const node = 'node1';

      // 默认通道为 R, G, B 全开
      expect(state.histogramChannels(node), equals({'r', 'g', 'b'}));
      expect(state.waveformChannels(node), equals({'r', 'g', 'b'}));

      // 选中 Y：R/G/B 被清空，只保留 Y
      state.toggleHistogramChannel(node, 'y');
      state.toggleWaveformChannel(node, 'y');
      expect(state.histogramChannels(node), equals({'y'}));
      expect(state.waveformChannels(node), equals({'y'}));

      // 关闭 Y：R/G/B 默认全开
      state.toggleHistogramChannel(node, 'y');
      state.toggleWaveformChannel(node, 'y');
      expect(state.histogramChannels(node), equals({'r', 'g', 'b'}));
      expect(state.waveformChannels(node), equals({'r', 'g', 'b'}));

      // 再次开启 Y
      state.toggleHistogramChannel(node, 'y');
      state.toggleWaveformChannel(node, 'y');

      // 点击 R 通道：Y 被移除，选择 R 单选
      state.toggleHistogramChannel(node, 'r');
      state.toggleWaveformChannel(node, 'r');
      expect(state.histogramChannels(node), equals({'r'}));
      expect(state.waveformChannels(node), equals({'r'}));

      // 多选 G 通道：开启 R + G 多选
      state.toggleHistogramChannel(node, 'g');
      state.toggleWaveformChannel(node, 'g');
      expect(state.histogramChannels(node), equals({'r', 'g'}));
      expect(state.waveformChannels(node), equals({'r', 'g'}));

      // 取消 R、G：当 RGB 全关时，自动激活 Y
      state.toggleHistogramChannel(node, 'r');
      state.toggleWaveformChannel(node, 'r');
      state.toggleHistogramChannel(node, 'g');
      state.toggleWaveformChannel(node, 'g');
      expect(state.histogramChannels(node), equals({'y'}));
      expect(state.waveformChannels(node), equals({'y'}));
    });

    test('连接 MONO 端口默认激活 Y，连接 RGB 端口默认激活 RGB', () {
      final state = IspStudioState.withDefaultGraph();
      final previewNodeId = state.graph.addNode('preview', 0, 0);
      final monoNodeId = state.graph.addNode('histogram', 100, 100);
      final rgbNodeId = state.graph.addNode('waveform', 300, 100);

      // 接入 in_mono 端口（mono -> mono）
      state.beginConnectionDrag(previewNodeId, 'out_mono', Offset.zero);
      state.endConnectionDrag(monoNodeId, 'in_mono');
      expect(state.histogramChannels(monoNodeId), equals({'y'}));

      // 接入 in (RGB) 端口（rgb -> rgb）
      state.beginConnectionDrag(previewNodeId, 'out', Offset.zero);
      state.endConnectionDrag(rgbNodeId, 'in');
      expect(state.waveformChannels(rgbNodeId), equals({'r', 'g', 'b'}));
    });
  });
}
