# ISP_IP_HSL_to_RGB V2.0 User Guide

本文说明 HSL→RGB 定点转换 IP（`ISP_IP_HSL_to_RGB`）V2.0 的配置项、端口、
数据格式、转换公式和时序行为。该 IP 接收 `{H, S, L}` 三通道像素流，输出
`{R, G, B}` 三通道像素流（三段色相支路 + 双线性 hue 插值）。

界面分为 **General** 和 **Optimization** 两个标签页，所有参数均使用下拉菜单。
核心采用全整数定点运算，支持 ready/valid 背压和 II=1 吞吐。HSL→RGB 全程
只有乘法与移位，**没有除法器**。

> 实现方式（函数定点或 LUT 归一化）在 ISP Studio 导出 IP 时按节点的
> `codegenMode` 选择，并烘焙进 IP。Vivado 的 Customize IP 不再切换实现方式。
>
> 本 IP 只做 HSL→RGB，**不涉及 YUV 矩阵**，因此没有 `YUV_STANDARD`
> 配置项，也没有 YUV 相关端口。

## 配置项速查

| 标签页 | 配置项 | 可选值 | 主要作用 |
|---|---|---|---|
| General | Pixel Bits (`PIX_BITS`) | 8、10、12、14、16 | 设置 H/S/L 与 R/G/B 每个通道的位宽 |
| General | Max Width (`MAX_WIDTH`) | 320～8192，按列表选择 | 预留的最大行宽参数；当前逐像素转换不使用行缓冲 |
| Optimization | Multiply Strategy (`GSTRATEGY`) | Area、Balanced、Performance | Area 走组合函数并绑定 LUT；Balanced/Performance 允许使用专用 DSP 通路 |
| Optimization | Fold Factor (`FOLD`) | x1、x2、x4 | 预留的窗口算子折叠因子；当前逐像素转换不使用 |
| Optimization | DSP Pipeline (`DSP_PIPE`) | 0、1、2、3 | 3 启用 HSL→RGB 专用 DSP 全流水路径；0～2 为基础实现 |

---

## IO 接口与数据格式

### 时钟、复位与 AXI4-Stream 像素流

Vivado 封装顶层为 `ISP_IP_HSL_to_RGB`。所有端口工作在 `aclk` 时钟域；
`aresetn` 为低电平有效复位。

| 端口 | 方向 | 位宽 | 说明 |
|---|---|---:|---|
| `aclk` | 输入 | 1 | 像素流时钟 |
| `aresetn` | 输入 | 1 | 低有效复位；正常工作时保持 1 |
| `s_axis_tdata` | 输入 | `3×PIX_BITS` | 输入 HSL 像素，打包格式见下节 |
| `s_axis_tvalid` | 输入 | 1 | 输入数据有效 |
| `s_axis_tready` | 输出 | 1 | IP 可接收输入 |
| `s_axis_tuser` | 输入 | 1 | 帧起始 SOF，与一帧的第一个像素同拍有效 |
| `s_axis_tlast` | 输入 | 1 | 行结束 EOL，与一行最后一个像素同拍有效 |
| `m_axis_tdata` | 输出 | `3×PIX_BITS` | 输出 RGB 像素，打包格式见下节 |
| `m_axis_tvalid` | 输出 | 1 | 输出数据有效 |
| `m_axis_tready` | 输入 | 1 | 下游可接收；为 0 时 IP 保持输出并暂停内部流水 |
| `m_axis_tuser` | 输出 | 1 | 与输出像素对应的 SOF |
| `m_axis_tlast` | 输出 | 1 | 与输出像素对应的 EOL |

握手规则：

- 输入侧在 `s_axis_tvalid=1` 且 `s_axis_tready=1` 的时钟上升沿接收一个像素。
- 输出侧在 `m_axis_tvalid=1` 且 `m_axis_tready=1` 时完成一次输出传输。
- `m_axis_tvalid=1`、`m_axis_tready=0` 时，输出数据和 `tuser/tlast` 保持不变。
- `tuser/tlast` 不参与颜色运算，但必须随对应像素输入；IP 会保持 SOF/EOL 对位。
- 流水填满后吞吐为 II=1，即每时钟一个像素。
- 全过程支持随机输入气泡与输出背压，不会丢像素或错拍（逐级弹性流水）。

