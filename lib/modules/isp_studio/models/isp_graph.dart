/// ISP Studio 节点图数据模型（纯 Dart，无 Flutter 依赖）。
library;

import 'isp_node.dart';

/// 节点间的一条连接。
class IspConnection {
  final String id;
  final String fromNodeId;

  /// 输出端口名。
  final String fromPort;
  final String toNodeId;

  /// 输入端口名。
  final String toPort;

  const IspConnection({
    required this.id,
    required this.fromNodeId,
    required this.fromPort,
    required this.toNodeId,
    required this.toPort,
  });
}

/// ISP 节点图。
class IspGraph {
  final Map<String, IspNode> nodes = {};
  final List<IspConnection> connections = [];
  int nextId = 1;

  IspGraph();

  /// 添加节点，返回节点 id（形如 'n7'）。类型不存在时抛 [ArgumentError]。
  String addNode(String typeId, double x, double y) {
    final type = IspNodeRegistry.byId(typeId);
    if (type == null) {
      throw ArgumentError('未知节点类型: $typeId');
    }
    final id = 'n${nextId++}';
    nodes[id] = IspNode.create(type, id, x, y);
    return id;
  }

  /// 删除节点，并级联删除其所有连接。
  void removeNode(String id) {
    nodes.remove(id);
    connections.removeWhere((c) => c.fromNodeId == id || c.toNodeId == id);
  }

  /// 建立连接。成功返回 null，失败返回中文错误信息。
  ///
  /// 目标输入端口已有连接时，替换旧连接并返回 null。
  String? connect(
    String fromNodeId,
    String fromPort,
    String toNodeId,
    String toPort,
  ) {
    final fromNode = nodes[fromNodeId];
    final toNode = nodes[toNodeId];
    if (fromNode == null || toNode == null) {
      return '节点不存在';
    }
    if (fromNodeId == toNodeId) {
      return '不允许节点连接自身';
    }
    final fromType = IspNodeRegistry.byId(fromNode.typeId);
    final toType = IspNodeRegistry.byId(toNode.typeId);
    final outSpec = fromType?.outputPort(fromPort);
    final inSpec = toType?.inputPort(toPort);
    if (outSpec == null || inSpec == null) {
      return '端口不存在';
    }
    if (outSpec.type != inSpec.type) {
      return '端口类型不匹配';
    }
    if (_wouldCreateCycle(fromNodeId, toNodeId)) {
      return '不允许形成环路';
    }
    // 输入端口只允许一条连接：替换旧连接。
    disconnectInput(toNodeId, toPort);
    connections.add(IspConnection(
      id: 'c${nextId++}',
      fromNodeId: fromNodeId,
      fromPort: fromPort,
      toNodeId: toNodeId,
      toPort: toPort,
    ));
    return null;
  }

  /// 按连接 id 断开。
  void disconnect(String connectionId) {
    connections.removeWhere((c) => c.id == connectionId);
  }

  /// 断开某节点指定输入端口的连接。
  void disconnectInput(String nodeId, String port) {
    connections.removeWhere((c) => c.toNodeId == nodeId && c.toPort == port);
  }

  /// 查询某节点指定输入端口上的连接。
  IspConnection? connectionAt(String nodeId, String inputPort) {
    for (final c in connections) {
      if (c.toNodeId == nodeId && c.toPort == inputPort) return c;
    }
    return null;
  }

  /// 对所有节点做 Kahn 拓扑排序（含无连接的孤立节点）。
  /// 存在环路时返回空列表。
  List<String> topologicalOrder() {
    final indegree = <String, int>{for (final id in nodes.keys) id: 0};
    final adj = <String, List<String>>{for (final id in nodes.keys) id: []};
    for (final c in connections) {
      if (!nodes.containsKey(c.fromNodeId) || !nodes.containsKey(c.toNodeId)) {
        continue;
      }
      adj[c.fromNodeId]!.add(c.toNodeId);
      indegree[c.toNodeId] = indegree[c.toNodeId]! + 1;
    }
    final queue = <String>[];
    for (final id in nodes.keys) {
      if (indegree[id] == 0) queue.add(id);
    }
    final order = <String>[];
    while (queue.isNotEmpty) {
      final id = queue.removeAt(0);
      order.add(id);
      for (final next in adj[id]!) {
        final d = indegree[next]! - 1;
        indegree[next] = d;
        if (d == 0) queue.add(next);
      }
    }
    return order.length == nodes.length ? order : [];
  }

  /// 直接或间接馈入该节点的所有上游节点 id。
  List<String> upstreamOf(String nodeId) {
    final result = <String>[];
    final visited = <String>{};
    final stack = <String>[nodeId];
    while (stack.isNotEmpty) {
      final id = stack.removeLast();
      for (final c in connections) {
        if (c.toNodeId == id && visited.add(c.fromNodeId)) {
          result.add(c.fromNodeId);
          stack.add(c.fromNodeId);
        }
      }
    }
    return result;
  }

