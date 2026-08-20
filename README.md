# DebugToolSet

面向嵌入式/硬件调试工程师的桌面端多功能调试工具集，基于 Flutter 开发，支持 **Windows** 与 **Ubuntu**（实验性）。集成嵌入式开发常用工具，甚至包含面向 FPGA 的 ISP 实现代码生成器。

## 功能模块

| 模块 | 功能 |
|---|---|
| 示波器 | 高速多通道波形显示（4 模拟通道 + 32bit MSO 逻辑分析通道），支持 I2C/SPI/UART/CAN 等协议解码、总线搜索、寄存器/命令释义（挂载 `.Regfile` / `.UartProtocol`）、波形存取（`.waveform`） |
| 终端 | 串口 / 网络终端，支持宏命令、ANSI 转义解析、回滚缓冲 |
| Hex 编辑器 | 二进制文件查看/编辑、字节解析面板、Hex 计算器、多固件合并 |
| 文本对比 / 补丁 | 文本编辑、语法高亮、文件/文件夹 diff、补丁生成与套用 |
| 字库提取 | 从 TTF/OTF 提取点阵字库（EBDT 解析、字符集管理、字形预览），导出 C 数组 / bin |
| UI 设计器 | 嵌入式 UI 拖拽设计器：控件箱 → 画布编辑 → 预览交互 → 导出 C99 代码（无动态分配、弱符号回调） |
| ISP Studio | 图像信号处理流水线节点图编辑器：节点画布 + 每节点代码页，支持 RAW 图像/视频源、ISP 算法核、仪器仪表（矢量示波器、音频分析等）、Worker 池并行计算、ffmpeg 视频导出 |

## 下载安装

预编译安装包见 [Releases](https://github.com/mustaches/DebugToolset/releases)：

- **Windows**：`DebugToolset_setup.exe`（Windows 10/11 64 位，Inno Setup 安装包）
- **Ubuntu**：`debug-tool-set_*_amd64.deb`（Ubuntu 22.04/24.04，`sudo apt install ./debug-tool-set_*_amd64.deb`，自动安装 ffmpeg、中文字体等全部依赖）

详细安装与卸载说明：[docs/Installation_Guide.md](docs/Installation_Guide.md)

## 从源码构建

```bash
git clone https://github.com/mustaches/DebugToolset.git
cd DebugToolset
flutter pub get

flutter run -d windows            # Windows（或 flutter build windows --release）
flutter run -d linux              # Linux（需先安装 clang/cmake/ninja/libgtk-3-dev 等）
```

要求 Flutter stable（Dart `^3.12.2`）。**必须从工程根目录启动**，程序按工作目录相对路径访问 `DeviceProtocol/`、`bussetup/` 等数据目录。Linux 依赖安装与 `.deb` 打包见 [docs/Installation_Guide.md](docs/Installation_Guide.md)。

## 文档

- [安装说明（Windows/Ubuntu）](docs/Installation_Guide.md)
- [Inno Setup 打包指南](docs/Inno_Setup_Packaging_Guide.md)
- [示波器下位机通信协议](docs/Oscilloscope_Protocol.md)
- [Regfile 寄存器文件格式](docs/Regfile_Format.md) / [UartProtocol 帧格式](docs/UartProtocol_Format.md)
- [UI 设计器](docs/UI_Designer.md) / [ISP 处理节点](docs/ISP_Process_Nodes.md)
- [AGENTS.md](AGENTS.md)：仓库结构、构建方式与开发约定（面向 AI 编码助手，也适合人类开发者参考）

## 技术栈

- Flutter / Dart，状态管理 Provider，暗色主题单窗口应用
- 串口：`flutter_libserialport`；窗口管理：`window_manager`；GPU 着色器（ISP 视频预览）
- 打包：Windows 用 Inno Setup，Ubuntu 用 `.deb`（`Linux_setup/build_deb.sh`，依赖自动推导）

## 许可

本项目基于 [GPL-3.0](LICENSE) 开源。
