// ε-字典序布线目标测试：硬闸门/容差换档/长尾折弯/绕行/平行/密度/长度。
import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_route_objective.dart';

NlRouteScore _score({
  bool legal = true,
  int crossings = 100,
  int bends = 150,
  double p95 = 9,
  double length = 40000,
  double hpwl = 35000,
  int parallel = 80,
  double density = 0.7,
  double portDy = 0,
}) => NlRouteScore(
  legal: legal,
  crossings: crossings,
  bends: bends,
  bendP95: p95,
  length: length,
  hpwl: hpwl,
  parallelPairs: parallel,
  densityPeak: density,
  portAlignMeanDy: portDy,
);

void main() {
  test('硬约束永远优先于任何指标', () {
    final illegal = _score(legal: false, crossings: 0, bends: 0, length: 1);
    final legal = _score(crossings: 9999, bends: 9999, length: 99999);
    expect(compareNlRouteScores(legal, illegal), lessThan(0));
    expect(compareNlRouteScores(illegal, legal), greaterThan(0));
  });

  test('交叉多 1 在容差内，折弯少 3 的候选胜出', () {
    final a = _score(crossings: 100, bends: 160);
    final b = _score(crossings: 99, bends: 150);
    // 交叉差 1 ≤ ε(1)，进入折弯级：b 少 10 弯。
    expect(compareNlRouteScores(b, a), lessThan(0));
  });

  test('交叉多 2 超出容差，即使折弯少 20 也输', () {
    final a = _score(crossings: 100, bends: 180);
    final b = _score(crossings: 98, bends: 160);
    expect(compareNlRouteScores(b, a), lessThan(0));
    expect(
      compareNlRouteScores(_score(crossings: 102, bends: 100), a),
      greaterThan(0),
    );
  });

  test('先比单网 P95 折弯，再比总折弯', () {
    final longTail = _score(crossings: 100, bends: 120, p95: 12);
    final tidy = _score(crossings: 100, bends: 160, p95: 8);
    // 总折弯更少但长尾更差：P95 优先，tidy 胜。
    expect(compareNlRouteScores(tidy, longTail), lessThan(0));
  });

  test('P95 在容差内时由总折弯决胜', () {
    final a = _score(p95: 9.0, bends: 160);
    final b = _score(p95: 8.5, bends: 150);
    expect(compareNlRouteScores(b, a), lessThan(0));
  });

  test('绕行比超出容差时决胜', () {
    final direct = _score(length: 38500, hpwl: 35000); // 1.100
    final detour = _score(length: 40250, hpwl: 35000); // 1.150
    expect(compareNlRouteScores(direct, detour), lessThan(0));
  });

  test('平行段在容差内时由密度决胜', () {
    final sparse = _score(parallel: 81, density: 0.60);
    final dense = _score(parallel: 80, density: 0.70);
    expect(compareNlRouteScores(sparse, dense), lessThan(0));
  });

  test('全指标一致返回 0，且比较反对称', () {
    final a = _score();
    final b = _score();
    expect(compareNlRouteScores(a, b), 0);
    final c = _score(crossings: 120);
    expect(
      compareNlRouteScores(a, c),
      -compareNlRouteScores(c, a),
    );
  });

  test('严格字典序（ε=0）下 +1 交叉即使少 10 弯也输', () {
    final fewerCross = _score(crossings: 99, bends: 160);
    final fewerBends = _score(crossings: 100, bends: 150);
    expect(
      compareNlRouteScores(
        fewerBends,
        fewerCross,
        config: NlObjectiveConfig.strict,
      ),
      greaterThan(0),
    );
  });

  test('单点网绕行比为 1', () {
    final s = _score(length: 100, hpwl: 0);
    expect(s.detour, 1.0);
  });
}
