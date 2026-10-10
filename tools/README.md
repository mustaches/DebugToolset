# tools/ 随包分发的第三方组件

本目录下的组件会经 `Windows_setup/DebugToolSet.iss` 递归打包进安装包
（`tools\*` → `{app}\tools`），运行时按工作目录相对路径访问。

| 目录 | 组件 | 用途 | 许可证 | 获取方式 |
|---|---|---|---|---|
| `ffmpeg/` | FFmpeg 9.0.2 full_build-shared（gyan.dev） | ISP Studio 视频解码/导出、编组验证程序内嵌解码器 | GPL v3 | https://www.gyan.dev/ffmpeg/builds/ |
| `iverilog/` | Icarus Verilog v14（bleyer.org Windows 构建的 bin 两件套 + lib/ivl） | IP Generator 一键仿真（iverilog -g2012 + vvp） | GPL v2 | https://bleyer.org/icarus/ （源码：https://github.com/steveicarus/iverilog） |
| `surfer/` | Surfer v0.7.0 Windows 版（surfer.exe） | 一键仿真波形查看（外部窗口，优先于 GTKWave） | EUPL-1.2 | https://gitlab.com/surfer-project/surfer/-/releases |
| `yosys/` | Yosys（oss-cad-suite Windows 构建的子集：bin/yosys.exe + 依赖 DLL + share/yosys） | IP Generator 电路图浏览（read_verilog → proc → write_json 出 RTL 网表） | ISC | https://github.com/YosysHQ/oss-cad-suite-build/releases |
| `netlistsvg/` | netlistsvg npm 包 + 独立 node.exe | 电路图布局渲染（网表 JSON → SVG） | netlistsvg MIT / Node.js MIT | https://github.com/nturley/netlistsvg ，node.exe 取自 Node.js 安装目录 |
| `iqa/` | 深度评价桥接脚本与权重 | LPIPS/DISTS/FID/KID/MUSIQ/CLIPIQA 节点 | 见各模型许可 | 权重由 `tools/iqa/export_weights.py` 生成 |

## 说明

- `iverilog/` 只保留了仿真必需的子集：`bin/iverilog.exe`、`bin/vvp.exe` +
  MinGW 运行库 DLL，`lib/ivl/` 完整目录（iverilog 驱动按自身位置相对发现
  `../lib/ivl`，目录层级不可改动）。GTKWave/Tcl/Tk 等未纳入（波形查看由
  Surfer 承担）。如需重建：安装 bleyer.org 的 iverilog 后按上述结构拷贝。
- `surfer/` 只需单个 `surfer.exe`（从 release zip 解压）。
- `yosys/` 为 oss-cad-suite 的子集：解压 release tgz 后拷入 `bin/yosys.exe`
  与 `bin/` 下其依赖的 DLL（`ldd bin/yosys.exe` 核查，逐缺逐补；不需要
  yosys-abc）及 `share/yosys/` 目录。
- `netlistsvg/` 重建：`cd tools/netlistsvg && npm init -y && npm install
  netlistsvg`，再拷入 Node.js 安装目录的 `node.exe`（单文件即可运行纯
  JS 包；版本建议 v20+）。
- 这些二进制不入 git 库（见 `.gitignore`），重新部署开发机时按上表重新放入。
