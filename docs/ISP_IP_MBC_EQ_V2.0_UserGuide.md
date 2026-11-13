# ISP_IP_MBC_EQ V2.0 User Guide

本文说明多段色彩均衡器 IP（`ISP_IP_MBC_EQ`）V2.0 在 Vivado
**Re-customize IP** 窗口中的全部配置项。界面分为 **General** 和
**Optimization** 两个标签页，所有配置均使用下拉菜单。

本文同时对应 LUT 查表与函数定点两种数据通路。`IMPL_MODE` 决定默认
实现方式，其他配置主要影响通道数量、接口形态、资源用量、组合路径和流水延迟。

## 配置项速查

| 标签页 | 配置项 | 可选值 | 主要作用 |
|---|---|---|---|
| General | Behavior Implementation (`IMPL_MODE`) | LUT file、Function | 选择 LUT 查表或函数运行期直算，并联动函数端口显示 |
| General | Pixel Bits (`PIX_BITS`) | 8、10、12、14、16 | 设置 H/S/L 每个通道的数据位宽和量化精度 |
| General | Max Width (`MAX_WIDTH`) | 320～8192，按列表选择 | 预留的最大行宽参数，面向后续窗口算子 |
| General | Number Of Color Picker Channels (`NUM_BANDS`) | 1～16 | 设置有效的取色器通道数，并改变相关接口 |
| General | Work Mode (`WORK_MODE`) | Parallel、Cascade | 选择取色器并联或串联工作方式，默认跟随 ispflow |
| Optimization | Multiply Strategy (`GSTRATEGY`) | Area、Balanced、Performance | 选择乘法器使用 LUT、由综合器决定或强制使用 DSP |
| Optimization | Fold Factor (`FOLD`) | x1、x2、x4 | 预留的窗口算子折叠/复用因子；当前点算子不使用 |
| Optimization | Band Pipeline (`DSP_PIPE`) | 0、1、2、3 | 设置权重计算流水线档位；3 启用 DSP 输入、乘法与输出全流水，用于提高 Fmax |

---

## IO 接口与数据格式

### 时钟、复位与 AXI4-Stream 像素流

Vivado 封装顶层为 `ISP_IP_MBC_EQ`。所有输入、输出像素流均工作在 `aclk`
时钟域；`aresetn` 为低电平有效复位，核心寄存器使用异步低有效复位。

| 端口 | 方向 | 位宽 | 说明 |
|---|---|---:|---|
| `aclk` | 输入 | 1 | 像素流与段参数共用时钟 |
| `aresetn` | 输入 | 1 | 低有效复位；正常工作时保持 1 |
| `s_axis_tdata` | 输入 | `3×PIX_BITS` | 输入 HSL 像素，打包格式见下节 |
| `s_axis_tvalid` | 输入 | 1 | 输入数据有效 |
| `s_axis_tready` | 输出 | 1 | IP 可接收输入；仅在 `s_axis_tvalid && s_axis_tready` 时接收像素 |
| `s_axis_tuser` | 输入 | 1 | 帧起始 SOF，与本帧第一个像素同拍有效 |
| `s_axis_tlast` | 输入 | 1 | 行结束 EOL，与本行最后一个像素同拍有效 |
| `m_axis_tdata` | 输出 | `3×PIX_BITS` | 输出 HSL 像素，字节/位域布局与输入相同 |
| `m_axis_tvalid` | 输出 | 1 | 输出数据有效 |
| `m_axis_tready` | 输入 | 1 | 下游可接收；为 0 时 IP 保持输出并暂停内部流水 |
| `m_axis_tuser` | 输出 | 1 | 与输出像素对应的 SOF |
| `m_axis_tlast` | 输出 | 1 | 与输出像素对应的 EOL |

数据传输必须遵守 ready/valid 握手：

