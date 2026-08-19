/// 三维数组视图：把链上流动的一维像素缓冲按 (frame, width, height) 索引呈现。
///
/// 底层仍是类型化一维数组（Uint16List/Uint8List），不复制、不改布局；
/// 只包装当前帧（多帧 RAW 不全部载入内存），因此 [frameCount] 恒为 1，
/// frame 下标恒为 0。多通道缓冲（rgb/yuv/hsl/rgba）通过 channel 维度寻址。
library;

/// 一维像素缓冲的三维只读视图。
class Frame3D {
  /// 底层一维数据（行优先，通道交织），长度 = width*height*channels。
  final List<int> data;

  /// 帧宽（第二维下标 x 的范围 0..width-1）。
  final int width;

  /// 帧高（第三维下标 y 的范围 0..height-1）。
  final int height;

  /// 每像素通道数：1=mosaic/灰度，3=rgb/yuv/hsl，4=rgba。
  final int channels;

  /// 帧数。当前实现只加载当前帧，恒为 1。
  final int frameCount = 1;

  const Frame3D({
    required this.data,
    required this.width,
    required this.height,
    this.channels = 1,
  });

  /// 取 (frame, x, y) 处的采样值；多通道缓冲用 [channel] 指定通道。
  int at(int frame, int x, int y, [int channel = 0]) {
    RangeError.checkValueInInterval(frame, 0, frameCount - 1, 'frame');
    RangeError.checkValueInInterval(x, 0, width - 1, 'x');
    RangeError.checkValueInInterval(y, 0, height - 1, 'y');
    RangeError.checkValueInInterval(channel, 0, channels - 1, 'channel');
    return data[((frame * height + y) * width + x) * channels + channel];
  }

  /// 一维下标 → (frame, x, y, channel) 坐标。
  (int, int, int, int) coordinateOf(int index) {
    RangeError.checkValueInInterval(index, 0, data.length - 1, 'index');
    final channel = index % channels;
    final pixel = index ~/ channels;
    final x = pixel % width;
    final y = (pixel ~/ width) % height;
    final frame = pixel ~/ (width * height);
    return (frame, x, y, channel);
  }

  /// 链格式字符串 → 通道数。
  static int channelsOf(String format) => switch (format) {
        'mosaic' => 1,
        'mono' => 1,
        'rgba' => 4,
        _ => 3, // rgb / yuv / hsl
      };
}