### HSL 输入和 RGB 输出位域

令 `PB=PIX_BITS`、`MAXV=2^PB-1`。输入按 **`{H, S, L}`** 打包，输出按
**`{R, G, B}`** 打包，均把第一个通道放在最高位段。

| 位域 | 通道 | 数值含义 |
|---|---|---|
| `s_axis_tdata[3×PB-1 : 2×PB]` | H | 色相，0～`MAXV` 对应 0°～360°（`MAXV` 与 0 同相位） |
| `s_axis_tdata[2×PB-1 : PB]` | S | 饱和度，0～`MAXV`；为 0 时输出灰色（R=G=B=L） |
| `s_axis_tdata[PB-1 : 0]` | L | 亮度（明度），0～`MAXV` |
| `m_axis_tdata[3×PB-1 : 2×PB]` | R | 红通道，已钳位到 0～`MAXV` |
| `m_axis_tdata[2×PB-1 : PB]` | G | 绿通道，已钳位到 0～`MAXV` |
| `m_axis_tdata[PB-1 : 0]` | B | 蓝通道，已钳位到 0～`MAXV` |

对于常用的 **24 bit / 8 bit 每通道**配置：

```text
输入：s_axis_tdata[23:0] = {H[7:0], S[7:0], L[7:0]}
输出：m_axis_tdata[23:0] = {R[7:0], G[7:0], B[7:0]}

bits  23       16 15        8 7         0
输入  +----------+-----------+-----------+
      |  H[7:0]  |  S[7:0]  |  L[7:0]  |
      +----------+-----------+-----------+
输出  +----------+-----------+-----------+
      |  R[7:0]  |  G[7:0]  |  B[7:0]  |
      +----------+-----------+-----------+
```

`PIX_BITS` 改变单通道宽度，三个通道始终等宽：

| PIX_BITS | 单通道位宽 | 接口总位宽 | `MAXV` | 色相量化步进 |
|---:|---:|---:|---:|---:|
| 8 | 8 | 24 | 255 | 360/255 ≈ 1.41° |
| 10 | 10 | 30 | 1023 | ≈ 0.352° |
| 12 | 12 | 36 | 4095 | ≈ 0.088° |
| 14 | 14 | 42 | 16383 | ≈ 0.022° |
| 16 | 16 | 48 | 65535 | ≈ 0.0055° |

### 定点转换公式

先把输入三通道归一化到 Q14（0～16384；`16384` 即 1.0）：

```text
h = round(H × 16384 / MAXV) % 16384
s = round(S × 16384 / MAXV)
l = round(L × 16384 / MAXV)
```

再按标准 HSL→RGB 定义计算（`round` 为四舍五入；`>>` 为算术右移）：

```text
if (s == 0)
  r = g = b = l
else
  q  = (l < 8192) ? l + ((l×s + 8192) >> 14)          // Q14 域 (1+s) 形
                  : l + s - ((l×s + 8192) >> 14)
  p  = 2l - q                                           // 2l 即 <<1
  h3 = 3h
  r  = hue(p, q, h3 + 16384)
  g  = hue(p, q, h3)
  b  = hue(p, q, h3 - 16384)

R = clamp(round(r × MAXV / 16384), 0, MAXV)
G = clamp(round(g × MAXV / 16384), 0, MAXV)
B = clamp(round(b × MAXV / 16384), 0, MAXV)
```

其中 `hue(p, q, t)` 先把 `t` 回绕到 `[0, 49152)`（负值 `+49152`），再按区间
选支路（`qm = q - p`）：

| `t` 区间 | 输出 |
|---|---|
| `t < 8192` | `p + round(qm × t / 8192)` |
| `8192 ≤ t < 24576` | `q` |
| `24576 ≤ t < 32768` | `p + round(qm × (32768 − t) / 8192)` |
| `t ≥ 32768` | `p` |

