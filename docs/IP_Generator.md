# ISP Studio IP Generator（编组 → FPGA Verilog IP 包）

ISP Studio 编组右键菜单「生成Verilog IP」：把编组（像素流式子图）导出为可
综合 Verilog IP 包，针对 FPGA 行级实时处理优化。实时性 ↔ RTL 规模的权衡
暴露为 IP 定制参数（Verilog `parameter`，Vivado 等工具的 Customize IP 界面
可直接改）。

## 当前范围（v1/v2）

- **节点**：`multi_band_eq`、六种 ColorTrans（`csc_rgb2yuv/rgb2hsl/yuv2rgb/yuv2hsl/hsl2rgb/hsl2yuv`）及
  `color_temp_adjuster`，均使用 `codegenMode=lut_fixed` 或 `func_fixed`。
  `csc_yuv2rgb` 与 `csc_rgb2yuv` 节点均可选择 BT.601（SD）/ BT.709（HD）/
  BT.2020（UHD，默认）矩阵标准；IP 参数 `YUV_STANDARD`（0/1/2）在
  func_fixed 下可于 Customize IP 或导出配置中切换，LUT 模式按生成时选择烘焙。
  均衡器保留原双实现核心；其余节点由 `fixed_ip_verilog.dart` 生成拓扑级联的
  一拍定点核心，支持 LUT ROM、Q14/Q16 整数计算及 ready/valid 背压。
  其余节点按 `docs/IP_Generator_Plan.md` 白名单逐步扩展。
- **目标平台**：Vivado / Libero / 通用 Verilog（Quartus/Lattice/Efinix 列出
  但禁用标注「待完成」）。
- **视频输入**：`none`（直通，核心像素流端口直出）；DVP/LVDS/MIPI CSI-2 留
  后续。
- **验证**：testbench + 一键仿真（探测 Icarus Verilog，有一键跑 PASS/FAIL，
  没有只出文件）。
- **多节点规则**：每个节点生成独立 IP 包与独立 Vivado 仓库；根 demo 顶层仅
  实例化并按图连接这些 IP，不再生成图级合并 IP。各实例使用
  `ISP_IP_<节点英文名>`，同类重复实例追加 `_2`、`_3` 后缀避免组件冲突。

### v2.0 双实现选择（IMPL_MODE）

- 统一核心同时包含 LUT 查表与函数定点数据通路：`IMPL_MODE=0` 为
  **Remap HSL color space using LUT file**，`IMPL_MODE=1` 为
  **Call a function to modify HSL color space**，默认跟随节点 codegenMode。
- `IMPL_MODE=0` 时 XGUI 隐藏全部函数段参数；`IMPL_MODE=1` 时按 NUM_BANDS
  显示。像素流接口保持一致，切换实现不需要更换 IP 文件或修改 demo 顶层。

### 色温调节器 IP：14 位运行期控制/测量（单节点）

单节点色温 IP 除像素流外还透出一对固定宽度端口（core/top/AXI/Libero 各层）：

| 端口 | 方向 | 位宽 | 说明 |
|---|---|---|---|
| `cct_in` | in | 14 | 目标色温 K（1800~12000，核内钳位） |
| `cct_out` | out | 14 | 实测输入色温 K，每帧更新（复位值 6500） |

- 图像接口是 RGB 打包像素流（每通道 `PIX_BITS` 位），ready/valid + sof/eol。
- **CCM 由内部自动生成**：`white(cct_in)/white(cct_out)` 的 von Kries 对角增益
  （Q14），白点用生成期烘焙的 512 段 Q16 表（6600K 断点两侧各一套）+ 倒数表
  算比值，3×3 系数**不作为参数或端口暴露**。目标与参考相同时短路为恒等。
- **测量**：核心逐帧累加输入 R/G/B，帧起始投入控件 FSM（sRGB→XYZ → McCamy
  色度比 → 48 拍长除法 → Q14 三次多项式），与 Dart 参考
  `pipeline/color_temp_hw.dart` 逐位一致；FSM 约 65 拍，**一帧像素数需 ≥96**。
- **时序口径**：片上无帧缓存，第 k 帧的增益用第 k−2 帧的测量（两帧后收敛）；
  tb/golden 用同一口径，帧起始那拍即切到新增益以保证整帧像素与增益对齐。
- 编组含多个节点时，逐节点 IP **关闭**这对端口（互连顶层没有唯一的控制/测量
  口），沿用生成期烘焙的增益。
