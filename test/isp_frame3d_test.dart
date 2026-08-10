import 'package:flutter_test/flutter_test.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/frame3d.dart';

void main() {
  group('Frame3D', () {
    test('单通道：at 与 coordinateOf 按 (frame, x, y) 互逆', () {
      // 4x3 马赛克：值 = y*4 + x。
      final view = Frame3D(
          data: List<int>.generate(12, (i) => i), width: 4, height: 3);
      expect(view.frameCount, 1);
      expect(view.at(0, 0, 0), 0);
      expect(view.at(0, 3, 0), 3);
      expect(view.at(0, 0, 1), 4);
      expect(view.at(0, 2, 2), 10);
      expect(view.coordinateOf(10), (0, 2, 2, 0));
      expect(view.coordinateOf(0), (0, 0, 0, 0));
    });

    test('多通道：channel 维度参与寻址', () {
      // 2x2 RGB：值 = 元素下标。
      final view = Frame3D(
          data: List<int>.generate(12, (i) => i),
          width: 2,
          height: 2,
          channels: 3);
      expect(view.at(0, 0, 0), 0); // (0,0).R
      expect(view.at(0, 0, 0, 2), 2); // (0,0).B
      expect(view.at(0, 1, 0), 3); // (1,0).R
      expect(view.at(0, 0, 1, 1), 7); // (0,1).G
      expect(view.coordinateOf(7), (0, 0, 1, 1));
    });

    test('越界访问抛 RangeError', () {
      final view = Frame3D(data: [1, 2, 3, 4], width: 2, height: 2);
      expect(() => view.at(1, 0, 0), throwsRangeError); // frame 只能为 0
      expect(() => view.at(0, 2, 0), throwsRangeError);
      expect(() => view.at(0, 0, -1), throwsRangeError);
      expect(() => view.at(0, 0, 0, 1), throwsRangeError); // 单通道无 channel 1
      expect(() => view.coordinateOf(4), throwsRangeError);
    });

    test('channelsOf 按链格式给通道数', () {
      expect(Frame3D.channelsOf('mosaic'), 1);
      expect(Frame3D.channelsOf('rgb'), 3);
      expect(Frame3D.channelsOf('yuv'), 3);
      expect(Frame3D.channelsOf('hsl'), 3);
      expect(Frame3D.channelsOf('rgba'), 4);
    });
  });
}
