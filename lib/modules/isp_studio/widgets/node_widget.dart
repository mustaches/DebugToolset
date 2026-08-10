/// ISP Studio 节点卡片：标题栏、端口行与类型附加控件。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../providers/isp_studio_state.dart';
import '../models/isp_node.dart';
import 'node_layout.dart';

/// 单个节点的可视化卡片。
///
/// 连线拖拽的坐标换算（全局 → 画布坐标）由画布负责，
/// 通过 [globalToCanvas] 传入；拖拽结束由 [onConnectionDragEnd] 通知画布做落点命中。
/// 输入端口的 [GlobalKey] 由画布通过 [inputPortKeyFor] 分配，用于落点命中测试。
class IspNodeWidget extends StatelessWidget {
  final IspNode node;
  final IspNodeType type;
  final bool selected;

  /// 全局坐标 → 画布（未缩放）坐标。
  final Offset Function(Offset globalPos) globalToCanvas;

  /// 连线拖拽结束回调（画布做命中测试并调用 endConnectionDrag）。
  final VoidCallback onConnectionDragEnd;

  /// 最大化/还原切换（画布计算视口矩形后调整节点几何）。
  /// 仅有显示区的节点（预览/仪器）会显示该按钮。
  final VoidCallback onToggleMaximize;

  /// 为输入端口分配/获取画布注册表中的 GlobalKey。
  final GlobalKey Function(String port) inputPortKeyFor;

  const IspNodeWidget({
    super.key,
    required this.node,
    required this.type,
    required this.selected,
    required this.globalToCanvas,
    required this.onConnectionDragEnd,
    required this.onToggleMaximize,
    required this.inputPortKeyFor,
  });

  @override
  Widget build(BuildContext context) {
    final state = context.watch<IspStudioState>();
    final rows = math.max(type.inputs.length, type.outputs.length);
    return GestureDetector(
      // 点击卡片任意位置选中节点（端口圆点、按钮等内部手势优先）。
      // 节点拖动由画布的右键拖拽统一处理；删除只走键盘 Delete。
      onTap: () => state.selectNode(node.id),
      child: Container(
        width: node.width,
        height: nodeHeight(type,
            previewExtraHeight: state.previewExtraHeight(node.id)),
        decoration: BoxDecoration(
          color: const Color(0xFF252525),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.primary
                : const Color(0xFF3A3A3A),
            width: selected ? 2 : 1,
          ),
          boxShadow: const [
            BoxShadow(
              color: Colors.black45,
              blurRadius: 6,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildTitleBar(state),
            for (var i = 0; i < rows; i++) _buildPortRow(state, i),
            if (type.typeId == 'preview') _buildPreviewExtra(state),
            if (allInstrumentTypes.contains(type.typeId))
              _buildInstrumentExtra(state),
            if (type.typeId == 'image_output')
              _buildExportButton(
                  state, '导出图片', () => state.exportImages(node.id)),
            if (type.typeId == 'video_output')
              _buildExportButton(
                  state, '导出 MP4', () => state.exportVideo(node.id)),
          ],
        ),
      ),
    );
  }

