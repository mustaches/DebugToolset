/// ISP 节点编组 C 导出的「规划层」：从图与编组推导发射所需的全部中间
/// 产物（拓扑序、mux4 死支路裁剪与 live 集、节点封装、边缓冲、外部
/// 输入/输出、gamma 穿透解析、scratch 布局项），不做任何字符串拼接。
/// 发射层见 group_c_export.dart 的 buildGroupCFiles（plan → emit 两段式）；
/// 后续导出变体（如行级流水黑盒）可复用 [planGroupC] 的产物自行发射。
library;

import '../models/isp_graph.dart';
import '../models/isp_node.dart';
import 'c_ident.dart';
import 'node_c_gen.dart';

/// 编组外部端口（run() 形参）：形参名、通道数与 C 类型。
class GroupCExtPort {
  final String name;
  final int channels;
  final String cType;
  const GroupCExtPort(this.name, this.channels, this.cType);
}

/// 节点的 LUT 烘焙域上限：沿各输入端口向上追溯（跨组边界、gamma 直通
/// 不影响位深）到无输入的源节点，取其 bitDepth 参数（bayerMaxValue 等价
/// (1<<bitDepth)-1）；追溯不到回退 1023（源节点 bitDepth 缺省 10bit）。
/// LUT 模式节点的烘焙表按 0..该值全量生成；运行时 max_value 不一致时
/// wrapper 回退直算（见各模板注释），所以推导只影响表大小与快路径命中。
int lutDomainMaxOf(IspGraph graph, IspNode node) {
  final seen = <String>{};
  final queue = [node.id];
  while (queue.isNotEmpty) {
    final id = queue.removeLast();
    if (!seen.add(id)) continue;
    final n = graph.nodes[id];
    if (n == null) continue;
    final type = IspNodeRegistry.byId(n.typeId);
    if (type == null) continue;
    if (type.inputs.isEmpty) {
      // 源节点：bitDepth 参数兼容字符串/数字（面板文本框存字符串）。
      final bd = int.tryParse('${n.paramValues['bitDepth'] ?? ''}');
      if (bd != null && bd > 0 && bd <= 16) return (1 << bd) - 1;
      continue;
    }
    for (final port in type.inputs) {
      final c = graph.connectionAt(id, port.name);
      if (c != null) queue.add(c.fromNodeId);
    }
  }
  return 1023;
}

/// 编组 top 层名（`isp_pipeline_<组名净化>`，组名全非 C 字符时回退组 id）。
String groupCTopName(IspNodeGroup group) {
  final topBase = sanitizeCIdent(group.name);
  return 'isp_pipeline_${topBase ?? group.id.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_')}';
}

/// 端口类型 → 帧格式字符串（'rgb'/'yuv'/'hsl'/'bayer'/'mono'；mono 与全部
/// 单通道端口归一为 'mono'）。
String cFrameFormatOfPort(IspPortType t) => switch (t) {
      IspPortType.rgb => 'rgb',
      IspPortType.yuv => 'yuv',
      IspPortType.hsl => 'hsl',
      IspPortType.bayer => 'bayer',
      _ => 'mono',
    };

/// 端口类型 → 帧通道数（rgb/yuv/hsl=3，其余 1）。
int cChannelsOfPort(IspPortType t) => switch (t) {
      IspPortType.rgb || IspPortType.yuv || IspPortType.hsl => 3,
      _ => 1,
    };

/// 编组 C 导出的规划产物：[planGroupC] 的输出，承载发射 top 层（或其它
/// 导出变体）所需的一切推导结果，不含任何已拼接的代码字符串。
class GroupCPlan {
  /// 编组成员节点（id → 节点，仅图中仍存在的）。
  final Map<String, IspNode> members;

  /// 活跃节点的拓扑序（已剔除 mux4 死支路上游与防御环漏项补尾）。
  final List<String> topo;

  /// 活跃节点集（拓扑序成员的集合形式）。
  final Set<String> live;

  /// 裁剪后的组内活边（已剔除 mux4 死边与死支路相关边）。
  final List<IspConnection> inGroupConns;

  /// 节点 id → 净化标识符（文件名 / 函数名前缀）。
  final Map<String, String> idents;

  /// top 层名（见 [groupCTopName]）。
  final String topName;

  /// 节点 id → 每节点封装生成结果（.h/.c 内容与端口 ABI）。
  final Map<String, CNodeFiles> wrappers;

  /// 中间边缓冲：'nodeId:port' → 缓冲名（e0/e1/...，按活边首次出现序）。
  /// gamma 不开边缓冲（其组内下游直接用 gamma 的输入缓冲，见
  /// [inputBuffers]）。
  final Map<String, String> edgeBuffers;

