/// ISP Studio 节点卡片：标题栏、端口行与类型附加控件。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../../providers/isp_studio_state.dart';
import '../models/isp_node.dart';
import '../models/multi_band_eq_params.dart';
import '../pipeline/audio_analysis.dart';
import '../pipeline/color_temp.dart';
import '../pipeline/isp_kernels.dart';
import '../pipeline/levels_curve.dart';
import '../pipeline/pyiqa_worker.dart';
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
      // 按下即选中节点：onTapDown 不经手势竞技场，内部滑条/按钮/附加区
      // 的手势（拖动调参、取色、播放等）照常优先处理自身逻辑，选中同时
      // 进行——点击节点内任意位置都高亮选中。节点拖动由画布的右键拖拽
      // 统一处理；删除只走键盘 Delete。
      onTapDown: (_) {
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
                  if (type.typeId == 'video_source')
                    _buildVideoSourceExtra(state),
                  if (type.typeId == 'preview') _buildPreviewExtra(state),
                  if (type.typeId == 'hsl_debugger')
                    _buildHslDebugExtra(state),
                  if (type.typeId == 'color_controller')
                    _buildColorControllerExtra(state),
                  if (type.typeId == 'multi_band_eq')
                    _buildMultiBandEqExtra(state),
                  if (type.typeId == 'rgb_debugger')
                    _buildRgbDebugExtra(state),
                  if (type.typeId == 'yuv_debugger')
                    _buildYuvDebugExtra(state),
                  if (type.typeId == 'sat_bright_adjuster')
                    _buildSatBrightExtra(state),
                  if (type.typeId == 'bright_contrast_adjuster')
                    _buildBrightContrastExtra(state),
                  if (type.typeId == 'gaussian_blur')
                    _buildGaussianBlurExtra(state),
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
                    _buildVideoOutputExtra(state),
                  if (type.typeId == 'format_converter')
                    _buildFormatConvertExtra(state),
                  if (type.typeId == 'video_health_check')
                    _buildHealthCheckExtra(state),
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
            child: _VectorscopeHoverRegion(
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
    } else if (type.typeId == 'ssim' ||
        type.typeId == 'msssim' ||
        type.typeId == 'fsim') {
      // SSIM/MS-SSIM/FSIM 数字表：大字号总体值 + R/G/B 分通道值；
      // 未运行/缺输入/尺寸不一致分别显示提示。完全相同（1.0）以绿色突出。
      final metric = switch (type.typeId) {
        'ssim' => 'SSIM',
        'msssim' => 'MS-SSIM',
        _ => 'FSIM',
      };
      final result = state.instrumentResults[node.id];
      final err = result?['error'] as String?;
      // 结果键随指标命名（ssim*/fsim*），显示逻辑共享。
      final ssim = (result?['ssim'] ?? result?['fsim']) as double?;
      final sr = (result?['ssimR'] ?? result?['fsimR']) as double?;
      final sg = (result?['ssimG'] ?? result?['fsimG']) as double?;
      final sb = (result?['ssimB'] ?? result?['fsimB']) as double?;
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
                      Text(
                        ssim!.toStringAsFixed(4),
                        style: TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.bold,
                          color: ssim >= 1.0
                              ? const Color(0xFF50C080)
                              : Colors.white,
                        ),
                      ),
                      Text(metric,
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey.shade400)),
                      const SizedBox(height: 8),
                      Text(
                          'R ${sr!.toStringAsFixed(4)}  '
                          'G ${sg!.toStringAsFixed(4)}  '
                          'B ${sb!.toStringAsFixed(4)}',
                          style: TextStyle(
                              fontSize: 10, color: Colors.grey.shade500)),
                    ],
                  ),
      );
    } else if (type.typeId == 'niqe' ||
        type.typeId == 'brisque' ||
        type.typeId == 'ilniqe' ||
        type.typeId == 'piqe') {
      // NIQE/BRISQUE/ILNIQE/PIQE 数字表：无参考，大字号分值 + 标签；
      // 越小越好（与其他数字表相反），NaN（图太小无法计算）显示 '—'。
      final label = switch (type.typeId) {
        'niqe' => 'NIQE',
        'brisque' => 'BRISQUE',
        'ilniqe' => 'ILNIQE',
        _ => 'PIQE',
      };
      final result = state.instrumentResults[node.id];
      final score = (result?[switch (type.typeId) {
        'niqe' => 'niqe',
        'brisque' => 'brisque',
        'ilniqe' => 'ilniqe',
        _ => 'piqe',
      }]) as double?;
      final valid = score != null && !score.isNaN;
      content = Center(
        child: result == null
            ? hint
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    valid ? score.toStringAsFixed(2) : '—',
                    style: const TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  Text(label,
                      style: TextStyle(
                          fontSize: 12, color: Colors.grey.shade400)),
                  const SizedBox(height: 8),
                  Text(valid ? '越小越好' : '图像太小',
                      style: TextStyle(
                          fontSize: 10, color: Colors.grey.shade500)),
                ],
              ),
      );
    } else if (pyIqaMetrics.containsKey(type.typeId)) {
      // 深度评价数字表（LPIPS/DISTS/FID/KID/MUSIQ/CLIPIQA，Python 桥接）：
      // 大字号分值 + 标签 + 方向提示；error（Python 环境缺失/输入未接等）
      // 显示提示文本；FID/KID 附两侧样本计数，样本不足显示「累计中」。
      final label = type.typeId.toUpperCase();
      final info = pyIqaMetrics[type.typeId]!;
      final result = state.instrumentResults[node.id];
      final err = result?['error'] as String?;
      final score = result?[type.typeId] as double?;
      final nRef = result?['n_ref'] as int?;
      final nTest = result?['n_test'] as int?;
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
                      Text(
                        score != null ? score.toStringAsFixed(4) : '…',
                        style: const TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      Text(label,
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey.shade400)),
                      const SizedBox(height: 8),
                      Text(
                        score != null
                            ? (nRef != null
                                ? '${info.lowerBetter ? '越小越好' : '越大越好'}'
                                    '（${nRef}v${nTest ?? 0} 样本）'
                                : (info.lowerBetter ? '越小越好' : '越大越好'))
                            : '累计中（${nRef ?? 0}v${nTest ?? 0} 样本，≥2 出分）',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 10, color: Colors.grey.shade500)),
                    ],
                  ),
      );
    } else if (type.typeId == 'minmax') {
      // 最值保持器：当前帧最大/最小 + 跨帧保持值（琥珀色突出），
      // 复位按钮清空保持值（下一帧重新累计）。
      final result = state.instrumentResults[node.id];
      final curMax = result?['max'] as int?;
      final curMin = result?['min'] as int?;
      final holdMax = result?['holdMax'] as int?;
      final holdMin = result?['holdMin'] as int?;
      content = Center(
        child: result == null
            ? hint
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _minmaxLine('最大', curMax, holdMax),
                  const SizedBox(height: 6),
                  _minmaxLine('最小', curMin, holdMin),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 24,
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        foregroundColor: Colors.white70,
                        side: BorderSide(color: Colors.grey.shade700),
                      ),
                      onPressed: () => state.resetMinmaxHold(node.id),
                      child:
                          const Text('复位', style: TextStyle(fontSize: 11)),
                    ),
                  ),
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

  /// 最值保持器的一行读数：标签 + 当前帧值（白色大字）+ 保持值（琥珀色）。
  /// FittedBox 缩放兜底：窄节点下数值过长时整体缩小而非溢出。
  Widget _minmaxLine(String label, int? cur, int? hold) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(label,
              style: TextStyle(fontSize: 11, color: Colors.grey.shade400)),
          const SizedBox(width: 8),
          Text('${cur ?? '--'}',
              style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.white)),
          const SizedBox(width: 10),
          Text('保持 ${hold ?? '--'}',
              style: const TextStyle(fontSize: 10, color: Color(0xFFF0B050))),
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
              // 多段色彩均衡器：读取色彩风格预设后标题栏追加
              // 「（风格文件名）」，配置参数调整后清除（清除逻辑在
              // IspStudioState.setParam/setParams）。
              type.typeId == 'multi_band_eq' &&
                      (node.paramValues['style_name']?.toString() ?? '')
                          .isNotEmpty
                  ? '${node.name}（${node.paramValues['style_name']}）'
                  : node.name,
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
                      color: Colors.white70, fontSize: 15),
                ),
              ),
            ),
          // 查看代码（只读标签页）。
          Tooltip(
            message: '查看代码',
            child: InkWell(
              onTap: () => state.openCodeTab(node.id),
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Image.asset('icons/code-oss.png', width: 26, height: 26),
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
              type.typeId == 'gaussian_blur' ||
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
                  child: Image.asset(
                    state.maximizedNodeId == node.id
                        ? 'icons/screen-normal.png'
                        : 'icons/screen-full.png',
                    width: 26,
                    height: 26,
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

  /// 视频源节点附加区（单行源信息）：未运行/非当前帧序源时显示视频
  /// 文件名；本节点是当前帧序（previewFrame/totalFrames）的源且帧率
  /// 已知时显示「当前时间/总时长」（与预览控制条时间文本同口径）。
  /// 逐帧刷新走 [IspStudioState.frameTick]，只有本行重建。
  Widget _buildVideoSourceExtra(IspStudioState state) {
    return ValueListenableBuilder<int>(
      valueListenable: state.frameTick,
      builder: (context, tick, child) {
        final total = state.totalFrames ?? 1;
        final isSrc = state.previewSrcNodeId == node.id;
        final showTime = isSrc && total > 1 && state.playbackSrcFps > 0;
        final String text;
        if (showTime) {
          text = playbackTimeText(state, total);
        } else {
          final path = node.paramValues['filePath']?.toString() ?? '';
          text = path.isEmpty ? '未选择视频文件' : p.basename(path);
        }
        // 时间形态：白字（透明底，与节点底色一致）+ 下方同款字体的
        // 「已播放帧数/总帧数」，两行均水平居中；文件名形态保持灰色小字。
        // 底部固定控制行：前一帧 / 播放暂停 / 倍速 / 后一帧。
        // 行高 116（30 时间 + 30 帧数·帧率 + 20 进度条 + 36 控制行，
        // nodeHeight 同步 +116）。
        final canStep = showTime && !state.isPlaying && !state.isProcessing;
        return SizedBox(
          height: 116,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Column(
              children: [
                SizedBox(
                  height: 30,
                  width: double.infinity,
                  child: Center(
                    child: showTime
                        ? Text(text,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: 'Consolas',
                              fontFamilyFallback: ['monospace'],
                              fontSize: 22.5,
                              color: Colors.white,
                            ))
                        : Align(
                            alignment: Alignment.centerLeft,
                            child: Text(text,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 10, color: Colors.grey)),
                          ),
                  ),
                ),
                SizedBox(
                  height: 30,
                  child: showTime
                      ? Center(
                          child: Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  // 已播放帧数/总帧数（左侧补零使左右
                                  // 位数一致）
                                  text:
                                      '${'${state.previewFrame}'.padLeft('$total'.length, '0')}/$total',
                                  style: const TextStyle(
                                    fontFamily: 'Consolas',
                                    fontFamilyFallback: ['monospace'],
                                    fontSize: 18,
                                    color: Colors.white,
                                  ),
                                ),
                                // 实时播放帧率（最近 1 秒上屏帧数；
                                // 字体颜色与帧数一致，仅播放中显示）
                                if (state.isPlaying)
                                  TextSpan(
                                    text: '  ${state.playbackFps} FPS',
                                    style: const TextStyle(
                                      fontFamily: 'Consolas',
                                      fontFamilyFallback: ['monospace'],
                                      fontSize: 18,
                                      color: Colors.white,
                                    ),
                                  ),
                              ],
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        )
                      : null,
                ),
                // 播放进度条：当前帧/总帧数；暂停时可拖动定位
                //（播放中禁用，与预览控制条同口径）。
                SizedBox(
                  height: 20,
                  child: SliderTheme(
                    data: kIspSliderTheme,
                    child: Slider(
                      value: showTime
                          ? state.previewFrame
                              .clamp(0, total - 1)
                              .toDouble()
                          : 0,
                      min: 0,
                      max: (total - 1).toDouble(),
                      onChanged: !showTime || state.isPlaying
                          ? null
                          : (v) => state.setPreviewFrame(v.round()),
                      onChangeEnd: !showTime || state.isPlaying
                          ? null
                          : (_) => state.runPreview(),
                    ),
                  ),
                ),
                SizedBox(
                  height: 36,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _videoCtlBtn(
                        Icons.folder_open,
                        '打开视频文件',
                        // 播放中禁换片（解码流已按旧片起好）。
                        state.isPlaying
                            ? null
                            : () => _pickVideoFile(state),
                      ),
                      _videoCtlBtn(
                        Icons.skip_previous,
                        '前一帧',
                        canStep && state.previewFrame > 0
                            ? () => state.stepPreviewFrame(-1)
                            : null,
                      ),
                      _videoCtlBtn(
                        state.isPlaying ? Icons.pause : Icons.play_arrow,
                        state.isPlaying ? '暂停' : '播放',
                        state.isProcessing && !state.isPlaying
                            ? null
                            : () => state.togglePlayback(),
                      ),
                      // 倍速选择（帧间隔 = 标称帧间隔 / 倍速；非 1x 无音频）
                      DropdownButtonHideUnderline(
                        child: DropdownButton<double>(
                          value: state.playbackSpeed,
                          isDense: true,
                          dropdownColor: const Color(0xFF2E2E2E),
                          style: const TextStyle(
                              fontSize: 16.5, color: Colors.white),
                          items: const [
                            DropdownMenuItem(value: 0.25, child: Text('0.25x')),
                            DropdownMenuItem(value: 0.5, child: Text('0.5x')),
                            DropdownMenuItem(value: 0.75, child: Text('0.75x')),
                            DropdownMenuItem(value: 1.0, child: Text('1x')),
                            DropdownMenuItem(value: 1.5, child: Text('1.5x')),
                            DropdownMenuItem(value: 2.0, child: Text('2x')),
                          ],
                          onChanged: (v) {
                            if (v != null) state.setPlaybackSpeed(v);
                          },
                        ),
                      ),
                      _videoCtlBtn(
                        Icons.skip_next,
                        '后一帧',
                        canStep && state.previewFrame < total - 1
                            ? () => state.stepPreviewFrame(1)
                            : null,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 视频源控制行小按钮（null onTap = 禁用置灰）。
  Widget _videoCtlBtn(IconData icon, String tip, VoidCallback? onTap) {
    return Tooltip(
      message: tip,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          child: Icon(
            icon,
            size: 24,
            color: onTap == null ? Colors.white24 : Colors.white,
          ),
        ),
      ),
    );
  }

  /// 控制行「打开」：选择视频文件并写入 filePath（与属性面板同口径；
  /// setParam 联动复位播放进度并自动填充帧率/帧数）。
  Future<void> _pickVideoFile(IspStudioState state) async {
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: '视频',
          extensions: ['mp4', 'mkv', 'avi', 'mov', 'ts', 'flv', 'wmv'],
        ),
      ],
    );
    final path = file?.path;
    if (path != null) state.setParam(node.id, 'filePath', path);
  }

  /// 预览附加区：屏幕 + 播放控制条 + 底部拖动手柄（调整屏幕高度）。
  /// 逐帧刷新走 [IspStudioState.frameTick]，只有本区重建。
  /// RepaintBoundary 隔离逐帧重绘：没有它时预览换帧的脏区冒泡到根，
  /// 整个 4K 节点画布（网格背景+全部节点）每帧跟着光栅化（实测
  /// 栅格 19-21ms/帧、75Hz 屏帧泵被拖到 ~48Hz——4K 播放"丢帧"
  /// 观感的真凶）。
  Widget _buildPreviewExtra(IspStudioState state) {
    return ValueListenableBuilder<int>(
      valueListenable: state.frameTick,
      builder: (context, tick, child) =>
          RepaintBoundary(child: _buildPreviewExtraContent(state)),
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
                // HDR/SDR 切换（视频源片源决定形态）：SDR 片源只显示静态
                // 标识；HDR 片源（PQ/HLG）两段互斥——SDR=直解对比 /
                // HDR=色调映射显示（默认）。
                if (state.playbackSrcTransfer == 0)
                  const Padding(
                    padding: EdgeInsets.only(right: 2),
                    child: Text('SDR',
                        style: TextStyle(fontSize: 10, color: Colors.grey)),
                  )
                else
                  _buildHdrToneMapToggle(state),
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
                // 进度滑条右侧：已播放时间/总时间（视频源播放时显示）。
                if (total > 1 && state.playbackSrcFps > 0)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Text(playbackTimeText(state, total),
                        style:
                            const TextStyle(fontSize: 10, color: Colors.grey)),
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

  /// 预览控制条的 HDR/SDR 两段互斥切换（仅 HDR 片源显示；选中段蓝底
  /// 白字高亮）。选 HDR = zscale+tonemap 映射显示（默认）；选 SDR =
  /// HDR 片源直解对比（发灰原样）。
  Widget _buildHdrToneMapToggle(IspStudioState state) {
    Widget seg(String label, bool selected, String tip) {
      return Tooltip(
        message: tip,
        waitDuration: const Duration(milliseconds: 400),
        child: InkWell(
          onTap: selected ? null : () => state.toggleHdrToneMap(),
          child: Container(
            height: 18,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? const Color(0xFF2B5A8C) : Colors.transparent,
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(label,
                style: TextStyle(
                    fontSize: 10,
                    color: selected ? Colors.white : Colors.grey)),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(right: 2),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey.shade800),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            seg('SDR', !state.hdrToneMapEnabled, 'SDR 直解对比（不做色调映射）'),
            seg('HDR', state.hdrToneMapEnabled, 'HDR 色调映射显示（zscale+tonemap）'),
          ],
        ),
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

  /// 色彩控制器附加区：双联矢量示波器（左调整前/右调整后，表盘叠加高斯
  /// 色相带）+ H中心/Q/ΔH/S/L 五行紧凑滑块 + 底部拖动手柄。
  /// 拖动滑块只写参数（实时重绘色相带），松手才重跑流水线更新示波器图。
  Widget _buildColorControllerExtra(IspStudioState state) {
    return ValueListenableBuilder<int>(
      valueListenable: state.frameTick,
      builder: (context, tick, child) => _buildColorControllerContent(state),
    );
  }

  Widget _buildColorControllerContent(IspStudioState state) {
    final scopeImage = state.hslVectorscopes[node.id];
    final inputScopeImage = state.hslInputVectorscopes[node.id];
    final hasInput = state.graph.connectionAt(node.id, 'in') != null;
    final extra = state.previewExtraHeight(node.id);
    final hCenter = (node.paramValues['h_center'] as num?)?.toDouble() ?? 0;
    final q = (node.paramValues['q'] as num?)?.toDouble() ?? 2;
    final hShift = (node.paramValues['h_shift'] as num?)?.toDouble() ?? 0;
    // 5 行滑块各 24，顶部留白 4，底部手柄 10，其余归示波器区。
    final scopeHeight = math.max(0.0, extra - 4 - 24 * 5 - 10);
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
                  // 左半：调整前（输入链统计），色带以 H 为中心（白色标线）；
                  // 右半：调整后（输出链统计），色带以 H+ΔH 为中心（黄色标线），
                  // 另有白色静态标线指回原 H 位置便于对比。
                  Expanded(
                      child: _buildBandScopePane(
                          inputScopeImage,
                          '调整前',
                          hasInput ? '运行预览后显示' : '未连接输入',
                          hCenter, q)),
                  const SizedBox(width: 4),
                  Expanded(
                      child: _buildBandScopePane(scopeImage, '调整后',
                          '运行预览后显示效果', hCenter + hShift, q,
                          referenceDeg: hCenter,
                          centerColor: const Color(0xFFF5F543))),
                ],
              ),
            ),
          ),
          _buildHslSliderRow(state, 'H中心', 'h_center', 0, 360, 0,
              (v) => '${v.toStringAsFixed(0)}°',
              labelWidth: 34, livePreview: true),
          _buildHslSliderRow(state, 'Q', 'q', 0.5, 100, 2,
              // 右侧同时显示高斯带宽 σ = 45°/Q
              (v) => '${v.toStringAsFixed(1)} σ=${(45 / v).toStringAsFixed(1)}°',
              labelWidth: 34, valueWidth: 92, livePreview: true),
          _buildHslSliderRow(state, 'ΔH', 'h_shift', -180, 180, 0,
              (v) => '${v >= 0 ? '+' : ''}${v.toStringAsFixed(1)}°',
              labelWidth: 34, livePreview: true),
          _buildHslSliderRow(state, 'S', 's_gain', 0, 5, 1,
              (v) => '×${v.toStringAsFixed(2)}',
              labelWidth: 34, livePreview: true),
          _buildHslSliderRow(state, 'L', 'l_gain', 0, 5, 1,
              (v) => '×${v.toStringAsFixed(2)}',
              labelWidth: 34, livePreview: true),
          // 底部手柄条：与预览/仪器节点共用同一套拖动调整机制。
          _buildResizeBar(state),
        ],
      ),
    );
  }

  /// 多段色彩均衡器附加区：交互状态（取色/删除模式、取样像素缓存）在
  /// [_MultiBandEqExtra] 内；布局复用本类的滑块行/对比窗格/手柄构建器。
  Widget _buildMultiBandEqExtra(IspStudioState state) =>
      _MultiBandEqExtra(host: this, state: state, node: node);

  /// 色彩控制器矢量示波器的半区：迹线图 → 高斯色相带 → 坐标格三层叠加
  /// （无图时显示占位文案 [hint]），左上角叠加半透明小标签 [label]。
  /// 色相带以 [bandCenterDeg] 为中心（调整前传 H，调整后传 H+ΔH 并加
  /// 白色参考线指回原 H）。[overridePainter] 非空时替代单段色相带
  /// painter（多段色彩均衡器 ALL 视图的全段叠加）。[onToggleTrace]
  /// 非空时右上角显示隐藏/显示迹线（绿色线）按钮，[showTrace] 为当前
  /// 可见状态。
  /// 布局与 vectorscope 仪器一致：数据区是居中、边长为短边 82% 的正方形。
  Widget _buildBandScopePane(ui.Image? image, String label, String hint,
      double bandCenterDeg, double q,
      {double? referenceDeg,
      Color centerColor = Colors.white,
      CustomPainter? overridePainter,
      bool showTrace = true,
      ValueChanged<bool>? onToggleTrace}) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final side =
            math.min(constraints.maxWidth, constraints.maxHeight) * 0.82;
        return Stack(
          fit: StackFit.expand,
          children: [
            _VectorscopeHoverRegion(
              bandPainter: overridePainter ??
                  _HueBandPainter(
                      centerDeg: bandCenterDeg,
                      q: q,
                      centerColor: centerColor,
                      referenceDeg: referenceDeg),
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
                      // 隐藏迹线时保留黑底（坐标格与色带叠加照常显示）。
                      : (showTrace
                          ? RawImage(image: image, fit: BoxFit.fill)
                          : const SizedBox.shrink()),
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
            // 右上角：隐藏/显示迹线（绿色线）按钮。
            if (onToggleTrace != null)
              Positioned(
                right: 2,
                top: 2,
                child: GestureDetector(
                  onTap: () => onToggleTrace(!showTrace),
                  child: Icon(
                    showTrace ? Icons.visibility : Icons.visibility_off,
                    size: 12,
                    color: showTrace ? Colors.white54 : Colors.white24,
                  ),
                ),
              ),
          ],
        );
      },
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
            _VectorscopeHoverRegion(
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

  /// 高斯模糊附加区：双联对比预览（左调整前/右调整后，与色饱和度/
  /// 亮度调节器同一布局）+ σ/强度两行滑块 + 底部拖动手柄。
  /// 图刷新走 [IspStudioState.frameTick]；拖动滑块只写参数，松手重跑。
  Widget _buildGaussianBlurExtra(IspStudioState state) {
    return ValueListenableBuilder<int>(
      valueListenable: state.frameTick,
      builder: (context, tick, child) => _buildGaussianBlurExtraContent(state),
    );
  }

  Widget _buildGaussianBlurExtraContent(IspStudioState state) {
    final image = state.previewImages[node.id];
    final inputImage = state.previewInputImages[node.id];
    // 互斥输入组：in/in_yuv/in_hsl/in_mono 任一已连接即视为有输入。
    final hasInput = state.graph.connectionAt(node.id, 'in') != null ||
        state.graph.connectionAt(node.id, 'in_yuv') != null ||
        state.graph.connectionAt(node.id, 'in_hsl') != null ||
        state.graph.connectionAt(node.id, 'in_mono') != null;
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
          _buildHslSliderRow(state, 'σ', 'sigma', 0.1, 10, 1,
              (v) => v.toStringAsFixed(1)),
          _buildHslSliderRow(state, '强度', 'strength', 0, 1, 1,
              (v) => '${(v * 100).toStringAsFixed(0)}%',
              labelWidth: 26),
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
      {double labelWidth = 12, double valueWidth = 48, bool livePreview = false}) {
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
                // 拖动中只写参数（不重跑流水线），松手才重跑；
                // livePreview 的行（色彩控制器）拖动中实时重跑——运行中
                // 的请求由 requestLivePreview 置脏标记合并，取最新参数。
                onChanged: (v) {
                  state.setParam(node.id, key, v);
                  if (livePreview) state.requestLivePreview();
                },
                onChangeEnd: (_) => state.runPreview(),
              ),
            ),
          ),
          SizedBox(
            width: valueWidth,
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
      IspStudioState state, String label, VoidCallback? onPressed,
      {Color? backgroundColor}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 3, 8, 3),
      child: SizedBox(
        height: 28,
        width: double.infinity,
        child: ElevatedButton(
          onPressed: state.isProcessing ? null : onPressed,
          style: ElevatedButton.styleFrom(
            foregroundColor: Colors.white,
            backgroundColor: backgroundColor,
            padding: EdgeInsets.zero,
            textStyle: const TextStyle(fontSize: 12),
          ),
          child: Text(label),
        ),
      ),
    );
  }

  /// 视频输出节点附加区：按钮行（设定路径 + 导出 MP4）+ 内嵌终端
  /// 面板（导出过程：输入/路径/编码器/进度行/结果，复用格式转换的
  /// 终端组件与 tick 局部刷新模式）。尺寸固定 860x360（无拖动手柄）：
  /// 附加区总高 = extraHeight（234，即节点总高 360），构成 = 按钮行
  /// 34 + 间距 3 + 终端（extra − 37）。
  Widget _buildVideoOutputExtra(IspStudioState state) {
    final extra = state.previewExtraHeight(node.id);
    return SizedBox(
      height: extra,
      child: Column(
        children: [
          _buildVideoOutputButtons(state),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 3),
            child: ValueListenableBuilder<int>(
              valueListenable: state.videoExportTick,
              builder: (context, tick, child) => _FormatConvertConsole(
                log: state.videoExportLogs[node.id] ?? '',
                height: math.max(0.0, extra - 37),
                hint: '导出 MP4 的过程信息将在此显示',
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// CRF 质量档位（值即 x264 CRF：1 无损画质档，越大文件越小画质越低）。
  /// 「真无损」（crf 0）另会把编码器强制为 libx264：NVENC 的 -cq 0 只是
  /// 视觉无损，只有 libx264 -crf 0 位级无损；从真无损切到其他档时恢复
  /// 编码器 auto。
  static const Map<String, int> _crfPresets = {
    '真无损': 0,
    '无损': 1,
    '超高': 15,
    '高': 18,
    '较高': 21,
    '中': 25,
    '较低': 30,
    '最低': 40,
  };

  /// 视频输出节点按钮行：「设定路径」（选择输出 mp4，tooltip 显示当前
  /// 路径）+ CRF 档位下拉（无损~最低 / 自定义CRF值，自定义时展开
  /// 输入框）+「导出 MP4」（未设路径时先弹保存对话框）。
  Widget _buildVideoOutputButtons(IspStudioState state) {
    final outPath = node.paramValues['filePath']?.toString() ?? '';
    final crf = (node.paramValues['crf'] as num?)?.toInt() ?? 25;
    final isPreset = _crfPresets.containsValue(crf);
    // 档位标签显式带数值：无损画质（1）、超高画质（15）…；真无损标注
    // 编码器（0·libx264）；自定义显示当前值。
    String labelOf(String name) =>
        name == '真无损' ? '$name画质（0·libx264）' : '$name画质（${_crfPresets[name]}）';
    final selLabel = isPreset
        ? labelOf(_crfPresets.keys.firstWhere((k) => _crfPresets[k] == crf))
        : '自定义CRF值（$crf）';
    final btnStyle = ElevatedButton.styleFrom(
      foregroundColor: Colors.white,
      padding: EdgeInsets.zero,
      textStyle: const TextStyle(fontSize: 12),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 3, 8, 3),
      child: SizedBox(
        height: 28,
        // 三个控件等宽（自定义 CRF 输入框为附加件，不参与等分）。
        child: Row(
          children: [
            Expanded(
              child: Tooltip(
                message: outPath.isEmpty ? '未设置输出路径' : outPath,
                child: ElevatedButton(
                  onPressed: state.isProcessing
                      ? null
                      : () => _pickVideoOutputPath(state),
                  style: btnStyle,
                  child: _iconBtnContent('icons/folder-opened.png', '设定路径'),
                ),
              ),
            ),
            const SizedBox(width: 6),
            // CRF 档位：按钮风格一致（ElevatedButton 外观 + 弹出菜单）。
            Expanded(
              child: PopupMenuButton<String>(
                enabled: !state.isProcessing,
                color: const Color(0xFF2E2E2E),
                onSelected: (v) {
                  final preset = _crfPresets[v];
                  if (preset == null) return;
                  if (v == '真无损') {
                    // 位级无损：libx264 + crf 0（NVENC cq0 只是视觉无损）。
                    state.setParams(node.id, {'crf': 0, 'encoder': 'x264'});
                  } else if (crf == 0 &&
                      (node.paramValues['encoder']?.toString() ?? 'auto') ==
                          'x264') {
                    // 从真无损切出：恢复编码器自动选择。
                    state.setParams(node.id, {'crf': preset, 'encoder': 'auto'});
                  } else {
                    state.setParam(node.id, 'crf', preset);
                  }
                },
                itemBuilder: (context) => [
                  for (final name in _crfPresets.keys)
                    PopupMenuItem<String>(
                      value: name,
                      height: 30,
                      child: Text(
                        labelOf(name),
                        style: TextStyle(
                          fontSize: 12,
                          color: labelOf(name) == selLabel
                              ? Colors.white
                              : const Color(0xFFCCCCCC),
                        ),
                      ),
                    ),
                  PopupMenuItem<String>(
                    value: '自定义CRF值',
                    height: 30,
                    child: Text(
                      '自定义CRF值（$crf）',
                      style: TextStyle(
                        fontSize: 12,
                        color: !isPreset
                            ? Colors.white
                            : const Color(0xFFCCCCCC),
                      ),
                    ),
                  ),
                ],
                child: IgnorePointer(
                  child: ElevatedButton(
                    onPressed: () {}, // 仅外观；点击由 PopupMenuButton 处理
                    style: btnStyle,
                    child:
                        _iconBtnContent('icons/gear.png', selLabel, dropdown: true),
                  ),
                ),
              ),
            ),
            if (!isPreset) ...[
              const SizedBox(width: 6),
              SizedBox(
                width: 52,
                child: TextFormField(
                  key: ValueKey('crf_${node.id}_$crf'),
                  initialValue: '$crf',
                  keyboardType: TextInputType.number,
                  style: const TextStyle(fontSize: 12, color: Colors.white),
                  decoration: const InputDecoration(
                    isDense: true,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) {
                    final n = int.tryParse(v);
                    if (n != null) {
                      state.setParam(node.id, 'crf', n.clamp(0, 51));
                    }
                  },
                ),
              ),
            ],
            const SizedBox(width: 6),
            Expanded(
              child: ElevatedButton(
                onPressed: state.isProcessing
                    ? null
                    : () => _exportVideoMp4(state),
                style: btnStyle,
                child: _iconBtnContent('icons/go-to-file.png', '导出 MP4'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 带图标的按钮内容：codicons PNG（已重着色为纯白）+ 文本，
  /// [dropdown] 时尾部附加下拉箭头。
  Widget _iconBtnContent(String icon, String label, {bool dropdown = false}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Image.asset(icon, width: 24, height: 24),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12),
          ),
        ),
        if (dropdown) const Icon(Icons.arrow_drop_down, size: 16),
      ],
    );
  }

  /// 选择视频输出路径（保存对话框），写入 filePath；返回所选路径。
  Future<String?> _pickVideoOutputPath(IspStudioState state) async {
    final loc = await getSaveLocation(suggestedName: 'output.mp4');
    final path = loc?.path;
    if (path != null) state.setParam(node.id, 'filePath', path);
    return path;
  }

  /// 导出 MP4：未设置输出路径时先弹保存对话框（用户取消则不导出，
  /// 不再静默只在状态栏报错）。
  Future<void> _exportVideoMp4(IspStudioState state) async {
    final path = node.paramValues['filePath']?.toString() ?? '';
    if (path.isEmpty && await _pickVideoOutputPath(state) == null) return;
    state.exportVideo(node.id);
  }

  /// 格式转换节点附加区：「开始转换」按钮 + 内嵌终端面板（流式显示
  /// ffmpeg 输出，参照 CodeCompileArea 的终端形态）。节点尺寸固定
  /// 1500x1200（min=max 不可调，无拖动手柄）：附加区总高 = extraHeight
  /// （1162，即节点总高 1200），构成 = 按钮行 34 + 间距 3 + 终端
  /// （extra − 34 − 3）。转换中按钮禁用并改文案「转换中…」。
  Widget _buildFormatConvertExtra(IspStudioState state) {
    final running = state.formatConvertRunning.contains(node.id);
    final extra = state.previewExtraHeight(node.id);
    return SizedBox(
      height: extra,
      child: Column(
        children: [
          _buildExportButton(state, running ? '转换中…' : '开始转换',
              running ? null : () => state.convertVideoFormat(node.id)),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 3),
            child: ValueListenableBuilder<int>(
              valueListenable: state.formatConvertTick,
              builder: (context, tick, child) => _FormatConvertConsole(
                  log: state.formatConvertLogs[node.id] ?? '',
                  height: math.max(0.0, extra - 37)),
            ),
          ),
        ],
      ),
    );
  }

  /// 视频健康检查节点附加区：「开始检查」按钮 + 内嵌终端面板（流式
  /// 显示检查报告，复用格式转换的终端组件）。尺寸固定 1500x1200 同
  /// format_converter（无拖动手柄）。检查中按钮变为红色「停止检查」
  ///（点击置取消标记，引擎中止返回 -2）；播放中（isProcessing）开始
  /// 按钮禁用，与导出按钮同口径。
  Widget _buildHealthCheckExtra(IspStudioState state) {
    final running = state.healthCheckRunning.contains(node.id);
    final extra = state.previewExtraHeight(node.id);
    return SizedBox(
      height: extra,
      child: Column(
        children: [
          if (running)
            _buildExportButton(state, '停止检查',
                () => state.stopHealthCheck(node.id),
                backgroundColor: const Color(0xFF8C2B2B))
          else
            _buildExportButton(
                state, '开始检查', () => state.runHealthCheck(node.id)),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 3),
            child: ValueListenableBuilder<int>(
              valueListenable: state.healthCheckTick,
              builder: (context, tick, child) => _FormatConvertConsole(
                  log: state.healthCheckLogs[node.id] ?? '',
                  height: math.max(0.0, extra - 37),
                  hint: '点击「开始检查」，报告将在此显示'),
            ),
          ),
        ],
      ),
    );
  }
}

/// 内嵌终端面板（格式转换 / 视频健康检查节点共用）：黑底等宽字体、
/// 自动滚到底。日志经 tick 信号驱动重建（局部刷新，不触发整树
/// notifyListeners）。
class _FormatConvertConsole extends StatefulWidget {
  final String log;
  final double height;

  /// 空日志时的占位提示。
  final String hint;

  const _FormatConvertConsole(
      {required this.log,
      required this.height,
      this.hint = '点击「开始转换」，输出将在此显示'});

  @override
  State<_FormatConvertConsole> createState() => _FormatConvertConsoleState();
}

class _FormatConvertConsoleState extends State<_FormatConvertConsole> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 日志追加驱动重建：每次重建后滚到底（参照 CodeCompileArea
    // 的 postFrame jumpTo maxScrollExtent）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
    return Container(
      height: widget.height,
      decoration: BoxDecoration(
        color: const Color(0xFF151515),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.grey.shade800),
      ),
      child: widget.log.isEmpty
          ? Center(
              child: Text(widget.hint,
                  style:
                      const TextStyle(fontSize: 14.25, color: Colors.grey)))
          : SingleChildScrollView(
              controller: _scroll,
              padding: const EdgeInsets.all(4),
              child: SizedBox(
                width: double.infinity,
                child: SelectableText(
                  widget.log,
                  style: const TextStyle(
                    fontFamily: 'Consolas',
                    fontFamilyFallback: ['monospace'],
                    fontSize: 14.25,
                    color: Color(0xFFB0C0B0),
                  ),
                ),
              ),
            ),
    );
  }
}

