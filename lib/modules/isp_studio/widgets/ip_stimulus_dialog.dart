/// IP 一键仿真「仿真激励参数」对话框：帧尺寸/帧数/帧间隔/激励图案/随机
/// 种子/握手压力率（输入气泡、输出背压）。默认 64×8×6 帧、帧间隔 10 拍。
/// 返回 null 表示取消。
library;

import 'package:flutter/material.dart';

import '../codegen/ip_stimulus.dart';

/// 弹出仿真激励参数对话框；确定返回 [IpSimStimulus]，取消返回 null。
/// [initial] 为该编组上次的激励参数（回填）；[confirmText] 为确定按钮
/// 文案（「一键仿真」入口传「开始仿真」）。
Future<IpSimStimulus?> showIpStimulusDialog(
  BuildContext context, {
  IpSimStimulus? initial,
  String confirmText = '应用',
}) {
  return showDialog<IpSimStimulus>(
    context: context,
    builder: (ctx) => _IpStimulusDialog(initial: initial, confirmText: confirmText),
  );
}

class _IpStimulusDialog extends StatefulWidget {
  final IpSimStimulus? initial;
  final String confirmText;

  const _IpStimulusDialog({this.initial, this.confirmText = '应用'});

  @override
  State<_IpStimulusDialog> createState() => _IpStimulusDialogState();
}

class _IpStimulusDialogState extends State<_IpStimulusDialog> {
  late final TextEditingController _wCtrl;
  late final TextEditingController _hCtrl;
  late final TextEditingController _framesCtrl;
  late final TextEditingController _frameGapCtrl;
  late final TextEditingController _seedCtrl;
  late final TextEditingController _clkCtrl;
  late IpSimPattern _pattern;
  late int _inGapPct;
  late int _outStallPct;
  String? _error;