  /// 边缓冲名 → 字节数表达式（实参名 w/h 固定）。
  final Map<String, String> edgeBytes;

  /// 外部输入：'nodeId:port' → 形参（活动输入端口中组外连接或未连接的）。
  final Map<String, GroupCExtPort> extInputs;

  /// run() 的外部输入形参列表（声明序）。
  final List<GroupCExtPort> extInputParams;

  /// 外部输出：'nodeId:regPort' → 形参（regPort 为图端口名，gamma 的
  /// out_rgba 归一为 out）。
  final Map<String, GroupCExtPort> extOutputs;

  /// run() 的外部输出形参列表（声明序）。
  final List<GroupCExtPort> extOutputParams;

  /// 每个活跃节点每个 wrapper 输入端口的缓冲解析结果：'nodeId:port' →
  /// 缓冲名（外部形参或边缓冲），null 表示传 NULL（未连接的次要输入）。
  /// 已含 gamma 穿透（沿 gamma 的输入向上解析到其上游缓冲）。
  final Map<String, String?> inputBuffers;

  /// scratch 持久区端口（跨帧保留，如 fluoro_temporal 的 history），
  /// 拓扑序。
  final List<({String nodeId, CPort port})> persistPorts;

  /// 持久区缓冲名：'nodeId:port' → `hist_<ident>`。
  final Map<String, String> persistNames;

  /// 各节点 scratch 宏表达式项（`MACRO(w, h, max_value)`，拓扑序）。
  final List<String> scratchMacros;

  /// scratch 竞技场总大小的求和项（持久区 → 边缓冲 → 节点 scratch MAX
  /// 表达式），发射层逐项包 ISP_PIPE_ALIGN8 后求和。
  final List<String> scratchTerms;

  const GroupCPlan({
    required this.members,
    required this.topo,
    required this.live,
    required this.inGroupConns,
    required this.idents,
    required this.topName,
    required this.wrappers,
    required this.edgeBuffers,
    required this.edgeBytes,
    required this.extInputs,
    required this.extInputParams,
    required this.extOutputs,
    required this.extOutputParams,
    required this.inputBuffers,
    required this.persistPorts,
    required this.persistNames,
    required this.scratchMacros,
    required this.scratchTerms,
  });
}

