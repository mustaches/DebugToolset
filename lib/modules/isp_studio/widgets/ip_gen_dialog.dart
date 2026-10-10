/// ISP 编组「生成Verilog IP」选项对话框：选目标 FPGA 厂商 + 位宽/行宽
/// （写入生成代码的 parameter 默认值，Vivado Customize IP 界面可再改）。
/// 附 iverilog 探测状态行。返回 null 表示取消。
library;

import 'package:flutter/material.dart';

import '../codegen/ip_target.dart';
import '../codegen/iverilog_sim.dart';

/// 弹出 IP 生成选项对话框；确定返回 [IpGenOptions]，取消返回 null。
/// [initial] 为上次该编组的选项（回填）。
Future<IpGenOptions?> showIpGenDialog(
  BuildContext context, {
  IpGenOptions? initial,
}) {
  return showDialog<IpGenOptions>(
    context: context,
    builder: (ctx) => _IpGenDialog(initial: initial),
  );
}

class _IpGenDialog extends StatefulWidget {
  final IpGenOptions? initial;

  const _IpGenDialog({this.initial});

  @override
  State<_IpGenDialog> createState() => _IpGenDialogState();
}

class _IpGenDialogState extends State<_IpGenDialog> {
  late IpVendor _vendor;
  late VivadoSeries _series;
  late int _pixBits; // 0 = 位深推导
  late int _maxWidth;
  IverilogToolchain? _iverilog;

  @override
  void initState() {
    super.initState();
    _vendor = widget.initial?.vendor ?? IpVendor.vivado;
    _series = widget.initial?.series ?? VivadoSeries.zynqUltrascalePlus;
    _pixBits = widget.initial?.pixBits ?? 0;
    _maxWidth = widget.initial?.maxWidth ?? 4096;
    _iverilog = detectIverilog();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('生成Verilog IP'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _label('目标 FPGA 厂商'),
            DropdownButtonFormField<IpVendor>(
              initialValue: _vendor,
              items: [
                for (final v in IpVendor.values)
                  DropdownMenuItem(
                    value: v,
                    enabled: v.enabled,
                    child: Text(
                      v.enabled ? v.displayName : '${v.displayName}（待完成）',
                      // 禁用项暗色主题下不显灰，显式灰色字体
                      style: v.enabled
                          ? null
                          : const TextStyle(color: Colors.grey),
                    ),
                  ),
              ],
              onChanged: (v) {
                if (v != null) setState(() => _vendor = v);
              },
            ),
            // 器件系列：仅 Vivado 厂商显示（驱动 package_ip.tcl 的
            // create_project -part 与 supported_families）。
            if (_vendor.isVivado) ...[
              const SizedBox(height: 12),
              _label('器件系列'),
              DropdownButtonFormField<VivadoSeries>(
                initialValue: _series,
                items: [
                  for (final s in VivadoSeries.values)
                    DropdownMenuItem(value: s, child: Text(s.displayName)),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _series = v);
                },
              ),
            ],
            const SizedBox(height: 12),
            _label('像素位宽 PIX_BITS'),
            DropdownButtonFormField<int>(
              initialValue: _pixBits,
              items: [
                const DropdownMenuItem(value: 0, child: Text('位深推导（默认）')),
                for (final b in const [8, 10, 12, 14, 16])
                  DropdownMenuItem(value: b, child: Text('$b bit')),
              ],
              onChanged: (v) {
                if (v != null) setState(() => _pixBits = v);
              },
            ),
            const SizedBox(height: 12),
            _label('最大行宽 MAX_WIDTH'),
            DropdownButtonFormField<int>(
              initialValue: _maxWidth,
              items: [
                for (final w in const [640, 1280, 1920, 2048, 4096, 8192])
                  DropdownMenuItem(value: w, child: Text('$w')),
              ],
              onChanged: (v) {
                if (v != null) setState(() => _maxWidth = v);
              },
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Icon(
                  _iverilog != null ? Icons.check_circle : Icons.info_outline,
                  size: 15,
                  color: _iverilog != null ? Colors.green : Colors.orange,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _iverilog != null
                        ? '已检测到 Icarus Verilog，可一键仿真'
                        : '未检测到 iverilog（一键仿真暂不可用；导出功能不受影响）',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              '以上参数在 Vivado Customize IP / SmartDesign generics 界面中可再次修改。',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            IpGenOptions(
              vendor: _vendor,
              series: _series,
              pixBits: _pixBits,
              maxWidth: _maxWidth,
            ),
          ),
          child: const Text('生成'),
        ),
      ],
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(text, style: const TextStyle(fontSize: 12)),
      );
}
