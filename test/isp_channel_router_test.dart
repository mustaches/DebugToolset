// 单层通道布线内核测试：车道复用/溢出/同高直线/冲突/确定性。
import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/netlist_channel_router.dart';

NlChannelNet _net(int id, double leftY, double rightY) => NlChannelNet(
  id: id,
  leftX: 30,
  leftY: leftY,
  rightX: 180,
  rightY: rightY,
);

void main() {
  test('空输入', () {
    final plan = routeNlChannel(
      nets: const [],
      xMin: 0,
      xMax: 150,
    );
    expect(plan.routes, isEmpty);
    expect(plan.unrouted, isEmpty);
  });

  test('同高网走直线，不占车道', () {
    final plan = routeNlChannel(
      nets: [_net(1, 100, 100)],
      xMin: 0,
      xMax: 150,
    );
    final wire = plan.routes.single;
    expect(wire.bends, 0);
    expect(wire.segments, hasLength(1));
    expect(wire.segments.single, (30.0, 100.0, 180.0, 100.0));
    expect(plan.lanes, isEmpty);
  });

  test('纵向区间不重叠的网复用同一车道', () {
    final plan = routeNlChannel(
      nets: [_net(1, 100, 160), _net(2, 300, 360)],
      xMin: 0,
      xMax: 150,
      gap: 15,
    );
    expect(plan.unrouted, isEmpty);
    expect(plan.lanes, [45.0]);
    expect(
      plan.routes.map((w) => w.laneX).toSet(),
      {45.0},
    );
  });

  test('纵向区间重叠时开新车道', () {
    final plan = routeNlChannel(
      nets: [_net(1, 100, 300), _net(2, 150, 260)],
      xMin: 0,
      xMax: 150,
      gap: 15,
    );
    expect(plan.lanes, [45.0, 60.0]);
    expect(plan.routes.map((w) => w.laneX).toList(), [45.0, 60.0]);
  });

  test('区间之间不足 gap 也要开新车道', () {
    final plan = routeNlChannel(
      nets: [_net(1, 100, 200), _net(2, 205, 300)],
      xMin: 0,
      xMax: 150,
      gap: 15,
    );
    expect(plan.lanes, [45.0, 60.0]);
  });

  test('车道不足时超出部分标记未布通', () {
    // 通道 0..60，净宽 30 → 车道 15/30/45，最多 3 条。
    NlChannelNet narrow(int id) => NlChannelNet(
      id: id,
      leftX: 0,
      leftY: 100,
      rightX: 180,
      rightY: 300,
    );
    final nets = [for (var i = 0; i < 5; i++) narrow(i)];
    final plan = routeNlChannel(
      nets: nets,
      xMin: 0,
      xMax: 60,
      gap: 15,
    );
    expect(plan.lanes, hasLength(3));
    expect(plan.routes, hasLength(3));
    expect(plan.unrouted, hasLength(2));
    expect(plan.unrouted, [3, 4]);
  });

  test('同高水平段重叠被标记为冲突', () {
    final plan = routeNlChannel(
      nets: [_net(1, 100, 100), _net(2, 100, 100)],
      xMin: 0,
      xMax: 150,
    );
    expect(plan.conflicts, contains((1, 2)));
  });

  test('输入顺序不影响结果（确定性）', () {
    final a = routeNlChannel(
      nets: [_net(1, 100, 300), _net(2, 150, 260), _net(3, 500, 500)],
      xMin: 0,
      xMax: 150,
    );
    final b = routeNlChannel(
      nets: [_net(3, 500, 500), _net(2, 150, 260), _net(1, 100, 300)],
      xMin: 0,
      xMax: 150,
    );
    expect(a.lanes, b.lanes);
    expect(
      [for (final w in a.routes) (w.id, w.laneX, w.bends)],
      [for (final w in b.routes) (w.id, w.laneX, w.bends)],
    );
  });

  test('Z 形路径端点接住两侧端子，折弯为 2', () {
    final plan = routeNlChannel(
      nets: [_net(1, 100, 220)],
      xMin: 0,
      xMax: 150,
    );
    final w = plan.routes.single;
    expect(w.bends, 2);
    expect(w.segments, hasLength(3));
    expect(w.segments.first, (30.0, 100.0, 45.0, 100.0));
    expect(w.segments.last, (45.0, 220.0, 180.0, 220.0));
    // 竖直车道贯穿两端 y。
    expect(w.segments[1].$2, 100);
    expect(w.segments[1].$4, 220);
    expect(w.segments[1].$1, 45);
    expect(w.segments[1].$3, 45);
  });

  test('多负载：一条主干 + 各右端分支，左端分叉打点', () {
    final plan = routeNlChannel(
      nets: [
        NlChannelNet.multi(
          id: 1,
          leftX: 30,
          leftY: 100,
          rights: const [(180.0, 60.0), (180.0, 200.0)],
        ),
      ],
      xMin: 0,
      xMax: 150,
    );
    final w = plan.routes.single;
    expect(w.bends, 2);
    expect(w.segments, hasLength(4));
    expect(w.segments[0], (30.0, 100.0, 45.0, 100.0));
    expect(w.segments[1], (45.0, 60.0, 45.0, 200.0));
    expect(w.segments[2], (45.0, 60.0, 180.0, 60.0));
    expect(w.segments[3], (45.0, 200.0, 180.0, 200.0));
    // 左端 y=100 在主干内部 → T 型分支点。
    expect(w.junctions, [(45.0, 100.0)]);
  });

  test('多负载同高：各自直线，不占车道', () {
    final plan = routeNlChannel(
      nets: [
        NlChannelNet.multi(
          id: 1,
          leftX: 30,
          leftY: 100,
          rights: const [(180.0, 100.0), (180.0, 100.0)],
        ),
      ],
      xMin: 0,
      xMax: 150,
    );
    final w = plan.routes.single;
    expect(w.bends, 0);
    expect(w.segments, hasLength(2));
    expect(plan.lanes, isEmpty);
  });

  test('端点方向相反（左端在右端右侧）直接未布通', () {
    final plan = routeNlChannel(
      nets: [
        NlChannelNet(id: 9, leftX: 200, leftY: 100, rightX: 100, rightY: 300),
      ],
      xMin: 0,
      xMax: 300,
    );
    expect(plan.unrouted, [9]);
  });
}
