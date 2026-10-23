/// 数字网表的分层布局内核（纯 Dart、确定性、无 Flutter 依赖）。
///
/// 面向 yosys 网表这类**近似有向无环的数据流图**，实现 Sugiyama 流程中与
/// 本项目相关的四步：
/// 1. **去环**：DFS 标记回边（时序反馈环），回边不参与分层；
/// 2. **分层**：最长路径分层（保证每条前向边跨至少一层）；
/// 3. **压列**：层数超过 [maxColumns] 时用 DP 把连续层合并成列，代价为跨列边
///    数 + 列宽均衡惩罚（替代现有的“按比例缩放”粗压缩）；
/// 4. **层内排序**：中位数启发式双向扫描 + 相邻交换（降低相邻列之间的边交叉），
///    平局一律按节点下标稳定排序，保证同一输入逐次产出同一结果。
///
/// 只处理整数节点与边；块尺寸、针脚、坐标分配仍由 `netlist_diagram.dart`
/// 负责，便于与既有几何/回归解耦。
library;

import 'dart:math' as math;

/// 分层布局结果。
class NlLayeredLayoutResult {
  /// 每个节点的列号（0..[columnCount]-1）。
  final List<int> column;

  /// 每列的节点顺序（自上而下）。
  final Map<int, List<int>> order;

  final int columnCount;

  /// 压列前的层数（诊断用）。
  final int layerCount;

  /// 相邻列之间的边交叉数（块级口径，诊断用）。
  final int crossingCount;

  /// 因压列而跨越列边界的边数。
  final int cutEdges;

  const NlLayeredLayoutResult({
    required this.column,
    required this.order,
    required this.columnCount,
    required this.layerCount,
    required this.crossingCount,
    required this.cutEdges,
  });

  static const empty = NlLayeredLayoutResult(
    column: [],
    order: {},
    columnCount: 0,
    layerCount: 0,
    crossingCount: 0,
    cutEdges: 0,
  );
}

/// 计算分层布局。
///
/// - [edges]：`(from, to)`，允许重复边与自环（自环忽略）。
/// - [sequential]：可选，标记时序单元（DFF 等）。当前实现按回边统一处理，
///   该参数保留给后续“寄存器边界优先”策略。
/// - [maxColumns]：列数上限（≥1）。
/// - [sift]：排序后是否执行 Sifting（单节点挪到列内最优位置）；大图默认
///   受预算上限保护，超限自动跳过。
/// - [balance]：最长路径分层后做“层平衡”坐标下降（只在前向边上移动节点，
///   每次移动都缩短总边长），用于压画布高度。
NlLayeredLayoutResult layoutLayeredNetlist({
  required int nodeCount,
  required List<(int, int)> edges,
  List<bool>? sequential,
  int maxColumns = 12,
  bool sift = true,
  bool balance = true,
}) {
  if (nodeCount <= 0) return NlLayeredLayoutResult.empty;
  final cap = math.max(1, maxColumns);

  // ---- 邻接表（去重、去自环、稳定排序）----
  final succ = List.generate(nodeCount, (_) => <int>{}, growable: false);
  final pred = List.generate(nodeCount, (_) => <int>{}, growable: false);
  for (final (u, v) in edges) {
    if (u == v || u < 0 || v < 0 || u >= nodeCount || v >= nodeCount) continue;
    succ[u].add(v);
    pred[v].add(u);
  }
  final succList = [
    for (final s in succ) (s.toList()..sort()),
  ];
  final predList = [
    for (final p in pred) (p.toList()..sort()),
  ];

  // ---- 去环：DFS 标记回边 ----
  final state = List<int>.filled(nodeCount, 0); // 0 未访问，1 栈中，2 完成
  final back = <(int, int)>{};
  final finish = <int>[];
  for (var start = 0; start < nodeCount; start++) {
    if (state[start] != 0) continue;
    final stack = <(int, int)>[(start, 0)];
    state[start] = 1;
    while (stack.isNotEmpty) {
      final (u, i) = stack.last;
      final list = succList[u];
      if (i >= list.length) {
        state[u] = 2;
        finish.add(u);
        stack.removeLast();
        continue;
      }
      stack[stack.length - 1] = (u, i + 1);
      final v = list[i];
      if (state[v] == 1) {
        back.add((u, v));
      } else if (state[v] == 0) {
        state[v] = 1;
        stack.add((v, 0));
      }
    }
  }
  final topo = finish.reversed.toList(growable: false);

  // ---- 最长路径分层（仅前向边）----
  final layer = List<int>.filled(nodeCount, 0);
  for (final v in topo) {
    for (final u in predList[v]) {
      if (back.contains((u, v))) continue;
      layer[v] = math.max(layer[v], layer[u] + 1);
    }
  }
  if (balance) _balanceLayers(layer, predList, succList, back);
  var layerCount = 0;
  for (final l in layer) {
    layerCount = math.max(layerCount, l + 1);
  }

  // ---- 压列：层数超限时 DP 合并连续层 ----
  var group = List<int>.generate(layerCount, (i) => i);
  var columnCount = layerCount;
  if (layerCount > cap) {
    final groups = _partitionLayers(
      layer: layer,
      layerCount: layerCount,
      predList: predList,
      back: back,
      maxColumns: cap,
    );
    group = groups.group;
    columnCount = groups.count;
  }

  final column = List<int>.generate(nodeCount, (i) => group[layer[i]]);
  final order = <int, List<int>>{
    for (var c = 0; c < columnCount; c++)
      c: [
        for (var i = 0; i < nodeCount; i++)
          if (column[i] == c) i,
      ],
  };

  // ---- 层内排序 ----
  _orderColumns(order, column, succList, predList);
  if (sift) _siftColumns(order, succList);
  final crossing = _totalCrossings(order, succList);

  // 诊断：跨列边数。
  var cutEdges = 0;
  for (var u = 0; u < nodeCount; u++) {
    for (final v in succList[u]) {
      if (back.contains((u, v))) continue;
      if (column[u] != column[v]) cutEdges++;
    }
  }

  return NlLayeredLayoutResult(
    column: column,
    order: {
      for (final e in order.entries)
        e.key: List<int>.unmodifiable(e.value),
    },
    columnCount: columnCount,
    layerCount: layerCount,
    crossingCount: crossing,
    cutEdges: cutEdges,
  );
}