- **表存储选项 `USE_BRAM`**（Verilog 参数，默认 1）：1 = 白点/倒数表放**块 RAM**
  （CLB LUT 约少 40%，实测 5786 LUT）；0 = 分布式组合 ROM（上一版实现，无读延迟、
  8180 LUT）。两套实现同时打进核、由 `generate` 选择，表数据与插值写法共用，
  **结果逐位一致**（iverilog 与 Vivado 行为仿真同一 golden）。导出对话框「色温表
  存 Block RAM」复选框决定参数默认值；Vivado Customize IP 的 **Optimization 页**
  有「Use Block RAM (USE_BRAM)」下拉，改值后重新生成 IP 即生效。
  **改值生效的前提**：fixed-IP 的 XGUI 必须带 `update_MODELPARAM_VALUE.*` 同步 proc
  （用户参数 → 模型参数），否则 Customize IP / `set_property CONFIG.X` 只改用户参数，
  生成的 wrapper 仍用打包默认值（曾表现为改选项后综合结果完全不变）。当前生成器已为
  PIX_BITS / MAX_WIDTH / GSTRATEGY / FOLD / DSP_PIPE / YUV_STANDARD / USE_BRAM 全部补齐。
  两个坑（都已在当前实现里规避）：① 组合 ROM 的查表**不能写在 `function` 里**读
  module 级数组——XSim 会返回 X、综合也会把 ROM 折叠掉（曾表现为模块只剩 34 LUT
  且仿真全 X），必须写成 `always @*` 组合块；② `(* use_dsp = "no" *)` 只认**模块
  级**属性。
- **资源口径**：白点表/倒数表放**块 RAM**（`ram_style="block"`，双端口读，
  插值两端点一拍取出；组合 ROM 多路器实测量级 4×513×19 表 ≈ 5.0k LUT、
  1024×24 倒数表 ≈ 2.6k LUT）。测量把 McCamy 的 `n=A/B` 预热成对累加和的
  **6 项合并系数**（原 `X/Y/Z/S` 要 12 次宽常数乘法），多项式常数取置位数少的
  6823/5520、累加和 64→48 位。整 IP 实现后 **5786 LUT / 1120 FF / 6 BRAM /
  2 DSP**（原 9924 LUT），WNS +20.3 ns。
- **DRC 口径**：控制块拆成 `_ct_romr`/`_ct_romb`/`_ct_romq`/`_ct_gain`/`_ct_meas` 五个
  `keep_hierarchy` 子模块（单模块原语过多会触发 `[Netlist 29-101]`），四个子模块
  与像素缩放器都带**模块级** `(* use_dsp = "no" *)`（挂在 wire/assign 上 Vivado
  不认）；`nq²/nq³` 用 DSP48 原语（AREG/BREG/MREG/PREG 全开、内部同步复位），
  FSM 全同步复位 → 零 DPIP/DPOP/DPOR。`demo/timing.xdc` 已把 `cct_in`/`cct_out`
  纳入 I/O 延迟约束（否则 methodology DRC 每 bit 报一条 TIMING-18）。
  Vivado 2020.2 实测：DRC 仅 2 条 Advisory（引脚未分配）、methodology DRC 0 条、
  综合/实现日志 0 条 WARNING。

### v2.0 通道配置（func_fixed）

- `NUM_BANDS`：1..16，默认与 ispflow 取色器数量一致，XGUI 下拉可配。
  **未启用的段单元在 elaboration 期就不实例化**（并联与串联两条全流水路径的
  pre/mid/post 都包在 `if (NUM_BANDS > i)` 的 generate 条件块里；legacy 档
  DSP_PIPE=0/1/2 的 pre/mid/post 同样裁剪；并联的像素直通延迟线全段共享一份）。
  串联路径的未启用段保留段内延迟线（它定义该级流水深度），并用 `hof/sof/lof`
  11 拍直通补偿 `band_ser_post` 自身在 w=0 时的恒等延迟，因此整链 LAT 与 golden
  与段数无关。实测 2 段配置：并联全流水 2883 → 1893 LUT、6331 → 3601 FF、
  127 → 43 DSP；legacy DSP_PIPE=2 并联 2703 → 1729 LUT、175 → 91 DSP；串联全流水
  2 段 7297 LUT（其中 5235 为 LUT-as-Memory/SRL 的段内延迟线）/ 3740 FF / 82 DSP，
  同一 RTL 的 16 段为 21981 LUT / 20742 FF / 614 DSP（＝裁剪前 2 段的等价硬件）。
  golden 与 16 段配置行为不变。改 `NUM_BANDS` 后需重新生成/综合该 IP。
- `CH_Enable[NUM_BANDS-1:0]`：每 bit 对应通道 Enable，1 启用、0 原始像素直出；
  作为 core/top/AXI/Libero 输入端口透传，不再是 parameter。未启用通道的
  par_b{i}_hc/q/dh/s1/l1 在 XGUI 中隐藏。IP 元数据版本为 2.0，XGUI 文件为
  `xgui/<top>_v2_0.tcl`，仅 General / Optimization 两页，全部下拉菜单。
- 固定 16 路结构在权重处屏蔽未使用段；lut_fixed 保持原查表通路，不改变
  其数值口径。串联结构延迟按固定 16 段计算（未启用段用 11 拍直通补偿填平），
  tb 排空同步放大。
