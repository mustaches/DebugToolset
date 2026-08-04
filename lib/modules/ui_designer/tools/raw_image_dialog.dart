import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../../providers/ui_designer_state.dart';
import '../models/project_serializer.dart';
import 'pixel_formats.dart';

/// Raw image extraction tool: opens a binary file and decodes a region as
/// an image with adjustable offset / size / stride / pixel format / scan
/// direction, with live preview. The result can be exported as PNG or
/// stored as a project asset.
Future<void> showRawImageDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const RawImageDialog(),
  );
}

class RawImageDialog extends StatefulWidget {
  const RawImageDialog({super.key});

  @override
  State<RawImageDialog> createState() => _RawImageDialogState();
}

class _RawImageDialogState extends State<RawImageDialog> {
  String? _filePath;
  Uint8List? _bytes;

  final _offsetCtrl = TextEditingController(text: '0');
  final _widthCtrl = TextEditingController(text: '64');
  final _heightCtrl = TextEditingController(text: '64');
  final _strideCtrl = TextEditingController(text: '0');
  PixelFormat _format = PixelFormat.rgb565;
  bool _columnMajor = false;

  ui.Image? _preview;
  String? _message;

  @override
  void dispose() {
    _offsetCtrl.dispose();
    _widthCtrl.dispose();
    _heightCtrl.dispose();
    _strideCtrl.dispose();
    _preview?.dispose();
    super.dispose();
  }

  int? _parseNum(TextEditingController c) =>
      int.tryParse(c.text) ?? int.tryParse(c.text.replaceAll('0x', ''), radix: 16);

  Future<void> _pickFile() async {
    final file = await openFile(acceptedTypeGroups: const [
      XTypeGroup(label: '二进制', extensions: ['bin', 'hex', 'dat', '*'])
    ]);
    if (file == null) return;
    final bytes = await file.readAsBytes();
    setState(() {
      _filePath = file.path;
      _bytes = bytes;
      _message = '已加载 ${bytes.length} 字节';
    });
    await _refreshPreview();
  }

  Future<void> _refreshPreview() async {
    final bytes = _bytes;
    if (bytes == null) return;
    final w = _parseNum(_widthCtrl);
    final h = _parseNum(_heightCtrl);
    final offset = _parseNum(_offsetCtrl) ?? 0;
    final stride = _parseNum(_strideCtrl) ?? 0;
    if (w == null || h == null || w <= 0 || h <= 0 || w * h > 4000000) {
      setState(() => _message = '宽高无效或过大');
      return;
    }
    try {
      final rgba = rawToRgba(bytes, w, h, _format,
          columnMajor: _columnMajor, offset: offset, stride: stride);
      final completerImage = await _decodePixels(rgba, w, h);
      _preview?.dispose();
      setState(() {
        _preview = completerImage;
        _message = null;
      });
    } catch (e) {
      setState(() => _message = '解码失败: $e');
    }
  }

  Future<ui.Image> _decodePixels(Uint8List rgba, int w, int h) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba,
      w,
      h,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }

  Future<void> _exportPng() async {
    final image = _preview;
    if (image == null) return;
    final data =
        await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) return;
    final location = await getSaveLocation(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'PNG', extensions: ['png'])
      ],
      suggestedName:
          '${p.basenameWithoutExtension(_filePath ?? 'image')}_extract.png',
    );
    if (location == null) return;
    await File(location.path)
        .writeAsBytes(data.buffer.asUint8List());
    setState(() => _message = '已导出 PNG: ${location.path}');
  }

  Future<void> _storeAsAsset() async {
    final image = _preview;
    if (image == null || _filePath == null) return;
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) return;
    // Persist the PNG next to the source binary, then import it.
    final name = sanitizeCIdentifier(
            p.basenameWithoutExtension(_filePath!)) ??
        'extract';
    final pngPath =
        p.join(p.dirname(_filePath!), '${name}_extract.png');
    await File(pngPath).writeAsBytes(data.buffer.asUint8List());
    if (!mounted) return;
    final state = context.read<UiDesignerState>();
    final asset = state.importAsset(pngPath, name: name);
    asset
      ..width = image.width
      ..height = image.height;
    setState(() => _message = '已存入工程资源: ${asset.name}（像素格式请用图片转换工具生成）');
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF2E2E2E),
      title: const Text('二进制图像提取', style: TextStyle(fontSize: 14)),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                ElevatedButton.icon(
                  onPressed: _pickFile,
                  icon: const Icon(Icons.folder_open, size: 16),
                  label: const Text('打开文件', style: TextStyle(fontSize: 12)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _filePath == null
                        ? '未选择'
                        : p.basename(_filePath!),
                    overflow: TextOverflow.ellipsis,
                    style:
                        const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _numField('偏移', _offsetCtrl, 56),
                _numField('宽', _widthCtrl, 48),
                _numField('高', _heightCtrl, 48),
                _numField('行距', _strideCtrl, 48),
                DropdownButton<PixelFormat>(
                  value: _format,
                  isDense: true,
                  style: const TextStyle(fontSize: 12),
                  items: [
                    for (final f in PixelFormat.values)
                      DropdownMenuItem(value: f, child: Text(f.label)),
                  ],
                  onChanged: (v) {
                    setState(() => _format = v!);
                    _refreshPreview();
                  },
                ),
                DropdownButton<bool>(
                  value: _columnMajor,
                  isDense: true,
                  style: const TextStyle(fontSize: 12),
                  items: const [
                    DropdownMenuItem(value: false, child: Text('行扫描')),
                    DropdownMenuItem(value: true, child: Text('列扫描')),
                  ],
                  onChanged: (v) {
                    setState(() => _columnMajor = v ?? false);
                    _refreshPreview();
                  },
                ),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              height: 200,
              width: double.infinity,
              decoration: BoxDecoration(
                color: const Color(0xFF1B1B1B),
                border: Border.all(color: Colors.grey.shade800),
              ),
              child: _preview == null
                  ? const Center(
                      child: Text('预览',
                          style:
                              TextStyle(fontSize: 12, color: Colors.grey)))
                  : RawImage(image: _preview, fit: BoxFit.contain),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                _actionButton('导出 PNG', _preview == null ? null : _exportPng),
                const SizedBox(width: 8),
                _actionButton(
                    '存入工程资源', _preview == null ? null : _storeAsAsset),
              ],
            ),
            if (_message != null) ...[
              const SizedBox(height: 8),
              Text(_message!,
                  style: const TextStyle(
                      fontSize: 11, color: Colors.cyanAccent)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  Widget _numField(
      String label, TextEditingController controller, double width) {
    return SizedBox(
      width: width + 34,
      child: Row(
        children: [
          Text(label,
              style: const TextStyle(fontSize: 11, color: Colors.grey)),
          const SizedBox(width: 4),
          Expanded(
            child: TextField(
              controller: controller,
              style:
                  const TextStyle(fontSize: 11, fontFamily: 'Consolas'),
              decoration: const InputDecoration(
                isDense: true,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _refreshPreview(),
              onEditingComplete: _refreshPreview,
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionButton(String label, VoidCallback? onPressed) {
    return ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: const Color(0xFF0A4A5A),
        foregroundColor: Colors.cyanAccent,
        minimumSize: const Size(0, 30),
      ),
      child: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }
}
