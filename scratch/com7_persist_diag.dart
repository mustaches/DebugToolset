// 验证 CP2105 Standard 口的波特率设置在 CloseHandle 后是否保持
// 运行：dart run scratch/com7_persist_diag.dart
import 'dart:ffi' as ffi;
import 'package:ffi/ffi.dart' as pkgffi;

final kernel32 = ffi.DynamicLibrary.open('kernel32.dll');

typedef NCreateFileW = ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Uint16>,
    ffi.Uint32, ffi.Uint32, ffi.Pointer<ffi.Void>, ffi.Uint32, ffi.Uint32, ffi.Pointer<ffi.Void>);
typedef DCreateFileW = ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Uint16>,
    int, int, ffi.Pointer<ffi.Void>, int, int, ffi.Pointer<ffi.Void>);
typedef NGetLastError = ffi.Uint32 Function();
typedef DGetLastError = int Function();
typedef NCloseHandle = ffi.Int32 Function(ffi.Pointer<ffi.Void>);
typedef DCloseHandle = int Function(ffi.Pointer<ffi.Void>);
typedef NCommState = ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>);
typedef DCommState = int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>);

final createFileW = kernel32.lookupFunction<NCreateFileW, DCreateFileW>('CreateFileW');
final getLastError = kernel32.lookupFunction<NGetLastError, DGetLastError>('GetLastError');
final closeHandle = kernel32.lookupFunction<NCloseHandle, DCloseHandle>('CloseHandle');
final getCommState = kernel32.lookupFunction<NCommState, DCommState>('GetCommState');
final setCommState = kernel32.lookupFunction<NCommState, DCommState>('SetCommState');

void setU32(ffi.Pointer<ffi.Uint8> p, int off, int v) => (p + off).cast<ffi.Uint32>().value = v;
int u32(ffi.Pointer<ffi.Uint8> p, int off) => (p + off).cast<ffi.Uint32>().value;

ffi.Pointer<ffi.Void> openPort(String comName) {
  final name = '\\\\.\\$comName'.toNativeUtf16();
  final h = createFileW(name.cast(), 0x80000000 | 0x40000000, 0, ffi.nullptr,
      3, 0x80, ffi.nullptr);
  pkgffi.malloc.free(name);
  return h;
}

int? readBaud(ffi.Pointer<ffi.Void> h) {
  final dcb = pkgffi.calloc<ffi.Uint8>(128);
  setU32(dcb, 0, 28);
  if (getCommState(h, dcb) == 0) {
    print('  GetCommState FAIL err=${getLastError()}');
    pkgffi.calloc.free(dcb);
    return null;
  }
  final baud = u32(dcb, 4);
  pkgffi.calloc.free(dcb);
  return baud;
}

void main() {
  print('1) 初始 baud = ${readBaud(openPort('COM7'))}');
  // 打开并设为 9600 后关闭
  var h = openPort('COM7');
  final dcb = pkgffi.calloc<ffi.Uint8>(128);
  setU32(dcb, 0, 28);
  getCommState(h, dcb);
  setU32(dcb, 4, 9600);
  final r = setCommState(h, dcb);
  print('2) SetCommState(9600): ${r != 0 ? "OK" : "FAIL err=${getLastError()}"}');
  pkgffi.calloc.free(dcb);
  closeHandle(h);
  // 重新打开读 baud
  h = openPort('COM7');
  print('3) 关闭重开后 baud = ${readBaud(h)}');
  closeHandle(h);
}
