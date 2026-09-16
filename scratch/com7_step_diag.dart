// 逐步复现 libserialport sp_open 的 Win32 调用序列，定位 COM7 失败环节
// 运行：dart run scratch/com7_step_diag.dart
import 'dart:ffi' as ffi;
import 'package:ffi/ffi.dart' as pkgffi;

final kernel32 = ffi.DynamicLibrary.open('kernel32.dll');

// ---- native 签名 ----
typedef NCreateFileW = ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Uint16>,
    ffi.Uint32, ffi.Uint32, ffi.Pointer<ffi.Void>, ffi.Uint32, ffi.Uint32, ffi.Pointer<ffi.Void>);
typedef NGetLastError = ffi.Uint32 Function();
typedef NCloseHandle = ffi.Int32 Function(ffi.Pointer<ffi.Void>);
typedef NSetCommTimeouts = ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint32>);
typedef NCreateEventW = ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>, ffi.Int32, ffi.Int32, ffi.Pointer<ffi.Uint16>);
typedef NSetCommMask = ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Uint32);
typedef NWaitCommEvent = ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint32>, ffi.Pointer<ffi.Uint8>);
typedef NCommState = ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>);
typedef NCancelIo = ffi.Int32 Function(ffi.Pointer<ffi.Void>);

// ---- Dart 签名 ----
typedef DCreateFileW = ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Uint16>,
    int, int, ffi.Pointer<ffi.Void>, int, int, ffi.Pointer<ffi.Void>);
typedef DGetLastError = int Function();
typedef DCloseHandle = int Function(ffi.Pointer<ffi.Void>);
typedef DSetCommTimeouts = int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint32>);
typedef DCreateEventW = ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>, int, int, ffi.Pointer<ffi.Uint16>);
typedef DSetCommMask = int Function(ffi.Pointer<ffi.Void>, int);
typedef DWaitCommEvent = int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint32>, ffi.Pointer<ffi.Uint8>);
typedef DCommState = int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>);
typedef DCancelIo = int Function(ffi.Pointer<ffi.Void>);

final createFileW = kernel32.lookupFunction<NCreateFileW, DCreateFileW>('CreateFileW');
final getLastError = kernel32.lookupFunction<NGetLastError, DGetLastError>('GetLastError');
final closeHandle = kernel32.lookupFunction<NCloseHandle, DCloseHandle>('CloseHandle');
final setCommTimeouts = kernel32.lookupFunction<NSetCommTimeouts, DSetCommTimeouts>('SetCommTimeouts');
final createEventW = kernel32.lookupFunction<NCreateEventW, DCreateEventW>('CreateEventW');
final setCommMask = kernel32.lookupFunction<NSetCommMask, DSetCommMask>('SetCommMask');
final waitCommEvent = kernel32.lookupFunction<NWaitCommEvent, DWaitCommEvent>('WaitCommEvent');
final getCommState = kernel32.lookupFunction<NCommState, DCommState>('GetCommState');
final setCommState = kernel32.lookupFunction<NCommState, DCommState>('SetCommState');
final cancelIo = kernel32.lookupFunction<NCancelIo, DCancelIo>('CancelIo');

String err() => 'err=${getLastError()}';

void probe(String comName) {
  print('== $comName ==');
  final name = '\\\\.\\$comName'.toNativeUtf16();
  final h = createFileW(name.cast(), 0x80000000 | 0x40000000, 0, ffi.nullptr,
      3, 0x80 | 0x40000000, ffi.nullptr);
  pkgffi.malloc.free(name);
  if (h.address == -1 || h.address == 0) {
    print('  CreateFile FAIL ${err()}');
    return;
  }
  print('  CreateFile OK');

  final timeouts = pkgffi.calloc<ffi.Uint32>(5); // COMMTIMEOUTS 全 0
  var r = setCommTimeouts(h, timeouts);
  print('  SetCommTimeouts: ${r != 0 ? "OK" : "FAIL ${err()}"}');
  pkgffi.calloc.free(timeouts);

  final evt = createEventW(ffi.nullptr, 1, 1, ffi.nullptr);
  print('  CreateEvent: ${evt.address != 0 && evt.address != -1 ? "OK" : "FAIL ${err()}"}');

  r = setCommMask(h, 0x0001 | 0x0080); // EV_RXCHAR | EV_ERR
  print('  SetCommMask(EV_RXCHAR|EV_ERR): ${r != 0 ? "OK" : "FAIL ${err()}"}');

  // OVERLAPPED: Internal, InternalHigh, Offset, OffsetHigh, hEvent (x64: 32 字节)
  final ovl = pkgffi.calloc<ffi.Uint8>(32);
  ovl.cast<ffi.Pointer<ffi.Void>>().elementAt(3).value = evt;
  final events = pkgffi.calloc<ffi.Uint32>();
  r = waitCommEvent(h, events, ovl);
  final werr = getLastError();
  print('  WaitCommEvent: ${r != 0 ? "OK(立即返回 events=0x${events.value.toRadixString(16)})" : (werr == 997 ? "PENDING(正常)" : "FAIL err=$werr")}');

  // DCB: DCBlength 在偏移 0，BaudRate 偏移 4
  final dcb = pkgffi.calloc<ffi.Uint8>(128);
  dcb.cast<ffi.Uint32>().value = 28; // sizeof(DCB)
  r = getCommState(h, dcb);
  final baud = dcb.cast<ffi.Uint32>().elementAt(1).value;
  print('  GetCommState: ${r != 0 ? "OK baud=$baud" : "FAIL ${err()}"}');
  if (r != 0) {
    r = setCommState(h, dcb);
    print('  SetCommState: ${r != 0 ? "OK" : "FAIL ${err()}"}');
  }

  cancelIo(h);
  closeHandle(evt);
  closeHandle(h);
  pkgffi.calloc.free(events);
  pkgffi.calloc.free(ovl);
  pkgffi.calloc.free(dcb);
}

void main() {
  probe('COM5');
  probe('COM7');
}