/// 层平衡：对每个节点，出边多于入边就尽量下移（入边多于出边则尽量上移），
/// 每次移动都严格缩短总边长；最多 8 轮，确定性顺序。
void _balanceLayers(
  List<int> layer,
  List<List<int>> predList,
  List<List<int>> succList,
  Set<(int, int)> back,
) {
  const inf = 1 << 30;
  for (var pass = 0; pass < 8; pass++) {
    var moved = false;
    for (var v = 0; v < layer.length; v++) {
      var inDeg = 0;
      var outDeg = 0;
      var lo = 0;
      var hi = inf;
      for (final u in predList[v]) {
        if (back.contains((u, v))) continue;
        inDeg++;
        if (layer[u] + 1 > lo) lo = layer[u] + 1;
      }
      for (final w in succList[v]) {
        if (back.contains((v, w))) continue;
        outDeg++;
        if (layer[w] - 1 < hi) hi = layer[w] - 1;
      }
      if (inDeg == 0 && outDeg == 0) continue;
      if (hi < lo) continue;
      int target;
      if (outDeg == 0 || inDeg > outDeg) {
        target = lo;
      } else if (outDeg > inDeg) {
        target = hi == inf ? layer[v] : hi;
      } else {
        continue;
      }
      if (target != layer[v]) {
        layer[v] = target;
        moved = true;
      }
    }
    if (!moved) break;
  }
}

