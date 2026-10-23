# isp_ip_multi_band_eq（FPGA Verilog IP，ISP Studio 自动生成）

## 接口（像素流）

核心模块 `isp_ip_multi_band_eq_core` 输入/输出均为通用像素流，通道打包 `{H,S,L}`
（H 在最高位段，每通道 `PIX_BITS` 位），全程带 ready 握手：

- `in_valid`/`in_ready`：输入握手，`advance = in_valid & in_ready`；
- `in_sof`/`in_eol`：帧起始/帧结束（与 `in_data` 同拍有效）；
- `out_valid`/`out_ready`/`out_sof`/`out_eol`/`out_data`：输出同形，1 拍流水
  延迟（II=1，每时钟 1 像素）。

## 参数（顶层 parameter，Customize IP / generics 面板可改）

| 参数 | 默认 | 说明 |
|---|---|---|
| `PIX_BITS` | 8 | 像素位宽；决定数据通路宽度与 LUT ROM 深度（MAXV = 2^PIX_BITS-1） |
| `MAX_WIDTH` | 4096 | 行缓冲最大行宽（本节点无窗口算子，参数保留） |
| `GSTRATEGY` | 1（平衡） | 窗口算子实现分档：0 面积 / 1 平衡 / 2 性能（当前白名单为点操作，预留） |
| `FOLD` | 1 | 窗口算子折叠因子（仅面积档生效，预留） |

Vivado 定制界面（双击 IP → Customize IP）为分页 + 控件化界面（基本配置 /
优化策略两页，`xgui/isp_ip_multi_band_eq_v1_0.tcl`），`FOLD` 仅面积档可编辑。

## 支持节点与定点口径

- `multi_band_eq`（codegenMode=lut_fixed）：H 偏移 16 位补码 ROM + S/L 乘子
  Q14 定点 ROM，逐像素 3 查表 + 色环回绕（单次条件加减）+ 2 次整数乘加
  `(in*q+8192)>>14` 后钳位；与 C 侧 `bb_clamp_q14` 逐位一致。

## 资源估算（粗估，随节点类型逐步细化）

| 项 | 估算 | 说明 |
|---|---|---|
| LUT ROM | 12800 bit（≈1 块 36K BRAM） | 3 张烘焙表（shift 16bit + S/L Q14 各 17bit）× 深度 2^PIX_BITS |
| DSP | ≈0 | S/L 两个 Q14 定点乘法器；性能档推断 DSP48，平衡/面积档绑 LUT |
| 逻辑 LUT | ≈1300 | 数据通路 + 握手 + 表取数（乘法器绑 LUT 时含其估算） |
| 延迟 | 1 拍 | 点操作编组：1 拍流水（无行缓冲） |
| 吞吐 | 1.0 px/clk | II=1 |

## 一键仿真

```
iverilog -g2012 -o tb.vvp tb_isp_ip_multi_band_eq.v isp_ip_multi_band_eq_core.v isp_ip_multi_band_eq_top.v
vvp tb.vvp
# 输出 PASS/FAIL（EXACT 逐位 FNV-1a 对拍）
```

## 导入说明（AMD/Xilinx Vivado）

用 package_ip.tcl 在 Vivado 打包导入；双击 IP 可用 Customize IP 界面改参数。

## 节点参数已烘焙进生成代码（与 C 导出同口径）；运行时寄存器/AXI-Lite 留 v2。
