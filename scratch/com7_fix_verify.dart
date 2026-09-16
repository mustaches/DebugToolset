// 端到端验证修复方案：FFI 预置合法波特率 → libserialport 打开 → 设置 115200 8N1
// 运行：LIBSERIALPORT_PATH=build/windows/x64/runner/Debug/serialport.dll dart run scratch/com7_fix_verify.dart
import 'dart:ffi' as ffi;
import 'dart:typed_data';
import 'package:ffi/ffi.dart' as pkgffi;
import 'package:libserialport/libserialport.dart';

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

bool primePort(String comName, int baudRate) {
  final name = '\\\\.\\$comName'.toNativeUtf16();
  final h = createFileW(name.cast(), 0x80000000 | 0x40000000, 0, ffi.nullptr,
      3, 0x80, ffi.nullptr);
  pkgffi.malloc.free(name);
  if (h.address == -1 || h.address == 0) {
    print('  [primer] CreateFile FAIL err=${getLastError()}');
    return false;
  }
  final dcb = pkgffi.calloc<ffi.Uint8>(128);
  dcb.cast<ffi.Uint32>().value = 28;
  var ok = getCommState(h, dcb) != 0;
  if (ok) {
    final oldBaud = dcb.cast<ffi.Uint32>().elementAt(1).value;
    (dcb.cast<ffi.Uint32>() + 1).value = baudRate;
    ok = setCommState(h, dcb) != 0;
    print('  [primer] baud $oldBaud -> $baudRate: ${ok ? "OK" : "FAIL err=${getLastError()}"}');
  } else {
    print('  [primer] GetCommState FAIL err=${getLastError()}');
  }
  pkgffi.calloc.free(dcb);
  closeHandle(h);
  return ok;
}

void main() {
  // 1) 直接打开（预期失败）
  var port = SerialPort('COM7');
  var ok = port.openReadWrite();
  print('1) 直接 openReadWrite: ${ok ? "OK" : "FAIL"}');
  if (ok) { port.close(); } else {
    // 2) primer 预置 115200
    print('2) primer:');
    final primed = primePort('COM7', 115200);
    // 3) 重试
    ok = port.openReadWrite();
    print('3) primer=${primed} 后 openReadWrite: ${ok ? "OK" : "FAIL"}');
  }
  if (ok) {
    // 4) 设置业务配置 115200 8N1
    try {
      final config = port.config;
      config.baudRate = 115200;
      config.bits = 8;
      config.stopBits = 1;
      config.parity = SerialPortParity.none;
      port.config = config;
      print('4) 设置 115200 8N1: OK (实际 baud=${port.config.baudRate})');
      // 5) 试写
      port.write(Uint8List.fromList([0x55]));
      print('5) write 1 字节: OK');
    } catch (e) {
      print('4/5) 配置或写入异常: $e');
    }
    port.close();
  }
  port.dispose();
  print('完成。');
}