/// 播放控制条时间文本：当前时间/总时长（hh:mm:ss/hh:mm:ss），按
/// [IspStudioState.playbackSrcFps] 换算（视频源单次预览运行与播放时
/// 都会填入）。预览控制条与视频源节点时间行共用。
String playbackTimeText(IspStudioState state, int total) {
  String fmt(double sec) {
    final s = sec.isFinite && sec > 0 ? sec.floor() : 0;
    return '${(s ~/ 3600).toString().padLeft(2, '0')}:'
        '${((s % 3600) ~/ 60).toString().padLeft(2, '0')}:'
        '${(s % 60).toString().padLeft(2, '0')}';
  }

  final fps = state.playbackSrcFps;
  return '${fmt(state.previewFrame / fps)}/${fmt(total / fps)}';
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

/// 矢量示波器坐标格（参照经典矢量示波器面板）：最外圈 8px 色环、外圈刻度环、
/// U/V 轴、75%/100% 六色目标框、双三角连线（Mg-Yl-Cy / R-G-B）与色标文字。
/// 数据坐标：x = Cb（0 左 255 右），y = Cr（0 下 255 上），中心 (128,128)。
/// [hover] 为鼠标悬停位置（画布局部坐标），非空时在光标处绘制采样标记和
/// HSL 气泡：H 为 (Cb,Cr) 方向对应的色相，S 为径向距离占该色相 100% 饱和
/// 色色度半径的百分比，L 为参考亮度 50%（矢量示波器无亮度信息）。
class VectorscopeGraticule extends CustomPainter {
  const VectorscopeGraticule({this.hover});

  final Offset? hover;

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

    // 最外圈 8px 色环（贴画布边缘）：色相随 (Cb,Cr) 平面实际角度排布，
    // 对饱和色用 BT.601 反推其在屏幕上的角度，逐 0.5° 色相画弧段。
    final half = math.min(size.width, size.height) / 2;
    const colorRingWidth = 8.0;
    final ringRect = Rect.fromCircle(
        center: center, radius: half - 1 - colorRingWidth / 2);
    for (var h = 0.0; h < 360; h += 0.5) {
      final c = HSVColor.fromAHSV(1, h, 1, 1).toColor();
      final r = c.r * 255, g = c.g * 255, b = c.b * 255;
      final y = 0.299 * r + 0.587 * g + 0.114 * b;
      final cb = 128 + 0.564 * (b - y);
      final cr = 128 + 0.713 * (r - y);
      final a = math.atan2(-(cr - 128), cb - 128);
      canvas.drawArc(
          ringRect,
          a,
          0.035,
          false,
          Paint()
            ..color = c
            ..style = PaintingStyle.stroke
            ..strokeWidth = colorRingWidth);
    }

    // 外圈 + 刻度环（2° 小刻度，10° 长刻度，朝内）。
    // 半径贴在色环内侧（留 2px 间隙）；512px 画布时约等于原 150 单位，
    // 100% 彩条目标点（径向约 130-135）落在环内侧。
    final ringRadius = half - colorRingWidth - 3;
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

    // 鼠标悬停：采样点标记 + HSL 气泡
    final h = hover;
    if (h != null) _drawHoverBubble(canvas, size, center, ds, h);
  }

  /// 色相 h（0-360）的 100% 饱和色在 (Cb,Cr) 平面相对中心的偏移。
  static (double, double) chromaOfHue(double h) {
    // 色相环绕归一：H+ΔH 可能越出 0..360（HSVColor 断言 hue >= 0），
    // 负值与超界都按色环折回。
    final c = HSVColor.fromAHSV(1, ((h % 360) + 360) % 360, 1, 1).toColor();
    final r = c.r * 255, g = c.g * 255, b = c.b * 255;
    final y = 0.299 * r + 0.587 * g + 0.114 * b;
    return (0.564 * (b - y), 0.713 * (r - y));
  }

  /// 反查 (du,dv) 方向对应的色相：整数度粗扫 + 三分法细化。
  static double hueForDirection(double du, double dv) {
    final target = math.atan2(dv, du);
    double diff(double h) {
      final (u, v) = chromaOfHue(h % 360);
      var d = math.atan2(v, u) - target;
      while (d > math.pi) {
        d -= 2 * math.pi;
      }
      while (d < -math.pi) {
        d += 2 * math.pi;
      }
      return d.abs();
    }

    var best = 0.0;
    var bestD = double.infinity;
    for (var h = 0.0; h < 360; h += 1) {
      final d = diff(h);
      if (d < bestD) {
        bestD = d;
        best = h;
      }
    }
    var lo = best - 1, hi = best + 1;
    for (var i = 0; i < 8; i++) {
      final m1 = lo + (hi - lo) / 3, m2 = hi - (hi - lo) / 3;
      if (diff(m1) < diff(m2)) {
        hi = m2;
      } else {
        lo = m1;
      }
    }
    return ((lo + hi) / 2) % 360;
  }

  void _drawHoverBubble(
      Canvas canvas, Size size, Offset center, double ds, Offset pos) {
    final du = (pos.dx - center.dx) / ds;
    final dv = -(pos.dy - center.dy) / ds;
    final dist = math.sqrt(du * du + dv * dv);
    final hue = dist < 1e-6 ? 0.0 : hueForDirection(du, dv);
    final (mu, mv) = chromaOfHue(hue);
    final maxR = math.sqrt(mu * mu + mv * mv);
    final sat = maxR > 0 ? dist / maxR * 100 : 0.0;
    final swatchColor = HSLColor.fromAHSL(
            1, hue, (sat / 100).clamp(0.0, 1.0), 0.5)
        .toColor();

    // 采样点标记
    canvas.drawCircle(
        pos,
        4,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2);

    final tp = TextPainter(
      text: TextSpan(
          text: 'H ${hue.round()}°  S ${sat.round()}%  L 50%',
          style: const TextStyle(fontSize: 10, color: Colors.white)),
      textDirection: TextDirection.ltr,
    )..layout();

    const swatch = 10.0, pad = 5.0, gap = 5.0;
    final w = pad + swatch + gap + tp.width + pad;
    final h = tp.height + pad * 2;
    // 默认放在光标右上方，越界则换侧并夹进画布
    var bx = pos.dx + 12;
    var by = pos.dy - 12 - h;
    if (bx + w > size.width - 1) bx = pos.dx - 12 - w;
    if (by < 1) by = pos.dy + 12;
    bx = bx.clamp(1.0, math.max(1.0, size.width - 1 - w));
    by = by.clamp(1.0, math.max(1.0, size.height - 1 - h));

    final rect = Rect.fromLTWH(bx, by, w, h);
    const radius = Radius.circular(3);
    canvas.drawRRect(RRect.fromRectAndRadius(rect, radius),
        Paint()..color = const Color(0xD9000000));
    canvas.drawRRect(
        RRect.fromRectAndRadius(rect, radius),
        Paint()
          ..color = const Color(0x99FFFFFF)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.8);
    final swatchRect = Rect.fromLTWH(bx + pad, by + (h - swatch) / 2, swatch, swatch);
    canvas.drawRect(swatchRect, Paint()..color = swatchColor);
    canvas.drawRect(
        swatchRect,
        Paint()
          ..color = const Color(0x99FFFFFF)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.8);
    tp.paint(canvas, Offset(bx + pad + swatch + gap, by + pad));
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
  bool shouldRepaint(VectorscopeGraticule old) => old.hover != hover;
}

/// 色彩控制器的高斯色相带叠加层（画在迹线与坐标格之间）。
/// 以 [centerDeg] 为带中心：每个屏幕角度经色相 LUT 反查 HSL 色相，按
/// w = exp(-(Δ/σ)²/2) 决定扇形不透明度（σ = 45°/q，Q 越高带越窄，左右
/// 边带正态衰减），扇形颜色取该角度的饱和色；带中心标线颜色为
/// [centerColor]（默认白），[referenceDeg] 非空时另画一条白色静态参考标线。
/// 调整前半区传 H 中心；调整后半区带中心传 H+ΔH（黄线），参考线传 H（白线）。
class _HueBandPainter extends CustomPainter {
  final double centerDeg;
  final double q;
  final Color centerColor;
  final double? referenceDeg;

  const _HueBandPainter({
    required this.centerDeg,
    required this.q,
    this.centerColor = Colors.white,
    this.referenceDeg,
  });

  /// 屏幕角度（度，y 向下）→ HSL 色相的查询表，首次使用时惰性构建。
  static final List<double> _hueByScreenDeg = List<double>.generate(360, (deg) {
    final a = deg * math.pi / 180;
    // 屏幕方向 (cos a, sin a) 对应数据方向 (cos a, -sin a)（数据 y 向上）。
    return VectorscopeGraticule.hueForDirection(math.cos(a), -math.sin(a));
  });

  /// 色相 H（度）对应的屏幕方向角（弧度）。
  static double _screenAngleOfHue(double hDeg) {
    final (u, v) = VectorscopeGraticule.chromaOfHue(hDeg);
    return math.atan2(-v, u);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final half = math.min(size.width, size.height) / 2;
    final center = size.center(Offset.zero);
    final bandR = half - 13; // 刻度环（半径 half-11）内侧
    if (bandR <= 0) return;
    final sigma = 45.0 / q;
    final rect = Rect.fromCircle(center: center, radius: bandR);
    const step = 2.0; // 扇形步进（度）
    for (var deg = 0.0; deg < 360; deg += step) {
      final hue = _hueByScreenDeg[deg.round() % 360];
      var d = (hue - centerDeg).abs() % 360.0;
      if (d > 180) d = 360 - d;
      final w = math.exp(-0.5 * (d / sigma) * (d / sigma));
      if (w < 0.02) continue;
      final color = HSVColor.fromAHSV(w * 0.4, hue, 1.0, 1.0).toColor();
      canvas.drawArc(rect, (deg - step / 2) * math.pi / 180,
          step * math.pi / 180, true, Paint()..color = color);
    }

    void marker(double hDeg, Color color, double width) {
      final a = _screenAngleOfHue(hDeg);
      final dir = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(center + dir * (bandR * 0.25), center + dir * bandR,
          Paint()
            ..color = color
            ..strokeWidth = width);
    }

    // 静态参考标线（白，如调整后半区的原 H 位置）+ 带中心标线
    final ref = referenceDeg;
    if (ref != null) marker(ref, Colors.white, 2);
    marker(centerDeg, centerColor, 2);
  }

  @override
  bool shouldRepaint(_HueBandPainter old) =>
      old.centerDeg != centerDeg ||
      old.q != q ||
      old.centerColor != centerColor ||
      old.referenceDeg != referenceDeg;
}

/// 矢量示波器悬停层：跟踪鼠标位置并交给 [VectorscopeGraticule] 绘制
/// 采样标记与 HSL 气泡。仪器节点与 HSL 调节器半区共用。
/// [bandPainter] 非空时作为中间叠加层（画在迹线与坐标格之间），
/// 色彩控制器用它叠加高斯色相带。
class _VectorscopeHoverRegion extends StatefulWidget {
  final Widget child;
  final CustomPainter? bandPainter;

  const _VectorscopeHoverRegion({required this.child, this.bandPainter});

  @override
  State<_VectorscopeHoverRegion> createState() =>
      _VectorscopeHoverRegionState();
}

class _VectorscopeHoverRegionState extends State<_VectorscopeHoverRegion> {
  Offset? _hover;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onHover: (e) => setState(() => _hover = e.localPosition),
      onExit: (_) => setState(() => _hover = null),
      child: CustomPaint(
        foregroundPainter: VectorscopeGraticule(hover: _hover),
        child: widget.bandPainter == null
            ? widget.child
            : CustomPaint(
                foregroundPainter: widget.bandPainter, child: widget.child),
      ),
    );
  }
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
      ..setFloat(8, frame.matrix.toDouble())
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

