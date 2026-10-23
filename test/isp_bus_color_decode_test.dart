// 「仿真波形」标签页总线色彩解码（bus_color_decode.dart）测试：
// HSL/RGB/YUV × 两种字节顺序 + 亮度阈值。
import 'package:flutter_test/flutter_test.dart';

import 'package:debug_tool_set/modules/isp_studio/models/bus_color_decode.dart';

void main() {
  group('decodeBusColor24', () {
    test('none 返回 null（不填充）', () {
      expect(decodeBusColor24(BusColorSpace.none, 0xFF8000), isNull);
    });

    test('RGB：高字节=R（默认）', () {
      expect(decodeBusColor24(BusColorSpace.rgb, 0xFF0000), (255, 0, 0));
      expect(decodeBusColor24(BusColorSpace.rgb, 0x00FF00), (0, 255, 0));
      expect(decodeBusColor24(BusColorSpace.rgb, 0x0000FF), (0, 0, 255));
    });

    test('RGB：高字节=B（字节顺序切换）', () {
      expect(
          decodeBusColor24(BusColorSpace.rgb, 0xFF0000, highByteFirst: false),
          (0, 0, 255));
      expect(
          decodeBusColor24(BusColorSpace.rgb, 0x0000FF, highByteFirst: false),
          (255, 0, 0));
      // 中间通道（G）不受字节序影响。
      expect(
          decodeBusColor24(BusColorSpace.rgb, 0x00FF00, highByteFirst: false),
          (0, 255, 0));
    });

    test('HSL：纯红/纯绿/灰', () {
      // H=0、S=255、L=128 → 纯红（L=128/255 不恰为 0.5，余量通道 ±2）。
      final red = decodeBusColor24(BusColorSpace.hsl, 0x00FF80)!;
      expect(red.$1, 255);
      expect(red.$2, inInclusiveRange(0, 2));
      expect(red.$3, inInclusiveRange(0, 2));
      // H=85（≈120°）、S=255、L=128 → 纯绿。
      final green = decodeBusColor24(BusColorSpace.hsl, 0x55FF80)!;
      expect(green.$1, inInclusiveRange(0, 2));
      expect(green.$2, 255);
      expect(green.$3, inInclusiveRange(0, 2));
      // S=0 → 灰（R=G=B=L）。
      expect(decodeBusColor24(BusColorSpace.hsl, 0x000080), (128, 128, 128));
    });

    test('HSL：字节顺序切换（高字节=L）', () {
      // 高字节=L=128、低字节=H=0：与上例纯红同义。
      final red =
          decodeBusColor24(BusColorSpace.hsl, 0x80FF00, highByteFirst: false)!;
      expect(red.$1, 255);
      expect(red.$2, inInclusiveRange(0, 2));
      expect(red.$3, inInclusiveRange(0, 2));
    });

    test('YUV：灰（U=V=128）与钳位', () {
      // Y=128、U=V=128 → 中性灰。
      expect(decodeBusColor24(BusColorSpace.yuv, 0x808080), (128, 128, 128));
      // Y=255、V=255 → R 钳位 255，G = 255−0.714×127 ≈ 164。
      final (r, g, b) = decodeBusColor24(BusColorSpace.yuv, 0xFF80FF)!;
      expect(r, 255);
      expect(g, inInclusiveRange(160, 170));
      expect(b, 255);
      // Y=0、U=V=0 → 各通道钳位 0 下限附近。
      final (r0, g0, b0) = decodeBusColor24(BusColorSpace.yuv, 0x000000)!;
      expect(r0, 0);
      expect(g0, inInclusiveRange(130, 140));
      expect(b0, 0);
    });

    test('isLightColor 亮度阈值', () {
      expect(isLightColor(255, 255, 255), isTrue);
      expect(isLightColor(0, 0, 0), isFalse);
      expect(isLightColor(255, 0, 0), isFalse); // 纯红亮度 ~76
    });
  });
}
