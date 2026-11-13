# ISP_IP_YUV_to_HSL V2.0 User Guide

本文说明 YUV→HSL 定点转换 IP（`ISP_IP_YUV_to_HSL`）V2.0 的配置项、端口、
数据格式、转换公式和时序行为。该 IP 接收 `{Y, U, V}` 三通道像素流，先经
BT.601 定点矩阵还原 R/G/B，再做 Q14 归一化与 RGB→HSL 转换，输出
`{H, S, L}` 三通道像素流。

界面分为 **General** 和 **Optimization** 两个标签页，所有参数均使用下拉菜单。
核心采用全整数定点运算，支持 ready/valid 背压和 II=1 吞吐，全程无除法器
（RGB→HSL 段的定点除法由牛顿迭代倒数 + 精确余数修正实现）。

> 实现方式（函数定点或 LUT 归一化）在 ISP Studio 导出 IP 时按节点的
> `codegenMode` 选择，并烘焙进 IP。Vivado 的 Customize IP 不再切换实现方式。
>
> YUV 矩阵标准由 `YUV_STANDARD` 参数选择：0 = BT.601(SD)、1 = BT.709(HD)、
> 2 = BT.2020(UHD)，**默认 2（BT.2020）**，与 ISP Studio 节点的默认值一致；
> 可在 Customize IP 里切换后重新 Generate Output Products，无需重新导出。

## 配置项速查

| 标签页 | 配置项 | 可选值 | 主要作用 |
|---|---|---|---|
| General | Pixel Bits (`PIX_BITS`) | 8、10、12、14、16 | 设置 Y/U/V 与 H/S/L 每个通道的位宽 |
| General | Max Width (`MAX_WIDTH`) | 320～8192，按列表选择 | 预留的最大行宽参数；当前逐像素转换不使用行缓冲 |
| General | YUV Matrix Standard (`YUV_STANDARD`) | 0、1、2 | 0 = BT.601（SD）、1 = BT.709（HD）、2 = BT.2020（UHD，默认） |
| Optimization | Multiply Strategy (`GSTRATEGY`) | Area、Balanced、Performance | Area 走组合函数并绑定 LUT；Balanced/Performance 允许使用专用 DSP 通路 |
| Optimization | Fold Factor (`FOLD`) | x1、x2、x4 | 预留的窗口算子折叠因子；当前逐像素转换不使用 |
| Optimization | DSP Pipeline (`DSP_PIPE`) | 0、1、2、3 | 3 启用 YUV→HSL 专用 DSP 全流水路径；0～2 为基础实现 |

---

## IO 接口与数据格式

### 时钟、复位与 AXI4-Stream 像素流

Vivado 封装顶层为 `ISP_IP_YUV_to_HSL`。所有端口工作在 `aclk` 时钟域；
`aresetn` 为低电平有效复位。

| 端口 | 方向 | 位宽 | 说明 |
|---|---|---:|---|
| `aclk` | 输入 | 1 | 像素流时钟 |
| `aresetn` | 输入 | 1 | 低有效复位；正常工作时保持 1 |
| `s_axis_tdata` | 输入 | `3×PIX_BITS` | 输入 YUV 像素，打包格式见下节 |
| `s_axis_tvalid` | 输入 | 1 | 输入数据有效 |
| `s_axis_tready` | 输出 | 1 | IP 可接收输入 |
| `s_axis_tuser` | 输入 | 1 | 帧起始 SOF，与一帧的第一个像素同拍有效 |
| `s_axis_tlast` | 输入 | 1 | 行结束 EOL，与一行最后一个像素同拍有效 |
| `m_axis_tdata` | 输出 | `3×PIX_BITS` | 输出 HSL 像素，打包格式见下节 |
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

### YUV 输入和 HSL 输出位域

令 `PB=PIX_BITS`、`MAXV=2^PB-1`。输入按 **`{Y, U, V}`** 打包，输出按
**`{H, S, L}`** 打包，均把第一个通道放在最高位段。

| 位域 | 通道 | 数值含义 |
|---|---|---|
| `s_axis_tdata[3×PB-1 : 2×PB]` | Y | 亮度码，全范围 0～`MAXV` |
| `s_axis_tdata[2×PB-1 : PB]` | U | Cb 色差，以 `MAXV/2` 为中点 |
| `s_axis_tdata[PB-1 : 0]` | V | Cr 色差，以 `MAXV/2` 为中点 |
| `m_axis_tdata[3×PB-1 : 2×PB]` | H | 色相，0～`MAXV` 对应 0°～360° |
| `m_axis_tdata[2×PB-1 : PB]` | S | 饱和度，0～`MAXV` |
| `m_axis_tdata[PB-1 : 0]` | L | 亮度（明度），0～`MAXV` |

