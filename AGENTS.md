# AGENTS.md — DebugToolSet 项目指南

本文件面向 AI 编码助手，介绍本仓库的结构、构建方式与开发约定。阅读前无需任何背景知识。

## 项目概述

**DebugToolSet** 是一个面向嵌入式/硬件调试工程师的 **Windows 桌面端多功能调试工具集**，使用 **Flutter (Dart)** 开发。界面为暗色主题单窗口应用，左侧窄边栏切换 7 个功能模块：

| 序号 | 模块 | 目录 | 功能 |
|---|---|---|---|
| 0 | 示波器 | `lib/modules/oscilloscope/` | 高速多通道波形显示（4 模拟通道 + 32bit MSO 逻辑分析通道），支持 I2C/SPI/UART/CAN 等协议解码、总线搜索、寄存器/命令释义（挂载 `.Regfile` / `.UartProtocol`）、波形存取（`.waveform`） |
| 1 | 终端 | `lib/modules/terminal/` | 串口（`flutter_libserialport`）/网络终端，支持宏命令、ANSI 转义解析、回滚缓冲 |
| 2 | Hex 编辑器 | `lib/modules/hex_editor/` | 二进制文件查看/编辑、字节解析面板、Hex 计算器、多固件合并（`hex_merge_dialog`） |
| 3 | 文本对比 / 补丁 | `lib/modules/text_editor/` | 文本编辑、语法高亮、文件/文件夹 diff、补丁生成与套用 |
| 4 | 字库提取 | `lib/modules/font_extractor/` | 从 TTF/OTF 提取点阵字库（EBDT 解析、字符集管理、字形预览），导出 C 数组/bin |
| 5 | UI 设计器 | `lib/modules/ui_designer/` | 嵌入式 UI 拖拽设计器：控件箱 → 画布编辑 → 预览交互 → 导出 C99 代码（无动态分配、弱符号回调）。详见 `docs/UI_Designer.md` |
| 6 | ISP Studio | `lib/modules/isp_studio/` | 图像信号处理流水线节点图编辑器：节点画布 + 每节点代码页，支持 RAW 图像/视频源、ISP 算法核、仪器仪表（矢量示波器、音频分析等）、Worker 池并行计算、ffmpeg 视频导出 |

应用强制暗色主题（`lib/main.dart` 中 `themeMode: ThemeMode.dark`），默认窗口 1658×869。

## 技术栈与关键配置

- **语言/框架**：Dart `^3.12.2` + Flutter；目标平台为 **Windows 桌面**（`windows/` 为标准 runner；`web/` 目录存在但不是主要目标）。
- **关键配置文件**：
  - `pubspec.yaml` — 依赖与资源声明。主要依赖：`provider`（状态管理）、`window_manager`、`flutter_libserialport`、`file_selector`、`ffi`、`archive`、`image`、`flutter_svg`、`flutter_colorpicker`、`intl`。
  - `analysis_options.yaml` — 使用 `flutter_lints/flutter.yaml`；**`scratch/` 目录被排除在静态分析之外**。
  - `Windows_setup/DebugToolSet.iss` — Inno Setup 打包脚本（详见下文「打包部署」）。
- **GPU 着色器**：`shaders/yuv_planes.frag`（在 `pubspec.yaml` 的 `shaders:` 中声明，ISP Studio 视频预览用）。

## 构建与运行

```bash
flutter pub get                 # 安装依赖
flutter run -d windows          # 调试运行（等价于 TestRun.bat）
flutter run -d windows --release # Release 运行（等价于 ReleaseBulidRun.bat）
flutter build windows --release  # 产出 build/windows/x64/runner/Release/debug_tool_set.exe
flutter analyze                 # 静态分析
```

注意：应用以**工作目录（`Directory.current`）相对路径**访问多个数据目录（见下），因此必须从工程根目录启动；打包时这些目录须与 exe 同级放置。

## 代码组织

- `lib/main.dart` — 入口：`window_manager` 初始化 + `MultiProvider` 注册全部状态。
- `lib/layout/main_layout.dart` — 主框架：左侧栏（模块切换）+ 工作区 + 底部状态栏。
- `lib/providers/` — 每个模块对应一个 `ChangeNotifier` 状态类（`AppState`、`TerminalState`、`OscilloscopeState`、`MacroState`、`HexEditorState`、`TextEditorState`、`FontExtractorState`、`UiDesignerState`、`IspStudioState`）。**状态管理统一用 Provider**，`OscilloscopeState` 通过 `ChangeNotifierProxyProvider` 依赖 `TerminalState`。
- `lib/modules/<模块名>/` — 每个模块内含 `<模块名>_view.dart` 根视图，及 `models/`（纯数据/逻辑，尽量无 Flutter 依赖）、`widgets/`（UI 组件）等子目录；`ui_designer` 另有 `codegen/`（C 代码生成），`isp_studio` 另有 `pipeline/`（流水线执行、ISP 核、仪器、Worker）。
- `lib/utils/` — 跨模块工具（ANSI 解析、波形存储 `waveform_storage.dart` 等）。
- `lib/theme/app_theme.dart` — 暗色主题定义。

## 数据目录与文件格式（运行时依赖）

以下目录在代码中按**相对工作目录**访问，属于程序运行/打包的一部分：

