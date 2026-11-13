# ISP_IP_YUV_to_RGB V2.0 User Guide

本文说明 YUV→RGB 定点转换 IP（`ISP_IP_YUV_to_RGB`）V2.0 的配置项、
端口、数据格式、转换公式和时序行为。该 IP 接收 `{Y, U, V}` 三通道像素流，
输出 `{R, G, B}` 三通道像素流，支持 BT.601、BT.709 和 BT.2020 三套矩阵标准。

界面分为 **General** 和 **Optimization** 两个标签页，所有参数均使用下拉菜单。
核心采用全整数定点运算，支持 ready/valid 背压和 II=1 吞吐。

> 实现方式（LUT 查表或函数定点）在 ISP Studio 导出 IP 时按节点的
> `codegenMode` 选择，并烘焙进 IP。Vivado 的 Customize IP 不再切换实现方式。

## 配置项速查

| 标签页 | 配置项 | 可选值 | 主要作用 |
|---|---|---|---|
| General | Pixel Bits (`PIX_BITS`) | 8、10、12、14、16 | 设置 Y/U/V 和 R/G/B 每个通道的位宽 |
| General | Max Width (`MAX_WIDTH`) | 320～8192，按列表选择 | 预留的最大行宽参数；当前逐像素转换不使用行缓冲 |
| General | YUV→RGB Standard (`YUV_STANDARD`) | 0、1、2 | 0 = BT.601（SD）、1 = BT.709（HD）、2 = BT.2020（UHD，默认） |
| Optimization | Multiply Strategy (`GSTRATEGY`) | Area、Balanced、Performance | 选择乘法器使用 LUT、由综合器决定或强制使用 DSP |
| Optimization | Fold Factor (`FOLD`) | x1、x2、x4 | 预留的窗口算子折叠因子；当前逐像素转换不使用 |
| Optimization | DSP Pipeline (`DSP_PIPE`) | 0、1、2、3 | 0～2 使用基础单拍实现；3 启用 YUV→RGB 专用 DSP 全流水路径 |

---

## IO 接口与数据格式

### 时钟、复位与 AXI4-Stream 像素流

Vivado 封装顶层为 `ISP_IP_YUV_to_RGB`。所有端口工作在 `aclk` 时钟域；
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

### YUV 输入和 RGB 输出位域

令 `PB=PIX_BITS`、`MAXV=2^PB-1`。输入按 **`{Y, U, V}`** 打包，输出按
**`{R, G, B}`** 打包，均把第一个通道放在最高位段。

| 位域 | 通道 | 数值含义 |
|---|---|---|
| `s_axis_tdata[3×PB-1 : 2×PB]` | Y | 亮度量化码，0～`MAXV` |
| `s_axis_tdata[2×PB-1 : PB]` | U | Cb 色差，以 `MAXV/2` 为中点 |
| `s_axis_tdata[PB-1 : 0]` | V | Cr 色差，以 `MAXV/2` 为中点 |
| `m_axis_tdata[3×PB-1 : 2×PB]` | R | 红通道，已钳位到 0～`MAXV` |
| `m_axis_tdata[2×PB-1 : PB]` | G | 绿通道，已钳位到 0～`MAXV` |
| `m_axis_tdata[PB-1 : 0]` | B | 蓝通道，已钳位到 0～`MAXV` |

对于常用的 **24 bit / 8 bit 每通道**配置：

```text
输入：s_axis_tdata[23:0] = {Y[7:0], U[7:0], V[7:0]}
输出：m_axis_tdata[23:0] = {R[7:0], G[7:0], B[7:0]}

bits  23       16 15        8 7         0
输入  +----------+-----------+-----------+
      |  Y[7:0]  |  U[7:0]  |  V[7:0]  |
      +----------+-----------+-----------+
          R[7:0]     G[7:0]      B[7:0]
```

`PIX_BITS` 改变单通道宽度，三个通道始终等宽：

| PIX_BITS | 单通道位宽 | 接口总位宽 | `MAXV` | 中性色差 |
|---:|---:|---:|---:|---:|
| 8 | 8 | 24 | 255 | 127 |
| 10 | 10 | 30 | 1023 | 511 |
| 12 | 12 | 36 | 4095 | 2047 |
| 14 | 14 | 42 | 16383 | 8191 |
| 16 | 16 | 48 | 65535 | 32767 |

当前 YUV→RGB 按**全范围**解释 YUV：Y 码除以 `MAXV` 得到 0～1 亮度，
U/V 码减去 `MAXV/2` 得到以 0 为中心、范围约 `[-MAXV/2, MAXV/2]` 的色差。
输出 RGB 同样为全范围 0～`MAXV`。本节点不提供 limited/TV range 切换。

### 定点转换公式

令：

```text
half = MAXV >> 1
U' = U - half
V' = V - half
```