- `DSP_PIPE`：0 纯组合、1 权重前段插一拍、2 权重前段与中段各插一拍、
  3 DSP 内部全流水（最高 Fmax，要求 `GSTRATEGY != 0`）。第 3 档以统一
  `full_en` 同步暂停整条数据通路，支持输入气泡和输出背压，吞吐仍为 II=1；
  段参数、原始 H/S/L 与串联进位均随像素同拍传递。每个乘法按输入寄存、
  MREG、PREG 和宽乘法补充输出寄存描述，舍入与缩窄放在 PREG 之后。
  UltraScale+ 并联路径的 `pre/mid` 乘法使用 DSP48E2 原语并显式设置
  `AREG=1/BREG=1/MREG=1/PREG=1`，并以 `OPMODEREG=0` 让常量乘法 OPMODE 直接生效；
  18 位无符号乘法在 PREG 后增加一级 `A<<18` 符号补偿寄存；串联使用独立旧模块。
  延迟为并联/单段 89 拍、固定 16 段串联 889 拍；旧档位及 LUT 通路保持原结构不变。
- RGB→HSL（func_fixed，`GSTRATEGY != 0` 且 `DSP_PIPE=3`）走**全流水分级数据
  通路**（`codegen/hsl_pipe_verilog.dart`，单节点 23 拍）：Q14 归一化 → 4 级
  定点除法（牛顿迭代倒数 + 精确余数修正，无除法器）→ 缩放。每级乘法用
  core 内的 `${top}_hsl_mul`（DSP48E2 原语，AREG/BREG/MREG/PREG 全 1），三个
  内部寄存器级分别由所在流水级的 ready 驱动（逐级弹性，支持气泡/背压）。
  三段组合逻辑（`_hsl_m` 归一化+max/min、`_hsl_q` 种子 ROM+规格化、
  `_hsl_corr` 余数修正+色相）各自成子模块并带 `keep_hierarchy`，核心只留
  流水寄存器与 DSP 原语——综合后不再出现 `[Netlist 29-101]/[29-43]`
  「not ideal for floorplanning」。实测 xczu15eg：1589 LUT / 11 DSP /
  WNS +18.7ns / **零 DPIP-DPOP 建议**，数值与组合版逐位一致（golden 哈希
  不变）。面积档（`GSTRATEGY=0`）仍为组合函数 + `use_dsp="no"`
  （13565 LUT / 0 DSP / 零建议）。
- HSL→RGB（func_fixed，`GSTRATEGY != 0` 且 `DSP_PIPE=3`）同样走全流水 DSP 通路
  （`hsl2Rgb`，单节点 14 拍）：Q14 归一化 + `h%16384` + `h3`/三条色相支路 →
  `l×s`（1 个 DSP）→ `q/p/qm` 与每通道乘法操作数/支路选择 → `qm×op`
  （3 个）→ 还原 r/g/b → `×MAXV`（3 个）→ 舍入钳位，全程乘法+移位无除法器。
  三段组合逻辑拆成保留层级子模块 `_hsl2rgb_n/_q/_c`（扁平网表即使只有
  ~800 LUT 也会报 `[Netlist 29-101]`）。实测 xczu15eg：716 LUT / 726 FF /
  7 DSP / WNS +19.2ns，**综合与实现 0 条 WARNING**、零 DPIP/DPOP、
  零 floorplanning 警告；数值与 Dart 参考逐位一致。面积档仍为组合函数 +
  `use_dsp="no"`（3 拍）。
- HSL→YUV（`csc_hsl2yuv`，同条件）把上面两条通路串起来：HSL→RGB 全流水段
  （复用 `_hsl2rgb_n/_q/_c`，末级输出 0..MAXV 的 R/G/B 码）→ BT.601 定点矩阵
  （Y/U/V 各 3 个乘加，系数为烘焙常量，含负系数故 DSP 用 `SIGNED_B=1`）→
  舍入钳位，单节点 18 拍、16 个 DSP48E2。实测 xczu15eg：IP OOC 综合
  1110 LUT / 950 FF / 16 DSP，综合与实现 0 条 WARNING、零 DPIP/DPOP、
  零 floorplanning 警告；面积档仍为组合函数 + `use_dsp="no"`（1 拍）。
  YUV 矩阵标准由 `YUV_STANDARD` 参数选择（0/1/2，默认 BT.2020，与节点
  「YUV 标准」选项一致）。
- YUV→HSL（`csc_yuv2hsl`，同条件）在其之前接一段 BT.601 矩阵（4 个 DSP，
  `U'/V'` 为有符号差值故 `SIGNED_A/SIGNED_B=1`）→ 累加舍入钳位得到 R/G/B 码 →
  复用 RGB→HSL 的 23 拍通路（`_hsl_m/_hsl_q/_hsl_corr`），单节点 28 拍、
  15 个 DSP48E2。YUV 矩阵固定 BT.601（与 `yuvToRgb()` 一致），不暴露
  实测 xczu15eg：1704 LUT / 2136 FF / 15 DSP / WNS +17.7ns，
  综合与实现 0 条 WARNING、零 DPIP/DPOP、零 floorplanning 警告；面积档仍为
  组合函数 + `use_dsp="no"`（三段式 3 拍）。
