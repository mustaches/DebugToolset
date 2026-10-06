/// ISP 编组「生成Verilog IP」的 FPGA 厂商目标体系（与 C 代码导出的 CPU
/// 目标 `GroupCTarget` 是两套并列体系，互不沿用；厂商元数据仿
/// `group_c_target.dart` 的 `GroupCTargetInfo` extension 单独定义）。
library;

/// FPGA 厂商目标。v1 实现 Vivado / Libero / 通用 Verilog；Quartus / Lattice /
/// Efinix 列出但禁用并标注「待完成」（对话框下拉项灰显）。
enum IpVendor {
  vivado('AMD/Xilinx Vivado', 'Vivado', true,
      '用 package_ip.tcl 在 Vivado 打包导入；双击 IP 可用 Customize IP 界面改参数。'),
  quartus('Intel Quartus', 'Quartus', false, '待完成'),
  libero('Microchip Libero', 'Libero', true,
      '顶层为 valid/ready 裸流封装；参数在 SmartDesign generics 面板可见可改。'),
  lattice('Lattice Radiant/Diamond', 'Lattice', false, '待完成'),
  efinix('Efinix Efinity', 'Efinix', false, '待完成'),
  generic('通用 Verilog', '通用', true,
      '核心模块直接即顶层（像素流 in/out）；可直接级联或接入自定义测试环境。');

  const IpVendor(
      this.displayName, this.shortName, this.enabled, this.importNote);

  final String displayName;
  final String shortName;
  final bool enabled;
  final String importNote;

  bool get isVivado => this == vivado;
  bool get isLibero => this == libero;
}

/// IP 生成选项（应用内对话框采集的「出厂默认」——写入生成的 `parameter`
/// 默认值；用户在 Vivado Customize IP 界面可再次修改）。顶层参数与
/// 视频输入物理层选择由此驱动。
class IpGenOptions {
  final IpVendor vendor;

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

  const IpGenOptions({
    required this.vendor,
    this.vinType = 'none',
    this.pixBits = 0,
    this.maxWidth = 4096,
    this.gstrategy = 2,
    this.fold = 2,
  });
}

/// 会话级「编组 id → IP 生成选项」缓存（仿 c_compile.dart 的顶层
/// sessionCompilerPaths，非 state 字段）：同一编组重开 IP 标签页时回填
/// 上次厂商/参数选择。
final Map<String, IpGenOptions> sessionIpGenOptions = {};
