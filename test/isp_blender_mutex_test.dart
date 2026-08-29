// 混叠器混叠图输入组互斥测试：in_blend/in_blend_yuv/in_blend_hsl/
// in_blend_mono 四端口只允许接入一路，且与基图视频输入组互不干扰。
import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/models/isp_graph.dart';

void main() {
  (IspGraph, String, String, String) buildGraph() {
    final graph = IspGraph();
    final src = graph.addNode('image_source', 0, 0);
    final mono = graph.addNode('cis_mono', 0, 0);
    final mix = graph.addNode('blender', 0, 0);
    return (graph, src, mono, mix);
  }

  test('混叠图四端口互斥：接入一路后其余拒绝', () {
    final (graph, src, mono, mix) = buildGraph();
    // 接入 混叠 RGB。
    expect(graph.connect(src, 'out_rgb', mix, 'in_blend'), isNull);
    // 其余三个混叠端口拒绝（互斥）。
    expect(graph.connect(src, 'out_yuv', mix, 'in_blend_yuv'), isNotNull);
    expect(graph.connect(src, 'out_hsl', mix, 'in_blend_hsl'), isNotNull);
    expect(graph.connect(mono, 'out', mix, 'in_blend_mono'), isNotNull);
    // 断开后可换接另一路。
    graph.disconnectInput(mix, 'in_blend');
    expect(graph.connect(mono, 'out', mix, 'in_blend_mono'), isNull);
    expect(graph.connect(src, 'out_rgb', mix, 'in_blend'), isNotNull);
  });

  test('混叠图组与基图组互不干扰', () {
    final (graph, src, mono, mix) = buildGraph();
    // 基图接 YUV、混叠接 RGB、蒙版接 mono：三组可同时接入。
    expect(graph.connect(src, 'out_yuv', mix, 'in_yuv'), isNull);
    expect(graph.connect(src, 'out_rgb', mix, 'in_blend'), isNull);
    expect(graph.connect(mono, 'out', mix, 'in_mask'), isNull);
    // 基图组内仍互斥。
    expect(graph.connect(src, 'out_rgb', mix, 'in'), isNotNull);
  });

  test('多路选择器：源组内互斥、组间可同时接入', () {
    final graph = IspGraph();
    final src = graph.addNode('image_source', 0, 0);
    final mono = graph.addNode('cis_mono', 0, 0);
    final mux = graph.addNode('mux4', 0, 0);
    // 源1 组内互斥：接入 in1 后，in1_yuv 拒绝。
    expect(graph.connect(src, 'out_rgb', mux, 'in1'), isNull);
    expect(graph.connect(src, 'out_yuv', mux, 'in1_yuv'), isNotNull);
    // 源2/源3 组可同时接入（组间不互斥）。
    expect(graph.connect(mono, 'out', mux, 'in2_mono'), isNull);
    expect(graph.connect(src, 'out_hsl', mux, 'in3_hsl'), isNull);
    // 断开源1 后可换接另一域。
    graph.disconnectInput(mux, 'in1');
    expect(graph.connect(src, 'out_yuv', mux, 'in1_yuv'), isNull);
  });
}
