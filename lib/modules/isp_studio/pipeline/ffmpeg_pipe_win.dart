/// Windows 高性能 ffmpeg 原始帧管道：CreatePipe（大缓冲）+ CreateProcessW
/// （stdout 重定向进管道）+ ReadFile 整帧阻塞读。
///
/// 动机：dart:io 的 Process.stdout 按 ~64KB 块经事件循环分发，4K 帧
/// （yuv420p 12.4MB）约 379 个事件/帧、~30ms/帧，把管道吞吐锁死在
/// ~33fps；Win32 大管道 + 整帧 ReadFile 单帧仅数次系统调用，且帧落
/// 在原生堆（calloc）上，跨 isolate 传指针即零拷贝。
library;

import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart' as pkgffi;

typedef _CreatePipeN = ffi.Int32 Function(ffi.Pointer<ffi.Uint64>,
    ffi.Pointer<ffi.Uint64>, ffi.Pointer<ffi.Void>, ffi.Uint32);
typedef _CreatePipeD = int Function(ffi.Pointer<ffi.Uint64>,
    ffi.Pointer<ffi.Uint64>, ffi.Pointer<ffi.Void>, int);
typedef _ReadFileN = ffi.Int32 Function(ffi.Uint64, ffi.Pointer<ffi.Uint8>,
    ffi.Uint32, ffi.Pointer<ffi.Uint32>, ffi.Pointer<ffi.Void>);
typedef _ReadFileD = int Function(
    int, ffi.Pointer<ffi.Uint8>, int, ffi.Pointer<ffi.Uint32>, ffi.Pointer<ffi.Void>);
typedef _CreateFileWN = ffi.Uint64 Function(
    ffi.Pointer<ffi.Uint16>, ffi.Uint32, ffi.Uint32, ffi.Pointer<ffi.Void>,
    ffi.Uint32, ffi.Uint32, ffi.Uint64);
typedef _CreateFileWD = int Function(
    ffi.Pointer<ffi.Uint16>, int, int, ffi.Pointer<ffi.Void>, int, int, int);
typedef _CreateProcessN = ffi.Int32 Function(
    ffi.Pointer<ffi.Uint16>,
    ffi.Pointer<ffi.Uint16>,
    ffi.Pointer<ffi.Void>,
    ffi.Pointer<ffi.Void>,
    ffi.Int32,
    ffi.Uint32,
    ffi.Pointer<ffi.Void>,
    ffi.Pointer<ffi.Uint16>,
    ffi.Pointer<ffi.Uint8>,
    ffi.Pointer<ffi.Uint8>);
typedef _CreateProcessD = int Function(
    ffi.Pointer<ffi.Uint16>,
    ffi.Pointer<ffi.Uint16>,
    ffi.Pointer<ffi.Void>,
    ffi.Pointer<ffi.Void>,
    int,
    int,
    ffi.Pointer<ffi.Void>,
    ffi.Pointer<ffi.Uint16>,
    ffi.Pointer<ffi.Uint8>,
    ffi.Pointer<ffi.Uint8>);
typedef _HandleIntN = ffi.Int32 Function(ffi.Uint64);
typedef _HandleIntD = int Function(int);
typedef _SetHandleInfoN = ffi.Int32 Function(
    ffi.Uint64, ffi.Uint32, ffi.Uint32);
typedef _SetHandleInfoD = int Function(int, int, int);
typedef _WaitN = ffi.Uint32 Function(ffi.Uint64, ffi.Uint32);
typedef _WaitD = int Function(int, int);
typedef _TerminateN = ffi.Int32 Function(ffi.Uint64, ffi.Uint32);
typedef _TerminateD = int Function(int, int);

final _k32 = ffi.DynamicLibrary.open('kernel32.dll');
final _createPipe =
    _k32.lookupFunction<_CreatePipeN, _CreatePipeD>('CreatePipe');
final _readFile = _k32.lookupFunction<_ReadFileN, _ReadFileD>('ReadFile');
final _createFileW =
    _k32.lookupFunction<_CreateFileWN, _CreateFileWD>('CreateFileW');
final _createProcessW =
    _k32.lookupFunction<_CreateProcessN, _CreateProcessD>('CreateProcessW');
final _closeHandle =
    _k32.lookupFunction<_HandleIntN, _HandleIntD>('CloseHandle');
final _setHandleInformation = _k32
    .lookupFunction<_SetHandleInfoN, _SetHandleInfoD>('SetHandleInformation');
final _waitFor = _k32.lookupFunction<_WaitN, _WaitD>('WaitForSingleObject');
final _terminate =
    _k32.lookupFunction<_TerminateN, _TerminateD>('TerminateProcess');

/// ffmpeg 原始帧输出管道（仅 Windows；[supported] 为 false 时上层走
/// dart:io Process 路径）。
class FfmpegRawPipeWin {
  static bool get supported => Platform.isWindows;

  int _readH = 0;
  int _processH = 0;
  int _threadH = 0;
  int _nulH = 0;

  bool get running => _processH != 0;