- 输入侧在 `s_axis_tvalid=1` 且 `s_axis_tready=1` 的时钟上升沿完成一次传输。
- 输出侧在 `m_axis_tvalid=1` 且 `m_axis_tready=1` 时完成一次传输。
- 当 `m_axis_tvalid=1`、`m_axis_tready=0` 时，`m_axis_tdata/tuser/tlast` 保持不变。
- `tuser/tlast` 不参与颜色计算，但必须随对应像素一起提供；流水输出保持原有
  SOF/EOL 对齐关系。
- 所有工作模式均支持 II=1，即流水填满后每个时钟可传输一个像素；流水延迟见
  `DSP_PIPE` 和 `WORK_MODE` 章节。

### HSL 像素位域分配

三个通道按 **`{H, S, L}`** 拼接，H 位于最高位，L 位于最低位。令
`PB=PIX_BITS`、`MAXV=2^PB-1`，则：

| 位域 | 通道 | 数值含义 |
|---|---|---|
| `tdata[3×PB-1 : 2×PB]` | H | 色相量化码；角度约为 `H×360/MAXV` 度 |
| `tdata[2×PB-1 : PB]` | S | 饱和度量化码；实际饱和度为 `S/MAXV` |
| `tdata[PB-1 : 0]` | L | 亮度量化码；实际亮度为 `L/MAXV` |

H 是环形量，0° 与 360° 等价。因此 H 码 0 和 `MAXV` 都位于红色附近；色环回绕由
IP 内部处理。S/L 码 0 表示最小值，`MAXV` 表示最大值。

对于常用的 **24 bit / 8 bit 每通道**配置：

```text
s_axis_tdata[23:0] = {H[7:0], S[7:0], L[7:0]}

bits  23       16 15        8 7         0
      +----------+-----------+-----------+
      |  H[7:0]  |  S[7:0]  |  L[7:0]  |
      +----------+-----------+-----------+
```

| 示例颜色 | H | S | L | 24 bit 数值 |
|---|---:|---:|---:|---:|
| 红色附近，满饱和度、中亮度 | 0（0°） | 255 | 128 | `24'h00FF80` |
| 绿色附近，满饱和度、中亮度 | 85（约 120°） | 255 | 128 | `24'h55FF80` |
| 灰色，无饱和度 | 任意 | 0 | 128 | `H=0` 时为 `24'h000080` |

Verilog 解包和打包可直接写为：

```verilog
wire [7:0] h = s_axis_tdata[23:16];
wire [7:0] s = s_axis_tdata[15:8];
wire [7:0] l = s_axis_tdata[7:0];
wire [23:0] hsl = {h, s, l};
```

### 通道使能 `CH_Enable`

`CH_Enable[NUM_BANDS-1:0]` 仅用于 `IMPL_MODE=1` 的函数定点模式。bit `i` 对应
取色器段 `i` 和 `par_b{i}_*` 参数组：

- `CH_Enable[i]=1`：该段参与权重计算和颜色调整。
- `CH_Enable[i]=0`：该段被屏蔽，相当于该段贡献为零，不影响其它有效段。
- 所有有效段均关闭时，输出原始 HSL 像素。
- `NUM_BANDS` 决定端口位宽及有效段数；`i>=NUM_BANDS` 的段始终无效。
- LUT 模式的段参数已在生成时烘焙，不使用该运行期端口。

### 段参数端口格式与设置方法

每个取色器段有 5 个 **32 bit 运行期输入端口**，仅在 `IMPL_MODE=1` 时启用。
`i=0` 对应第一组取色器，`i=1` 对应第二组，依此类推。端口不是浮点数，必须按下表
换算为定点整数；带符号端口使用 32 bit 二进制补码。

