# ISP_IP_RGB_to_YUV V2.0 User Guide

本文说明 RGB→YUV 定点转换 IP（`ISP_IP_RGB_to_YUV`）V2.0 的配置项、端口、
数据格式、转换公式和时序行为。该 IP 接收 `{R, G, B}` 三通道像素流，输出
`{Y, U, V}` 三通道像素流，支持 BT.601、BT.709 和 BT.2020 三套矩阵标准。

界面分为 **General** 和 **Optimization** 两个标签页，所有参数均使用下拉菜单。
核心采用全整数定点运算，支持 ready/valid 背压和 II=1 吞吐。

> 实现方式（LUT 查表或函数定点）以及 full/limited 范围在 ISP Studio 导出 IP
> 时按节点参数选择，并烘焙进 IP。Vivado 的 Customize IP 不再切换这两项。

## 配置项速查

| 标签页 | 配置项 | 可选值 | 主要作用 |
|---|---|---|---|
| General | Pixel Bits (`PIX_BITS`) | 8、10、12、14、16 | 设置 R/G/B 和 Y/U/V 每个通道的位宽 |
| General | Max Width (`MAX_WIDTH`) | 320～8192，按列表选择 | 预留的最大行宽参数；当前逐像素转换不使用行缓冲 |
| General | YUV Matrix Standard (`YUV_STANDARD`) | 0、1、2 | 0 = BT.601（SD）、1 = BT.709（HD）、2 = BT.2020（UHD，默认） |
| Optimization | Multiply Strategy (`GSTRATEGY`) | Area、Balanced、Performance | 选择乘法器使用 LUT、由综合器决定或强制使用 DSP |
| Optimization | Fold Factor (`FOLD`) | x1、x2、x4 | 预留的窗口算子折叠因子；当前逐像素转换不使用 |
| Optimization | DSP Pipeline (`DSP_PIPE`) | 0、1、2、3 | 0～2 使用基础单拍实现；3 启用 RGB→YUV 专用 DSP 全流水路径 |

---

## IO 接口与数据格式

### 时钟、复位与 AXI4-Stream 像素流

Vivado 封装顶层为 `ISP_IP_RGB_to_YUV`。所有端口工作在 `aclk` 时钟域；
`aresetn` 为低电平有效复位。

| 端口 | 方向 | 位宽 | 说明 |
|---|---|---:|---|
| `aclk` | 输入 | 1 | 像素流时钟 |
| `aresetn` | 输入 | 1 | 低有效复位；正常工作时保持 1 |
| `s_axis_tdata` | 输入 | `3×PIX_BITS` | 输入 RGB 像素，打包格式见下节 |
| `s_axis_tvalid` | 输入 | 1 | 输入数据有效 |
| `s_axis_tready` | 输出 | 1 | IP 可接收输入 |
| `s_axis_tuser` | 输入 | 1 | 帧起始 SOF，与一帧的第一个像素同拍有效 |
| `s_axis_tlast` | 输入 | 1 | 行结束 EOL，与一行最后一个像素同拍有效 |
| `m_axis_tdata` | 输出 | `3×PIX_BITS` | 输出 YUV 像素，打包格式见下节 |
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

### RGB 输入和 YUV 输出位域

令 `PB=PIX_BITS`、`MAXV=2^PB-1`。输入按 **`{R, G, B}`** 打包，输出按
**`{Y, U, V}`** 打包，均把第一个通道放在最高位段。

| 位域 | 通道 | 数值含义 |
|---|---|---|
| `s_axis_tdata[3×PB-1 : 2×PB]` | R | 红色，0～`MAXV` |
| `s_axis_tdata[2×PB-1 : PB]` | G | 绿色，0～`MAXV` |
| `s_axis_tdata[PB-1 : 0]` | B | 蓝色，0～`MAXV` |
| `m_axis_tdata[3×PB-1 : 2×PB]` | Y | 亮度 |
| `m_axis_tdata[2×PB-1 : PB]` | U | Cb 色差，以 `MAXV/2` 为中点 |
| `m_axis_tdata[PB-1 : 0]` | V | Cr 色差，以 `MAXV/2` 为中点 |

