import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/codegen/ip_gen_config.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/ip_target.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/vivado_parts.dart';
import 'package:debug_tool_set/modules/isp_studio/codegen/vivado_runner.dart';
import 'package:debug_tool_set/modules/isp_studio/widgets/vivado_part_picker.dart';

void main() {
  const options = IpGenOptions(
    vendor: IpVendor.vivado,
    series: VivadoSeries.zynqUltrascalePlus,
    targetPart: 'xczu15eg-ffvb1156-2-i',
    targetFamily: 'zynquplus',
    vivadoExecutable: r'D:\AMDDesignTools\2026.1\Vivado\bin\vivado.bat',
    vinType: 'none',
    pixBits: 12,
    maxWidth: 3840,
    gstrategy: 0,
    fold: 4,
    dspPipe: 2,
    yuvStandard: 'bt709',
    projectName: 'ycbcr_equalizer_demo',
  );
  const filters = VivadoPartFilters(
    category: 'General Purpose',
    family: 'Zynq UltraScale+',
    package: 'ffvb1156',
    speed: '-2',
    temperature: 'I',
    staticPower: 'S',
    search: 'xczu15',
  );

  test('配置完整 JSON 往返', () {
    final restored = decodeIpGenConfig(
      encodeIpGenConfig(const IpGenConfig(options: options, filters: filters)),
    );
    expect(restored.options.vendor, options.vendor);
    expect(restored.options.series, options.series);
    expect(restored.options.targetPart, options.targetPart);
    expect(restored.options.targetFamily, options.targetFamily);
    expect(restored.options.vivadoExecutable, options.vivadoExecutable);
    expect(restored.options.vinType, options.vinType);
    expect(restored.options.pixBits, options.pixBits);
    expect(restored.options.maxWidth, options.maxWidth);
    expect(restored.options.gstrategy, options.gstrategy);
    expect(restored.options.fold, options.fold);
    expect(restored.options.dspPipe, options.dspPipe);
    expect(restored.options.yuvStandard, options.yuvStandard);
    expect(restored.options.projectName, options.projectName);
    expect(restored.filters.category, filters.category);
    expect(restored.filters.family, filters.family);
    expect(restored.filters.package, filters.package);
    expect(restored.filters.speed, filters.speed);
    expect(restored.filters.temperature, filters.temperature);
    expect(restored.filters.staticPower, filters.staticPower);
    expect(restored.filters.search, filters.search);
  });

  test('错误版本、未知枚举与非法参数按约定处理', () {
    expect(() => decodeIpGenConfig('[]'), throwsFormatException);
    expect(() => decodeIpGenConfig('{"version":99}'), throwsFormatException);
    final restored = decodeIpGenConfig(
      '{"version":1,"vendor":"quartus","series":"unknown","pixBits":7,"maxWidth":123,"gstrategy":9,"fold":8,"dspPipe":-1}',
      requireVivado: true,
    );
    expect(restored.options.vendor, IpVendor.vivado);
    expect(restored.options.series, VivadoSeries.zynqUltrascalePlus);
    expect(restored.options.pixBits, 0);
    expect(restored.options.maxWidth, 3840);
    expect(restored.options.gstrategy, 2);
    expect(restored.options.fold, 2);
    expect(restored.options.dspPipe, 3);
    expect(restored.options.yuvStandard, 'auto');
  });

  test('ipcfg/prjcfg 实写读、后缀补全与默认目录', () async {
    final dir = await Directory.systemTemp.createTemp('ip_config_io_');
    try {
      for (final extension in ['ipcfg', 'prjcfg']) {
        final path = await saveIpGenConfigFile(
          const IpGenConfig(options: options, filters: filters),
          '${dir.path}${Platform.pathSeparator}config',
          extension,
        );
        expect(path, endsWith('config.$extension'));
        final restored = await readIpGenConfigFile(path, requireVivado: true);
        expect(restored.options.targetPart, options.targetPart);
        expect(restored.filters.search, filters.search);
        expect(ipConfigDirectory(extension).path, contains('export_config'));
        expect(ipConfigDirectory(extension).path, endsWith(extension));
      }
      expect(ensureIpConfigExtension('a.IPCFG', 'ipcfg'), 'a.IPCFG');
      expect(ensureIpConfigExtension('a', 'prjcfg'), 'a.prjcfg');
    } finally {
      await dir.delete(recursive: true);
    }
  });

  testWidgets('picker 恢复筛选不被默认值覆盖并回调 Reset', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const defaultPart = VivadoPart(
      name: 'xczu15eg-ffvb1156-2-i',
      category: 'General Purpose',
      family: 'zynquplus',
      familyDisplay: 'Zynq UltraScale+',
      package: 'ffvb1156',
      speed: '-2',
      temperature: 'I',
      staticPower: 'S',
    );
    const automotivePart = VivadoPart(
      name: 'xazu3eg-sfvc784-1-i',
      category: 'Automotive',
      family: 'zynquplus',
      familyDisplay: 'Zynq UltraScale+',
      package: 'sfvc784',
      speed: '-1',
      temperature: 'I',
      staticPower: 'S',
    );
    late VivadoPartFilters changed;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 1000,
            height: 700,
            child: VivadoPartPicker(
              toolchain: const VivadoToolchain('fake-vivado'),
              initialPart: defaultPart.name,
              initialFilters: const VivadoPartFilters(
                category: 'Automotive',
                search: 'xaz',
              ),
              onFiltersChanged: (value) => changed = value,
              onSelected: (_) {},
              parts: const [defaultPart, automotivePart],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('1 / 2 个器件'), findsOneWidget);
    expect(changed.category, 'Automotive');
    expect(changed.search, 'xaz');
    await tester.tap(find.text('Reset All Filters'));
    await tester.pumpAndSettle();
    expect(find.text('2 / 2 个器件'), findsOneWidget);
    expect(changed.category, '');
    expect(changed.search, '');
  });
}
