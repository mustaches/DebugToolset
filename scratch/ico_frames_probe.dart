// 一次性脚本：列出 ico 各帧尺寸与像素哈希。
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:image/image.dart' as img;

void main(List<String> args) {
  for (final path in args) {
    final bytes = File(path).readAsBytesSync();
    final dec = img.IcoDecoder();
    dec.startDecode(bytes);
    // ignore: avoid_print
    print('$path (${dec.numFrames()} 帧):');
    for (var i = 0; i < dec.numFrames(); i++) {
      final f = dec.decodeFrame(i);
      if (f == null) continue;
      final hash = crypto.md5
          .convert(f.getBytes(order: img.ChannelOrder.rgba))
          .toString()
          .substring(0, 10);
      // ignore: avoid_print
      print('  frame$i ${f.width}x${f.height} md5=$hash');
    }
  }
}
