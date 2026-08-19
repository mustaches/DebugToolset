/// ISP Studio 节点数据模型（纯 Dart，无 Flutter 依赖，可用于后台 isolate）。
library;

/// 端口数据类型。
enum IspPortType {
  /// 原始 Bayer 马赛克帧。
  bayer,

  /// 处理后的 RGB 帧。
  rgb,

  /// YUV（BT.601 全范围）帧。
  yuv,

  /// HSL 帧。
  hsl,

  /// 音频流（视频音轨，预览播放时经 MCI 回放）。
  audio,

  /// 单通道 R (Red)。
  r,

  /// 单通道 G (Green)。
  g,

  /// 单通道 B (Blue)。
  b,

  /// 单通道 Y (Luma)。
  y,

  /// 单通道 U (Chroma U)。
  u,

  /// 单通道 V (Chroma V)。
  v,

  /// 单通道 H (Hue)。
  h,

  /// 单通道 S (Saturation)。
  s,

  /// 单通道 L (Lightness)。
  l,

  /// 通用 Mono 单通道端口。
  mono,
}

/// 是否为单通道端口类型（R/G/B/Y/U/V/H/S/L/Mono）。
bool isSingleChannelPort(IspPortType type) => switch (type) {
      IspPortType.r ||
      IspPortType.g ||
      IspPortType.b ||
      IspPortType.y ||
      IspPortType.u ||
      IspPortType.v ||
      IspPortType.h ||
      IspPortType.s ||
      IspPortType.l ||
      IspPortType.mono =>
        true,
      _ => false,
    };

/// 参数类型。
enum IspParamType {
  intNumber,
  doubleNumber,
  boolean,
  choice,
  text,
  filePath,
  matrix3,
}

/// 参数规格定义。
class IspParamSpec {
  final String key;
  final String label;
  final IspParamType type;
  final Object defaultValue;
  final double? min;
  final double? max;

  /// choice 类型的可选值（存 key；显示文案可与 key 相同或为中文）。
  final List<String>? options;

  const IspParamSpec({
    required this.key,
    required this.label,
    required this.type,
    required this.defaultValue,
    this.min,
    this.max,
    this.options,
  });
}

/// 端口规格定义。
class IspPortSpec {
  final String name;
  final IspPortType type;
  final String label;

  const IspPortSpec({
    required this.name,
    required this.type,
    required this.label,
  });
}

/// 节点类型定义。
class IspNodeType {
  final String typeId;
  final String displayName;
  final List<IspPortSpec> inputs;
  final List<IspPortSpec> outputs;
  final List<IspParamSpec> params;

  /// 节点标题栏颜色（ARGB）。
  final int colorValue;

  const IspNodeType({
    required this.typeId,
    required this.displayName,
    this.inputs = const [],
    this.outputs = const [],
    this.params = const [],
    required this.colorValue,
  });

  /// 视频格式输入组（RGB/YUV/HSL/Mono）的端口名：同组互斥，只允许一路接入。
  static const videoInputGroupPorts = {'in', 'in_yuv', 'in_hsl', 'in_mono'};

  /// 是否带视频格式输入组（具备该组两个及以上端口，如仪器/预览/
  /// 输出节点）。同组端口互斥：接入一路后其余置灰、不允许再连。
  bool get hasVideoInputGroup =>
      inputs.where((p) => videoInputGroupPorts.contains(p.name)).length > 1;

  IspPortSpec? inputPort(String name) {
    for (final p in inputs) {
      if (p.name == name) return p;
    }
    return null;
  }

  IspPortSpec? outputPort(String name) {
    for (final p in outputs) {
      if (p.name == name) return p;
    }
    return null;
  }
}

/// 节点卡片默认宽度。
const double kNodeWidth = 190;

/// 预览/仪器节点附加显示区默认高度（画布坐标）。
const double kDefaultNodeExtraHeight = 160;

/// 图中的节点实例。
class IspNode {
  final String id;
  final String typeId;
  double x;
  double y;

  /// 节点卡片宽度（画布坐标）。预览节点可通过右下角控制点调宽，
  /// 输出端口与连线几何以该值为准。随流程保存。
  double width;

  /// 预览/仪器节点附加显示区高度（画布坐标），可通过底部手柄或
  /// 右下角控制点调整。随流程保存。
  double extraHeight;
  final Map<String, Object?> paramValues;

  IspNode({
    required this.id,
    required this.typeId,
    required this.x,
    required this.y,
    this.width = kNodeWidth,
    this.extraHeight = kDefaultNodeExtraHeight,
    required this.paramValues,
  });

  /// 按类型默认值初始化参数创建节点。
  factory IspNode.create(IspNodeType type, String id, double x, double y) {
    final values = <String, Object?>{};
    for (final p in type.params) {
      values[p.key] = p.defaultValue;
    }
    return IspNode(id: id, typeId: type.typeId, x: x, y: y, paramValues: values);
  }
}

