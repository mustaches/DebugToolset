/// Python IQA 桥接进程（tools/iqa/iqa_bridge.py）的 Dart 侧封装：
/// 为深度评价节点（LPIPS / DISTS / FID / KID / MUSIQ / CLIPIQA）提供
/// 计算后端。这些指标依赖 torch 深度模型，无法在 Dart 内实现，故通过
/// 常驻子进程 + stdin/stdout JSON 行协议调用（协议见 iqa_bridge.py
/// 文件头注释）。
///
/// 一指标一进程（模型常驻内存，避免每帧数秒的 torch 导入与模型加载），
/// 请求按协议串行（单在途）。FID/KID 为分布级指标：帧逐次 [distAdd]
/// 累计特征，[distScore] 出分，[distReset] 清空（状态侧按运行轮次
/// 复位，见 isp_studio_state.dart）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'exporters.dart';

/// 深度评价指标元信息（与 iqa_bridge.py 的 META 对应）。
class PyIqaMetricInfo {
  const PyIqaMetricInfo(this.kind, this.lowerBetter);

  /// 'pair'（双输入：LPIPS/DISTS）| 'single'（无参考单输入：MUSIQ/
  /// CLIPIQA）| 'dist'（分布级双输入：FID/KID，逐帧累计）。
  final String kind;
  final bool lowerBetter;
}

/// 支持的深度评价指标（typeId → 元信息）。
const pyIqaMetrics = <String, PyIqaMetricInfo>{
  'lpips': PyIqaMetricInfo('pair', true),
  'dists': PyIqaMetricInfo('pair', true),
  'fid': PyIqaMetricInfo('dist', true),
  'kid': PyIqaMetricInfo('dist', true),
  'musiq': PyIqaMetricInfo('single', false),
  'clipiqa': PyIqaMetricInfo('single', false),
};

/// Python 解释器路径（相对工作目录，与应用其他数据目录同口径）。
/// 需要安装 torch/torchmetrics/lpips/pyiqa 的环境；不存在时
/// [PyIqaWorker.available] 为 false，节点显示不可用提示。
String pyIqaPythonPath = 'scratch/eval_venv/Scripts/python.exe';

/// 桥接脚本路径（相对工作目录）。
String pyIqaBridgePath = 'tools/iqa/iqa_bridge.py';

/// 单个请求的超时（首次 load 含模型加载，给足余量）。
const _kRequestTimeout = Duration(seconds: 300);

/// 一指标一个常驻桥接进程；协议单在途，请求排队串行。
class PyIqaWorker {
  PyIqaWorker._(this.metric);

  /// 支持的指标名（见 [pyIqaMetrics]）。
  final String metric;

  Process? _process;
  StreamSubscription<String>? _stdoutSub;

  /// 单在途请求的应答槽。
  Completer<Map<String, Object?>>? _pending;

  /// 请求串行链：每个请求挂到链尾。
  Future<void> _queue = Future.value();

  bool _dead = false;

  static final Map<String, PyIqaWorker> _workers = {};

  /// 运行环境是否可用（python 与桥接脚本均存在）。
  static bool get available =>
      File(pyIqaPythonPath).existsSync() && File(pyIqaBridgePath).existsSync();

  /// 取某指标的常驻进程（不存在则创建并懒启动）。
  static PyIqaWorker forMetric(String metric) {
    assert(pyIqaMetrics.containsKey(metric));
    return _workers.putIfAbsent(metric, () => PyIqaWorker._(metric));
  }

  /// 关闭全部桥接进程（应用退出/图替换时调用）。先取出快照再清表：
  /// 并发的第二次调用（多个 state 的 dispose 交叠）不能在迭代中清表。
  static Future<void> disposeAll() async {
    final workers = _workers.values.toList();
    _workers.clear();
    for (final w in workers) {
      await w._shutdown();
    }
  }

  /// 仅测试用：重置注册表（不杀进程，进程已死时用）。
  @visibleForTesting
  static void resetRegistry() => _workers.clear();

