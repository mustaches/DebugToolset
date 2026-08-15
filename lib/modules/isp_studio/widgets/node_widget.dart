/// ISP Studio 节点卡片：标题栏、端口行与类型附加控件。
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../providers/isp_studio_state.dart';
import '../models/isp_node.dart';
import '../pipeline/audio_analysis.dart';
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
    final isPrimary = node.id == state.primarySelectedNodeId;
    final isSecondary = !isPrimary && state.selectedNodeIds.contains(node.id);
    final isSelected = isPrimary || isSecondary;

    final borderColor = isPrimary
        ? const Color(0xFFFFC107)
        : isSecondary
            ? const Color(0xFF2196F3)
            : const Color(0xFF3A3A3A);

    final boxShadows = isPrimary
        ? const [
            BoxShadow(
              color: Color(0x99FFC107),
              blurRadius: 10,
              spreadRadius: 1,
            ),
            BoxShadow(
              color: Colors.black45,
              blurRadius: 6,
              offset: Offset(0, 2),
            ),
          ]
        : isSecondary
            ? const [
                BoxShadow(
                  color: Color(0x992196F3),
                  blurRadius: 8,
                  spreadRadius: 1,
                ),
                BoxShadow(
                  color: Colors.black45,
                  blurRadius: 6,
                  offset: Offset(0, 2),
                ),
              ]
            : const [
                BoxShadow(
                  color: Colors.black45,
                  blurRadius: 6,
                  offset: Offset(0, 2),
                ),
              ];

    return GestureDetector(
      // 点击卡片任意位置选中节点（端口圆点、按钮等内部手势优先）。
      // 节点拖动由画布的右键拖拽统一处理；删除只走键盘 Delete。
      onTap: () {
        final isMulti = HardwareKeyboard.instance.isShiftPressed ||
            HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isMetaPressed;
        state.selectNode(node.id, multiSelect: isMulti);
      },
      child: Container(
        width: node.width,
        height: nodeHeight(type,
            previewExtraHeight: state.previewExtraHeight(node.id)),
        decoration: BoxDecoration(
          color: const Color(0xFF252525),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: borderColor,
            width: isSelected ? 2 : 1,
          ),
          boxShadow: boxShadows,
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
  /// 播放中的仪器刷新走 [IspStudioState.instrumentTick]，只有本区重建。
  Widget _buildInstrumentExtra(IspStudioState state) {
    return ValueListenableBuilder<int>(
      valueListenable: state.instrumentTick,
      builder: (context, tick, child) => _buildInstrumentExtraContent(state),
    );
  }

  Widget _buildInstrumentExtraContent(IspStudioState state) {
    const hint =
        Text('未运行', style: TextStyle(fontSize: 11, color: Colors.grey));
    final extra = state.previewExtraHeight(node.id);
    Widget content;
    if (type.typeId == 'histogram') {
      final result = state.instrumentResults[node.id];
      final visible = state.histogramChannels(node.id);
      content = Column(
        children: [
          // 通道勾选行（Y 单选，R/G/B 多选且与 Y 互斥）。
          SizedBox(
            height: 16,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (final (ch, label, color) in [
                  ('y', 'Y', const Color(0xFFFFFFFF)),
                  ('r', 'R', const Color(0xFFFF0000)),
                  ('g', 'G', const Color(0xFF00FF00)),
                  ('b', 'B', const Color(0xFF0000FF)),
                ])
                  _channelToggle(state, ch, label, color,
                      visible.contains(ch)),
              ],
            ),
          ),
          Expanded(
            // SizedBox.expand：无 child 的 CustomPaint 在松散约束下会
            // 塌缩成 0 宽，这里强制占满。
            // 格线与框线由 painter 常显（未运行时也绘制）；
            // 通道数据为空时中央放提示文字（与波形节点一致）。
            child: SizedBox.expand(
              child: CustomPaint(
                painter: _HistogramPainter(
                  r: result?['r'] as Uint32List?,
                  g: result?['g'] as Uint32List?,
                  b: result?['b'] as Uint32List?,
                  y: result?['y'] as Uint32List?,
                  showR: visible.contains('r'),
                  showG: visible.contains('g'),
                  showB: visible.contains('b'),
                  showY: visible.contains('y'),
                ),
                child: result == null ? const Center(child: hint) : null,
              ),
            ),
          ),
        ],
      );
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
      // 表盘常显（与波形节点一致）：未运行时按静音状态绘制
      // （两条空条 + 刻度，dB 值显示 -∞）。
      content = CustomPaint(
          painter: _AudioLevelPainter(
              (result?['left'] as num?)?.toDouble() ?? 0,
              (result?['right'] as num?)?.toDouble() ?? 0),
          child: const SizedBox.expand());
    } else if (type.typeId == 'audio_waveform') {
      final result = state.instrumentResults[node.id];
      // 表盘常显（与电平/EQ 一致）：未运行时按静音状态绘制
      // （只有格线、边框、L/R 标识与 0 电平中线）。
      // 顶部一行显示音频格式（采样率/采样深度，亮白色）。
      content = Column(
        children: [
          SizedBox(
            height: 14,
            child: Center(
              child: Text(
                result == null ? '' : _audioFormatText(result),
                style: const TextStyle(fontSize: 9, color: Colors.white),
              ),
            ),
          ),
          Expanded(
            child: CustomPaint(
              painter: _AudioWaveformPainter(
                result?['l'] as Float32List? ?? Float32List(0),
                result?['r'] as Float32List? ?? Float32List(0),
              ),
              child: const SizedBox.expand(),
            ),
          ),
        ],
      );
    } else if (type.typeId == 'audio_eq') {
      final result = state.instrumentResults[node.id];
      // 表盘常显（与波形节点一致）：未运行时按静音状态绘制
      // （全零频段：只有边框、刻度与频率标签，柱子全暗）。
      content = CustomPaint(
          painter: _AudioEqPainter(
              result?['left'] as Float64List? ?? Float64List(kAudioEqBands),
              result?['right'] as Float64List? ?? Float64List(kAudioEqBands)),
          child: const SizedBox.expand());
    } else if (type.typeId == 'waveform') {
      final image = state.instrumentImages[node.id];
      final visible = state.waveformChannels(node.id);
      content = Column(
        children: [
          // 通道勾选行（Y 单选，R/G/B 多选且与 Y 互斥）。
          SizedBox(
            height: 16,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (final (ch, label, color) in [
                  ('y', 'Y', const Color(0xFFFFFFFF)),
                  ('r', 'R', const Color(0xFFFF0000)),
                  ('g', 'G', const Color(0xFF00FF00)),
                  ('b', 'B', const Color(0xFF0000FF)),
                ])
                  _waveformChannelButton(
                      state, ch, label, color, visible.contains(ch)),
              ],
            ),
          ),
          Expanded(
            child: SizedBox.expand(
              child: CustomPaint(
                foregroundPainter: const WaveformGraticule(),
                child: Padding(
                  padding: const EdgeInsets.only(
                      left: WaveformGraticule.labelWidth),
                  child: image == null
                      ? const Center(child: hint)
                      : RawImage(image: image, fit: BoxFit.fill),
                ),
              ),
            ),
          ),
        ],
      );
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

  /// 波形监视器通道勾选项：彩色小方块 + 字母标签（样式与直方图通道
  /// 勾选一致；Y 单选，R/G/B 多选且与 Y 互斥）。
  Widget _waveformChannelButton(IspStudioState state, String ch, String label,
      Color color, bool on) {
    return InkWell(
      onTap: () => state.toggleWaveformChannel(node.id, ch),
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
    // 视频格式输入组（RGB/YUV/HSL）互斥：同组已有其他路接入时
    // 该端口置灰（圆点 + 标签），落点命中也会跳过它。
    final inDisabled = hasIn &&
        !state.graph
            .videoInputPortAvailable(node.id, type.inputs[index].name);
    const labelStyle = TextStyle(fontSize: 11, color: Colors.grey);
    const disabledLabelStyle =
        TextStyle(fontSize: 11, color: Color(0xFF4A4A4A));
    return SizedBox(
      height: kPortRowHeight,
      child: Row(
        children: [
          if (hasIn)
            _inputDot(state, type.inputs[index], disabled: inDisabled)
          else
            const SizedBox(width: kPortRadius * 2),
          if (hasIn)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(type.inputs[index].label,
                  style: inDisabled ? disabledLabelStyle : labelStyle),
            ),
          const Spacer(),
          if (hasOut)
            _outputArea(state, type.outputs[index], labelStyle)
          else
            const SizedBox(width: kPortRadius * 2),
        ],
      ),
    );
  }

  /// 输出端口区：标签 + 圆点整体都是拉线命中区（比只点 10px 圆点
  /// 成功率高得多）。命中区全在 Row 自身范围内——Row 只命中测试
  /// 自身范围内的点，直接把圆点平移出节点边缘会让探出的那一半
  /// 点不到；视觉圆点经 Align+平移保持圆心在节点右边缘。
  Widget _outputArea(
      IspStudioState state, IspPortSpec port, TextStyle labelStyle) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (d) => state.beginConnectionDrag(
          node.id, port.name, globalToCanvas(d.globalPosition)),
      onPanUpdate: (d) =>
          state.updateConnectionDrag(globalToCanvas(d.globalPosition)),
      onPanEnd: (_) => onConnectionDragEnd(),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Text(port.label, style: labelStyle),
          ),
          SizedBox(
            width: kPortRadius * 3,
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
        ],
      ),
    );
  }

  Widget _dot(IspPortSpec port, bool connected, {bool disabled = false}) {
    return Container(
      width: kPortRadius * 2,
      height: kPortRadius * 2,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: disabled ? const Color(0xFF2E2E2E) : portColor(port.type),
        border: connected ? Border.all(color: Colors.white54) : null,
      ),
    );
  }

  /// 输入端口：圆心位于节点左边缘（x = 0），点击断开已有连接。
  /// [disabled] 为视频输入组互斥置灰（同组已有其他路接入）。
  Widget _inputDot(IspStudioState state, IspPortSpec port,
      {bool disabled = false}) {
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
              child: _dot(port, connected, disabled: disabled),
            ),
          ),
        ),
      ),
    );
  }

  /// 预览附加区：屏幕 + 播放控制条 + 底部拖动手柄（调整屏幕高度）。
  /// 逐帧刷新走 [IspStudioState.frameTick]，只有本区重建。
  Widget _buildPreviewExtra(IspStudioState state) {
    return ValueListenableBuilder<int>(
      valueListenable: state.frameTick,
      builder: (context, tick, child) => _buildPreviewExtraContent(state),
    );
  }

  Widget _buildPreviewExtraContent(IspStudioState state) {
    final image = state.previewImages[node.id];
    final plane = state.previewPlanes[node.id];
    final shader = state.yuvPlaneShader;
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
              // GPU 平面帧（全分辨率视频播放）优先于 CPU 像素图。
              child: plane != null && shader != null
                  ? SizedBox.expand(
                      child: CustomPaint(
                          painter: _PlanePreviewPainter(plane, shader)))
                  : image != null
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

  /// 底部手柄条：中间上下拖调整高度，右下角控制点双向调整宽高。
  /// 预览与仪器节点共用。
  Widget _buildResizeBar(IspStudioState state) {
    return SizedBox(
      height: 10,
      child: Stack(
        children: [
          // 中部：上下拖只调整高度（忽略横向位移）。
          Align(
            alignment: Alignment.center,
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeUpDown,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                dragStartBehavior: DragStartBehavior.down,
                onPanStart: (_) => state.beginNodeResize(node.id),
                onPanUpdate: (d) => state.resizePreview(
                    node.id, Offset(0, d.delta.dy) / state.canvasZoom),
                onPanEnd: (_) => state.endNodeResize(),
                onPanCancel: () => state.endNodeResize(),
                child: const SizedBox(
                  width: 40,
                  height: 10,
                  child: Center(
                    child: Icon(Icons.drag_handle, size: 10, color: Colors.grey),
                  ),
                ),
              ),
            ),
          ),
          // 右下角：双向拖同时调整宽高。
          Align(
            alignment: Alignment.centerRight,
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeUpLeftDownRight,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                dragStartBehavior: DragStartBehavior.down,
                onPanStart: (_) => state.beginNodeResize(node.id),
                onPanUpdate: (d) =>
                    state.resizePreview(node.id, d.delta / state.canvasZoom),
                onPanEnd: (_) => state.endNodeResize(),
                onPanCancel: () => state.endNodeResize(),
                child: const SizedBox(
                  width: 16,
                  height: 10,
                  child: Center(
                    child: Icon(Icons.south_east, size: 10, color: Colors.grey),
                  ),
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

/// RGB+Y 直方图绘制：对数刻度，通道竖条叠加（每亮度级一根，Y 为白色）。
/// 网格线与完整框线常显（通道数据全为空 = 未运行时也绘制，与波形
/// 节点一致）。绘图区左侧留 [_labelWidth] 显示纵轴统计值（对数刻度
/// 计数，写在格线左边），底部留 [_axisBottom] 显示 X 轴亮度刻度
/// （0..255）。所有文字亮白色。
class _HistogramPainter extends CustomPainter {
  final Uint32List? r;
  final Uint32List? g;
  final Uint32List? b;
  final Uint32List? y;
  final bool showR;
  final bool showG;
  final bool showB;
  final bool showY;

  /// 左侧纵轴统计值区宽度。
  static const double _labelWidth = 30;

  /// 底部 X 轴刻度区高度。
  static const double _axisBottom = 14;

  static const _textStyle = TextStyle(fontSize: 8, color: Colors.white);

  _HistogramPainter({
    this.r,
    this.g,
    this.b,
    this.y,
    this.showR = true,
    this.showG = true,
    this.showB = true,
    this.showY = false,
  });

  /// 计数值的紧凑格式（1.2K / 3.4M），纵轴空间窄。
  static String _fmtCount(int v) {
    if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M';
    if (v >= 10000) return '${v ~/ 1000}K';
    if (v >= 1000) return '${(v / 1000).toStringAsFixed(1)}K';
    return '$v';
  }

  @override
  void paint(Canvas canvas, Size size) {
    // 绘图区内缩：左侧给纵轴统计值、底部给 X 轴刻度文字留位。
    final plot = Rect.fromLTWH(_labelWidth, 2,
        size.width - _labelWidth - 2, size.height - _axisBottom - 2);
    if (plot.width <= 0 || plot.height <= 0) return;

    // 网格（未运行时也绘制）：X 四等分（0/64/128/192/255），Y 四等分。
    final gridPaint = Paint()
      ..color = const Color(0x2EFFFFFF)
      ..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      final dx = plot.left + plot.width * i / 4;
      canvas.drawLine(
          Offset(dx, plot.top), Offset(dx, plot.bottom), gridPaint);
      final dy = plot.top + plot.height * i / 4;
      canvas.drawLine(
          Offset(plot.left, dy), Offset(plot.right, dy), gridPaint);
    }

    // 数据（未运行时全为空，只画格线/框线/横轴刻度）。
    var max = 1;
    final hasData = r != null || g != null || b != null || y != null;
    if (hasData) {
      // 可见通道的最大值（归一化基准）。
      for (final (bins, show)
          in [(r, showR), (g, showG), (b, showB), (y, showY)]) {
        if (!show || bins == null) continue;
        for (final c in bins) {
          if (c > max) max = c;
        }
      }
    }
    final logMax = math.log(max + 1);

    // 通道竖条（只画勾选通道）：每个亮度级一根竖条，
    // 稀疏数据不会被折线插值成三角形。
    if (hasData) {
      final barWidth = plot.width / 256;
      void draw(Uint32List bins, Color color) {
        final paint = Paint()
          ..color = color
          ..blendMode = BlendMode.screen;
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

      final r = this.r, g = this.g, b = this.b, y = this.y;
      if (showR && r != null) draw(r, const Color(0xCCFF0000));
      if (showG && g != null) draw(g, const Color(0xCC00FF00));
      if (showB && b != null) draw(b, const Color(0xCC0000FF));
      if (showY && y != null) draw(y, const Color(0xCCFFFFFF));
    }

    // 完整框线（未运行时也绘制）。
    final axisPaint = Paint()
      ..color = const Color(0x59FFFFFF)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    canvas.drawRect(plot, axisPaint);

    // 纵轴统计值：各水平格线（含顶端）对应的对数刻度计数，
    // 右对齐写在格线左边（有数据时才绘制）。
    if (hasData) {
      for (var i = 1; i <= 4; i++) {
        final t = i / 4;
        final value = (math.exp(logMax * t) - 1).round();
        final tp = TextPainter(
          text: TextSpan(text: _fmtCount(value), style: _textStyle),
          textDirection: TextDirection.ltr,
        )..layout();
        final dy = plot.bottom - plot.height * t;
        tp.paint(canvas, Offset(plot.left - 3 - tp.width,
            (dy - tp.height / 2).clamp(0.0, size.height - tp.height)));
      }
    }

    // X 轴刻度文字（亮度 0/64/128/192/255，未运行时也绘制）。
    const ticks = [0, 64, 128, 192, 255];
    for (var i = 0; i < ticks.length; i++) {
      final tp = TextPainter(
        text: TextSpan(text: '${ticks[i]}', style: _textStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      var dx = plot.left + ticks[i] / 255 * plot.width - tp.width / 2;
      if (i == 0) dx = plot.left;
      if (i == ticks.length - 1) dx = plot.right - tp.width;
      tp.paint(canvas, Offset(dx, plot.bottom + 3));
    }
  }

  @override
  bool shouldRepaint(_HistogramPainter old) =>
      old.r != r ||
      old.g != g ||
      old.b != b ||
      old.y != y ||
      old.showR != showR ||
      old.showG != showG ||
      old.showB != showB ||
      old.showY != showY;
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
          style: const TextStyle(fontSize: 10, color: Color(0xFFFFFFFF))),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  void _textCentered(Canvas canvas, Offset center, String s) {
    final tp = TextPainter(
      text: TextSpan(
          text: s,
          style: const TextStyle(fontSize: 10, color: Color(0xFFFFFFFF))),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(VectorscopeGraticule old) => false;
}

/// 波形监视器标准坐标格：外框 + 横向 10 等分（纵轴 0% 在底，
/// 50% 中线加亮）、纵向 10 等分。左侧留 [labelWidth] 级标区，
/// 0/25/50/75/100 级标在格线外面。前景层叠加在迹线图上
/// （未运行时也有格线）。
class WaveformGraticule extends CustomPainter {
  const WaveformGraticule();

  /// 左侧级标区宽度（级标画在格线外，格线与迹线相应内缩）。
  static const labelWidth = 16.0;

  @override
  void paint(Canvas canvas, Size size) {
    final rect =
        Rect.fromLTWH(labelWidth, 0, size.width - labelWidth, size.height);
    if (rect.width <= 0 || rect.height <= 0) return;
    final faint = Paint()
      ..color = const Color(0x33FFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final line = Paint()
      ..color = const Color(0x66FFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    canvas.drawRect(rect, line);
    // 横线：纵轴 10 等分，50% 中线用主线。
    for (var i = 1; i < 10; i++) {
      final y = rect.top + rect.height * i / 10;
      canvas.drawLine(Offset(rect.left, y), Offset(rect.right, y),
          i == 5 ? line : faint);
    }
    // 竖线：横轴 10 等分。
    for (var i = 1; i < 10; i++) {
      final x = rect.left + rect.width * i / 10;
      canvas.drawLine(Offset(x, rect.top), Offset(x, rect.bottom), faint);
    }
    // 级标：格线左侧（右对齐，亮白色），0% 在底，100% 在顶。
    for (final pct in [0, 25, 50, 75, 100]) {
      final y = rect.top + rect.height * (100 - pct) / 100;
      final tp = TextPainter(
        text: TextSpan(
            text: '$pct',
            style: const TextStyle(
                fontSize: 7, color: Color(0xFFFFFFFF), height: 1)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(
          canvas,
          Offset(rect.left - 2 - tp.width,
              (y - tp.height / 2).clamp(rect.top, rect.bottom - tp.height)));
    }
  }

  @override
  bool shouldRepaint(WaveformGraticule old) => false;
}

/// 音频类仪器（电平/波形/EQ）中所有字符的统一颜色：亮白色。
const _kAudioTextColor = Color(0xFFFFFFFF);

/// 音频波形顶部的格式文字（采样率/采样深度），如 "44.1kHz 16bit"。
String _audioFormatText(Map<String, Object?> result) {
  final sr = (result['sampleRate'] as num?)?.toInt() ?? 0;
  final bits = (result['bits'] as num?)?.toInt() ?? 0;
  if (sr <= 0 || bits <= 0) return '';
  final k = sr / 1000;
  final srText = k == k.roundToDouble()
      ? '${k.round()}kHz'
      : '${k.toStringAsFixed(1)}kHz';
  return '$srText ${bits}bit';
}

/// 立体声电平指示器：L/R 两条 LED 段式横条（上 L 下 R），
/// 绿（≤-20dB）/ 黄（-20~-6dB）/ 红（>-6dB）三段配色。
/// 顶部为 dB 刻度，条左为 L/R 通道标识，条右为当前峰值 dB 值。
class _AudioLevelPainter extends CustomPainter {
  final double left;
  final double right;

  _AudioLevelPainter(this.left, this.right);

  /// LED 段数：100 段。
  static const _segments = 100;
  static const _gap = 1.0;

  /// dB 刻度下限（与 audio_analysis.kAudioLevelFloorDb 一致）；
  /// 显示值 0..1 线性对应 -60..0 dBFS。
  static const _dbFloor = -60.0;

  /// 顶部标注的 dB 刻度。
  static const _tickDbs = [-60, -40, -20, -6, 0];

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF101010));
    const scaleH = 10.0; // 顶部 dB 刻度行高
    const labelW = 12.0; // 左侧 L/R 标识宽
    const valueW = 32.0; // 右侧 dB 数值宽
    final barX = 4 + labelW;
    final barW = size.width - barX - valueW - 4;
    final barH = (size.height - scaleH - 14) / 2;
    if (barW <= 0 || barH <= 0) return;
    final rectL = Rect.fromLTWH(barX, scaleH + 2, barW, barH);
    final rectR = Rect.fromLTWH(barX, scaleH + 6 + barH, barW, barH);
    _scale(canvas, rectL);
    _bar(canvas, rectL, left);
    _bar(canvas, rectR, right);
    _channelLabel(canvas, 'L', rectL);
    _channelLabel(canvas, 'R', rectR);
    _dbValue(canvas, left, rectL);
    _dbValue(canvas, right, rectR);
  }

  /// 顶部 dB 刻度标签（与条的横向位置对齐）。
  void _scale(Canvas canvas, Rect barRect) {
    for (final db in _tickDbs) {
      final t = (db - _dbFloor) / -_dbFloor;
      final x = barRect.left + t * barRect.width;
      final tp = _textPainter('$db', 7, _kAudioTextColor);
      // 居中于刻度位置，两端钳制在画布内。
      final dx = (x - tp.width / 2).clamp(0.0, barRect.right - tp.width);
      tp.paint(canvas, Offset(dx, 1));
    }
  }

  /// 条左侧的通道标识（L/R），垂直居中。
  void _channelLabel(Canvas canvas, String label, Rect barRect) {
    final tp = _textPainter(label, 9, _kAudioTextColor);
    tp.paint(
        canvas,
        Offset(barRect.left - 2 - tp.width,
            barRect.top + (barRect.height - tp.height) / 2));
  }

  /// 条右侧的当前峰值 dB 值，垂直居中。
  void _dbValue(Canvas canvas, double value, Rect barRect) {
    final text = value <= 0
        ? '-∞'
        : (value * -_dbFloor + _dbFloor).toStringAsFixed(1);
    final tp = _textPainter(text, 8, _kAudioTextColor);
    tp.paint(
        canvas,
        Offset(barRect.right + 3,
            barRect.top + (barRect.height - tp.height) / 2));
  }

  TextPainter _textPainter(String text, double fontSize, Color color) =>
      TextPainter(
        text: TextSpan(
            text: text,
            style: TextStyle(color: color, fontSize: fontSize, height: 1)),
        textDirection: TextDirection.ltr,
      )..layout();

  void _bar(Canvas canvas, Rect rect, double value) {
    final segW = (rect.width - (_segments - 1) * _gap) / _segments;
    if (segW <= 0) return;
    final lit = (value.clamp(0.0, 1.0) * _segments).round();
    final paint = Paint();
    for (var i = 0; i < _segments; i++) {
      final t = (i + 1) / _segments;
      paint.color = i >= lit
          ? const Color(0xFF151515)
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

/// 音频波形显示器：L/R 两行（上 L 绿、下 R 蓝），采样点光滑连线成
/// 示波器式迹线。每行带完整边框与横向格线（±1.0/±0.5/0 五档，
/// 0 电平中线加强），行内左上为 L/R 通道标识，格线左边为电平刻度
/// （线性振幅，亮白色）。表盘常显：无数据（静音）时只剩格线与
/// 0 电平中线。
class _AudioWaveformPainter extends CustomPainter {
  /// 左/右声道的降采样点（-1..1，等距）。
  final Float32List l;
  final Float32List r;

  _AudioWaveformPainter(this.l, this.r);

  /// 每行的电平格线档位（线性振幅，0 为中线）。
  static const _levelTicks = [1.0, 0.5, 0.0, -0.5, -1.0];

  /// 左侧电平刻度区宽度。
  static const _labelWidth = 22.0;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF101010));
    final rowH = size.height / 2;
    if (rowH < 2) return;
    _row(canvas, Rect.fromLTWH(0, 0, size.width, rowH), l,
        const Color(0xFF50C080), 'L');
    _row(canvas, Rect.fromLTWH(0, rowH, size.width, rowH), r,
        const Color(0xFF5080C0), 'R');
  }

  void _row(Canvas canvas, Rect rect, Float32List samples, Color color,
      String label) {
    // 绘图区：左侧内缩出电平刻度区，四边各留 1px 给边框。
    final plot = Rect.fromLTWH(rect.left + _labelWidth, rect.top + 1,
        rect.width - _labelWidth - 2, rect.height - 2);
    if (plot.width <= 0 || plot.height <= 0) return;
    final centerY = plot.top + plot.height / 2;
    final amp = plot.height / 2;

    // 横向格线 + 左侧电平刻度（格线左边，亮白色）。
    final gridPaint = Paint()
      ..color = const Color(0x2EFFFFFF)
      ..strokeWidth = 1;
    final zeroPaint = Paint()
      ..color = const Color(0x59FFFFFF)
      ..strokeWidth = 1;
    for (final tick in _levelTicks) {
      final y = centerY - tick * amp;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y),
          tick == 0 ? zeroPaint : gridPaint);
      final tp = TextPainter(
        text: TextSpan(
          text: tick == 0 ? '0' : tick.toStringAsFixed(1),
          style: const TextStyle(
              color: _kAudioTextColor, fontSize: 7, height: 1),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(
          canvas,
          Offset(
              plot.left - 2 - tp.width,
              (y - tp.height / 2)
                  .clamp(plot.top, plot.bottom - tp.height)));
    }

    // 迹线：采样点依次光滑连线（无数据时跳过，只剩格线 = 静音状态）。
    if (samples.isNotEmpty) {
      final ampData = amp - 1;
      final path = Path();
      for (var i = 0; i < samples.length; i++) {
        final x = samples.length == 1
            ? plot.left + plot.width / 2
            : plot.left + i * plot.width / (samples.length - 1);
        final y = centerY - samples[i] * ampData;
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(
          path,
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.75
            ..strokeJoin = StrokeJoin.round
            ..strokeCap = StrokeCap.round);
    }

    // 完整边框（压在迹线上，与 EQ 频谱同一风格）。
    canvas.drawRect(
        plot,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = const Color(0xFF3A3A3A));

    // 框内侧左上角的通道标识（L/R）。
    final tp = TextPainter(
      text: TextSpan(
        text: label,
        style: const TextStyle(
            color: _kAudioTextColor, fontSize: 9, height: 1),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(plot.left + 3, plot.top + 2));
  }

  @override
  bool shouldRepaint(_AudioWaveformPainter old) => true;
}

/// 31 段音频 EQ 频谱：左 L 右 R 两组格子柱（与电平表一致的段式显示，
/// 每柱 40 格、格间 1px、柱间 2px，颜色随高度绿→黄→红），
/// 每组用暗灰色边框围起，L/R 标识在框内侧左上角，dB 刻度竖向标注在
/// 两框中间（0/-20/-40/-60，与电平表同为 -60dB 起步）；
/// 每组内每段下方竖排标注中心频率（20Hz–20kHz，1/3 倍频程等距）。
class _AudioEqPainter extends CustomPainter {
  final Float64List left;
  final Float64List right;

  _AudioEqPainter(this.left, this.right);

  /// 频率柱子之间的间隔。
  static const _gap = 2.0;

  /// 每根柱子的格子数（格间固定 1px）。
  static const _cells = 40;

  /// 格子之间的间隔。
  static const _cellGap = 1.0;

  /// 侧边标注的 dB 刻度。
  static const _dbTicks = [0, -20, -40, -60];

  /// 底部中心频率标签区高度（竖排文字）。
  static const _labelH = 26.0;

  /// 左右两组之间的间隔（中间放 dB 刻度，需容纳 "-60" 宽的文字）。
  static const _midGap = 20.0;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF101010));
    final n = left.length;
    if (n == 0) return;
    final halfW = (size.width - 8 - _midGap) / 2;
    // 框底部与下方频率标签顶部之间留 2px（柱子底部贴框底）。
    final boxH = size.height - _labelH - 4;
    if (halfW <= 0 || boxH <= 8) return;
    final boxL = Rect.fromLTWH(4, 2, halfW, boxH);
    final boxR = Rect.fromLTWH(4 + halfW + _midGap, 2, halfW, boxH);
    // 柱子区：框内缩 3px（底部不缩，贴框底边）。
    final rectL = Rect.fromLTRB(boxL.left + 3, boxL.top + 3,
        boxL.right - 3, boxL.bottom);
    final rectR = Rect.fromLTRB(boxR.left + 3, boxR.top + 3,
        boxR.right - 3, boxR.bottom);
    final barW = (rectL.width - (n - 1) * _gap) / n;
    if (barW <= 0) return;
    _bars(canvas, rectL, barW, left);
    _bars(canvas, rectR, barW, right);
    // 暗灰边框画在柱子之后，底边压在柱子下沿上。
    final border = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = const Color(0xFF3A3A3A);
    canvas.drawRect(boxL, border);
    canvas.drawRect(boxR, border);
    _channelLabel(canvas, 'L', boxL);
    _channelLabel(canvas, 'R', boxR);
    // dB 刻度：竖向标注在两框中间的中线上。
    _dbScale(canvas, rectL, 4 + halfW + _midGap / 2);
    // 每组内每段下方竖排中心频率标签（横向空间不足，文字竖排向下延伸）。
    final labelTop = size.height - _labelH;
    for (var rect in [rectL, rectR]) {
      for (var i = 0; i < n; i++) {
        final cx = rect.left + i * (barW + _gap) + barW / 2;
        _freqLabel(canvas, _freqText(i), Offset(cx, labelTop));
      }
    }
  }

  /// 一组格子柱：每柱 40 格自下而上点亮，格间 1px，
  /// 颜色按格子高度绿（≤66%）/黄（≤90%）/红，未点亮为暗灰。
  void _bars(Canvas canvas, Rect rect, double barW, Float64List bands) {
    final cellH = (rect.height - (_cells - 1) * _cellGap) / _cells;
    if (cellH <= 0) return;
    final paint = Paint();
    for (var i = 0; i < bands.length; i++) {
      final v = bands[i].clamp(0.0, 1.0);
      final lit = (v * _cells).round();
      final x = rect.left + i * (barW + _gap);
      for (var c = 0; c < _cells; c++) {
        final t = (c + 1) / _cells;
        paint.color = c >= lit
            ? const Color(0xFF151515)
            : t <= 0.66
                ? const Color(0xFF50C050)
                : t <= 0.9
                    ? const Color(0xFFD0C040)
                    : const Color(0xFFD04040);
        canvas.drawRect(
            Rect.fromLTWH(
                x, rect.bottom - (c + 1) * (cellH + _cellGap) + _cellGap,
                barW, cellH),
            paint);
      }
    }
  }

  /// 框内侧左上角的通道标识（L/R）。
  void _channelLabel(Canvas canvas, String label, Rect boxRect) {
    final tp = TextPainter(
      text: TextSpan(
          text: label,
          style:
              const TextStyle(color: _kAudioTextColor, fontSize: 9, height: 1)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(boxRect.left + 4, boxRect.top + 2));
  }

  /// 在两框中间（[centerX] 中线）竖向标注 dB 刻度。
  /// 刻度按电平表同一映射定位：0..1 对应 -60..0 dBFS。
  void _dbScale(Canvas canvas, Rect rect, double centerX) {
    for (final db in _dbTicks) {
      final t = (db - kAudioLevelFloorDb) / -kAudioLevelFloorDb;
      final y = rect.bottom - t * rect.height;
      final tp = TextPainter(
        text: TextSpan(
            text: '$db',
            style: const TextStyle(
                color: _kAudioTextColor, fontSize: 7, height: 1)),
        textDirection: TextDirection.ltr,
      )..layout();
      final dy = (y - tp.height / 2).clamp(rect.top, rect.bottom - tp.height);
      tp.paint(canvas, Offset(centerX - tp.width / 2, dy));
    }
  }

  /// 竖排频率标签：以 [topCenter] 为顶端中点，文字从上往下读
  /// （顺时针转 90°，向下延伸，不会伸进上方的柱子区）。
  void _freqLabel(Canvas canvas, String text, Offset topCenter) {
    final tp = TextPainter(
      text: TextSpan(
          text: text,
          style:
              const TextStyle(color: _kAudioTextColor, fontSize: 7, height: 1)),
      textDirection: TextDirection.ltr,
    )..layout();
    canvas.save();
    canvas.translate(topCenter.dx, topCenter.dy);
    canvas.rotate(math.pi / 2);
    tp.paint(canvas, Offset(1, -tp.height / 2));
    canvas.restore();
  }

  /// 第 [b] 段的中心频率紧凑写法（如 20、63、1k、12.6k）。
  String _freqText(int b) {
    final f = audioEqBandCenterHz(b);
    if (f < 995) return f.round().toString();
    final s = (f / 1000).toStringAsFixed(1);
    return '${s.endsWith('.0') ? s.substring(0, s.length - 2) : s}k';
  }

  @override
  bool shouldRepaint(_AudioEqPainter old) => true;
}

/// GPU 平面预览绘制器：用 yuv_planes.frag 把打包纹理（Y/U/V 平面
/// 各 4 样本/纹素）按 [PlanePreviewFrame.mode] 解包上色，等比 contain
/// 适配绘制区域。全分辨率视频播放时预览的零 CPU 转换路径。
class _PlanePreviewPainter extends CustomPainter {
  final PlanePreviewFrame frame;
  final ui.FragmentShader shader;

  _PlanePreviewPainter(this.frame, this.shader);

  @override
  void paint(Canvas canvas, Size size) {
    // BoxFit.contain 等比适配。
    final srcAspect = frame.width / frame.height;
    double dw = size.width, dh = size.height;
    if (dw / dh > srcAspect) {
      dw = dh * srcAspect;
    } else {
      dh = dw / srcAspect;
    }
    final rect =
        Rect.fromLTWH((size.width - dw) / 2, (size.height - dh) / 2, dw, dh);
    shader
      ..setFloat(0, rect.left)
      ..setFloat(1, rect.top)
      ..setFloat(2, rect.width)
      ..setFloat(3, rect.height)
      ..setFloat(4, frame.width.toDouble())
      ..setFloat(5, frame.height.toDouble())
      ..setFloat(6, frame.mode.toDouble())
      ..setFloat(7, frame.limited ? 1.0 : 0.0)
      ..setImageSampler(0, frame.packed);
    canvas.drawRect(rect, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_PlanePreviewPainter old) => !identical(old.frame, frame);
}
