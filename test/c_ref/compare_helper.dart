/// Dart↔C 对拍测试辅助库。
///
/// 协议（与 test/c_ref/harness.h 契约一致）：
/// - 用例目录（`Directory.systemTemp` 下临时创建）内含：
///   - `params.txt`：`key=value` 行；double 用 `toString()`（最短往返表示，
///     C 侧 strtod 精确往返），bool 写 0/1，int 直写，String 原样；
///   - `inN.bin`：小端 uint16 数组；`inRaw0.bin`：原始字节流。
/// - harness 输出 `outN.bin`（小端 uint16 或 u8 流）与 `scalars.txt`。
///
/// 典型用法（组代理照此写测试）：
/// ```dart
/// Future<void> main() async {
///   final built = await ensureHarnessBuilt();
///   group('xxx C↔Dart 对拍',
///       skip: built ? false : '无 MSVC 环境或 harness 构建失败', () {
///     test('case', () async {
///       final r = await runCOp('some_op',
///           params: {'width': 64, 'height': 48}, inputs: [frame]);
///       expectFramesEqual(r.outputs[0], dartExpected, context: 'case');
///     });
///   });
/// }
/// ```
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

/// harness exe 路径（相对工程根；flutter test 的工作目录即工程根）。
const String harnessExePath = r'scratch\c_ref_check\c_ref_harness.exe';

/// 构建脚本路径。
const String harnessBuildScript = r'scripts\c_build_harness.bat';

/// 带分组标签的 exe 路径（并行开发期各组构建自己的 exe，避免输出文件竞争；
/// 正式全量运行用 [tag] = '' 的默认 exe）。
String harnessExePathFor(String tag) =>
    tag.isEmpty ? harnessExePath : 'scratch\\c_ref_check\\c_ref_harness$tag.exe';

// ---------------------------------------------------------------------------
// 确定性测试帧生成
// ---------------------------------------------------------------------------

/// 确定性 LCG（Numerical Recipes 常数）生成 Uint16List 测试帧。
///
/// 不依赖 dart:math Random 的种子语义，跨版本/跨平台结果恒定。
/// 返回长度 width*height*channels，值域 [0, maxValue]。
Uint16List lcgFrame(int width, int height, int channels, int seed,
    {int maxValue = 1023}) {
  final out = Uint16List(width * height * channels);
  var state = seed & 0xFFFFFFFF;
  final mod = maxValue + 1;
  for (var i = 0; i < out.length; i++) {
    state = (state * 1664525 + 1013904223) & 0xFFFFFFFF;
    // 取高 16 位再取模，低位的短周期特性不影响取值分布。
    out[i] = ((state >> 16) & 0xFFFF) % mod;
  }
  return out;
}

/// 确定性渐变+边缘图案帧：横向渐变叠加纵向条纹，四角强制 0 与 maxValue，
/// 覆盖边界值。返回长度 width*height*channels。
Uint16List gradientFrame(int width, int height, int channels,
    {int maxValue = 1023}) {
  final out = Uint16List(width * height * channels);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final base = width > 1 ? (x * maxValue) ~/ (width - 1) : 0;
      final stripe = (y & 1) == 0 ? 0 : (maxValue >> 2);
      for (var c = 0; c < channels; c++) {
        var v = (base + stripe + c * 7) % (maxValue + 1);
        if ((x == 0 || x == width - 1) && (y == 0 || y == height - 1)) {
          v = ((x + y) & 1) == 0 ? 0 : maxValue;
        }
        out[(y * width + x) * channels + c] = v;
      }
    }
  }
  return out;
}

/// 常量帧。
Uint16List constantFrame(int width, int height, int channels, int value) {
  return Uint16List.fromList(
      List<int>.filled(width * height * channels, value));
}

// ---------------------------------------------------------------------------
// 文件 IO
// ---------------------------------------------------------------------------

/// 写小端 uint16 帧文件（inN.bin / 期望输出比对用）。
Future<void> writeFrameBin(String path, List<int> data) async {
  final bytes = Uint8List(data.length * 2);
  final bd = ByteData.view(bytes.buffer);
  for (var i = 0; i < data.length; i++) {
    bd.setUint16(i * 2, data[i] & 0xFFFF, Endian.little);
  }
  await File(path).writeAsBytes(bytes, flush: true);
}

/// 写原始字节流文件（inRaw0.bin）。
Future<void> writeRawBin(String path, List<int> bytes) async {
  await File(path).writeAsBytes(bytes, flush: true);
}

/// 写 params.txt。double 用 toString()（与 C strtod 精确往返），
/// bool -> 0/1，int/String 直写。
Future<void> writeParams(String path, Map<String, Object?> params) async {
  final sb = StringBuffer();
  params.forEach((key, value) {
    if (value == null) return;
    if (value is bool) {
      sb.writeln('$key=${value ? 1 : 0}');
    } else {
      sb.writeln('$key=$value');
    }
  });
  await File(path).writeAsString(sb.toString(), flush: true);
}

/// 读小端 uint16 帧文件。
Future<Uint16List> readFrameBin(String path) async {
  final bytes = await File(path).readAsBytes();
  final bd = ByteData.sublistView(bytes);
  final out = Uint16List(bytes.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = bd.getUint16(i * 2, Endian.little);
  }
  return out;
}

/// 读原始字节流文件。
Future<Uint8List> readRawBin(String path) async {
  return File(path).readAsBytes();
}

