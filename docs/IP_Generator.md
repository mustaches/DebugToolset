# ISP Studio IP Generator（编组 → FPGA Verilog IP 包）

ISP Studio 编组右键菜单「生成Verilog IP」：把编组（像素流式子图）导出为可
综合 Verilog IP 包，针对 FPGA 行级实时处理优化。实时性 ↔ RTL 规模的权衡
暴露为 IP 定制参数（Verilog `parameter`，Vivado 等工具的 Customize IP 界面
可直接改）。

## 当前范围（v1）

- **节点**：`multi_band_eq`（`codegenMode=lut_fixed` Q14 定点）；其余节点按
  计划（`docs/IP_Generator_Plan.md` 白名单）逐步扩展。
- **目标平台**：Vivado / Libero / 通用 Verilog（Quartus/Lattice/Efinix 列出
  但禁用标注「待完成」）。
- **视频输入**：`none`（直通，核心像素流端口直出）；DVP/LVDS/MIPI CSI-2 留
  后续。
- **验证**：testbench + 一键仿真（探测 Icarus Verilog，有一键跑 PASS/FAIL，
  没有只出文件）。

## 使用

1. 编组（单节点 `multi_band_eq`，lut_fixed）上右键 →「生成Verilog IP」。
2. 校验不过弹错误；通过则弹生成选项对话框（厂商 / `PIX_BITS` / `MAX_WIDTH`）。
3. 确定后打开 IP 标签页：左侧文件清单、右侧 Verilog 高亮代码区，工具栏
   「导出IP包」写盘、「一键仿真」跑 iverilog。

## 文件集（每组一个目录，top 名 `isp_ip_<组名净化>`）

| 文件 | 说明 |
|---|---|
| `isp_ip_<组>_core.v` | 流水线核心：通用像素流 in→out，全程 ready 握手；节点参数烘焙 |
| `isp_ip_<组>_top.v` | 顶层装配（`VIN_TYPE=none` 时透传核心端口） |
| `isp_ip_<组>_axis.v` | Vivado AXI4-Stream 封装（tuser=sof / tlast=eol） |
| `isp_ip_<组>_libero.v` | Libero 裸流封装（valid/ready 直通） |
| `tb_isp_ip_<组>.v` | testbench：`$readmemh` 输入 + FNV-1a 对拍（EXACT） |
| `golden_in.hex` | LCG 输入帧（64×48，应用内 Dart 生成） |
| `golden_hash.txt` | 期望 FNV-1a（32 位，uint16 小端逐字节） |
| `package_ip.tcl` | Vivado IP 打包脚本（含参数组） |
| `README.md` | 接口时序 / 参数表 / 资源估算 / 导入说明 |

## 接口（像素流）

核心模块输入/输出均为通用像素流，通道打包 `{H,S,L}`（H 在最高位段，每
通道 `PIX_BITS` 位）：

- `in_valid`/`in_ready`：输入握手，`advance = in_valid & in_ready`；
- `in_sof`/`in_eol`：帧起始/帧结束（与 `in_data` 同拍有效）；
- `out_valid`/`out_ready`/`out_sof`/`out_eol`/`out_data`：输出同形，1 拍
  流水延迟（II=1，每时钟 1 像素）。

## 定点口径（multi_band_eq lut_fixed）

- 三张 ROM：H 偏移（16 位补码）、S/L 乘子 Q14（各 17 位），深度 `2^PIX_BITS`；
- 逐像素：H 钳上界 → 查 shift 表 → 色环回绕（单次条件加减，与 `% (MAXV+1)`
  逐位一致）→ S/L `(in*q+8192)>>14` 后钳位；
- 与 C 侧 `bb_clamp_q14` 逐位一致；ROM 表由 Dart 侧 `multiBandLuts` 烘焙。

## 一键仿真

```
iverilog -g2012 -o tb.vvp tb_isp_ip_<组>.v isp_ip_<组>_core.v isp_ip_<组>_top.v
vvp tb.vvp      # 输出 PASS/FAIL（EXACT 逐位 FNV-1a 对拍），并转储 wave.vcd
```

testbench 内含 `$dumpfile/$dumpvars` 波形转储；仿真结束后自动打开
ISP Studio 内嵌**「仿真波形」标签页**（Flutter 原生数字波形查看器：
解析 wave.vcd 后 CustomPaint 渲染，时钟/复位/IP I/O 信号默认展示，
拖动平移、滚轮缩放、单击光标、双击 Zoom Fit）。工具链随安装包内置
（`tools/iverilog/` + `tools/surfer/`，安装版开箱即用）；标签页工具栏
可改由外部查看器打开：Surfer（经 `wave.sucl` 启动命令文件自动加载
同一批信号）→ GTKWave（经 `wave.gtkw` 保存文件）。无 iverilog 时 UI
探测行提示安装（导出功能不受影响）。

## 电路图浏览

IP 标签页工具栏「电路图浏览」打开**「电路图」标签页**（`sch:` 前缀），
含两种视图（工具栏左侧切换）：

- **模块框图**（默认）：由编组规划 IR 直绘的模块级框图（Vivado
  Elaborated Design 风格）——实例块带端口针脚、网表三段正交肘线连线、
  位宽标注，输入/输出端口组钉在左右缘，节点按拓扑层级分列；点节点块
  可打开其代码页。零工具链依赖，即时显示。
- **RTL 网表**：yosys + netlistsvg 管线渲染的实际网表电路图（首次
  切换时懒触发）：

```
yosys -p "read_verilog <各 .v>; hierarchy -top <最外层封装>; proc; opt_clean; write_json net.json"
node netlistsvg.js net.json -o sch.svg
```

页内嵌 SVG 浏览（拖动平移、滚轮缩放），工具栏含「重新生成」「导出SVG」
与日志面板开关。顶层封装按厂商选择：Vivado 取 `*_axis`，Libero 取
`*_libero`，通用取 `*_top`。工具链随安装包内置（`tools/yosys/` +
`tools/netlistsvg/`，安装版开箱即用；重建方式见 `tools/README.md`）；
缺失时 RTL 视图提示安装（框图视图不受影响）。

## 导入说明

- **Vivado**：`vivado -mode batch -source package_ip.tcl` 打包 → `./ip_repo`；
  双击 IP 用 Customize IP 界面改 `PIX_BITS`/`MAX_WIDTH`。
- **Libero**：顶层为 valid/ready 裸流封装；参数在 SmartDesign generics 面板
  可见可改。
- **通用**：核心模块直接即顶层，可级联或接入自定义测试环境。