  /// 序列化为 JSON 可编码结构（节点 + 连接 + id 计数器）。
  Map<String, Object?> toJson() => {
        'nodes': [
          for (final n in nodes.values)
            {
              'id': n.id,
              'typeId': n.typeId,
              'x': n.x,
              'y': n.y,
              'width': n.width,
              'params': n.paramValues,
            },
        ],
        'connections': [
          for (final c in connections)
            {
              'id': c.id,
              'from': c.fromNodeId,
              'fromPort': c.fromPort,
              'to': c.toNodeId,
              'toPort': c.toPort,
            },
        ],
        'nextId': nextId,
      };

  /// 从 [toJson] 的结构恢复。未知节点类型抛 [FormatException]；
  /// 引用缺失节点的连接直接跳过。
  factory IspGraph.fromJson(Map<String, Object?> json) {
    final graph = IspGraph();
    for (final raw in json['nodes'] as List? ?? const []) {
      final m = (raw as Map).cast<String, Object?>();
      final typeId = m['typeId'] as String;
      if (IspNodeRegistry.byId(typeId) == null) {
        throw FormatException('未知节点类型: $typeId');
      }
      final id = m['id'] as String;
      graph.nodes[id] = IspNode(
        id: id,
        typeId: typeId,
        x: (m['x'] as num).toDouble(),
        y: (m['y'] as num).toDouble(),
        width: (m['width'] as num?)?.toDouble() ?? kNodeWidth,
        paramValues: Map<String, Object?>.from(m['params'] as Map? ?? const {}),
      );
    }
    for (final raw in json['connections'] as List? ?? const []) {
      final m = (raw as Map).cast<String, Object?>();
      final from = m['from'] as String;
      final to = m['to'] as String;
      if (!graph.nodes.containsKey(from) || !graph.nodes.containsKey(to)) {
        continue;
      }
      graph.connections.add(IspConnection(
        id: m['id'] as String,
        fromNodeId: from,
        fromPort: m['fromPort'] as String,
        toNodeId: to,
        toPort: m['toPort'] as String,
      ));
    }
    graph.nextId = (json['nextId'] as num?)?.toInt() ?? graph._deriveNextId();
    return graph;
  }

  /// 旧文件缺 nextId 时按现有节点/连接 id 的数字后缀推导。
  int _deriveNextId() {
    var max = 0;
    for (final id in [...nodes.keys, ...connections.map((c) => c.id)]) {
      final n = int.tryParse(id.substring(1));
      if (n != null && n > max) max = n;
    }
    return max + 1;
  }

  /// 校验图，返回中文错误信息列表。
  List<String> validate() {
    final errors = <String>[];
    if (topologicalOrder().isEmpty && nodes.isNotEmpty) {
      errors.add('图中存在环路');
    }
    const sinkTypes = sinkNodeTypes;
    for (final node in nodes.values) {
      final type = IspNodeRegistry.byId(node.typeId);
      if (type == null) continue;
      if (sinkTypes.contains(node.typeId)) {
        final hasInput =
            type.inputs.any((p) => connectionAt(node.id, p.name) != null);
        if (!hasInput) {
          errors.add('「${type.displayName}」的输入未连接');
        }
      }
      // 源节点（无输入且有 filePath 参数）必须设置文件路径。
      if (type.inputs.isEmpty &&
          type.params.any((p) => p.key == 'filePath')) {
        final path = node.paramValues['filePath'];
        if (path == null || (path as String).isEmpty) {
          errors.add('「${type.displayName}」未设置文件路径');
        }
      }
    }
    return errors;
  }

  /// 若新增 from→to 的边会形成环路则返回 true。
  bool _wouldCreateCycle(String fromNodeId, String toNodeId) {
    // 从 toNodeId 出发沿现有边能回到 fromNodeId 即成环。
    final visited = <String>{};
    final stack = <String>[toNodeId];
    while (stack.isNotEmpty) {
      final id = stack.removeLast();
      if (id == fromNodeId) return true;
      if (!visited.add(id)) continue;
      for (final c in connections) {
        if (c.fromNodeId == id) stack.add(c.toNodeId);
      }
    }
    return false;
  }
}

/// 标准默认图：源→黑电平→去马赛克→白平衡→CCM→Gamma→预览，
/// 横向排布，预览节点下方再放一个图片输出节点并连接预览的输出。
/// 预览节点默认高 220（含屏幕附加区），图片输出须避开其底部区域。
IspGraph defaultGraph() {
  final graph = IspGraph();
  const chain = [
    'bayer_source',
    'black_level',
    'demosaic',
    'white_balance',
    'ccm',
    'gamma',
    'preview',
  ];
  String? prev;
  for (var i = 0; i < chain.length; i++) {
    final id = graph.addNode(chain[i], 100.0 + i * 230.0, 100);
    if (prev != null) {
      graph.connect(prev, 'out', id, 'in');
    }
    prev = id;
  }
  final outputId =
      graph.addNode('image_output', 100.0 + (chain.length - 1) * 230.0, 340);
  graph.connect(prev!, 'out', outputId, 'in');
  return graph;
}
