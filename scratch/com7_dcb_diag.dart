// 转储 COM5/COM7 的 DCB 全字段，并逐项试验找出 SetCommState 失败原因
// 运行：dart run scratch/com7_dcb_diag.dart
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

int u32(ffi.Pointer<ffi.Uint8> p, int off) => (p + off).cast<ffi.Uint32>().value;
int u16(ffi.Pointer<ffi.Uint8> p, int off) => (p + off).cast<ffi.Uint16>().value;
int u8(ffi.Pointer<ffi.Uint8> p, int off) => (p + off).value;
void setU32(ffi.Pointer<ffi.Uint8> p, int off, int v) => (p + off).cast<ffi.Uint32>().value = v;
void setU16(ffi.Pointer<ffi.Uint8> p, int off, int v) => (p + off).cast<ffi.Uint16>().value = v;
void setU8(ffi.Pointer<ffi.Uint8> p, int off, int v) => (p + off).value = v;

void dumpDcb(ffi.Pointer<ffi.Uint8> dcb) {
  final flags = u32(dcb, 8);
  print('  DCBlength=${u32(dcb, 0)} BaudRate=${u32(dcb, 4)}');
  print('  flags=0x${flags.toRadixString(16).padLeft(8, '0')}');
  print('    fBinary=${flags & 1} fParity=${(flags >> 1) & 1} fOutxCtsFlow=${(flags >> 2) & 1} '
      'fOutxDsrFlow=${(flags >> 3) & 1} fDtrControl=${(flags >> 4) & 3} fDsrSensitivity=${(flags >> 6) & 1}');
  print('    fTXContinueOnXoff=${(flags >> 7) & 1} fOutX=${(flags >> 8) & 1} fInX=${(flags >> 9) & 1} '
      'fErrorChar=${(flags >> 10) & 1} fNull=${(flags >> 11) & 1} fRtsControl=${(flags >> 12) & 3} '
      'fAbortOnError=${(flags >> 14) & 1} fDummy2=${flags >> 15}');
  print('  XonLim=${u16(dcb, 12)} XoffLim=${u16(dcb, 14)} ByteSize=${u8(dcb, 16)} '
      'Parity=${u8(dcb, 17)} StopBits=${u8(dcb, 18)}');
  print('  XonChar=${u8(dcb, 19)} XoffChar=${u8(dcb, 20)} ErrorChar=${u8(dcb, 21)} '
      'EofChar=${u8(dcb, 22)} EvtChar=${u8(dcb, 23)} wReserved=${u16(dcb, 24)}');
}

void probe(String comName) {
  print('== $comName ==');
  final name = '\\\\.\\$comName'.toNativeUtf16();
  final h = createFileW(name.cast(), 0x80000000 | 0x40000000, 0, ffi.nullptr,
      3, 0x80, ffi.nullptr); // 非 overlapped，排除干扰
  pkgffi.malloc.free(name);
  if (h.address == -1 || h.address == 0) {
    print('  CreateFile FAIL err=${getLastError()}');
    return;
  }

  final dcb = pkgffi.calloc<ffi.Uint8>(128);
  setU32(dcb, 0, 28);
  if (getCommState(h, dcb) == 0) {
    print('  GetCommState FAIL err=${getLastError()}');
    closeHandle(h);
    pkgffi.calloc.free(dcb);
    return;
  }
  print('  [原始 DCB]');
  dumpDcb(dcb);

  // 试验 1：原样写回
  var r = setCommState(h, dcb);
  print('  原样写回: ${r != 0 ? "OK" : "FAIL err=${getLastError()}"}');

  // 试验 2：只改波特率为 9600
  setU32(dcb, 4, 9600);
  r = setCommState(h, dcb);
  print('  改 BaudRate=9600: ${r != 0 ? "OK" : "FAIL err=${getLastError()}"}');

  // 试验 3：9600 + flags 按 libserialport 方式规范化
  var flags = u32(dcb, 8);
  flags |= 1;                 // fBinary = TRUE
  flags &= ~(1 << 6);         // fDsrSensitivity = FALSE
  flags &= ~(1 << 10);        // fErrorChar = FALSE
  flags &= ~(1 << 11);        // fNull = FALSE
  flags &= ~(1 << 14);        // fAbortOnError = FALSE
  setU32(dcb, 8, flags);
  r = setCommState(h, dcb);
  print('  9600 + 规范化 flags: ${r != 0 ? "OK" : "FAIL err=${getLastError()}"}');

  // 试验 4：再清 fDummy2 高位
  setU32(dcb, 8, flags & 0x7FFF);
  r = setCommState(h, dcb);
  print('  上者 + 清 fDummy2: ${r != 0 ? "OK" : "FAIL err=${getLastError()}"}');

  // 试验 5：完整标准配置 9600 8N1 无流控
  setU32(dcb, 4, 9600);
  setU8(dcb, 16, 8);
  setU8(dcb, 17, 0); // NOPARITY
  setU8(dcb, 18, 0); // ONESTOPBIT
  var f = 1;                    // fBinary
  f |= (1 << 4);                // fDtrControl = DTR_CONTROL_ENABLE
  f |= (1 << 12);               // fRtsControl = RTS_CONTROL_ENABLE
  setU32(dcb, 8, f);
  setU16(dcb, 12, 2048);
  setU16(dcb, 14, 512);
  setU8(dcb, 19, 0x11); setU8(dcb, 20, 0x13);
  setU8(dcb, 21, 0); setU8(dcb, 22, 0); setU8(dcb, 23, 0);
  setU16(dcb, 24, 0);
  r = setCommState(h, dcb);
  print('  标准 9600 8N1 无流控: ${r != 0 ? "OK" : "FAIL err=${getLastError()}"}');

  closeHandle(h);
  pkgffi.calloc.free(dcb);
}

void main() {
  probe('COM5');
  probe('COM7');
}
