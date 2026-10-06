/// ISP 编组「生成Verilog IP」的校验层：复用黑盒行级流水的校验口径（全帧
/// 统计/跨帧/数据环在 FPGA 上同样需要帧缓冲，拒绝集天然成立），再收窄到
/// IP 节点白名单并做参数检查。可导出返回 null，否则返回中文错误说明。
library;

import '../models/isp_graph.dart';
import '../models/isp_node.dart';
import 'group_c_export_bb.dart';

/// v1 IP 节点白名单（仅多段色彩均衡器；后续按
/// docs/IP_Generator_Plan.md「v1 节点白名单」逐步扩展）。
const Set<String> kIpV1TypeIds = {'multi_band_eq'};

/// 校验编组能否导出 Verilog IP；可导出返回 null，否则返回中文错误说明。
String? validateGroupIpExport(IspGraph graph, IspNodeGroup group) {
  // 黑盒口径：基础校验（validateGroupCExport）+ 流式支持集 + demosaic /
  // white_balance(auto) / q 参数 / 数据环。
  final base = validateGroupBlackBoxExport(graph, group);
  if (base != null) return base;

  final members = [for (final id in group.nodeIds) ?graph.nodes[id]];
  final unsupported = <String>[];
  for (final n in members) {
    if (!kIpV1TypeIds.contains(n.typeId)) {
      final display = IspNodeRegistry.byId(n.typeId)?.displayName ?? n.typeId;
      unsupported.add('${n.name}（$display）');
    }
  }
  if (unsupported.isNotEmpty) {
    return 'Verilog IP v1 暂仅支持「多段色彩均衡器」节点，以下节点尚未'
        '支持：${unsupported.join('、')}。';
  }
  // multi_band_eq：Verilog 定点口径要求 codegenMode=lut_fixed（FP64 的
  // lut 模式与 func 模式在 RTL 上无逐位可复现的定点表）。
  for (final n in members) {
    if (n.typeId == 'multi_band_eq' &&
        n.paramValues['codegenMode'] != 'lut_fixed') {
      return '节点 ${n.name} 的 codegenMode 必须为 lut_fixed（Verilog 定点'
          '口径；请在节点参数中切换为 lut_fixed 后重试）。';
    }
  }
  return null;
}
