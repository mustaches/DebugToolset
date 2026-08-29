/// ISP Studio 左侧节点工具栏：按分组列出全部节点类型，点击添加到画布。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../providers/isp_studio_state.dart';
import '../models/isp_node.dart';

/// 左侧工具栏宽度。
const double kNodePaletteWidth = 144;

/// 「Source → CIS Src」分组中的 CIS 源节点。
const _cisTypeIds = [
  'cis_bayer_rggb',
  'cis_rccb_rccg',
  'cis_rccc',
  'cis_ryycy',
  'cis_rgb_ir',
  'cis_mono',
];

/// 「Process」分组：RAW→RGB 链上的处理算子（按典型流水线顺序）。
const _processTypeIds = [
  'black_level',
  'dpc',
  'fpn',
  'lsc',
  'grgb_balance',
  'bayer_dnr',
  'highlight',
  'demosaic',
  'white_balance',
  'ccm',
  'rgb_dnr',
  'sharpen',
  'edge_extract',
  'morphology',
  'gamma',
  'ahe',
  'hsl_debugger',
  'rgb_debugger',
  'yuv_debugger',
  'sat_bright_adjuster',
  'bright_contrast_adjuster',
  'levels_curves',
  'color_balance',
  'color_temp_adjuster',
];

/// 「ColorTrans」分组：色彩空间转换（RGB/YUV/HSL 互转）。
const _colorTransTypeIds = [
  'csc_rgb2yuv',
  'csc_rgb2hsl',
  'csc_yuv2rgb',
  'csc_yuv2hsl',
  'csc_hsl2rgb',
  'csc_hsl2yuv',
];

/// 「Process → Fluorescence」分组：ICG 荧光 mono 域算子与融合。
const _fluorescenceTypeIds = [
  'fluoro_leak',
  'fluoro_background',
  'fluoro_normalize',
  'fluoro_temporal',
  'pseudo_color',
  'fluoro_fusion',
];

/// 「Datapath」分组：分路器、合路器与乘法器。
const _datapathTypeIds = [
  'rgb_splitter',
  'yuv_splitter',
  'hsl_splitter',
  'rgb_combiner',
  'yuv_combiner',
  'hsl_combiner',
  'multiplier',
  'adder',
  'blender',
  'mux4',
];

/// 「Output」分组：预览与导出汇点。
const _outputTypeIds = [
  'preview',
  'image_output',
  'video_output',
];

/// 「Instrument」分组：仪器类分析节点（图像仪器 + 音频仪器）。
const _instrumentTypeIds = [
  'histogram',
  'waveform',
  'vectorscope',
  'psnr',
  'audio_level',
  'audio_waveform',
  'audio_eq',
];

/// 节点工具栏：按 Source / Process / ColorTrans / Datapath / Output /
/// Instrument 分组列出全部节点类型
/// （类型色点 + 名称），点击后把节点添加到视口中心
/// （[onPickCenter] 由视图/画布计算）。
/// 注：bayer_source 不在工具栏提供——与 CIS Src → Bayer RGGB 重复
/// （类型仍保留，默认流程图与已保存的 .ispflow 继续使用）。
class IspNodePalette extends StatelessWidget {
  final Offset Function() onPickCenter;

  const IspNodePalette({super.key, required this.onPickCenter});

