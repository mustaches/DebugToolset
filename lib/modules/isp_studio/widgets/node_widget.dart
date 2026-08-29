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
import '../pipeline/color_temp.dart';
import '../pipeline/levels_curve.dart';
import 'node_layout.dart';

/// ISP Studio 节点控制条（Slider）的统一主题：滑钮（控制点）直径为
/// Material 默认的一半（半径 10 → 5），所有带控制条的节点共用。
const SliderThemeData kIspSliderTheme = SliderThemeData(
  thumbShape: RoundSliderThumbShape(enabledThumbRadius: 5),
);

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

  /// 节点处于 Bypass（直通）模式：Process 类节点且 bypass 参数勾选。
  /// 置灰显示表示节点失效。
  bool get _bypassed =>
      IspNodeRegistry.isProcessType(type.typeId) &&
      node.paramValues['bypass'] == true;

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
            // Bypass 模式：端口与附加区整体半透明，表示节点失效。
            Opacity(
              opacity: _bypassed ? 0.4 : 1.0,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < rows; i++) ...[
                    // 端口分组间隔行（如混叠器的基图/蒙版/混叠图分组，
                    // 几何偏移见 node_layout.kPortGroupGapRows）。
                    if ((kPortGroupGapRows[type.typeId] ?? const <int>[])
                        .contains(i))
                      const SizedBox(height: kPortRowHeight),
                    _buildPortRow(state, i),
                  ],
                  if (type.typeId == 'multiplier')
                    _buildMultiplierOffsets(state),
                  if (type.typeId == 'adder') _buildAdderBalance(state),
                  if (type.typeId == 'mux4') _buildMux4Select(state),
                  if (type.typeId == 'preview') _buildPreviewExtra(state),
                  if (type.typeId == 'hsl_debugger')
                    _buildHslDebugExtra(state),
                  if (type.typeId == 'rgb_debugger')
                    _buildRgbDebugExtra(state),
                  if (type.typeId == 'yuv_debugger')
                    _buildYuvDebugExtra(state),
                  if (type.typeId == 'sat_bright_adjuster')
                    _buildSatBrightExtra(state),
                  if (type.typeId == 'bright_contrast_adjuster')
                    _buildBrightContrastExtra(state),
                  if (type.typeId == 'levels_curves')
                    _buildLevelsExtra(state),
                  if (type.typeId == 'color_balance')
                    _buildColorBalanceExtra(state),
                  if (type.typeId == 'color_temp_adjuster')
                    _buildColorTempExtra(state),
                  if (type.typeId == 'edge_extract')
                    _buildEdgeExtractExtra(state),
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
    } else if (type.typeId == 'psnr') {
      // PSNR 数字表：大字号 dB 值 + MSE；未运行/缺输入/尺寸不一致
      // 分别显示提示。完全相同（∞）以绿色突出。
      final result = state.instrumentResults[node.id];
      final err = result?['error'] as String?;
      final psnr = result?['psnr'] as double?;
      final mse = result?['mse'] as double?;
      content = Center(
        child: result == null
            ? hint
            : err != null
                ? Text(err,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 11, color: Colors.orangeAccent))
                : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // dB 跟在数值后面（同一行，基线对齐）。
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(
                            psnr!.isInfinite
                                ? '∞'
                                : psnr.toStringAsFixed(2),
                            style: TextStyle(
                              fontSize: 32,
                              fontWeight: FontWeight.bold,
                              color: psnr.isInfinite
                                  ? const Color(0xFF50C080)
                                  : Colors.white,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Text('dB',
                              style: TextStyle(
                                  fontSize: 20,
                                  color: Colors.grey.shade400)),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text('MSE ${mse!.toStringAsFixed(2)}',
                          style: TextStyle(
                              fontSize: 10, color: Colors.grey.shade500)),
                    ],
                  ),
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
        // Bypass 模式：标题栏置灰（暗灰 #2D2D2D），表示节点失效（直通）。
        color: _bypassed ? const Color(0xFF2D2D2D) : Color(type.colorValue),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(5)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              node.name,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // Bypass 直通勾选框（Process 类节点）：与属性面板的开关读写
          // 同一 paramValues['bypass']，经 setParam 自动双向同步。
          if (IspNodeRegistry.isProcessType(type.typeId))
            Tooltip(
              message: 'Bypass 直通',
              child: InkWell(
                onTap: () => state.setParam(
                    node.id, 'bypass', !(node.paramValues['bypass'] == true)),
                child: Padding(
                  padding: const EdgeInsets.only(right: 3),
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: node.paramValues['bypass'] == true
                          ? Colors.white
                          : Colors.transparent,
                      border: Border.all(color: Colors.white70),
                      borderRadius: BorderRadius.circular(2),
                    ),
                    // Bypass 生效打叉（✗）：打勾易误读为「启用」。
                    child: node.paramValues['bypass'] == true
                        ? const Icon(Icons.close,
                            size: 10, color: Colors.black)
                        : null,
                  ),
                ),
              ),
            ),
          // 节点工作时间（最近一次运行预览测得；未运行时不显示）。
          if (state.nodeRunTimesUs[node.id] != null)
            Tooltip(
              message: '节点工作时间',
              child: Padding(
                padding: const EdgeInsets.only(right: 3),
                child: Text(
                  formatNodeRunTime(state.nodeRunTimesUs[node.id]!),
                  style: const TextStyle(
                      color: Colors.white70, fontSize: 10),
                ),
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
          // 最大化/还原（仅有显示区的节点：预览/调节器/高频边缘提取/
          // 曲线调节器/仪器）。
          if (type.typeId == 'preview' ||
              type.typeId == 'hsl_debugger' ||
              type.typeId == 'rgb_debugger' ||
              type.typeId == 'yuv_debugger' ||
              type.typeId == 'sat_bright_adjuster' ||
              type.typeId == 'bright_contrast_adjuster' ||
              type.typeId == 'edge_extract' ||
              type.typeId == 'levels_curves' ||
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
                    child: SliderTheme(
                      data: kIspSliderTheme,
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

  /// HSL 调节器附加区：双联矢量示波器（左调整前/右调整后，与
  /// vectorscope 仪器同一布局）+ H/S/L 三行紧凑滑块 + 底部拖动手柄。
  /// 拖动滑块只写参数（实时刷新数值），松手才重跑流水线更新示波器图；
  /// 图刷新走 [IspStudioState.frameTick]，只有本区重建。
  Widget _buildHslDebugExtra(IspStudioState state) {
    return ValueListenableBuilder<int>(
      valueListenable: state.frameTick,
      builder: (context, tick, child) => _buildHslDebugExtraContent(state),
    );
  }

  Widget _buildHslDebugExtraContent(IspStudioState state) {
    final scopeImage = state.hslVectorscopes[node.id];
    final inputScopeImage = state.hslInputVectorscopes[node.id];
    final hasInput = state.graph.connectionAt(node.id, 'in') != null;
    final extra = state.previewExtraHeight(node.id);
    // 3 行滑块各 24，顶部留白 4，底部手柄 10，其余归示波器区。
    final scopeHeight = math.max(0.0, extra - 4 - 24 * 3 - 10);
    return SizedBox(
      height: extra,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
            child: SizedBox(
              height: scopeHeight,
              child: Row(
                children: [
                  // 左半：调整前（输入链统计）；右半：调整后（输出链统计）。
                  Expanded(
                      child: _buildHslVectorscopePane(inputScopeImage, '调整前',
                          hasInput ? '运行预览后显示' : '未连接输入')),
                  const SizedBox(width: 4),
                  Expanded(
                      child: _buildHslVectorscopePane(
                          scopeImage, '调整后', '运行预览后显示效果')),
                ],
              ),
            ),
          ),
          _buildHslSliderRow(state, 'H', 'h_shift', -180, 180, 0,
              (v) => '${v >= 0 ? '+' : ''}${v.toStringAsFixed(0)}°'),
          _buildHslSliderRow(state, 'S', 's_gain', 0, 5, 1,
              (v) => '×${v.toStringAsFixed(2)}'),
          _buildHslSliderRow(state, 'L', 'l_gain', 0, 5, 1,
              (v) => '×${v.toStringAsFixed(2)}'),
          // 底部手柄条：与预览/仪器节点共用同一套拖动调整机制。
          _buildResizeBar(state),
        ],
      ),
    );
  }

  /// HSL 调节器矢量示波器的半区：矢量示波器坐标格 + 迹线图（无图时
  /// 显示占位文案 [hint]），左上角叠加半透明小标签 [label]
  /// （「调整前」/「调整后」）。布局与 vectorscope 仪器一致：数据区
  /// 是居中、边长为短边 82% 的正方形，迹线铺满该正方形。
  Widget _buildHslVectorscopePane(ui.Image? image, String label, String hint) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final side =
            math.min(constraints.maxWidth, constraints.maxHeight) * 0.82;
        return Stack(
          fit: StackFit.expand,
          children: [
            CustomPaint(
              foregroundPainter: const VectorscopeGraticule(),
              child: Container(
                color: Colors.black,
                alignment: Alignment.center,
                child: SizedBox(
                  width: side,
                  height: side,
                  child: image == null
                      ? Center(
                          child: Text(hint,
                              style: const TextStyle(
                                  fontSize: 11, color: Colors.grey)))
                      : RawImage(image: image, fit: BoxFit.fill),
                ),
              ),
            ),
            Positioned(
              left: 2,
              top: 2,
              child: Text(label,
                  style:
                      const TextStyle(fontSize: 10, color: Colors.white54)),
            ),
          ],
        );
      },
    );
  }

  /// RGB 调节器附加区：与 HSL 调节器同构（双联对比预览 + 3 行增益滑块）。
  Widget _buildRgbDebugExtra(IspStudioState state) {
    return ValueListenableBuilder<int>(
      valueListenable: state.frameTick,
      builder: (context, tick, child) => _buildRgbDebugExtraContent(state),
    );
  }

  Widget _buildRgbDebugExtraContent(IspStudioState state) {
    final image = state.previewImages[node.id];
    final inputImage = state.previewInputImages[node.id];
    final hasInput = state.graph.connectionAt(node.id, 'in') != null;
    final extra = state.previewExtraHeight(node.id);
    // 3 行滑块各 24，顶部留白 4，底部手柄 10，其余归预览图区。
    final imageHeight = math.max(0.0, extra - 4 - 24 * 3 - 10);
    return SizedBox(
      height: extra,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
            child: SizedBox(
              height: imageHeight,
              child: Row(
                children: [
                  // 左半：调整前（输入链出图）；右半：调整后（输出链出图）。
                  Expanded(
                      child: _buildHslComparePane(inputImage, '调整前',
                          hasInput ? '运行预览后显示' : '未连接输入')),
                  const SizedBox(width: 4),
                  Expanded(
                      child: _buildHslComparePane(
                          image, '调整后', '运行预览后显示效果')),
                ],
              ),
            ),
          ),
          _buildHslSliderRow(state, 'R', 'r_gain', 0, 5, 1,
              (v) => '×${v.toStringAsFixed(2)}'),
          _buildHslSliderRow(state, 'G', 'g_gain', 0, 5, 1,
              (v) => '×${v.toStringAsFixed(2)}'),
          _buildHslSliderRow(state, 'B', 'b_gain', 0, 5, 1,
              (v) => '×${v.toStringAsFixed(2)}'),
          // 底部手柄条：与预览/仪器节点共用同一套拖动调整机制。
          _buildResizeBar(state),
        ],
      ),
    );
  }

  /// YUV 调节器附加区：与 HSL/RGB 调节器同构（双联对比预览 +
  /// Y 增益与 U/V 色度增益滑块）。
  Widget _buildYuvDebugExtra(IspStudioState state) {
    return ValueListenableBuilder<int>(
      valueListenable: state.frameTick,
      builder: (context, tick, child) => _buildYuvDebugExtraContent(state),
    );
  }

  Widget _buildYuvDebugExtraContent(IspStudioState state) {
    final image = state.previewImages[node.id];
    final inputImage = state.previewInputImages[node.id];
    final hasInput = state.graph.connectionAt(node.id, 'in') != null;
    final extra = state.previewExtraHeight(node.id);
    // 3 行滑块各 24，顶部留白 4，底部手柄 10，其余归预览图区。
    final imageHeight = math.max(0.0, extra - 4 - 24 * 3 - 10);
    return SizedBox(
      height: extra,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
            child: SizedBox(
              height: imageHeight,
              child: Row(
                children: [
                  // 左半：调整前（输入链出图）；右半：调整后（输出链出图）。
                  Expanded(
                      child: _buildHslComparePane(inputImage, '调整前',
                          hasInput ? '运行预览后显示' : '未连接输入')),
                  const SizedBox(width: 4),
                  Expanded(
                      child: _buildHslComparePane(
                          image, '调整后', '运行预览后显示效果')),
                ],
              ),
            ),
          ),
          _buildHslSliderRow(state, 'Y', 'y_gain', 0, 5, 1,
              (v) => '×${v.toStringAsFixed(2)}'),
          _buildHslSliderRow(state, 'U', 'u_gain', 0, 5, 1,
              (v) => '×${v.toStringAsFixed(2)}'),
          _buildHslSliderRow(state, 'V', 'v_gain', 0, 5, 1,
              (v) => '×${v.toStringAsFixed(2)}'),
          // 底部手柄条：与预览/仪器节点共用同一套拖动调整机制。
          _buildResizeBar(state),
        ],
      ),
    );
  }

  /// 高频边缘提取附加区：与色饱和度/亮度调节器同构（双联对比预览 +
  /// 增益/噪声门限两行滑块），输入可为 RGB/YUV/HSL 任一种。
  Widget _buildEdgeExtractExtra(IspStudioState state) {
    return ValueListenableBuilder<int>(
      valueListenable: state.frameTick,
      builder: (context, tick, child) => _buildEdgeExtractExtraContent(state),
    );
  }

  Widget _buildEdgeExtractExtraContent(IspStudioState state) {
    final image = state.previewImages[node.id];
    final inputImage = state.previewInputImages[node.id];
    // 互斥输入组：in(RGB)/in_yuv/in_hsl 任一已连接即视为有输入。
    final hasInput = state.graph.connectionAt(node.id, 'in') != null ||
        state.graph.connectionAt(node.id, 'in_yuv') != null ||
        state.graph.connectionAt(node.id, 'in_hsl') != null;
    final extra = state.previewExtraHeight(node.id);
    // 2 行滑块各 24，顶部留白 4，底部手柄 10，其余归预览图区。
    final imageHeight = math.max(0.0, extra - 4 - 24 * 2 - 10);
    return SizedBox(
      height: extra,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
            child: SizedBox(
              height: imageHeight,
              child: Row(
                children: [
                  // 左半：调整前（输入链出图）；右半：提取后（输出链出图）。
                  Expanded(
                      child: _buildHslComparePane(inputImage, '输入',
                          hasInput ? '运行预览后显示' : '未连接输入')),
                  const SizedBox(width: 4),
                  Expanded(
                      child: _buildHslComparePane(
                          image, '输出', '运行预览后显示效果')),
                ],
              ),
            ),
          ),
          _buildHslSliderRow(state, 'Gain', 'gain', 0.1, 8, 1,
              (v) => '×${v.toStringAsFixed(2)}', labelWidth: 40),
          _buildHslSliderRow(state, 'Thr', 'threshold', 0, 256, 4,
              (v) => v.toStringAsFixed(1), labelWidth: 40),
          // 底部手柄条：与预览/仪器节点共用同一套拖动调整机制。
          _buildResizeBar(state),
        ],
      ),
    );
  }

  /// 色饱和度/亮度调节器附加区：与 HSL 调节器同构（双联对比预览 +
  /// 色饱和度/亮度两行滑块），输入可为 RGB/YUV/HSL 任一种。
  Widget _buildSatBrightExtra(IspStudioState state) {
    return ValueListenableBuilder<int>(
      valueListenable: state.frameTick,
      builder: (context, tick, child) => _buildSatBrightExtraContent(state),
    );
  }

  /// 亮度/对比度调节器附加区：Y 通道波形示波器（调整后输出帧）+
  /// 基线绿色虚线与左缘三角滑块 + 亮度/基线/增益三行紧凑滑块 +
  /// 底部拖动手柄。拖动滑块或三角只写参数，松手才重跑流水线。
  Widget _buildBrightContrastExtra(IspStudioState state) {
    return ValueListenableBuilder<int>(
      valueListenable: state.frameTick,
      builder: (context, tick, child) =>
          _buildBrightContrastExtraContent(state),
    );
  }

  Widget _buildBrightContrastExtraContent(IspStudioState state) {
    final waveform = state.brightContrastWaveforms[node.id];
    final inputWaveform = state.brightContrastInputWaveforms[node.id];
    // 互斥输入组：in(RGB)/in_yuv/in_hsl/in_mono 任一已连接即视为有输入。
    final hasInput = state.graph.connectionAt(node.id, 'in') != null ||
        state.graph.connectionAt(node.id, 'in_yuv') != null ||
        state.graph.connectionAt(node.id, 'in_hsl') != null ||
        state.graph.connectionAt(node.id, 'in_mono') != null;
    final baseline =
        (node.paramValues['baseline'] as num?)?.toDouble() ?? 50.0;
    final extra = state.previewExtraHeight(node.id);
    // 3 行滑块各 24，顶部留白 4，示波器与滑块之间留白 8，底部手柄 10，
    // 其余归示波器区。
    final scopeHeight = math.max(0.0, extra - 4 - 8 - 24 * 3 - 10);
    return SizedBox(
      height: extra,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
            child: SizedBox(
              height: scopeHeight,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // 黑底双联波形：左半调整前（输入链）、右半调整后（输出
                  // 链），与波形仪器同一布局（左侧级标区 labelWidth）。
                  CustomPaint(
                    foregroundPainter: const WaveformGraticule(),
                    child: Container(
                      color: Colors.black,
                      padding: const EdgeInsets.only(
                          left: WaveformGraticule.labelWidth),
                      child: Row(
                        children: [
                          Expanded(
                              child: _buildWaveformHalf(
                                  inputWaveform,
                                  '调整前',
                                  hasInput ? '运行预览后显示' : '未连接输入')),
                          // 左右波形之间的 10px 灰色间隔。
                          Container(width: _kWaveformHalfGap, color: _kWaveformGapColor),
                          Expanded(
                              child: _buildWaveformHalf(
                                  waveform, '调整后', '运行预览后显示效果')),
                        ],
                      ),
                    ),
                  ),
                  // 基线叠加：绿色 1px 虚线 + 左缘三角形滑块。
                  IgnorePointer(
                    child: CustomPaint(
                        painter: _BaselineOverlayPainter(baseline)),
                  ),
                  // 左缘竖条手势区：垂直拖动/点按调整基线（等价于拖基线
                  // 滑块），松手重跑流水线刷新波形。
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    width: WaveformGraticule.labelWidth + 8,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onVerticalDragUpdate: (d) => _baselineDragTo(
                          state, d.localPosition.dy, scopeHeight),
                      onTapDown: (d) =>
                          _baselineDragTo(state, d.localPosition.dy, scopeHeight),
                      onVerticalDragEnd: (_) => state.runPreview(),
                      onTapUp: (_) => state.runPreview(),
                    ),
                  ),
                ],
              ),
            ),
          ),
          _buildHslSliderRow(state, 'Bright', 'bright', 0, 1000, 100,
              (v) => '${v.toStringAsFixed(0)}%', labelWidth: 52),
          _buildHslSliderRow(state, 'Baseline', 'baseline', 0, 100, 50,
              (v) => '${v.toStringAsFixed(0)}%', labelWidth: 52),
          _buildHslSliderRow(state, 'Gain', 'gain', 0, 1000, 100,
              (v) => '${v.toStringAsFixed(0)}%', labelWidth: 52),
          // 底部手柄条：与预览/仪器节点共用同一套拖动调整机制。
          _buildResizeBar(state),
        ],
      ),
    );
  }

  /// 亮度/对比度调节器示波器的半区：波形图（无图时显示占位文案
  /// [hint]），左上角叠加半透明小标签 [label]（「调整前」/「调整后」）。
  Widget _buildWaveformHalf(ui.Image? image, String label, String hint) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // 波形图必须占满整个半区（紧约束 + BoxFit.fill 拉伸），其 256 行
        // 才与 WaveformGraticule 的 0..100 级标逐行对齐；套 Center 会让
        // RawImage 退回固有宽高比、上下留边，导致迹线与 Y 级标错位。
        if (image != null)
          Positioned.fill(child: RawImage(image: image, fit: BoxFit.fill))
        else
          Center(
            child: Text(hint,
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ),
        Positioned(
          left: 2,
          top: 2,
          child: Text(label,
              style: const TextStyle(fontSize: 10, color: Colors.white54)),
        ),
      ],
    );
  }

  /// 示波器左缘基线拖动：把竖向位置换算为基线百分比（0% 在底，
  /// 100% 在顶）写入参数；不重跑流水线（松手由调用方触发）。
  void _baselineDragTo(IspStudioState state, double dy, double scopeHeight) {
    if (scopeHeight <= 0) return;
    final v = (100 - dy / scopeHeight * 100).clamp(0.0, 100.0);
    state.setParam(node.id, 'baseline', v);
  }

  /// 色彩平衡附加区：双联对比预览（左调整前/右调整后，与 RGB 调节器
  /// 同一布局）+ 青↔红 / 洋红↔绿 / 黄↔蓝 三行渐变滑杆 + 底部拖动手柄。
  /// 数值输入走右侧属性面板（三个 doubleNumber 参数）。拖动滑块只写
  /// 参数，松手才重跑流水线；图刷新走 [IspStudioState.frameTick]。
  Widget _buildColorBalanceExtra(IspStudioState state) {
    return ValueListenableBuilder<int>(
      valueListenable: state.frameTick,
      builder: (context, tick, child) => _buildColorBalanceExtraContent(state),
    );
  }

  Widget _buildColorBalanceExtraContent(IspStudioState state) {
    final image = state.previewImages[node.id];
    final inputImage = state.previewInputImages[node.id];
    // 互斥输入组：in(RGB)/in_yuv/in_hsl 任一已连接即视为有输入。
    final hasInput = state.graph.connectionAt(node.id, 'in') != null ||
        state.graph.connectionAt(node.id, 'in_yuv') != null ||
        state.graph.connectionAt(node.id, 'in_hsl') != null;
    final extra = state.previewExtraHeight(node.id);
    // 3 行滑杆各 24，顶部留白 4，底部手柄 10，其余归预览图区。
    final imageHeight = math.max(0.0, extra - 4 - 24 * 3 - 10);
    return SizedBox(
      height: extra,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
            child: SizedBox(
              height: imageHeight,
              child: Row(
                children: [
                  // 左半：调整前（输入链出图）；右半：调整后（输出链出图）。
                  Expanded(
                      child: _buildHslComparePane(inputImage, '调整前',
                          hasInput ? '运行预览后显示' : '未连接输入')),
                  const SizedBox(width: 4),
                  Expanded(
                      child: _buildHslComparePane(
                          image, '调整后', '运行预览后显示效果')),
                ],
              ),
            ),
          ),
          _buildBalanceSliderRow(state, 'cyan_red', '青色',
              const Color(0xFF40C0C0), '红色', const Color(0xFFE05050)),
          _buildBalanceSliderRow(state, 'magenta_green', '洋红',
              const Color(0xFFD050D0), '绿色', const Color(0xFF50C050)),
          _buildBalanceSliderRow(state, 'yellow_blue', '黄色',
              const Color(0xFFD8D050), '蓝色', const Color(0xFF5070E0)),
          _buildResizeBar(state),
        ],
      ),
    );
  }

  /// 色彩平衡单行：左标签 + 渐变轨道滑杆 + 右标签 + 当前值。渐变轨道
  /// 画在滑杆下层（Slider 自身轨道透明），直观表达偏移方向。左侧补
  /// 与右侧数值区等宽的 34px 间隔，使左右装饰对称、滑杆轨道（及 0 值
  /// 中心点）与调试块中心对齐。
  Widget _buildBalanceSliderRow(IspStudioState state, String key,
      String leftLabel, Color leftColor, String rightLabel, Color rightColor) {
    final value = (node.paramValues[key] as num?)?.toDouble() ?? 0.0;
    final labelStyle = TextStyle(fontSize: 10, color: Colors.grey.shade400);
    return SizedBox(
      height: 24,
      child: Row(
        children: [
          const SizedBox(width: 8),
          // 与右侧「当前值 34px」等宽的对称间隔，保证轨道居中。
          const SizedBox(width: 34),
          SizedBox(width: 26, child: Text(leftLabel, style: labelStyle)),
          Expanded(
            child: Stack(
              alignment: Alignment.center,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Container(
                    height: 4,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(2),
                      gradient:
                          LinearGradient(colors: [leftColor, rightColor]),
                    ),
                  ),
                ),
                SliderTheme(
                  data: const SliderThemeData(
                    activeTrackColor: Colors.transparent,
                    inactiveTrackColor: Colors.transparent,
                    trackHeight: 4,
                    // 滑钮直径减半（与 kIspSliderTheme 一致）。
                    thumbShape: RoundSliderThumbShape(enabledThumbRadius: 5),
                  ),
                  child: Slider(
                    value: value.clamp(-100.0, 100.0),
                    min: -100,
                    max: 100,
                    // 拖动中只写参数（实时刷新数值），松手才重跑。
                    onChanged: (v) => state.setParam(node.id, key, v),
                    onChangeEnd: (_) => state.runPreview(),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
              width: 26,
              child: Text(rightLabel, style: labelStyle)),
          SizedBox(
            width: 34,
            child: Text(value.toStringAsFixed(0),
                style: const TextStyle(fontSize: 10, color: Colors.white70)),
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }

  /// 色温调节器附加区：双联对比预览（左调整前/右调整后）+ 实测色温
  /// 按钮（点击把滑块设为测量值）/目标色温行 + 暖→冷渐变色温滑杆
  ///（1800~12000K）+ 底行（左下 CCM 3x3 方框 / 右下调整后 RGB 直方图）
  /// + 底部拖动手柄。图刷新走 [IspStudioState.frameTick]；拖动滑块只写
  /// 参数，松手重跑流水线。
  Widget _buildColorTempExtra(IspStudioState state) {
    return ValueListenableBuilder<int>(
      valueListenable: state.frameTick,
      builder: (context, tick, child) => _buildColorTempExtraContent(state),
    );
  }

  Widget _buildColorTempExtraContent(IspStudioState state) {
    final image = state.previewImages[node.id];
    final inputImage = state.previewInputImages[node.id];
    final hasInput = state.graph.connectionAt(node.id, 'in') != null;
    final extra = state.previewExtraHeight(node.id);
    final measured = state.measuredColorTemps[node.id];
    final target =
        (node.paramValues['temperature'] as num?)?.toDouble() ?? 6500.0;
    final refCct = (node.paramValues['measured_cct'] as num?)?.toInt() ?? 0;
    final ccm = colorTempCcm(colorTempGains(target, refCct));
    // 温度行 24 + 滑杆行 24 + 底行（CCM 方框 / 直方图）64，顶部留白 4，
    // 底部手柄 10，其余归预览图区。
    final imageHeight = math.max(0.0, extra - 4 - 24 - 24 - 64 - 10);
    const textStyle = TextStyle(fontSize: 10, color: Colors.white70);
    return SizedBox(
      height: extra,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
            child: SizedBox(
              height: imageHeight,
              child: Row(
                children: [
                  // 左半：调整前（输入链出图）；右半：调整后（输出链出图）。
                  Expanded(
                      child: _buildHslComparePane(inputImage, '调整前',
                          hasInput ? '运行预览后显示' : '未连接输入')),
                  const SizedBox(width: 4),
                  Expanded(
                      child: _buildHslComparePane(
                          image, '调整后', '运行预览后显示效果')),
                ],
              ),
            ),
          ),
          // 实测/目标色温行：测量值是可点击按钮（点击把滑块设为测量值）。
          SizedBox(
            height: 24,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Tooltip(
                        message: measured != null ? '点击将色温设为测量值' : '运行预览后显示测量值',
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: measured != null
                              ? () => state.applyMeasuredColorTemp(node.id)
                              : null,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: measured != null
                                  ? const Color(0xFF3A3A3A)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(3),
                              border: measured != null
                                  ? Border.all(color: const Color(0xFF5A5A5A))
                                  : null,
                            ),
                            child: Text(
                              measured != null ? '测量: $measured K' : '测量: 未运行',
                              style: TextStyle(
                                  fontSize: 10,
                                  color: measured != null
                                      ? const Color(0xFFFFC890)
                                      : Colors.grey),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Text('目标: ${target.toStringAsFixed(0)} K',
                      style: textStyle),
                ],
              ),
            ),
          ),
          _buildColorTempSliderRow(state, target),
          // 底行：左下 CCM 3x3 方框（9 个长方框），右下调整后 RGB 直方图。
          SizedBox(
            height: 64,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  Expanded(child: _buildCcmGrid(ccm)),
                  const SizedBox(width: 6),
                  Expanded(
                    // SizedBox.expand：有数据时 CustomPaint 无 child，
                    // Row 的松散高度约束下会塌缩成 0 高（与仪器区同理）。
                    child: SizedBox.expand(
                      child: CustomPaint(
                        key: const ValueKey('colorTempHist'),
                        painter: _RgbHistMiniPainter(
                            state.colorTempHistograms[node.id]),
                        child: state.colorTempHistograms[node.id] == null
                            ? const Center(
                                child: Text('未运行',
                                    style: TextStyle(
                                        fontSize: 9, color: Colors.grey)))
                            : null,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          _buildResizeBar(state),
        ],
      ),
    );
  }

  /// 色温调节器左下角的 CCM 显示：9 个长方框按 3x3 各显示一个矩阵值
  ///（当前色温增益对角阵，行优先）。每行背景用对应通道的 RGB 颜色
  ///（R 行红底 / G 行绿底 / B 行蓝底，半透明保证文字可读）。
  Widget _buildCcmGrid(List<double> ccm) {
    // 行 → 通道颜色（R/G/B）。
    const rowColors = [
      Color(0xFFE05353),
      Color(0xFF53E553),
      Color(0xFF5383E5),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(
            height: 12,
            child:
                Text('CCM', style: TextStyle(fontSize: 9, color: Colors.grey))),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var r = 0; r < 3; r++) ...[
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var c = 0; c < 3; c++) ...[
                        Expanded(
                          child: Container(
                            decoration: BoxDecoration(
                              // 对应 RGB 通道色半透明背景；对角元（增益
                              // 所在）略亮一档。
                              color: rowColors[r].withValues(
                                  alpha: r == c ? 0.45 : 0.22),
                              border: Border.all(
                                  color: rowColors[r].withValues(alpha: 0.6)),
                              borderRadius: BorderRadius.circular(2),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              ccm[r * 3 + c].toStringAsFixed(3),
                              style: const TextStyle(
                                  fontSize: 8,
                                  fontFamily: 'monospace',
                                  color: Colors.white70),
                            ),
                          ),
                        ),
                        if (c < 2) const SizedBox(width: 2),
                      ],
                    ],
                  ),
                ),
                if (r < 2) const SizedBox(height: 2),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// 色温滑杆行：暖（橙）→冷（蓝）渐变轨道 + 两端色温标签 + 当前值。
  /// 渐变画在滑杆下层（Slider 自身轨道透明），左右装饰等宽保证轨道居中。
  Widget _buildColorTempSliderRow(IspStudioState state, double value) {
    const labelStyle = TextStyle(fontSize: 9, color: Colors.grey);
    return SizedBox(
      height: 24,
      child: Row(
        children: [
          const SizedBox(width: 8),
          const SizedBox(width: 30, child: Text('1800K', style: labelStyle)),
          Expanded(
            child: Stack(
              alignment: Alignment.center,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Container(
                    height: 4,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(2),
                      // 暖色（低色温橙）→ 冷色（高色温蓝）。
                      gradient: const LinearGradient(colors: [
                        Color(0xFFFFA040),
                        Color(0xFFFFF4E0),
                        Color(0xFF5090FF),
                      ]),
                    ),
                  ),
                ),
                SliderTheme(
                  data: const SliderThemeData(
                    activeTrackColor: Colors.transparent,
                    inactiveTrackColor: Colors.transparent,
                    trackHeight: 4,
                    // 滑钮直径减半（与 kIspSliderTheme 一致）。
                    thumbShape: RoundSliderThumbShape(enabledThumbRadius: 5),
                  ),
                  child: Slider(
                    value: value.clamp(1800.0, 12000.0),
                    min: 1800,
                    max: 12000,
                    // 拖动中只写参数（实时刷新数值），松手才重跑。
                    onChanged: (v) =>
                        state.setParam(node.id, 'temperature', v),
                    onChangeEnd: (_) => state.runPreview(),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 30, child: Text('12000K', style: labelStyle)),
          SizedBox(
            width: 44,
            child: Text('${value.toStringAsFixed(0)}K',
                style: const TextStyle(fontSize: 10, color: Colors.white70)),
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }

  /// 曲线调节器附加区：传递函数曲线编辑器（黑色背景 + 输入 Y 直方图 +
  /// 输出（调节后）Y 直方图 + 四分网格 + 单调三次样条曲线；单击空白
  /// 加点、拖动移点、双击删点，端点 A1/C1 的 x 固定）+ 底部拖动手柄。拖动只写参数，松手重跑
  /// 流水线；直方图刷新走 [IspStudioState.frameTick]。
  Widget _buildLevelsExtra(IspStudioState state) {
    return ValueListenableBuilder<int>(
      valueListenable: state.frameTick,
      builder: (context, tick, child) => _buildLevelsExtraContent(state),
    );
  }

  Widget _buildLevelsExtraContent(IspStudioState state) {
    final extra = state.previewExtraHeight(node.id);
    // 顶部留白 4，底部手柄 10，其余归曲线编辑区。
    final editorHeight = math.max(0.0, extra - 4 - 10);
    return SizedBox(
      height: extra,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
            child: SizedBox(
              height: editorHeight,
              child: _LevelsCurveEditor(state: state, node: node),
            ),
          ),
          // 底部手柄条：与预览/仪器节点共用同一套拖动调整机制。
          _buildResizeBar(state),
        ],
      ),
    );
  }

  Widget _buildSatBrightExtraContent(IspStudioState state) {
    final image = state.previewImages[node.id];
    final inputImage = state.previewInputImages[node.id];
    // 互斥输入组：in(RGB)/in_yuv/in_hsl 任一已连接即视为有输入。
    final hasInput = state.graph.connectionAt(node.id, 'in') != null ||
        state.graph.connectionAt(node.id, 'in_yuv') != null ||
        state.graph.connectionAt(node.id, 'in_hsl') != null;
    final extra = state.previewExtraHeight(node.id);
    // 2 行滑块各 24，顶部留白 4，底部手柄 10，其余归预览图区。
    final imageHeight = math.max(0.0, extra - 4 - 24 * 2 - 10);
    return SizedBox(
      height: extra,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
            child: SizedBox(
              height: imageHeight,
              child: Row(
                children: [
                  // 左半：调整前（输入链出图）；右半：调整后（输出链出图）。
                  Expanded(
                      child: _buildHslComparePane(inputImage, '调整前',
                          hasInput ? '运行预览后显示' : '未连接输入')),
                  const SizedBox(width: 4),
                  Expanded(
                      child: _buildHslComparePane(
                          image, '调整后', '运行预览后显示效果')),
                ],
              ),
            ),
          ),
          _buildHslSliderRow(state, 'S', 'sat_gain', 0, 8, 1,
              (v) => '×${v.toStringAsFixed(2)}'),
          _buildHslSliderRow(state, 'L', 'bright_gain', 0, 32, 1,
              (v) => '×${v.toStringAsFixed(2)}'),
          // 底部手柄条：与预览/仪器节点共用同一套拖动调整机制。
          _buildResizeBar(state),
        ],
      ),
    );
  }

  /// HSL 调节器对比窗格的半区：黑底图（无图时显示占位文案 [hint]），
  /// 左上角叠加半透明小标签 [label]（「调整前」/「调整后」）。
  Widget _buildHslComparePane(ui.Image? image, String label, String hint) {
    return Container(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: image != null
                ? RawImage(image: image, fit: BoxFit.contain)
                : Text(hint,
                    style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ),
          Positioned(
            left: 4,
            top: 2,
            child: Text(label,
                style: const TextStyle(fontSize: 10, color: Colors.white54)),
          ),
        ],
      ),
    );
  }

  /// 乘法器的偏移行：源1/源2 偏移各一行「− 带符号值 +」步进控件，
  /// 点击写参数并重跑预览（与滑块松手重跑同一语义）。
  Widget _buildMultiplierOffsets(IspStudioState state) {
    return Column(
      children: [
        _buildOffsetStepperRow(state, '源1偏移', 'offset1'),
        _buildOffsetStepperRow(state, '源2偏移', 'offset2'),
      ],
    );
  }

  /// 加法器平衡控制条：上方居中显示平衡值，下方左「源1」右「源2」
  /// 渐变轨道，控制点位置即平衡增益（0..1，默认 0.5 居中）。
  /// 拖动中只写参数（实时刷新数值），松手才重跑（同色彩平衡滑杆）。
  Widget _buildAdderBalance(IspStudioState state) {
    final value = (node.paramValues['balance'] as num?)?.toDouble() ?? 0.5;
    final labelStyle = TextStyle(fontSize: 10, color: Colors.grey.shade400);
    return Column(
      children: [
        // 平衡值显示行（控制条上方，居中）。
        SizedBox(
          height: 14,
          child: Center(
            child: Text(value.toStringAsFixed(2),
                style: const TextStyle(fontSize: 10, color: Colors.white70)),
          ),
        ),
        SizedBox(
          height: 24,
          child: Row(
            children: [
              const SizedBox(width: 8),
              SizedBox(width: 26, child: Text('源1', style: labelStyle)),
              Expanded(
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Container(
                        height: 4,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(2),
                          gradient: const LinearGradient(colors: [
                            Color(0xFF50A0B0),
                            Color(0xFF807060),
                          ]),
                        ),
                      ),
                    ),
                    SliderTheme(
                      data: const SliderThemeData(
                        activeTrackColor: Colors.transparent,
                        inactiveTrackColor: Colors.transparent,
                        trackHeight: 4,
                        // 滑钮直径减半（与 kIspSliderTheme 一致）。
                        thumbShape:
                            RoundSliderThumbShape(enabledThumbRadius: 5),
                      ),
                      child: Slider(
                        value: value.clamp(0.0, 1.0),
                        min: 0,
                        max: 1,
                        // 拖动中只写参数（实时刷新数值），松手才重跑。
                        onChanged: (v) =>
                            state.setParam(node.id, 'balance', v),
                        onChangeEnd: (_) => state.runPreview(),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(width: 26, child: Text('源2', style: labelStyle)),
              const SizedBox(width: 8),
            ],
          ),
        ),
      ],
    );
  }

  /// 多路选择器源选择开关：源1~源4 单选（select 参数，默认 1），
  /// 点击即切换输出通道并重跑预览。
  Widget _buildMux4Select(IspStudioState state) {
    final sel = (node.paramValues['select'] as num?)?.toInt() ?? 1;
    return SizedBox(
      height: 24,
      child: Row(
        children: [
          const SizedBox(width: 8),
          for (var i = 1; i <= 4; i++) ...[
            Expanded(
              child: GestureDetector(
                onTap: () {
                  if (sel == i) return;
                  state.setParam(node.id, 'select', i);
                  state.runPreview();
                },
                child: Container(
                  height: 18,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: sel == i
                        ? const Color(0xFF4A6E8E)
                        : const Color(0xFF333333),
                    borderRadius: BorderRadius.circular(3),
                    border: Border.all(
                        color: sel == i
                            ? const Color(0xFF6A9EC0)
                            : Colors.grey.shade800),
                  ),
                  child: Text('源$i',
                      style: TextStyle(
                          fontSize: 10,
                          color: sel == i
                              ? Colors.white
                              : Colors.grey.shade500)),
                ),
              ),
            ),
            if (i < 4) const SizedBox(width: 4),
          ],
          const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _buildOffsetStepperRow(
      IspStudioState state, String label, String key) {
    final value = (node.paramValues[key] as num?)?.toDouble() ?? 0.0;
    // 带显式正负号的紧凑格式：整数去小数点（+120 / -30.5 / +0）。
    String fmt(double v) {
      final abs = v.abs();
      final s = abs == abs.roundToDouble()
          ? abs.toInt().toString()
          : abs.toStringAsFixed(1);
      return v < 0 ? '-$s' : '+$s';
    }

    void step(double d) {
      state.setParam(
          node.id, key, (value + d).clamp(-65535.0, 65535.0));
      state.runPreview();
    }

    return SizedBox(
      height: 24,
      child: Row(
        children: [
          const SizedBox(width: 8),
          SizedBox(
            width: 46,
            child: Text(label,
                style: const TextStyle(fontSize: 11, color: Colors.white70)),
          ),
          _offsetStepperButton(Icons.remove, () => step(-1)),
          Expanded(
            child: Center(
              child: Text(fmt(value),
                  style:
                      const TextStyle(fontSize: 11, color: Colors.white70)),
            ),
          ),
          _offsetStepperButton(Icons.add, () => step(1)),
          const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _offsetStepperButton(IconData icon, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: Icon(icon, size: 14, color: Colors.white70),
      ),
    );
  }

  /// HSL 调节器的单行紧凑滑块：窄标签 + Slider + 数值文本。
  /// [fallback] 为参数缺失时的显示值（增益类参数应取恒等 1.0），
  /// [format] 把参数值格式化为显示文本（H 带符号角度，S/L 增益倍数）。
  Widget _buildHslSliderRow(IspStudioState state, String label, String key,
      double min, double max, double fallback, String Function(double) format,
      {double labelWidth = 12}) {
    final value = (node.paramValues[key] as num?)?.toDouble() ?? fallback;
    return SizedBox(
      height: 24,
      child: Row(
        children: [
          const SizedBox(width: 8),
          SizedBox(
            width: labelWidth,
            child: Text(label,
                style: const TextStyle(fontSize: 11, color: Colors.white70)),
          ),
          Expanded(
            child: SliderTheme(
              data: kIspSliderTheme,
              child: Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                // 拖动中只写参数（不重跑流水线），松手才重跑。
                onChanged: (v) => state.setParam(node.id, key, v),
                onChangeEnd: (_) => state.runPreview(),
              ),
            ),
          ),
          SizedBox(
            width: 48,
            child: Text(format(value),
                style: const TextStyle(fontSize: 10, color: Colors.white70)),
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }

  /// 底部手柄条：中间上下拖调整高度，右下角控制点双向调整宽高。
  /// 预览、HSL 调节器与仪器节点共用。
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

/// 节点工作时间的紧凑格式：µs / ms / s 三档。
String formatNodeRunTime(int us) {
  if (us >= 1000000) return '${(us / 1000000).toStringAsFixed(2)} s';
  if (us >= 100000) return '${us ~/ 1000} ms';
  if (us >= 1000) return '${(us / 1000).toStringAsFixed(1)} ms';
  return '$us µs';
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

/// 亮度/对比度调节器示波器左右波形之间的间隔（灰色竖条）。
const double _kWaveformHalfGap = 10.0;
const Color _kWaveformGapColor = Color(0xFF616161);

/// 亮度/对比度调节器示波器的基线叠加层：按基线百分比 [baselinePct]
/// 画绿色 1px 水平虚线（0% 在底、100% 在顶），**只画在左半「调整前」
/// 波形区**；左缘画实心三角形滑块（指向右，垂直居中于基线）。
class _BaselineOverlayPainter extends CustomPainter {
  final double baselinePct;

  const _BaselineOverlayPainter(this.baselinePct);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(WaveformGraticule.labelWidth, 0,
        size.width - WaveformGraticule.labelWidth, size.height);
    if (rect.width <= 0 || rect.height <= 0) return;
    // 左半「调整前」波形区宽度（减去中间灰色间隔后两等分）。
    final leftHalfRight =
        rect.left + (rect.width - _kWaveformHalfGap) / 2;
    if (leftHalfRight <= rect.left) return;
    final y = rect.top +
        rect.height * (100 - baselinePct.clamp(0.0, 100.0)) / 100;
    const green = Color(0xFF00FF00);
    // 绿色 1px 水平虚线（4px 线 / 3px 间隔），仅覆盖左半波形区。
    final linePaint = Paint()
      ..color = green
      ..strokeWidth = 1;
    const dash = 4.0;
    const gap = 3.0;
    for (var x = rect.left; x < leftHalfRight; x += dash + gap) {
      canvas.drawLine(
          Offset(x, y), Offset(math.min(x + dash, leftHalfRight), y),
          linePaint);
    }
    // 左缘三角形滑块（尺寸随全局控制点减半约定：10x7 → 5x3.5）。
    final tri = Path()
      ..moveTo(rect.left, y - 2.5)
      ..lineTo(rect.left, y + 2.5)
      ..lineTo(rect.left + 3.5, y)
      ..close();
    canvas.drawPath(tri, Paint()..color = green);
  }

  @override
  bool shouldRepaint(_BaselineOverlayPainter old) =>
      old.baselinePct != baselinePct;
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

/// 色温调节器右下角直方图：调整后 R/G/B 三通道对数刻度竖条叠加（复用
/// 曲线调节器的直方图绘制，黑底、无坐标轴标注；未运行时不画）。
class _RgbHistMiniPainter extends CustomPainter {
  final (Uint32List, Uint32List, Uint32List)? hist;

  const _RgbHistMiniPainter(this.hist);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.black);
    final h = hist;
    if (h == null) return;
    _LevelsCurvePainter._drawHistogram(
        canvas, size, h.$1, const Color(0x99E05353));
    _LevelsCurvePainter._drawHistogram(
        canvas, size, h.$2, const Color(0x9953E553));
    _LevelsCurvePainter._drawHistogram(
        canvas, size, h.$3, const Color(0x995383E5));
  }

  @override
  bool shouldRepaint(_RgbHistMiniPainter old) => !identical(old.hist, hist);
}

/// 曲线调节器的曲线编辑器：黑色背景 + 输入 Y 直方图（对数刻度，半透
/// 明白）+ 输出（调节后）Y 直方图（对数刻度，#605040）+ 四分网格 +
/// 传递函数曲线（#FFD0B0；生成公式由 curveMode 参数选择：单调三次
/// 样条/贝塞尔/线段）。X 为输入值、Y 为输出值，
/// 值域 0..4095；曲线区长宽比恒定 1:1（边长取可用空间短边，整体
/// 居中），左缘竖条为输出灰阶（上白下黑）、底缘横条为输入灰阶
/// （左黑右白）。交互：单击空白加点、拖动移点（中间点 x 限制在
/// 相邻点之间，端点 A1/C1 的 x 固定）、**拖住控制点移出曲线区
/// （外扩 16px 容差，约等于移出节点附加区）即删除该点**（端点不可
/// 删）。命中半径随画布缩放自适应（恒定 12 屏幕像素），缩放画布里
/// 小方块也能点中。拖动只写参数（曲线实时重绘），松手才重跑流水线。
/// gamma 模式例外：只允许一个控制点（点按/拖动任意位置即移动它），
/// 点恒落在 y = max·(x/max)^(1/γ) 曲线上，拖动时控制点旁显示 γ 值
/// 气泡；γ 也可在属性面板的 Gamma 参数中直接设置。
class _LevelsCurveEditor extends StatefulWidget {
  final IspStudioState state;
  final IspNode node;

  const _LevelsCurveEditor({required this.state, required this.node});

  @override
  State<_LevelsCurveEditor> createState() => _LevelsCurveEditorState();
}

class _LevelsCurveEditorState extends State<_LevelsCurveEditor> {
  /// 正在拖动的控制点下标（拖动中曲线绘制为高亮）。
  int? _dragIndex;

  /// 拖出判定容差：曲线区外扩 16px 覆盖灰阶条与内边距，约等于
  /// 「移出曲线调节器节点」。
  static const _kDragOutMargin = 16.0;

  LevelsCurveMode get _mode =>
      levelsCurveModeFromParam(widget.node.paramValues['curveMode']);

  double get _gamma =>
      (widget.node.paramValues['gamma'] as num?)?.toDouble() ?? 1.0;

  List<List<double>> get _points {
    final pts = levelsPointsFromParam(widget.node.paramValues['points']);
    if (_mode != LevelsCurveMode.gamma) return pts;
    // gamma 模式只允许一个控制点：取存储的首个中间点 x（缺省 1024），
    // y 由 gamma 曲线推出（显示的点恒落在对应的 gamma 曲线上）。
    final x = pts.length > 2 ? pts[1][0] : 1024.0;
    final max = kLevelsMax.toDouble();
    return [
      [0.0, 0.0],
      [x, gammaCurveEval(x, _gamma)],
      [max, max],
    ];
  }

  void _writePoints(List<List<double>> points, {required bool rerun}) {
    widget.state
        .setParam(widget.node.id, 'points', normalizeLevelsPoints(points));
    if (rerun) widget.state.runPreview();
  }

  /// gamma 模式：把唯一控制点移到值域 (x, y)，由点位置反解 γ 并同步
  /// 写入 gamma/points 两个参数（y 落在反解出的 gamma 曲线上）。
  void _writeGammaPoint(double x, double y, {required bool rerun}) {
    final max = kLevelsMax.toDouble();
    // 避开 0/max（对数无定义），γ 限制在参数范围内。
    final cx = x.clamp(1.0, max - 1);
    final cy = y.clamp(1.0, max - 1);
    final g = (gammaFromPoint(cx, cy) ?? _gamma).clamp(0.1, 10.0);
    widget.state.setParam(widget.node.id, 'gamma', g);
    widget.state.setParam(widget.node.id, 'points', [
      [0.0, 0.0],
      [cx, gammaCurveEval(cx, g)],
      [max, max],
    ]);
    if (rerun) widget.state.runPreview();
  }

  /// 像素坐标 → 曲线值域（x 向右 0..4095，y 向上 0..4095）。
  List<double> _toValue(Offset pos, Size size) {
    final max = kLevelsMax.toDouble();
    final x = size.width <= 0 ? 0.0 : pos.dx / size.width * max;
    final y = size.height <= 0 ? 0.0 : (1 - pos.dy / size.height) * max;
    return [x.clamp(0.0, max), y.clamp(0.0, max)];
  }

  /// 命中测试：返回距 [pos] 一个命中半径内的控制点下标（无则 null）。
  /// 半径恒定 12 屏幕像素（除以画布缩放换算为曲线区逻辑像素），
  /// 画布缩小时 7px 的控制点方块也能可靠点中。
  int? _hitPoint(Offset pos, Size size, List<List<double>> points) {
    final max = kLevelsMax.toDouble();
    final zoom = widget.state.canvasZoom;
    final radius = 12.0 / (zoom > 0 ? zoom : 1.0);
    for (var i = 0; i < points.length; i++) {
      final px = points[i][0] / max * size.width;
      final py = (1 - points[i][1] / max) * size.height;
      if ((Offset(px, py) - pos).distance <= radius) return i;
    }
    return null;
  }

  void _tapDown(TapDownDetails d, Size size) {
    final v = _toValue(d.localPosition, size);
    // gamma 模式：不允许加点，点按即把唯一控制点移到该处。
    if (_mode == LevelsCurveMode.gamma) {
      _writeGammaPoint(v[0], v[1], rerun: true);
      return;
    }
    final points = _points;
    // 点上按下不处理（等拖动或双击）；空白处单击加点。
    if (_hitPoint(d.localPosition, size, points) != null) return;
    _writePoints([...points, v], rerun: true);
  }

  void _panStart(DragStartDetails d, Size size) {
    // gamma 模式：拖动的恒为唯一中间点（点按已由 _tapDown 落位）。
    if (_mode == LevelsCurveMode.gamma) {
      setState(() => _dragIndex = 1);
      return;
    }
    final points = _points;
    var hit = _hitPoint(d.localPosition, size, points);
    if (hit == null) {
      // 空白处开始拖动：先在该处加点再拖它。
      final v = _toValue(d.localPosition, size);
      final next = normalizeLevelsPoints([...points, v]);
      widget.state.setParam(widget.node.id, 'points', next);
      hit = _hitPoint(d.localPosition, size, next) ?? next.length - 2;
    }
    setState(() => _dragIndex = hit);
  }

  void _panUpdate(DragUpdateDetails d, Size size) {
    final i = _dragIndex;
    if (i == null) return;
    final pos = d.localPosition;
    final v = _toValue(pos, size);
    // gamma 模式：跟随移动唯一控制点并反解 γ（不可拖出删除）。
    if (_mode == LevelsCurveMode.gamma) {
      _writeGammaPoint(v[0], v[1], rerun: false);
      return;
    }
    final points = [for (final p in _points) [...p]];
    if (i >= points.length) return;
    // 拖出曲线区（含容差）即删除该点；端点 A1/C1 不可删。
    final out = pos.dx < -_kDragOutMargin ||
        pos.dx > size.width + _kDragOutMargin ||
        pos.dy < -_kDragOutMargin ||
        pos.dy > size.height + _kDragOutMargin;
    if (out) {
      if (i > 0 && i < points.length - 1) {
        _writePoints(points..removeAt(i), rerun: true);
      }
      setState(() => _dragIndex = null);
      return;
    }
    // 端点 x 固定；中间点 x 限制在相邻点之间（保持严格递增）。
    if (i > 0 && i < points.length - 1) {
      points[i][0] =
          v[0].clamp(points[i - 1][0] + 1, points[i + 1][0] - 1);
    }
    points[i][1] = v[1];
    _writePoints(points, rerun: false);
  }

  void _panEnd(DragEndDetails d) {
    if (_dragIndex == null) return;
    setState(() => _dragIndex = null);
    widget.state.runPreview();
  }

  @override
  Widget build(BuildContext context) {
    final points = _points;
    final histogram = widget.state.levelsHistograms[widget.node.id];
    final outHistogram =
        widget.state.levelsOutputHistograms[widget.node.id];
    final mode = _mode;
    final gamma = _gamma;
    return LayoutBuilder(
      builder: (context, constraints) {
        // 曲线区长宽比恒定 1:1：灰阶条占 10+2，边长取剩余宽高的
        // 较小值，整体居中。
        final side = math.max(
            0.0,
            math.min(constraints.maxWidth - 12,
                constraints.maxHeight - 12));
        final plot = SizedBox(
          width: side,
          height: side,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => _tapDown(d, Size.square(side)),
            onPanStart: (d) => _panStart(d, Size.square(side)),
            onPanUpdate: (d) => _panUpdate(d, Size.square(side)),
            onPanEnd: _panEnd,
            child: CustomPaint(
              painter: _LevelsCurvePainter(
                points: points,
                mode: mode,
                gamma: gamma,
                // gamma 模式拖动中显示 γ 值气泡。
                gammaBubble: mode == LevelsCurveMode.gamma &&
                        _dragIndex != null
                    ? gamma
                    : null,
                histogram: histogram,
                outputHistogram: outHistogram,
                dragIndex: _dragIndex,
              ),
              child: const SizedBox.expand(),
            ),
          ),
        );
        return Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 输出灰阶条（上白下黑，对应 Y 轴输出值）。
              Container(
                width: 10,
                height: side,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.white, Colors.black],
                  ),
                ),
              ),
              const SizedBox(width: 2),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  plot,
                  const SizedBox(height: 2),
                  // 输入灰阶条（左黑右白，对应 X 轴输入值）。
                  Container(
                    width: side,
                    height: 10,
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Colors.black, Colors.white],
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 曲线调节器曲线区绘制：黑底 + 输入 Y 直方图（对数刻度竖条，半透明白，
/// 未运行时不画）+ 输出（调节后）Y 直方图（对数刻度竖条，#605040，叠在
/// 输入直方图之上）+ 四分网格与框线 + 传递函数曲线（#FFD0B0，生成公式
/// 由 [mode] 决定）+ 控制点小方块（拖动中的点实心，其余空心）。
class _LevelsCurvePainter extends CustomPainter {
  final List<List<double>> points;
  final LevelsCurveMode mode;

  /// gamma 模式的 γ 值（曲线由它而非控制点决定）。
  final double gamma;

  /// 非空时在拖动中的控制点旁画 γ 值气泡（gamma 模式拖动反馈）。
  final double? gammaBubble;
  final Uint32List? histogram;
  final Uint32List? outputHistogram;
  final int? dragIndex;

  _LevelsCurvePainter({
    required this.points,
    required this.mode,
    required this.gamma,
    required this.gammaBubble,
    required this.histogram,
    required this.outputHistogram,
    required this.dragIndex,
  });

  /// 画一幅对数刻度 Y 直方图竖条（与直方图仪器同一呈现；[hist] 为
  /// null 或全零时不画）。
  static void _drawHistogram(
      Canvas canvas, Size size, Uint32List? hist, Color color) {
    if (hist == null || hist.isEmpty) return;
    var max = 0;
    for (final c in hist) {
      if (c > max) max = c;
    }
    if (max <= 0) return;
    final logMax = math.log(max + 1);
    final barWidth = size.width / hist.length;
    final paint = Paint()..color = color;
    for (var i = 0; i < hist.length; i++) {
      if (hist[i] == 0) continue;
      final h = math.log(hist[i] + 1) / logMax * size.height;
      canvas.drawRect(
          Rect.fromLTWH(i * barWidth, size.height - h, barWidth + 0.5, h),
          paint);
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = Colors.black);

    // 输入 Y 直方图背景 + 输出（调节后）Y 直方图叠加（对数刻度）。
    _drawHistogram(canvas, size, histogram, const Color(0x55FFFFFF));
    _drawHistogram(canvas, size, outputHistogram, const Color(0xFF605040));

    // 四分网格与框线。格线用 hairline（strokeWidth 0 = 恒 1 物理像素，
    // 高分屏下不会因 strokeWidth 1 糊成 2px+）。
    final faint = Paint()
      ..color = const Color(0x33FFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0;
    final frame = Paint()
      ..color = const Color(0x66FFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      final x = size.width * i / 4;
      final y = size.height * i / 4;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), faint);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), faint);
    }
    canvas.drawRect(rect, frame);

    // X=Y 参考斜线（左下 → 右上，即恒等传递函数；比格线略亮，仍为
    // hairline，便于和实际曲线区分）。
    canvas.drawLine(
        Offset(0, size.height),
        Offset(size.width, 0),
        Paint()
          ..color = const Color(0x55FFFFFF)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0);

    // 传递函数曲线（128 段折线逼近；生成公式由 curveMode 参数决定）。
    final max = kLevelsMax.toDouble();
    final path = Path();
    const segments = 128;
    for (var i = 0; i <= segments; i++) {
      final x = i / segments * max;
      final y = levelsCurveEval(points, x, mode: mode, gamma: gamma)
          .clamp(0.0, max);
      final px = x / max * size.width;
      final py = (1 - y / max) * size.height;
      if (i == 0) {
        path.moveTo(px, py);
      } else {
        path.lineTo(px, py);
      }
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = const Color(0xFFFFD0B0)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5);

    // 控制点：6px 小方块（拖动中的实心，其余黑底白框）。
    final border = Paint()..color = Colors.white;
    final fill = Paint()..color = Colors.black;
    final active = Paint()..color = Colors.white;
    for (var i = 0; i < points.length; i++) {
      final px = points[i][0] / max * size.width;
      final py = (1 - points[i][1] / max) * size.height;
      final r = Rect.fromCenter(center: Offset(px, py), width: 7, height: 7);
      canvas.drawRect(r, i == dragIndex ? active : fill);
      canvas.drawRect(
          r,
          border
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1);
    }

    // gamma 模式拖动中的 γ 值气泡：跟随被拖控制点，默认在点右上方，
    // 越界时翻转到左侧/下方。
    final gb = gammaBubble;
    final di = dragIndex;
    if (gb != null && di != null && di < points.length) {
      final px = points[di][0] / max * size.width;
      final py = (1 - points[di][1] / max) * size.height;
      final tp = TextPainter(
        text: TextSpan(
          text: 'γ = ${gb.toStringAsFixed(2)}',
          style: const TextStyle(fontSize: 11, color: Colors.white),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      const pad = 5.0;
      final bw = tp.width + pad * 2;
      final bh = tp.height + pad * 2;
      var bx = px + 10;
      var by = py - bh - 10;
      if (bx + bw > size.width) bx = px - bw - 10;
      if (by < 0) by = py + 10;
      final rrect = RRect.fromRectAndRadius(
          Rect.fromLTWH(bx, by, bw, bh), const Radius.circular(4));
      canvas.drawRRect(rrect, Paint()..color = const Color(0xCC000000));
      canvas.drawRRect(
          rrect,
          Paint()
            ..color = const Color(0xFFFFD0B0)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1);
      tp.paint(canvas, Offset(bx + pad, by + pad));
    }
  }

  @override
  bool shouldRepaint(_LevelsCurvePainter old) => true;
}