/// 执行编组 C 导出的全部规划（见 [GroupCPlan] 各字段）。纯推导，无 IO、
/// 无字符串代码生成；调用前应先经 validateGroupCExport 校验。
GroupCPlan planGroupC(IspGraph graph, IspNodeGroup group) {
  final members = {
    for (final id in group.nodeIds)
      if (graph.nodes[id] != null) id: graph.nodes[id]!,
  };
  final memberIds = members.keys.toSet();

  // ---- 命名 ----
  final taken = <String>{};
  final idents = <String, String>{
    for (final n in members.values)
      n.id: uniqueCIdent(n.name, 'node_${n.id}', taken),
  };
  final topName = groupCTopName(group);

  // ---- 拓扑序（仅组内成员；防御环导致的漏项）----
  final fullTopo = graph.topologicalOrder();
  final topo = <String>[
    for (final id in fullTopo)
      if (memberIds.contains(id)) id,
    for (final id in memberIds)
      if (!fullTopo.contains(id)) id,
  ];

  // ---- mux4 未选中支路裁剪（与 Dart 预览 compileChain 一致：未选中槽位
  // 是死路——不追溯、不计算）。连到 mux4 未选中槽位（inN*，N != 烘焙
  // select）的组内边为死边；只经死边下游的组内节点整体不活跃：不生成
  // 封装、不分配边缓冲/scratch、top 层不调用，也不为其组外来源生成
  // run() 形参。互斥输入组（in/in_yuv/... 同组只允一路连接）无此问题，
  // 各 wrapper 模板本就按 ctx.inputFormats 只生成活动分支。----
  int muxSelectOf(IspNode n) =>
      ((n.paramValues['select'] as num?)?.toInt() ?? 1).clamp(1, 4);
  bool isDeadConn(IspConnection c) {
    final to = members[c.toNodeId];
    return to != null &&
        to.typeId == 'mux4' &&
        !c.toPort.startsWith('in${muxSelectOf(to)}');
  }

  final inGroupConns = [
    for (final c in graph.connections)
      if (memberIds.contains(c.fromNodeId) && memberIds.contains(c.toNodeId)) c,
  ];
  final liveConns = [for (final c in inGroupConns) if (!isDeadConn(c)) c];

  // 活跃成员（不动点）：有组外连接、真尾节点（无任何组内出边，输出按
  // 尾节点语义暴露为组输出）、gamma（链尾 rgba 恒暴露）为种子，再沿活边
  // 反向扩散。只经死边下游的节点（死支路上游）被裁剪。
  final live = <String>{
    for (final id in topo)
      if (graph.connections.any(
              (c) => c.fromNodeId == id && !memberIds.contains(c.toNodeId)) ||
          !inGroupConns.any((c) => c.fromNodeId == id) ||
          members[id]!.typeId == 'gamma')
        id,
  };
  var grew = true;
  while (grew) {
    grew = false;
    for (final c in liveConns) {
      if (live.contains(c.toNodeId) && live.add(c.fromNodeId)) grew = true;
    }
  }
  topo.removeWhere((id) => !live.contains(id));
  inGroupConns
    ..clear()
    ..addAll(liveConns.where(
        (c) => live.contains(c.fromNodeId) && live.contains(c.toNodeId)));

  // ---- 端口格式工具（公开版见 cFrameFormatOfPort/cChannelsOfPort）----
  final formatOfPort = cFrameFormatOfPort;
  final channelsOfPort = cChannelsOfPort;

  // 成员的活动输入端口：已连接（组内/组外）的端口；全无连接时取首要端口。
  // mux4 只统计选中槽位（inN*，N == 烘焙 select）——未选中槽位的连接是
  // 死支路，不参与生成（见上方裁剪说明）。
  Map<String, String> activeInputFormats(IspNode n, IspNodeType type) {
    final selSlot = n.typeId == 'mux4' ? 'in${muxSelectOf(n)}' : null;
    final result = <String, String>{};
    for (final port in type.inputs) {
      if (selSlot != null && !port.name.startsWith(selSlot)) continue;
      if (graph.connectionAt(n.id, port.name) != null) {
        result[port.name] = formatOfPort(port.type);
      }
    }
    if (result.isEmpty && type.inputs.isNotEmpty) {
      final p = type.inputs.first;
      result[p.name] = formatOfPort(p.type);
    }
    return result;
  }

  // ---- 生成各节点封装 ----
  final wrappers = <String, CNodeFiles>{};
  for (final id in topo) {
    final n = members[id]!;
    final type = IspNodeRegistry.byId(n.typeId)!;
    wrappers[id] = genCNodeWrapper(CNodeGenCtx(
      node: n,
      type: type,
      ident: idents[id]!,
      inputFormats: activeInputFormats(n, type),
      lutDomainMax: lutDomainMaxOf(graph, n),
    ));
  }

  // ---- 中间边缓冲：按生产者 (node, port) 一个缓冲；gamma 不开边缓冲
  //（其组内下游直接用 gamma 的输入缓冲，见 inputBuffers）。只统计裁剪
  // 后的活边（inGroupConns 已在上方剔除 mux4 死支路）。----
  final edgeBuffers = <String, String>{}; // 'nodeId:port' → 缓冲名
  final edgeBytes = <String, String>{}; // 缓冲名 → bytesExpr
  var edgeSeq = 0;
  for (final c in inGroupConns) {
    final key = '${c.fromNodeId}:${c.fromPort}';
    if (edgeBuffers.containsKey(key)) continue;
    if (members[c.fromNodeId]!.typeId == 'gamma') continue;
    final fromType = IspNodeRegistry.byId(members[c.fromNodeId]!.typeId)!;
    final port = fromType.outputs.firstWhere((p) => p.name == c.fromPort,
        orElse: () => fromType.outputs.first);
    final buf = 'e${edgeSeq++}';
    edgeBuffers[key] = buf;
    edgeBytes[buf] =
        '(size_t)(w) * (size_t)(h) * ${channelsOfPort(port.type)}u * sizeof(uint16_t)';
  }

  // ---- 外部输入（run() 形参）：活动输入端口中，组外连接或无连接的 ----
  final extInputs = <String, GroupCExtPort>{}; // 'nodeId:port' → 形参
  final extInputParams = <GroupCExtPort>[];
  for (final id in topo) {
    final n = members[id]!;
    final type = IspNodeRegistry.byId(n.typeId)!;
    final active = activeInputFormats(n, type);
    for (final port in type.inputs) {
      if (!active.containsKey(port.name)) continue;
      final conn = graph.connectionAt(id, port.name);
      if (conn != null && memberIds.contains(conn.fromNodeId)) continue;
      final p = GroupCExtPort('in${extInputParams.length}',
          channelsOfPort(port.type), 'uint16_t');
      extInputs['$id:${port.name}'] = p;
      extInputParams.add(p);
    }
  }

  // ---- 外部输出（run() 形参）：连到组外的输出端口；或节点在组内无
  // 出边时其未连接输出。gamma 的 rgba 恒暴露（链尾语义）。----
  final extOutputs = <String, GroupCExtPort>{}; // 'nodeId:regPort' → 形参
  final extOutputParams = <GroupCExtPort>[];
  final hasInGroupOut = {
    for (final id in topo) id: inGroupConns.any((c) => c.fromNodeId == id),
  };
  for (final id in topo) {
    final w = wrappers[id]!;
    for (final cp in w.outputs) {
      if (cp.isPersistent) continue;
      final regPort = cp.name == 'out_rgba' ? 'out' : cp.name;
      final conns = [
        for (final c in graph.connections)
          if (c.fromNodeId == id && c.fromPort == regPort) c,
      ];
      final inGroup = conns.where((c) => memberIds.contains(c.toNodeId));
      final outGroup = conns.where((c) => !memberIds.contains(c.toNodeId));
      final exposed = cp.name == 'out_rgba' ||
          outGroup.isNotEmpty ||
          (inGroup.isEmpty && !(hasInGroupOut[id] ?? false));
      if (!exposed) continue;
      final p = GroupCExtPort('out${extOutputParams.length}', cp.channels, cp.cType);
      extOutputs['$id:$regPort'] = p;
      extOutputParams.add(p);
    }
  }

  // 消费端口 → 缓冲名解析（gamma 直通沿其输入向上解析）。
  String? inputBufferOf(String nodeId, String portName) {
    final conn = graph.connectionAt(nodeId, portName);
    if (conn == null || !memberIds.contains(conn.fromNodeId)) {
      return extInputs['$nodeId:$portName']?.name;
    }
    var producer = conn.fromNodeId;
    var producerPort = conn.fromPort;
    var guard = 0;
    while (members[producer]!.typeId == 'gamma' && guard++ < 32) {
      final up = graph.connectionAt(producer, 'in');
      if (up == null || !memberIds.contains(up.fromNodeId)) {
        return extInputs['$producer:in']?.name;
      }
      producer = up.fromNodeId;
      producerPort = up.fromPort;
    }
    return edgeBuffers['$producer:$producerPort'];
  }

  // 每个活跃节点每个 wrapper 输入端口的缓冲解析（含 gamma 穿透结果）；
  // null 表示该端口未连接（发射层传 NULL）。
  final inputBuffers = <String, String?>{
    for (final id in topo)
      for (final cp in wrappers[id]!.inputs)
        '$id:${cp.name}': inputBufferOf(id, cp.name),
  };

  // ---- scratch 竞技场布局：持久区 → 边缓冲 → 节点 scratch 区 ----
  final persistPorts = [
    for (final id in topo)
      ...wrappers[id]!.outputs
          .where((p) => p.isPersistent)
          .map((p) => (nodeId: id, port: p)),
  ];
  final persistNames = <String, String>{
    for (final pp in persistPorts)
      '${pp.nodeId}:${pp.port.name}': 'hist_${idents[pp.nodeId]}',
  };
  final scratchMacros = [
    for (final id in topo)
      if (wrappers[id]!.scratchMacro != null)
        '${wrappers[id]!.scratchMacro}(w, h, max_value)',
  ];
  String maxExpr(List<String> exprs) {
    if (exprs.isEmpty) return '(size_t)0';
    var e = exprs.last;
    for (var i = exprs.length - 2; i >= 0; i--) {
      e = 'ISP_MAX(${exprs[i]}, $e)';
    }
    return e;
  }

  final scratchTerms = <String>[
    for (final pp in persistPorts) pp.port.bytesExpr,
    for (final b in edgeBytes.values) b,
    if (scratchMacros.isNotEmpty) maxExpr(scratchMacros),
  ];

  return GroupCPlan(
    members: members,
    topo: topo,
    live: live,
    inGroupConns: inGroupConns,
    idents: idents,
    topName: topName,
    wrappers: wrappers,
    edgeBuffers: edgeBuffers,
    edgeBytes: edgeBytes,
    extInputs: extInputs,
    extInputParams: extInputParams,
    extOutputs: extOutputs,
    extOutputParams: extOutputParams,
    inputBuffers: inputBuffers,
    persistPorts: persistPorts,
    persistNames: persistNames,
    scratchMacros: scratchMacros,
    scratchTerms: scratchTerms,
  );
}
