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