对于常用的 **24 bit / 8 bit 每通道**配置：

```text
输入：s_axis_tdata[23:0] = {Y[7:0], U[7:0], V[7:0]}
输出：m_axis_tdata[23:0] = {H[7:0], S[7:0], L[7:0]}

bits  23       16 15        8 7         0
输入  +----------+-----------+-----------+
      |  Y[7:0]  |  U[7:0]  |  V[7:0]  |
      +----------+-----------+-----------+
输出  +----------+-----------+-----------+
      |  H[7:0]  |  S[7:0]  |  L[7:0]  |
      +----------+-----------+-----------+
```

`PIX_BITS` 改变单通道宽度，三个通道始终等宽：

| PIX_BITS | 单通道位宽 | 接口总位宽 | `MAXV` | 色差中点 |
|---:|---:|---:|---:|---:|
| 8 | 8 | 24 | 255 | 127 |
| 10 | 10 | 30 | 1023 | 511 |
| 12 | 12 | 36 | 4095 | 2047 |
| 14 | 14 | 42 | 16383 | 8191 |
| 16 | 16 | 48 | 65535 | 32767 |

输入 YUV 按**全范围**解释（Y 0～MAXV，U/V 以 MAXV/2 为中心）；本 IP 不提供
limited/TV range 识别。

### 定点转换公式

第一步：YUV 定点矩阵（Q16 系数，`>>` 为算术右移）：

```text
half = MAXV >> 1
U' = U - half, V' = V - half

R = clamp(Y + (( 91881×V' + 32768) >> 16), 0, MAXV)
G = clamp(Y + ((-22553×U' - 46801×V' + 32768) >> 16), 0, MAXV)
B = clamp(Y + ((116130×U' + 32768) >> 16), 0, MAXV)
```

系数按 `YUV_STANDARD` 选择（Q16）：

| 值 | 标准 | `crV` | `cgU` | `cgV` | `cbU` |
|---:|---|---:|---:|---:|---:|
| 0 | BT.601（SD） | 91881 | -22553 | -46801 | 116130 |
| 1 | BT.709（HD） | 103206 | -12276 | -30679 | 121609 |
| 2 | BT.2020（UHD，默认） | 96639 | -10784 | -37444 | 123299 |

第二步：R/G/B 归一化到 Q14 后再做 HSL（与 `ISP_IP_RGB_to_HSL` 同一口径）：

```text
r = round(R × 16384 / MAXV)   // 同理 g / b
mx = max(r,g,b); mn = min(r,g,b); d = mx - mn; l = (mx + mn) / 2
den = (l > 8192) ? (32768 - mx - mn) : (mx + mn)
s = round(d × 16384 / den)
diff = (mx == r) ? (g - b) : ((mx == g) ? (b - r) : (r - g))
t = round(diff × 16384 / d) + (mx == r ? 0 : (mx == g ? 32768 : 65536))
if (mx == r && t < 0) t += 98304
h = round(t / 6)
H = clamp(round(h × MAXV / 16384), 0, MAXV)   // 同理 S / L
```

要点：

- 矩阵系数由综合参数 `YUV_STANDARD` 选择（下表），不是 AXI-Lite 运行期端口；
- 第二阶段的所有除法都由「牛顿迭代倒数 + 精确余数修正」的整数电路实现，
  结果与理想四舍五入除法**逐位一致**；
- 与 ISP Studio 的 Dart 定点参考（`cscFixedPixel('csc_yuv2hsl')`
  = `yuvToRgb` BT.601 + `_rgbToHslQ14`）在 8 bit 全域 256³ 组合、
  10/12/16 bit 抽样上逐位一致。

---

## 1. General 标签页

### 1.1 Pixel Bits（`PIX_BITS`）

**含义**

设置 Y、U、V 与 H、S、L 每个通道的位宽。三个通道共用相同位宽，接口总位宽为
`3×PIX_BITS`。

**可选值**

`8`、`10`、`12`、`14`、`16` 位。

**影响**

- 位宽越高，色相与色差分辨率越高，内部数据通路越宽。
- 位宽越低，逻辑和连线资源通常越少。
- 该参数不会改变图像分辨率或帧率。
- `PIX_BITS` 是综合参数；DEMO 的 `create_demo_project.tcl` 会把导出时的选择
  写入 `CONFIG.PIX_BITS`。

**建议**

