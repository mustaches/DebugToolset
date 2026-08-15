/// 运行预览的进度窗口：准备阶段（解析→探针→渲染预览节点→更新仪器）
/// 弹出的细长条，显示双色斜条进度条（与 hex 编辑器同款）、阶段文字
/// 与百分比；完成自动关闭。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../providers/isp_studio_state.dart';

/// 运行预览并弹出进度窗口。任务未启动（图中没有预览节点等立即
/// 返回的情况）时不弹。
void runPreviewWithProgress(BuildContext context, IspStudioState state) {
  state.runPreview(); // 同步段会把 isProcessing 置位
  if (!state.isProcessing) return;
  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => RunPreviewProgressDialog(state: state),
  ));
}

/// 细长条进度窗口：进度条走 [IspStudioState.progressTick]（平滑插值），
/// 阶段文字走 state 的 notifyListeners；isProcessing 落地即自动关闭。
class RunPreviewProgressDialog extends StatefulWidget {
  const RunPreviewProgressDialog({super.key, required this.state});

  final IspStudioState state;

  @override
  State<RunPreviewProgressDialog> createState() =>
      _RunPreviewProgressDialogState();
}

class _RunPreviewProgressDialogState extends State<RunPreviewProgressDialog>
    with SingleTickerProviderStateMixin {
  /// 斜条流动动画（与 hex 编辑器进度条同一节奏）。
  late final AnimationController _stripeController;

  @override
  void initState() {
    super.initState();
    _stripeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
    widget.state.addListener(_onStateChanged);
    // 极快的任务可能在窗口首帧前就已完成。
    WidgetsBinding.instance.addPostFrameCallback((_) => _onStateChanged());
  }

  void _onStateChanged() {
    if (!mounted) return;
    if (!widget.state.isProcessing) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {}); // 阶段文字随 notifyListeners 刷新
  }

  @override
  void dispose() {
    widget.state.removeListener(_onStateChanged);
    _stripeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    return Dialog(
      backgroundColor: const Color(0xFF2B2B2B),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: const BorderSide(width: 1, color: Color(0xFF555555)),
      ),
      child: SizedBox(
        width: 560,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.play_circle_outline,
                  size: 16, color: Color(0xFF4CAF50)),
              const SizedBox(width: 8),
              const Text('预览准备中',
                  style: TextStyle(fontSize: 12, color: Colors.white)),
              const SizedBox(width: 12),
              Expanded(
                child: AnimatedBuilder(
                  animation: _stripeController,
                  builder: (context, _) => ValueListenableBuilder<double>(
                    valueListenable: state.progressTick,
                    builder: (context, value, _) => CustomPaint(
                      painter: _ZebraProgressPainter(
                        progress: value,
                        phase: _stripeController.value * 14.0,
                      ),
                      child: const SizedBox(height: 10, width: double.infinity),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              ValueListenableBuilder<double>(
                valueListenable: state.progressTick,
                builder: (context, value, _) => Text(
                  '${(value * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  state.statusMessage,
                  style:
                      const TextStyle(fontSize: 11, color: Colors.white54),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 双色斜条进度条（与 hex 编辑器 _ZebraProgressBarPainter 同款：
/// 深底 + 深蓝基底 + 45° 流动亮蓝斜纹 + 顶部 1px 高光）。
class _ZebraProgressPainter extends CustomPainter {
  _ZebraProgressPainter({required this.progress, required this.phase});

  final double progress;

  /// 斜纹流动相位，0..step。
  final double phase;

  @override
  void paint(Canvas canvas, Size size) {
    final barWidth = size.width * progress.clamp(0.0, 1.0);
    final bgRect = Rect.fromLTWH(0, 0, size.width, size.height);
    final progressRect = Rect.fromLTWH(0, 0, barWidth, size.height);

    canvas.drawRect(bgRect, Paint()..color = const Color(0xFF1E1E1E));
    if (barWidth <= 0) return;

    canvas.drawRect(
        progressRect, Paint()..color = const Color(0xFF0D47A1));

    canvas.save();
    canvas.clipRect(progressRect);
    final stripePaint = Paint()
      ..color = const Color(0xFF2979FF)
      ..strokeWidth = 3.0;
    const step = 14.0;
    for (var x = -size.height - phase; x < barWidth + size.height; x += step) {
      canvas.drawLine(
          Offset(x, size.height), Offset(x + size.height, 0), stripePaint);
    }
    canvas.restore();

    final borderPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.1)
      ..strokeWidth = 1.0;
    canvas.drawLine(Offset(0, 0), Offset(size.width, 0), borderPaint);
  }

  @override
  bool shouldRepaint(covariant _ZebraProgressPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.phase != phase;
}