- **多节点编组的 demo** 不生成图级合并 IP：逐节点各打一个独立 IP 包
  （`<ident>/` 子目录，各带自己的 core/top/axis/xgui/README/UserGuide），
  `demo/demo_top.v` 只做实例化与互连，`create_demo_project.tcl` 逐节点
  `create_ip` + `create_ip_run` 并写入各节点自己的 CONFIG（含 `YUV_STANDARD`、
  `IMPL_MODE/WORK_MODE/NUM_BANDS`），根目录另给组合 testbench
  `tb_<组名>.v`（把三个 IP 串起来对拍 golden）。实测
  `YUV_MBC_EQ`（YUV→HSL + 多段色彩均衡器 + HSL→YUV）：三包 OOC 合计
  6642 LUT / 10757 寄存器 / 158 DSP，父工程实现后 5622 LUT / 9229 寄存器 /
  158 DSP（顶层综合会裁掉各包边界开销，比三包之和小 ~15%），WNS +15.6ns，
  组合 tb golden PASS，综合与实现 0 条 WARNING。
  多节点 demo 的实现策略固定为 `Performance_Explore`——Vivado 默认实现流程在
  单 SLR 器件上会请求 `place_design -ultrathreads` 报
  `[Vivado_Tcl 4-1400]`。
- demo 工程的未约束 I/O 两条 DRC（`NSTD-1`/`UCIO-1`）：无 `pins.xdc` 时由
  `demo/clock_route.tcl`（pre-opt_design 钩子）声明为 `Advisory`——XDC 不支持
  `if`/`foreach`，且 Vivado 2020.2 只接受 `Advisory`（`Info` 报
  `[Vivado 12-2485] Invalid severity Info`）；`report_drc` 中仍可见，
  量产请用 IP 页「引脚约束」生成的 `pins.xdc` 取代。

## 使用

1. 编组（单节点 `multi_band_eq`，lut_fixed 或 func_fixed）上右键 →「生成Verilog IP」。
2. 校验不过弹错误；通过则弹生成选项对话框。Vivado 目标可选择本机 Vivado
   版本（默认优先 2020.2，未安装时才选最新版本；上次明确选择优先回填），
   按该版本的器件库筛选 PART，并配置 `PIX_BITS` / `MAX_WIDTH` 等参数。
3. 确定后打开 IP 标签页：左侧文件清单、右侧 Verilog 高亮代码区，工具栏
   「导出IP包」写盘、「一键仿真」跑 iverilog。`README.md` 后同时附带
   `<IP名>_V2.0_UserGuide.md` 用户指南，并随 IP 包和 demo_prj 一起导出：
   均衡器编组取 `docs/ISP_IP_MBC_EQ_V2.0_UserGuide.md`、YUV→RGB 取
   `docs/ISP_IP_YUV_to_RGB_V2.0_UserGuide.md`、RGB→YUV 取
   `docs/ISP_IP_RGB_to_YUV_V2.0_UserGuide.md`、RGB→HSL 取
   `docs/ISP_IP_RGB_to_HSL_V2.0_UserGuide.md`、HSL→RGB 取
   `docs/ISP_IP_HSL_to_RGB_V2.0_UserGuide.md`、HSL→YUV 取
   `docs/ISP_IP_HSL_to_YUV_V2.0_UserGuide.md`、YUV→HSL 取
   `docs/ISP_IP_YUV_to_HSL_V2.0_UserGuide.md`（替换其中的 IP 名前缀）。
4. Vivado 目标可点「导出demo_prj」：应用从当前 Vivado 的 `get_parts` 器件库
   异步读取真实型号（按 Vivado 路径缓存），对话框提供 Category / Family /
   Package / Speed / Temperature / Static power 联动筛选及 Search，点选目标
   PART；右侧配置 `PIX_BITS` / `MAX_WIDTH` / `GSTRATEGY` / `FOLD` /
   `DSP_PIPE`，以及 YUV→RGB IP 的 `YUV_STANDARD`（跟随节点 / BT.601 /
   BT.709 / BT.2020）。选中器件的实际 family 同步写入 IP 打包脚本。点击「生成工程」后，
   在「请输入工程名」窗口中设置工程名（允许字母、数字和下划线）。默认工程名优先取当前
   `.ispflow` 流程的英文文件名（不含扩展名，空格等字符转换为下划线），例如
   `YUV2HSL.ispflow` 对应 `YUV2HSL`；未保存或中文文件名回退到既有英文名
   `HSL_Multi_Band_Color_EQ` / `YUV_Multi_Band_Color_EQ`，其他编组回退到 `demo_prj`。
   再选择导出父目录，应用先创建 `<父目录>/<工程名>/`，将 IP 包和导出日志写入该目录，
   并运行 `vivado -mode batch -source demo/create_demo_project.tcl`，生成
   `<父目录>/<工程名>/demo/<工程名>/<工程名>.xpr`；启动后打开独立「Vivado 日志」标签页，流式显示完整日志，
   会话跨页面切换保留，不再挤占 IP 页面底部。工程生成时关闭 IP 缓存以避免长路径
   与弃用缓存参数警告；仅将已审查的组合 Horner DSP 级联提示 `Synth 8-5409`
   及固定 16 段未启用变体的空模块/未连接/裁剪提示 `Synth 8-3330`、`8-3332`、
   `8-3936`、`8-6014`、`8-7129` 降为 Info；DRC、时序和其他 warning 不屏蔽。
   应用从 Windows 注册表 Vivado 卸载信息、PATH 及常见 Xilinx/AMD 安装目录
   探测全部版本；安装时修改过路径也可经注册表发现（安装后手工移动且注册表
   未更新的目录不在自动探测范围）。demo 的 `create_ip` 会显式应用七项 IP 配置，
   其中 `IMPL_MODE` 跟随节点 codegenMode，`NUM_BANDS` 取 ispflow 段数，均可在
   Vivado XGUI 中继续修改。demo 顶层和 tb
   均例化以实际 `topName` 命名的可配置 IP（不再是统一的 `eq_ip`）。demo 顶层以 SystemVerilog `.*` 连接，
   并显式例化 `IBUF + BUFGCE`（CE 恒为 1）将 `aclk` 接入全局时钟网络，避免 XDC 依赖综合后内部网名及 UltraScale+ 的 IBUFG 重定向警告。
   tb 使用显式 AXI 端口连接，避免 Post-Implementation 端口重命名导致隐式 `.*` 绑定失败。
   段参数按名称连接，无需在修改通道数后重新导出。tb 默认做逐位 golden 哈希检查；若修改了 IP 配置，
   将 tb 的 `GOLDEN_CHECK` 设为 0 可改为帧数完整性检查。tb 不引用 DUT 内部的 RTL
   参数或层次对象，因此同一 tb 可用于行为、Post-Synthesis 与 Post-Implementation 仿真。

