// 多段色彩均衡器（multi_band_eq）测试：节点注册、多段 LUT 合成数学
// （并联求和/串联级联/单段退化/色环环绕/恒等段）与 pipeline_runner 集成。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/models/isp_node.dart';
import 'package:debug_tool_set/modules/isp_studio/models/multi_band_eq_params.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/hsl_band_pool.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/isp_kernels.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/pipeline_runner.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const max = 360; // H 域 0..360，hDeg == hv，便于手算验证

  ({double h, double q, double dh, double s, double l}) band(
          double h, double q, double dh,
          [double s = 1.0, double l = 1.0]) =>
      (h: h, q: q, dh: dh, s: s, l: l);

  void expectLutsEqual(
      (Int32List, Float64List, Float64List) a,
      (Int32List, Float64List, Float64List) b) {
    expect(a.$1, equals(b.$1), reason: 'shift LUT');
    expect(a.$2, equals(b.$2), reason: 'sMul LUT');
    expect(a.$3, equals(b.$3), reason: 'lMul LUT');
  }

  group('节点注册', () {
    test('multi_band_eq 注册：显示名/HSL 端口/固定参数 spec/bypass 注入', () {
      final type = IspNodeRegistry.byId('multi_band_eq')!;
      expect(type.displayName, '多段色彩均衡器');
      expect(type.inputs.single.type, IspPortType.hsl);
      expect(type.outputs.single.type, IspPortType.hsl);
      // bypass 由 processTypeIds 注入到首位。
      expect(type.params.first.key, 'bypass');
      // 段参数 b{i}_* 不进 spec，仅登记固定参数（codegenMode 供 C 导出
      // 选择直算/烘焙 LUT，与色彩控制器同义）。
      expect(type.params.map((p) => p.key).toList(),
          ['bypass', 'band_count', 'band_mode', 'sel_band', 'codegenMode']);
      expect(type.params[1].defaultValue, 1);
      expect(type.params[1].min, 1);
      expect(type.params[1].max, 24);
      expect(type.params[2].defaultValue, 'parallel');
      expect(type.params[2].options, ['parallel', 'serial']);
      expect(type.params[3].defaultValue, 0);
    });

    test('IspNode.create 默认值：宽度与色彩控制器一致，高度更大', () {
      final node = IspNode.create(IspNodeRegistry.byId('multi_band_eq')!,
          'mb', 0, 0);
      final cc = IspNode.create(IspNodeRegistry.byId('color_controller')!,
          'cc', 0, 0);
      expect(node.width, cc.width);
      expect(node.extraHeight, greaterThan(cc.extraHeight));
      expect(node.paramValues['band_count'], 1);
      expect(node.paramValues['band_mode'], 'parallel');
      expect(node.paramValues['sel_band'], 0);
      expect(node.paramValues['bypass'], false);
    });
  });

  group('色彩风格名标注（标题栏「（文件名）」）', () {
    test('读取预设写入 style_name；配置调整清除，切换选中段保留', () {
      final state = IspStudioState.empty();
      final id = state.graph.addNode('multi_band_eq', 0, 0);
      final node = state.graph.nodes[id]!;

      state.setParam(id, 'style_name', 'a.colorstyle');
      expect(node.paramValues['style_name'], 'a.colorstyle');
      // 切换选中段不清除。
      state.setParam(id, 'sel_band', 0);
      expect(node.paramValues['style_name'], 'a.colorstyle');
      // 调整段参数即清除。
      state.setParam(id, 'b0_h', 120.0);
      expect(node.paramValues.containsKey('style_name'), isFalse);

      // 批量写含配置键同样清除。
      state.setParam(id, 'style_name', 'b.colorstyle');
      state.setParams(id, {'b0_q': 3.0});
      expect(node.paramValues.containsKey('style_name'), isFalse);

      // 批量写自带 style_name（预设读取路径）时保留新名字。
      state.setParams(id, {'b0_h': 10.0, 'style_name': 'c.colorstyle'});
      expect(node.paramValues['style_name'], 'c.colorstyle');
    });
  });

  group('LUT 合成数学', () {
    test('单段并联/串联均与色彩控制器 hslBandLuts 逐位一致', () {
      final ref = hslBandLuts(
          maxValue: max,
          hCenterDeg: 120,
          q: 3.0,
          hShiftDeg: -45,
          sGain: 1.5,
          lGain: 0.8);
      expectLutsEqual(
          multiBandLuts([band(120, 3.0, -45, 1.5, 0.8)],
              serial: false, maxValue: max),
          ref);
      expectLutsEqual(
          multiBandLuts([band(120, 3.0, -45, 1.5, 0.8)],
              serial: true, maxValue: max),
          ref);
    });

    test('空段合成恒等 LUT（两种模式）', () {
      for (final serial in [false, true]) {
        final (shift, sMul, lMul) =
            multiBandLuts(const [], serial: serial, maxValue: max);
        for (var hv = 0; hv <= max; hv++) {
          expect(shift[hv], 0, reason: 'serial=$serial hv=$hv');
          expect(sMul[hv], 1.0, reason: 'serial=$serial hv=$hv');
          expect(lMul[hv], 1.0, reason: 'serial=$serial hv=$hv');
        }
      }
    });

    test('全恒等段合成恒等 LUT（两种模式）', () {
      final bands = [band(30, 2.0, 0), band(200, 5.0, 0)];
      for (final serial in [false, true]) {
        final (shift, sMul, lMul) =
            multiBandLuts(bands, serial: serial, maxValue: max);
        for (var hv = 0; hv <= max; hv++) {
          expect(shift[hv], 0, reason: 'serial=$serial hv=$hv');
          expect(sMul[hv], 1.0, reason: 'serial=$serial hv=$hv');
          expect(lMul[hv], 1.0, reason: 'serial=$serial hv=$hv');
        }
      }
    });

    test('并联：恒等段不改变合成结果（与单段逐位一致）', () {
      // 恒等段权重项全为 0（dh=0、s/l=1），加权求和不受影响。
      final two = multiBandLuts(
          [band(120, 3.0, -45, 1.5, 0.8), band(300, 8.0, 0)],
          serial: false, maxValue: max);
      final one = hslBandLuts(
          maxValue: max,
          hCenterDeg: 120,
          q: 3.0,
          hShiftDeg: -45,
          sGain: 1.5,
          lGain: 0.8);
      expectLutsEqual(two, one);
    });

    test('并联：同中心两段 ΔH 加权求和、S/L 按 1+Σw·(g−1) 合成', () {
      // 中心 180°、w=1 处：dh 30+30=60，sMul=1+2·(2−1)=3，lMul=1+2·(1.5−1)=2。
      final (shift, sMul, lMul) = multiBandLuts(
          [band(180, 2.0, 30, 2.0, 1.5), band(180, 2.0, 30, 2.0, 1.5)],
          serial: false, maxValue: max);
      expect(shift[180], 60);
      expect(sMul[180], 3.0);
      expect(lMul[180], 2.0);
    });

    test('并联：合成量钳位（ΔH ±180°、乘子 0..5）', () {
      // 中心 0° 处 w=1：dh 180+180=360 → 钳位 180；s 5+5 → 1+2·4=9 → 钳位 5。
      final (shift, sMul, lMul) = multiBandLuts(
          [band(0, 2.0, 180, 5.0, 5.0), band(0, 2.0, 180, 5.0, 5.0)],
          serial: false, maxValue: max);
      expect(shift[0], 180);
      expect(sMul[0], 5.0);
      expect(lMul[0], 5.0);
      // s=0 两段：1+2·(0−1)=−1 → 钳位 0。
      final (_, sMul0, _) = multiBandLuts(
          [band(0, 2.0, 0, 0.0), band(0, 2.0, 0, 0.0)],
          serial: false, maxValue: max);
      expect(sMul0[0], 0.0);
    });

    test('串联：后段在前段更新后的色相上取权重（级联）', () {
      // hv=0：段0（中心0,q=2,dh=90）w=1 → H₁=90；段1（中心90,q=2,s=2）
      // 在 H₁=90 处 w=1 → H₂=180，sMul=2。并联则在原 H=0 上取段1 权重
      // e^-8≈0，ΔH≈90.03 → shift=90。
      final bands = [band(0, 2.0, 90), band(90, 2.0, 90, 2.0)];
      final (serShift, serSMul, _) =
          multiBandLuts(bands, serial: true, maxValue: max);
      expect(serShift[0], 180);
      expect(serSMul[0], 2.0);
      final (parShift, parSMul, _) =
          multiBandLuts(bands, serial: false, maxValue: max);
      expect(parShift[0], 90);
      expect(parSMul[0], closeTo(1.0, 1e-3));
    });

    test('串联：段序交换结果不同（顺序依赖）', () {
      // 段序 [B90, B0] 时 hv=0 先几乎不动（w=e^-8），再经 B0 移到 ~90°。
      final fwd = multiBandLuts([band(0, 2.0, 90), band(90, 2.0, 90)],
          serial: true, maxValue: max);
      final rev = multiBandLuts([band(90, 2.0, 90), band(0, 2.0, 90)],
          serial: true, maxValue: max);
      expect(fwd.$1[0], 180);
      expect(rev.$1[0], 90);
    });

    test('串联：色环环绕（±方向最短路径）', () {
      final identity = band(100, 2.0, 0); // 恒等段，只为进入串联迭代路径
      // hv=5，段中心 350°、dh=−60：d=15°，w=e^{−0.5·(15/22.5)²}≈0.8007，
      // H₁=5−48.04=−43.04 → 模 360 得 316.96；首尾差 311.96° 取最短路径
      // −48.04° → shift=−48。
      final neg = multiBandLuts([band(350, 2.0, -60), identity],
          serial: true, maxValue: max);
      expect(neg.$1[5], -48);
      // hv=355，段中心 10°、dh=+60：对称情形，H₁=355+48.04=403.04 →
      // 模 360 得 43.04；首尾差 −311.96° 取最短路径 +48.04° → shift=48。
      final pos = multiBandLuts([band(10, 2.0, 60), identity],
          serial: true, maxValue: max);
      expect(pos.$1[355], 48);
    });
  });

  group('段重排（reindexBandParams）', () {
    /// 构造 bandCount 段全键参数：b{i}_h = 10·i，其余键按后缀区分。
    Map<String, Object?> fullParams(int count,
            {int selBand = 0, String mode = 'parallel'}) =>
        {
          'band_count': count,
          'band_mode': mode,
          'sel_band': selBand,
          for (var i = 0; i < count; i++) ...{
            'b${i}_h': 10.0 * i,
            'b${i}_q': 2.0 + i,
            'b${i}_dh': -5.0 * i,
            'b${i}_s': 1.0 + i,
            'b${i}_l': 1.0 + 0.5 * i,
          },
        };

    test('删首段：后续段键前移，末段残留清除', () {
      final next = reindexBandParams(fullParams(3, selBand: 2), 0, 3);
      expect(next['band_count'], 2);
      // b0 ← 原 b1，b1 ← 原 b2。
      expect(next['b0_h'], 10.0);
      expect(next['b1_q'], 4.0);
      expect(next['b1_l'], 2.0);
      // 原 b2 键全部清除（无残留）。
      for (final s in kMultiBandEqBandSuffixes) {
        expect(next.containsKey('b2_$s'), isFalse, reason: 'b2_$s');
      }
      // 删除选中段之前的段：sel_band 减一。
      expect(next['sel_band'], 1);
      // 无关键不受影响。
      expect(next['band_mode'], 'parallel');
    });

    test('删中段：只前移其后的段', () {
      final next = reindexBandParams(fullParams(3), 1, 3);
      expect(next['b0_h'], 0.0); // b0 不变
      expect(next['b1_h'], 20.0); // b1 ← 原 b2
      expect(next.containsKey('b2_h'), isFalse);
      expect(next['sel_band'], 0);
    });

    test('删尾段：其余段原样，仅清尾段键', () {
      final next = reindexBandParams(fullParams(3), 2, 3);
      expect(next['b0_h'], 0.0);
      expect(next['b1_h'], 10.0);
      for (final s in kMultiBandEqBandSuffixes) {
        expect(next.containsKey('b2_$s'), isFalse, reason: 'b2_$s');
      }
      expect(next['band_count'], 2);
    });

    test('删除选中段：sel_band 回退 0', () {
      final next = reindexBandParams(fullParams(3, selBand: 1), 1, 3);
      expect(next['sel_band'], 0);
    });

    test('缺键段前移时目标键移除（保持缺键=恒等默认语义）', () {
      final params = fullParams(2)
        ..remove('b1_h')
        ..remove('b1_s');
      final next = reindexBandParams(params, 0, 2);
      expect(next.containsKey('b0_h'), isFalse);
      expect(next.containsKey('b0_s'), isFalse);
      expect(next['b0_q'], 3.0); // b1_q 前移
      expect(next['band_count'], 1);
    });

    test('不改入参映射', () {
      final params = fullParams(3);
      final before = Map<String, Object?>.of(params);
      reindexBandParams(params, 1, 3);
      expect(params, before);
    });
  });

  group('预设序列化（.colorstyle）', () {
    test('encode/decode 往返（缺键按恒等默认补齐）', () {
      final params = {
        'band_count': 3,
        'band_mode': 'parallel',
        'sel_band': 2,
        'b0_h': 10.0,
        'b0_q': 2.5,
        'b0_dh': -30.0,
        'b0_s': 1.5,
        'b0_l': 0.8,
        'b2_h': 200.0,
        'b2_dh': 45.0,
      };
      final json = jsonEncode(encodeColorStyle(params));
      final d = decodeColorStyle(json, oldBandCount: 3);
      expect(d['band_count'], 3);
      expect(d['band_mode'], 'parallel');
      expect(d['sel_band'], 0);
      expect(d['b0_h'], 10.0);
      expect(d['b0_s'], 1.5);
      expect(d['b1_q'], 2.0); // 缺键段补齐恒等默认
      expect(d['b1_s'], 1.0);
      expect(d['b2_h'], 200.0);
      expect(d['b2_l'], 1.0);
      expect(d.containsKey('b3_h'), isFalse); // 无多余段键
    });

    test('encode 缺 band_count/band_mode 回退 1 段并联', () {
      final style = encodeColorStyle(const {});
      expect(style['version'], 1);
      expect(style['band_mode'], 'parallel');
      expect(style['bands'], [
        {'h': 0.0, 'q': 2.0, 'dh': 0.0, 's': 1.0, 'l': 1.0}
      ]);
    });

    test('版本不符拒绝', () {
      final bad = jsonEncode(
          {'version': 2, 'band_mode': 'parallel', 'bands': [{}]});
      expect(() => decodeColorStyle(bad, oldBandCount: 1),
          throwsFormatException);
    });

    test('非 JSON / 顶层非对象 / 段数越界拒绝', () {
      expect(() => decodeColorStyle('not json', oldBandCount: 1),
          throwsFormatException);
      expect(() => decodeColorStyle('[1,2]', oldBandCount: 1),
          throwsFormatException);
      expect(
          () => decodeColorStyle(
              jsonEncode(
                  {'version': 1, 'band_mode': 'parallel', 'bands': []}),
              oldBandCount: 1),
          throwsFormatException);
      expect(
          () => decodeColorStyle(
              jsonEncode({
                'version': 1,
                'band_mode': 'parallel',
                'bands': List.generate(25, (i) => {}),
              }),
              oldBandCount: 1),
          throwsFormatException);
    });

    test('数值越界 clamp（宽容策略，不整份拒绝）', () {
      final json = jsonEncode({
        'version': 1,
        'band_mode': 'serial',
        'bands': [
          {'h': 999.0, 'q': 0.1, 'dh': -500.0, 's': 9.0, 'l': -1.0}
        ],
      });
      final d = decodeColorStyle(json, oldBandCount: 1);
      expect(d['band_mode'], 'serial');
      expect(d['b0_h'], 360.0);
      expect(d['b0_q'], 0.5);
      expect(d['b0_dh'], -180.0);
      expect(d['b0_s'], 5.0);
      expect(d['b0_l'], 0.0);
    });

    test('段字段缺失补齐恒等默认', () {
      final json = jsonEncode(
          {'version': 1, 'band_mode': 'parallel', 'bands': [{}]});
      final d = decodeColorStyle(json, oldBandCount: 1);
      expect(d['b0_h'], 0.0);
      expect(d['b0_q'], 2.0);
      expect(d['b0_dh'], 0.0);
      expect(d['b0_s'], 1.0);
      expect(d['b0_l'], 1.0);
    });

    test('读取后多余旧段键写 null 清除', () {
      final json = jsonEncode({
        'version': 1,
        'band_mode': 'parallel',
        'bands': [
          {'h': 50.0}
        ],
      });
      final d = decodeColorStyle(json, oldBandCount: 3);
      expect(d.containsKey('b1_h'), isTrue);
      expect(d['b1_h'], isNull);
      expect(d['b2_l'], isNull);
      expect(d.containsKey('b3_h'), isFalse); // 不波及超出现有段数的键
    });
  });

  group('pipeline_runner 集成', () {
    /// 8bit unpacked RAW：每像素一个 16 位小端字。
    List<int> raw8Le(Iterable<int> px) => [
          for (final v in px) ...[v & 0xFF, (v >> 8) & 0xFF],
        ];

    Future<File> tempRaw(int w, int h) async {
      final tmp = File(
          '${Directory.systemTemp.path}/isp_mb_eq_${DateTime.now().microsecondsSinceEpoch}.raw');
      await tmp.writeAsBytes(
          raw8Le(List<int>.generate(w * h, (i) => i * 37 % 251)));
      return tmp;
    }

    List<Map<String, Object?>> chain(File tmp, int w, int h,
            Map<String, Object?>? mb) =>
        [
          {
            'typeId': 'bayer_source',
            'nodeId': 'src',
            'params': {
              'filePath': tmp.path,
              'width': w,
              'height': h,
              'bitDepth': '8',
              'packing': 'unpacked_lsb',
              'bayerPattern': 'RGGB',
              'littleEndian': true,
              'frameIndex': 0,
            },
          },
          {'typeId': 'demosaic', 'nodeId': 'dm', 'params': {}},
          {'typeId': 'csc_rgb2hsl', 'nodeId': 'hsl', 'params': {}},
          ?mb,
          {'typeId': 'csc_hsl2rgb', 'nodeId': 'rgb', 'params': {}},
          {'typeId': 'preview', 'nodeId': 'pv', 'params': {}},
        ];

    test('单段与色彩控制器同参数结果逐字节一致', () async {
      const w = 8, h = 8;
      final tmp = await tempRaw(w, h);
      try {
        final mb = await runChainFrame(
            chain(tmp, w, h, {
              'typeId': 'multi_band_eq',
              'nodeId': 'mb',
              'params': {
                'band_count': 1,
                'b0_h': 120.0,
                'b0_q': 3.0,
                'b0_dh': -45.0,
                'b0_s': 1.5,
                'b0_l': 0.8,
              },
            }),
            0);
        final cc = await runChainFrame(
            chain(tmp, w, h, {
              'typeId': 'color_controller',
              'nodeId': 'mb',
              'params': {
                'h_center': 120.0,
                'q': 3.0,
                'h_shift': -45.0,
                's_gain': 1.5,
                'l_gain': 0.8,
              },
            }),
            0);
        expect(mb, equals(cc));
      } finally {
        await tmp.delete();
      }
    });

    test('缺省段参数恒等直通（与无该节点一致）', () async {
      const w = 8, h = 8;
      final tmp = await tempRaw(w, h);
      try {
        final identity = await runChainFrame(
            chain(tmp, w, h, {
              'typeId': 'multi_band_eq',
              'nodeId': 'mb',
              // band_count=3 但无任何 b{i}_* 键：全部回退恒等段。
              'params': {'band_count': 3},
            }),
            0);
        final direct = await runChainFrame(chain(tmp, w, h, null), 0);
        expect(identity, equals(direct));
      } finally {
        await tmp.delete();
      }
    });

    test('bypass 直通（与无该节点一致）', () async {
      const w = 8, h = 8;
      final tmp = await tempRaw(w, h);
      try {
        final bypassed = await runChainFrame(
            chain(tmp, w, h, {
              'typeId': 'multi_band_eq',
              'nodeId': 'mb',
              'params': {'band_count': 1, 'b0_dh': 90.0, 'bypass': true},
            }),
            0);
        final direct = await runChainFrame(chain(tmp, w, h, null), 0);
        expect(bypassed, equals(direct));
      } finally {
        await tmp.delete();
      }
    });

    test('两段串联跑通且与并联结果不同（小图集成）', () async {
      const w = 8, h = 8;
      final tmp = await tempRaw(w, h);
      try {
        Map<String, Object?> mb(String mode) => {
              'typeId': 'multi_band_eq',
              'nodeId': 'mb',
              'params': {
                'band_count': 2,
                'band_mode': mode,
                'b0_h': 0.0,
                'b0_q': 2.0,
                'b0_dh': 90.0,
                'b1_h': 90.0,
                'b1_q': 2.0,
                'b1_dh': 90.0,
                'b1_s': 2.0,
              },
            };
        final serial = await runChainFrame(chain(tmp, w, h, mb('serial')), 0);
        final parallel =
            await runChainFrame(chain(tmp, w, h, mb('parallel')), 0);
        final direct = await runChainFrame(chain(tmp, w, h, null), 0);
        expect(serial, isNot(equals(parallel)));
        expect(serial, isNot(equals(direct)));
      } finally {
        await tmp.delete();
      }
    });
  });

  group('estimateBandQ 取色器 Q 值自动评估', () {
    /// 合成 RGBA8 像素缓冲（[pixel] 返回 (r,g,b)，alpha 恒 255）。
    ByteData rgbaOf(int w, int h, (int, int, int) Function(int, int) pixel) {
      final bd = ByteData(w * h * 4);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final (r, g, b) = pixel(x, y);
          final off = (y * w + x) * 4;
          bd.setUint8(off, r);
          bd.setUint8(off + 1, g);
          bd.setUint8(off + 2, b);
          bd.setUint8(off + 3, 255);
        }
      }
      return bd;
    }

    test('硬边界：平滑段到边界距离 d，Q = 宽/d', () {
      // 左半纯红（0°）右半纯绿（120°）：从 (0,5) 向右走 20 像素到边界，
      // 为 8 方向最长段，Q = 40/20 = 2。
      final bd =
          rgbaOf(40, 10, (x, y) => x < 20 ? (255, 0, 0) : (0, 255, 0));
      expect(estimateBandQ(bd, 40, 10, 0, 5), closeTo(2.0, 1e-9));
    });

    test('低饱和灰像素视为相位突变，阻断平滑段', () {
      // x=10 灰列：向右平滑段缩短为 10，Q = 40/10 = 4。
      final bd = rgbaOf(40, 10, (x, y) {
        if (x == 10) return (128, 128, 128);
        return x < 20 ? (255, 0, 0) : (0, 255, 0);
      });
      expect(estimateBandQ(bd, 40, 10, 0, 5), closeTo(4.0, 1e-9));
    });

    test('起始像素低饱和（色相无意义）回退默认 2.0', () {
      final bd = rgbaOf(40, 10, (x, y) => (128, 128, 128));
      expect(estimateBandQ(bd, 40, 10, 5, 5), 2.0);
    });

    test('孤立像素 d=1，Q=M 且钳位不超过 100', () {
      // 200x1：唯一红像素四周皆绿，d=1，M=200，Q 钳位到 100。
      final bd =
          rgbaOf(200, 1, (x, y) => x == 100 ? (255, 0, 0) : (0, 255, 0));
      expect(estimateBandQ(bd, 200, 1, 100, 0), 100.0);
    });

    test('色相环绕：355° 与 5° 环差约 10° 判为连续', () {
      // 左半 hue≈355°、右半 hue≈5°，边界不中断：从 (10,1) 向右平滑段
      // 直达右边界（d=20），Q = 30/20 = 1.5；若环绕处理缺失会在 x=15
      // 处误判突变（d=5，Q=6）。
      final bd =
          rgbaOf(30, 4, (x, y) => x < 15 ? (255, 0, 21) : (255, 21, 0));
      expect(estimateBandQ(bd, 30, 4, 10, 1), closeTo(1.5, 1e-9));
    });
  });

  group('applyHslBandLutsParallel 常驻条带池', () {
    test('池路径（≥1M 像素）与整幅串行逐位一致', () async {
      // 1024x1024 触发并行池路径（parallelPixels = 1M）。
      const w = 1024, h = 1024, max = 255;
      final hsl = Uint16List(w * h * 3);
      for (var i = 0; i < hsl.length; i++) {
        hsl[i] = (i * 7 + (i ~/ 3)) % 256;
      }
      final (shift, sMul, lMul) = multiBandLuts([
        (h: 100.0, q: 3.0, dh: 40.0, s: 1.5, l: 0.8),
        (h: 300.0, q: 8.0, dh: -60.0, s: 0.7, l: 1.2),
      ], serial: true, maxValue: max);
      final expected = applyHslBandLuts(hsl, 0, hsl.length ~/ 3,
          maxValue: max, shiftLut: shift, sMulLut: sMul, lMulLut: lMul);
      final actual = await applyHslBandLutsParallel(hsl,
          width: w,
          height: h,
          maxValue: max,
          shiftLut: shift,
          sMulLut: sMul,
          lMulLut: lMul);
      expect(actual, equals(expected));
    });
  });
}