/// 多段色彩均衡器附加区（有状态：取色/删除模式与取样像素缓存）：
/// 双联矢量示波器行 + 取色器工具栏（增/删 │ 预设占位按钮 │ 段按钮列，
/// 位于示波器与预览区之间）+ 前后双联预览（左调整前/右调整后，取色
/// 模式下左区十字光标点击取色）+ 选中段 H中心/Q/ΔH/S/L 五行控制条 +
/// 播放控制条（播放/暂停 + 帧进度滑条，与预览节点附加区同款）+
/// 底部拖动手柄。
/// 图刷新走 [IspStudioState.frameTick]；滑块拖动实时重跑（同色彩控制器）。
/// 取色模式：点段按钮进入（光标变十字），左预览区悬停实时计算光标像素
/// HSL——H 与自动评估的 Q（[estimateBandQ]：8 方向色相平滑段长度评估）
/// 实时叠加到调整前矢量示波器的色相线/Q 带，光标旁气泡实时显示 HSL
/// 数值，右预览区同时切换为左区 10 倍放大视图（中心=十字线像素，近
/// 边缘钳位）；点击取样把 H 与 Q 一并写入该段 b{i}_h/b{i}_q 并重跑
/// 预览；Esc 或点击预览区外退出。删除模式：点「删除」进入（再点退出），
/// 段按钮区高亮、悬停叠 ✕，点击删除该段并重排键名。
class _MultiBandEqExtra extends StatefulWidget {
  /// 宿主卡片（复用其 _buildHslSliderRow/_buildHslComparePane/_buildResizeBar
  /// 构建器，同库私有成员直接访问）。
  final IspNodeWidget host;
  final IspStudioState state;
  final IspNode node;

