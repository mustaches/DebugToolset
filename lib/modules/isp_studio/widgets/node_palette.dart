/// ISP Studio 左侧节点工具栏：按分组列出全部节点类型，点击添加到画布。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../providers/isp_studio_state.dart';
import '../models/isp_node.dart';

/// 左侧工具栏宽度。
const double kNodePaletteWidth = 120;

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
  'gamma',
  'csc_rgb2yuv',
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

/// 「Datapath」分组：分路器与合路器。
const _datapathTypeIds = [
  'rgb_splitter',
  'yuv_splitter',
  'hsl_splitter',
  'rgb_combiner',
  'yuv_combiner',
  'hsl_combiner',
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
  'audio_level',
  'audio_waveform',
  'audio_eq',
];

/// 节点工具栏：按 Source / Process / Datapath / Output / Instrument 分组列出全部节点类型
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
            _expansionGroup('Source', [
              _expansionGroup(
                'CIS Src',
                [for (final id in _cisTypeIds) _item(state, id)],
                nested: true,
              ),
              _item(state, 'image_source'),
              _item(state, 'video_source'),
            ]),
            _expansionGroup('Process', [
              for (final id in _processTypeIds) _item(state, id),
              _expansionGroup(
                'Fluorescence',
                [for (final id in _fluorescenceTypeIds) _item(state, id)],
                nested: true,
              ),
            ]),
            _expansionGroup('Datapath', [
              for (final id in _datapathTypeIds) _item(state, id),
            ]),
            _expansionGroup('Output', [
              for (final id in _outputTypeIds) _item(state, id),
            ]),
            _expansionGroup('Instrument', [
              for (final id in _instrumentTypeIds) _item(state, id),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _expansionGroup(String title, List<Widget> children,
      {bool nested = false}) {
    return ExpansionTile(
      title: Text(title,
          style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: Colors.white70)),
      initiallyExpanded: true,
      dense: true,
      tilePadding: EdgeInsets.symmetric(horizontal: nested ? 12 : 4),
      childrenPadding: const EdgeInsets.only(left: 4),
      iconColor: Colors.white54,
      collapsedIconColor: Colors.white54,
      children: children,
    );
  }

  Widget _item(IspStudioState state, String typeId) {
    final type = IspNodeRegistry.byId(typeId)!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: InkWell(
        onTap: () => state.addNodeAt(type.typeId, onPickCenter()),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
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
                  style:
                      const TextStyle(fontSize: 11, color: Colors.white70),
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
