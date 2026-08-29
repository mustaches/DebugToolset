// GPU 前缀覆盖判定（gpuChainPrefixCovered）回归测试：
// 透传汇点不在主链上且输入来自侧向端口（分路器 out_y、edge_extract
// out_mono 等）时拒绝覆盖——否则该预览会被主链在处理链末端节点的主帧
// 处捕获出图，单通道预览错显示为上游主帧（分解锐化流程中 Y 通道
// 预览显示成全彩 YUV 图的故障）。
import 'package:debug_tool_set/providers/isp_studio_state.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> op(String nodeId, String typeId,
        [Map<String, Map<String, String>>? inputs]) =>
    {
      'nodeId': nodeId,
      'typeId': typeId,
      'params': <String, Object?>{},
      'inputs': ?inputs,
    };

void main() {
  // 分解锐化流程主链：n1 → n10(分路器) → n2 → … → n24。
  const mainIds = ['n1', 'n10', 'n2', 'n17', 'n20', 'n7', 'n23', 'n24'];

  group('gpuChainPrefixCovered', () {
    test('常规前缀链（输入来自 out 主帧别名）允许覆盖', () {
      final sub = [
        op('n1', 'image_source'),
        op('n10', 'yuv_splitter'),
        op('n4', 'preview', {
          'in': {'fromNodeId': 'n10', 'fromPort': 'out'},
        }),
      ];
      expect(gpuChainPrefixCovered(sub, mainIds), isTrue);
      // 源节点的 out_rgb/out_yuv/out_hsl 同样是主帧别名。
      final sub2 = [
        op('n1', 'image_source'),
        op('n4', 'preview', {
          'in_yuv': {'fromNodeId': 'n1', 'fromPort': 'out_yuv'},
        }),
      ];
      expect(gpuChainPrefixCovered(sub2, ['n1', 'n2']), isTrue);
    });

    test('汇点不在主链且输入来自侧向端口：拒绝覆盖', () {
      // 分路器 out_y → 预览 in_mono（本回归的故障拓扑）。
      final sub = [
        op('n1', 'image_source'),
        op('n10', 'yuv_splitter'),
        op('n4', 'preview', {
          'in_mono': {'fromNodeId': 'n10', 'fromPort': 'out_y'},
        }),
      ];
      expect(gpuChainPrefixCovered(sub, mainIds), isFalse);
      // edge_extract out_mono → 预览 in_mono 同理。
      final sub2 = [
        op('n1', 'image_source'),
        op('n2', 'edge_extract'),
        op('n4', 'preview', {
          'in_mono': {'fromNodeId': 'n2', 'fromPort': 'out_mono'},
        }),
      ];
      expect(
          gpuChainPrefixCovered(
              sub2, const ['n1', 'n2', 'n10', 'n24']), isFalse);
    });

    test('汇点在主链上（分支出图）：侧向输入仍允许覆盖', () {
      // 捕获点即汇点自身，GPU 执行到该节点时 frame 正是其输入帧。
      final sub = [
        op('n1', 'image_source'),
        op('n10', 'yuv_splitter'),
        op('n4', 'preview', {
          'in_mono': {'fromNodeId': 'n10', 'fromPort': 'out_y'},
        }),
      ];
      expect(gpuChainPrefixCovered(sub, const ['n1', 'n10', 'n4', 'n24']),
          isTrue);
    });

    test('非透传汇点（调节器）：显示为自身输出，不受输入端口约束', () {
      // 调节器链是其主链的严格前缀（调节器本身在主链上）：捕获点 =
      // 调节器自身输出帧，输入来自侧向端口也不影响等价性。
      final sub = [
        op('n1', 'image_source'),
        op('n10', 'yuv_splitter'),
        op('n17', 'bright_contrast_adjuster', {
          'in_mono': {'fromNodeId': 'n10', 'fromPort': 'out_y'},
        }),
      ];
      expect(
          gpuChainPrefixCovered(
              sub, const ['n1', 'n10', 'n17', 'n20', 'n24']), isTrue);
    });

    test('含 gamma 的处理链不做合并捕获', () {
      final sub = [
        op('n1', 'image_source'),
        op('n2', 'gamma'),
        op('n4', 'preview'),
      ];
      expect(gpuChainPrefixCovered(sub, mainIds), isFalse);
    });
  });
}