/// 连续层分组成列：最小化跨列边 + 列宽均衡。
({List<int> group, int count}) _partitionLayers({
  required List<int> layer,
  required int layerCount,
  required List<List<int>> predList,
  required Set<(int, int)> back,
  required int maxColumns,
}) {
  final k = math.min(maxColumns, layerCount);
  // cut[b]：跨过“第 b 层之前”这条边界的边数（b=1..layerCount-1）。
  final diff = List<int>.filled(layerCount + 1, 0);
  for (var v = 0; v < layer.length; v++) {
    for (final u in predList[v]) {
      if (back.contains((u, v))) continue;
      final lo = layer[u] + 1;
      final hi = layer[v];
      if (hi < lo) continue; // 同层边不计
      diff[lo]++;
      diff[hi + 1]--;
    }
  }
  final cut = List<int>.filled(layerCount, 0);
  var running = 0;
  for (var b = 0; b < layerCount; b++) {
    running += diff[b];
    cut[b] = b == 0 ? 0 : running;
  }
  // 每层节点数（均衡项按节点数比较）。
  final layerSize = List<int>.filled(layerCount, 0);
  for (final l in layer) {
    layerSize[l]++;
  }
  final prefix = List<int>.filled(layerCount + 1, 0);
  for (var i = 0; i < layerCount; i++) {
    prefix[i + 1] = prefix[i] + layerSize[i];
  }
  final avg = prefix.last / k;
  const balance = 1.5;

  // dp[g][i]：前 i 层分成 g 列的最小代价；choice 记录上一个边界。
  const inf = 1 << 60;
  final dp = List.generate(k + 1, (_) => List<int>.filled(layerCount + 1, inf));
  final choice = List.generate(
    k + 1,
    (_) => List<int>.filled(layerCount + 1, -1),
  );
  dp[0][0] = 0;
  for (var g = 1; g <= k; g++) {
    for (var i = g; i <= layerCount; i++) {
      for (var j = g - 1; j < i; j++) {
        if (dp[g - 1][j] >= inf) continue;
        final size = (prefix[i] - prefix[j]).toDouble();
        final penalty = balance * (size - avg) * (size - avg);
        final cost = dp[g - 1][j] + cut[j] + penalty.round();
        if (cost >= dp[g][i]) continue;
        dp[g][i] = cost;
        choice[g][i] = j;
      }
    }
  }
  final boundaries = <int>[0];
  var i = layerCount;
  for (var g = k; g >= 2; g--) {
    final j = choice[g][i];
    if (j <= 0) break;
    boundaries.add(j);
    i = j;
  }
  boundaries.sort();
  final group = List<int>.filled(layerCount, 0);
  for (var g = 0; g < boundaries.length; g++) {
    final start = boundaries[g];
    final end = g + 1 < boundaries.length ? boundaries[g + 1] : layerCount;
    for (var l = start; l < end; l++) {
      group[l] = g;
    }
  }
  return (group: group, count: boundaries.length);
}

/// 中位数启发式 + 相邻交换；全程保留交叉数最优的列顺序快照。
void _orderColumns(
  Map<int, List<int>> order,
  List<int> column,
  List<List<int>> succ,
  List<List<int>> pred,
) {
  final columns = order.keys.toList()..sort();
  if (columns.length < 2) return;
  final pos = <int, int>{};
  void refresh() {
    for (final c in columns) {
      final nodes = order[c]!;
      for (var i = 0; i < nodes.length; i++) {
        pos[nodes[i]] = i;
      }
    }
  }

  refresh();
  var best = _totalCrossings(order, succ);
  var bestOrder = <int, List<int>>{
    for (final e in order.entries) e.key: [...e.value],
  };
  for (var pass = 0; pass < 6; pass++) {
    final down = pass.isEven;
    final seq = down ? columns : columns.reversed.toList();
    for (final c in seq) {
      final nodes = order[c]!;
      if (nodes.length < 2) continue;
      final keys = <int, double>{};
      for (final n in nodes) {
        final neighbours = down ? pred[n] : succ[n];
        final values = <double>[
          for (final m in neighbours)
            if (column[m] != c) (pos[m] ?? 0).toDouble(),
        ];
        keys[n] = values.isEmpty ? (pos[n] ?? 0).toDouble() : _median(values);
      }
      final sorted = [...nodes]..sort((a, b) {
        final ka = keys[a]!, kb = keys[b]!;
        if (ka != kb) return ka.compareTo(kb);
        final pa = pos[a] ?? 0, pb = pos[b] ?? 0;
        if (pa != pb) return pa.compareTo(pb);
        return a.compareTo(b);
      });
      nodes
        ..clear()
        ..addAll(sorted);
      for (var i = 0; i < nodes.length; i++) {
        pos[nodes[i]] = i;
      }
    }
    final after = _totalCrossings(order, succ);
    if (after < best) {
      best = after;
      bestOrder = {for (final e in order.entries) e.key: [...e.value]};
    }
  }
  // 回到最优快照（中位数单趟可能劣化，不能直接留在最后状态）。
  for (final e in order.entries) {
    e.value
      ..clear()
      ..addAll(bestOrder[e.key]!);
  }
  _transpose(order, succ);
}

double _median(List<double> values) {
  final sorted = [...values]..sort();
  final mid = sorted.length ~/ 2;
  if (sorted.length.isOdd) return sorted[mid];
  return (sorted[mid - 1] + sorted[mid]) / 2;
}

