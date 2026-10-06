# tools/ 随包分发的第三方组件

本目录下的组件会经 `Windows_setup/DebugToolSet.iss` 递归打包进安装包
（`tools\*` → `{app}\tools`），运行时按工作目录相对路径访问。

| 目录 | 组件 | 用途 | 许可证 | 获取方式 |
|---|---|---|---|---|
| `ffmpeg/` | FFmpeg 9.0.2 full_build-shared（gyan.dev） | ISP Studio 视频解码/导出、编组验证程序内嵌解码器 | GPL v3 | https://www.gyan.dev/ffmpeg/builds/ |
| `iverilog/` | Icarus Verilog v14（bleyer.org Windows 构建的 bin 两件套 + lib/ivl） | IP Generator 一键仿真（iverilog -g2012 + vvp） | GPL v2 | https://bleyer.org/icarus/ （源码：https://github.com/steveicarus/iverilog） |
| `surfer/` | Surfer v0.7.0 Windows 版（surfer.exe） | 一键仿真波形查看（优先于 GTKWave） | EUPL-1.2 | https://gitlab.com/surfer-project/surfer/-/releases |
| `iqa/` | 深度评价桥接脚本与权重 | LPIPS/DISTS/FID/KID/MUSIQ/CLIPIQA 节点 | 见各模型许可 | 权重由 `tools/iqa/export_weights.py` 生成 |

## 说明

- `iverilog/` 只保留了仿真必需的子集：`bin/iverilog.exe`、`bin/vvp.exe` +
  MinGW 运行库 DLL，`lib/ivl/` 完整目录（iverilog 驱动按自身位置相对发现
  `../lib/ivl`，目录层级不可改动）。GTKWave/Tcl/Tk 等未纳入（波形查看由
  Surfer 承担）。如需重建：安装 bleyer.org 的 iverilog 后按上述结构拷贝。
- `surfer/` 只需单个 `surfer.exe`（从 release zip 解压）。
- 这些二进制不入 git 库（见 `.gitignore`），重新部署开发机时按上表重新放入。