  const _MultiBandEqExtra(
      {required this.host, required this.state, required this.node});

  @override
  State<_MultiBandEqExtra> createState() => _MultiBandEqExtraState();
}

class _MultiBandEqExtraState extends State<_MultiBandEqExtra> {
  /// 取色模式中的段号（null=未取色）；进入时该段同时置为选中段。
  int? _armedBand;

  /// 取色悬停时右区放大预览的倍率（工具栏 X2/X4/X6/X8/X10 互斥组，
  /// 默认 X6）。
  int _magZoom = 6;

  /// comp 对比模式：隐藏双联示波器/取色器工具栏/调整后预览，调整前
  /// 预览充满这些位置，顶部换为 comp 工具栏（comp 按住看调整后 +
  /// 恢复退出）。[_compHold] = comp 按钮按住中。
  bool _compMode = false;
  bool _compHold = false;

  /// ALL 视图：双联矢量示波器叠加全部段的色相线/色带（按段色着色）。
  bool _allView = false;

  /// 双联矢量示波器迹线（绿色线）显示开关（右上角按钮切换，隐藏时
  /// 保留黑底 + 坐标格 + 色带叠加）。
  bool _showLeftTrace = true;
  bool _showRightTrace = true;

  /// 删除模式：段按钮区高亮描边，点击按钮删除该段。
  bool _deleteArmed = false;