对于常用的 **24 bit / 8 bit 每通道**配置：

```text
输入：s_axis_tdata[23:0] = {R[7:0], G[7:0], B[7:0]}
输出：m_axis_tdata[23:0] = {Y[7:0], U[7:0], V[7:0]}

bits  23       16 15        8 7         0
输入  +----------+-----------+-----------+
      |  R[7:0]  |  G[7:0]  |  B[7:0]  |
      +----------+-----------+-----------+
输出  |  Y[7:0]  |  U[7:0]  |  V[7:0]  |
      +----------+-----------+-----------+
```

`PIX_BITS` 改变单通道宽度，三个通道始终等宽：

| PIX_BITS | 单通道位宽 | 接口总位宽 | `MAXV` | 中性色差 |
|---:|---:|---:|---:|---:|
| 8 | 8 | 24 | 255 | 127 |
| 10 | 10 | 30 | 1023 | 511 |
| 12 | 12 | 36 | 4095 | 2047 |
| 14 | 14 | 42 | 16383 | 8191 |
| 16 | 16 | 48 | 65535 | 32767 |

full 模式下输入 RGB 和输出 YUV 均为全范围：RGB 为 0～`MAXV`，Y 为
0～`MAXV`，U/V 以 `MAXV/2` 为中点。

limited（TV range）模式按 8 bit 标度映射：

- Y：16～235，对应 0～`MAXV` 输出量级；
- U/V：16～240，以 `MAXV/2` 为中点；
- full/limited 在节点生成时选择，没有运行期 AXI 端口。

### 定点转换公式

令 `half = MAXV >> 1`。full 模式下：

```text
Y = clamp((CY_R×R + CY_G×G + CY_B×B + 32768) >> 16, 0, MAXV)
U = clamp(((CU_R×R + CU_G×G + CU_B×B + 32768) >> 16) + half, 0, MAXV)
V = clamp(((CV_R×R + CV_G×G + CV_B×B + 32768) >> 16) + half, 0, MAXV)
```

其中 `CU_B` 和 `CV_R` 恒为 `32768`（0.5×2^16）。`32768` 是 Q16 半值舍入项，
`>> 16` 为算术右移。最终结果与 Dart/C 定点参考逐位一致。

limited 模式在 full 结果上继续处理：

```text
offY = (MAXV × 16 + 127) / 255
Ylim = offY + (Y × 219 + 127) / 255
Ulim = half + ((U - half) × 224 + sign127) / 255
Vlim = half + ((V - half) × 224 + sign127) / 255
```

`sign127` 根据色差符号取 `±127`。除法为生成到逻辑中的常数除法，输出最终钳位
到 0～`MAXV`。

### `YUV_STANDARD` 与系数

| 值 | 标准 | `CY_R` | `CY_G` | `CY_B` | `CU_R` | `CU_G` | `CV_G` | `CV_B` |
|---:|---|---:|---:|---:|---:|---:|---:|---:|
| 0 | BT.601（SD） | 19595 | 38470 | 7471 | -11058 | -21710 | -27439 | -5329 |
| 1 | BT.709（HD） | 13933 | 46871 | 4732 | -7509 | -25260 | -29759 | -3009 |
| 2 | BT.2020（UHD） | 17216 | 44433 | 3886 | -9151 | -23617 | -30133 | -2635 |

系数均为 Q16 定点。默认值为 **2（BT.2020）**，与节点默认值一致。

生效条件：

- **func_fixed**：系数由 `YUV_STANDARD` 参数选择，可在 Customize IP 中修改后
  重新 Generate Output Products，无需重新导出；
- **lut_fixed**：IP 在生成时按节点标准烘焙系数乘积 ROM，修改 Customize IP 的
  `YUV_STANDARD` 不会更新 ROM，需要重新生成 IP；
- `YUV_STANDARD` 是综合参数，不是 AXI-Lite 运行期端口。

---

## 1. General 标签页

### 1.1 Pixel Bits（`PIX_BITS`）