- 常规 8 bit 视频链路选择 `8`；与上游 YUV 源保持一致。
- 不建议仅为“精度显示”盲目选择 16 bit，应同时检查时序和资源报告。

### 1.2 Max Width（`MAX_WIDTH`）

**含义**

预留的最大行宽参数，供后续包含行缓冲或窗口操作的 IP 复用。

**当前作用**

YUV→HSL 是逐像素点算子，不使用行缓冲，因此改变 `MAX_WIDTH` 不改变本 IP 的
处理结果、资源或延迟。本 IP 仍保留该参数，以保持与其它 ISP IP 的通用参数
面板和 demo 生成流程一致。

---

## 2. Optimization 标签页

### 2.1 Multiply Strategy（`GSTRATEGY`）

| 可选值 | 值 | 说明 |
|---|---:|---|
| Area (folded operators) | 0 | 组合函数实现，模块级 `use_dsp="no"` 绑定 LUT：零 DSP 占用 |
| Balanced (synthesizer chooses) | 1 | 依赖 `DSP_PIPE`；=3 时启用专用 DSP 全流水通路 |
| Performance (use DSP) | 2 | 同 Balanced；默认，`DSP_PIPE=3` 时实际使用 15 个 DSP48E2 |

在 func_fixed 且 `GSTRATEGY!=0`、`DSP_PIPE=3` 时，YUV→HSL 使用 **15 个
DSP48E2 乘法单元**：

1. BT.601 矩阵段 4 个：`crV×V'`、`cgU×U'`、`cgV×V'`、`cbU×U'`
   （`U'`/`V'` 为减去中点的有符号差值，故该级 `SIGNED_A=1`、`SIGNED_B=1`，
   系数上限 116130 需 18 位有符号 B 端口）；
2. RGB→HSL 段 11 个：`l×s`、三条 `qm×op`、三条 `×MAXV` 与四级定点除法的
   倒数/商/余数乘法。

所有乘法单元的 AREG/BREG/MREG/PREG 全为 1（`OPMODEREG=0`），三个内部寄存器级
分别由所在流水级的 ready 驱动，因此既不会有 `DPIP`/`DPOP`「DSP 未流水」建议，
也不会在背压下与同像素侧数据错拍。

在 `GSTRATEGY=0`（或 `DSP_PIPE!=3`）时，乘法由组合逻辑完成；`GSTRATEGY=0`
会把整个核心绑定到 LUT（0 个 DSP）。

### 2.2 Fold Factor（`FOLD`）

预留给窗口算子的折叠/复用因子。YUV→HSL 是逐像素点算子，当前 V2.0 不使用
`FOLD`，修改它不会改变输出、吞吐或延迟。

### 2.3 DSP Pipeline（`DSP_PIPE`）

| 值 | YUV→HSL 行为 |
|---:|---|
| 0 | 基础实现（组合函数，三段式），输出延迟 3 拍 |
| 1 | 基础实现（本 IP 暂无额外可选插拍位置），输出延迟 3 拍 |
| 2 | 基础实现（本 IP 暂无额外可选插拍位置），输出延迟 3 拍 |
| 3 | 启用 YUV→HSL 专用 DSP 全流水通路（需 `GSTRATEGY!=0`），输出延迟 28 拍 |

`DSP_PIPE=3` 的专用路径（单节点 28 拍，II=1）：

```text
拍 0      入口寄存（YUV 像素）
拍 1～ 3   矩阵乘法级（4 个 DSP：crV/cgU/cgV/cbU）
拍 4      三路累加 + 舍入 + 钳位 → R/G/B 码
拍 5      入口寄存（R/G/B 码）+ Q14 归一化 + max/min + den/差分   → REC_M
拍 6      规格化移位 + 种子 ROM                                   → REC_Q
拍 7～ 9   乘法级 1（dn × A0）
拍 10     牛顿因子 nf
拍 11～13  乘法级 2（A0 × nf）→ 倒数 R
拍 14     R = p >> 16
拍 15～17  乘法级 3（nv × R）→ 商估计 q0
拍 18     q0 = p >> (19 − k)
拍 19～21  乘法级 4（q0 × den）→ 余数修正用乘积
拍 22     ±1 余数修正 + 色相基点 + 除 6
拍 23～25  缩放乘法（×MAXV）
拍 26     四舍五入 + 钳位 → 输出
```

（严格说拍 5 起与 `ISP_IP_RGB_to_HSL` 的 23 拍阶梯完全一致：入口 1 拍 +
归一化 1 拍 + 除法预备 1 拍 + 4 级除法各 4 拍 + 缩放 4 拍 + 输出 1 拍。）