IP 使用 Q16 系数和整数移位：

```text
R = clamp(Y + ((CR_V × V' + 32768) >> 16), 0, MAXV)
G = clamp(Y + ((CG_U × U' + CG_V × V' + 32768) >> 16), 0, MAXV)
B = clamp(Y + ((CB_U × U' + 32768) >> 16), 0, MAXV)
```

`32768` 是 Q16 半值舍入项，`>> 16` 为算术右移。所有中间乘积使用足够宽的
有符号整数；最终钳位与 Dart/C 定点参考逐位一致。

### `YUV_STANDARD` 与系数

| 值 | 标准 | `CR_V` | `CG_U` | `CG_V` | `CB_U` |
|---:|---|---:|---:|---:|---:|
| 0 | BT.601（SD） | 91881 | -22553 | -46801 | 116130 |
| 1 | BT.709（HD） | 103206 | -12276 | -30679 | 121609 |
| 2 | BT.2020（UHD） | 96639 | -10784 | -37444 | 123299 |

系数均按 Q16 定点定义。默认值为 **2（BT.2020）**，与 ISP Studio 节点默认值一致。

`YUV_STANDARD` 的生效条件：

- **func_fixed 实现**：系数选择由参数控制，可在 Customize IP 中修改
  `YUV_STANDARD` 后重新 Generate Output Products，不需要重新导出 IP。
- **lut_fixed 实现**：IP 在生成时按节点选择的标准烘焙了系数乘积 ROM。
  Customize IP 中的 `YUV_STANDARD` 仅作为记录/默认值显示，不会重写 ROM；
  需要其它标准时应修改节点后重新生成 IP。
- 在同一帧中不要动态改变标准；该参数是综合参数，不是 AXI-Lite 运行期端口。

---

## 1. General 标签页

### 1.1 Pixel Bits（`PIX_BITS`）

**含义**

设置 Y、U、V、R、G、B 每个通道的位宽。三个通道共用相同位宽，接口总位宽为
`3×PIX_BITS`。

**可选值**

`8`、`10`、`12`、`14`、`16` 位。

**影响**

- 位宽越高，量化和舍入误差越小，乘法与数据通路越宽。
- 位宽越低，逻辑和连线资源通常越少。
- 该参数不会改变图像分辨率或帧率。
- `PIX_BITS` 是综合参数；DEMO 的 `create_demo_project.tcl` 会把导出时的选择
  写入 `CONFIG.PIX_BITS`。

**建议**

- 常规 8 bit 视频链路选择 `8`。
- 上游本来就是 10/12 bit 时选择与上游一致的位宽。
- 不建议仅为提高“精度显示”盲目选择 16 bit，应同时检查时序和 DSP 资源。

### 1.2 Max Width（`MAX_WIDTH`）

**含义**

预留的最大行宽参数，供后续包含行缓冲或窗口操作的 IP 复用。

**当前作用**

YUV→RGB 是逐像素点算子，不使用行缓冲，因此改变 `MAX_WIDTH` 不改变本 IP 的
处理结果、资源或延迟。本 IP 仍保留该参数，以保持与其它 ISP IP 的通用参数面板
和 demo 生成流程一致。

### 1.3 YUV→RGB Standard（`YUV_STANDARD`）

**含义**

选择 YUV 到 RGB 的矩阵系数标准。

| 下拉选项 | 值 | 典型用途 |
|---|---:|---|
| BT.601 (SD) | 0 | SD 视频、传统 BT.601 YUV |
| BT.709 (HD) | 1 | 1080p/HD 视频 |
| BT.2020 (UHD) | 2 | 4K/8K UHD、宽色域工作流；默认 |

**设置建议**

- 节点或上游视频元数据为 BT.2020 时保持默认 `2`。
- HD（BT.709）素材选择 `1`。
- 传统 BT.601 素材选择 `0`。
- 如果输入 YUV 是 limited range（Y 16～235），应先在上游转换到全范围，
  或在 ISP Studio 中确认该节点的范围约定；本 IP 不自动识别 limited range。

---

## 2. Optimization 标签页

### 2.1 Multiply Strategy（`GSTRATEGY`）

| 可选值 | 值 | 说明 |
|---|---:|---|
| Area (folded operators) | 0 | 乘法器绑定 LUT，避免占用 DSP；不启用专用 DSP 流水 |
| Balanced (synthesizer chooses) | 1 | 由综合器选择 LUT/DSP 实现 |
| Performance (use DSP) | 2 | 优先使用 DSP48，适合高 Fmax；默认 |

在 func_fixed 且 `GSTRATEGY!=0`、`DSP_PIPE=3` 时，YUV→RGB 使用 4 个 DSP48E2
乘法单元：R 路一个、B 路一个、G 路两个并行乘法后求和。四个乘法器均启用输入
寄存器、`MREG=1`、`PREG=1`，并显式设置乘法 OPMODE，避免 DPIP/DPOP DRC。

