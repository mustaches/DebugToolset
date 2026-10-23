import 'dart:io';
void main() {
  const frameBytes = 3840 * 2160 * 3 ~/ 2;
  final f = File('scratch/seg55.yuv').openSync();
  final out = File('scratch/seg55_src.hash').openWrite();
  final buf = List<int>.filled(frameBytes, 0);
  var idx = 0;
  while (true) {
    var got = 0;
    while (got < frameBytes) {
      final r = f.readIntoSync(buf, got, frameBytes);
      if (r <= 0) break;
      got += r;
    }
    if (got < frameBytes) break;
    var h = 0x811c9dc5;
    for (var i = 0; i < frameBytes; i += 16) {
      h ^= buf[i];
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    out.writeln('$idx ${h.toRadixString(16).padLeft(8, '0')}');
    idx++;
  }
  out.close();
  f.closeSync();
  print('hashed $idx frames');
}