  /// 删除模式下悬停的段按钮（叠 ✕ 角标）。
  int? _hoverDeleteBand;

  /// 各段最近一次取样像素的颜色（取色后染到段按钮背景；仅会话内记忆，
  /// 不落参数——预设/存档恢复后按钮回到默认底色）。
  final Map<int, Color> _bandColors = {};

  /// 左预览区（调整前）取色悬停位置（窗格坐标，画十字线）。
  Offset? _pickHover;

  /// 悬停实时取色：最近计算的图像像素坐标（去重，像素不变不重算）。
  Offset? _hoverPixel;

  /// 悬停像素的实时色相（°）、饱和度/亮度（0..1）与自动评估 Q
  /// （H/Q 实时叠加到调整前示波器，HSL 同时显示在悬停气泡）。
  double? _hoverHueDeg;
  double? _hoverS;
  double? _hoverL;
  double? _hoverQ;

  /// 惰性缓存的调整前图像像素（进入取色后首次点击时 toByteData 一次，
  /// 图像对象变化时重取）。
  ui.Image? _pickImage;
  ByteData? _pickPixels;

  bool _escHandlerOn = false;

  IspStudioState get state => widget.state;
  IspNode get node => widget.node;

  /// 段数（缺省 1，钳位 1..kMultiBandEqMaxBands）。
  int get _bandCount {
    final v = (node.paramValues['band_count'] as num?)?.toInt() ?? 1;
    return v.clamp(1, kMultiBandEqMaxBands).toInt();
  }

  /// 选中段（钳位到现有段范围）。
  int get _selBand {
    final v = (node.paramValues['sel_band'] as num?)?.toInt() ?? 0;
    return v.clamp(0, _bandCount - 1).toInt();
  }

  @override
  void dispose() {
    _removeEscHandler();
    super.dispose();
  }

  // ---- Esc 退出取色/删除模式（全局键盘钩子，仅在两种模式之一激活时挂载）----