要点：

- `8192` 是 `16384/2`，即 Q14 域的半圈色相；三个支路覆盖 R/G/B 的上升沿、
  平台与下降沿，与浮点 `hue2rgb` 口径一致；
- 所有乘法都是「乘 + 加半值 + 移位」，**没有除法器**，结果与理想四舍五入
  除法逐位一致，不依赖综合器对 `/` 的处理；
- 与 ISP Studio 的 Dart 定点参考（`csc_fixed.dart` 的 `_hslToRgbQ14`）
  在 8 bit 全域 256³ 组合、10/12/16 bit 抽样上逐位一致。

### 与 RGB→HSL 的配合

- `ISP_IP_RGB_to_HSL` 与 `ISP_IP_HSL_to_RGB` 串联可做「HSL 域调色后还原」：
  两者在同一 `PIX_BITS` 下首尾相接时，`S = 0`/`MAXV`、`H` 环绕等边界行为
  与浮点实现一致；
- 直接把 HSL 当数据通道（例如传输 H/S/L 分量）时注意 `H` 是**量化色相**，
  转角度用 `H × 360 / MAXV`。

---

## 1. General 标签页

### 1.1 Pixel Bits（`PIX_BITS`）

**含义**

设置 H、S、L、R、G、B 每个通道的位宽。三个通道共用相同位宽，接口总位宽为
`3×PIX_BITS`。

**可选值**

`8`、`10`、`12`、`14`、`16` 位。

**影响**

- 位宽越高，色相分辨率越高，内部数据通路越宽。
- 位宽越低，逻辑和连线资源通常越少。
- 该参数不会改变图像分辨率或帧率。
- `PIX_BITS` 是综合参数；DEMO 的 `create_demo_project.tcl` 会把导出时的选择
  写入 `CONFIG.PIX_BITS`。

**建议**

- 常规 8 bit 视频链路选择 `8`。
- 与上游 RGB→HSL 或调色模块保持相同位宽，避免二次量化。
- 不建议仅为“精度显示”盲目选择 16 bit，应同时检查时序和资源报告。

### 1.2 Max Width（`MAX_WIDTH`）

**含义**

预留的最大行宽参数，供后续包含行缓冲或窗口操作的 IP 复用。

**当前作用**

HSL→RGB 是逐像素点算子，不使用行缓冲，因此改变 `MAX_WIDTH` 不改变本 IP 的
处理结果、资源或延迟。本 IP 仍保留该参数，以保持与其它 ISP IP 的通用参数
面板和 demo 生成流程一致。

---

## 2. Optimization 标签页

### 2.1 Multiply Strategy（`GSTRATEGY`）

| 可选值 | 值 | 说明 |
|---|---:|---|
| Area (folded operators) | 0 | 组合函数实现，模块级 `use_dsp="no"` 绑定 LUT：零 DSP 占用 |
| Balanced (synthesizer chooses) | 1 | 依赖 `DSP_PIPE`；=3 时启用专用 DSP 全流水通路 |
| Performance (use DSP) | 2 | 同 Balanced；默认，`DSP_PIPE=3` 时实际使用 7 个 DSP48E2 |

在 func_fixed 且 `GSTRATEGY!=0`、`DSP_PIPE=3` 时，HSL→RGB 使用 **7 个
DSP48E2 乘法单元**：

1. `l × s`（Q14 域 `q14mul`，1 个）；
2. `qm × op`（三条色相支路的插值乘积，3 个并行）；
3. `r/g/b × MAXV`（输出缩放，3 个并行）。

每个乘法单元的 `AREG/BREG/MREG/PREG` 全为 1（`OPMODEREG=0`），三个内部寄存器
级分别由所在流水级的 ready 驱动，因此既不会有 `DPIP`/`DPOP`「DSP 未流水」
建议，也不会在背压下与同像素侧数据错拍。

