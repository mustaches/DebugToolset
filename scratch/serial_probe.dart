// 串口打开失败诊断探针（一次性脚本）：用应用同源的 libserialport
//（LIBSERIALPORT_PATH 指向应用打包的 serialport.dll）枚举并逐一打开
// 系统中所有 COM 口，打印 open 失败时的 lastError 与配置写入结果。
// 运行：
//   LIBSERIALPORT_PATH=build/windows/x64/runner/Debug/serialport.dll \
//     dart run scratch/serial_probe.dart
import 'package:libserialport/libserialport.dart';

void main() {
  print('availablePorts: ${SerialPort.availablePorts}');
  for (final name in SerialPort.availablePorts) {
    final p = SerialPort(name);
    print('== $name desc=${p.description} manufacturer=${p.manufacturer} '
        'serial=${p.serialNumber} vid=${p.vendorId} pid=${p.productId} '
        'bus=${p.busNumber} dev=${p.deviceNumber}');
    final ok = p.openReadWrite();
    if (!ok) {
      final err = SerialPort.lastError;
      print('   openReadWrite FAIL: code=${err?.errorCode} '
          'msg=${err?.message}');
      // 对照：只读打开是否可行
      final ok2 = p.openRead();
      final err2 = SerialPort.lastError;
      print('   openRead ${ok2 ? 'OK' : 'FAIL'}: code=${err2?.errorCode} '
          'msg=${err2?.message}');
      if (ok2) p.close();
      p.dispose();
      continue;
    }
    print('   openReadWrite OK');
    final cfg = p.config;
    cfg.baudRate = 115200;
    cfg.bits = 8;
    cfg.stopBits = 1;
    cfg.parity = SerialPortParity.none;
    try {
      p.config = cfg;
      print('   set config OK (115200 8N1)');
    } catch (e) {
      final err = SerialPort.lastError;
      print('   set config FAIL: $e; lastError code=${err?.errorCode} '
          'msg=${err?.message}');
    }
    p.close();
    p.dispose();
  }
}