  /// 仪器节点附加区：直方图与音频仪器（电平/波形/EQ）用 CustomPaint
  /// 直绘 instrumentResults，波形/矢量示波器显示 state 里解码好的亮度图。
  /// 高度与预览节点共用同一套拖动调整机制（底部手柄 + 右下角控制点）。
  Widget _buildInstrumentExtra(IspStudioState state) {
    const hint =
        Text('未运行', style: TextStyle(fontSize: 11, color: Colors.grey));
    final extra = state.previewExtraHeight(node.id);
    Widget content;
    if (type.typeId == 'histogram') {
      final result = state.instrumentResults[node.id];
      if (result == null) {
        content = hint;
      } else {
        final visible = state.histogramChannels(node.id);
        content = Column(
          children: [
            // 通道勾选行（R/G/B）。
            SizedBox(
              height: 16,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (final (ch, label, color) in [
                    ('r', 'R', const Color(0xFFE04040)),
                    ('g', 'G', const Color(0xFF40C040)),
                    ('b', 'B', const Color(0xFF4080E0)),
                  ])
                    _channelToggle(state, ch, label, color,
                        visible.contains(ch)),
                ],
              ),
            ),
            Expanded(
              // SizedBox.expand：无 child 的 CustomPaint 在松散约束下会
              // 塌缩成 0 宽，这里强制占满。
              child: SizedBox.expand(
                child: CustomPaint(
                  painter: _HistogramPainter(
                    r: result['r'] as Uint32List,
                    g: result['g'] as Uint32List,
                    b: result['b'] as Uint32List,
                    showR: visible.contains('r'),
                    showG: visible.contains('g'),
                    showB: visible.contains('b'),
                  ),
                ),
              ),
            ),
          ],
        );
      }
    } else if (type.typeId == 'vectorscope') {
      final image = state.instrumentImages[node.id];
      // 坐标格（前景层）始终绘制，未运行时也有格线。
      // 数据区是居中、边长为短边 82% 的正方形（与坐标格 paint 里的
      // min(w,h)*0.82 一致）；迹线铺满该正方形，外圈刻度环画在留白里。
      // 不能用 FractionallySizedBox：附加区一般不是正方形，按比例内缩
      // 会得到矩形，与坐标格的正方数据区对不上。
      content = LayoutBuilder(
        builder: (context, constraints) {
          final side =
              math.min(constraints.maxWidth, constraints.maxHeight) * 0.82;
          return SizedBox.expand(
            child: CustomPaint(
              foregroundPainter: const VectorscopeGraticule(),
              child: Center(
                child: SizedBox(
                  width: side,
                  height: side,
                  child: image == null
                      ? const Center(child: hint)
                      : RawImage(image: image, fit: BoxFit.fill),
                ),
              ),
            ),
          );
        },
      );
    } else if (type.typeId == 'audio_level') {
      final result = state.instrumentResults[node.id];
      content = result == null
          ? hint
          : CustomPaint(
              painter: _AudioLevelPainter(
                  (result['left'] as num).toDouble(),
                  (result['right'] as num).toDouble()),
              child: const SizedBox.expand());
    } else if (type.typeId == 'audio_waveform') {
      final result = state.instrumentResults[node.id];
      content = result == null
          ? hint
          : CustomPaint(
              painter: _AudioWaveformPainter(
                result['lMin'] as Float32List,
                result['lMax'] as Float32List,
                result['rMin'] as Float32List,
                result['rMax'] as Float32List,
              ),
              child: const SizedBox.expand());
    } else if (type.typeId == 'audio_eq') {
      final result = state.instrumentResults[node.id];
      content = result == null
          ? hint
          : CustomPaint(
              painter: _AudioEqPainter(result['bands'] as Float64List),
              child: const SizedBox.expand());
    } else {
      final image = state.instrumentImages[node.id];
      content =
          image == null ? hint : RawImage(image: image, fit: BoxFit.contain);
    }
    return SizedBox(
      height: extra,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
            child: Container(
              // 附加区 - 顶部留白 4 - 拖动手柄 10。
              height: extra - 14,
              color: Colors.black,
              alignment: Alignment.center,
              child: content,
            ),
          ),
          _buildResizeBar(state),
        ],
      ),
    );
  }

  /// 直方图通道勾选项：彩色小方块 + 字母标签。
  Widget _channelToggle(IspStudioState state, String ch, String label,
      Color color, bool on) {
    return InkWell(
      onTap: () => state.toggleHistogramChannel(node.id, ch),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: on ? color : Colors.transparent,
                border: Border.all(color: color),
                borderRadius: BorderRadius.circular(2),
              ),
              child: on
                  ? const Icon(Icons.check, size: 8, color: Colors.black)
                  : null,
            ),
            const SizedBox(width: 2),
            Text(label,
                style: TextStyle(
                    fontSize: 9, color: on ? color : Colors.grey)),
          ],
        ),
      ),
    );
  }

  Widget _buildTitleBar(IspStudioState state) {
    // 拖动由画布的右键拖拽统一处理，标题栏不再响应左键拖拽。
    return Container(
      height: kNodeTitleHeight,
      decoration: BoxDecoration(
        color: Color(type.colorValue),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(5)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              type.displayName,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // 查看代码（只读标签页）。
          Tooltip(
            message: '查看代码',
            child: InkWell(
              onTap: () => state.openCodeTab(node.id),
              child: const Padding(
                padding: EdgeInsets.all(2),
                child: Icon(Icons.code, size: 14, color: Colors.white70),
              ),
            ),
          ),
          // 最大化/还原（仅有显示区的节点：预览/仪器）。
          if (type.typeId == 'preview' ||
              allInstrumentTypes.contains(type.typeId))
            Tooltip(
              message:
                  state.maximizedNodeId == node.id ? '还原' : '最大化',
              child: InkWell(
                onTap: onToggleMaximize,
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: Icon(
                    state.maximizedNodeId == node.id
                        ? Icons.fullscreen_exit
                        : Icons.fullscreen,
                    size: 14,
                    color: Colors.white70,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPortRow(IspStudioState state, int index) {
    final hasIn = index < type.inputs.length;
    final hasOut = index < type.outputs.length;
    const labelStyle = TextStyle(fontSize: 11, color: Colors.grey);
    return SizedBox(
      height: kPortRowHeight,
      child: Row(
        children: [
          if (hasIn)
            _inputDot(state, type.inputs[index])
          else
            const SizedBox(width: kPortRadius * 2),
          if (hasIn)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(type.inputs[index].label, style: labelStyle),
            ),
          const Spacer(),
          if (hasOut)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Text(type.outputs[index].label, style: labelStyle),
            ),
          if (hasOut)
            _outputDot(state, type.outputs[index])
          else
            const SizedBox(width: kPortRadius * 2),
        ],
      ),
    );
  }

  Widget _dot(IspPortSpec port, bool connected) {
    return Container(
      width: kPortRadius * 2,
      height: kPortRadius * 2,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: portColor(port.type),
        border: connected ? Border.all(color: Colors.white54) : null,
      ),
    );
  }

  /// 输入端口：圆心位于节点左边缘（x = 0），点击断开已有连接。
  Widget _inputDot(IspStudioState state, IspPortSpec port) {
    final connected =
        state.graph.connectionAt(node.id, port.name) != null;
    // 命中区是行内 20x行高 的不透明区域（全在 Row 自身范围内——
    // Row 只命中测试自身范围内的点，直接把圆点平移出节点边缘会
    // 让探出的那一半点不到）；视觉圆点经 Align+平移保持圆心在
    // 节点边缘。GlobalKey 挂在圆点上，落点命中量的是圆点圆心。
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: connected
          ? () => state.disconnectInput(node.id, port.name)
          : null,
      child: SizedBox(
        width: kPortRadius * 4,
        height: kPortRowHeight,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Transform.translate(
            offset: const Offset(-kPortRadius, 0),
            child: SizedBox(
              key: inputPortKeyFor(port.name),
              width: kPortRadius * 2,
              height: kPortRadius * 2,
              child: _dot(port, connected),
            ),
          ),
        ),
      ),
    );
  }

  /// 输出端口：圆心位于节点右边缘，从此拖出连线。
  Widget _outputDot(IspStudioState state, IspPortSpec port) {
    // 命中区处理同 _inputDot（行内 20x行高，圆心视觉在节点右边缘）。
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (d) => state.beginConnectionDrag(
          node.id, port.name, globalToCanvas(d.globalPosition)),
      onPanUpdate: (d) =>
          state.updateConnectionDrag(globalToCanvas(d.globalPosition)),
      onPanEnd: (_) => onConnectionDragEnd(),
      child: SizedBox(
        width: kPortRadius * 4,
        height: kPortRowHeight,
        child: Align(
          alignment: Alignment.centerRight,
          child: Transform.translate(
            offset: const Offset(kPortRadius, 0),
            child: SizedBox(
              width: kPortRadius * 2,
              height: kPortRadius * 2,
              child: _dot(port, false),
            ),
          ),
        ),
      ),
    );
  }

  /// 预览附加区：屏幕 + 播放控制条 + 底部拖动手柄（调整屏幕高度）。
  Widget _buildPreviewExtra(IspStudioState state) {
    final image = state.previewImage;
    final total = state.totalFrames ?? 1;
    final extra = state.previewExtraHeight(node.id);
    return SizedBox(
      height: extra,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
            child: Container(
              // 附加区 - 顶部留白 4 - 控制条 26 - 拖动手柄 10。
              height: extra - 40,
              color: Colors.black,
              alignment: Alignment.center,
              child: image != null
                  ? RawImage(image: image, fit: BoxFit.contain)
                  : const Text('未运行',
                      style: TextStyle(fontSize: 11, color: Colors.grey)),
            ),
          ),
          SizedBox(
            height: 26,
            child: Row(
              children: [
                IconButton(
                  icon: Icon(
                      state.isPlaying ? Icons.pause : Icons.play_arrow,
                      size: 16),
                  padding: EdgeInsets.zero,
                  tooltip: state.isPlaying ? '暂停' : '连续播放',
                  // 导出等处理中禁用；播放中点击为暂停。
                  onPressed: state.isProcessing && !state.isPlaying
                      ? null
                      : () => state.togglePlayback(),
                ),
                if (total > 1)
                  Expanded(
                    child: Slider(
                      value: state.previewFrame
                          .clamp(0, total - 1)
                          .toDouble(),
                      min: 0,
                      max: (total - 1).toDouble(),
                      // 播放中禁用拖帧。
                      onChanged: state.isPlaying
                          ? null
                          : (v) => state.setPreviewFrame(v.round()),
                      onChangeEnd:
                            state.isPlaying ? null : (_) => state.runPreview(),
                    ),
                  ),
              ],
            ),
          ),
          // 底部手柄条：中间上下拖调整高度，右下角控制点双向调整宽高。
          _buildResizeBar(state),
        ],
      ),
    );
  }

  /// 底部手柄条：中间上下拖调整附加区高度，右下角控制点双向调整节点宽高。
  /// 预览与仪器节点共用。
  Widget _buildResizeBar(IspStudioState state) {
    return SizedBox(
      height: 10,
      child: Row(
        children: [
          Expanded(
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeUpDown,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                // 从按下点起算增量：认领后立刻补齐位移，避免前 36px 死区。
                dragStartBehavior: DragStartBehavior.down,
                onPanUpdate: (d) => state.setPreviewExtraHeight(
                    node.id,
                    state.previewExtraHeight(node.id) +
                        d.delta.dy / state.canvasZoom),
                child: const Center(
                  child:
                      Icon(Icons.drag_handle, size: 10, color: Colors.grey),
                ),
              ),
            ),
          ),
          // 右下角控制点：X、Y 方向同时缩放。
          MouseRegion(
            cursor: SystemMouseCursors.resizeUpLeftDownRight,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              dragStartBehavior: DragStartBehavior.down,
              onPanUpdate: (d) => state.resizePreview(
                  node.id,
                  node.width + d.delta.dx / state.canvasZoom,
                  state.previewExtraHeight(node.id) +
                      d.delta.dy / state.canvasZoom),
              child: const SizedBox(
                width: 16,
                height: 10,
                child: Center(
                  child: Icon(Icons.south_east, size: 10, color: Colors.grey),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildExportButton(
      IspStudioState state, String label, VoidCallback onPressed) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 3, 8, 3),
      child: SizedBox(
        height: 28,
        width: double.infinity,
        child: ElevatedButton(
          onPressed: state.isProcessing ? null : onPressed,
          style: ElevatedButton.styleFrom(
            foregroundColor: Colors.white,
            padding: EdgeInsets.zero,
            textStyle: const TextStyle(fontSize: 12),
          ),
          child: Text(label),
        ),
      ),
    );
  }
}

/// RGB 直方图绘制：对数刻度，三通道竖条叠加（每亮度级一根）；
/// 带网格线、坐标轴与 X 轴刻度（0..255）。
class _HistogramPainter extends CustomPainter {
  final Uint32List r;
  final Uint32List g;
  final Uint32List b;
  final bool showR;
  final bool showG;
  final bool showB;

  _HistogramPainter({
    required this.r,
    required this.g,
    required this.b,
    this.showR = true,
    this.showG = true,
    this.showB = true,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 底部预留 12px 给 X 轴刻度文字。
    final plot = Rect.fromLTWH(0, 0, size.width, size.height - 12);

    // 网格：X 四等分（0/64/128/192/255），Y 四等分。
    final gridPaint = Paint()
      ..color = const Color(0x1AFFFFFF)
      ..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      final dx = plot.width * i / 4;
      canvas.drawLine(
          Offset(dx, plot.top), Offset(dx, plot.bottom), gridPaint);
      final dy = plot.height * i / 4;
      canvas.drawLine(
          Offset(plot.left, dy), Offset(plot.right, dy), gridPaint);
    }

    // 通道竖条（只画勾选通道，按可见通道的最大值归一化）：
    // 每个亮度级一根竖条，稀疏数据不会被折线插值成三角形。
    var max = 1;
    for (final (bins, show) in [(r, showR), (g, showG), (b, showB)]) {
      if (!show) continue;
      for (final c in bins) {
        if (c > max) max = c;
      }
    }
    final logMax = math.log(max + 1);
    final barWidth = plot.width / 256;
    void draw(Uint32List bins, Color color) {
      final paint = Paint()..color = color;
      for (var i = 0; i < 256; i++) {
        if (bins[i] == 0) continue;
        final t = math.log(bins[i] + 1) / logMax;
        canvas.drawRect(
          Rect.fromLTWH(plot.left + i * barWidth,
              plot.bottom - plot.height * t, barWidth, plot.height * t),
          paint,
        );
      }
    }

    if (showR) draw(r, const Color(0xCCE04040));
    if (showG) draw(g, const Color(0xCC40C040));
    if (showB) draw(b, const Color(0xCC4080E0));

    // 坐标轴：左 + 底。
    final axisPaint = Paint()
      ..color = const Color(0x59FFFFFF)
      ..strokeWidth = 1;
    canvas.drawLine(
        Offset(plot.left, plot.top), Offset(plot.left, plot.bottom),
        axisPaint);
    canvas.drawLine(
        Offset(plot.left, plot.bottom), Offset(plot.right, plot.bottom),
        axisPaint);

    // X 轴刻度文字（0/64/128/192/255）。
    const ticks = [0, 64, 128, 192, 255];
    for (var i = 0; i < ticks.length; i++) {
      final tp = TextPainter(
        text: TextSpan(
          text: '${ticks[i]}',
          style: const TextStyle(fontSize: 8, color: Color(0xFF808080)),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      var dx = plot.left + ticks[i] / 255 * plot.width - tp.width / 2;
      if (i == 0) dx = plot.left;
      if (i == ticks.length - 1) dx = plot.right - tp.width;
      tp.paint(canvas, Offset(dx, plot.bottom + 2));
    }
  }

  @override
  bool shouldRepaint(_HistogramPainter old) =>
      old.r != r ||
      old.g != g ||
      old.b != b ||
      old.showR != showR ||
      old.showG != showG ||
      old.showB != showB;
}

/// 矢量示波器坐标格（参照经典矢量示波器面板）：外圈刻度环、U/V 轴、
/// 75%/100% 六色目标框、双三角连线（Mg-Yl-Cy / R-G-B）与色标文字。
/// 数据坐标：x = Cb（0 左 255 右），y = Cr（0 下 255 上），中心 (128,128)。
class VectorscopeGraticule extends CustomPainter {
  const VectorscopeGraticule();

  /// 100% 彩条的 (Cb, Cr) 目标点（BT.601，8bit 全范围）。
  static const _targets = <String, (double, double)>{
    'R': (85.3, 255.5),
    'Mg': (212.7, 234.6),
    'B': (255.5, 107.1),
    'Cy': (170.8, 0.5),
    'G': (43.4, 21.4),
    'Yl': (0.5, 148.9),
  };

  @override
  void paint(Canvas canvas, Size size) {
    // 数据区为中央 82% 的正方形（与显示图像的缩放一致），
    // 外圈刻度环（150 单位）画在数据区外侧的留白里。
    final ds = math.min(size.width, size.height) / 256 * 0.82;
    final center = size.center(Offset.zero);
    Offset at(double cb, double cr) =>
        center + Offset((cb - 128) * ds, (128 - cr) * ds);

    final faint = Paint()
      ..color = const Color(0x33FFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final line = Paint()
      ..color = const Color(0x66FFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    // 外圈 + 刻度环（2° 小刻度，10° 长刻度，朝内）。
    // 半径 150 单位：100% 彩条目标点（径向约 130-135）落在环内侧。
    final ringRadius = 150 * ds;
    canvas.drawCircle(center, ringRadius, faint);
    for (var deg = 0; deg < 360; deg += 2) {
      final a = deg * math.pi / 180;
      final dir = Offset(math.cos(a), math.sin(a));
      final len = deg % 10 == 0 ? 12 * ds : 5 * ds;
      canvas.drawLine(center + dir * ringRadius,
          center + dir * (ringRadius - len), faint);
    }

    // U/V 轴与轴上小刻度（每 32 单位）。
    canvas.drawLine(at(0, 128), at(255, 128), line);
    canvas.drawLine(at(128, 0), at(128, 255), line);
    for (var u = 32; u < 256; u += 32) {
      final t = 5 * ds;
      canvas.drawLine(at(u.toDouble(), 128) + Offset(0, -t),
          at(u.toDouble(), 128) + Offset(0, t), faint);
      canvas.drawLine(at(128, u.toDouble()) + Offset(-t, 0),
          at(128, u.toDouble()) + Offset(t, 0), faint);
    }
    _text(canvas, at(255, 128) + Offset(4 * ds, -12), 'U');
    _text(canvas, at(128, 255) + Offset(6 * ds, -2), 'V');

    // 六色目标框：100% 与 75%（径向 3/4 处）。
    final bh = 6 * ds; // 目标框半边长
    Offset box((double, double) p, Paint p0) {
      final c = at(p.$1, p.$2);
      canvas.drawRect(
          Rect.fromCenter(center: c, width: bh * 2, height: bh * 2), p0);
      return c;
    }

    final boxPaint = Paint()
      ..color = const Color(0x99FFFFFF)
      ..style = PaintingStyle.stroke;
    final centers100 = <String, Offset>{};
    for (final e in _targets.entries) {
      final p75 = (
        128 + (e.value.$1 - 128) * 0.75,
        128 + (e.value.$2 - 128) * 0.75,
      );
      box(p75, faint);
      centers100[e.key] = box(e.value, boxPaint);
    }

    // 双三角连线（按角度间隔取色：Mg-Yl-Cy 与 R-G-B）。
    for (final tri in [
      ['Mg', 'Yl', 'Cy'],
      ['R', 'G', 'B'],
    ]) {
      final path = Path()
        ..moveTo(centers100[tri[0]]!.dx, centers100[tri[0]]!.dy)
        ..lineTo(centers100[tri[1]]!.dx, centers100[tri[1]]!.dy)
        ..lineTo(centers100[tri[2]]!.dx, centers100[tri[2]]!.dy)
        ..close();
      canvas.drawPath(path, faint);
    }

    // 75% / 100% 标记（沿 R 方向参考线）。
    final r75 = at(128 + (85.3 - 128) * 0.75, 128 + (255.5 - 128) * 0.75);
    _text(canvas, r75 + Offset(-26 * ds, -14 * ds), '75%');
    _text(canvas, centers100['R']! + Offset(-30 * ds, -18 * ds), '100%');

    // 色标文字：沿径向放在 100% 目标框外侧。
    for (final e in _targets.entries) {
      final dir = Offset(e.value.$1 - 128, 128 - e.value.$2); // y 向上为正
      final len = dir.distance;
      final unit = len > 0 ? dir / len : Offset.zero;
      final pos = centers100[e.key]! + unit * (bh + 9 * ds);
      _textCentered(canvas, pos, e.key);
    }
  }

  void _text(Canvas canvas, Offset at, String s) {
    final tp = TextPainter(
      text: TextSpan(
          text: s,
          style: const TextStyle(fontSize: 10, color: Color(0xFF909090))),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  void _textCentered(Canvas canvas, Offset center, String s) {
    final tp = TextPainter(
      text: TextSpan(
          text: s,
          style: const TextStyle(fontSize: 10, color: Color(0xFF909090))),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(VectorscopeGraticule old) => false;
}

/// 立体声电平指示器：L/R 两条 LED 段式横条（上 L 下 R），
/// 绿（≤-20dB）/ 黄（-20~-6dB）/ 红（>-6dB）三段配色。
class _AudioLevelPainter extends CustomPainter {
  final double left;
  final double right;

  _AudioLevelPainter(this.left, this.right);

  static const _segments = 40;
  static const _gap = 1.0;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF101010));
    final barH = (size.height - 12) / 2;
    if (barH <= 0) return;
    _bar(canvas, Rect.fromLTWH(4, 4, size.width - 8, barH), left);
    _bar(canvas, Rect.fromLTWH(4, 8 + barH, size.width - 8, barH), right);
  }

  void _bar(Canvas canvas, Rect rect, double value) {
    final segW = (rect.width - (_segments - 1) * _gap) / _segments;
    if (segW <= 0) return;
    final lit = (value.clamp(0.0, 1.0) * _segments).round();
    final paint = Paint();
    for (var i = 0; i < _segments; i++) {
      final t = (i + 1) / _segments;
      paint.color = i >= lit
          ? const Color(0xFF2A2A2A)
          : t <= 0.66
              ? const Color(0xFF50C050)
              : t <= 0.9
                  ? const Color(0xFFD0C040)
                  : const Color(0xFFD04040);
      canvas.drawRect(
          Rect.fromLTWH(rect.left + i * (segW + _gap), rect.top, segW,
              rect.height),
          paint);
    }
  }

  @override
  bool shouldRepaint(_AudioLevelPainter old) =>
      old.left != left || old.right != right;
}

/// 音频波形显示器：L/R 两行（上 L 绿、下 R 蓝），逐列画 min..max
/// 竖线，中线为 0 电平。
class _AudioWaveformPainter extends CustomPainter {
  final Float32List lMin;
  final Float32List lMax;
  final Float32List rMin;
  final Float32List rMax;

  _AudioWaveformPainter(this.lMin, this.lMax, this.rMin, this.rMax);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF101010));
    final rowH = size.height / 2;
    if (rowH < 2) return;
    _row(canvas, Rect.fromLTWH(0, 0, size.width, rowH), lMin, lMax,
        const Color(0xFF50C080));
    _row(canvas, Rect.fromLTWH(0, rowH, size.width, rowH), rMin, rMax,
        const Color(0xFF5080C0));
  }

  void _row(Canvas canvas, Rect rect, Float32List mins, Float32List maxs,
      Color color) {
    final centerY = rect.top + rect.height / 2;
    // 0 电平中线。
    canvas.drawRect(
        Rect.fromLTWH(rect.left, centerY - 0.5, rect.width, 1),
        Paint()..color = const Color(0xFF3A3A3A));
    final columns = mins.length;
    if (columns == 0) return;
    final amp = rect.height / 2 - 1;
    final paint = Paint()
      ..color = color
      ..strokeWidth = math.max(1, rect.width / columns - 1);
    for (var c = 0; c < columns; c++) {
      final x = rect.left + (c + 0.5) * rect.width / columns;
      final y1 = centerY - maxs[c] * amp;
      final y2 = centerY - mins[c] * amp;
      canvas.drawLine(Offset(x, y1), Offset(x, y2), paint);
    }
  }

  @override
  bool shouldRepaint(_AudioWaveformPainter old) => true;
}

/// 21 段音频 EQ 频谱：竖条自下而上，颜色随幅度绿→黄→红。
class _AudioEqPainter extends CustomPainter {
  final Float64List bands;

  _AudioEqPainter(this.bands);

  static const _gap = 2.0;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF101010));
    final n = bands.length;
    if (n == 0) return;
    final barW = (size.width - (n - 1) * _gap) / n;
    if (barW <= 0) return;
    final paint = Paint();
    for (var i = 0; i < n; i++) {
      final v = bands[i].clamp(0.0, 1.0);
      if (v <= 0) continue;
      final bh = v * (size.height - 4);
      paint.color = v <= 0.66
          ? const Color(0xFF50C050)
          : v <= 0.9
              ? const Color(0xFFD0C040)
              : const Color(0xFFD04040);
      canvas.drawRect(
          Rect.fromLTWH(i * (barW + _gap), size.height - 2 - bh, barW, bh),
          paint);
    }
  }

  @override
  bool shouldRepaint(_AudioEqPainter old) => true;
}