在 `GSTRATEGY=0`（或 `DSP_PIPE!=3`）时，乘法由组合逻辑完成；`GSTRATEGY=0`
会把整个核心绑定到 LUT（0 个 DSP）。

### 2.2 Fold Factor（`FOLD`）

预留给窗口算子的折叠/复用因子。HSL→RGB 是逐像素点算子，当前 V2.0 不使用
`FOLD`，修改它不会改变输出、吞吐或延迟。

### 2.3 DSP Pipeline（`DSP_PIPE`）

| 值 | HSL→RGB 行为 |
|---:|---|
| 0 | 基础实现（Q14 归一化 + 组合函数），输出延迟 3 拍 |
| 1 | 基础实现（本 IP 暂无额外可选插拍位置），输出延迟 3 拍 |
| 2 | 基础实现（本 IP 暂无额外可选插拍位置），输出延迟 3 拍 |
| 3 | 启用 HSL→RGB 专用 DSP 全流水通路（需 `GSTRATEGY!=0`），输出延迟 14 拍 |

`DSP_PIPE=3` 的专用路径（单节点 14 拍，II=1）：

```text
拍 0      入口寄存（像素）
拍 1      归一化 + h%16384 + h3 + 三条色相支路 t → 记录 REC_N
拍 2～ 4   乘法级 1（l × s）        AREG/MREG/PREG
拍 5      q / p / qm + 三通道乘法操作数与支路选择 → 记录 REC_Q
拍 6～ 8   乘法级 2（qm × op，3 路并行）
拍 9      色相插值还原 r/g/b（Q14）→ 记录 REC_RGB
拍 10～12  乘法级 3（r/g/b × MAXV，3 路并行）
拍 13     四舍五入 + 钳位 → 输出
```

发生下游背压时，整条流水与 7 个 DSP 的使能一起暂停，不会丢像素或错位；
输入气泡同样被 valid 链逐级传递。

若把参数从 14 拍实现切换到 3 拍实现，测试台与系统集成方必须相应调整帧起始
后的等待时间；像素数量、吞吐和数值语义完全不变（golden 哈希一致）。

---

## 3. 实现方式与建议

### 3.1 func_fixed

- 使用 Q14 定点整数运算，无 ROM 表。
- 默认 `GSTRATEGY=Performance`、`DSP_PIPE=3` 时使用 7 个 DSP48E2 全流水乘法器。
- 三段组合逻辑拆成独立子模块并保留层级（`*_hsl2rgb_n` / `*_hsl2rgb_q` /
  `*_hsl2rgb_c`），便于在大型 ISP 里做 pblock/区域约束。
- 适合追求高 Fmax、需要与其它 IP 共享 DSP 资源池的嵌入式工程。

### 3.2 lut_fixed

- Q14 归一化在生成阶段烘焙为查表 ROM（三通道各一张），其余运算仍为定点函数。
- 适合上游位宽固定、希望进一步省逻辑的设计。
- 输出与 func_fixed 在同一 `PIX_BITS` 下逐位一致。
- 本模式下固定使用 3 拍基础通路（不启用 DSP 全流水）。

### 3.3 资源与延迟参考

在 `xczu15eg-ffvb1156-2-i`、`PIX_BITS=8`、默认 Performance/DSP_PIPE=3 的
demo 顶层实现（Vivado 2020.2，`Flow_PerfOptimized_high` + `Performance_Explore`）
中：

| 资源 | 用量（参考） |
|---|---:|
| DSP48E2 | 7 |
| CLB LUT | 716 |
| CLB 寄存器 | 726 |
| Block RAM | 0 |
| WNS | +19.2 ns |

实际资源会随器件、`PIX_BITS`、实现方式和综合策略变化，应以目标工程的
Utilization 报告为准。

| 实现条件 | 输出延迟 | 吞吐 |
|---|---:|---:|
| lut_fixed | 3 拍 | II=1 |
| func_fixed，GSTRATEGY=0 | 3 拍 | II=1 |
| func_fixed，GSTRATEGY!=0，DSP_PIPE=0/1/2 | 3 拍 | II=1 |
| func_fixed，GSTRATEGY!=0，DSP_PIPE=3 | 14 拍 | II=1 |