/// 读 scalars.txt 为 key->double 映射。
Future<Map<String, double>> readScalars(String path) async {
  final out = <String, double>{};
  final f = File(path);
  if (!f.existsSync()) return out;
  for (final line in (await f.readAsString()).split('\n')) {
    final t = line.trim();
    if (t.isEmpty || t.startsWith('#')) continue;
    final eq = t.indexOf('=');
    if (eq <= 0) continue;
    out[t.substring(0, eq)] = double.parse(t.substring(eq + 1));
  }
  return out;
}

// ---------------------------------------------------------------------------
// harness 构建与调用
// ---------------------------------------------------------------------------

/// 确保 harness exe 已构建：不存在则调 scripts/c_build_harness.bat 构建。
/// 返回 false 表示无 MSVC 环境或构建失败（测试应以 skip 处理）。
/// [tag] 见 [harnessExePathFor]。
Future<bool> ensureHarnessBuilt({String tag = ''}) async {
  if (File(harnessExePathFor(tag)).existsSync()) return true;
  final r = await Process.run('cmd', ['/c', harnessBuildScript, tag]);
  if (r.exitCode != 0) {
    // ignore: avoid_print
    print('c_ref harness 构建失败（测试将 skip）：\n${r.stdout}\n${r.stderr}');
    return false;
  }
  return File(harnessExePathFor(tag)).existsSync();
}

/// 一次 C op 调用的结果。
class COpResult {
  COpResult(
      {required this.outputs, required this.scalars, required this.caseDir});

  /// out0.bin..outN.bin 读回的小端 u16 数组（u8 流输出请用 [rawOutputs]）。
  final List<Uint16List> outputs;

  /// outN.bin 读回的原始字节（仅在 [runCOp] 指定 rawOutputCount 时填充，
  /// 用于 tonemap RGBA 等 u8 流输出）。
  final List<Uint8List> rawOutputs = [];

  /// scalars.txt 读回的标量输出。
  final Map<String, double> scalars;

  /// 用例目录（未删除，失败排查时可查看；由 OS 清理临时目录）。
  final String caseDir;
}

/// 调用 C harness 执行一个 op。
///
/// [params] 写入 params.txt；[inputs] 逐帧写 in0.bin/in1.bin...；
/// [inRaw] 写 inRaw0.bin（原始字节流输入，如 unpack 用例）。
/// [outputCount] 个 outN.bin 按小端 u16 读回；[rawOutputCount] 个 outN.bin
/// （接在 u16 输出之后编号，如 outputCount=1、rawOutputCount=1 则读
/// out0(u16) 与 out1(raw u8)）按字节流读回。
/// 进程非零退出时抛 StateError（附 stderr）。
Future<COpResult> runCOp(String op,
    {Map<String, Object?> params = const {},
    List<List<int>> inputs = const [],
    List<int>? inRaw,
    int outputCount = 1,
    int rawOutputCount = 0,
    String tag = ''}) async {
  final dir = await Directory.systemTemp.createTemp('c_ref_case_');
  await writeParams('${dir.path}\\params.txt', params);
  for (var i = 0; i < inputs.length; i++) {
    await writeFrameBin('${dir.path}\\in$i.bin', inputs[i]);
  }
  if (inRaw != null) {
    await writeRawBin('${dir.path}\\inRaw0.bin', inRaw);
  }
  final r = await Process.run(harnessExePathFor(tag), [op, dir.path]);
  if (r.exitCode != 0) {
    throw StateError(
        'c_ref op $op 失败 rc=${r.exitCode}（用例目录 ${dir.path}）：\n'
        '${r.stderr}');
  }
  final outputs = <Uint16List>[];
  for (var i = 0; i < outputCount; i++) {
    outputs.add(await readFrameBin('${dir.path}\\out$i.bin'));
  }
  final result = COpResult(
      outputs: outputs,
      scalars: await readScalars('${dir.path}\\scalars.txt'),
      caseDir: dir.path);
  for (var i = 0; i < rawOutputCount; i++) {
    result.rawOutputs
        .add(await readRawBin('${dir.path}\\out${outputCount + i}.bin'));
  }
  return result;
}

// ---------------------------------------------------------------------------
// 比对断言
// ---------------------------------------------------------------------------

/// 逐元素比对两帧。不等时打印前若干差异坐标/值与最大差，然后 fail。
///
/// [tol] 容差（默认 0 = 逐位相等）；使用容差时在测试注释里写明理由，
/// 并关注打印的 maxDiff 是否远超预期。
void expectFramesEqual(List<int> actual, List<int> expected,
    {String context = '', int tol = 0}) {
  expect(actual.length, expected.length,
      reason: '$context: 帧长度不等 actual=${actual.length} '
          'expected=${expected.length}');
  final diffs = <String>[];
  var maxDiff = 0;
  var mismatch = 0;
  for (var i = 0; i < actual.length; i++) {
    final d = (actual[i] - expected[i]).abs();
    if (d > tol) {
      mismatch++;
      if (diffs.length < 10) {
        diffs.add('  [$i] actual=${actual[i]} expected=${expected[i]} d=$d');
      }
    }
    if (d > maxDiff) maxDiff = d;
  }
  if (tol > 0) {
    // ignore: avoid_print
    print('$context: maxDiff=$maxDiff (tol=$tol)');
  }
  if (mismatch > 0) {
    fail('$context: $mismatch/${actual.length} 个元素超出容差 tol=$tol，'
        'maxDiff=$maxDiff\n${diffs.join('\n')}');
  }
}