生成的 `.v` 与 `.tcl` 统一使用英文 ASCII 注释，XGUI 也统一纯英文，避免任意 Vivado 版本的文本兼容问题；写盘编码仍随所选 Vivado 版本变化：
2020.2 及旧版 Windows 使用系统代码页（本机 GBK），2024.2 及新版和其他
平台使用 UTF-8；XGUI 页签、参数、下拉选项和说明文本统一使用纯英文 ASCII。编码问题与排查过程详见
`docs/Vivado_Text_Encoding.md`。旧 IP 包需
重新导出后才会应用该编码约定。

## 配置保存与导入

「生成Verilog IP」与「导出demo_prj」对话框均提供「保存配置」「导入配置」。
IP 使用 `.ipcfg`，demo_prj 使用 `.prjcfg`，默认目录分别为
`IspFlow/export_config/ipcfg/` 与 `IspFlow/export_config/prjcfg/`（运行期自动创建）。
JSON 保存完整 IP 参数、Vivado 可执行路径、目标 PART/family，以及六项器件
过滤器和搜索词；导入时一并恢复。未知枚举和越界参数回退默认值，版本不符或
JSON 结构错误会明确提示。目标 Vivado/PART 在本机不存在时按现有回退或重选逻辑处理。

## 文件集（单节点 top/Component Name 为 `ISP_IP_<节点英文名>`）

节点的英文名由 `IspNodeType.englishName` 统一定义，并在选中节点后的右侧属性面板
显示「英文名」与完整「IP」名称。例如 `csc_yuv2hsl` 对应
`YUV_to_HSL`，`multi_band_eq` 对应 `MBC_EQ`。多节点流程中的同类重复实例追加
`_2`、`_3` 等后缀；根互连顶层仍按组名命名，但不打包为合并 IP。

| 文件 | 说明 |
|---|---|
| `ISP_IP_<节点英文名>_core.v` | 流水线核心：通用像素流 in→out，全程 ready 握手；节点参数烘焙 |
| `ISP_IP_<节点英文名>_top.v` | 顶层装配（`VIN_TYPE=none` 时透传核心端口） |
| `ISP_IP_<节点英文名>_axis.v` | Vivado AXI4-Stream 封装（tuser=sof / tlast=eol） |
| `ISP_IP_<节点英文名>_libero.v` | Libero 裸流封装（valid/ready 直通） |
| `tb_ISP_IP_<节点英文名>.v` | testbench：`$readmemh` 输入 + FNV-1a 对拍（EXACT）；激励参数烘焙 |
| `golden_in.hex` | 输入激励帧（尺寸/帧数/图案/种子由「仿真激励参数」对话框指定，默认 64×8×1 帧随机） |
| `golden_hash.txt` | 期望 FNV-1a（32 位，uint16 小端逐字节） |
| `package_ip.tcl` | Vivado IP 打包脚本（含参数组） |
| `README.md` | 接口时序 / 参数表 / 资源估算 / 导入说明 |

## 接口（像素流）

核心模块输入/输出均为通用像素流，通道打包 `{H,S,L}`（H 在最高位段，每
通道 `PIX_BITS` 位）：

- `in_valid`/`in_ready`：输入握手，`advance = in_valid & in_ready`；
- `in_sof`/`in_eol`：帧起始/帧结束（与 `in_data` 同拍有效）；
- `out_valid`/`out_ready`/`out_sof`/`out_eol`/`out_data`：输出同形；lut_fixed
  1 拍流水延迟，func_fixed 按段数/模式 LAT 拍流水（II=1，每时钟 1 像素）。

## 定点口径（multi_band_eq lut_fixed）

