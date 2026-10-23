// 一次性：用真实 wave_sample.vcd 验证 vcd_parser。
import 'dart:io';

import 'package:debug_tool_set/modules/isp_studio/codegen/vcd_parser.dart';

void main() {
  final text = File('scratch/wave_sample.vcd').readAsStringSync();
  final sw = Stopwatch()..start();
  final vcd = parseVcd(text);
  print('parse: ${sw.elapsedMilliseconds}ms, signals=${vcd.signals.length}, '
      'timescale=${vcd.timescalePs}ps, endTime=${vcd.endTime}');
  final tops = vcd.topScopeSignals();
  print('top signals: ${tops.map((s) => '${s.name}(id=${s.id},w=${s.width},chg=${s.changes.length})').join(' ')}');
  final clk = tops.firstWhere((s) => s.name == 'clk');
  print('clk first changes: ${clk.changes.take(8).map((c) => '${c.time}:${c.bits}').join(' ')}');
  final inData = tops.firstWhere((s) => s.name == 'in_data');
  print('in_data chg=${inData.changes.length}, first: '
      '${inData.changes.take(5).map((c) => '${c.time}:${bitsToHex(c.bits)}').join(' ')}');
  final outValid = tops.firstWhere((s) => s.name == 'out_valid');
  print('out_valid first: ${outValid.changes.take(6).map((c) => '${c.time}:${c.bits}').join(' ')}');
  for (final n in ['in_ready','out_ready','rst_n','in_valid']) {
    final s = tops.firstWhere((x) => x.name == n);
    print('$n: ${s.changes.take(4).map((c) => '${c.time}:${c.bits}').join(' ')}');
  }
}
