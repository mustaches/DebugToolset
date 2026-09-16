// CP2105 双口复现探针（一次性脚本）：用应用同源的 serialport.dll
// 1) 同进程同时打开 COM5+COM7（两个方向）
// 2) COM7 波特率/数据位/校验位扫描，找驱动不支持的组合
// 运行：
//   LIBSERIALPORT_PATH=build/windows/x64/runner/Debug/serialport.dll \
//     dart run scratch/serial_probe2.dart
import 'package:libserialport/libserialport.dart';

void tryOpen(String name, {bool hold = false, List<SerialPort>? holdList}) {
  final p = SerialPort(name);
  final ok = p.openReadWrite();
  if (!ok) {
    final err = SerialPort.lastError;
    print('  $name openReadWrite FAIL: code=${err?.errorCode} '
        'msg=${err?.message}');
    p.dispose();
    return;
  }
  print('  $name openReadWrite OK');
  if (hold) {
    holdList?.add(p);
  } else {
    p.close();
    p.dispose();
  }
}

void setBaud(String name, int baud) {
  final p = SerialPort(name);
  if (!p.openReadWrite()) {
    print('  $name baud=$baud: open FAIL');
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
    // 读回确认
    final rb = p.config.baudRate;
    print('  $name baud=$baud: set OK (readback=$rb)');
  } catch (e) {
    final err = SerialPort.lastError;
    print('  $name baud=$baud: set FAIL $e lastError=${err?.message}');
  }
  p.close();
  p.dispose();
}

void main() {
  print('--- 同进程同时打开 ---');
  final held = <SerialPort>[];
  print('先开 COM5 再开 COM7（保持 COM5 不关）:');
  tryOpen('COM5', hold: true, holdList: held);
  tryOpen('COM7', hold: true, holdList: held);
  for (final p in held) {
    p.close();
    p.dispose();
  }
  held.clear();
  print('先开 COM7 再开 COM5（保持 COM7 不关）:');
  tryOpen('COM7', hold: true, holdList: held);
  tryOpen('COM5', hold: true, holdList: held);
  for (final p in held) {
    p.close();
    p.dispose();
  }

  print('--- COM7 波特率扫描 ---');
  for (final b in [
    9600, 57600, 115200, 230400, 460800, 500000, 576000, 921600,
    1000000, 1500000, 2000000, 3000000
  ]) {
    setBaud('COM7', b);
  }
  print('--- COM5 波特率扫描（对照） ---');
  for (final b in [115200, 921600, 1500000, 2000000, 3000000]) {
    setBaud('COM5', b);
  }
}
