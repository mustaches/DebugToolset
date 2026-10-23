// 一次性脚本：用当前 stubMainWinSource 重新生成验证程序 main_win.c
// （lut_fixed 单节点黑盒形态：hsl 进 hsl 出、无 scratch、MAXV=255）。
import 'dart:io';

import 'package:debug_tool_set/modules/isp_studio/codegen/c_compile.dart';

void main() {
  final src = stubMainWinSource(
      topName: 'isp_pipe_multi_band_eq_bb',
      inFormat: 'hsl',
      outFormat: 'hsl',
      hasScratch: false,
      maxValue: 255);
  File('scratch/cc_win_check_1790780476218/main_win.c')
      .writeAsStringSync(src);
  stdout.writeln('main_win.c regenerated: ${src.length} chars');
}
