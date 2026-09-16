// 诊断 CP2105 双串口 COM7 打开失败问题
// 运行方式（项目根目录）：
//   set LIBSERIALPORT_PATH=build/windows/x64/runner/Debug/serialport.dll
//   dart run scratch/com7_open_diag.dart
// （Git Bash: LIBSERIALPORT_PATH=build/windows/x64/runner/Debug/serialport.dll dart run scratch/com7_open_diag.dart）
import 'dart:ffi' as ffi;
import 'package:ffi/ffi.dart' as pkgffi;
import 'package:libserialport/libserialport.dart';

typedef CreateFileWNative = ffi.Pointer<ffi.Void> Function(
    ffi.Pointer<ffi.Uint16> lpFileName,
    ffi.Uint32 dwDesiredAccess,
    ffi.Uint32 dwShareMode,
    ffi.Pointer<ffi.Void> lpSecurityAttributes,
    ffi.Uint32 dwCreationDisposition,
    ffi.Uint32 dwFlagsAndAttributes,
    ffi.Pointer<ffi.Void> hTemplateFile);
typedef CreateFileWDart = ffi.Pointer<ffi.Void> Function(
    ffi.Pointer<ffi.Uint16> lpFileName,
    int dwDesiredAccess,
    int dwShareMode,
    ffi.Pointer<ffi.Void> lpSecurityAttributes,
    int dwCreationDisposition,
    int dwFlagsAndAttributes,
    ffi.Pointer<ffi.Void> hTemplateFile);
typedef GetLastErrorNative = ffi.Uint32 Function();
typedef GetLastErrorDart = int Function();
typedef CloseHandleNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>);
typedef CloseHandleDart = int Function(ffi.Pointer<ffi.Void>);

void win32Probe(String comName) {
  final kernel32 = ffi.DynamicLibrary.open('kernel32.dll');
  final createFileW = kernel32
      .lookupFunction<CreateFileWNative, CreateFileWDart>('CreateFileW');
  final getLastError =
      kernel32.lookupFunction<GetLastErrorNative, GetLastErrorDart>(
          'GetLastError');
  final closeHandle =
      kernel32.lookupFunction<CloseHandleNative, CloseHandleDart>(
          'CloseHandle');

  for (final flags in [0, 0x40000000 /* FILE_FLAG_OVERLAPPED */]) {
    final name = '\\\\.\\$comName'.toNativeUtf16();
    final h = createFileW(
        name.cast(),
        0x80000000 | 0x40000000 /* GENERIC_READ|GENERIC_WRITE */,
        0,
        ffi.nullptr,
        3 /* OPEN_EXISTING */,
        0x00000080 /* FILE_ATTRIBUTE_NORMAL */ | flags,
        ffi.nullptr);
    final err = getLastError();
    pkgffi.malloc.free(name);
    final ok = h.address != -1 && h.address != 0;
    print(
        '  CreateFileW($comName, overlapped=${flags != 0}) -> ${ok ? "OK handle=0x${h.address.toRadixString(16)}" : "FAIL GetLastError=$err"}');
    if (ok) closeHandle(h);
  }
}

void tryOpen(String name) {
  print('== libserialport 打开 $name ==');
  final port = SerialPort(name);
  print('  description: ${port.description}');
  print('  transport:   ${port.transport}');
  final ok = port.openReadWrite();
  if (ok) {
    print('  openReadWrite: OK');
    port.close();
  } else {
    print('  openReadWrite: FAIL');
    final err = SerialPort.lastError;
    print('  lastError: code=${err?.errorCode} message=${err?.message}');
    // 再试试只读 / 只写
    final okR = port.openRead();
    print('  openRead:  ${okR ? "OK" : "FAIL"}');
    if (okR) port.close();
    final okW = port.openWrite();
    print('  openWrite: ${okW ? "OK" : "FAIL"}');
    if (okW) port.close();
  }
  port.dispose();
}

void main() {
  print('可用串口: ${SerialPort.availablePorts}');
  win32Probe('COM5');
  win32Probe('COM7');
  tryOpen('COM5');
  tryOpen('COM7');
}