  /// 起 ffmpeg：标准输出进大缓冲匿名管道，stderr 进 NUL（错误诊断让位
  /// 于吞吐；失败表现为一帧不出，上层据此回退软解重试）。
  /// [pipeFrames] 为管道缓冲容纳的帧数（解耦写/读节奏）。
  void start(String ffmpeg, List<String> args, int frameBytes,
      {int pipeFrames = 4}) {
    if (!supported) throw UnsupportedError('仅 Windows 支持');
    stop();

    // SECURITY_ATTRIBUTES（x64 为 24 字节：nLength@0 u32，对齐填充 4，
    // lpSecurityDescriptor@8 u64，bInheritHandle@16 u32）：
    // 置可继承，管道写端才能被子进程 stdout 使用。
    final sa = pkgffi.calloc<ffi.Uint64>(3);
    sa.cast<ffi.Uint32>().value = 24;
    sa[1] = 0;
    (sa.cast<ffi.Uint32>() + 4).value = 1; // bInheritHandle = TRUE
    final readP = pkgffi.calloc<ffi.Uint64>();
    final writeP = pkgffi.calloc<ffi.Uint64>();
    if (_createPipe(readP, writeP, sa.cast<ffi.Void>(), frameBytes * pipeFrames) == 0) {
      pkgffi.calloc.free(sa);
      pkgffi.calloc.free(readP);
      pkgffi.calloc.free(writeP);
      throw StateError('CreatePipe 失败');
    }
    pkgffi.calloc.free(sa);
    _readH = readP.value;
    final writeH = writeP.value;
    pkgffi.calloc.free(readP);
    pkgffi.calloc.free(writeP);
    // 关键：读端不可继承。SECURITY_ATTRIBUTES 置可继承只为让子进程
    // 拿到写端；若读端也被子进程继承，父进程（应用）退出/被杀后
    // 管道读端仍被 ffmpeg 自己持有——写端永远等不到「读取方关闭」，
    // ffmpeg 写满管道缓冲后永久阻塞成孤儿进程（每个持有 NVDEC
    // 会话与 ~90 个线程；多个孤儿耗尽 NVDEC 会话数，后续播放的
    // cuda 硬解初始化失败退为软解，4K60 帧率崩落）。读端不可继承
    // 后父进程一死管道即破，ffmpeg 写管道出错自行退出。
    _setHandleInformation(_readH, 1, 0); // HANDLE_FLAG_INHERIT, 0

    // stderr → NUL（不占管道，不阻塞）
    final nulName = 'NUL'.toNativeUtf16().cast<ffi.Uint16>();
    _nulH = _createFileW(nulName, 0x40000000, 3, ffi.nullptr, 4, 0x80, 0);
    pkgffi.malloc.free(nulName);

    // STARTUPINFOW（x64，104 字节）：cb=104，dwFlags=STARTF_USESTDHANDLES
    // (0x100) @60，hStdInput @80，hStdOutput @88，hStdError @96。
    final si = pkgffi.calloc<ffi.Uint8>(104);
    si.cast<ffi.Uint32>().value = 104;
    (si.cast<ffi.Uint32>() + 15).value = 0x100;
    (si.cast<ffi.Uint64>() + 10).value = _nulH; // stdin → NUL
    (si.cast<ffi.Uint64>() + 11).value = writeH; // stdout → 管道
    (si.cast<ffi.Uint64>() + 12).value = _nulH; // stderr → NUL
    final pi = pkgffi.calloc<ffi.Uint8>(24);

    final cmd = _quoteCmd(ffmpeg, args).toNativeUtf16().cast<ffi.Uint16>();
    const createNoWindow = 0x08000000;
    final ok = _createProcessW(ffi.nullptr, cmd, ffi.nullptr, ffi.nullptr, 1,
        createNoWindow, ffi.nullptr, ffi.nullptr, si, pi);
    pkgffi.malloc.free(cmd);
    _closeHandle(writeH); // 父进程不再持有写端
    if (ok == 0) {
      pkgffi.calloc.free(si);
      pkgffi.calloc.free(pi);
      stop();
      throw StateError('CreateProcessW 失败: $ffmpeg');
    }
    _processH = (pi.cast<ffi.Uint64>() + 0).value;
    _threadH = (pi.cast<ffi.Uint64>() + 1).value;
    pkgffi.calloc.free(si);
    pkgffi.calloc.free(pi);
  }

  static String _quoteCmd(String exe, List<String> args) {
    String q(String a) => '"${a.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
    return [q(exe), for (final a in args) q(a)].join(' ');
  }

  /// 阻塞读满 [len] 字节到 [buf]；返回实际读取数（< len 即 EOF/出错）。
  int readInto(ffi.Pointer<ffi.Uint8> buf, int len) {
    final got = pkgffi.calloc<ffi.Uint32>();
    var total = 0;
    try {
      while (total < len) {
        if (_readFile(_readH, buf + total, len - total, got, ffi.nullptr) ==
            0) {
          return total; // 管道关闭/错误
        }
        if (got.value == 0) return total; // EOF
        total += got.value;
      }
      return total;
    } finally {
      pkgffi.calloc.free(got);
    }
  }

  /// 终止进程并释放全部句柄（幂等）。
  void stop() {
    if (_processH != 0) {
      _terminate(_processH, 1);
      _waitFor(_processH, 2000);
      _closeHandle(_processH);
      _processH = 0;
    }
    if (_threadH != 0) {
      _closeHandle(_threadH);
      _threadH = 0;
    }
    if (_readH != 0) {
      _closeHandle(_readH);
      _readH = 0;
    }
    if (_nulH != 0) {
      _closeHandle(_nulH);
      _nulH = 0;
    }
  }
}