/// 节点类型注册表。
abstract final class IspNodeRegistry {
  /// CIS RAW 源节点的公共参数（文件/分辨率/位深/打包/端序/起始帧）。
  static List<IspParamSpec> _rawSourceParams(
          [List<IspParamSpec> extra = const []]) =>
      [
        const IspParamSpec(
          key: 'filePath',
          label: '文件路径',
          type: IspParamType.filePath,
          defaultValue: '',
        ),
        const IspParamSpec(
          key: 'width',
          label: '宽度',
          type: IspParamType.intNumber,
          defaultValue: 3840,
          min: 16,
          max: 16384,
        ),
        const IspParamSpec(
          key: 'height',
          label: '高度',
          type: IspParamType.intNumber,
          defaultValue: 2160,
          min: 16,
          max: 16384,
        ),
        const IspParamSpec(
          key: 'bitDepth',
          label: '位深',
          type: IspParamType.choice,
          defaultValue: '10',
          options: ['8', '10', '12', '14', '16'],
        ),
        const IspParamSpec(
          key: 'packing',
          label: '打包方式',
          type: IspParamType.choice,
          defaultValue: 'unpacked_lsb',
          options: ['unpacked_lsb', 'unpacked_msb', 'mipi'],
        ),
        const IspParamSpec(
          key: 'littleEndian',
          label: '小端序',
          type: IspParamType.boolean,
          defaultValue: true,
        ),
        const IspParamSpec(
          key: 'frameIndex',
          label: '起始帧',
          type: IspParamType.intNumber,
          defaultValue: 0,
          min: 0,
        ),
        ...extra,
      ];

  /// RAW 域处理算子的双输入端口（Bayer 或 Mono 二选一，互斥组自动生效）。
  static const List<IspPortSpec> _rawDualInputs = [
    IspPortSpec(name: 'in', type: IspPortType.bayer, label: 'Bayer'),
    IspPortSpec(name: 'in_mono', type: IspPortType.mono, label: 'Mono'),
  ];

  /// RAW 域处理算子的双输出端口（与输入同格式直通）。
  static const List<IspPortSpec> _rawDualOutputs = [
    IspPortSpec(name: 'out', type: IspPortType.bayer, label: 'Bayer'),
    IspPortSpec(name: 'out_mono', type: IspPortType.mono, label: 'Mono'),
  ];

