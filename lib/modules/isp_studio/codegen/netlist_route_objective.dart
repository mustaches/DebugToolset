/// 布线质量目标函数（纯 Dart、确定性、无 Flutter 依赖）。
///
/// 采用 **ε-字典序**：高优先级指标差距超过容差才一票否决，否则交给下一级。
/// 这避免严格字典序的两个极端：
/// - 为少 1 个交叉而把折弯从 4 涨到 40（路径畸形）；
/// - 为少 2 个折弯而接受明显更多的交叉。
///
/// 层级（高 → 低）：
/// 1. **硬约束**：合法（无穿块/重叠/间距/断口/越界）永远优先；
/// 2. 交叉数（ε 默认 1）；
/// 3. 单网折弯 P95（ε 默认 1）——先压长尾，而不是只看总数；
/// 4. 折弯总数（ε 默认 2）；
/// 5. 绕行比（ε 默认 0.02）；
/// 6. 平行贴近段（ε 默认 2）；
/// 7. 密度峰值（ε 默认 0.02）；
/// 8. 端口最近一跳偏差均值（ε 默认 2px）；
/// 9. 长度（最后一档，ε 0）。
///
/// 每级都只回答“谁更好”；全部落在容差内返回 0（调用方保留先到者），
/// 因此同一组候选无论评估顺序如何，胜者一致（平局由调用方稳定顺序决定）。
library;

import 'netlist_routing_metrics.dart';

/// 布线候选的标量摘要（由诊断报告归一化而来）。
class NlRouteScore {
  final bool legal;
  final int crossings;
  final int bends;
  final double bendP95;
  final double length;
  final double hpwl;

  /// 异网平行贴近段对数。
  final int parallelPairs;

  /// 密度峰值（0..1）。
  final double densityPeak;

  /// 端口最近一跳偏差均值（px）。
  final double portAlignMeanDy;

  const NlRouteScore({
    required this.legal,
    required this.crossings,
    required this.bends,
    required this.bendP95,
    required this.length,
    required this.hpwl,
    required this.parallelPairs,
    required this.densityPeak,
    required this.portAlignMeanDy,
  });

  /// 绕行比；无 HPWL（单点/空网）时为 1。
  double get detour => hpwl > 0.01 ? length / hpwl : 1.0;

  /// 从诊断报告构造（路由结果的标准入口）。
  factory NlRouteScore.fromDiagnostics(NlRoutingDiagnostics d) => NlRouteScore(
    legal: d.legal,
    crossings: d.crossings,
    bends: d.bends,
    bendP95: d.bendP95,
    length: d.length,
    hpwl: d.hpwl,
    parallelPairs: d.parallelPairs,
    densityPeak: d.densityPeak,
    portAlignMeanDy: d.portAlignMeanDy,
  );
}

/// ε-字典序容差。
class NlObjectiveConfig {
  final double epsilonCrossings;
  final double epsilonBendP95;
  final double epsilonBends;
  final double epsilonDetour;
  final double epsilonParallel;
  final double epsilonDensity;
  final double epsilonPortDy;

  const NlObjectiveConfig({
    this.epsilonCrossings = 1,
    this.epsilonBendP95 = 1,
    this.epsilonBends = 2,
    this.epsilonDetour = 0.02,
    this.epsilonParallel = 2,
    this.epsilonDensity = 0.02,
    this.epsilonPortDy = 2,
  });

  /// 严格字典序（ε 全 0），用于回归对照。
  static const strict = NlObjectiveConfig(
    epsilonCrossings: 0,
    epsilonBendP95: 0,
    epsilonBends: 0,
    epsilonDetour: 0,
    epsilonParallel: 0,
    epsilonDensity: 0,
    epsilonPortDy: 0,
  );
}

/// 比较两个候选：负数 = a 更好，正数 = b 更好，0 = 容差内等价。
int compareNlRouteScores(
  NlRouteScore a,
  NlRouteScore b, {
  NlObjectiveConfig config = const NlObjectiveConfig(),
}) {
  if (a.legal != b.legal) return a.legal ? -1 : 1;

  int cmp(double x, double y, double eps) {
    final d = x - y;
    if (d.abs() <= eps) return 0;
    return d < 0 ? -1 : 1;
  }

  var r = cmp(
    a.crossings.toDouble(),
    b.crossings.toDouble(),
    config.epsilonCrossings,
  );
  if (r != 0) return r;

  r = cmp(a.bendP95, b.bendP95, config.epsilonBendP95);
  if (r != 0) return r;

  r = cmp(a.bends.toDouble(), b.bends.toDouble(), config.epsilonBends);
  if (r != 0) return r;

  r = cmp(a.detour, b.detour, config.epsilonDetour);
  if (r != 0) return r;

  r = cmp(
    a.parallelPairs.toDouble(),
    b.parallelPairs.toDouble(),
    config.epsilonParallel,
  );
  if (r != 0) return r;

  r = cmp(a.densityPeak, b.densityPeak, config.epsilonDensity);
  if (r != 0) return r;

  r = cmp(a.portAlignMeanDy, b.portAlignMeanDy, config.epsilonPortDy);
  if (r != 0) return r;

  r = cmp(a.length, b.length, 0);
  if (r != 0) return r;
  return 0;
}

/// 两个候选是否在容差内等价。
bool nlRouteScoresEquivalent(
  NlRouteScore a,
  NlRouteScore b, {
  NlObjectiveConfig config = const NlObjectiveConfig(),
}) => compareNlRouteScores(a, b, config: config) == 0;
