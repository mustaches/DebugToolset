// CP2105 COM7 失效根因二分探针（一次性脚本），在设备**重新插拔恢复后**
// 运行。两个阶段：
// A) 排除「快速反复 open/close 搞挂驱动」：固定 115200 反复开闭 20 次；
// B) 波特率递增二分：open → set baud → close → 延时 → 重新 open，
//    在哪一档之后 reopen 失败，就说明该档波特率使设备失效。
// 运行：
//   LIBSERIALPORT_PATH=build/windows/x64/runner/Debug/serialport.dll \
//     dart run scratch/serial_probe4.dart
import 'dart:io';
import 'package:libserialport/libserialport.dart';

String lastErr() {
  final err = SerialPort.lastError;
  return 'code=${err?.errorCode} msg=${err?.message}';
}

bool tryOpenOnly(String name) {
  final p = SerialPort(name);
  final ok = p.openReadWrite();
  if (ok) {
    p.close();
  }
  p.dispose();
  return ok;
}

void main() {
  print('--- A) 固定 115200 反复开闭 20 次 ---');
  for (var i = 0; i < 20; i++) {
    final p = SerialPort('COM7');
    if (!p.openReadWrite()) {
      print('  第 ${i + 1} 次 OPEN FAIL ${lastErr()} → 纯开闭即可复现');
      return;
    }
    final cfg = p.config;
    cfg.baudRate = 115200;
    p.config = cfg;
    p.close();
    p.dispose();
    sleep(const Duration(milliseconds: 100));
  }
  print('  20 次开闭全部 OK（排除纯开闭竞态）');

  print('--- B) 波特率递增：set 后 close 再 reopen 验证 ---');
  for (final b in [
    115200, 230400, 460800, 500000, 576000, 768000, 921600, 1000000
  ]) {
    final p = SerialPort('COM7');
    if (!p.openReadWrite()) {
      print('  baud=$b: 本轮 OPEN FAIL ${lastErr()}（上一档已使设备失效）');
      return;
    }
    final cfg = p.config;
    cfg.baudRate = b;
    try {
      p.config = cfg;
    } catch (e) {
      print('  baud=$b: SET FAIL ${lastErr()}');
    }
    p.close();
    p.dispose();
    sleep(const Duration(milliseconds: 500));
    if (!tryOpenOnly('COM7')) {
      print('  baud=$b: set+close 后 REOPEN FAIL ${lastErr()} '
          '→ 该档波特率使设备失效，需重新插拔恢复');
      return;
    }
    print('  baud=$b: set 后 reopen OK');
  }
  print('--- 全部档位通过 ---');
}