---

## 4. Demo 工程与验证

导出的 IP 包包含：

- `ISP_IP_HSL_to_RGB_core.v`：转换核心（含 `_hsl2rgb_n` / `_hsl2rgb_q` /
  `_hsl2rgb_c` 三个保留层级的组合子模块，以及 `_hsl_mul` DSP 乘法模块）；
- `ISP_IP_HSL_to_RGB_top.v`：通用像素流顶层；
- `ISP_IP_HSL_to_RGB_axis.v`：AXI4-Stream 封装；
- `package_ip.tcl`：IP 打包脚本；
- `xgui/ISP_IP_HSL_to_RGB_v2_0.tcl`：Vivado Customize IP 界面；
- `demo/create_demo_project.tcl`：创建 demo Vivado 工程；
- `demo/clock_route.tcl`：pre-opt_design 钩子（无板卡引脚时的时钟路由放宽与
  无约束 I/O 的 DRC 降级）；
- `demo/demo_top.v`、`demo/tb_demo.v`：演示顶层和 golden 自检 testbench；
- `golden_in.hex`、`golden_hash.txt`：确定性激励和期望哈希。

demo 的 `create_demo_project.tcl` 会显式写入（数值对应导出时的选择，不含
`YUV_STANDARD`）：

```tcl
set_property CONFIG.PIX_BITS {8} [get_ips ISP_IP_HSL_to_RGB]
set_property CONFIG.MAX_WIDTH {3840} [get_ips ISP_IP_HSL_to_RGB]
set_property CONFIG.GSTRATEGY {2} [get_ips ISP_IP_HSL_to_RGB]
set_property CONFIG.FOLD {2} [get_ips ISP_IP_HSL_to_RGB]
set_property CONFIG.DSP_PIPE {3} [get_ips ISP_IP_HSL_to_RGB]
```

修改 IP 后建议执行：

1. Generate Output Products；
2. Run Synthesis；
3. Run Implementation；
4. 打开 `demo_top_drc_routed.rpt`，确认没有 `DPIP`、`DPOP` 相关警告；
5. 运行 Behavioral / Post-Synthesis / Post-Implementation Functional Simulation，
   确认 golden 哈希一致。

预期的综合/实现提示：

- **不应**出现 `DPIP-2`、`DPOP-3`、`DPOP-4`（DSP 未流水）；
- **不应**出现 `[Netlist 29-101]` / `[Netlist 29-43]`（网表展平、不利于
  floorplanning）——核心已拆出保留层级的子模块；
- demo 没有板卡引脚定义，因此 `NSTD-1`（未指定 IOSTANDARD）与 `UCIO-1`
  （未约束引脚位置）会命中全部端口。`demo/clock_route.tcl` 作为
  pre-opt_design 钩子在**没有 `pins.xdc` 时**把这两条 DRC 声明为
  `Advisory`（`report_drc` 里仍可见，只是不再计为警告）；量产集成请用
  IP 页的「引脚约束」生成 `pins.xdc`，取代这个豁免。

---

## 5. 常见配置

| 使用目标 | 建议配置 |
|---|---|
| 常规 8 bit 视频链路 | `PIX_BITS=8`，`GSTRATEGY=Performance`，`DSP_PIPE=3` |
| 高精度色相还原 | `PIX_BITS=12` 或 16，`GSTRATEGY=Performance`，`DSP_PIPE=3` |
| 与大型 ISP 共享 DSP | `GSTRATEGY=Performance`，`DSP_PIPE=3`，按需分配 pblock |
| DSP 资源紧张 | `GSTRATEGY=Area`（0 DSP） |
| 最低延迟 | `GSTRATEGY=Area` 或 `DSP_PIPE=0/1/2`，输出延迟 3 拍 |
| 上游位宽固定、追求省逻辑 | lut_fixed + Area |

最终选择应结合上游调色模块的实际位宽、下游对色相还原精度的要求，以及目标
器件的时序与资源报告确认。
