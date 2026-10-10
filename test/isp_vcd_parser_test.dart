import 'package:debug_tool_set/modules/isp_studio/codegen/vcd_parser.dart';
import 'package:flutter_test/flutter_test.dart';

const _sample = '''
\$date
	test
\$end
\$timescale
	1ps
\$end
\$scope module tb_dut \$end
\$var wire 1 ! out_valid \$end
\$var reg 1 + clk \$end
\$var reg 8 - in_data [7:0] \$end
\$var parameter 32 & EXPECTED_HASH \$end
\$scope module dut \$end
\$var wire 1 ! out_valid \$end
\$upscope \$end
\$upscope \$end
\$enddefinitions \$end
#0
0+
x!
b00000000 -
b10101010 &
#5
1+
#10
0+
1!
b00000001 -
#15
1+
''';

void main() {
  test('解析声明层级与值变化', () {
    final vcd = parseVcd(_sample);
    expect(vcd.timescalePs, 1);
    expect(vcd.endTime, 15);

    final clk = vcd.signals.firstWhere((s) => s.name == 'clk');
    expect(clk.path, 'tb_dut.clk');
    expect(clk.width, 1);
    expect(clk.changes.map((c) => '${c.time}:${c.bits}').toList(),
        ['0:0', '5:1', '10:0', '15:1']);

    final bus = vcd.signals.firstWhere((s) => s.name == 'in_data');
    expect(bus.isBus, isTrue);
    expect(bus.width, 8);
    expect(bus.changes.last.bits, '00000001');

    // dut 子层级信号路径（同一 id 在多层级声明为别名，变化共享）
    final nested = vcd.signals.firstWhere(
        (s) => s.name == 'out_valid' && s.path.split('.').length == 3);
    expect(nested.path, 'tb_dut.dut.out_valid');
    expect(nested.changes.length, 2); // 别名共享 id `!` 的值变化（x→1）
    final topValid = vcd.signals.firstWhere((s) => s.path == 'tb_dut.out_valid');
    expect(topValid.changes.length, 2);
  });

  test('topScopeSignals 只含顶层非 parameter 信号', () {
    final vcd = parseVcd(_sample);
    final tops = vcd.topScopeSignals();
    expect(tops.map((s) => s.name).toList(),
        ['out_valid', 'clk', 'in_data']);
  });

  test('valueAt 按时间取值', () {
    final vcd = parseVcd(_sample);
    final clk = vcd.signals.firstWhere((s) => s.name == 'clk');
    expect(valueAt(clk, 0), '0');
    expect(valueAt(clk, 6), '1');
    expect(valueAt(clk, 14), '0');
    final bus = vcd.signals.firstWhere((s) => s.name == 'in_data');
    expect(valueAt(bus, 12), '00000001');
  });

  test('scope 层级树', () {
    final vcd = parseVcd(_sample);
    expect(vcd.root.children.single.name, 'tb_dut');
    final tb = vcd.root.children.single;
    expect(tb.children.single.name, 'dut');
    expect(tb.children.single.path, 'tb_dut.dut');
    // 顶层信号挂在 tb scope，子模块信号挂在 dut scope
    expect(tb.signals.map((s) => s.name), contains('clk'));
    expect(tb.children.single.signals.single.name, 'out_valid');
  });

  test('bitsToHex 常规与含 x/z', () {
    expect(bitsToHex('00000001'), '01');
    expect(bitsToHex('10101010'), 'aa');
    expect(bitsToHex('10x0'), 'x');
    expect(bitsToHex('0x1x'), 'x');
    expect(bitsToHex('zzzz'), 'z');
  });
}
