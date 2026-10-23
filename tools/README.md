# tools/ 随包分发的第三方组件

本目录下的组件会经 `Windows_setup/DebugToolSet.iss` 递归打包进安装包
（`tools\*` → `{app}\tools`），运行时按工作目录相对路径访问。

| 目录 | 组件 | 用途 | 许可证 | 获取方式 |
|---|---|---|---|---|
| `ffmpeg/` | FFmpeg 9.0.2 full_build-shared（gyan.dev） | ISP Studio 视频解码/导出、编组验证程序内嵌解码器 | GPL v3 | https://www.gyan.dev/ffmpeg/builds/ |
| `iverilog/` | Icarus Verilog v14（bleyer.org Windows 构建的 bin 两件套 + lib/ivl） | IP Generator 一键仿真（iverilog -g2012 + vvp） | GPL v2 | https://bleyer.org/icarus/ （源码：https://github.com/steveicarus/iverilog） |
| `yosys/` | Yosys（oss-cad-suite Windows 构建的子集：bin/yosys.exe + 依赖 DLL + share/yosys） | IP Generator 电路图浏览（**只出网表 JSON**：read_verilog → hierarchy -top → proc → opt_clean → write_json；布局与绘制由应用自研完成） | ISC | https://github.com/YosysHQ/oss-cad-suite-build/releases |
| `iqa/` | 深度评价桥接脚本与权重 | LPIPS/DISTS/FID/KID/MUSIQ/CLIPIQA 节点 | 见各模型许可 | 权重由 `tools/iqa/export_weights.py` 生成 |

## 说明

- `iverilog/` 只保留了仿真必需的子集：`bin/iverilog.exe`、`bin/vvp.exe` +
  MinGW 运行库 DLL，`lib/ivl/` 完整目录（iverilog 驱动按自身位置相对发现
  `../lib/ivl`，目录层级不可改动）。GTKWave/Tcl/Tk 等未纳入（波形查看由
  内嵌「仿真波形」标签页承担）。如需重建：安装 bleyer.org 的 iverilog
  后按上述结构拷贝。
- `yosys/` 为 oss-cad-suite 的子集：解压 release tgz 后拷入 `bin/yosys.exe`
  与 `bin/` 下其依赖的 DLL（`ldd bin/yosys.exe` 核查，逐缺逐补；不需要
  yosys-abc）及 `share/yosys/` 目录。
- `netlistsvg/` **已移除**：电路图改为应用自研布局与绘制（Dart 侧解析
  网表 JSON），不再需要 Node.js/netlistsvg。
- 这些二进制不入 git 库（见 `.gitignore`），重新部署开发机时按上表重新放入。