| 端口 | 节点参数 | 定点格式 | 设置公式与作用 |
|---|---|---|---|
| `par_b{i}_hc` | H 中心 `h`（度） | 无符号 Q16 度 | `round(h×65536) mod 23592960`；正常输入 `0<=h<360`，23592960=`360×2^16` |
| `par_b{i}_q` | Q 值 `q` | 无符号 Q20 | `round(q/45×1048576)`；Q 越大色相带越窄，越小越宽；权重为 `exp(-0.5×(d×q/45)^2)` |
| `par_b{i}_dh` | 色相偏移 `dh`（度） | 有符号 Q16 度 | `round(dh×65536)`；正值沿色环正向偏移，负值反向偏移 |
| `par_b{i}_s1` | S 增益 `s` | 有符号 Q14 增益偏移 | `round((s-1)×16384)`；`s=1` 时填 0，`s>1` 增强，`0<=s<1` 减弱 |
| `par_b{i}_l1` | L 增益 `l` | 有符号 Q14 增益偏移 | `round((l-1)×16384)`；`l=1` 时填 0，正负规则同 S |

这里的 `d` 是当前像素 H 与该段 H 中心的环形最短角距，单位为度。S/L 端口存储的是
**增益减 1**，不是增益本身。例如需要 S 增益 1.5 时，端口值为
`round((1.5-1)×16384)=8192`，而不是 24576。

#### 设置示例

以某段参数 `H=120°、Q=2、ΔH=-30°、S=1.5、L=0.8` 为例：

| 端口 | 计算 | 应设置的整数 | Verilog 示例 |
|---|---|---:|---|
| `par_b0_hc` | `120×65536` | 7864320 | `32'd7864320` |
| `par_b0_q` | `round(2/45×1048576)` | 46603 | `32'd46603` |
| `par_b0_dh` | `-30×65536` | -1966080 | `-32'sd1966080` |
| `par_b0_s1` | `round(0.5×16384)` | 8192 | `32'sd8192` |
| `par_b0_l1` | `round(-0.2×16384)` | -3277 | `-32'sd3277` |

如果只希望关闭某段，推荐 `CH_Enable[i]=0`。若某段启用但要求不改变 S/L，则
`par_b{i}_s1=0`、`par_b{i}_l1=0`；若同时要求不改变 H，则再设置
`par_b{i}_dh=0`。

段参数可连接 AXI-Lite 寄存器或外部控制逻辑。虽然 IP 支持运行期调整，但为避免同一帧
内不同像素使用不同参数，**推荐在帧间隙统一更新，并在一帧期间保持稳定**。修改
`NUM_BANDS`、`WORK_MODE` 等综合参数则必须在 Vivado 中重新定制 IP，不能靠上述运行期
端口完成。

---

## 1. General 标签页

### 1.1 Behavior Implementation（`IMPL_MODE`）

**含义**

选择 IP 的行为实现方式。核心中同时包含 LUT 查表和函数定点两套数据通路，
默认 `IMPL_MODE` 跟随多段色彩均衡器节点的代码生成模式，在 Vivado 的
Re-customize IP 窗口中可再次切换。

| 下拉选项 | 值 | 数据通路 | 段参数与 CH_Enable |
|---|---:|---|---|
| Remap HSL color space using LUT file | 0 | 使用生成期烘焙的 H 偏移和 S/L Q14 乘子表 | 隐藏 |
| Call a function to modify HSL color space | 1 | 运行期调用定点函数计算各取色器段权重 | 按 NUM_BANDS 显示 |

**端口联动**

- `IMPL_MODE=0`：隐藏 `par_b{i}_*`、`CH_Enable`、`NUM_BANDS`、`WORK_MODE`
  和 `DSP_PIPE`，只保留像素流及通用配置端口。
- `IMPL_MODE=1`：显示函数模式配置；`par_b{i}_*` 仍按 `NUM_BANDS` 隐藏未使用段。
- 两种实现共用同一像素流接口，切换时不需要更换 IP 文件或修改 demo 顶层。

**建议**

- 需要最少运行期端口、使用固定色彩风格时选择 LUT file。
- 需要在 FPGA 中动态调整取色器参数时选择 Function，并将段参数连接到寄存器
  或外部控制逻辑。

### 1.2 Pixel Bits（`PIX_BITS`）

**含义**

设置 H、S、L 每个通道的像素数据位宽。三个通道共用相同的位宽。

