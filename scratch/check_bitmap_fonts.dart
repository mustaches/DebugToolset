import 'dart:io';

import 'package:debug_tool_set/modules/font_extractor/utils/font_info.dart';

Future<void> main() async {
  final cases = {
    r'C:\Windows\Fonts\simsun.ttc': true, // 宋体内嵌点阵
    r'C:\Windows\Fonts\msyh.ttc': false, // 微软雅黑无点阵
    r'C:\Windows\Fonts\arial.ttf': false,
    r'C:\Windows\Fonts\seguiemj.ttf': false, // COLR 矢量分层，非点阵
  };
  for (final e in cases.entries) {
    final has = await fontHasEmbeddedBitmap(e.key);
    final ok = has == e.value ? 'OK' : 'MISMATCH';
    stdout.writeln('$ok  ${e.key} -> $has (expect ${e.value})');
  }
}