  @override
  void initState() {
    super.initState();
    final s = widget.initial ?? const IpSimStimulus();
    _wCtrl = TextEditingController(text: '${s.width}');
    _hCtrl = TextEditingController(text: '${s.height}');
    _framesCtrl = TextEditingController(text: '${s.frames}');
    _frameGapCtrl = TextEditingController(text: '${s.frameGapCycles}');
    _seedCtrl = TextEditingController(
        text: '0x${s.seed.toRadixString(16).padLeft(8, '0')}');
    _clkCtrl = TextEditingController(text: fmtClkMHz(s.clkMHz));
    _pattern = s.pattern;
    _inGapPct = s.inGapPct;
    _outStallPct = s.outStallPct;
    // 尺寸/帧数变化时刷新像素总数提示。
    for (final c in [_wCtrl, _hCtrl, _framesCtrl]) {
      c.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    _wCtrl.dispose();
    _hCtrl.dispose();
    _framesCtrl.dispose();
    _frameGapCtrl.dispose();
    _seedCtrl.dispose();
    _clkCtrl.dispose();
    super.dispose();
  }

  int? _parseInt(String text, {bool hexOk = false}) {
    final t = text.trim();
    if (t.isEmpty) return null;
    if (hexOk && t.toLowerCase().startsWith('0x')) {
      return int.tryParse(t.substring(2), radix: 16);
    }
    return int.tryParse(t);
  }

  /// 收集并校验；合法返回参数，否则置错误信息返回 null。
  IpSimStimulus? _collect() {
    final w = _parseInt(_wCtrl.text);
    final h = _parseInt(_hCtrl.text);
    final f = _parseInt(_framesCtrl.text);
    final gap = _parseInt(_frameGapCtrl.text);
    final seed = _parseInt(_seedCtrl.text, hexOk: true);
    final clk = double.tryParse(_clkCtrl.text.trim());
    if (w == null || h == null || f == null || gap == null) {
      setState(() => _error = '帧宽/帧高/帧数/帧间隔须为整数');
      return null;
    }
    if (seed == null) {
      setState(() => _error = '随机种子须为整数（支持 0x 前缀十六进制）');
      return null;
    }
    if (clk == null) {
      setState(() => _error = 'CLK频率须为数值（MHz，默认 100）');
      return null;
    }
    final s = IpSimStimulus(
      width: w,
      height: h,
      frames: f,
      frameGapCycles: gap,
      clkMHz: clk,
      pattern: _pattern,
      seed: seed,
      inGapPct: _inGapPct,
      outStallPct: _outStallPct,
    );
    final err = s.validate();
    if (err != null) {
      setState(() => _error = err);
      return null;
    }
    return s;
  }

  void _resetDefaults() {
    const d = IpSimStimulus();
    setState(() {
      _wCtrl.text = '${d.width}';
      _hCtrl.text = '${d.height}';
      _framesCtrl.text = '${d.frames}';
      _frameGapCtrl.text = '${d.frameGapCycles}';
      _seedCtrl.text = '0x${d.seed.toRadixString(16).padLeft(8, '0')}';
      _clkCtrl.text = fmtClkMHz(d.clkMHz);
      _pattern = d.pattern;
      _inGapPct = d.inGapPct;
      _outStallPct = d.outStallPct;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final w = _parseInt(_wCtrl.text) ?? 0;
    final h = _parseInt(_hCtrl.text) ?? 0;
    final f = _parseInt(_framesCtrl.text) ?? 0;
    final total = w * h * f;
    return AlertDialog(
      title: const Text('仿真激励参数'),
      content: SizedBox(
        width: 420,
        // 内容随参数项增多可能超出小窗口对话框高度：可滚动。
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
            _label('帧尺寸（宽 × 高）、帧数与帧间隔'),
            Row(
              children: [
                Expanded(child: _intField(_wCtrl, '宽')),
                const SizedBox(width: 8),
                Expanded(child: _intField(_hCtrl, '高')),
                const SizedBox(width: 8),
                Expanded(child: _intField(_framesCtrl, '帧数')),
                const SizedBox(width: 8),
                Expanded(child: _intField(_frameGapCtrl, '间隔(拍)')),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '激励像素总数：$total${total > 200000 ? '（较大，仿真较慢）' : ''}'
              '；帧间隔单位为时钟周期数（仅多帧时生效）',
              style: TextStyle(
                fontSize: 11,
                color: total > 200000 ? Colors.orange : Colors.grey,
              ),
            ),
            const SizedBox(height: 12),
            _label('CLK 频率（MHz，默认 100；决定 tb 时钟周期）'),
            SizedBox(
              width: 160,
              child: TextFormField(
                controller: _clkCtrl,
                style: const TextStyle(fontSize: 12, fontFamily: 'Consolas'),
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: '100',
                  suffixText: 'MHz',
                ),
              ),
            ),
            const SizedBox(height: 12),
            _label('激励图案'),
            DropdownButtonFormField<IpSimPattern>(
              initialValue: _pattern,
              items: [
                for (final p in IpSimPattern.values)
                  DropdownMenuItem(value: p, child: Text(p.displayName)),
              ],
              onChanged: (v) {
                if (v != null) setState(() => _pattern = v);
              },
            ),
            const SizedBox(height: 12),
            _label('随机种子（随机图案与握手压力的随机源，0x 前缀十六进制）'),
            TextFormField(
              controller: _seedCtrl,
              style: const TextStyle(fontSize: 12, fontFamily: 'Consolas'),
              decoration: const InputDecoration(
                isDense: true,
                hintText: '0x12345678',
              ),
            ),
            const SizedBox(height: 12),
            _label('握手压力（验证 ready 握手健壮性；不影响 golden 数据）'),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<int>(
                    initialValue: _inGapPct,
                    decoration: const InputDecoration(
                        isDense: true, labelText: '输入气泡率'),
                    items: [
                      for (final p in const [0, 10, 25, 50])
                        DropdownMenuItem(value: p, child: Text('$p%')),
                    ],
                    onChanged: (v) {
                      if (v != null) setState(() => _inGapPct = v);
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButtonFormField<int>(
                    initialValue: _outStallPct,
                    decoration: const InputDecoration(
                        isDense: true, labelText: '输出背压率'),
                    items: [
                      for (final p in const [0, 10, 25, 50])
                        DropdownMenuItem(value: p, child: Text('$p%')),
                    ],
                    onChanged: (v) {
                      if (v != null) setState(() => _outStallPct = v);
                    },
                  ),
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: const TextStyle(fontSize: 12, color: Color(0xFFCF6679)),
              ),
            ],
            const SizedBox(height: 8),
            const Text(
              '参数随「一键仿真」重新生成 tb/golden 生效；导出 IP 包亦携带同一激励。',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _resetDefaults,
          child: const Text('恢复默认'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final s = _collect();
            if (s != null) Navigator.pop(context, s);
          },
          child: Text(widget.confirmText),
        ),
      ],
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(text, style: const TextStyle(fontSize: 12)),
      );

  Widget _intField(TextEditingController ctrl, String label) {
    return TextFormField(
      controller: ctrl,
      style: const TextStyle(fontSize: 12, fontFamily: 'Consolas'),
      decoration: InputDecoration(isDense: true, labelText: label),
    );
  }
}
