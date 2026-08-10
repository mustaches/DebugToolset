import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';

void main() {
  group('IspStudioState 标签页', () {
    test('默认流程图标签标题为「缺省流程」', () {
      final state = IspStudioState();
      expect(state.graphTabTitle, '缺省流程');
      expect(state.activeTab, 0);
      expect(state.openCodeTabs, isEmpty);
    });

    test('设置工程名后标签标题使用工程名', () {
      final state = IspStudioState();
      state.graphName = '我的流水线';
      expect(state.graphTabTitle, '我的流水线');
      state.graphName = '';
      expect(state.graphTabTitle, '缺省流程');
    });

    test('openCodeTab 打开并激活，重复打开仅激活', () {
      final state = IspStudioState();
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
      final state = IspStudioState();
      state.openCodeTab('n999');
      expect(state.openCodeTabs, isEmpty);
      expect(state.activeTab, 0);
    });

    test('closeCodeTab 关闭活动标签后落到相邻标签', () {
      final state = IspStudioState();
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
      final state = IspStudioState();
      state.setActiveTab(10);
      expect(state.activeTab, 0);
      state.setActiveTab(-1);
      expect(state.activeTab, 0);
    });

    test('removeNode 级联关闭其代码标签页', () {
      final state = IspStudioState();
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
        final a = IspStudioState();
        a.graph.nodes.values.first.paramValues['filePath'] = 'x.raw';
        a.graphName = '我的流程';
        await a.saveGraphToFile(tmp.path);
        expect(a.statusMessage, contains('流程已保存'));

        final b = IspStudioState();
        b.openCodeTab(b.graph.nodes.keys.first); // 打开后应被清空
        await b.importGraphFromFile(tmp.path);
        expect(b.statusMessage, contains('已打开流程'));
        expect(b.graphName, '我的流程');
        expect(b.graph.nodes.length, a.graph.nodes.length);
        expect(b.graph.connections.length, a.graph.connections.length);
        expect(b.graph.nodes.values.first.paramValues['filePath'], 'x.raw');
        expect(b.openCodeTabs, isEmpty);
        expect(b.activeTab, 0);
      } finally {
        if (tmp.existsSync()) await tmp.delete();
      }
    });

    test('打开非法文件只更新状态栏消息', () async {
      final tmp = File(
          '${Directory.systemTemp.path}/isp_flow_bad_${DateTime.now().microsecondsSinceEpoch}.ispflow');
      try {
        await tmp.writeAsString('not json{');
        final state = IspStudioState();
        final nodeCount = state.graph.nodes.length;
        await state.importGraphFromFile(tmp.path);
        expect(state.statusMessage, contains('打开流程失败'));
        expect(state.graph.nodes.length, nodeCount); // 图未被破坏
      } finally {
        if (tmp.existsSync()) await tmp.delete();
      }
    });
  });
}