  bool _onKey(KeyEvent e) {
    if (_armedBand == null && !_deleteArmed) return false;
    if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape) {
      setState(() {
        _armedBand = null;
        _deleteArmed = false;
        _pickHover = null;
        _hoverDeleteBand = null;
        _clearHoverHsl();
      });
      _removeEscHandler();
      return true;
    }
    return false;
  }

  void _addEscHandler() {
    if (_escHandlerOn) return;
    HardwareKeyboard.instance.addHandler(_onKey);
    _escHandlerOn = true;
  }

  void _removeEscHandler() {
    if (!_escHandlerOn) return;
    HardwareKeyboard.instance.removeHandler(_onKey);
    _escHandlerOn = false;
  }

  // ---- 模式切换与段管理 ----

  /// 点段按钮：删除模式下删除该段；再点取色中的段退出取色；否则选中
  /// 该段并进入取色模式。
  void _tapBand(int i) {
    if (_deleteArmed) {
      _deleteBand(i);
      return;
    }
    if (_armedBand == i) {
      _disarmPick();
      return;
    }
    state.setParam(node.id, 'sel_band', i);
    setState(() => _armedBand = i);
    _addEscHandler();
    // 预加载取色像素缓存，悬停实时取色不必等首次点击。
    final image = state.previewInputImages[node.id];
    if (image != null) _ensurePickPixels(image);
  }

  void _disarmPick() {
    setState(() {
      _armedBand = null;
      _pickHover = null;
      _clearHoverHsl();
    });
    if (!_deleteArmed) _removeEscHandler();
  }

  /// 增加取色器：段数 +1（新段不落参数键，读取侧缺省即恒等默认），
  /// 自动选中新段并直接进入取色模式（与点段按钮一致，便于立即取样）；
  /// 段结果不变（新段恒等），不重跑预览。
  void _addBand() {
    final count = _bandCount;
    if (count >= kMultiBandEqMaxBands) return;
    state.setParam(node.id, 'band_count', count + 1);
    state.setParam(node.id, 'sel_band', count);
    setState(() {
      _armedBand = count;
      // 取色与删除互斥：删除模式中新建时退出删除模式。
      _deleteArmed = false;
      _hoverDeleteBand = null;
    });
    _addEscHandler();
    // 预加载取色像素缓存，悬停实时取色不必等首次点击。
    final image = state.previewInputImages[node.id];
    if (image != null) _ensurePickPixels(image);
  }

  void _toggleDelete() {
    setState(() {
      _deleteArmed = !_deleteArmed;
      _hoverDeleteBand = null;
      if (_deleteArmed) {
        // 删除与取色互斥：进入删除模式退出取色。
        _armedBand = null;
        _pickHover = null;
        _clearHoverHsl();
      }
    });
    if (_deleteArmed) {
      _addEscHandler();
    } else if (_armedBand == null) {
      _removeEscHandler();
    }
  }

  /// 删除第 [i] 段：键名前移重排（[reindexBandParams]），删除后重跑预览。
  void _deleteBand(int i) {
    final count = _bandCount;
    if (count <= 1) return;
    final next = reindexBandParams(node.paramValues, i, count);
    // 差异键一次性批量写入（被清除的键写 null，读取侧缺省回退恒等默认）。
    final patch = <String, Object?>{};
    final keys = {...node.paramValues.keys, ...next.keys};
    for (final k in keys) {
      if (node.paramValues[k] != next[k]) patch[k] = next[k];
    }
    state.setParams(node.id, patch);
    setState(() {
      if (_armedBand == i) _armedBand = null;
      // 删除后光标位置不动：后段前移，原位置变成第 i 段（段按钮无 key
      // 按位置复用元素，且被删按钮的 MouseRegion 卸载会触发 onExit，
      // 因此悬停标记必须在这里显式重指——否则要动一下鼠标 X 遮罩才
      // 出现在新到该位置的段上）。删除的是末段时原位置已无按钮。
      _hoverDeleteBand = i < count - 1 ? i : null;
      // 剩 1 段时退出删除模式（按钮随即置灰）。
      if (count - 1 <= 1) _deleteArmed = false;
      // 段按钮颜色同步前移重排（与 reindexBandParams 同口径）。
      final colors = Map<int, Color>.of(_bandColors);
      _bandColors.clear();
      for (var k = 0; k < count - 1; k++) {
        final c = colors[k < i ? k : k + 1];
        if (c != null) _bandColors[k] = c;
      }
    });
    if (_armedBand == null && !_deleteArmed) _removeEscHandler();
    state.runPreview();
  }

  // ---- 取色 ----

  /// 窗格坐标经 contain 适配换算为图像像素坐标；落在图像外的黑边区
  /// 或窗格尺寸无效时返回 null（悬停与点击取样共用）。
  Offset? _pixelAt(Offset local, Size paneSize, ui.Image image) {
    if (paneSize.width <= 0 || paneSize.height <= 0) return null;
    final scale =
        math.min(paneSize.width / image.width, paneSize.height / image.height);
    final ox = (paneSize.width - image.width * scale) / 2;
    final oy = (paneSize.height - image.height * scale) / 2;
    final px = ((local.dx - ox) / scale).floor();
    final py = ((local.dy - oy) / scale).floor();
    if (px < 0 || py < 0 || px >= image.width || py >= image.height) {
      return null;
    }
    return Offset(px.toDouble(), py.toDouble());
  }

  /// 取色像素缓存是否正在加载（防并发重复 toByteData）。
  bool _pickLoading = false;

  /// 惰性加载 [image] 的 RGBA8 像素缓存（图像对象变化时重取；图像已被
  /// 预览系统置换 dispose 时 toByteData 返回 null/抛错——不缓存失败
  /// 结果，留待后续悬停重试）。
  Future<ByteData?> _ensurePickPixels(ui.Image image) async {
    if (!identical(_pickImage, image) || _pickPixels == null) {
      final ByteData? data;
      try {
        data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      } catch (_) {
        return null;
      }
      if (data == null) return null;
      _pickPixels = data;
      _pickImage = image;
    }
    return _pickPixels;
  }

  /// 清除悬停实时取色结果（十字线坐标 [_pickHover] 由调用方另行处理）。
  void _clearHoverHsl() {
    _hoverPixel = null;
    _hoverHueDeg = null;
    _hoverS = null;
    _hoverL = null;
    _hoverQ = null;
  }

  /// 取色模式悬停：更新十字线；像素坐标变化且像素缓存就绪时实时计算
  /// 光标像素 HSL——H 与 [estimateBandQ] 自动评估的 Q 实时叠加到
  /// 调整前矢量示波器的色相线/Q 带。
  void _updateHover(Offset local, Size paneSize) {
    final image = state.previewInputImages[node.id];
    if (image == null) {
      setState(() {
        _pickHover = local;
        _clearHoverHsl();
      });
      return;
    }
    final p = _pixelAt(local, paneSize, image);
    // 界外黑边区：清实时取色结果，只保留十字线。
    if (p == null) {
      setState(() {
        _pickHover = local;
        _clearHoverHsl();
      });
      return;
    }
    // 像素坐标未变（像素内微动）：只画十字线。
    if (p == _hoverPixel) {
      setState(() => _pickHover = local);
      return;
    }
    final bytes = identical(_pickImage, image) ? _pickPixels : null;
    if (bytes == null) {
      // 缓存未就绪或图像已被预览重建置换：只画十字线，异步加载完成后
      // 按当前悬停位置补算一次。
      setState(() => _pickHover = local);
      if (!_pickLoading) {
        _pickLoading = true;
        _ensurePickPixels(image).then((data) {
          _pickLoading = false;
          if (!mounted || _armedBand == null || data == null) return;
          if (!identical(state.previewInputImages[node.id], image)) return;
          final h = _pickHover;
          if (h != null) _updateHover(h, paneSize);
        });
      }
      return;
    }
    final px = p.dx.toInt();
    final py = p.dy.toInt();
    final off = (py * image.width + px) * 4;
    // 预览图为 RGBA8，对应 maxValue=255 的管线量化口径。
    final hsl = rgbToHsl(
        Uint16List.fromList([
          bytes.getUint8(off),
          bytes.getUint8(off + 1),
          bytes.getUint8(off + 2)
        ]),
        maxValue: 255);
    final hDeg = hsl[0] * 360.0 / 255;
    final q = estimateBandQ(bytes, image.width, image.height, px, py);
    setState(() {
      _pickHover = local;
      _hoverPixel = p;
      _hoverHueDeg = hDeg;
      _hoverS = hsl[1] / 255;
      _hoverL = hsl[2] / 255;
      _hoverQ = q;
    });
  }

  /// 左预览区点击取色：取样像素 RGB 经管线同款 RGB→HSL 转换得色相（°），
  /// 连同 [estimateBandQ] 自动评估的 Q 一并写入取色段的 b{i}_h/b{i}_q
  /// 并重跑预览。
  Future<void> _pickAt(Offset local, Size paneSize) async {
    final band = _armedBand;
    if (band == null) return;
    final image = state.previewInputImages[node.id];
    if (image == null) return;
    // 点在图像外的黑边区：忽略。
    final p = _pixelAt(local, paneSize, image);
    if (p == null) return;
    final px = p.dx.toInt();
    final py = p.dy.toInt();
    final bytes = await _ensurePickPixels(image);
    if (!mounted || _armedBand != band) return;
    if (bytes == null) return;
    final off = (py * image.width + px) * 4;
    // 预览图为 RGBA8，对应 maxValue=255 的管线量化口径。
    final hsl = rgbToHsl(
        Uint16List.fromList([
          bytes.getUint8(off),
          bytes.getUint8(off + 1),
          bytes.getUint8(off + 2)
        ]),
        maxValue: 255);
    final hDeg = hsl[0] * 360.0 / 255;
    final qEst = estimateBandQ(bytes, image.width, image.height, px, py);
    // 取样像素的 HSL 颜色染到对应段按钮背景。
    setState(() => _bandColors[band] = HSLColor.fromAHSL(1.0, hDeg,
            (hsl[1] / 255).clamp(0.0, 1.0), (hsl[2] / 255).clamp(0.0, 1.0))
        .toColor());
    state.setParams(node.id, {'b${band}_h': hDeg, 'b${band}_q': qEst});
    state.runPreview();
  }

  // ---- 色彩风格预设存取（.colorstyle，JSON 文本）----

  /// 预设文件类型（与 .ispflow 同一约定）。
  static const _styleTypeGroup =
      XTypeGroup(label: '色彩风格', extensions: ['colorstyle']);

  /// 预设的默认目录（IspFlow/ColorStyle，不存在则创建）。
  /// 注意：必须使用平台分隔符拼接（仿 isp_studio_view._flowDir() 的坑：
  /// Windows 上混用 '/' 会使 file_selector 静默回退到「上次使用的目录」）。
  Future<Directory> _colorStyleDir() async {
    final dir = Directory(
        '${Directory.current.path}${Platform.pathSeparator}IspFlow'
        '${Platform.pathSeparator}ColorStyle');
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir;
  }

  /// 保存当前段配置为 .colorstyle（缺键按恒等默认补齐写出，文件自足）。
  Future<void> _saveStyle() async {
    final dir = await _colorStyleDir();
    if (!mounted) return;
    final loc = await getSaveLocation(
      suggestedName: '未命名风格.colorstyle',
      acceptedTypeGroups: [_styleTypeGroup],
      initialDirectory: dir.path,
    );
    if (loc == null) return; // 用户取消
    try {
      final json = const JsonEncoder.withIndent('  ')
          .convert(encodeColorStyle(node.paramValues));
      // 用户未键入扩展名时补上（保存对话框不保证自动追加）。
      final path = loc.path.toLowerCase().endsWith('.colorstyle')
          ? loc.path
          : '${loc.path}.colorstyle';
      await File(path).writeAsString(json);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content:
              Text('已保存色彩风格：${path.split(Platform.pathSeparator).last}'),
          duration: const Duration(seconds: 2)));
    } catch (e) {
      if (!mounted) return;
      await _showStyleError('保存色彩风格失败', '$e');
    }
  }

  /// 读取 .colorstyle 恢复段序列：解析校验（版本/段数/结构，数值越界
  /// clamp）→ setParams 批量恢复（多余旧段键写 null 清除）→ 重跑预览。
  Future<void> _loadStyle() async {
    final dir = await _colorStyleDir();
    if (!mounted) return;
    final file = await openFile(
      acceptedTypeGroups: [_styleTypeGroup],
      initialDirectory: dir.path,
    );
    if (file == null) return; // 用户取消
    final Map<String, Object?> patch;
    try {
      patch = decodeColorStyle(await file.readAsString(),
          oldBandCount: _bandCount);
    } on FormatException catch (e) {
      await _showStyleError('无法读取色彩风格预设', e.message);
      return;
    } catch (e) {
      await _showStyleError('无法读取色彩风格预设', '$e');
      return;
    }
    state.setParams(node.id, patch);
    // 标题栏追加「（风格文件名）」标注（须在 setParams 之后写入，
    // 避免被批量写的清除逻辑抹掉；配置后续调整即自动清除）。
    state.setParam(node.id, 'style_name', file.name);
    // 段序列被替换：退出取色/删除模式（sel_band 已由补丁回 0）。
    setState(() {
      _armedBand = null;
      _deleteArmed = false;
      _pickHover = null;
      _hoverDeleteBand = null;
      _bandColors.clear();
      _clearHoverHsl();
    });
    _removeEscHandler();
    state.runPreview();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('已读取色彩风格：${file.name}'
            '（${patch['band_count']} 段，'
            '${patch['band_mode'] == 'serial' ? '串联' : '并联'}）'),
        duration: const Duration(seconds: 2)));
  }

  /// 预设错误对话框（风格仿 ensureGroupCExportable 的 AlertDialog）。
  Future<void> _showStyleError(String title, String message) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2E2E2E),
        title: Text(title,
            style: const TextStyle(color: Colors.white, fontSize: 14)),
        content: Text(message,
            style: const TextStyle(color: Colors.white70, fontSize: 12)),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('知道了')),
        ],
      ),
    );
  }

  // ---- 构建 ----

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: state.frameTick,
      builder: (context, tick, child) => _buildContent(),
    );
  }

  Widget _buildContent() {
    final host = widget.host;
    final image = state.previewImages[node.id];
    final inputImage = state.previewInputImages[node.id];
    final hasInput = state.graph.connectionAt(node.id, 'in') != null;
    final extra = state.previewExtraHeight(node.id);
    final sel = _selBand;
    final scope = state.hslVectorscopes[node.id];
    final inputScope = state.hslInputVectorscopes[node.id];
    // 当前选中段的色相带参数（叠加到矢量示波器上，同色彩控制器）。
    final hCenter = (node.paramValues['b${sel}_h'] as num?)?.toDouble() ?? 0;
    final q = (node.paramValues['b${sel}_q'] as num?)?.toDouble() ?? 2;
    final dh = (node.paramValues['b${sel}_dh'] as num?)?.toDouble() ?? 0;
    // 播放中矢量示波器冻结不刷新，停播时以最后一帧补齐；
    // 取色悬停实时叠加在播放中同样可用。
    // 取色悬停实时值优先：悬停时调整前示波器的色相线/Q 带跟随光标像素。
    final hoverLive = _armedBand != null && _hoverHueDeg != null;
    final leftH = hoverLive ? _hoverHueDeg! : hCenter;
    final leftQ = hoverLive ? (_hoverQ ?? q) : q;
    // ALL 视图叠加层：两半区都画各段的 Q 高斯色带 + 中心色相标线——
    // 调整前以原 H 为中心、按段色着色；调整后以 H+ΔH 为中心、按移位后
    // 色相着色（已取色段保持取样颜色的饱和度/亮度仅移色相；未取色段
    // 用移位后色相的纯色：全饱和、55% 亮度）。
    CustomPainter? leftOverride;
    CustomPainter? rightOverride;
    if (_allView) {
      final before = <(double, double, Color, Color?, String)>[];
      final after = <(double, double, Color, Color?, String)>[];
      for (var i = 0; i < _bandCount; i++) {
        final h = (node.paramValues['b${i}_h'] as num?)?.toDouble() ?? 0;
        final bq = (node.paramValues['b${i}_q'] as num?)?.toDouble() ?? 2;
        final bd = (node.paramValues['b${i}_dh'] as num?)?.toDouble() ?? 0;
        final picked = _bandColors[i];
        final c = picked ??
            HSLColor.fromAHSL(1.0, h, 1.0, 0.55).toColor();
        final shiftedH = ((h + bd) % 360 + 360) % 360;
        final cAfter = (picked != null
                ? HSLColor.fromColor(picked).withHue(shiftedH)
                : HSLColor.fromAHSL(1.0, shiftedH, 1.0, 0.55))
            .toColor();
        before.add((h, bq, c, null, '${i + 1}'));
        // 圆心段传原始色相颜色：调整后的标线分两段（圆心段原色 /
        // 外圈段移位后色），呈现移位前后对比。
        after.add((h + bd, bq, cAfter, c, '${i + 1}'));
      }
      leftOverride = _AllBandsPainter(bands: before);
      rightOverride = _AllBandsPainter(bands: after);
    }
    // 示波器行顶部留白 4 + 取色器工具栏 64 + 预览行间隔 4 + 5 行滑块
    // 各 24 + 播放控制条 26（节点尺寸锁定 1920x1770，无底部手柄行）。
    // 示波器格保持 1:1（矢量示波器为圆形，格高 = 半格宽，与
    // _displayAspect/_displayChrome 的口径一致），其余高度归预览图行。
    final scopeHeight = math.min((node.width - 20) / 2,
        math.max(0.0, extra - 4 - 64 - 4 - 24 * 5 - 26));
    final imageHeight = math.max(
        0.0, extra - 4 - 64 - 4 - 24 * 5 - 26 - scopeHeight);
    return SizedBox(
      height: extra,
      // 点击工具栏/右预览/滑条背景等空白处退出取色模式（左预览与按钮
      // 等内部手势优先，不触发本回调）。
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () {
          if (_armedBand != null) _disarmPick();
        },
        child: Column(
          children: [
            if (!_compMode) ...[
            // 双联矢量示波器行（左调整前/右调整后），位于预览图上方，
            // 与 color_controller 同一统计口径（vectorscope 仪器）。
            // 左格叠加选中段的 H 中心线 + Q 高斯带（白色标线）；右格叠加
            // ΔH 移位后的中心线 + Q 带（黄色标线），另有白色静态参考线
            // 指回原 H 位置便于对比——均与色彩控制器同款叠加。
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
              child: SizedBox(
                height: scopeHeight,
                child: Row(
                  children: [
                    // AspectRatio 居中约束：高度不足示波器格收缩时，
                    // 黑框仍保持 1:1（正常情况格宽==格高，布局不变）。
                    Expanded(
                        child: Center(
                            child: AspectRatio(
                                aspectRatio: 1,
                                child: host._buildBandScopePane(
                                    inputScope,
                                    '调整前',
                                    hasInput ? '运行预览后显示' : '未连接输入',
                                    leftH,
                                    leftQ,
                                    overridePainter: leftOverride,
                                    showTrace: _showLeftTrace,
                                    onToggleTrace: (v) => setState(
                                        () => _showLeftTrace = v))))),
                    const SizedBox(width: 4),
                    Expanded(
                        child: Center(
                            child: AspectRatio(
                                aspectRatio: 1,
                                child: host._buildBandScopePane(
                                    scope, '调整后', '运行预览后显示',
                                    hCenter + dh, q,
                                    referenceDeg: hCenter,
                                    centerColor: const Color(0xFFF5F543),
                                    overridePainter: rightOverride,
                                    showTrace: _showRightTrace,
                                    onToggleTrace: (v) => setState(
                                        () => _showRightTrace = v))))),
                  ],
                ),
              ),
            ),
            // 取色器工具栏位于示波器与预览区之间（取色按钮紧邻左预览区，
            // 进入取色后视线/光标路径最短）。
            _buildToolbar(),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
              child: SizedBox(
                height: imageHeight,
                child: Row(
                  children: [
                    // 左半：调整前（输入链出图），取色模式下可点击取样；
                    // 右半：调整后（输出链出图）；取色悬停时切换为左区
                    // 放大视图（倍率见工具栏 X2~X10 互斥组，中心 = 左区
                    // 十字线像素，近边缘钳位）。
                    Expanded(
                        child: _buildInputPane(inputImage,
                            hasInput ? '运行预览后显示' : '未连接输入')),
                    const SizedBox(width: 4),
                    Expanded(
                      child: _armedBand != null &&
                              _hoverPixel != null &&
                              inputImage != null
                          ? _buildMagnifierPane(inputImage)
                          : host._buildHslComparePane(
                              image, '调整后', '运行预览后显示效果'),
                    ),
                  ],
                ),
              ),
            ),
            ] else ...[
              // comp 对比模式：示波器/取色器工具栏/调整后预览隐藏，
              // 预览充满这些位置（comp 工具栏与原工具栏同高 64，
              // 预览高 = 示波器行 + 原预览行 + 间隔 4）。
              _buildCompToolbar(),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                child: SizedBox(
                  height: scopeHeight + 4 + imageHeight,
                  child: _compHold
                      // 按住 comp：显示调整后；释放：调整前。
                      ? host._buildHslComparePane(
                          image, '调整后', '运行预览后显示效果')
                      : _buildInputPane(inputImage,
                          hasInput ? '运行预览后显示' : '未连接输入'),
                ),
              ),
            ],
            host._buildHslSliderRow(state, 'H中心', 'b${sel}_h', 0, 360, 0,
                (v) => '${v.toStringAsFixed(0)}°',
                labelWidth: 34, livePreview: true),
            host._buildHslSliderRow(state, 'Q', 'b${sel}_q', 0.5, 100, 2,
                // 右侧同时显示高斯带宽 σ = 45°/Q
                (v) =>
                    '${v.toStringAsFixed(1)} σ=${(45 / v).toStringAsFixed(1)}°',
                labelWidth: 34, valueWidth: 92, livePreview: true),
            host._buildHslSliderRow(state, 'ΔH', 'b${sel}_dh', -180, 180, 0,
                (v) => '${v >= 0 ? '+' : ''}${v.toStringAsFixed(1)}°',
                labelWidth: 34, livePreview: true),
            host._buildHslSliderRow(state, 'S', 'b${sel}_s', 0, 5, 1,
                (v) => '×${v.toStringAsFixed(2)}',
                labelWidth: 34, livePreview: true),
            host._buildHslSliderRow(state, 'L', 'b${sel}_l', 0, 5, 1,
                (v) => '×${v.toStringAsFixed(2)}',
                labelWidth: 34, livePreview: true),
            // 播放控制条（与预览节点附加区同款）：播放/暂停 + 帧进度
            // 滑条（播放中禁拖；暂停时拖动定位、松手重跑预览）。
            _buildPlaybackBar(),
            // 节点尺寸锁定（1920x1770），无底部拖动手柄。
          ],
        ),
      ),
    );
  }

  /// 播放控制条（样式与预览节点附加区一致）：播放/暂停按钮 + 帧进度
  /// 滑条；多帧源（视频/图像序列，totalFrames > 1）才显示滑条。
  /// 播放/暂停与帧推进的状态刷新分别走 notifyListeners（父级节点卡片
  /// 重建）与 [IspStudioState.frameTick]（本区 ValueListenableBuilder）。
  Widget _buildPlaybackBar() {
    final total = state.totalFrames ?? 1;
    return SizedBox(
      height: 26,
      child: Row(
        children: [
          IconButton(
            icon: Icon(state.isPlaying ? Icons.pause : Icons.play_arrow,
                size: 16),
            padding: EdgeInsets.zero,
            tooltip: state.isPlaying ? '暂停' : '连续播放',
            // 导出等处理中禁用；播放中点击为暂停。
            onPressed: state.isProcessing && !state.isPlaying
                ? null
                : () => state.togglePlayback(),
          ),
          // HDR/SDR 切换（与预览节点控制条同款同逻辑）：SDR 片源只显示
          // 静态标识；HDR 片源（PQ/HLG）两段互斥——SDR=直解对比 /
          // HDR=色调映射显示（默认）。
          if (state.playbackSrcTransfer == 0)
            const Padding(
              padding: EdgeInsets.only(right: 2),
              child: Text('SDR',
                  style: TextStyle(fontSize: 10, color: Colors.grey)),
            )
          else
            widget.host._buildHdrToneMapToggle(state),
          if (total > 1)
            Expanded(
              child: SliderTheme(
                data: kIspSliderTheme,
                child: Slider(
                  value:
                      state.previewFrame.clamp(0, total - 1).toDouble(),
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
          // 进度滑条右侧：已播放时间/总时间（视频源播放时显示）。
          if (total > 1 && state.playbackSrcFps > 0)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Text(playbackTimeText(state, total),
                  style: const TextStyle(fontSize: 10, color: Colors.grey)),
            ),
        ],
      ),
    );
  }

  /// comp 模式工具栏（与取色器工具栏同规格：总高 64 = 顶部留白 4 +
  /// 内容 60，按钮 56x56、图标 48px，居中）：[comp]（释放=调整前，
  /// 按住=调整后，验证程序按住对比同款语义）+ [恢复]（退出 comp
  /// 对比模式，还原多段色彩均衡器界面）。
  Widget _buildCompToolbar() {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: SizedBox(
        height: 60,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Tooltip(
              message: '前后效果对比',
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: (_) => setState(() => _compHold = true),
                onPointerUp: (_) => setState(() => _compHold = false),
                onPointerCancel: (_) => setState(() => _compHold = false),
                child: Container(
                  width: 56,
                  height: 56,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    // 按住时高亮描边（与放大率按钮选中态同款配色）。
                    color: _compHold
                        ? const Color(0xFF4A6E8E)
                        : const Color(0xFF333333),
                    borderRadius: BorderRadius.circular(3),
                    border: Border.all(
                      color: _compHold
                          ? const Color(0xFF6A9EC0)
                          : Colors.grey.shade800,
                    ),
                  ),
                  child: Image.asset('icons/book.png', width: 48, height: 48),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: Image.asset('icons/layout-sidebar-right-dock.png',
                  width: 48, height: 48),
              constraints: const BoxConstraints.tightFor(width: 56, height: 56),
              padding: EdgeInsets.zero,
              tooltip: '退出 comp 对比模式',
              onPressed: () => setState(() {
                _compMode = false;
                _compHold = false;
              }),
            ),
          ],
        ),
      ),
    );
  }

  /// 取色器工具栏（64px，样式仿 preview 控制条）：[读取预设] [保存风格] │
  /// [+]增加 [-]删除 │ 放大率互斥组 [X2 X4 X6 X8 X10] │ [段按钮 1..n] │
  /// [comp]。按钮统一 56x56（图标 48px），内容垂直居中；顶部留白 4px
  ///（视觉居中修正——内容与上下邻区间距对称）。
  Widget _buildToolbar() {
    final count = _bandCount;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: SizedBox(
        height: 60,
      child: Row(
        children: [
          const SizedBox(width: 4),
          IconButton(
            icon: Image.asset('icons/folder-opened.png', width: 48, height: 48),
            constraints: const BoxConstraints.tightFor(width: 56, height: 56),
            padding: EdgeInsets.zero,
            tooltip: '读取预设',
            onPressed: () => _loadStyle(),
          ),
          IconButton(
            icon: Image.asset('icons/save.png', width: 48, height: 48),
            constraints: const BoxConstraints.tightFor(width: 56, height: 56),
            padding: EdgeInsets.zero,
            tooltip: '保存风格',
            onPressed: () => _saveStyle(),
          ),
          _toolbarDivider(),
          IconButton(
            icon: Image.asset('icons/diff-added.png', width: 48, height: 48),
            constraints: const BoxConstraints.tightFor(width: 56, height: 56),
            padding: EdgeInsets.zero,
            tooltip: '增加取色器',
            // 段数到上限置灰。
            onPressed:
                count >= kMultiBandEqMaxBands ? null : () => _addBand(),
          ),
          IconButton(
            // 删除模式激活时图标染红（PNG 为纯白，color 默认 srcIn 着色）。
            icon: Image.asset(
              'icons/diff-removed.png',
              width: 48,
              height: 48,
              color: _deleteArmed ? const Color(0xFFFF6E6E) : null,
            ),
            constraints: const BoxConstraints.tightFor(width: 56, height: 56),
            padding: EdgeInsets.zero,
            tooltip: _deleteArmed ? '退出删除模式' : '删除取色器',
            // 剩 1 段时置灰。
            onPressed: count <= 1 ? null : () => _toggleDelete(),
          ),
          _toolbarDivider(),
          // 放大率互斥组（取色悬停时右区放大预览的倍率）。
          for (final z in const [2, 4, 6, 8, 10]) ...[
            _buildZoomButton(z),
            if (z != 10) const SizedBox(width: 3),
          ],
          _toolbarDivider(),
          // 段按钮列：删除模式下整体红色描边高亮。段数多（上限 24）
          // 时超出部分横向滚动，不挤压工具栏图标。
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              // 行级 onExit 统一清除悬停删除标记（按钮自身的 onExit
              // 不承担——见 _buildBandButton 注释）。
              child: MouseRegion(
                onExit: (_) => setState(() => _hoverDeleteBand = null),
                child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
                decoration: _deleteArmed
                    ? BoxDecoration(
                        borderRadius: BorderRadius.circular(3),
                        border: Border.all(color: const Color(0xFFBF4040)))
                    : null,
                child: Row(
                  children: [
                    // ALL 视图：双联示波器叠加全部段的色相线/色带。
                    _buildAllButton(),
                    const SizedBox(width: 3),
                    for (var i = 0; i < count; i++) ...[
                      _buildBandButton(i),
                      if (i < count - 1) const SizedBox(width: 3),
                    ],
                  ],
                ),
                ),
              ),
            ),
          ),
          _toolbarDivider(),
          // comp 对比模式（取色器工具栏右侧）：进入后示波器/本工具栏/
          // 调整后预览隐藏，调整前预览充满，顶部换 comp 工具栏。
          IconButton(
            icon: Image.asset('icons/book.png', width: 48, height: 48),
            constraints: const BoxConstraints.tightFor(width: 56, height: 56),
            padding: EdgeInsets.zero,
            tooltip: '进入Comp对比模式',
            onPressed: () => setState(() {
              if (_armedBand != null) _disarmPick();
              _deleteArmed = false;
              _compMode = true;
              _compHold = false;
            }),
          ),
        ],
      ),
      ),
    );
  }

  /// 放大率按钮（互斥组 X2/X4/X6/X8/X10）：选中项高亮描边，点击切换
  /// 右区放大预览倍率。
  Widget _buildZoomButton(int z) {
    final sel = _magZoom == z;
    return GestureDetector(
      onTap: () => setState(() => _magZoom = z),
      child: Container(
        width: 56,
        height: 56,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: sel ? const Color(0xFF4A6E8E) : const Color(0xFF333333),
          borderRadius: BorderRadius.circular(3),
          border: Border.all(
              color: sel ? const Color(0xFF6A9EC0) : Colors.grey.shade800),
        ),
        child: Text('X$z',
            style: TextStyle(
                fontSize: 20,
                color: sel ? Colors.white : Colors.grey.shade500)),
      ),
    );
  }

  /// ALL 视图按钮（取色器组首位）：开启后双联矢量示波器叠加全部段的
  /// 色相线/色带（按段按钮取样颜色着色，未取色段用色相纯色）。
  Widget _buildAllButton() {
    return GestureDetector(
      onTap: () => setState(() => _allView = !_allView),
      child: Container(
        width: 56,
        height: 56,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color:
              _allView ? const Color(0xFF4A6E8E) : const Color(0xFF333333),
          borderRadius: BorderRadius.circular(3),
          border: Border.all(
              color: _allView
                  ? const Color(0xFF6A9EC0)
                  : Colors.grey.shade800),
        ),
        child: Text('ALL',
            style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: _allView ? Colors.white : Colors.grey.shade500)),
      ),
    );
  }

  Widget _toolbarDivider() => VerticalDivider(
      width: 9, thickness: 1, indent: 5, endIndent: 5, color: Colors.grey.shade800);

  /// 段按钮（取色器 i+1）：选中段高亮描边；取色中的段琥珀色描边；删除
  /// 模式悬停时覆盖半透明遮罩 + 对角线大叉。已取色的段以取样像素的
  /// HSL 颜色作背景，数字白字黑描边 2px（彩色底上保证可读）。
  Widget _buildBandButton(int i) {
    final sel = i == _selBand;
    final armed = _armedBand == i;
    final deleteHover = _deleteArmed && _hoverDeleteBand == i;
    final pickedColor = _bandColors[i];
    return MouseRegion(
      onEnter: (_) => setState(() => _hoverDeleteBand = i),
      // 注意：不设 onExit——按钮行整体的外层 MouseRegion 负责清除。
      // 删除段后被删按钮的 MouseRegion 卸载会误触发 onExit 把刚重指到
      // 前移段的悬停标记清空（光标其实没动）。
      child: GestureDetector(
        onTap: () => _tapBand(i),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 56,
              height: 56,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: pickedColor ??
                    (armed
                        ? const Color(0xFF6A5E2E)
                        : sel
                            ? const Color(0xFF4A6E8E)
                            : const Color(0xFF333333)),
                borderRadius: BorderRadius.circular(3),
                border: Border.all(
                    color: deleteHover
                        ? const Color(0xFFFF6E6E)
                        : armed
                            ? const Color(0xFFFFC107)
                            : sel
                                ? const Color(0xFF6A9EC0)
                                : Colors.grey.shade800),
              ),
              // 已取色：白字黑描边；未取色：沿用原配色。
              child: pickedColor != null
                  ? Stack(
                      children: [
                        Text('${i + 1}',
                            style: TextStyle(
                                fontSize: 22,
                                foreground: Paint()
                                  ..style = PaintingStyle.stroke
                                  ..strokeWidth = 3.5
                                  ..color = Colors.black)),
                        Text('${i + 1}',
                            style: const TextStyle(
                                fontSize: 22, color: Colors.white)),
                      ],
                    )
                  : Text('${i + 1}',
                      style: TextStyle(
                          fontSize: 22,
                          color: sel || armed
                              ? Colors.white
                              : Colors.grey.shade500)),
            ),
            if (deleteHover)
              // 删除悬停：整个按钮覆盖半透明遮罩 + 对角线大叉。
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: const _DeleteCrossPainter(),
                    child: Container(
                      decoration: BoxDecoration(
                        color: const Color(0x88000000),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 左半「调整前」预览：黑底 contain 图（无图时占位文案）+ 左上角标签；
  /// 取色模式下十字光标、点击取样、叠加悬停十字线；
  /// 悬停时叠加 HSL 气泡（光标右下方，近右/下边缘翻转到左上侧）。
  Widget _buildInputPane(ui.Image? image, String hint) {
    final armed = _armedBand != null;
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        // 取色悬停气泡：实时显示光标像素 HSL，风格与矢量示波器悬停气泡
        // 一致（VectorscopeGraticule._drawHoverBubble）：圆角黑底白边、
        // 左侧色样块（HSL 50% 亮度纯色）、H/S/L 百分比文案；默认光标右
        // 上方，越界换侧并夹进窗格。
        Widget? bubble;
        final hov = _pickHover;
        if (armed && hov != null && _hoverHueDeg != null) {
          final hue = _hoverHueDeg!;
          final sat = (_hoverS ?? 0).clamp(0.0, 1.0);
          final lig = (_hoverL ?? 0).clamp(0.0, 1.0);
          const bw = 140.0, bh = 24.0; // 估算尺寸（换侧判断用）
          var bx = hov.dx + 12;
          var by = hov.dy - 12 - bh;
          if (bx + bw > size.width - 1) bx = hov.dx - 12 - bw;
          if (by < 1) by = hov.dy + 12;
          bx = bx.clamp(1.0, math.max(1.0, size.width - 1 - bw));
          by = by.clamp(1.0, math.max(1.0, size.height - 1 - bh));
          bubble = Positioned(
            left: bx,
            top: by,
            // 不拦截手势（气泡仅展示，十字线/点击照常）。
            child: IgnorePointer(
              child: Container(
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  color: const Color(0xD9000000),
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(
                      color: const Color(0x99FFFFFF), width: 0.8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: HSLColor.fromAHSL(1, hue, sat, 0.5).toColor(),
                        border: Border.all(
                            color: const Color(0x99FFFFFF), width: 0.8),
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      'H ${hue.round()}°  S ${(sat * 100).round()}%'
                      '  L ${(lig * 100).round()}%',
                      style: const TextStyle(
                          fontSize: 10, color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
          );
        }
        return MouseRegion(
          cursor: armed ? SystemMouseCursors.precise : MouseCursor.defer,
          onHover:
              armed ? (e) => _updateHover(e.localPosition, size) : null,
          onExit: armed
              ? (_) => setState(() {
                    _pickHover = null;
                    _clearHoverHsl();
                  })
              : null,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: armed ? (d) => _pickAt(d.localPosition, size) : null,
            child: CustomPaint(
              foregroundPainter:
                  armed ? _PickOverlayPainter(hover: _pickHover) : null,
              child: Container(
                color: Colors.black,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Center(
                      child: image != null
                          ? RawImage(image: image, fit: BoxFit.contain)
                          : Text(hint,
                              style: const TextStyle(
                                  fontSize: 11, color: Colors.grey)),
                    ),
                    const Positioned(
                      left: 4,
                      top: 2,
                      child: Text('调整前',
                          style: TextStyle(
                              fontSize: 10, color: Colors.white54)),
                    ),
                    ?bubble,
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 取色悬停时的右半放大视图：左预览图以悬停像素为中心按 [_magZoom]
  /// 倍放大（像素中心对齐，近边缘时源窗钳位在图内不出黑边；点采样
  /// 显示像素格）。左上角叠加标签。
  Widget _buildMagnifierPane(ui.Image image) {
    final c = _hoverPixel!;
    return Container(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          CustomPaint(
              painter: _MagnifierPainter(
                  image: image,
                  center: Offset(c.dx + 0.5, c.dy + 0.5),
                  zoom: _magZoom.toDouble())),
          Positioned(
            left: 4,
            top: 2,
            child: Text('调整前 ×$_magZoom',
                style:
                    const TextStyle(fontSize: 10, color: Colors.white54)),
          ),
        ],
      ),
    );
  }
}

/// 取色模式叠加层：左预览区（调整前）悬停十字线。
class _PickOverlayPainter extends CustomPainter {
  final Offset? hover;

  const _PickOverlayPainter({this.hover});

  @override
  void paint(Canvas canvas, Size size) {
    final h = hover;
    if (h != null) {
      final cross = Paint()
        ..color = const Color(0xCCFFFFFF)
        ..strokeWidth = 1;
      canvas.drawLine(Offset(h.dx, 0), Offset(h.dx, size.height), cross);
      canvas.drawLine(Offset(0, h.dy), Offset(size.width, h.dy), cross);
    }
  }

  @override
  bool shouldRepaint(_PickOverlayPainter old) => true;
}

/// ALL 视图叠加层（多段色彩均衡器）：全部段的高斯色带 + 色相标线，
/// 按段按钮取样颜色着色。数学口径与 [_HueBandPainter] 一致（σ=45°/Q，
/// 扇形步进 2°，半径 half-13）。每条标线在 0.55R 处标注取色器序号
/// （白字黑边 2px）。
/// [bands]：(中心°, Q, 颜色, 圆心段颜色?, 序号标签)——调整前半区传
/// 原 H 中心（圆心段颜色 null，色带整径单色、标线从 0.25R 起）；
/// 调整后半区传 H+ΔH 移位后中心，圆心段颜色 = 原始色相颜色：色带
/// 径向分两段——0→0.25R 中心饼用原始颜色、0.25R→R 环形段用移位后
/// 颜色；标线同样分两段（圆心段加粗），呈现移位前后的强烈对比。
class _AllBandsPainter extends CustomPainter {
  /// (中心°, Q, 颜色, 圆心段颜色?, 序号标签)。
  final List<(double, double, Color, Color?, String)> bands;

  const _AllBandsPainter({this.bands = const []});

  @override
  void paint(Canvas canvas, Size size) {
    final half = math.min(size.width, size.height) / 2;
    final center = size.center(Offset.zero);
    final bandR = half - 13; // 刻度环内侧（与 _HueBandPainter 同口径）
    if (bandR <= 0) return;
    final rect = Rect.fromCircle(center: center, radius: bandR);
    const step = 2.0;

    void marker(double hDeg, Color color, Color? innerColor) {
      final a = _HueBandPainter._screenAngleOfHue(hDeg);
      final dir = Offset(math.cos(a), math.sin(a));
      if (innerColor != null) {
        // 圆心段：原始色相颜色（从圆心覆盖到 0.25R，加粗强调对比）。
        canvas.drawLine(center, center + dir * (bandR * 0.25),
            Paint()
              ..color = innerColor
              ..strokeWidth = 3);
      }
      canvas.drawLine(center + dir * (bandR * 0.25), center + dir * bandR,
          Paint()
            ..color = color
            ..strokeWidth = 2);
    }

    /// 序号标签（0.55R 处）：白字黑边 2px（描边层 + 填充层）。
    void label(String s, double hDeg) {
      final a = _HueBandPainter._screenAngleOfHue(hDeg);
      final at = center +
          Offset(math.cos(a), math.sin(a)) * (bandR * 0.55);
      final stroke = TextPainter(
        text: TextSpan(
            text: s,
            style: TextStyle(
                fontSize: 20,
                foreground: Paint()
                  ..style = PaintingStyle.stroke
                  ..strokeWidth = 2
                  ..color = Colors.black)),
        textDirection: TextDirection.ltr,
      )..layout();
      final fill = TextPainter(
        text: TextSpan(
            text: s,
            style: const TextStyle(fontSize: 20, color: Colors.white)),
        textDirection: TextDirection.ltr,
      )..layout();
      final topLeft = at - Offset(stroke.width / 2, stroke.height / 2);
      stroke.paint(canvas, topLeft);
      fill.paint(canvas, topLeft);
    }

    void band(double centerDeg, double q, Color color, Color? innerColor,
        String seq) {
      final sigma = 45.0 / q;
      final innerRect =
          Rect.fromCircle(center: center, radius: bandR * 0.25);
      for (var deg = 0.0; deg < 360; deg += step) {
        final hue = _HueBandPainter._hueByScreenDeg[deg.round() % 360];
        var d = (hue - centerDeg).abs() % 360.0;
        if (d > 180) d = 360 - d;
        final w = math.exp(-0.5 * (d / sigma) * (d / sigma));
        if (w < 0.02) continue;
        final start = (deg - step / 2) * math.pi / 180;
        final sweep = step * math.pi / 180;
        if (innerColor != null) {
          // 径向两段：0.25R→R 环形段用移位后颜色（Path 环形扇区，
          // 避免与中心饼叠混透明度），0→0.25R 中心饼用原始颜色。
          final ring = Path()
            ..addArc(rect, start, sweep)
            ..arcTo(innerRect, start + sweep, -sweep, false)
            ..close();
          canvas.drawPath(ring,
              Paint()..color = color.withAlpha((w * 0.4 * 255).round()));
          canvas.drawArc(innerRect, start, sweep, true,
              Paint()..color = innerColor.withAlpha((w * 0.4 * 255).round()));
        } else {
          canvas.drawArc(rect, start, sweep, true,
              Paint()..color = color.withAlpha((w * 0.4 * 255).round()));
        }
      }
      marker(centerDeg, color, innerColor);
      label(seq, centerDeg);
    }

    for (final (h, q, c, inner, seq) in bands) {
      band(h, q, c, inner, seq);
    }
  }

  @override
  bool shouldRepaint(_AllBandsPainter old) => true;
}

/// 删除模式悬停角标：覆盖整个段按钮的对角线大叉（四角留 2px 内缩）。
class _DeleteCrossPainter extends CustomPainter {
  const _DeleteCrossPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = const Color(0xFFFF6E6E)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    const inset = 2.0;
    canvas.drawLine(const Offset(inset, inset),
        Offset(size.width - inset, size.height - inset), p);
    canvas.drawLine(Offset(size.width - inset, inset),
        Offset(inset, size.height - inset), p);
  }

  @override
  bool shouldRepaint(_DeleteCrossPainter old) => false;
}

/// 取色放大视图：以 [center]（图像像素坐标，可为小数，平滑跟随十字线）
/// 为中心、按 [zoom] 倍放大绘制 [image]——**倍率相对左区预览的显示
/// 缩放**（contain 适配），绝对缩放 = zoom × baseScale，X1 即与左区等
/// 大（直接按图像像素放大在大图上会远超预期：4K 图在预览格里约缩小
/// 10 倍显示，X2 绝对放大观感已超 X20）。源窗近边缘时钳位在图内
/// （视图恒铺满，不出黑边）；图小于源窗时源窗收缩到整图。点采样
/// （FilterQuality.none）显示像素格，便于逐像素取色。放大图上叠加
/// 十字线 + 中心圆标记左区锁定的像素（边缘钳位时源窗内移，十字线按
/// 像素在视图中的实际位置绘制，不恒在画面中心）。
class _MagnifierPainter extends CustomPainter {
  final ui.Image image;
  final Offset center;
  final double zoom;

  const _MagnifierPainter(
      {required this.image, required this.center, this.zoom = 6});

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    // 左右预览格同尺寸，baseScale 即左区 contain 显示缩放。
    final baseScale =
        math.min(size.width / image.width, size.height / image.height);
    final absZoom = zoom * baseScale;
    var srcW = size.width / absZoom;
    var srcH = size.height / absZoom;
    // 图小于源窗：源窗收缩到整图（极限边缘条件）。
    if (srcW > image.width) srcW = image.width.toDouble();
    if (srcH > image.height) srcH = image.height.toDouble();
    // 近边缘：源窗钳位在图内（中心随之内移，视图不出现黑边）。
    final left =
        (center.dx - srcW / 2).clamp(0.0, image.width - srcW).toDouble();
    final top =
        (center.dy - srcH / 2).clamp(0.0, image.height - srcH).toDouble();
    canvas.drawImageRect(
        image,
        Rect.fromLTWH(left, top, srcW, srcH),
        Rect.fromLTWH(0, 0, size.width, size.height),
        Paint()..filterQuality = FilterQuality.none);

    // 锁定像素在视图中的实际位置（源窗被钳位内移时不恒在画面中心）。
    final scaleX = size.width / srcW;
    final scaleY = size.height / srcH;
    final cx = (center.dx - left) * scaleX;
    final cy = (center.dy - top) * scaleY;
    // 中心圆：半径随放大像素尺寸（约 3 个像素格），标记左区十字线
    // 锁定的像素。
    final r = math.max(18.0, math.min(scaleX, scaleY) * 1.8);
    // 十字线画到圆圈外：四段线止于圆周，不穿过中心圆。
    final cross = Paint()
      ..color = const Color(0xCCFFFFFF)
      ..strokeWidth = 1;
    canvas.drawLine(Offset(cx, 0), Offset(cx, cy - r), cross);
    canvas.drawLine(Offset(cx, cy + r), Offset(cx, size.height), cross);
    canvas.drawLine(Offset(0, cy), Offset(cx - r, cy), cross);
    canvas.drawLine(Offset(cx + r, cy), Offset(size.width, cy), cross);
    canvas.drawCircle(
        Offset(cx, cy),
        r,
        Paint()
          ..color = const Color(0xFFFFFFFF)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5);
    canvas.drawCircle(
        Offset(cx, cy), 1.5, Paint()..color = const Color(0xFFFFFFFF));
  }

  @override
  bool shouldRepaint(_MagnifierPainter old) =>
      old.image != image || old.center != center || old.zoom != zoom;
}