- 三张 ROM：H 偏移（16 位补码）、S/L 乘子 Q14（各 17 位），深度 `2^PIX_BITS`；
- 逐像素：H 钳上界 → 查 shift 表 → 色环回绕（单次条件加减，与 `% (MAXV+1)`
  逐位一致）→ S/L `(in*q+8192)>>14` 后钳位；
- 与 C 侧 `bb_clamp_q14` 逐位一致；ROM 表由 Dart 侧 `multiBandLuts` 烘焙。

## 定点口径（multi_band_eq func_fixed，无 ROM 表）

- **段运算单元**（`ISP_IP_<节点英文名>_band_par`/`_band_ser`）：每个取色器段实例化
  一个独立单元；**段参数（H 中心/Q/ΔH/S 增益/L 增益的定点常量）为运行期
  输入端口** `par_b{i}_hc/q/dh/s1/l1`（core/top/AXI/Libero 各层原样透出，
  可接 AXI-Lite 寄存器运行中动态调整，建议帧间隙修改；换算公式见 IP 包
  README「段参数端口」一节），ispflow 参数只烘焙进 tb 的段参数激励 reg
  初值——与 LUT 烘焙形态本质区别；单元内为高斯权重的全整数定点直算：
  角距条件回绕 → x=d·q/45
  （Q20）→ u=0.5x²·log2e（Q16）→ 2^(−u) 整数部移位 + [0,1) 五次多项式
  （Q16 系数 Horner，系数拟合脚本 `scratch/fit_exp2_neg_poly.dart`）→
  Q14 权重；乘法器由综合器推断 DSP（性能档）。
- **展开形态**：并联（parallel）时全部段单元在同一流水级并行展开，三项
  贡献（dh Q30 / s·l Q28）求和后钳位收尾，LAT=5 拍；串联（serial）时段
  单元按取色器段序流水线展开（每段一级，中间色相/S/L 累加器逐级传递），
  LAT=段数+4 拍；单段两种模式同构（无钳位捷径）。
- **无除法器**：h_q16 = (hv·360·2^16 + MAXV/2)/MAXV 用 Mersenne 折叠
  （MAXV=2^PIX_BITS−1，四次折叠 + 末位修正）精确替代；shift 的
  round(·/(360·2^30|2^16)) 用「先右移再 ×ceil(2^33/360) 倒数乘」精确替代
  （恒等式全量/密集验证见 `test/isp_group_ip_export_test.dart`）。
- 与 Dart 参考 `applyMultiBandEqFx` 逐位一致（iverilog EXACT 对拍），与
  FP64 口径偏差 ≤1 LSB；任意 `PIX_BITS`（8/10/12/14/16）恒走定点直算，
  无 LUT 模式的域失配问题。

## 一键仿真

激励参数不由生成器写死：点工具栏「一键仿真」会先弹出激励参数对话框
（`ip_stimulus_dialog.dart` → `ip_stimulus.dart` 的 `IpSimStimulus`，
确认按钮「开始仿真」，取消则不跑），会话缓存 `sessionIpSimStimulus`
按编组回填，应用后 tb/golden 一并重新生成：

- **帧宽 × 帧高 × 帧数**（默认 64×8×1；多帧连续喂入，逐帧 sof、逐行 eol）；
- **CLK 频率**（默认 25MHz，决定 tb 时钟周期为 40ns）；
- **帧间隔**（时钟周期数，默认 10 拍，0=帧间连续）：帧末像素接收后插入指定拍数
  的 in_valid 空闲（验证帧间间隔处理）；
- **激励图案**：随机（LCG）/ 水平渐变 / 垂直渐变 / 纯色 / 棋盘格 /
  24 位色彩激励（HSL/RGB/YUV × 高字节（H/R/Y）或高字节（L/B/V）两种
  字节序：产生彩色渐变，配合「仿真波形」Signal 右键菜单的色彩解码
  同空间同字节序即可在波形上直接看到色彩块）；
- **随机种子**：随机图案的 LCG 种子，同时派生 tb 侧握手压力的随机序列
  （仿真可复现）；
- **握手压力**：输入气泡率（in_valid 随机空闲拍概率）与输出背压率
  （out_ready 随机拉低概率），验证 ready 握手健壮性——不影响 golden
  数据口径（tb 驱动全部负沿切换、输出按传输拍 `out_valid & out_ready`
  监控计数，背压保持的输出不重计）。

```
iverilog -g2012 -o tb.vvp tb_ISP_IP_<节点英文名>.v ISP_IP_<节点英文名>_core.v ISP_IP_<节点英文名>_top.v
vvp tb.vvp      # 输出 PASS/FAIL（EXACT 逐位 FNV-1a 对拍），并转储 wave.vcd
```

testbench 内含 `$dumpfile/$dumpvars` 波形转储（`$test$plusargs("NOVCD")` 可关闭；
demo 工程经 `XSIM.SIMULATE.XSIM.MORE_OPTIONS = {-testplusarg NOVCD}` 传入，
避免为 flatten 后的布线后网表（数万网线）白写一份 VCD）；仿真结束后自动打开
ISP Studio 内嵌**「仿真波形」标签页**（Flutter 原生数字波形查看器：
解析 wave.vcd 后 CustomPaint 渲染，时钟/复位/IP I/O 信号默认展示，
拖动平移、滚轮缩放、单击光标、双击 Zoom Fit）。工具链随安装包内置
（`tools/iverilog/`，安装版开箱即用）。无 iverilog 时 UI 探测行提示
安装（导出功能不受影响）。