发生下游背压时，整条流水与 15 个 DSP 的使能一起暂停，不会丢像素或错位；
输入气泡同样被 valid 链逐级传递。

若把参数从 28 拍实现切换到 3 拍实现，测试台与系统集成方必须相应调整帧起始
后的等待时间；像素数量、吞吐和数值语义完全不变（golden 哈希一致）。

---

## 3. 实现方式与建议

### 3.1 func_fixed

- 使用 Q14/Q16 定点整数运算，无 ROM 表（种子 ROM 是 `case` 函数）。
- 默认 `GSTRATEGY=Performance`、`DSP_PIPE=3` 时使用 15 个 DSP48E2 全流水乘法器。
- RGB→HSL 段复用 `_hsl_m` / `_hsl_q` / `_hsl_corr` 三个保留层级的子模块，
  矩阵段在其前接线，便于在大型 ISP 里做 pblock/区域约束。
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
| DSP48E2 | 15 |
| CLB LUT | 1704 |
| CLB 寄存器 | 2136 |
| Block RAM | 0 |
| WNS | +17.7 ns |

（该配置下 IP OOC 综合为 1867 LUT / 3130 寄存器 / 15 DSP。）

实际资源会随器件、`PIX_BITS`、实现方式和综合策略变化，应以目标工程的
Utilization 报告为准。

| 实现条件 | 输出延迟 | 吞吐 |
|---|---:|---:|
| lut_fixed | 3 拍 | II=1 |
| func_fixed，GSTRATEGY=0 | 3 拍 | II=1 |
| func_fixed，GSTRATEGY!=0，DSP_PIPE=0/1/2 | 3 拍 | II=1 |
| func_fixed，GSTRATEGY!=0，DSP_PIPE=3 | 28 拍 | II=1 |

---

## 4. Demo 工程与验证

导出的 IP 包包含：

- `ISP_IP_YUV_to_HSL_core.v`：转换核心（含 `_hsl_m` / `_hsl_q` / `_hsl_corr`
  三个保留层级的组合子模块，以及 `_hsl_mul` DSP 乘法模块）；
- `ISP_IP_YUV_to_HSL_top.v`：通用像素流顶层；
- `ISP_IP_YUV_to_HSL_axis.v`：AXI4-Stream 封装；
- `package_ip.tcl`：IP 打包脚本；
- `xgui/ISP_IP_YUV_to_HSL_v2_0.tcl`：Vivado Customize IP 界面；
- `ISP_IP_YUV_to_HSL_V2.0_UserGuide.md`：本说明；
- `demo/create_demo_project.tcl`：创建 demo Vivado 工程；
- `demo/clock_route.tcl`：pre-opt_design 钩子（无板卡引脚时的时钟路由放宽与
  无约束 I/O 的 DRC 降级）；
- `demo/demo_top.v`、`demo/tb_demo.v`：演示顶层和 golden 自检 testbench；
- `golden_in.hex`、`golden_hash.txt`：确定性激励和期望哈希。

demo 的 `create_demo_project.tcl` 会显式写入（数值对应导出时的选择）：

```tcl
set_property CONFIG.PIX_BITS {8} [get_ips ISP_IP_YUV_to_HSL]
set_property CONFIG.MAX_WIDTH {3840} [get_ips ISP_IP_YUV_to_HSL]
set_property CONFIG.GSTRATEGY {2} [get_ips ISP_IP_YUV_to_HSL]
set_property CONFIG.FOLD {2} [get_ips ISP_IP_YUV_to_HSL]
set_property CONFIG.DSP_PIPE {3} [get_ips ISP_IP_YUV_to_HSL]
set_property CONFIG.YUV_STANDARD {2} [get_ips ISP_IP_YUV_to_HSL]
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
| 常规 8 bit 视频链路（BT.601 源） | `PIX_BITS=8`，`GSTRATEGY=Performance`，`DSP_PIPE=3` |
| 高精度色相处理 | `PIX_BITS=12` 或 16，`GSTRATEGY=Performance`，`DSP_PIPE=3` |
| BT.709 / BT.2020 素材 | 直接改 `YUV_STANDARD`（1 / 2，默认 2） |
| DSP 资源紧张 | `GSTRATEGY=Area`（0 DSP） |
| 最低延迟 | `GSTRATEGY=Area` 或 `DSP_PIPE=0/1/2`，输出延迟 3 拍 |
| 上游位宽固定、追求省逻辑 | lut_fixed + Area |

最终选择应结合上游 YUV 源的矩阵标准、范围约定，以及目标器件的时序与资源
报告确认。
