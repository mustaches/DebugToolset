/// Image 源节点的图片解码：BMP/JPG/PNG/GIF（GIF 取第一帧）。
///
/// 纯 Dart（image 包），可在后台 isolate 中运行。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// 解码图片文件为 16 位量级的交织 RGB（长度 w*h*3），返回 (数据, 宽, 高)。
///
/// 8 位样本按比例放大到 [maxValue]；高位深图片（如 16 位 PNG）
/// 先降为 8 位再放大。文件不存在或无法解码时抛 [StateError]。
Future<(Uint16List, int, int)> decodeImageFileToRgb16(
  String path, {
  required int maxValue,
}) async {
  final file = File(path);
  if (!await file.exists()) throw StateError('图片文件不存在: $path');
  final bytes = await file.readAsBytes();
  var image = img.decodeImage(bytes);
  if (image == null) {
    throw StateError('无法解码图片文件（支持 BMP/JPG/PNG/GIF）: $path');
  }
  if (image.format != img.Format.uint8) {
    image = image.convert(format: img.Format.uint8);
  }
  final w = image.width;
  final h = image.height;
  final out = Uint16List(w * h * 3);
  final scale = maxValue / 255;
  var i = 0;
  for (final px in image) {
    out[i++] = (px.r * scale).round();
    out[i++] = (px.g * scale).round();
    out[i++] = (px.b * scale).round();
  }
  return (out, w, h);
}

/// 解码图片文件为 RGBA8888（长度 w*h*4），返回 (数据, 宽, 高)。
///
/// 供预览运行期「一次解码、多链共享」注入：调用方解码一次后经
/// sourceRgba 注入各预览链（链内再按位深放大到 16 位量级），避免
/// 每条链对同一文件重复完整解码。高位深图片同样先降为 8 位，与
/// [decodeImageFileToRgb16] 口径一致。
///
/// 快速路径：uint8 无调色板图像直接取内部缓冲（4 通道零拷贝，3 通道
/// 一趟紧凑循环扩 alpha），跳过 convert 的通用逐像素 Pixel 遍历
/// （20MP 图可省 1.5~2s）。
Future<(Uint8List, int, int)> decodeImageFileToRgba8(String path) async {
  final file = File(path);
  if (!await file.exists()) throw StateError('图片文件不存在: $path');
  final bytes = await file.readAsBytes();
  var image = img.decodeImage(bytes);
  if (image == null) {
    throw StateError('无法解码图片文件（支持 BMP/JPG/PNG/GIF）: $path');
  }
  final data = image.data;
  if (data is img.ImageDataUint8 && image.palette == null) {
    final w = image.width;
    final h = image.height;
    if (data.numChannels == 4) {
      return (data.data, w, h);
    }
    if (data.numChannels == 3) {
      final src = data.data;
      final out = Uint8List(w * h * 4);
      var i = 0, j = 0;
      for (; i < src.length; i += 3, j += 4) {
        out[j] = src[i];
        out[j + 1] = src[i + 1];
        out[j + 2] = src[i + 2];
        out[j + 3] = 255;
      }
      return (out, w, h);
    }
  }
  image = image.convert(format: img.Format.uint8, numChannels: 4);
  return (image.toUint8List(), image.width, image.height);
}

/// 图片文件的像素尺寸（完整解码，开销可接受）。
Future<(int, int)> imageFileDimensions(String path) async {
  final file = File(path);
  if (!await file.exists()) throw StateError('图片文件不存在: $path');
  final image = img.decodeImage(await file.readAsBytes());
  if (image == null) {
    throw StateError('无法解码图片文件（支持 BMP/JPG/PNG/GIF）: $path');
  }
  return (image.width, image.height);
}
