/// .nnw 二进制权重文件读取器（纯 Dart，无 Flutter 依赖）。
///
/// 格式（见 tools/iqa/export_weights.py）：
///   字节 0-7   magic ASCII "DTSNNW01"
///   字节 8-15  uint64 LE = manifest JSON 字节长度
///   随后       manifest UTF-8 JSON {"format":1,"tensors":{name:
///              {"shape":[...],"dtype":"f32","offset":N,"nbytes":M}}}
///   随后       数据区 raw fp32 LE，row-major（offset 相对数据区起点）
///
/// 通过 RandomAccessFile 按需读取单个张量，不全量加载大权重文件。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'tensor.dart';

/// manifest 中单个张量的元信息。
class NnwTensorInfo {
  const NnwTensorInfo(this.shape, this.offset, this.nbytes);

  final List<int> shape;

  /// 相对数据区起点的字节偏移。
  final int offset;
  final int nbytes;

  int get numel {
    var n = 1;
    for (final d in shape) {
      n *= d;
    }
    return n;
  }

  @override
  String toString() => 'NnwTensorInfo(shape: $shape, offset: $offset, '
      'nbytes: $nbytes)';
}

/// .nnw 读取器。用 [NnwReader.open] 打开，用完 [close]。
class NnwReader {
  NnwReader._(this._raf, this._dataStart, this._tensors);

  /// 打开并解析文件头与 manifest（同步）。
  factory NnwReader.open(String path) {
    final raf = File(path).openSync();
    try {
      final header = raf.readSync(16);
      if (header.length < 16) {
        throw FormatException('$path: 文件头不完整', path);
      }
      for (var i = 0; i < 8; i++) {
        if (header[i] != _magic.codeUnitAt(i)) {
          throw FormatException('$path: magic 不匹配，不是 .nnw 文件', path);
        }
      }
      final mlen = ByteData.sublistView(header).getUint64(8, Endian.little);
      final mBytes = raf.readSync(mlen);
      if (mBytes.length < mlen) {
        throw FormatException('$path: manifest 不完整', path);
      }
      final manifest =
          jsonDecode(utf8.decode(mBytes)) as Map<String, dynamic>;
      if (manifest['format'] != 1) {
        throw FormatException(
            '$path: 不支持的 format ${manifest['format']}', path);
      }
      final tensors = <String, NnwTensorInfo>{};
      (manifest['tensors'] as Map<String, dynamic>).forEach((name, e) {
        final m = e as Map<String, dynamic>;
        if (m['dtype'] != 'f32') {
          throw FormatException('$path: 张量 $name 的 dtype ${m['dtype']} '
              '不是 f32', path);
        }
        tensors[name] = NnwTensorInfo(
          (m['shape'] as List).cast<int>(),
          m['offset'] as int,
          m['nbytes'] as int,
        );
      });
      return NnwReader._(raf, 16 + mlen, tensors);
    } catch (_) {
      raf.closeSync();
      rethrow;
    }
  }

  static const String _magic = 'DTSNNW01';

  final RandomAccessFile _raf;
  final int _dataStart;
  final Map<String, NnwTensorInfo> _tensors;
  var _closed = false;

  List<String> get tensorNames => List<String>.unmodifiable(_tensors.keys);

  bool contains(String name) => _tensors.containsKey(name);

  List<int> shapeOf(String name) => _info(name).shape;

  NnwTensorInfo infoOf(String name) => _info(name);

  /// 按需读取一个张量：返回 (fp32 数据, shape)。
  (Float32List, List<int>) tensor(String name) {
    final info = _info(name);
    final bytes = Uint8List(info.nbytes);
    _raf
      ..setPositionSync(_dataStart + info.offset)
      ..readIntoSync(bytes);
    return (bytes.buffer.asFloat32List(0, info.nbytes ~/ 4), info.shape);
  }

  /// 直接以 [NnTensor] 返回。
  NnTensor readTensor(String name) {
    final (data, shape) = tensor(name);
    return NnTensor(data, shape);
  }

  NnwTensorInfo _info(String name) {
    if (_closed) {
      throw StateError('NnwReader 已关闭');
    }
    final info = _tensors[name];
    if (info == null) {
      throw ArgumentError('.nnw 中不存在张量 "$name"');
    }
    return info;
  }

  void close() {
    if (!_closed) {
      _closed = true;
      _raf.closeSync();
    }
  }
}
