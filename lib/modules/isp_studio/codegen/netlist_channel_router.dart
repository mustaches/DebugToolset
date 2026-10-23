/// 单层左右通道布线内核（纯 Dart、确定性、无 Flutter 依赖）。
///
/// 面向「列间隙」这类**两侧端子通道**：左侧一列元件的输出脚、右侧一列元件的
/// 输入脚，中间是可用的垂直通道。每条网在通道里占一条竖直车道（lane），
/// 用「左端水平 → 竖直车道 → 各右端水平」连接：单负载同高时是直线，
/// 否则主干两端各一个拐角，多负载在主干上分叉（T 型分支由调用方打点）。
///
/// 车道分配用区间着色：按端子纵向区间起点排序，复用第一条「上一区间结束
/// + 间距 ≤ 本区间起点」的车道；没有可用车道就新开一条，超出通道宽度记为
/// 未布通（由调用方回退 A*）。与 left-edge 算法同一思路，但不做 dogleg：
/// 每条网只允许一条车道，保证折弯数 ≤2、结果可复现。
library;

import 'dart:math' as math;

/// 一条待布通道网：一个左端子（驱动）+ 任意个右端子（同列负载）。
class NlChannelNet {
  /// 调用方稳定 id（通常为网的序号）；用于结果回填与平局排序。
  final int id;

  /// 左端子的 x/y（驱动脚外延点）。
  final double leftX;
  final double leftY;

  /// 右端子列表 `(x, y)`（负载脚外延点），至少一个。
  final List<(double, double)> rights;

  /// 单负载便捷构造。
  NlChannelNet({
    required this.id,
    required this.leftX,
    required this.leftY,
    required double rightX,
    required double rightY,
  }) : rights = [(rightX, rightY)];

  /// 多负载构造。
  NlChannelNet.multi({
    required this.id,
    required this.leftX,
    required this.leftY,
    required this.rights,
  });

  double get yMin {
    var v = leftY;
    for (final r in rights) {
      v = math.min(v, r.$2);
    }
    return v;
  }

  double get yMax {
    var v = leftY;
    for (final r in rights) {
      v = math.max(v, r.$2);
    }
    return v;
  }

  double get rightBound => rights.map((r) => r.$1).reduce(math.min);
}

/// 一条通道走线：主干 + 分支线段 + 车道。
class NlChannelWire {
  final int id;
  final double laneX;

  /// 线段 `(x1, y1, x2, y2)`，均为水平/垂直。
  final List<(double, double, double, double)> segments;

  /// 折弯数（同高直线 0，其余主干两端各 1 个拐角 = 2）。
  final int bends;

  /// 主干上的 T 型分支点（用于实心圆点）。
  final List<(double, double)> junctions;

  const NlChannelWire({
    required this.id,
    required this.laneX,
    required this.segments,
    required this.bends,
    this.junctions = const [],
  });
}

/// 通道布线结果。
class NlChannelPlan {
  final List<NlChannelWire> routes;

  /// 因车道不足/端点反向而未布通的 id。
  final List<int> unrouted;

  /// 实际使用的车道 x（升序）。
  final List<double> lanes;

  /// 不同网水平段共线重叠的 id 对（调用方应回退/换车道）。
  final List<(int, int)> conflicts;

  const NlChannelPlan({
    required this.routes,
    required this.unrouted,
    required this.lanes,
    required this.conflicts,
  });

  static const empty = NlChannelPlan(
    routes: [],
    unrouted: [],
    lanes: [],
    conflicts: [],
  );
}

