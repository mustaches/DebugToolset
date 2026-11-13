/// ISP 编组「生成Verilog IP」的校验层：复用黑盒行级流水的校验口径（全帧
/// 统计/跨帧/数据环在 FPGA 上同样需要帧缓冲，拒绝集天然成立），再收窄到
/// IP 节点白名单并做参数检查。可导出返回 null，否则返回中文错误说明。
library;

import '../models/isp_graph.dart';
import '../models/isp_node.dart';
import 'group_c_export_bb.dart';

/// IP 节点白名单：多段色彩均衡器、六向 ColorTrans、色温调节器。
const Set<String> kIpV1TypeIds = {
  'multi_band_eq',
  'csc_rgb2yuv',
  'csc_rgb2hsl',
  'csc_yuv2rgb',
  'csc_yuv2hsl',
  'csc_hsl2rgb',
  'csc_hsl2yuv',
  'color_temp_adjuster',
};

/// 校验编组能否导出 Verilog IP；可导出返回 null，否则返回中文错误说明。
String? validateGroupIpExport(IspGraph graph, IspNodeGroup group) {
  // 黑盒口径：基础校验（validateGroupCExport）+ 流式支持集 + demosaic /
  // white_balance(auto) / q 参数 / 数据环。
  final base = validateGroupBlackBoxExport(graph, group);
  if (base != null &&
      !(group.nodeIds.length == 1 &&
          base == '编组成员不足 2 个节点' &&
          kIpV1TypeIds.contains(graph.nodes[group.nodeIds.single]?.typeId))) {
    return base;
  }

  final members = [for (final id in group.nodeIds) ?graph.nodes[id]];
  final unsupported = <String>[];
  for (final n in members) {
    if (!kIpV1TypeIds.contains(n.typeId)) {
      final display = IspNodeRegistry.byId(n.typeId)?.displayName ?? n.typeId;
      unsupported.add('${n.name}（$display）');
    }
  }
  if (unsupported.isNotEmpty) {
    return '以下节点尚未支持 Verilog IP 导出：${unsupported.join('、')}。'
        '当前支持多段色彩均衡器、ColorTrans 和色温调节器。';
  }
  for (final n in members) {
    final mode = '${n.paramValues['codegenMode'] ?? 'func_fixed'}';
    if (mode != 'lut_fixed' && mode != 'func_fixed') {
      return '节点 ${n.name} 的 codegenMode 必须为 lut_fixed 或 func_fixed'
          '（Verilog 定点口径；请在节点参数中切换后重试）。';
    }
  }
  return null;
}
