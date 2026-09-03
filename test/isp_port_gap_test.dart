// 端口分组间隔行（kPortGroupGapRows）测试：混叠器的基图/蒙版/混叠图
// 三组输入之间各插入一行间隔，节点高度与端口几何同步偏移。
import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/models/isp_node.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/node_layout.dart';

void main() {
  test('混叠器端口间隔：高度与端口几何同步偏移', () {
    final type = IspNodeRegistry.byId('blender')!;
    final node = IspNode.create(type, 'n1', 0, 0);

    // 高度：标题 30 + 9 端口行 + 2 间隔行 + 底部留白 8。
    const expected = kNodeTitleHeight + 11 * kPortRowHeight + 8;
    expect(nodeHeight(type), expected);

    // 基图四端口（0..3）无偏移；蒙版（4）多 1 行、混叠图（5..8）多 2 行。
    final y3 = inputPortPos(node, type, 3).dy; // 基图 Mono
    final y4 = inputPortPos(node, type, 4).dy; // 蒙版 Mono
    final y5 = inputPortPos(node, type, 5).dy; // 混叠 RGB
    final y8 = inputPortPos(node, type, 8).dy; // 混叠 Mono
    expect(y4 - y3, 2 * kPortRowHeight, reason: '蒙版与基图间隔一行');
    expect(y5 - y4, 2 * kPortRowHeight, reason: '混叠图与蒙版间隔一行');
    expect(y8 - y5, 3 * kPortRowHeight, reason: '混叠图四端口连续无间隔');
    // 端口不越出节点下缘（留白 8 内）。
    expect(y8, lessThan(node.y + expected));
  });

  test('无间隔配置的节点：端口几何不变', () {
    final type = IspNodeRegistry.byId('multiplier')!;
    final node = IspNode.create(type, 'n1', 0, 0);
    final y0 = inputPortPos(node, type, 0).dy;
    final y1 = inputPortPos(node, type, 1).dy;
    expect(y1 - y0, kPortRowHeight);
  });

  test('双输入评价节点：参考图与测试图两组输入之间插入一行间隔', () {
    // PSNR/SSIM/MS-SSIM/FSIM 与 LPIPS/DISTS/FID/KID（8 端口双输入）
    // 统一在第 5 个端口（in_test）前插入一行间隔。
    for (final id in [
      'psnr',
      'ssim',
      'msssim',
      'fsim',
      'lpips',
      'dists',
      'fid',
      'kid',
    ]) {
      final type = IspNodeRegistry.byId(id)!;
      final node = IspNode.create(type, 'n1', 0, 0);
      // 高度：标题 30 + 8 端口行 + 1 间隔行 + 仪器附加区 160 + 底部留白 8。
      const expected = kNodeTitleHeight + 9 * kPortRowHeight + 160 + 8;
      expect(nodeHeight(type), expected, reason: '$id 节点高度应含 1 行间隔');
      final y3 = inputPortPos(node, type, 3).dy; // 参考 Mono
      final y4 = inputPortPos(node, type, 4).dy; // 测试 RGB
      expect(y4 - y3, 2 * kPortRowHeight, reason: '$id 参考/测试之间应间隔一行');
    }
  });
}