### Vivado 侧仿真模式（实测，xczu15eg 3 节点 demo）

| 模式 | 验证对象 | 实测 |
|---|---|---|
| Behavioral | RTL 源文件 | 约 15 s |
| Post-Synthesis Functional | 综合后网表 | 约 152 s，golden PASS |
| Post-Implementation Functional | 布线后网表 | 约 152 s，golden PASS |
| Post-Implementation Timing | 带 SDF 时序反标注 | **不可用**：XSim 内核加载这份约 1.5 万单元 / 158 DSP48E2 的时序网表后长时间无输出（实测 45 min+，4 GB 内存单核满载），GUI 的 Cancel 也不生效，只能结束 `xsimk.exe` |

排查见 `docs/decisions.md`「2026-11-11 布线后时序仿真」。功能与连接性验证用
Functional 三档，时序收敛看 `report_timing_summary`（本 demo WNS 约 +15 ns）。

## 电路图浏览

IP 标签页工具栏「电路图浏览」打开**「电路图」标签页**（`sch:` 前缀）。
模块框图已移除，页面直接显示单一 **RTL 顶层网表**：

- **RTL 网表**：**自研渲染**（不用 netlistsvg/ELK/SVG；进入页面即提取）。
  yosys **只做网表提取**，布局与绘制全部在应用内：