在 LUT fixed 或 `GSTRATEGY=0` 时，乘法由查表或 LUT 逻辑完成，不产生 DSP 流水。

### 2.2 Fold Factor（`FOLD`）

预留给窗口算子的折叠/复用因子。YUV→RGB 是逐像素点算子，当前 V2.0 不使用
`FOLD`，修改它不会改变输出、吞吐或延迟。

### 2.3 DSP Pipeline（`DSP_PIPE`）

| 值 | YUV→RGB 行为 |
|---:|---|
| 0 | 基础单拍函数实现 |
| 1 | 基础单拍函数实现（本 IP 暂无额外可选插拍位置） |
| 2 | 基础单拍函数实现（本 IP 暂无额外可选插拍位置） |
| 3 | 启用 YUV→RGB 专用 DSP 全流水路径；需 `GSTRATEGY!=0` 且为 func_fixed |

`DSP_PIPE=3` 的专用路径包含：

1. 输入 Y/U/V 差值及亮度对齐寄存器；
2. 4 个 DSP48E2 乘法，输入、乘法、输出三级内部寄存；
3. DSP 乘积与 Y 延迟对齐；
4. 最终舍入、加 Y 和 RGB 钳位输出寄存器。

该路径总延迟为 **4 拍**（从输入握手到对应输出），吞吐仍为 II=1。发生下游背压时，
整条流水和四个 DSP 的使能一起暂停，不会丢像素或错位。

`DSP_PIPE=0/1/2` 的 func_fixed 基础路径和 lut_fixed 路径均为 **1 拍**输出延迟。
若把参数从 4 拍实现切换到 1 拍实现，测试台和系统集成方必须相应调整帧起始后的
等待时间；像素数量、吞吐和数值语义不变。

---

## 3. 实现方式与建议

### 3.1 func_fixed

- 使用定点整数运算，默认无 ROM 表。
- 默认 `GSTRATEGY=Performance`、`DSP_PIPE=3` 时使用 4 个 DSP48E2 全流水乘法器。
- 可在 Customize IP 中修改 `YUV_STANDARD`，重新生成后生效。
- 适合需要修改标准、追求高 Fmax 的嵌入式工程。

### 3.2 lut_fixed

- 系数乘积项在生成阶段烘焙为 ROM/LUT。
- 适合标准固定、资源受限或不需要运行期换标准的设计。
- `YUV_STANDARD` 的生效依赖重新导出 IP；Customize IP 中切换不会更新烘焙 ROM。
- 输出与 func_fixed 在同一标准和位宽下逐位一致。

### 3.3 资源与延迟参考

在 `xczu15eg-ffvb1156-2-i`、`PIX_BITS=8`、BT.709、默认 Performance/DSP_PIPE=3
的实现中，demo 顶层资源约为：

| 资源 | 用量（参考） |
|---|---:|
| DSP48E2 | 4 |
| CLB LUT | 约 122 |
| CLB 寄存器 | 约 60 |

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

- `ISP_IP_YUV_to_RGB_core.v`：转换核心；
- `ISP_IP_YUV_to_RGB_top.v`：通用像素流顶层；
- `ISP_IP_YUV_to_RGB_axis.v`：AXI4-Stream 封装；
- `package_ip.tcl`：IP 打包脚本；
- `xgui/ISP_IP_YUV_to_RGB_v2_0.tcl`：Vivado Customize IP 界面；
- `demo/create_demo_project.tcl`：创建 demo Vivado 工程；
- `demo/demo_top.v`、`demo/tb_demo.v`：演示顶层和 golden 自检 testbench；
- `golden_in.hex`、`golden_hash.txt`：确定性激励和期望哈希。

demo 的 `create_demo_project.tcl` 会显式写入：

```tcl
set_property CONFIG.PIX_BITS {8} [get_ips ISP_IP_YUV_to_RGB]
set_property CONFIG.YUV_STANDARD {2} [get_ips ISP_IP_YUV_to_RGB]
```

实际数值对应导出时选择。修改 IP 后建议执行：

1. Generate Output Products；
2. Run Synthesis；
3. Run Implementation；
4. 打开 `demo_top_drc_routed.rpt`，确认没有 `DPIP`、`DPOP` 相关警告；
5. 运行 Behavioral / Post-Synthesis / Post-Implementation Functional Simulation，
   确认 golden 哈希一致。

demo 顶层未绑定具体板卡引脚和 I/O 电平标准时，DRC 会保留 `NSTD-1`、`UCIO-1`；
这两项与转换核心无关，量产集成时应按实际板卡补齐 XDC 约束。

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

最终选择应结合输入视频的实际色彩矩阵、范围约定和目标器件时序报告确认。
