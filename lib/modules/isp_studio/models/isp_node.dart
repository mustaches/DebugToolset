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
}

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

/// 图中的节点实例。
class IspNode {
  final String id;
  final String typeId;
  double x;
  double y;

  /// 节点卡片宽度（画布坐标）。预览节点可通过右下角控制点调宽，
  /// 输出端口与连线几何以该值为准。
  double width;
  final Map<String, Object?> paramValues;

  IspNode({
    required this.id,
    required this.typeId,
    required this.x,
    required this.y,
    this.width = kNodeWidth,
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
abstract final class IspNodeRegistry {  /// CIS RAW 源节点的公共参数（文件/分辨率/位深/打包/端序/起始帧）。
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
        IspPortSpec(name: 'out', type: IspPortType.rgb, label: 'RGB'),
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
        // 音轨输出：接到「音频输出」节点仅作流程示意；预览播放时
        // 含音轨即自动回放（不依赖该连接）。
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
      ],
      outputs: [
        IspPortSpec(name: 'out', type: IspPortType.bayer, label: 'Bayer'),
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
      ],
      outputs: [
        // 透传节点：三个输出端口送出的是同一帧，格式与输入一致。
        IspPortSpec(name: 'out', type: IspPortType.rgb, label: 'RGB'),
        IspPortSpec(name: 'out_yuv', type: IspPortType.yuv, label: 'YUV'),
        IspPortSpec(name: 'out_hsl', type: IspPortType.hsl, label: 'HSL'),
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
    'audio_output': IspNodeType(
      typeId: 'audio_output',
      displayName: '音频输出',
      colorValue: 0xFF6E5E8E,
      inputs: [
        IspPortSpec(name: 'in', type: IspPortType.audio, label: 'Audio'),
      ],
      // 无参数：视频预览播放时含音轨即自动回放（MCI），该节点仅
      // 在流程图上表达音频流向。
    ),
    'video_output': IspNodeType(
      typeId: 'video_output',
      displayName: '视频输出 MP4',
      colorValue: 0xFF3E5E6E,
      inputs: [
        IspPortSpec(name: 'in', type: IspPortType.rgb, label: 'RGB'),
        IspPortSpec(name: 'in_yuv', type: IspPortType.yuv, label: 'YUV'),
        IspPortSpec(name: 'in_hsl', type: IspPortType.hsl, label: 'HSL'),
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
  };

  static IspNodeType? byId(String typeId) => types[typeId];
}

/// 仪器类节点（直方图/示波器/矢量示波器）：只进不出的分析汇点，
/// 节点内嵌分析结果显示区。
const instrumentTypes = {'histogram', 'waveform', 'vectorscope'};

/// 透传汇点节点（不改变帧数据）：预览 / 仪器 / 图片输出 / 视频输出 /
/// 音频输出。
const sinkNodeTypes = {
  'preview',
  ...instrumentTypes,
  'image_output',
  'video_output',
  'audio_output',
};
