// 对照：原生 SubmenuButton 按开的菜单，外部点击是否关闭。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('stock submenu button outside tap closes', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              SubmenuButton(
                menuChildren: [
                  MenuItemButton(onPressed: null, child: Text('item-a')),
                ],
                child: Text('open-menu'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.text('open-menu'));
    await tester.pumpAndSettle();
    expect(find.text('item-a'), findsOneWidget);

    await tester.tapAt(const Offset(50, 550));
    await tester.pumpAndSettle();
    expect(find.text('item-a'), findsNothing, reason: '外部点击后菜单应关闭');
  });
}