**可选值**

`8`、`10`、`12`、`14`、`16` 位。

**对数据接口的影响**

像素流按 `{H, S, L}` 打包，因此总数据宽度为：

```text
3 × PIX_BITS
```

| PIX_BITS | 单通道位宽 | 打包后的数据宽度 | 量化上限 `MAXV` |
|---:|---:|---:|---:|
| 8 | 8 bit | 24 bit | 255 |
| 10 | 10 bit | 30 bit | 1023 |
| 12 | 12 bit | 36 bit | 4095 |
| 14 | 14 bit | 42 bit | 16383 |
| 16 | 16 bit | 48 bit | 65535 |

其中 `MAXV = 2^PIX_BITS - 1`，用于色相、饱和度和亮度的量化及定点换算。

**对精度和资源的影响**

- 位宽越高，量化误差越小，但数据通路、乘法器输入和部分计算单元更宽。
- 位宽越低，接口和运算资源通常更少，但量化误差增大。
- 该配置只改变数据的表示精度，**不会改变图像的分辨率或帧率**。

**建议**

- 常规 8 bit 视频链路选择 `8`。
- 需要保留更多颜色细节或上游本来就是 10/12 bit 数据时，选择与上游一致的位宽。
- 不建议仅为了“看起来精度更高”而盲目选择 16 bit，应同时评估 DSP/LUT 资源和目标频率。

### 1.3 Max Width（`MAX_WIDTH`）

**含义**

预留的最大行宽参数，供包含行缓冲或窗口操作的 IP 算子使用。

**可选值**

`320`、`400`、`600`、`640`、`1000`、`1280`、`1920`、`2048`、`3840`、
`4096`、`7680`、`8192`。

**当前多段色彩均衡器中的实际作用**

当前 `multi_band_eq` 是逐像素点算子，不依赖相邻行或相邻像素，**没有行缓冲**。
因此，在当前 V2.0 数据通路中：

- 修改 `MAX_WIDTH` 不会改变处理结果；
- 不会改变帧尺寸；
- 不会改变当前节点的 BRAM 用量；
- 不会改变当前节点的吞吐量或延迟。

该参数保留在接口中，主要是为了与后续包含窗口算子的编组保持统一配置方式。
对于真正使用行缓冲的算子，较大的 `MAX_WIDTH` 通常意味着更多 BRAM 资源。

**建议**

当前仅使用多段色彩均衡器时，保持导出默认值即可，例如 `3840`。

### 1.4 Number Of Color Picker Channels（`NUM_BANDS`）

**含义**

设置有效的取色器通道数量。每个通道可针对一个色相带设置独立参数。

**可选值**

`1～16`，默认与 ispflow 中多段色彩均衡器节点的取色器数量一致。

**对接口的影响**

- `CH_Enable` 的位宽为 `NUM_BANDS` 位，即 `CH_Enable[NUM_BANDS-1:0]`。
- 仅显示有效通道的参数端口：`par_b{i}_hc/q/dh/s1/l1`。
- 例如设置为 `4` 时：
  - `CH_Enable` 为 `[3:0]`；
  - 显示 `par_b0_*`、`par_b1_*`、`par_b2_*`、`par_b3_*`；
  - `par_b4_*～par_b15_*` 在 IP 定制界面中隐藏。
- demo 顶层和 testbench 使用 SystemVerilog `.*` 连接，可自动适应这些被隐藏的端口，
  不需要在修改通道数后重新导出 demo。

**对算法结构的影响**

IP 保留固定的 16 路计算结构，并屏蔽 `i >= NUM_BANDS` 的通道。超出有效范围的
通道对输出没有贡献。`NUM_BANDS` 是综合时的配置，不是运行时动态增删硬件通道。

**与 `CH_Enable` 的关系**

`NUM_BANDS` 决定哪些通道存在于当前 IP 配置中，`CH_Enable[i]` 决定有效通道 `i`
在运行时是否启用：