/// Sifting：逐个节点尝试列内全部位置，保留相邻列交叉最少的位置；两轮无改善
/// 即停。预算上限 20000 次位置评估，防止大图退化；平局保留原位置。
void _siftColumns(Map<int, List<int>> order, List<List<int>> succ) {
  final columns = order.keys.toList()..sort();
  var best = _totalCrossings(order, succ);
  var moves = 0;
  for (var pass = 0; pass < 2; pass++) {
    var improved = false;
    for (final c in columns) {
      final nodes = order[c]!;
      if (nodes.length < 2) continue;
      for (var i = 0; i < nodes.length; i++) {
        if (moves > 20000) return;
        final node = nodes.removeAt(i);
        var bestPos = i;
        var bestScore = 1 << 60;
        for (var j = 0; j <= nodes.length; j++) {
          nodes.insert(j, node);
          final score = _totalCrossings(order, succ);
          moves++;
          if (j == i) {
            bestScore = score;
            bestPos = i;
          } else if (score < bestScore) {
            bestScore = score;
            bestPos = j;
          }
          nodes.removeAt(j);
        }
        nodes.insert(bestPos, node);
        if (bestScore < best) {
          best = bestScore;
          improved = true;
        }
      }
    }
    if (!improved) break;
  }
}

/// 相邻交换：只保留能减少交叉的交换。
void _transpose(
  Map<int, List<int>> order,
  List<List<int>> succ,
) {
  final columns = order.keys.toList()..sort();
  var current = _totalCrossings(order, succ);
  for (var round = 0; round < 2; round++) {
    var improved = false;
    for (final c in columns) {
      final nodes = order[c]!;
      for (var i = 0; i + 1 < nodes.length; i++) {
        final before = current;
        final tmp = nodes[i];
        nodes[i] = nodes[i + 1];
        nodes[i + 1] = tmp;
        final after = _totalCrossings(order, succ);
        if (after < before) {
          current = after;
          improved = true;
        } else {
          final back = nodes[i];
          nodes[i] = nodes[i + 1];
          nodes[i + 1] = back;
        }
      }
    }
    if (!improved) break;
  }
}

/// 相邻列之间的边交叉总数（边按源列位置排序后统计目标列位置逆序对）。
int _totalCrossings(Map<int, List<int>> order, List<List<int>> succ) {
  final columns = order.keys.toList()..sort();
  final columnOf = <int, int>{};
  final pos = <int, int>{};
  for (final c in columns) {
    final nodes = order[c]!;
    for (var i = 0; i < nodes.length; i++) {
      columnOf[nodes[i]] = c;
      pos[nodes[i]] = i;
    }
  }
  var total = 0;
  for (var gi = 0; gi + 1 < columns.length; gi++) {
    final c = columns[gi];
    final next = columns[gi + 1];
    final pairs = <(int, int)>[];
    for (final u in order[c]!) {
      for (final v in succ[u]) {
        if (columnOf[v] != next) continue;
        pairs.add((pos[u]!, pos[v]!));
      }
    }
    if (pairs.length < 2) continue;
    total += _inversions(pairs);
  }
  return total;
}

int _inversions(List<(int, int)> pairs) {
  pairs.sort((a, b) {
    if (a.$1 != b.$1) return a.$1.compareTo(b.$1);
    return a.$2.compareTo(b.$2);
  });
  final values = [for (final p in pairs) p.$2];
  return _mergeSortCount(values, List<int>.filled(values.length, 0), 0, values.length);
}

int _mergeSortCount(List<int> a, List<int> tmp, int lo, int hi) {
  if (hi - lo <= 1) return 0;
  final mid = (lo + hi) >> 1;
  var count = _mergeSortCount(a, tmp, lo, mid) + _mergeSortCount(a, tmp, mid, hi);
  var i = lo;
  var j = mid;
  var k = lo;
  while (i < mid && j < hi) {
    if (a[i] <= a[j]) {
      tmp[k++] = a[i++];
    } else {
      tmp[k++] = a[j++];
      count += mid - i;
    }
  }
  while (i < mid) {
    tmp[k++] = a[i++];
  }
  while (j < hi) {
    tmp[k++] = a[j++];
  }
  for (var t = lo; t < hi; t++) {
    a[t] = tmp[t];
  }
  return count;
}