设置 RGB 输入与 YUV 输出每个通道的位宽，三个通道共用相同宽度，接口总宽度为
`3×PIX_BITS`。

可选 `8`、`10`、`12`、`14`、`16` 位。位宽越高，量化误差越小，但数据通路和
乘法资源更宽。常规 8 bit 视频选择 `8`；上游为 10/12 bit 时选择匹配位宽。

### 1.2 Max Width（`MAX_WIDTH`）

预留给后续窗口算子的最大行宽参数。RGB→YUV 是逐像素点算子，不使用行缓冲，
因此当前改变 `MAX_WIDTH` 不会改变结果、资源或延迟。

### 1.3 YUV Matrix Standard（`YUV_STANDARD`）

选择 RGB 到 YUV 的矩阵标准：

| 下拉选项 | 值 | 典型用途 |
|---|---:|---|
| BT.601 (SD) | 0 | SD 视频、传统 BT.601 工作流 |
| BT.709 (HD) | 1 | 1080p/HD 视频 |
| BT.2020 (UHD) | 2 | 4K/8K UHD、宽色域；默认 |

输入视频元数据为 BT.2020 时保持默认 `2`；HD 素材选择 `1`；传统 SD 素材选择
`0`。如果下游要求 limited range，需在 ISP Studio 节点中设置，Customize IP 中
没有独立的 range 参数。

---

## 2. Optimization 标签页

### 2.1 Multiply Strategy（`GSTRATEGY`）

| 可选值 | 值 | 说明 |
|---|---:|---|
| Area (folded operators) | 0 | 乘法器绑定 LUT，不启用专用 DSP 流水 |
| Balanced (synthesizer chooses) | 1 | 综合器选择 LUT/DSP |
| Performance (use DSP) | 2 | 优先使用 DSP48，适合高 Fmax；默认 |

在 func_fixed、`GSTRATEGY!=0`、`DSP_PIPE=3` 时，RGB→YUV 使用 **9 个
DSP48E2**：Y/U/V 各 3 个乘法器。所有 DSP 均启用输入寄存器、`MREG=1`、
`PREG=1`，并显式设置乘法 OPMODE，避免 DPIP/DPOP DRC。

LUT fixed 或 `GSTRATEGY=0` 时，乘法由 ROM/LUT 逻辑完成。

### 2.2 Fold Factor（`FOLD`）

预留的窗口算子折叠因子。RGB→YUV 是逐像素点算子，当前 V2.0 不使用 `FOLD`，
修改不会改变输出、吞吐或延迟。

### 2.3 DSP Pipeline（`DSP_PIPE`）

| 值 | RGB→YUV 行为 |
|---:|---|
| 0 | 基础单拍函数实现 |
| 1 | 基础单拍函数实现 |
| 2 | 基础单拍函数实现 |
| 3 | 启用 RGB→YUV 专用 DSP 全流水路径；需 `GSTRATEGY!=0` 且为 func_fixed |

`DSP_PIPE=3` 的专用路径包含：

1. 输入 RGB 像素寄存及 3 个对齐延迟级；
2. 9 个 DSP48E2 乘法，输入、乘法、输出三级内部寄存；
3. 3 组乘积求和、Q16 舍入和移位；
4. full/limited 映射与输出钳位寄存器。

该路径总延迟为 **4 拍**（从输入握手到对应输出），吞吐仍为 II=1。发生背压时，
整条流水和 9 个 DSP 使能一起暂停，不会丢像素或错位。

`DSP_PIPE=0/1/2` 的 func_fixed 基础路径和 lut_fixed 路径均为 **1 拍**输出延迟。
切换档位时必须同步调整外部帧起始后的等待时间；像素数量、吞吐和数值结果不变。

---

## 3. 实现方式与建议

### 3.1 func_fixed

- 使用整数定点运算，默认无 ROM 表。
- 默认 Performance + DSP_PIPE=3 时使用 9 个 DSP48E2 全流水乘法器。
- 可在 Customize IP 中修改 `YUV_STANDARD`，重新生成后生效。
- 适合需要切换标准、追求高 Fmax 的嵌入式工程。