- `DeviceProtocol/{I2C,SPI,Uart}/` — `.Regfile`（I2C/SPI 寄存器/命令定义）与 `.UartProtocol`（UART 帧格式定义）文件，均为 JSON 语法。格式规范见 `docs/Regfile_Format.md`、`docs/UartProtocol_Format.md`。
- `bussetup/` — `.bussetup` 总线配置（单行 JSON：引脚、缩放、解码器等）。
- `waveform/` — `.waveform` 波形存档：头部魔数 `WAVEFORM1.0` + JSON 元数据 + gzip 压缩的二进制采样数据。
- `IspFlow/` — `.ispflow` ISP 流程图文件（JSON 文本）。
- `UI_Project/` — `.uiproj` UI 设计器工程文件（JSON）；`UI_Project/exported_c/`、`gpu_effects_demo_c/` 为导出示例。
- `tools/ffmpeg/ffmpeg.exe` — ISP Studio 视频导出默认使用（节点属性 `ffmpegPath` 默认值 `tools/ffmpeg/ffmpeg.exe`）。
- `docs/Oscilloscope_Protocol.md` — 下位机（FPGA/MCU）二进制同步帧通信协议规范，修改示波器数据通路时应先阅读。

其余顶层目录多为**测试素材与参考资料**，不属于代码：`datasheet/`、`MSO8000/`、`SIGLENT/`（各厂编程手册 PDF）、`BayerRGGB/`（RAW 图测试数据）、`Font/`、`FontLib/`、`Memorydump/`、`binfile/`、`cfile/`、`vfile/` 等。

## 测试

- 测试位于 `test/`（约 58 个 `*_test.dart`），使用 `flutter_test`。
- 命名约定：`isp_*` 前缀对应 ISP Studio，`font_*` 对应字库提取，`ui_*` 对应 UI 设计器，`text_editor_*`/`folder_*` 对应文本对比模块。
- 运行：

```bash
flutter test                    # 全部测试
flutter test test/isp_kernels_test.dart   # 单个文件
```

- `scripts/` 与 `scratch/` 是一次性/辅助脚本目录（mock 数据生成、批量代码修改、性能基准等），**不参与静态分析**，不要当作正式代码维护；工程根目录的 `patch_*.py`、`fix_*.py`、`test_*.dart` 同样是临时脚本。
- 项目已有测试覆盖的习惯：修改某模块逻辑时，优先在 `test/` 下补充或更新对应前缀的测试。

## 代码风格约定

- 遵循 `flutter_lints` 默认规则（`analysis_options.yaml` 未自定义额外规则）。
- 注释与文档以**中文**为主（部分 UI 文案为英文），新代码沿用此习惯。
- 状态放 `providers/`，视图放 `modules/<m>/<m>_view.dart` 与 `widgets/`，纯逻辑/数据模型放 `models/` 并尽量保持无 Flutter 依赖（如 `isp_graph.dart` 标注「纯 Dart，无 Flutter 依赖」）。
- 修改尽量最小化，与目标文件现有风格保持一致；不要顺手重构无关代码。

## 打包部署

使用 Inno Setup，脚本为 `Windows_setup/DebugToolSet.iss`，向导步骤详见 `docs/Inno_Setup_Packaging_Guide.md`。要点：

1. 先 `flutter build windows --release`。
2. `.iss` 将整个 `build/windows/x64/runner/Release/` 拷入 `{app}`，并额外打包 `bussetup/`、`DeviceProtocol/`、`docs/`、`waveform/`、`tools/ffmpeg/` 到同名子目录（这些目录必须随安装包分发，原因见「数据目录」一节）。
3. 安装包输出到 `Windows_setup/Output/`。
4. 若新增了运行时依赖目录，需同步更新 `.iss` 与该指南文档。

### Linux（.deb）

实验性 Linux 桌面版的打包脚本在 `Linux_setup/`（在 Ubuntu/WSL 中运行）：

1. 先 `flutter build linux --release`。
2. `bash Linux_setup/build_deb.sh` 产出 `Linux_setup/Output/debug-tool-set_<版本>_amd64.deb`。
3. 布局：程序装 `/opt/debug_tool_set/`，启动器 `/usr/bin/debug-tool-set`（首次启动把数据目录复制到 `~/.local/share/debug_tool_set/` 再启动，解决 `/opt` 不可写问题）；`Depends` 由 `ldd`+`dpkg -S` 自动推导，另加 `ffmpeg`、`fonts-noto-cjk`。
4. 若新增运行时依赖目录，需同步更新 `build_deb.sh` 与启动器 `debug-tool-set` 中的目录列表。

## 安全与其他注意事项

- 工程根目录的 `kimi_proxy.py` 与 `requirements.txt`（fastapi/uvicorn/httpx/pydantic）是一个与主程序无关的 Kimi↔OpenAI API 代理脚本，内含 API key 环境变量占位；**不要**将其 key 提交真实值，也不要把它当作应用的一部分。
- 应用可访问串口与网络（LXI 连接），测试硬件交互代码时注意副作用。
- 仓库中有大量大二进制素材（PDF、RAW、波形、固件），勿随意重编码或移动，`isp_*` 等测试可能按固定路径引用它们。
- 开发环境为 Windows + Git Bash；脚本一律使用 Unix 语法。