/// 在 `[xMin, xMax]` 的通道里为 [nets] 分配车道并生成走线。
///
/// - [pitch]：车道间距（与布局 Grid 一致）。
/// - [gap]：同一车道内两段竖直区间之间要求的最小空档（≥pitch 才不会粘成一根）。
/// - [margin]：车道距通道两侧的最小留白。
NlChannelPlan routeNlChannel({
  required List<NlChannelNet> nets,
  required double xMin,
  required double xMax,
  double pitch = 15,
  double gap = 15,
  double margin = 15,
}) {
  if (nets.isEmpty) return NlChannelPlan.empty;
  // 车道必须整体落在所有左端子右侧、所有右端子左侧，且不越出调用方给的
  // 通道范围。
  final leftBound = math.max(
    xMin + margin,
    nets.map((n) => n.leftX).reduce(math.max) + margin,
  );
  final rightBound = math.min(
    xMax - margin,
    nets.map((n) => n.rightBound).reduce(math.min) - margin,
  );
  final usable = rightBound - leftBound;
  if (usable < -0.01) {
    return NlChannelPlan(
      routes: const [],
      unrouted: [for (final n in nets) n.id],
      lanes: const [],
      conflicts: const [],
    );
  }
  final laneCount = (usable / pitch).floor() + 1;

  // 所有右端都与左端同高：直线，不占车道。
  final straight = <int>[];
  final candidates = <NlChannelNet>[];
  for (final n in nets) {
    if (n.rights.every((r) => (r.$2 - n.leftY).abs() < 0.01)) {
      straight.add(n.id);
    } else {
      candidates.add(n);
    }
  }
  candidates.sort((a, b) {
    final c = a.yMin.compareTo(b.yMin);
    if (c != 0) return c;
    final d = a.yMax.compareTo(b.yMax);
    return d != 0 ? d : a.id.compareTo(b.id);
  });

  final laneEnd = <double>[];
  final assigned = <int, int>{};
  final unrouted = <int>[];

  for (final net in candidates) {
    // 所有右端子都必须在右端、且左端在这些右端子左侧。
    var ok = net.leftX < net.rightBound - 2 * margin;
    for (final r in net.rights) {
      if (r.$1 <= net.leftX) ok = false;
    }
    if (!ok) {
      unrouted.add(net.id);
      continue;
    }
    var lane = -1;
    for (var i = 0; i < laneEnd.length; i++) {
      if (laneEnd[i] + gap <= net.yMin + 0.01) {
        lane = i;
        break;
      }
    }
    if (lane < 0) {
      if (laneEnd.length >= laneCount) {
        unrouted.add(net.id);
        continue;
      }
      lane = laneEnd.length;
      laneEnd.add(net.yMax);
    } else {
      laneEnd[lane] = net.yMax;
    }
    assigned[net.id] = lane;
  }

  final lanes = [
    for (var i = 0; i < laneEnd.length; i++) leftBound + i * pitch,
  ];
  final routes = <NlChannelWire>[];
  for (final net in candidates) {
    final lane = assigned[net.id];
    if (lane == null) continue;
    final x = lanes[lane];
    final yMin = net.yMin;
    final yMax = net.yMax;
    final rights = [...net.rights]..sort((a, b) => a.$2.compareTo(b.$2));
    final segments = <(double, double, double, double)>[
      (net.leftX, net.leftY, x, net.leftY),
      if ((yMax - yMin).abs() > 0.01) (x, yMin, x, yMax),
      for (final r in rights) (x, r.$2, r.$1, r.$2),
    ];
    routes.add(
      NlChannelWire(
        id: net.id,
        laneX: x,
        segments: segments,
        bends: 2,
        junctions: [
          if (net.leftY > yMin + 0.01 && net.leftY < yMax - 0.01)
            (x, net.leftY),
          for (final r in rights)
            if ((r.$2 - yMin).abs() > 0.01 &&
                (r.$2 - yMax).abs() > 0.01 &&
                (r.$2 - net.leftY).abs() > 0.01)
              (x, r.$2),
        ],
      ),
    );
  }
  for (final net in nets) {
    if (!straight.contains(net.id)) continue;
    final rights = [...net.rights]..sort((a, b) => a.$2.compareTo(b.$2));
    routes.add(
      NlChannelWire(
        id: net.id,
        laneX: net.leftX,
        segments: [for (final r in rights) (net.leftX, net.leftY, r.$1, r.$2)],
        bends: 0,
      ),
    );
  }
  routes.sort((a, b) => a.id.compareTo(b.id));

  // 同高水平段共线重叠检测（不同网、y 相同、x 区间相交）。
  final conflicts = <(int, int)>[];
  for (var i = 0; i < routes.length; i++) {
    for (var j = i + 1; j < routes.length; j++) {
      final a = routes[i];
      final b = routes[j];
      for (final sa in a.segments) {
        if ((sa.$2 - sa.$4).abs() > 0.01) continue; // 非水平
        for (final sb in b.segments) {
          if ((sb.$2 - sb.$4).abs() > 0.01) continue;
          if ((sa.$2 - sb.$2).abs() > 0.01) continue;
          final overlap =
              math.min(math.max(sa.$1, sa.$3), math.max(sb.$1, sb.$3)) -
              math.max(math.min(sa.$1, sa.$3), math.min(sb.$1, sb.$3));
          if (overlap > 0.01) conflicts.add((a.id, b.id));
        }
      }
    }
  }

  return NlChannelPlan(
    routes: routes,
    unrouted: unrouted,
    lanes: lanes,
    conflicts: conflicts,
  );
}
