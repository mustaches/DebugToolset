// CP2105 COM7 高波特率失败细节探针（一次性脚本）：
// 1) 先确认 COM7 当前可正常打开（状态是否恢复）
// 2) 逐个波特率：open → set baud → close，每步打印 lastError，
//    步间延时排除快速 reopen 竞态
// 3) 高波特率失败后，再次测试普通波特率能否打开（状态是否卡住）
// 运行：
//   LIBSERIALPORT_PATH=build/windows/x64/runner/Debug/serialport.dll \
//     dart run scratch/serial_probe3.dart
import 'dart:io';
import 'package:libserialport/libserialport.dart';

String lastErr() {
  final err = SerialPort.lastError;
  return 'code=${err?.errorCode} msg=${err?.message}';
}

void test(String name, int baud) {
  final p = SerialPort(name);
  if (!p.openReadWrite()) {
    print('  $name baud=$baud: OPEN FAIL ${lastErr()}');
    p.dispose();
    return;
  }
  final cfg = p.config;
  cfg.baudRate = baud;
  cfg.bits = 8;
  cfg.stopBits = 1;
  cfg.parity = SerialPortParity.none;
  try {
    p.config = cfg;
    print('  $name baud=$baud: open+set OK (readback=${p.config.baudRate})');
  } catch (e) {
    print('  $name baud=$baud: open OK, SET FAIL ${lastErr()} ($e)');
  }
  p.close();
  p.dispose();
  sleep(const Duration(milliseconds: 300));
}

void main() {
  print('--- 当前状态确认 ---');
  test('COM7', 115200);
  print('--- 高波特率逐个测试（步间 300ms） ---');
  for (final b in [576000, 921600, 1000000]) {
    test('COM7', b);
  }
  print('--- 失败后普通波特率是否仍可用 ---');
  test('COM7', 115200);
  test('COM5', 921600); // 对照：Enhanced 口
  test('COM5', 115200);
}
