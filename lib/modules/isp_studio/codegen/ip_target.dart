/// ISP 编组「生成Verilog IP」的 FPGA 厂商目标体系（与 C 代码导出的 CPU
/// 目标 `GroupCTarget` 是两套并列体系，互不沿用；厂商元数据仿
/// `group_c_target.dart` 的 `GroupCTargetInfo` extension 单独定义）。
library;

/// FPGA 厂商目标。v1 实现 Vivado / 通用 Verilog；Quartus / Libero /
/// Lattice / Efinix 列出但禁用并标注「待完成」（对话框下拉项灰显不可选）。
enum IpVendor {
  vivado(
    'AMD/Xilinx Vivado',
    'Vivado',
    true,
    '用 package_ip.tcl 在 Vivado 打包导入；双击 IP 可用 Customize IP 界面改参数。',
  ),
  quartus('Intel Quartus', 'Quartus', false, '待完成'),
  libero('Microchip Libero', 'Libero', false, '待完成'),
  lattice('Lattice Radiant/Diamond', 'Lattice', false, '待完成'),
  efinix('Efinix Efinity', 'Efinix', false, '待完成'),
  generic('通用 Verilog', '通用', true, '核心模块直接即顶层（像素流 in/out）；可直接级联或接入自定义测试环境。');

  const IpVendor(
    this.displayName,
    this.shortName,
    this.enabled,
    this.importNote,
  );

  final String displayName;
  final String shortName;
  final bool enabled;
  final String importNote;

  bool get isVivado => this == vivado;
  bool get isLibero => this == libero;
}

/// Vivado 器件系列（对话框中仅 Vivado 厂商时显示）：驱动 package_ip.tcl
/// 的 `create_project -part` 与 `supported_families`。
/// 注：Spartan6/Virtex6 为 ISE 器件族，Vivado 无对应 part，仅作系列标注
/// 导出（part 字段仍给代表型号，供需要时人工替换）。
enum VivadoSeries {
  spartan6('Spartan6', 'xc6slx45-fgg484-2', 'spartan6'),
  virtex6('Virtex6', 'xc6vlx240t-ff1156-1', 'virtex6'),
  spartan7('Spartan7', 'xc7s50-csga324-1', 'spartan7'),
  artix7('Artix7', 'xc7a100t-csg324-1', 'artix7'),
  kintex7('Kintex7', 'xc7k325t-ffg900-2', 'kintex7'),
  virtex7('Virtex7', 'xc7v585t-ffg1157-1', 'virtex7'),
  zynq7000('Zynq7000_SOC', 'xc7z020-clg484-1', 'zynq'),
  zynqUltrascalePlus(
    'Zynq UltraScale+ MPSoC',
    'xczu15eg-ffvb1156-2-i',
    'zynquplus',
  ),
  versalAiCore('Versal AI Core Series', 'xcvc1902-vsva2197-2MP-e-S', 'versal');

  const VivadoSeries(this.displayName, this.part, this.supportedFamilies);

  final String displayName;

  /// package_ip.tcl 的 `create_project -part` 代表型号。
  final String part;

  /// package_ip.tcl 的 `supported_families` 值。
  final String supportedFamilies;
}

/// MAX_WIDTH 的可选值，两个导出对话框与 Vivado 参数校验共用。
const kIpMaxWidthOptions = [
  320,
  400,
  600,
  640,
  1000,
  1280,
  1920,
  2048,
  3840,
  4096,
  7680,
  8192,
];

String effectiveYuvStandard(String option, String nodeValue) =>
    option == 'auto' || option.isEmpty ? nodeValue : option;

int yuvStandardCode(String standard) => switch (standard) {
  'bt709' => 1,
  'bt2020' || 'bt2100' => 2,
  _ => 0,
};

/// IP 生成选项（应用内对话框采集的「出厂默认」——写入生成的 `parameter`
/// 默认值；用户在 Vivado Customize IP 界面可再次修改）。顶层参数与
/// 视频输入物理层选择由此驱动。
class IpGenOptions {
  final IpVendor vendor;

  /// Vivado 器件系列（仅 vendor == vivado 时有意义）。
  final VivadoSeries series;

  /// Vivado 具体器件型号；空字符串表示使用器件系列的代表型号。
  final String targetPart;

  /// 具体器件的 Vivado family；空字符串表示使用系列默认值。
  final String targetFamily;

  /// 用户选择的 Vivado 可执行文件；空字符串表示自动使用最新版本。
  final String vivadoExecutable;

  String get vivadoPart => targetPart.isEmpty ? series.part : targetPart;
  String get vivadoFamily =>
      targetFamily.isEmpty ? series.supportedFamilies : targetFamily;

  /// 视频输入接口：`none`（直通）/ `dvp` / `lvds` / `mipi`（v1 仅 none）。
  final String vinType;

  /// 像素位宽；0 = 位深推导（沿源节点 bitDepth 追溯，默认）。
  final int pixBits;

  /// 行缓冲最大行宽（BRAM 用量报表/参数）。
  final int maxWidth;

  /// 窗口算子实现分档：0 面积 / 1 平衡 / 2 性能（v1 点操作无窗口，参数
  /// 保留备用）。
  final int gstrategy;

  /// 窗口算子折叠因子（面积档生效；v1 保留备用）。
  final int fold;

  /// func_fixed 流水模式：0 纯组合 / 1 前段插一拍 / 2 前段+中段各插一拍 /
  /// 3 DSP 内部全流水（最高 Fmax）。写入顶层 `parameter DSP_PIPE` 默认值，
  /// Vivado Customize IP 界面可再改（选通结构经综合折叠，改值即生效）。
  final int dspPipe;

  /// YUV→RGB 系数标准：auto（跟随 ispflow 节点）/ bt601 / bt709 / bt2020。
  final String yuvStandard;

  /// 色温 IP 的表存储方式（生成期选项）：true = Block RAM（省 CLB LUT，
  /// 默认），false = 组合 ROM（上一版实现，LUT 用量大但对时序无读延迟）。
  /// 两者表数据与插值写法相同，结果逐位一致；生成后不可再切换（要另一种
  /// 实现需重新导出）。
  final bool useBram;

  /// Vivado 演示工程名，同时作为工程目录与 .xpr 文件名。
  final String projectName;

  const IpGenOptions({
    required this.vendor,
    this.series = VivadoSeries.zynqUltrascalePlus,
    this.targetPart = '',
    this.targetFamily = '',
    this.vivadoExecutable = '',
    this.vinType = 'none',
    this.pixBits = 0,
    this.maxWidth = 3840,
    this.gstrategy = 2,
    this.fold = 2,
    this.dspPipe = 3,
    this.yuvStandard = 'auto',
    this.useBram = true,
    this.projectName = 'demo_prj',
  });
}

/// 会话级「编组 id → IP 生成选项」缓存（仿 c_compile.dart 的顶层
/// sessionCompilerPaths，非 state 字段）：同一编组重开 IP 标签页时回填
/// 上次厂商/参数选择。
final Map<String, IpGenOptions> sessionIpGenOptions = {};
