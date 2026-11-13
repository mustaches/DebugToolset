# Vivado 中文注释与生成文件编码问题记录

## 问题描述

ISP Studio 生成的 `tb_demo.v`、其他 Verilog 文件在 Vivado 文本编辑器中打开时，中文注释出现乱码；英文、数字和 Verilog 语法本身正常。生成 XPR 时，Vivado 输出到 ISP Studio 信息窗口的中文也出现过乱码。

典型现象是 UTF-8 中文被按 Windows 本地代码页解释，例如“一次性仿真”等注释变成无意义汉字或问号。问题只影响文本显示，不代表 Verilog 逻辑损坏。

## 排查过程

### 1. 不是中文输入或字体本身不可用

用户直接在 Vivado 的 Verilog 编辑窗口输入中文可以正常显示。这说明 Vivado 并非不能显示中文，关键在**已有文件的写盘编码与 Vivado 读取编码不一致**。

在中文 Windows 上，Vivado 编辑器直接输入并保存中文时通常使用系统代码页；本机对应 GBK。ISP Studio 原先使用 Dart `writeAsString` 的默认 UTF-8 编码写文件，因此产生乱码。

AMD 用户支持讨论中也有相同现象：Windows Vivado 编辑器中的中文注释需要 GBK，Linux 环境则通常使用 UTF-8：

- [Vivado 总会显示中文注释乱码，怎么处理（AMD Adaptive Support）](https://adaptivesupport.amd.com/s/question/0D54U00008zBCDmSAO/vivado%E6%80%BB%E4%BC%9A%E6%98%BE%E7%A4%BA%E4%B8%AD%E6%96%87%E6%B3%A8%E9%87%8A%E4%B9%B1%E7%A0%81%E6%80%8E%E4%B9%88%E5%A4%84%E7%90%86?language=en_US)
- [Does Vivado Text Editor support different encodings such as UTF-8, GBK?](https://adaptivesupport.amd.com/s/question/0D54U00008s1xOySAI/does-vivado-text-editor-support-different-encodings-such-as-utf8-gbki-have-a-gbk-encoding-source-file-with-chinese-comments-and-it-shows-garbled-text-for-all-the-chinese-comments-anyway-to-display-the-chinese-commentsthanks?language=en_US)

### 2. 统一改成英文不是根治

曾将生成的 Verilog/Tcl 注释全部改为 ASCII 英文。这样确实消除了乱码，但丢失了中文注释的可读性，只是绕开编码问题，不符合保留中文的需求，因此该方案已撤回。

### 3. 单纯切换进程日志解码也不可靠

生成 XPR 时，曾尝试在 UTF-8 与 Windows 系统编码之间切换 Vivado 子进程日志解码。实测不同脚本内容经过 Vivado Tcl 解析后，输出编码会发生变化，不能只靠更换解码器稳定修复。

最终，生成脚本的状态提示使用 ASCII 英文，ISP Studio 自身的中文提示保持正常；这与 Verilog 编辑器中的中文注释是两个独立问题。

### 4. UTF-8 BOM 不作为通用方案

Vivado Tcl 可能把 UTF-8 BOM 当作脚本开头的普通字符，导致 `invalid command name` 等错误。因此没有通过给所有生成文件统一添加 BOM 来掩盖问题。

## 编码方案演进与最终决定

### 最终决定：生成代码全部英文

曾恢复 `group_ip_export.dart` 与 `node_v_stream.dart` 中的中文注释并按版本编码，虽然 Verilog 编辑器显示问题得到解决，但不同 Vivado 版本和 XGUI 控件的兼容差异仍然复杂。最终按产品决策，所有生成的 Verilog/Tcl 注释统一为英文 ASCII，XGUI 页签、参数、下拉和说明也使用纯英文，从生成源头消除跨版本乱码。仿真激励图案使用枚举 `name`，CLK 注释使用 `CLK frequency`，README 仍保留中文。

这些修改只涉及注释和文件编码，不改变可综合逻辑、参数、golden 哈希或仿真语义。版本编码写盘逻辑保留用于其他文本及历史兼容场景。

### 按平台选择写盘编码

新增 `lib/modules/isp_studio/codegen/generated_text_io.dart`：

- Windows + Vivado 2020.2 及旧版：使用 `systemEncoding`，本机即 GBK；
- Windows + Vivado 2024.2 及新版（含 2026.1）：使用 UTF-8；
- Linux 等其他平台：使用 UTF-8。

2020.2 与 2024.2 的编辑器实测行为不同，不能只按操作系统统一决定编码。
导出时将所选 `vivadoExecutable` 传入写盘函数，由版本选择正确编码。

`exportGroupIpPackage` 与 `runIpSimulation` 均通过该入口写文本文件，保证：

- 用户导出的 Verilog 在 Windows Vivado 编辑器中按相同代码页读取；
- 一键仿真临时写盘也遵循同一编码；
- golden、地址、参数和 ASCII 内容不受影响。

核心原则是：**生成器内存中仍使用 Unicode 字符串，只在写盘时转换为目标编码。**

### XGUI 控件统一显式解码

曾尝试 Tcl `\uXXXX` 转义以及原生 GBK/UTF-8 文本，但不同 Vivado 版本和控件的表现不一致：页签、下拉标签、参数 `display_name` 与 `add_static_text` 并不总按同一方式解码。

曾尝试 Tcl `\uXXXX`、原生中文、UTF-8 十六进制和 `format %c` Unicode 码点方案，但 2020.2、2024.2、2026.1 的 XGUI 控件仍无法稳定显示中文，而且 Customize IP 安全解释器会禁用 `encoding` 命令。最终按产品决策，**XGUI 页签、参数名、下拉选项和说明文本统一使用纯英文 ASCII**，彻底避开这些兼容性问题。Verilog 中文注释不受影响，仍按 Vivado 版本选择正确编码。

不支持的 `ipgui::add_param -tooltip` 已改为兼容的 `ipgui::add_static_text`；`-text_icon` 也已移除，因为 Vivado 2020.2 不支持该参数。

## 验证方法

### 自动化编码回归

`test/isp_group_ip_export_test.dart` 包含“中文生成文件按平台编码写盘并可无损读回”用例：

1. 覆盖 Vivado + lut_fixed、generic + func_fixed 并联、Libero + func_fixed 串联；
2. 覆盖 demo testbench、非默认 CLK 和中文激励图案；
3. 将文件实际写入临时目录；
4. 读取原始字节，用 `generatedTextEncoding` 解码；
5. 要求解码结果与生成器内存中的文本逐字一致。

同时保留 iverilog 实仿，验证中文注释不会影响编译和 golden 逐位对拍。

### Vivado 实际流程

重新导出 IP 包后，使用 Vivado 2024.2 执行打包和 demo_prj 创建，检查：

- `tb_demo.v` 保留中文注释；
- Windows 下原始字节按 GBK 可无损解码；
- XGUI 正常加载；
- IP 实例和 `demo_prj.xpr` 成功生成。

## 使用注意事项

- 已导出的旧 IP 包不会自动改变编码，必须重新导出。
- 如果在 VS Code 等其他编辑器中打开 Windows 生成的文件，需要将编辑器编码设为 GBK/GB2312；不能把不同编辑器的默认编码混为一谈。
- 不建议用 UTF-8 重新保存这些文件后在 Windows Vivado 中继续使用，除非已确认对应 Vivado 版本能正确识别该编码。
- 修改注释和编码不需要重新计算 golden；如果仿真结果变化，应按独立逻辑问题排查。