- `CH_Enable[i] = 1`：通道 `i` 参与色彩调整；
- `CH_Enable[i] = 0`：通道 `i` 被 bypass，其权重贡献为零，该通道不对像素产生调整。

`CH_Enable` 是 IP 的输入端口，可在 FPGA 运行过程中修改。建议帧间隙调整通道参数，
避免一帧内出现不一致的处理结果。

**注意事项**

- 减少 `NUM_BANDS` 会改变实际参与处理的通道集合，输出可能随之改变。
- 默认通道数下，demo testbench 执行逐位 golden 哈希检查；改为其他通道数后，
  testbench 执行帧数完整性检查。
- 通道参数为运行时输入，可连接 AXI-Lite 寄存器或外部控制逻辑。

### 1.5 Work Mode（`WORK_MODE`）

**含义**

选择多段色彩均衡器的工作方式，对应 ispflow 节点的并联/串联参数。
XGUI 默认值与当前 ispflow 节点的工作方式一致。

| XGUI 选项 | 值 | 工作方式 | 主要特点 |
|---|---:|---|---|
| Color picker parallel operation | 0 | 取色器并联：各通道并行计算，再汇总调整量 | 延迟较低，并行数据通路较多 |
| Color picker cascade operation | 1 | 取色器串联：各通道按级联顺序逐级处理 | 流水级数更多，输出延迟较大 |

**对数值结果的影响**

两种结构遵循相同的定点算法，在相同通道参数和 `CH_Enable` 下输出逐位一致。
工作方式只改变计算结构和延迟，不改变颜色调整的语义。

**对延迟的影响**

在 `DSP_PIPE=0` 时：

- 并联结构的基准延迟为 5 拍；
- 串联结构按固定 16 段计算，基准延迟为 20 拍。

`DSP_PIPE` 会在所选工作方式上继续增加流水延迟：

- 并联：`5 + DSP_PIPE` 拍；
- 串联：`16 × (1 + DSP_PIPE) + 4` 拍。

**对资源的影响**

并联与串联是两种数据通路组织方式，不应简单理解为“串联一定节省 DSP”。
实际 LUT、DSP 和寄存器用量取决于 `PIX_BITS`、`GSTRATEGY`、`DSP_PIPE` 以及综合器
优化结果，应以目标器件的综合报告为准。

**建议**

- 优先追求较低输出延迟：选择 `Color picker parallel operation`。
- 需要与既有 ispflow 串联处理结构保持一致：选择 `Color picker cascade operation`。
- 仅修改工作方式无需重新导出 demo；IP 会在综合时通过 `WORK_MODE` 选择对应结构。

---

## 2. Optimization 标签页

### 2.1 Multiply Strategy（`GSTRATEGY`）

**含义**

控制定点乘法器在 FPGA 中的实现方式，主要影响 LUT/DSP 资源分配及时序。

| 选项 | 值 | 实现方式 | 适用场景 |
|---|---:|---|---|
| Area (folded operators) | 0 | 通过 `use_dsp=no` 强制使用 LUT | DSP 资源紧张，或希望减少 DSP 使用量 |
| Balanced (synthesizer chooses) | 1 | 由综合器自行选择 LUT 或 DSP | 希望综合器根据目标器件和时序自动权衡 |
| Performance (use DSP) | 2 | 通过 `use_dsp=yes` 强制使用 DSP | 希望改善乘法路径时序，且 DSP 资源充足 |

**对数值结果的影响**

只改变乘法器的硬件映射方式，不改变定点运算口径，输出应保持逐位一致。

**对 FOLD 的影响**

只有选择 `Area (GSTRATEGY=0)` 时，`FOLD` 才允许编辑；选择 `Balanced` 或
`Performance` 时，FOLD 下拉框为灰色，不可配置。

**建议**

- 默认需要乘法路径性能时选择 `Performance`。
- DSP 资源不足时选择 `Area`，并同时评估 LUT 用量和最高时钟频率。
- 不确定时选择 `Balanced`，以综合报告中的 DSP、LUT 和时序结果为准。