```
yosys -p "read_verilog <各 .v>; hierarchy -top <最外层封装>; proc; opt_clean; write_json net.json"
# JSON 由 Dart 侧 YosysNetlist.parse 解析 → 自研分层布局 → CustomPaint 绘制
```

  **不 flatten**：保留模块层级（顶层 = 端口 + 子模块实例，块左上「＋」可
  **原位展开**成容器——Vivado 风格：内部递归绘制子模块的块与走线（多层，
  深度 ≤3）、容器针脚＝实例针脚（边缘同排）并用连接短线接到子模块端口，
  `−` 收起；单击 `＋/−` 切换、双击块进入整页下钻（工具栏「回顶层」返回），
  容器内外同等交互（跨层悬停高亮与网名、点逻辑单元跳源码、可继续展开）），且真实信号名（`n1_hv17`/
  `n1_hsum`）不被 `$flatten\u_core.` 前缀污染。**端口按方向三分类**：
  输入＝五边形（尖端朝设计内）+ 符号内 `I`；输出＝五边形（尖端朝设计外）
  + `O`；**双向 inout＝六边形 + `IO`**（填充配色区分；双向端口与输出同列，
  双向引脚放块右缘且引脚名带 `IO ` 前缀），工具栏信息区给出
  `I n / O n / IO n` 计数。RTL 单元按类型使用**标准电路符号**（共享几何见
  `codegen/netlist_symbols.dart`，Canvas 与 SVG 不再各画一套）：AND/OR/XOR/
  XNOR/NOT 使用 ANSI/IEEE 异形门（含反相气泡），MUX 使用梯形且选择端 `S`
  在底边，DFF 带时钟三角与低有效气泡，ROM/RAM 使用存储器符号，算术/比较/
  移位使用 IEC 运算符框（`+`/`×`/`<`/`<<` 等）；子模块实例保留标准层级矩形。
  单元仍按类别配色（时序/存储/算术/比较/选择/逻辑/移位），上方为实例名、
  下方为类型名（`ADD`/`MUX`/`ADFF`/`ROM`），针脚名带位宽（`A[16:0]`）、
  针脚短线接实际符号轮廓、常量引脚标 `1'b0`/`8'h00`；**连线为直线预览且默认团拓扑**——同一根网的所有 pin 两两相连（工具栏「设置」里可切星形＝各 pin 到质心），直接连接 `pin.pos`，**不做正交布线**（布线器、多轮优化、镜像/行序/引脚重排、手工布线/学习规则均已移除）。每条直线按其实际承载比特决定线宽：暗色模式总线使用亮蓝色（#00BFFF）；浅色模式单信号线为深绿色（#14651A）、总线为深蓝色（#1F4E79）；单比特接入总线针脚的一位仍画单信号；同一组负载的完整总线拼接仍合并。**多驱动输入针脚按连续位域拆分**（如 `B[23:0]` 拆为 `B[23:16]`、`B[15:8]`、`B[7:0]`，高位段在上，各自有独立连接点；单驱动完整总线不拆，双向端口除外）。`edge → pos` 只作为灰色针脚自身短线绘制，彩色直线从外部节点 `pos` 起步，不画到元件框上的 `edge`。**统一使用 15px Grid**：符号边界及其连接点、元件 pin、端口符号与画布边距均落在 15px 整数倍坐标；针脚文字行、实例名与类型名标题带均为 30px，不得压成 15px 导致文字裁切；单输出组合符号用偶数格高度和对称针脚消除半格，MUX 用偶数格宽度保持底边选择端居中。**所有网名与位域标签默认一律隐藏**，只有鼠标**悬停/点选到的那根网**（或悬停单元的相连网）在线路高亮时才显示完整标签（含位域，如 `n1_res_l[7:0]`；命中测试按点到直线段的距离，容差随缩放补偿；点选用 `selectedNet`/`onNetSelected`），标签贴驱动端、底板为半透明圆角块，页内标签另用独立最顶层绘制层；导出 SVG 标全部网名（文档模式）。标签取覆盖当前比特集合最多的真实网段；yosys 生成名（标识符中间含 `$`）改用「驱动单元_端口」派生名如 `add836_Y`。层级压缩到
  6~14 列并对超长链做 BFS 分层，避免 1:N 长条。工具栏「布局布线设置」对话框内用单选切换团形/星形拓扑，并可勾选「镜像元件」「引脚交换」；「开始优化布局」重排列内行序并自动迭代至总直线长度不再下降（勾选引脚交换时兼换输入槽位），以总直线长度为目标，右上角浮层显示「布局优化中」、模块数、端点数、输入/输出/双向端口数与总直线长度；工具栏「走线密度热力图」按 24px 网格累计走线长度，以半透明蓝→青→绿→黄→红叠加并带右下角图例；「自动布线」按 15px 网格 A* 为每条网生成正交走线：单一 0.5dp、总线 3dp，引脚向外至少 1 Grid 才能折弯，同网合并为树并在 T/十字分支点画实心圆点（总线直径 8dp、单线 4dp），不同网同轴线不重叠（十字交叉允许），列间距按跨列网数自动加宽（每网一个 Grid、上限 8），再次点击恢复直线预览；「自动优化布线」按「交叉点最少 → 折弯点最少 → 总长最短」的字典序重跑不同布线/负载顺序，并允许在不改变列内上下顺序、同列仍留 5 Grid 的前提下上下移动元件后重新布线，输入/输出端口块及单个端口引脚也可上下移动以减少折弯（端口优先对齐到对端引脚 y 或所属网水平主线，不增加交叉），列内移动反复迭代至不再改善（元件相对原位置最多上下移动 ±10 Grid）；右上角「布线优化中/完成」浮层显示交叉点、折弯点与走线总长；优化过程逐轮回调重绘画布，并与布局优化浮层互斥（打开前先关闭布局窗），SnackBar 提示交叉/折弯/长度变化；自动布线只影响显示，自动优化布线可上下微调元件并保留在布局中。交互：悬停单元高亮其相连
  网络（其余调暗）、点实例下钻、点逻辑单元跳 IP 代码页并高亮其信号名；
  暗色配色下元件符号边框、pin 节点与针脚短线、pin/实例/模块文本和端口边框
  均为 `#FFFFFF` 纯白，且元件边框、pin 针脚短线和端口轮廓线宽均为
  **0.5dp**（Canvas 与 SVG 一致，普通连线与总线线宽不变）；实例框内左上角的
  ＋/− 按钮共用居中几何，常态边框与图标也为 `#FFFFFF`，悬停时变为亮黄并显示
  展开/收起提示。常量参数（如 `8'h00`/`8'hFF`）不是悬空输入；平时不绘制
  参数文本，鼠标悬停到对应 10×10 常量标记时才以 Tooltip 气泡显示；气泡固定为
  两行，第一行按 MSB→LSB 列出各段 pin 位域，第二行按相同顺序列出常量值
  （如 `[17:14] [13] [12:0]` 换行 `4'h0 | 1'b1 | 13'h0000`）；SVG 文档模式
  仍保留参数值及元件外侧布局，暗色模式同样显示为白色。
  导出 SVG 由同一布局模型直出（无 `<style>` 块），导出 PNG 复用 SVG
  栅格化。
  两个视图均支持**初始自适应**（首次显示自动缩放至全图居中可见）与工具栏
  **Zoom In/Out/Fit**（视口中心锚点缩放）。RTL 视图在编组内容或参数
  修改后于顶部显示琥珀色**过期提示条**（指纹比对：成员+参数+选项对象
  同一性），点提示条「重新生成」刷新；工具栏另含「重新生成」「导出SVG」
  「导出PNG」「查看网表」（只读网表文本，可切换模块、复制）与日志面板开关。
  顶层封装按厂商选择：Vivado 取 `*_axis`，Libero 取 `*_libero`，通用取
  `*_top`。工具链只需内置 `tools/yosys/`（安装版开箱即用；重建方式见
  `tools/README.md`）——`tools/netlistsvg/` 已删除（布局绘制全在应用内）；
  yosys 缺失时 RTL 视图提示安装（框图视图不受影响）。

## 导入说明

- **Vivado**：`vivado -mode batch -source package_ip.tcl` 打包 → `./ip_repo`；
  双击 IP 用 Customize IP 界面改 `PIX_BITS`/`MAX_WIDTH`。
- **Libero**：顶层为 valid/ready 裸流封装；参数在 SmartDesign generics 面板
  可见可改。
- **通用**：核心模块直接即顶层，可级联或接入自定义测试环境。
