import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:debug_tool_set/providers/network_terminal_state.dart';

void main() {
  group('NetworkTerminalState (TCP loopback)', () {
    late ServerSocket server;
    late NetworkTerminalState state;

    setUp(() async {
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      state = NetworkTerminalState();
      state.updateNetworkConfig('127.0.0.1', server.port);
    });

    tearDown(() async {
      state.toggleConnection(); // 若仍连接则断开
      await server.close();
    });

    test('连接 echo 服务器后发送并收到数据', () async {
      final echoed = Completer<void>();
      server.listen((client) {
        client.listen(client.add); // echo
      });

      state.toggleConnection();
      // 等待连接建立
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!state.isConnected && DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(milliseconds: 20));
      }
      expect(state.isConnected, isTrue);

      state.addListener(() {
        final log = state.rawDataLog;
        if (log.any((l) => l.content.contains('hello')) && !echoed.isCompleted) {
          echoed.complete();
        }
      });

      state.sendCommand('hello', eolMode: 'LF');
      await echoed.future.timeout(const Duration(seconds: 5));

      expect(state.rawDataLog.any((l) => l.content.contains('hello')), isTrue);
      // 回显也应出现在系统日志提示已连接
      expect(state.systemLog.any((l) => l.content.contains('Connected')), isTrue);
    });

    test('Hex 发送字节正确', () async {
      final received = Completer<List<int>>();
      server.listen((client) {
        client.listen((data) {
          if (!received.isCompleted) received.complete(data);
        });
      });

      state.toggleConnection();
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!state.isConnected && DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(milliseconds: 20));
      }
      expect(state.isConnected, isTrue);

      state.sendCommand('01 AB FF', isHex: true);
      final data = await received.future.timeout(const Duration(seconds: 5));
      expect(data, equals([0x01, 0xAB, 0xFF]));
    });

    test('未连接时发送仅记日志', () {
      state.sendData([1, 2, 3]);
      expect(state.systemLog.any((l) => l.content.contains('未连接')), isTrue);
    });

    test('未连接时切换协议端口跟随默认值', () {
      final fresh = NetworkTerminalState();
      expect(fresh.protocol, NetworkProtocol.tcp);
      fresh.setProtocol(NetworkProtocol.ssh);
      expect(fresh.port, 22);
      fresh.setProtocol(NetworkProtocol.tcp);
      expect(fresh.port, 8080);
    });
  });
}
