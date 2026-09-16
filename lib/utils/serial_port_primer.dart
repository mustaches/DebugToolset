import 'dart:ffi' as ffi;
import 'dart:io' show Platform;
import 'dart:typed_data' show Uint8List;

import 'package:ffi/ffi.dart' as pkgffi;
import 'package:flutter_libserialport/flutter_libserialport.dart';

// CP2105 等双口 USB 串口芯片的 Standard 口（第二口）驱动默认波特率为 1200，
// 但该口实际拒绝 1200，libserialport 打开端口时内部 SetCommState 失败
// （ERROR_GEN_FAILURE）导致 openReadWrite() 返回 false。
// 这里在打开失败时先用 Win32 API 把端口波特率预置为合法值（驱动会记住该设置），
// 再重试打开。仅 Windows 有效，其余平台直接返回 false。

typedef _NCreateFileW = ffi.Pointer<ffi.Void> Function(
    ffi.Pointer<ffi.Uint16>,
    ffi.Uint32,
    ffi.Uint32,
    ffi.Pointer<ffi.Void>,
    ffi.Uint32,
    ffi.Uint32,
    ffi.Pointer<ffi.Void>);
typedef _DCreateFileW = ffi.Pointer<ffi.Void> Function(
    ffi.Pointer<ffi.Uint16>, int, int, ffi.Pointer<ffi.Void>, int, int, ffi.Pointer<ffi.Void>);
typedef _NCloseHandle = ffi.Int32 Function(ffi.Pointer<ffi.Void>);
typedef _DCloseHandle = int Function(ffi.Pointer<ffi.Void>);
typedef _NCommState = ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>);
typedef _DCommState = int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>);
typedef _NFormatMessageW = ffi.Uint32 Function(ffi.Uint32, ffi.Pointer<ffi.Void>,
    ffi.Uint32, ffi.Uint32, ffi.Pointer<ffi.Uint16>, ffi.Uint32, ffi.Pointer<ffi.Void>);
typedef _DFormatMessageW = int Function(int, ffi.Pointer<ffi.Void>, int, int,
    ffi.Pointer<ffi.Uint16>, int, ffi.Pointer<ffi.Void>);

typedef _NGetLastError = ffi.Uint32 Function();
typedef _DGetLastError = int Function();
typedef _NMbToWide = ffi.Int32 Function(ffi.Uint32, ffi.Uint32,
    ffi.Pointer<ffi.Uint8>, ffi.Int32, ffi.Pointer<ffi.Uint16>, ffi.Int32);
typedef _DMbToWide = int Function(int, int, ffi.Pointer<ffi.Uint8>, int,
    ffi.Pointer<ffi.Uint16>, int);

final ffi.DynamicLibrary _kernel32 = ffi.DynamicLibrary.open('kernel32.dll');
final _createFileW = _kernel32.lookupFunction<_NCreateFileW, _DCreateFileW>('CreateFileW');
final _closeHandle = _kernel32.lookupFunction<_NCloseHandle, _DCloseHandle>('CloseHandle');
final _getLastError = _kernel32.lookupFunction<_NGetLastError, _DGetLastError>('GetLastError');

bool _ffiWarmedUp = false;

/// 函数级 FFI 首次调用会触发 trampoline 解析，期间的 VM 工作会把线程
/// last-error 清 0，导致紧跟失败调用的 GetLastError 读到假值（code=0）。
/// 用一次无害的 CreateFileW+GetLastError 调用对提前完成预热。
void _warmUpFfi() {
  if (_ffiWarmedUp) return;
  _ffiWarmedUp = true;
  _getLastError();
  final name = '\\\\.\\__warmup_nonexistent__'.toNativeUtf16();
  final handle = _createFileW(
      name.cast(), 0, 0, ffi.nullptr, 3, 0x80, ffi.nullptr);
  _getLastError();
  pkgffi.malloc.free(name);
  if (handle.address != -1 && handle.address != 0) _closeHandle(handle);
}
final _getCommState = _kernel32.lookupFunction<_NCommState, _DCommState>('GetCommState');
final _setCommState = _kernel32.lookupFunction<_NCommState, _DCommState>('SetCommState');
final _formatMessageW =
    _kernel32.lookupFunction<_NFormatMessageW, _DFormatMessageW>('FormatMessageW');
final _mbToWide = _kernel32.lookupFunction<_NMbToWide, _DMbToWide>('MultiByteToWideChar');

/// 修复 libserialport ANSI 错误消息的乱码。
/// sp_last_error_message 走 ANSI 版 FormatMessageA，中文系统下返回 GBK 字节，
/// Dart 侧按 Latin-1 逐字节解码成乱码（每个字符即一个原始字节，如
/// "²Ù×÷³É¹¦Íê³É¡£" 实为「操作成功完成。」）。这里把字符低 8 位还原为字节流，
/// 再用 MultiByteToWideChar(CP_ACP) 正确转回 Unicode。
/// 已是正常 Unicode（含 >0xFF 字符）、纯 ASCII、非法 GBK 序列（避免误伤正常
/// Latin-1 文本）或非 Windows 平台时原样返回。
String repairAnsiMojibake(String text) {
  if (!Platform.isWindows || text.isEmpty) return text;

  final bytes = Uint8List(text.length);
  var hasHighByte = false;
  for (var i = 0; i < text.length; i++) {
    final c = text.codeUnitAt(i);
    if (c > 0xFF) return text; // 已是正常 Unicode，无需修复
    if (c >= 0x80) hasHighByte = true;
    bytes[i] = c;
  }
  if (!hasHighByte) return text;

  const mbErrInvalidChars = 0x00000008;
  final inBuf = pkgffi.calloc<ffi.Uint8>(bytes.length);
  inBuf.asTypedList(bytes.length).setAll(0, bytes);
  final need = _mbToWide(0, mbErrInvalidChars, inBuf, bytes.length,
      ffi.nullptr.cast<ffi.Uint16>(), 0);
  if (need <= 0) {
    pkgffi.calloc.free(inBuf);
    return text;
  }
  final outBuf = pkgffi.calloc<ffi.Uint16>(need);
  final got = _mbToWide(0, mbErrInvalidChars, inBuf, bytes.length, outBuf, need);
  pkgffi.calloc.free(inBuf);
  if (got <= 0) {
    pkgffi.calloc.free(outBuf);
    return text;
  }
  final repaired = outBuf.cast<pkgffi.Utf16>().toDartString(length: got);
  pkgffi.calloc.free(outBuf);
  return repaired;
}

