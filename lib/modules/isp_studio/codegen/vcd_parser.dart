/// 极简 VCD（Value Change Dump）解析：为「仿真波形」标签页服务。
///
/// 覆盖 Icarus Verilog `$dumpvars` 产物的常用子集：$var 声明（wire/reg/
/// integer/parameter，标量与总线）、$scope/$upscope 层级、#时间戳、
/// 标量变化（`0!`/`1!`/`x!`/`z!`）与总线变化（`b0101 $`）。real 型与
/// 强度信息忽略。纯 Dart 无 Flutter 依赖。
library;

import 'dart:convert';

/// 单次取值变化。[bits] 标量为单字符（0/1/x/z），总线为 0/1/x/z 组成的
/// 位串（高位在前，与 VCD 原文一致）。
class VcdChange {
  final int time;
  final String bits;

  const VcdChange(this.time, this.bits);
}

class VcdSignal {
  /// 层级全路径（如 tb_isp_ip_multi_band_eq.clk）。
  final String path;

  /// 短名（如 clk）。
  final String name;
  final String id;
  final int width;
  final String vcdType; // wire / reg / integer / parameter ...
  final List<VcdChange> changes = [];

  VcdSignal({
    required this.path,
    required this.name,
    required this.id,
    required this.width,
    required this.vcdType,
  });

  bool get isBus => width > 1;
}

/// VCD scope 层级节点（$scope/$upscope 还原的模块树）。
class VcdScope {
  final String name;
  final VcdScope? parent;
  final List<VcdScope> children = [];
  final List<VcdSignal> signals = [];

  VcdScope(this.name, this.parent);

  String get path =>
      parent == null || parent!.path.isEmpty ? name : '${parent!.path}.$name';
}

class VcdFile {
  /// 时间戳单位（皮秒）。`$timescale 1ps` → 1。
  final int timescalePs;
  final List<VcdSignal> signals;
  final int endTime;

  /// scope 层级树根（无名的虚拟根，其子节点为顶层模块）。
  final VcdScope root;

  const VcdFile({
    required this.timescalePs,
    required this.signals,
    required this.endTime,
    required this.root,
  });

  /// 顶层 scope（testbench）下的非 parameter 信号，按声明顺序。
  List<VcdSignal> topScopeSignals({bool includeParameters = false}) {
    final top = signals.isEmpty ? '' : signals.first.path.split('.').first;
    return [
      for (final s in signals)
        if (s.path.split('.').length == 2 &&
            s.path.split('.').first == top &&
            (includeParameters || s.vcdType != 'parameter'))
          s,
    ];
  }
}

/// 解析 VCD 文本。宽容策略：不识别的行直接跳过。
/// 注意 VCD 的别名机制：不同层级中指向同一网络的信号共用同一 id 编码
///（如 tb.clk 与 dut.clk），值变化要追加到所有同名 id 的信号上。
VcdFile parseVcd(String text) {
  final idToSignals = <String, List<VcdSignal>>{};
  final signals = <VcdSignal>[];
  final root = VcdScope('', null);
  final scopeStack = <VcdScope>[root];
  int timescalePs = 1;
  int time = 0;
  bool inDefs = true;

  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (inDefs) {
      if (line.startsWith('\$timescale')) {
        // 形如 "$timescale 1ps $end"（也可能单位独占下一行，这里合并处理常见单行形态）。
        final m = RegExp(r'(\d+)\s*(fs|ps|ns|us|ms|s)').firstMatch(line);
        if (m != null) {
          final v = int.parse(m.group(1)!);
          const unit = {'fs': 0.001, 'ps': 1, 'ns': 1000, 'us': 1e6, 'ms': 1e9, 's': 1e12};
          timescalePs = (v * unit[m.group(2)]!).round();
        }
      } else if (line.startsWith('\$scope')) {
        // $scope module tb_xxx $end
        final parts = line.split(RegExp(r'\s+'));
        if (parts.length >= 3) {
          final child = VcdScope(parts[2], scopeStack.last);
          scopeStack.last.children.add(child);
          scopeStack.add(child);
        }
      } else if (line.startsWith('\$upscope')) {
        if (scopeStack.length > 1) scopeStack.removeLast();
      } else if (line.startsWith('\$var')) {
        // $var wire 24 $ out_data [23:0] $end
        final parts = line.split(RegExp(r'\s+'));
        if (parts.length >= 5) {
          final type = parts[1];
          final width = int.tryParse(parts[2]) ?? 1;
          final id = parts[3];
          final name = parts[4];
          final scope = scopeStack.last;
          final path = scope.path.isEmpty ? name : '${scope.path}.$name';
          final sig = VcdSignal(
              path: path, name: name, id: id, width: width, vcdType: type);
          idToSignals.putIfAbsent(id, () => []).add(sig);
          signals.add(sig);
          scope.signals.add(sig);
        }
      } else if (line.startsWith('\$enddefinitions')) {
        inDefs = false;
      }
      continue;
    }
    // 值变化区
    final c = line[0];
    if (c == '#') {
      time = int.tryParse(line.substring(1)) ?? time;
    } else if (c == '0' || c == '1' || c == 'x' || c == 'X' || c == 'z' || c == 'Z') {
      // 标量：值字符 + id（无空格）
      final id = line.substring(1);
      for (final s in idToSignals[id] ?? const <VcdSignal>[]) {
        s.changes.add(VcdChange(time, c.toLowerCase()));
      }
    } else if (c == 'b' || c == 'B') {
      // 总线：b<位串> <id>
      final sp = line.indexOf(' ');
      if (sp > 1) {
        final bits = line.substring(1, sp).toLowerCase();
        final id = line.substring(sp + 1).trim();
        for (final s in idToSignals[id] ?? const <VcdSignal>[]) {
          s.changes.add(VcdChange(time, bits));
        }
      }
    }
    // r/R（real）、s（强度）等忽略
  }

  int end = 0;
  for (final s in signals) {
    if (s.changes.isNotEmpty && s.changes.last.time > end) {
      end = s.changes.last.time;
    }
  }
  return VcdFile(
      timescalePs: timescalePs, signals: signals, endTime: end, root: root);
}

/// 查询某信号在 [time] 时刻的取值（changes 按时间有序，二分查找）。
String valueAt(VcdSignal sig, int time) {
  final changes = sig.changes;
  if (changes.isEmpty) return sig.isBus ? 'x' * sig.width : 'x';
  var lo = 0, hi = changes.length - 1, ans = 0;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    if (changes[mid].time <= time) {
      ans = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return changes[ans].bits;
}

/// 位串 → 十六进制显示（含 x/z 时整体显示 x/z…与 0/1 混合逐位翻译：
/// 每 4 位为一组，组内含 x 显示 x、含 z 显示 z）。
String bitsToHex(String bits) {
  final padded = bits.padLeft((bits.length + 3) ~/ 4 * 4, '0');
  final out = StringBuffer();
  for (var i = 0; i < padded.length; i += 4) {
    final nib = padded.substring(i, i + 4);
    if (nib.contains('x')) {
      out.write('x');
    } else if (nib.contains('z')) {
      out.write('z');
    } else {
      out.write(int.parse(nib, radix: 2).toRadixString(16));
    }
  }
  return out.toString();
}