  @override
  Widget build(BuildContext context) {
    final state = context.read<IspStudioState>();
    // 背景用 Material 提供 ink 表面（ExpansionTile/InkWell 需要）。
    return Material(
      color: const Color(0xFF252525),
      child: Container(
        width: kNodePaletteWidth,
        decoration: BoxDecoration(
          border: Border(right: BorderSide(color: Colors.grey.shade800)),
        ),
        child: ListView(
          padding: const EdgeInsets.all(6),
          children: [
            _expansionGroup('Source', const Color(0xFF263328), [
              _expansionGroup(
                'CIS Src',
                null,
                [for (final id in _cisTypeIds) _item(state, id)],
                nested: true,
              ),
              _item(state, 'image_source'),
              _item(state, 'video_source'),
            ]),
            _expansionGroup('Process', const Color(0xFF2A3040), [
              for (final id in _processTypeIds) _item(state, id),
              _expansionGroup(
                'ColorTrans',
                null,
                [for (final id in _colorTransTypeIds) _item(state, id)],
                nested: true,
              ),
              _expansionGroup(
                'Fluorescence',
                null,
                [for (final id in _fluorescenceTypeIds) _item(state, id)],
                nested: true,
              ),
            ]),
            _expansionGroup('Datapath', const Color(0xFF3A3226), [
              for (final id in _datapathTypeIds) _item(state, id),
            ]),
            _expansionGroup('Output', const Color(0xFF3A2A2E), [
              for (final id in _outputTypeIds) _item(state, id),
            ]),
            _expansionGroup('Instrument', const Color(0xFF26363A), [
              for (final id in _instrumentTypeIds) _item(state, id),
            ]),
          ],
        ),
      ),
    );
  }

  /// 大类分组：默认收起（收起态固定 32px 高），带边框与分组背景色的
  /// 圆角框（嵌套子组不加框、随父组展开）。
  Widget _expansionGroup(String title, Color? frameColor, List<Widget> children,
      {bool nested = false}) {
    return _PaletteGroup(
      title: title,
      frameColor: frameColor,
      nested: nested,
      children: children,
    );
  }

  Widget _item(IspStudioState state, String typeId) {
    final type = IspNodeRegistry.byId(typeId)!;
    // 条目宽度有限，长名称会省略号截断；悬浮气泡显示完整节点名。
    return Tooltip(
      message: type.displayName,
      waitDuration: const Duration(milliseconds: 400),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: InkWell(
          onTap: () => state.addNodeAt(type.typeId, onPickCenter()),
          child: Container(
            // 紧凑条目：行高压到 1.0、垂直 padding 1，高度约为默认一半。
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
            decoration: BoxDecoration(
              color: const Color(0xFF303030),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: const Color(0xFF3A3A3A)),
            ),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Color(type.colorValue),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    type.displayName,
                    style: const TextStyle(
                        fontSize: 11, height: 1.0, color: Colors.white70),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}


/// 工具栏大类分组框：默认收起（收起态固定 32px 高标题栏），点击展开。
/// 顶级分组带背景色圆角框；嵌套子组（[nested]）无框且默认展开。
class _PaletteGroup extends StatefulWidget {
  final String title;
  final Color? frameColor;
  final bool nested;
  final List<Widget> children;

  const _PaletteGroup({
    required this.title,
    required this.frameColor,
    required this.nested,
    required this.children,
  });

  @override
  State<_PaletteGroup> createState() => _PaletteGroupState();
}

class _PaletteGroupState extends State<_PaletteGroup> {
  late bool _expanded = widget.nested;

  @override
  Widget build(BuildContext context) {
    final header = InkWell(
      onTap: () => setState(() => _expanded = !_expanded),
      child: SizedBox(
        height: 20, // 收起态框高 20px
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: widget.nested ? 22 : 8),
          child: Row(
            children: [
              Icon(
                _expanded
                    ? Icons.keyboard_arrow_down
                    : Icons.keyboard_arrow_right,
                size: 14,
                color: Colors.white54,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  widget.title,
                  style: const TextStyle(
                      fontSize: 11,
                      height: 1.0,
                      fontWeight: FontWeight.bold,
                      color: Colors.white70),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        if (_expanded)
          Padding(
            // 嵌套子组右缩进比顶级分组多 10px。
            padding: EdgeInsets.only(
                left: widget.nested ? 14 : 4, bottom: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: widget.children,
            ),
          ),
      ],
    );
    if (widget.nested) return content;
    // 用 Material 承载背景色（ink 效果需要 Material 祖先）。
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: widget.frameColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: BorderSide(color: Colors.grey.shade800),
        ),
        clipBehavior: Clip.antiAlias,
        child: content,
      ),
    );
  }
}