/// 把串口相关异常格式化为无乱码的日志文本。
/// - errno > 0：直接用 FormatMessageW 取宽字符系统描述（无视可能乱码的 message）
/// - errno = 0：libserialport 读到的是残留 GetLastError()==0，其 message 恒为
///   「操作成功完成」的误报，替换为更有意义的说明
/// - 其他异常：修复其中可能存在的 ANSI 乱码后原样输出
String describeSerialError(Object error) {
  if (error is SerialPortError) {
    if (error.errorCode > 0) {
      final msg = win32ErrorMessage(error.errorCode);
      if (msg != null) {
        return 'SerialPortError: $msg, errno = ${error.errorCode}';
      }
    } else if (error.errorCode == 0) {
      return 'SerialPortError: 系统未记录具体错误（设备可能已被拔出）, errno = 0';
    }
  }
  return repairAnsiMojibake('$error');
}

/// 用 Win32 FormatMessageW 取 [errorCode] 的系统错误描述（UTF-16，无乱码）。
/// libserialport 的 sp_last_error_message 走的是 ANSI 版 FormatMessageA，
/// 中文系统下返回 GBK 字节，被当作 Latin-1 解码后出现乱码，故在此重新获取。
/// 非 Windows 平台或查询失败返回 null。
String? win32ErrorMessage(int errorCode) {
  if (!Platform.isWindows) return null;

  const flags = 0x00001000 | 0x00000200; // FROM_SYSTEM | IGNORE_INSERTS
  final buffer = pkgffi.calloc<ffi.Uint16>(512);
  final len =
      _formatMessageW(flags, ffi.nullptr, errorCode, 0, buffer, 512, ffi.nullptr);
  if (len == 0) {
    pkgffi.calloc.free(buffer);
    return null;
  }
  final message = buffer.cast<pkgffi.Utf16>().toDartString(length: len).trimRight();
  pkgffi.calloc.free(buffer);
  return message;
}

/// 探测以读写独占方式打开 [portName] 的结果，失败时返回紧跟 CreateFileW
/// 取得的 OS 错误码（如 5 = 拒绝访问/端口被占用，2 = 端口不存在）。
/// 打开成功（说明端口本身可开，libserialport 失败另有原因，如 CP2105 配置
/// 问题）或非 Windows 平台返回 null。
///
/// libserialport 的 sp_last_error_code() 在 Windows 上返回的是读取那一刻的
/// GetLastError()，容易被失败后的其他系统调用覆盖（曾误报 code=0），
/// 因此打开失败时用本函数立即探测，错误码才可靠。
int? probeSerialPortError(String portName) {
  if (!Platform.isWindows) return null;
  _warmUpFfi();

  final name = '\\\\.\\$portName'.toNativeUtf16();
  final handle = _createFileW(
    name.cast(),
    0x80000000 | 0x40000000, // GENERIC_READ | GENERIC_WRITE
    0,
    ffi.nullptr,
    3, // OPEN_EXISTING
    0x80, // FILE_ATTRIBUTE_NORMAL
    ffi.nullptr,
  );
  // 必须在任何其他 FFI 调用（含 malloc.free）之前取错误码，否则可能被覆盖
  final error = _getLastError();
  pkgffi.malloc.free(name);
  if (handle.address == -1 || handle.address == 0) {
    return error;
  }
  _closeHandle(handle);
  return null;
}

/// 用 Win32 API 将 [portName]（如 "COM7"）的波特率预置为 [baudRate]。
/// 返回是否预置成功；非 Windows 平台或任意一步失败返回 false。
bool primeSerialPortBaudRate(String portName, int baudRate) {
  if (!Platform.isWindows) return false;

  final name = '\\\\.\\$portName'.toNativeUtf16();
  final handle = _createFileW(
    name.cast(),
    0x80000000 | 0x40000000, // GENERIC_READ | GENERIC_WRITE
    0,
    ffi.nullptr,
    3, // OPEN_EXISTING
    0x80, // FILE_ATTRIBUTE_NORMAL
    ffi.nullptr,
  );
  pkgffi.malloc.free(name);
  if (handle.address == -1 || handle.address == 0) return false;

  // DCB 结构 28 字节：偏移 0 = DCBlength，偏移 4 = BaudRate
  final dcb = pkgffi.calloc<ffi.Uint8>(128);
  dcb.cast<ffi.Uint32>().value = 28;
  var ok = _getCommState(handle, dcb) != 0;
  if (ok) {
    (dcb.cast<ffi.Uint32>() + 1).value = baudRate;
    ok = _setCommState(handle, dcb) != 0;
  }
  pkgffi.calloc.free(dcb);
  _closeHandle(handle);
  return ok;
}