### 2.2 Fold Factor（`FOLD`）

**含义**

预留的窗口算子折叠/复用因子，用于让计算单元在多个时钟周期内复用，以换取更少的
硬件资源。

**可选值**

- `x1`：不折叠；
- `x2`：按 2 路折叠，面向每 2 时钟处理一个样本的结构；
- `x4`：按 4 路折叠，面向每 4 时钟处理一个样本的结构。

**当前多段色彩均衡器中的实际作用**

当前 `multi_band_eq` 是逐像素点算子，当前白名单实现始终按 II=1 工作，未使用窗口
算子的折叠结构。因此，在当前 V2.0 数据通路中，`FOLD` 是预留参数：

- 不改变当前节点的输出；
- 不改变当前节点的吞吐量；
- 不改变当前节点的资源分配；
- 不应把它与 `DSP_PIPE` 混为一谈。

`FOLD` 面向后续窗口算子。届时，较大的折叠因子通常意味着更多计算单元复用、
较少资源，但单像素服务时间和调度延迟增加。

**可编辑条件**

- `GSTRATEGY=0`：可编辑；
- `GSTRATEGY=1/2`：灰色，不可编辑。

**建议**

当前仅使用多段色彩均衡器时，保持默认值即可。

### 2.3 Band Pipeline（`DSP_PIPE`）

**含义**

在 `func_fixed` 的高斯权重计算路径中插入流水寄存器，切断组合路径，以改善时序。
它不改变吞吐量，也不改变像素数据。

| 选项 | 值 | 寄存器插入位置 | 额外延迟 |
|---|---:|---|---:|
| Combinational (lowest latency) | 0 | 不插入额外流水寄存器 | 0 拍 |
| Pipeline band_pre | 1 | `band_pre` 与 `band_mid` 之间 | 1 拍 |
| Pipeline band_pre+band_mid | 2 | 在两个计算阶段边界均插入寄存器 | 2 拍 |
| Full internal DSP pipeline (highest Fmax) | 3 | DSP 输入、乘法与输出内部全流水 | 多拍 |

相关计算阶段如下：

- `band_pre`：计算色相角距、`x²` 和高斯函数自变量 `u`；
- `band_mid`：使用定点多项式计算 Q14 高斯权重；
- `post`：使用权重调整 H/S/L 通道。

**对性能和资源的影响**

- `DSP_PIPE=0`：延迟最低，但组合路径最长，目标频率通常最低。
- `DSP_PIPE=1`：切断部分组合路径，是延迟和时序之间的折中。
- `DSP_PIPE=2`：切断两个计算阶段边界，兼顾延迟和时序。
- `DSP_PIPE=3`：启用 DSP 内部输入、乘法及输出寄存器，优先获得最高 Fmax；
  要求 `GSTRATEGY` 不为 Area。

**对吞吐量和数据的影响**

- 仍支持每个时钟接收一个像素，即 II=1。
- 增加的是首个输出的延迟，不是降低持续吞吐量。
- 四种配置与 Dart 定点参考实现逐位一致，已分别进行仿真对拍。
- 增加的资源主要是寄存器，不等同于增加 DSP 数量，也不等于折叠复用。

**延迟估算**

按当前固定 16 段结构：

- 并联结构：0～2 档为 `5 + DSP_PIPE` 拍，第 3 档为 89 拍；
- 串联结构：0～2 档为 `16 × (1 + DSP_PIPE) + 4` 拍，第 3 档为 889 拍。

**建议**

- 目标频率较低且希望延迟最小：选择 `0`。
- 一般时序优化：选择 `1` 或 `2`。
- 需要最高 Fmax 和 DSP 内部全流水：选择 `3`。

