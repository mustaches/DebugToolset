// 复现：MenuAnchor 经 Listener 右键 open(position:) 后，外部点击是否关闭。
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('probe tap region dispatch', (tester) async {
    final controller = MenuController();
    var probeOutside = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              TapRegion(
                onTapOutside: (_) => probeOutside++,
                child: Container(width: 100, height: 50, color: Colors.red),
              ),
              Expanded(
                child: Stack(
                  children: [
                    Listener(
                      behavior: HitTestBehavior.translucent,
                      onPointerDown: (e) {
                        if (e.buttons == kSecondaryButton) {
                          controller.open(position: e.localPosition);
                        }
                      },
                      child: Container(color: Colors.black),
                    ),
                    Positioned(
                      left: 0,
                      top: 0,
                      child: MenuAnchor(
                        controller: controller,
                        menuChildren: [
                          MenuItemButton(
                            onPressed: () {},
                            child: const Text('item-a'),
                          ),
                        ],
                        child: const SizedBox(width: 1, height: 1),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    // 右键按下打开菜单
    final g = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryButton,
    );
    await g.down(const Offset(400, 300));
    await tester.pumpAndSettle();
    expect(find.text('item-a'), findsOneWidget);
    // ignore: avoid_print
    print('menu open: isOpen=${controller.isOpen}');

    // 外部左键点击（远离菜单位置）
    await tester.tapAt(const Offset(50, 550));
    await tester.pumpAndSettle();
    // ignore: avoid_print
    print('probeOutside=$probeOutside, isOpen=${controller.isOpen}');

    // 手动 close 验证关闭路径本身是否有效
    controller.close();
    await tester.pumpAndSettle();
    // ignore: avoid_print
    print('after manual close: isOpen=${controller.isOpen}');

    expect(find.text('item-a'), findsNothing, reason: '外部点击后菜单应关闭');
  });
}