  static final Map<String, IspNodeType> types = {
    'bayer_source': IspNodeType(
      typeId: 'bayer_source',
      displayName: 'Bayer RAW 源',
      colorValue: 0xFF4E6E4E,
      outputs: [
        IspPortSpec(name: 'out', type: IspPortType.bayer, label: 'Bayer'),
      ],
      params: [
        IspParamSpec(
          key: 'filePath',
          label: '文件路径',
          type: IspParamType.filePath,
          defaultValue: '',
        ),
        IspParamSpec(
          key: 'width',
          label: '宽度',
          type: IspParamType.intNumber,
          defaultValue: 3840,
          min: 16,
          max: 16384,
        ),
        IspParamSpec(
          key: 'height',
          label: '高度',
          type: IspParamType.intNumber,
          defaultValue: 2160,
          min: 16,
          max: 16384,
        ),
        IspParamSpec(
          key: 'bitDepth',
          label: '位深',
          type: IspParamType.choice,
          defaultValue: '10',
          options: ['8', '10', '12', '14', '16'],
        ),
        IspParamSpec(
          key: 'packing',
          label: '打包方式',
          type: IspParamType.choice,
          defaultValue: 'unpacked_lsb',
          options: ['unpacked_lsb', 'unpacked_msb', 'mipi'],
        ),
        IspParamSpec(
          key: 'bayerPattern',
          label: 'Bayer 排列',
          type: IspParamType.choice,
          defaultValue: 'RGGB',
          options: ['RGGB', 'BGGR', 'GRBG', 'GBRG'],
        ),
        IspParamSpec(
          key: 'littleEndian',
          label: '小端序',
          type: IspParamType.boolean,
          defaultValue: true,
        ),
        IspParamSpec(
          key: 'frameIndex',
          label: '起始帧',
          type: IspParamType.intNumber,
          defaultValue: 0,
          min: 0,
        ),
      ],
    ),
    'cis_bayer_rggb': IspNodeType(
      typeId: 'cis_bayer_rggb',
      displayName: 'Bayer RGGB',
      colorValue: 0xFF3E6E3E,
      outputs: [
        IspPortSpec(name: 'out', type: IspPortType.bayer, label: 'Bayer'),
      ],
      params: _rawSourceParams([
        const IspParamSpec(
          key: 'bayerPattern',
          label: 'Bayer 排列',
          type: IspParamType.choice,
          defaultValue: 'RGGB',
          options: ['RGGB', 'BGGR', 'GRBG', 'GBRG'],
        ),
      ]),
    ),
    'cis_rccb_rccg': IspNodeType(
      typeId: 'cis_rccb_rccg',
      displayName: 'RCCB/RCCG',
      colorValue: 0xFF4E7E4E,
      outputs: [
        IspPortSpec(name: 'out', type: IspPortType.bayer, label: 'RAW'),
      ],
      params: _rawSourceParams([
        const IspParamSpec(
          key: 'cfaPattern',
          label: 'CFA 排列',
          type: IspParamType.choice,
          defaultValue: 'RCCB',
          options: ['RCCB', 'RCCG'],
        ),
      ]),
    ),
    'cis_rccc': IspNodeType(
      typeId: 'cis_rccc',
      displayName: 'RCCC',
      colorValue: 0xFF5E6E3E,
      outputs: [
        IspPortSpec(name: 'out', type: IspPortType.bayer, label: 'RAW'),
      ],
      params: _rawSourceParams(),
    ),
    'cis_ryycy': IspNodeType(
      typeId: 'cis_ryycy',
      displayName: 'RYYCy',
      colorValue: 0xFF6E7E3E,
      outputs: [
        IspPortSpec(name: 'out', type: IspPortType.bayer, label: 'RAW'),
      ],
      params: _rawSourceParams(),
    ),
    'cis_rgb_ir': IspNodeType(
      typeId: 'cis_rgb_ir',
      displayName: 'RGB-IR',
      colorValue: 0xFF3E5E4E,
      outputs: [
        IspPortSpec(name: 'out', type: IspPortType.bayer, label: 'RAW'),
      ],
      params: _rawSourceParams([
        const IspParamSpec(
          key: 'irSubtraction',
          label: 'IR 扣除比例',
          type: IspParamType.doubleNumber,
          defaultValue: 0.5,
          min: 0,
          max: 1,
        ),
      ]),
    ),
    'cis_mono': IspNodeType(
      typeId: 'cis_mono',
      displayName: 'MONO',
      colorValue: 0xFF5E5E5E,
      outputs: [
        // 16 位 mono 中间格式：单通道直接入链，不再展开为 RGB。
        IspPortSpec(name: 'out', type: IspPortType.mono, label: 'Mono'),
      ],
      params: _rawSourceParams(),
    ),
    'image_source': IspNodeType(
      typeId: 'image_source',
      displayName: 'Image',
      colorValue: 0xFF4E5E7E,
      outputs: [
        IspPortSpec(name: 'out_rgb', type: IspPortType.rgb, label: 'RGB'),
        IspPortSpec(name: 'out_yuv', type: IspPortType.yuv, label: 'YUV'),
        IspPortSpec(name: 'out_hsl', type: IspPortType.hsl, label: 'HSL'),
      ],
      params: [
        IspParamSpec(
          key: 'filePath',
          label: '图片文件',
          type: IspParamType.filePath,
          defaultValue: '',
        ),
        IspParamSpec(
          key: 'bitDepth',
          label: '输出位深',
          type: IspParamType.choice,
          defaultValue: '8',
          options: ['8', '10', '12', '16'],
        ),
      ],
    ),
    'video_source': IspNodeType(
      typeId: 'video_source',
      displayName: 'Video',
      colorValue: 0xFF7E5E4E,
      outputs: [
        IspPortSpec(name: 'out_rgb', type: IspPortType.rgb, label: 'RGB'),
        IspPortSpec(name: 'out_yuv', type: IspPortType.yuv, label: 'YUV'),
        IspPortSpec(name: 'out_hsl', type: IspPortType.hsl, label: 'HSL'),
        // 音轨输出：接到音频仪器（电平/波形/EQ）表达音频流向；
        // 预览播放时含音轨即自动回放（不依赖该连接）。
        IspPortSpec(name: 'out_audio', type: IspPortType.audio, label: 'Audio'),
      ],
      params: [
        IspParamSpec(
          key: 'filePath',
          label: '视频文件',
          type: IspParamType.filePath,
          defaultValue: '',
        ),
        IspParamSpec(
          key: 'bitDepth',
          label: '输出位深',
          type: IspParamType.choice,
          defaultValue: '8',
          options: ['8', '10', '12', '16'],
        ),
        IspParamSpec(
          key: 'ffmpegPath',
          label: 'ffmpeg 路径',
          type: IspParamType.text,
          // 默认用项目内置的 ffmpeg（tools/ffmpeg/ffmpeg.exe）。
          defaultValue: 'tools/ffmpeg/ffmpeg.exe',
        ),
      ],
    ),
    'black_level': IspNodeType(
      typeId: 'black_level',
      displayName: '黑电平校正',
      colorValue: 0xFF5A5A6E,
      inputs: [
        IspPortSpec(name: 'in', type: IspPortType.bayer, label: 'Bayer'),
        // mono 输入（荧光链）：用 r 参数作为统一偏移扣除。
        IspPortSpec(name: 'in_mono', type: IspPortType.mono, label: 'Mono'),
      ],
      outputs: [
        IspPortSpec(name: 'out', type: IspPortType.bayer, label: 'Bayer'),
        IspPortSpec(name: 'out_mono', type: IspPortType.mono, label: 'Mono'),
      ],
      params: [
        IspParamSpec(
          key: 'r',
          label: 'R 黑电平',
          type: IspParamType.doubleNumber,
          defaultValue: 0.0,
          min: 0,
          max: 4095,
        ),
        IspParamSpec(
          key: 'gr',
          label: 'Gr 黑电平',
          type: IspParamType.doubleNumber,
          defaultValue: 0.0,
          min: 0,
          max: 4095,
        ),
        IspParamSpec(
          key: 'gb',
          label: 'Gb 黑电平',
          type: IspParamType.doubleNumber,
          defaultValue: 0.0,
          min: 0,
          max: 4095,
        ),
        IspParamSpec(
          key: 'b',
          label: 'B 黑电平',
          type: IspParamType.doubleNumber,
          defaultValue: 0.0,
          min: 0,
          max: 4095,
        ),
      ],
    ),
    // ---- ICG 荧光内窥镜方案：RAW 域算子（mosaic/mono → 同格式）----
    'dpc': IspNodeType(
      typeId: 'dpc',
      displayName: '坏点校正',
      colorValue: 0xFF5A5A6E,
      inputs: _rawDualInputs,
      outputs: _rawDualOutputs,
      params: [
        IspParamSpec(
          key: 'threshold',
          label: '离群阈值%',
          type: IspParamType.doubleNumber,
          defaultValue: 5.0,
          min: 0,
          max: 100,
        ),
        IspParamSpec(
          key: 'mode',
          label: '模式',
          type: IspParamType.choice,
          defaultValue: 'median',
          options: ['median', 'directional'],
        ),
      ],
    ),
    'fpn': IspNodeType(
      typeId: 'fpn',
      displayName: 'FPN 校正',
      colorValue: 0xFF5A626E,
      inputs: _rawDualInputs,
      outputs: _rawDualOutputs,
      params: [
        IspParamSpec(
          key: 'row',
          label: '行校正',
          type: IspParamType.boolean,
          defaultValue: true,
        ),
        IspParamSpec(
          key: 'col',
          label: '列校正',
          type: IspParamType.boolean,
          defaultValue: true,
        ),
        IspParamSpec(
          key: 'maxCorr',
          label: '最大校正量',
          type: IspParamType.doubleNumber,
          defaultValue: 64.0,
          min: 0,
          max: 4095,
        ),
      ],
    ),
    'lsc': IspNodeType(
      typeId: 'lsc',
      displayName: '镜头阴影校正',
      colorValue: 0xFF5A6A6E,
      inputs: _rawDualInputs,
      outputs: _rawDualOutputs,
      params: [
        IspParamSpec(
          key: 'strength',
          label: '强度',
          type: IspParamType.doubleNumber,
          defaultValue: 0.5,
          min: 0,
          max: 2,
        ),
        IspParamSpec(
          key: 'centerX',
          label: '中心 X',
          type: IspParamType.doubleNumber,
          defaultValue: 0.5,
          min: 0,
          max: 1,
        ),
        IspParamSpec(
          key: 'centerY',
          label: '中心 Y',
          type: IspParamType.doubleNumber,
          defaultValue: 0.5,
          min: 0,
          max: 1,
        ),
      ],
    ),
    'grgb_balance': IspNodeType(
      typeId: 'grgb_balance',
      displayName: 'Gr/Gb 均衡',
      colorValue: 0xFF4E6A5E,
      inputs: _rawDualInputs,
      outputs: _rawDualOutputs,
      params: [
        IspParamSpec(
          key: 'strength',
          label: '强度',
          type: IspParamType.doubleNumber,
          defaultValue: 1.0,
          min: 0,
          max: 1,
        ),
      ],
    ),
    'bayer_dnr': IspNodeType(
      typeId: 'bayer_dnr',
      displayName: 'Bayer 降噪',
      colorValue: 0xFF56665E,
      inputs: _rawDualInputs,
      outputs: _rawDualOutputs,
      params: [
        IspParamSpec(
          key: 'strength',
          label: '强度',
          type: IspParamType.doubleNumber,
          defaultValue: 1.0,
          min: 0,
          max: 4,
        ),
      ],
    ),
    'highlight': IspNodeType(
      typeId: 'highlight',
      displayName: '高光恢复',
      colorValue: 0xFF66605A,
      inputs: _rawDualInputs,
      outputs: _rawDualOutputs,
      params: [
        IspParamSpec(
          key: 'mode',
          label: '模式',
          type: IspParamType.choice,
          defaultValue: 'recover',
          options: ['recover', 'clip'],
        ),
        IspParamSpec(
          key: 'knee',
          label: '膝点',
          type: IspParamType.doubleNumber,
          defaultValue: 0.9,
          min: 0.5,
          max: 1,
        ),
      ],
    ),
    // ---- ICG 荧光内窥镜方案：RGB 域算子 ----
    'rgb_dnr': IspNodeType(
      typeId: 'rgb_dnr',
      displayName: 'RGB 降噪',
      colorValue: 0xFF4E5A66,
      inputs: [
        IspPortSpec(name: 'in', type: IspPortType.rgb, label: 'RGB'),
      ],
      outputs: [
        IspPortSpec(name: 'out', type: IspPortType.rgb, label: 'RGB'),
      ],
      params: [
        IspParamSpec(
          key: 'luma',
          label: '亮度强度',
          type: IspParamType.doubleNumber,
          defaultValue: 1.0,
          min: 0,
          max: 4,
        ),
        IspParamSpec(
          key: 'chroma',
          label: '色度强度',
          type: IspParamType.doubleNumber,
          defaultValue: 0.5,
          min: 0,
          max: 1,
        ),
      ],
    ),
    'sharpen': IspNodeType(
      typeId: 'sharpen',
      displayName: '锐化',
      colorValue: 0xFF5E5A66,
      inputs: [
        IspPortSpec(name: 'in', type: IspPortType.rgb, label: 'RGB'),
      ],
      outputs: [
        IspPortSpec(name: 'out', type: IspPortType.rgb, label: 'RGB'),
      ],
      params: [
        IspParamSpec(
          key: 'amount',
          label: '强度',
          type: IspParamType.doubleNumber,
          defaultValue: 0.5,
          min: 0,
          max: 4,
        ),
        IspParamSpec(
          key: 'threshold',
          label: '噪声门限',
          type: IspParamType.doubleNumber,
          defaultValue: 4.0,
          min: 0,
          max: 256,
        ),
      ],
    ),
    'csc_rgb2yuv': IspNodeType(
      typeId: 'csc_rgb2yuv',
      displayName: 'RGB→YUV 转换',
      colorValue: 0xFF565E6A,
      inputs: [
        IspPortSpec(name: 'in', type: IspPortType.rgb, label: 'RGB'),
      ],
      outputs: [
        IspPortSpec(name: 'out', type: IspPortType.yuv, label: 'YUV'),
      ],
      params: [
        IspParamSpec(
          key: 'standard',
          label: '标准',
          type: IspParamType.choice,
          defaultValue: 'bt601',
          options: ['bt601', 'bt709'],
        ),
        IspParamSpec(
          key: 'range',
          label: '范围',
          type: IspParamType.choice,
          defaultValue: 'full',
          options: ['full', 'limited'],
        ),
      ],
    ),
    // ---- ICG 荧光内窥镜方案：荧光 mono 域算子（青绿色系）----
    'fluoro_leak': IspNodeType(
      typeId: 'fluoro_leak',
      displayName: '激发泄漏扣除',
      colorValue: 0xFF3E7E76,
      inputs: [
        IspPortSpec(name: 'in_mono', type: IspPortType.mono, label: 'Mono'),
      ],
      outputs: [
        IspPortSpec(name: 'out_mono', type: IspPortType.mono, label: 'Mono'),
      ],
      params: [
        IspParamSpec(
          key: 'level',
          label: '扣除电平',
          type: IspParamType.doubleNumber,
          defaultValue: 64.0,
          min: 0,
          max: 65535,
        ),
        IspParamSpec(
          key: 'maxSub',
          label: '最大扣除限幅',
          type: IspParamType.doubleNumber,
          defaultValue: 128.0,
          min: 0,
          max: 65535,
        ),
      ],
    ),
    'fluoro_background': IspNodeType(
      typeId: 'fluoro_background',
      displayName: '背景扣除',
      colorValue: 0xFF3E767E,
      inputs: [
        IspPortSpec(name: 'in_mono', type: IspPortType.mono, label: 'Mono'),
      ],
      outputs: [
        IspPortSpec(name: 'out_mono', type: IspPortType.mono, label: 'Mono'),
      ],
      params: [
        IspParamSpec(
          key: 'blockSize',
          label: '块大小',
          type: IspParamType.intNumber,
          defaultValue: 16,
          min: 2,
          max: 256,
        ),
        IspParamSpec(
          key: 'strength',
          label: '强度',
          type: IspParamType.doubleNumber,
          defaultValue: 1.0,
          min: 0,
          max: 1,
        ),
      ],
    ),
    'fluoro_normalize': IspNodeType(
      typeId: 'fluoro_normalize',
      displayName: '激发归一化',
      colorValue: 0xFF3E6E7E,
      inputs: [
        IspPortSpec(name: 'in_mono', type: IspPortType.mono, label: 'Mono'),
      ],
      outputs: [
        IspPortSpec(name: 'out_mono', type: IspPortType.mono, label: 'Mono'),
      ],
      params: [
        IspParamSpec(
          key: 'reference',
          label: '参考电平',
          type: IspParamType.doubleNumber,
          defaultValue: 1000.0,
          min: 0,
          max: 65535,
        ),
        IspParamSpec(
          key: 'epsilon',
          label: '除法下限',
          type: IspParamType.doubleNumber,
          defaultValue: 1.0,
          min: 0,
          max: 1024,
        ),
      ],
    ),
    'fluoro_temporal': IspNodeType(
      typeId: 'fluoro_temporal',
      displayName: '时域 IIR 降噪',
      colorValue: 0xFF3E667E,
      inputs: [
        IspPortSpec(name: 'in_mono', type: IspPortType.mono, label: 'Mono'),
      ],
      outputs: [
        IspPortSpec(name: 'out_mono', type: IspPortType.mono, label: 'Mono'),
      ],
      params: [
        IspParamSpec(
          key: 'alpha',
          label: 'α（当前帧权重）',
          type: IspParamType.doubleNumber,
          defaultValue: 0.5,
          min: 0,
          max: 1,
        ),
        IspParamSpec(
          key: 'motionAdapt',
          label: '运动自适应',
          type: IspParamType.boolean,
          defaultValue: true,
        ),
      ],
    ),
    'pseudo_color': IspNodeType(
      typeId: 'pseudo_color',
      displayName: '伪彩映射',
      colorValue: 0xFF3E7E6E,
      inputs: [
        IspPortSpec(name: 'in_mono', type: IspPortType.mono, label: 'Mono'),
      ],
      outputs: [
        IspPortSpec(name: 'out', type: IspPortType.rgb, label: 'RGB'),
      ],
      params: [
        IspParamSpec(
          key: 'colormap',
          label: '色表',
          type: IspParamType.choice,
          defaultValue: 'green',
          options: ['green', 'magenta', 'hot'],
        ),
        IspParamSpec(
          key: 'gain',
          label: '增益',
          type: IspParamType.doubleNumber,
          defaultValue: 1.0,
          min: 0,
          max: 8,
        ),
      ],
    ),
    'fluoro_fusion': IspNodeType(
      typeId: 'fluoro_fusion',
      displayName: '荧光融合',
      colorValue: 0xFF2E8E7E,
      inputs: [
        IspPortSpec(name: 'in', type: IspPortType.rgb, label: '白光 RGB'),
        // 荧光输入不在视频互斥组（'in'/'in_yuv'/'in_hsl'/'in_mono'）内，
        // 可与 'in' 同时接入（白光 + 荧光双源链）。
        IspPortSpec(name: 'in_fluoro', type: IspPortType.mono, label: '荧光 Mono'),
      ],
      outputs: [
        IspPortSpec(name: 'out', type: IspPortType.rgb, label: 'RGB'),
      ],
      params: [
        IspParamSpec(
          key: 'mode',
          label: '模式',
          type: IspParamType.choice,
          defaultValue: 'alpha',
          options: ['alpha', 'contour'],
        ),
        IspParamSpec(
          key: 'threshold',
          label: '荧光门限',
          type: IspParamType.doubleNumber,
          defaultValue: 128.0,
          min: 0,
          max: 65535,
        ),
        IspParamSpec(
          key: 'alphaMax',
          label: '最大 α',
          type: IspParamType.doubleNumber,
          defaultValue: 0.8,
          min: 0,
          max: 1,
        ),
        IspParamSpec(
          key: 'colormap',
          label: '色表',
          type: IspParamType.choice,
          defaultValue: 'green',
          options: ['green', 'magenta', 'hot'],
        ),
        IspParamSpec(
          key: 'offsetX',
          label: '配准偏移 X',
          type: IspParamType.doubleNumber,
          defaultValue: 0.0,
          min: -64,
          max: 64,
        ),
        IspParamSpec(
          key: 'offsetY',
          label: '配准偏移 Y',
          type: IspParamType.doubleNumber,
          defaultValue: 0.0,
          min: -64,
          max: 64,
        ),
      ],
    ),
    'demosaic': IspNodeType(
      typeId: 'demosaic',
      displayName: '去马赛克',
      colorValue: 0xFF6E5A4E,
      inputs: [
        IspPortSpec(name: 'in', type: IspPortType.bayer, label: 'Bayer'),
      ],
      outputs: [
        IspPortSpec(name: 'out', type: IspPortType.rgb, label: 'RGB'),
      ],
      params: [
        IspParamSpec(
          key: 'algorithm',
          label: '算法',
          type: IspParamType.choice,
          defaultValue: 'bilinear',
          options: ['bilinear'],
        ),
      ],
    ),
    'white_balance': IspNodeType(
      typeId: 'white_balance',
      displayName: '白平衡',
      colorValue: 0xFF4E5A6E,
      inputs: [
        IspPortSpec(name: 'in', type: IspPortType.rgb, label: 'RGB'),
      ],
      outputs: [
        IspPortSpec(name: 'out', type: IspPortType.rgb, label: 'RGB'),
      ],
      params: [
        IspParamSpec(
          key: 'mode',
          label: '模式',
          type: IspParamType.choice,
          defaultValue: 'auto',
          options: ['manual', 'auto'],
        ),
        IspParamSpec(
          key: 'rGain',
          label: 'R 增益',
          type: IspParamType.doubleNumber,
          defaultValue: 1.0,
          min: 0.1,
          max: 8,
        ),
        IspParamSpec(
          key: 'bGain',
          label: 'B 增益',
          type: IspParamType.doubleNumber,
          defaultValue: 1.0,
          min: 0.1,
          max: 8,
        ),
      ],
    ),
    'ccm': IspNodeType(
      typeId: 'ccm',
      displayName: '色彩校正 CCM',
      colorValue: 0xFF5A4E6E,
      inputs: [
        IspPortSpec(name: 'in', type: IspPortType.rgb, label: 'RGB'),
      ],
      outputs: [
        IspPortSpec(name: 'out', type: IspPortType.rgb, label: 'RGB'),
      ],
      params: [
        IspParamSpec(
          key: 'matrix',
          label: '3x3 矩阵',
          type: IspParamType.matrix3,
          defaultValue: <double>[1, 0, 0, 0, 1, 0, 0, 0, 1],
        ),
      ],
    ),
    'gamma': IspNodeType(
      typeId: 'gamma',
      displayName: 'Gamma/色调',
      colorValue: 0xFF6E4E5A,
      inputs: [
        IspPortSpec(name: 'in', type: IspPortType.rgb, label: 'RGB'),
      ],
      outputs: [
        IspPortSpec(name: 'out', type: IspPortType.rgb, label: 'RGB'),
      ],
      params: [
        IspParamSpec(
          key: 'gamma',
          label: 'Gamma',
          type: IspParamType.doubleNumber,
          defaultValue: 2.2,
          min: 0.5,
          max: 5,
        ),
        IspParamSpec(
          key: 'brightness',
          label: '亮度',
          type: IspParamType.doubleNumber,
          defaultValue: 0.0,
          min: -0.5,
          max: 0.5,
        ),
        IspParamSpec(
          key: 'contrast',
          label: '对比度',
          type: IspParamType.doubleNumber,
          defaultValue: 1.0,
          min: 0.2,
          max: 3,
        ),
      ],
    ),
    'preview': IspNodeType(
      typeId: 'preview',
      displayName: '预览',
      colorValue: 0xFF4E6E66,
      inputs: [
        IspPortSpec(name: 'in', type: IspPortType.rgb, label: 'RGB'),
        IspPortSpec(name: 'in_yuv', type: IspPortType.yuv, label: 'YUV'),
        IspPortSpec(name: 'in_hsl', type: IspPortType.hsl, label: 'HSL'),
        IspPortSpec(name: 'in_mono', type: IspPortType.mono, label: 'Mono'),
      ],
      outputs: [
        // 透传节点：四个输出端口送出的是同一帧，格式与输入一致。
        IspPortSpec(name: 'out', type: IspPortType.rgb, label: 'RGB'),
        IspPortSpec(name: 'out_yuv', type: IspPortType.yuv, label: 'YUV'),
        IspPortSpec(name: 'out_hsl', type: IspPortType.hsl, label: 'HSL'),
        IspPortSpec(name: 'out_mono', type: IspPortType.mono, label: 'Mono'),
      ],
      params: [
        IspParamSpec(
          key: 'fps',
          label: '播放帧率',
          type: IspParamType.intNumber,
          // 默认 30；视频源打开文件时自动填充为视频原生帧率。
          defaultValue: 30,
          min: 1,
          max: 60,
        ),
        IspParamSpec(
          key: 'frameCount',
          label: '预览帧数',
          type: IspParamType.intNumber,
          // 预览/播放只取源文件前 N 帧；超过文件实际帧数时按实际帧数。
          defaultValue: 30,
          min: 1,
          max: 100000,
        ),
      ],
    ),
    'histogram': IspNodeType(
      typeId: 'histogram',
      displayName: '直方图',
      colorValue: 0xFF6E5A7A,
      inputs: [
        IspPortSpec(name: 'in', type: IspPortType.rgb, label: 'RGB'),
        IspPortSpec(name: 'in_yuv', type: IspPortType.yuv, label: 'YUV'),
        IspPortSpec(name: 'in_hsl', type: IspPortType.hsl, label: 'HSL'),
        IspPortSpec(name: 'in_mono', type: IspPortType.mono, label: 'Mono'),
      ],
    ),
    'waveform': IspNodeType(
      typeId: 'waveform',
      displayName: '示波器',
      colorValue: 0xFF4A6E5E,
      inputs: [
        IspPortSpec(name: 'in', type: IspPortType.rgb, label: 'RGB'),
        IspPortSpec(name: 'in_yuv', type: IspPortType.yuv, label: 'YUV'),
        IspPortSpec(name: 'in_hsl', type: IspPortType.hsl, label: 'HSL'),
        IspPortSpec(name: 'in_mono', type: IspPortType.mono, label: 'Mono'),
      ],
    ),
    'vectorscope': IspNodeType(
      typeId: 'vectorscope',
      displayName: '矢量示波器',
      colorValue: 0xFF3E5A7A,
      inputs: [
        IspPortSpec(name: 'in', type: IspPortType.rgb, label: 'RGB'),
        IspPortSpec(name: 'in_yuv', type: IspPortType.yuv, label: 'YUV'),
        IspPortSpec(name: 'in_hsl', type: IspPortType.hsl, label: 'HSL'),
        IspPortSpec(name: 'in_mono', type: IspPortType.mono, label: 'Mono'),
      ],
    ),
    'image_output': IspNodeType(
      typeId: 'image_output',
      displayName: '图片输出',
      colorValue: 0xFF6E664E,
      inputs: [
        IspPortSpec(name: 'in', type: IspPortType.rgb, label: 'RGB'),
        IspPortSpec(name: 'in_yuv', type: IspPortType.yuv, label: 'YUV'),
        IspPortSpec(name: 'in_hsl', type: IspPortType.hsl, label: 'HSL'),
        IspPortSpec(name: 'in_mono', type: IspPortType.mono, label: 'Mono'),
      ],
      params: [
        IspParamSpec(
          key: 'format',
          label: '格式',
          type: IspParamType.choice,
          defaultValue: 'jpg',
          options: ['jpg', 'png'],
        ),
        IspParamSpec(
          key: 'quality',
          label: '质量',
          type: IspParamType.intNumber,
          defaultValue: 100,
          min: 1,
          max: 100,
        ),
        IspParamSpec(
          key: 'directory',
          label: '输出目录',
          type: IspParamType.filePath,
          // 默认输出到项目根目录下 IspFlow/ImageOut（相对工作目录）。
          defaultValue: 'IspFlow/ImageOut',
        ),
        IspParamSpec(
          key: 'fileName',
          label: '文件名',
          type: IspParamType.text,
          defaultValue: 'isp_{frame}',
        ),
      ],
    ),
    'audio_level': IspNodeType(
      typeId: 'audio_level',
      displayName: '音频电平',
      colorValue: 0xFF4E7E8E,
      inputs: [
        IspPortSpec(name: 'in', type: IspPortType.audio, label: 'Audio'),
      ],
      // 无参数：当前位置前 50ms 窗的各声道峰值电平（dB 刻度）。
    ),
    'audio_waveform': IspNodeType(
      typeId: 'audio_waveform',
      displayName: '音频波形',
      colorValue: 0xFF5E5E9E,
      inputs: [
        IspPortSpec(name: 'in', type: IspPortType.audio, label: 'Audio'),
      ],
      // 无参数：当前位置前 ~92ms 窗的逐列 min/max 波形（L/R 两行）。
    ),
    'audio_eq': IspNodeType(
      typeId: 'audio_eq',
      displayName: '音频EQ频谱',
      colorValue: 0xFF7E5E9E,
      inputs: [
        IspPortSpec(name: 'in', type: IspPortType.audio, label: 'Audio'),
      ],
      // 无参数：当前位置前 2048 样本 FFT，左右 L/R 两组各 31 段
      // （20Hz–20kHz 1/3 倍频程），每段下方标注中心频率。
    ),
    'video_output': IspNodeType(
      typeId: 'video_output',
      displayName: '视频输出',
      colorValue: 0xFF3E5E6E,
      inputs: [
        IspPortSpec(name: 'in', type: IspPortType.rgb, label: 'RGB'),
        IspPortSpec(name: 'in_yuv', type: IspPortType.yuv, label: 'YUV'),
        IspPortSpec(name: 'in_hsl', type: IspPortType.hsl, label: 'HSL'),
        IspPortSpec(name: 'in_mono', type: IspPortType.mono, label: 'Mono'),
      ],
      params: [
        IspParamSpec(
          key: 'fps',
          label: '帧率',
          type: IspParamType.intNumber,
          defaultValue: 30,
          min: 1,
          max: 120,
        ),
        IspParamSpec(
          key: 'crf',
          label: 'CRF',
          type: IspParamType.intNumber,
          defaultValue: 18,
          min: 0,
          max: 51,
        ),
        IspParamSpec(
          key: 'encoder',
          label: '编码器',
          type: IspParamType.choice,
          // x264_fast = libx264 veryfast 预设；nvenc = NVIDIA GPU（用 -cq）。
          defaultValue: 'x264',
          options: ['x264', 'x264_fast', 'nvenc'],
        ),
        IspParamSpec(
          key: 'filePath',
          label: '输出文件',
          type: IspParamType.filePath,
          // 默认输出到项目根目录下 IspFlow/VideoOut（相对工作目录）。
          defaultValue: 'IspFlow/VideoOut/output.mp4',
        ),
        IspParamSpec(
          key: 'ffmpegPath',
          label: 'ffmpeg 路径',
          type: IspParamType.text,
          // 默认用项目内置的 ffmpeg（tools/ffmpeg/ffmpeg.exe）。
          defaultValue: 'tools/ffmpeg/ffmpeg.exe',
        ),
      ],
    ),
    // ---- Datapath 分路器 & 合路器 ----
    'rgb_splitter': IspNodeType(
      typeId: 'rgb_splitter',
      displayName: 'RGB 分路器',
      colorValue: 0xFF3E6E5E,
      inputs: [
        IspPortSpec(name: 'in', type: IspPortType.rgb, label: 'RGB'),
      ],
      outputs: [
        IspPortSpec(name: 'out_r', type: IspPortType.r, label: 'R'),
        IspPortSpec(name: 'out_g', type: IspPortType.g, label: 'G'),
        IspPortSpec(name: 'out_b', type: IspPortType.b, label: 'B'),
      ],
    ),
    'yuv_splitter': IspNodeType(
      typeId: 'yuv_splitter',
      displayName: 'YUV 分路器',
      colorValue: 0xFF3E5E7E,
      inputs: [
        IspPortSpec(name: 'in', type: IspPortType.yuv, label: 'YUV'),
      ],
      outputs: [
        IspPortSpec(name: 'out_y', type: IspPortType.y, label: 'Y'),
        IspPortSpec(name: 'out_u', type: IspPortType.u, label: 'U'),
        IspPortSpec(name: 'out_v', type: IspPortType.v, label: 'V'),
      ],
    ),
    'hsl_splitter': IspNodeType(
      typeId: 'hsl_splitter',
      displayName: 'HSL 分路器',
      colorValue: 0xFF7E3E5E,
      inputs: [
        IspPortSpec(name: 'in', type: IspPortType.hsl, label: 'HSL'),
      ],
      outputs: [
        IspPortSpec(name: 'out_h', type: IspPortType.h, label: 'H'),
        IspPortSpec(name: 'out_s', type: IspPortType.s, label: 'S'),
        IspPortSpec(name: 'out_l', type: IspPortType.l, label: 'L'),
      ],
    ),
    'rgb_combiner': IspNodeType(
      typeId: 'rgb_combiner',
      displayName: 'RGB 合路器',
      colorValue: 0xFF4E7E6E,
      inputs: [
        IspPortSpec(name: 'in_r', type: IspPortType.r, label: 'R'),
        IspPortSpec(name: 'in_g', type: IspPortType.g, label: 'G'),
        IspPortSpec(name: 'in_b', type: IspPortType.b, label: 'B'),
      ],
      outputs: [
        IspPortSpec(name: 'out', type: IspPortType.rgb, label: 'RGB'),
      ],
    ),
    'yuv_combiner': IspNodeType(
      typeId: 'yuv_combiner',
      displayName: 'YUV 合路器',
      colorValue: 0xFF4E6E7E,
      inputs: [
        IspPortSpec(name: 'in_y', type: IspPortType.y, label: 'Y'),
        IspPortSpec(name: 'in_u', type: IspPortType.u, label: 'U'),
        IspPortSpec(name: 'in_v', type: IspPortType.v, label: 'V'),
      ],
      outputs: [
        IspPortSpec(name: 'out', type: IspPortType.yuv, label: 'YUV'),
      ],
    ),
    'hsl_combiner': IspNodeType(
      typeId: 'hsl_combiner',
      displayName: 'HSL 合路器',
      colorValue: 0xFF7E4E6E,
      inputs: [
        IspPortSpec(name: 'in_h', type: IspPortType.h, label: 'H'),
        IspPortSpec(name: 'in_s', type: IspPortType.s, label: 'S'),
        IspPortSpec(name: 'in_l', type: IspPortType.l, label: 'L'),
      ],
      outputs: [
        IspPortSpec(name: 'out', type: IspPortType.hsl, label: 'HSL'),
      ],
    ),
  };

  static IspNodeType? byId(String typeId) => types[typeId];
}

/// 仪器类节点（直方图/示波器/矢量示波器）：只进不出的分析汇点，
/// 节点内嵌分析结果显示区。
const instrumentTypes = {'histogram', 'waveform', 'vectorscope'};

/// 音频类仪器节点（电平/波形/EQ 频谱）：数据来自视频音轨 PCM 而非
/// 图像帧，走独立的刷新路径（isp_studio_state._runAudioInstruments）。
const audioInstrumentTypes = {
  'audio_level',
  'audio_waveform',
  'audio_eq',
};

/// 全部仪器类节点（图像仪器 + 音频仪器）：只进不出、内嵌显示区。
const allInstrumentTypes = {...instrumentTypes, ...audioInstrumentTypes};

/// 透传汇点节点（不改变帧数据）：预览 / 仪器 / 音频仪器 / 图片输出 /
/// 视频输出。
const sinkNodeTypes = {
  'preview',
  ...instrumentTypes,
  ...audioInstrumentTypes,
  'image_output',
  'video_output',
};