出厂默认值为 `3`，优先保证复杂 ISP 系统中的时序健壮性。若手动改为较低档位后
出现 `Timing 38-282`、WNS 为负，应在 Customize IP 的 Optimization 页将 Band
Pipeline 改为 `Full internal DSP pipeline (highest Fmax)`，重新 Generate Output
Products，再复位并运行综合与实现。不要通过删除时钟约束或添加 `false_path`
掩盖问题。若仍未收敛，应根据新的最差路径继续优化 RTL，或在系统允许时降低
`aclk` 频率并同步修改 XDC 的 `create_clock` 周期。

---

## 3. 配置项之间的关系

### 3.1 `NUM_BANDS` 与 `CH_Enable`

- `NUM_BANDS` 是综合配置，决定有效通道数量和接口形态。
- `CH_Enable` 是运行时输入，决定每个有效通道是否实际参与处理。
- 通道被 bypass 后只忽略该通道的调整作用，不会破坏其他通道或像素流握手。

### 3.2 `GSTRATEGY` 与 `FOLD`

- `GSTRATEGY` 决定乘法器使用 LUT 还是 DSP。
- `FOLD` 仅在 Area 模式下开放，属于预留的窗口算子折叠选项。
- 当前多段色彩均衡器中，修改 `FOLD` 不改变处理结果或性能。

### 3.3 `GSTRATEGY` 与 `DSP_PIPE`

- `GSTRATEGY` 决定乘法器“用什么硬件实现”。
- `DSP_PIPE` 决定计算路径“插入多少级流水”。
- 两者可以组合使用。例如：
  - `GSTRATEGY=Performance + DSP_PIPE=3`：偏向高 Fmax；
  - `GSTRATEGY=Area + DSP_PIPE=0`：偏向较少寄存器和较低延迟；
  - `GSTRATEGY=Balanced + DSP_PIPE=1`：兼顾资源、时序和延迟。

### 3.4 `PIX_BITS` 与其他优化项

- `PIX_BITS` 决定数据精度和数据通路宽度。
- 位宽增加后，乘法路径和资源压力可能增大，此时可结合 `GSTRATEGY` 和
  `DSP_PIPE` 优化实现方式与时序。

---

## 4. 推荐配置示例

| 使用目标 | 建议配置 |
|---|---|
| 常规 8 bit、低延迟处理 | `PIX_BITS=8`，`GSTRATEGY=Performance`，`DSP_PIPE=0` |
| 较高目标频率 | `GSTRATEGY=Performance`，`DSP_PIPE=3` |
| DSP 资源受限 | `GSTRATEGY=Area`，根据综合报告评估 LUT 用量 |
| 资源与时序折中 | `GSTRATEGY=Balanced`，`DSP_PIPE=1` |
| 仅处理少量色相带 | 将 `NUM_BANDS` 设置为实际取色器数量，减少无作用通道 |
| 需要运行时通道开关 | 保持所需 `NUM_BANDS`，通过 `CH_Enable[i]` 控制各通道 bypass |

最终配置应以目标器件的综合资源报告和时序报告为准。不同 FPGA 系列、位宽、
通道数和目标频率下，LUT、DSP、寄存器及最高可达频率会有所不同。

---

## 5. 在 Vivado 中配置实例化 IO

板级引脚不在 DebugToolSet 的 demo_prj 导出对话框中配置，而是直接使用
Vivado 的 **I/O Planning**。该界面除 `PACKAGE_PIN` 和 `IOSTANDARD` 外，
还可设置驱动强度、斜率、上下拉、片外端接和差分选项，功能更完整。

需要下载到板卡时：

1. 打开 Implemented Design，进入 I/O Planning。
2. 按板卡原理图和 Bank 电压为全部逻辑端口分配引脚与电平。
3. 保存约束。若保存为 `demo/pins.xdc`，`create_demo_project.tcl` 会自动
   将其加入 `constrs_1`；使用其他文件名时，请手动加入该约束集。
4. 重新运行实现和 Generate Bitstream。

未分配前的 NSTD-1 / UCIO-1 仅表示尚未做板级引脚配置。不要仅为消除 DRC
而随意分配引脚或降低其严重级别。