### 3.2 lut_fixed

- 系数乘积项在生成阶段烘焙为 ROM/LUT。
- 适合标准固定、资源受限或不需要运行期换标准的设计。
- `YUV_STANDARD` 的生效依赖重新导出 IP；Customize IP 中切换不会更新烘焙 ROM。
- 输出与 func_fixed 在同一标准、位宽和 range 下逐位一致。

### 3.3 资源与延迟参考

在 `xczu15eg-ffvb1156-2-i`、`PIX_BITS=8`、BT.2020、默认
Performance/DSP_PIPE=3 的实现中，demo 顶层资源约为：

| 资源 | 用量（参考） |
|---|---:|
| DSP48E2 | 9 |
| CLB LUT | 约 338 |
| CLB 寄存器 | 约 36 |

实际资源会随器件、`PIX_BITS`、实现方式和综合策略变化，应以目标工程的
Utilization 报告为准。

| 实现条件 | 输出延迟 | 吞吐 |
|---|---:|---:|
| lut_fixed | 1 拍 | II=1 |
| func_fixed，GSTRATEGY=0 | 1 拍 | II=1 |
| func_fixed，GSTRATEGY!=0，DSP_PIPE=0/1/2 | 1 拍 | II=1 |
| func_fixed，GSTRATEGY!=0，DSP_PIPE=3 | 4 拍 | II=1 |

---

## 4. Demo 工程与验证

导出的 IP 包包含：

- `ISP_IP_RGB_to_YUV_core.v`：转换核心；
- `ISP_IP_RGB_to_YUV_top.v`：通用像素流顶层；
- `ISP_IP_RGB_to_YUV_axis.v`：AXI4-Stream 封装；
- `package_ip.tcl`：IP 打包脚本；
- `xgui/ISP_IP_RGB_to_YUV_v2_0.tcl`：Vivado Customize IP 界面；
- `demo/create_demo_project.tcl`：创建 demo Vivado 工程；
- `demo/demo_top.v`、`demo/tb_demo.v`：演示顶层和 golden 自检 testbench；
- `golden_in.hex`、`golden_hash.txt`：确定性激励和期望哈希。

demo 的 `create_demo_project.tcl` 会显式写入：

```tcl
set_property CONFIG.PIX_BITS {8} [get_ips ISP_IP_RGB_to_YUV]
set_property CONFIG.YUV_STANDARD {2} [get_ips ISP_IP_RGB_to_YUV]
```

实际数值对应导出时选择。修改 IP 后建议执行：

1. Generate Output Products；
2. Run Synthesis；
3. Run Implementation；
4. 打开 `demo_top_drc_routed.rpt`，确认没有 `DPIP`、`DPOP` 相关警告；
5. 运行 Behavioral / Post-Synthesis / Post-Implementation Functional Simulation，
   确认 golden 哈希一致。

demo 顶层未绑定具体板卡引脚和 I/O 电平时，DRC 会保留 `NSTD-1`、`UCIO-1`；
量产集成时应按实际板卡补齐 XDC 约束。

---

## 5. 常见配置

| 使用目标 | 建议配置 |
|---|---|
| 常规 SD / BT.601 | `PIX_BITS=8`，`YUV_STANDARD=0`，`GSTRATEGY=Performance`，`DSP_PIPE=3` |
| HD / BT.709 | `PIX_BITS=8` 或 10，`YUV_STANDARD=1`，`GSTRATEGY=Performance`，`DSP_PIPE=3` |
| UHD / BT.2020 | `PIX_BITS=10` 或 12，`YUV_STANDARD=2`（默认），`GSTRATEGY=Performance`，`DSP_PIPE=3` |
| 资源受限 | `GSTRATEGY=Area`，必要时使用 lut_fixed |
| 最低延迟 | `DSP_PIPE=0/1/2` 或 lut_fixed，输出延迟 1 拍 |
| 标准固定且不复用 DSP | lut_fixed + Area，按目标标准生成 |

最终选择应结合输入视频的色彩矩阵、range 约定和目标器件的时序/资源报告确认。