  Future<void> _ensureStarted() async {
    if (_dead) throw StateError('桥接进程已终止（$metric）');
    if (_process != null) return;
    if (!available) {
      throw StateError('未找到 Python 环境（$pyIqaPythonPath）或桥接脚本'
          '（$pyIqaBridgePath）；深度评价节点需要安装 '
          'torch/torchmetrics/lpips/pyiqa 的 Python 环境');
    }
    final proc = await Process.start(
      pyIqaPythonPath,
      [pyIqaBridgePath, '--serve'],
      workingDirectory: Directory.current.path,
    );
    _process = proc;
    final ready = Completer<Map<String, Object?>>();
    _pending = ready;
    _stdoutSub = proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
      (line) {
        // 非 JSON 行（第三方库偶发的 stdout 输出）忽略，只把 JSON
        // 应答路由给在途请求。
        if (!line.trimLeft().startsWith('{')) return;
        final slot = _pending;
        if (slot == null || slot.isCompleted) return;
        try {
          slot.complete(jsonDecode(line) as Map<String, Object?>);
        } catch (e) {
          slot.completeError(StateError('桥接应答解析失败: $line'));
        }
      },
      onError: (Object e) {
        _pending?.completeError(StateError('桥接输出读取失败: $e'));
      },
      onDone: _onProcessDone,
    );
    // stderr 只进日志（torch 的 warning 较多）。
    proc.stderr.transform(utf8.decoder).listen((line) {
      debugPrint('[pyiqa:$metric] $line');
    });
    final hello = await ready.future.timeout(_kRequestTimeout,
        onTimeout: () =>
            throw TimeoutException('桥接进程启动超时（$metric，300s）'));
    if (hello['ok'] != true) {
      throw StateError('桥接进程启动失败（$metric）: $hello');
    }
    // 握手后加载模型（一次性，后续请求复用）。注意：此处仍在串行链内，
    // 必须走原始请求（不能再经 _request 入队，否则自等待死锁）。
    final resp = await _requestRaw({'cmd': 'load', 'metric': metric});
    _checkOk(resp);
  }

  void _onProcessDone() {
    _process = null;
    final slot = _pending;
    _pending = null;
    slot?.completeError(StateError('桥接进程意外退出（$metric）'));
  }

  void _checkOk(Map<String, Object?> resp) {
    if (resp['ok'] != true) {
      throw StateError('${resp['error'] ?? '桥接未知错误'}');
    }
  }

  /// 发一个请求并等应答（自动排队，保证协议单在途）。
  Future<Map<String, Object?>> _request(Map<String, Object?> req) {
    final task = _queue.then((_) => _requestNow(req));
    // 链上吞掉异常，后续请求不被前序失败阻塞。
    _queue = task.then((_) {}, onError: (_) {});
    return task;
  }

  Future<Map<String, Object?>> _requestNow(Map<String, Object?> req) async {
    await _ensureStarted();
    return _requestRaw(req);
  }

  /// 原始请求（进程已启动；仅在串行链内调用，保证 [_pending] 单在途）。
  Future<Map<String, Object?>> _requestRaw(Map<String, Object?> req) async {
    final proc = _process;
    if (proc == null) throw StateError('桥接进程不可用（$metric）');
    final slot = Completer<Map<String, Object?>>();
    _pending = slot;
    proc.stdin.writeln(jsonEncode(req));
    await proc.stdin.flush();
    try {
      return await slot.future.timeout(_kRequestTimeout, onTimeout: () {
        throw TimeoutException('桥接请求超时（$metric ${req['cmd']}，300s）');
      });
    } finally {
      if (_pending == slot) _pending = null;
    }
  }

  Future<void> _shutdown() async {
    _dead = true;
    final proc = _process;
    _process = null;
    if (proc != null) {
      try {
        proc.stdin.writeln(jsonEncode({'cmd': 'quit'}));
        await proc.stdin.flush();
        await proc.exitCode.timeout(const Duration(seconds: 5));
      } catch (_) {
        proc.kill();
      }
    }
    await _stdoutSub?.cancel();
    _stdoutSub = null;
  }

  // ---- 对外 API（按指标类型约束，错用抛 StateError）----

  /// 双输入指标（lpips/dists）：[aPath] 参考图、[bPath] 测试图（PNG 路径）。
  Future<double> pairScore(String aPath, String bPath) async {
    final resp = await _request({'cmd': 'pair', 'a': aPath, 'b': bPath});
    _checkOk(resp);
    return (resp['score'] as num).toDouble();
  }

  /// 无参考单输入指标（musiq/clipiqa）。
  Future<double> singleScore(String aPath) async {
    final resp = await _request({'cmd': 'single', 'a': aPath});
    _checkOk(resp);
    return (resp['score'] as num).toDouble();
  }

  /// 分布级指标（fid/kid）：向 [side]（'ref'|'test'）累计一帧，
  /// 返回该侧已累计帧数。
  Future<int> distAdd(String side, String aPath) async {
    final resp = await _request({'cmd': 'add', 'side': side, 'a': aPath});
    _checkOk(resp);
    return (resp['n'] as num).toInt();
  }

  /// 分布级指标出分：返回 (score, 参考侧帧数, 测试侧帧数)；
  /// 样本不足（任一侧 <2 帧）返回 null。
  Future<(double, int, int)?> distScore() async {
    final resp = await _request({'cmd': 'score'});
    if (resp['ok'] != true) {
      final err = '${resp['error'] ?? ''}';
      if (err.contains('样本不足')) return null;
      _checkOk(resp);
    }
    return (
      (resp['score'] as num).toDouble(),
      (resp['n_ref'] as num).toInt(),
      (resp['n_test'] as num).toInt(),
    );
  }

  /// 分布级指标清空累计（新一轮运行开始时调用）。
  Future<void> distReset() async {
    final resp = await _request({'cmd': 'reset'});
    _checkOk(resp);
  }
}

/// RGBA8888 帧写入临时 PNG（桥接进程的图像输入），返回文件路径。
/// 文件放在系统临时目录的固定子目录，按序号命名；调用侧无需删除
/// （系统临时目录自清）。PNG 编码在后台 isolate 执行（大图纯 Dart
/// deflate 在 UI isolate 上会阻塞事件循环，见 encodePngRgbaInIsolate）。
int _tempPngSeq = 0;

Future<String> pyIqaWriteTempPng(Uint8List rgba, int w, int h) async {
  final dir = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}debug_tool_set_iqa');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final png = await compute(encodePngRgbaInIsolate,
      {'rgba': rgba, 'width': w, 'height': h});
  final path =
      '${dir.path}${Platform.pathSeparator}f_${DateTime.now().millisecondsSinceEpoch}_${_tempPngSeq++}.png';
  await File(path).writeAsBytes(png, flush: true);
  return path;
}
