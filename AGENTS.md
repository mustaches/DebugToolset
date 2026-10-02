# AGENTS.md — DebugToolSet 项目指南

本文件面向 AI 编码助手，介绍本仓库的结构、构建方式与开发约定。阅读前无需任何背景知识。

## 项目概述

**DebugToolSet** 是一个面向嵌入式/硬件调试工程师的 **Windows 桌面端多功能调试工具集**，使用 **Flutter (Dart)** 开发。界面为暗色主题单窗口应用，左侧窄边栏切换 8 个功能模块：

| 序号 | 模块 | 目录 | 功能 |
|---|---|---|---|
| 0 | 串口终端 | `lib/modules/terminal/` | 串口终端（`flutter_libserialport`），支持宏命令、ANSI 转义解析、回滚缓冲；打开失败时经 `lib/utils/serial_port_primer.dart` 预置波特率修复 CP2105 Standard 口等驱动兼容问题 |
| 1 | 网络终端 | `lib/modules/network_terminal/` | TCP Socket / SSH（`dartssh2`，用户名+密码认证的 shell 会话）终端，与串口终端共享宏命令（`MacroState`、`sequence/`）、输出区/输入框组件（经 `TerminalSession` 接口复用） |
| 2 | 示波器 | `lib/modules/oscilloscope/` | 高速多通道波形显示（4 模拟通道 + 32bit MSO 逻辑分析通道），支持 I2C/SPI/UART/CAN 等协议解码、总线搜索、寄存器/命令释义（挂载 `.Regfile` / `.UartProtocol`）、波形存取（`.waveform`） |
| 3 | Hex 编辑器 | `lib/modules/hex_editor/` | 二进制文件查看/编辑、字节解析面板、Hex 计算器、多固件合并（`hex_merge_dialog`） |
| 4 | 文本对比 / 补丁 | `lib/modules/text_editor/` | 文本编辑、语法高亮、文件/文件夹 diff、补丁生成与套用 |
| 5 | 字库提取 | `lib/modules/font_extractor/` | 从 TTF/OTF 提取点阵字库（EBDT 解析、字符集管理、字形预览），导出 C 数组/bin |
| 6 | UI 设计器 | `lib/modules/ui_designer/` | 嵌入式 UI 拖拽设计器：控件箱 → 画布编辑 → 预览交互 → 导出 C99 代码（无动态分配、弱符号回调）。详见 `docs/UI_Designer.md` |
| 7 | ISP Studio | `lib/modules/isp_studio/` | 图像信号处理流水线节点图编辑器：节点画布 + 每节点代码页（嵌入式相关节点展示 `lib/modules/isp_studio/c_ref/` 下的 ANSI C99 参考实现，.h/.c 文件树，与 Dart 实现数值语义对应；PC 侧节点仍展示 Dart 源码），支持 RAW 图像/视频源、ISP 算法核、仪器仪表（矢量示波器、音频分析等）、Worker 池并行计算、ffmpeg 视频导出（GPU 链导出走**分段并行**：源先经 `-c copy -f segment` 按包拆为关键帧对齐分段（不解码，对 VFR/时间戳异常片源也精确），各段独立 `VideoFrameStream` 解码流（`-fps_mode passthrough` 每包一帧 + `maxFrames` 确切收尾；段 s>0 输入为 parts[0..s] 的 concat 列表 + `skipFrames` 跳过重叠区，解决 open-GOP 切割点引导帧引用缺失）+ 各自 NVENC 编码进程，渲染经异步锁串行，完成后 `ffmpeg -f concat -c copy` 无损拼接并校验帧数/时长，失败回退单段；分段逻辑在 `pipeline/export_segments.dart`）；单帧预览可走 GPU 快路径（`pipeline/gpu/`：16 位打包纹理 + FragmentShader，仅 UI isolate，失败自动回退 CPU isolate 路径；源纹理跨 run 缓存支持增量重跑）；视频播放时若全部预览链都有 GPU shader 实现（`GpuPipeline.isSupportedChain`）则走 **GPU 链播放**（流帧 RGBA 直传 + `isp_rgba8_to_rgb16.frag` 重排 + 全 pass 驻留 + 免回读上屏，平面直出/直连形态优先，不支持回退 CPU worker 池）；YUV 端口链与 **RGB 视频直连**（源→预览汇点）均优先走 **yuv420p 平面直出**（ffmpeg 直出解码器原生格式 + 打包纹理 + `yuv_planes.frag` GPU 上色——管道/上传流量为 RGBA 直连的 37%，上色矩阵随片源元数据 601/709/2020 可选（`VideoInfo.colorMatrix`，与 ffmpeg rgba 转换尊重帧元数据同口径；仪器馈源 `yuv420p8ToRgbaStep` 同参数）；HDR（BT.2020 PQ/HLG，按 `VideoInfo.colorTransfer` 判定：smpte2084→PQ、arib-std-b67→HLG）片源在解码侧统一经 zscale+tonemap(hable) 滤镜链映射为 BT.709 SDR 8bit 交付（`kHdrTonemapFilter`/`buildDecodeVf`；tonemap 时 colorMatrix 按交付帧口径恒报 709、fullRange 恒 false），播放（平面直出/RGB 直连/worker 池）与导出（分段/单段）全路径统一，SDR 片源滤镜链零改动；预览节点与多段色彩均衡器的播放控制条均带 HDR/SDR 切换（同一构建器 `_buildHdrToneMapToggle`；SDR 片源仅静态标识；HDR 片源可切 SDR 直解对比/HDR tonemap 显示，默认 HDR；`IspStudioState.hdrToneMapEnabled`，切换经链参数 `_toneMapHdr` 与 VideoFrameStream config 贯通，导出路径恒映射不受开关影响），奇数尺寸/帧字节超 2^24/shader 不可用时回退 RGBA 直连或 CPU worker 池）；播放上屏为**按需出帧**（秒表粗等到截止前 ~6ms 再 `scheduleFrame` 对齐 vsync，不强制满速帧泵——4K/75Hz 下强制满速出帧的呈现开销会耗尽栅格线程；无绑定环境/无刷新率/首个 vsync 等待超时自动回退原秒表节拍）；视频播放起步有**预读闸**（`togglePlayback` 起流后先等缓冲攒够 min(8, 剩余帧数) 帧、上限 ~1.5s 再开始走帧——解码器管线填充期（帧线程延迟 + B 帧重排）交付是"先干后涌"，不等够帧起步会把填充等待暴露成开播后一串停滞；实测 4K HEVC Rext 4:2:2 手术录像起步停滞 6 次→0，H.264 无 B 帧源本就为 0）；**一切顺序解码路径必须 `-fps_mode passthrough`**（播放两处 `VideoFrameStream.start`、CPU 池范围任务 `pipeline_worker.dart`、GPU 链导出 `decodeVideoStreamRgba`——rawvideo 管道 muxer 的默认 CFR 帧同步会按流内 VUI 标称帧率补/丢帧：VUI 标 60fps 的 30fps 片源（手术录像 HEVC Rext）被逐帧复制成 60fps 交付，播放时每画面停 66ms 呈 15fps 全程卡顿观感、导出帧数翻倍，而 FPS/停滞指标全部正常——排查教训：指标正常不代表上屏内容正确，需对比交付帧数与包数）；**画布与预览附加区必须保持 RepaintBoundary 隔离**（`node_canvas.dart` 的画布 Stack 与 `node_widget.dart` 的预览附加区——否则 4K 下画布与逐帧更新（状态栏文本/预览换帧）同处根图层，每次发布都让整个场景显示列表重录（实测栅格 18-21ms/帧、75Hz 屏帧泵被拖到 ~48Hz），这是 4K 播放"丢帧"观感的教训，排查历经解码/管道/纹理/节拍全部排除后定位）；打包纹理双缓冲延迟一帧释放；ffmpeg 解码/滤镜线程封顶 `-threads 8 -filter_threads 8`（112 核机默认 auto 百线程爆发式占满全核会饿死栅格线程/DWM，吞吐仍数倍于实时）；自动播放诊断：环境变量 `ISP_AUTOPLAY=<视频>` / `ISP_AUTOMOD=<模块号>` / `ISP_AUTOLOG=<日志>`（`main.dart` 的 `_installAutoplayDiag`——启动 3s 后自动建 视频源→预览 流程播放，状态栏指标每秒采样写文件，供无交互采集真机播放诊断）；色彩控制器（`color_controller`，高斯色相带选择调参）CPU 侧经 `hsl_band_pool.dart` 常驻条带池（核数-2 worker，每 isolate 单例）并行；多段色彩均衡器的 LUT 查表并行复用同池（LUT 模式消息——播放路径每帧 Isolate.run 扇出的 spawn 开销 ~300ms 级不可承受）；多段色彩均衡器（`multi_band_eq`，色彩控制器增强版：1~24 段取色器工具栏（增删段/前后双联预览取色——取色模式下悬停实时计算光标像素 HSL，H 与自动评估 Q（`estimateBandQ`：8 方向色相平滑段长度评估，相邻环差 >15° 或低饱和视为相位突变，Q=该方向图像长度/段长）实时叠加到调整前示波器色相线/Q 带，光标旁气泡实时显示 HSL（与矢量示波器悬停气泡同风格），右预览区同时切换为左区放大视图（倍率经工具栏 X2/X4/X6/X8/X10 互斥组选择，中心=十字线像素，近边缘钳位，放大图上叠加十字线+中心圆标记锁定像素），点击一并写入 b{i}_h 与 b{i}_q）/风格预设存取 `IspFlow/ColorStyle/*.colorstyle`，段按钮过多时横向滚动）、附加区含播放控制条（播放/暂停 + 帧进度滑条，与预览节点同款；均衡器节点本身即播放汇点——无预览节点的图也可对其播放，`fps`/`frameCount` 经 `autoFillFromVideo` 一并填充）、附加区上行为前后双联矢量示波器（复用 `hslVectorscopes`/`hslInputVectorscopes` 缓存，与 vectorscope 仪器同口径）、下行为前后双联预览图（视频播放中两者逐帧同步：CPU worker 路径把均衡器输出链/输入链并入 `runParallel` 靠前缀覆盖顺带捕获（`multi_band_eq` 已入 `_captureSafe` 白名单——输出恒为新帧不就地改写），GPU 链路径经 `displayCaptures` 顺带捕获 `'eqId'/'eqId#in'` 出图；矢量示波器播放中按 ~5Hz 节流刷新（`_refreshEqScopesFromPlayback`：busy 闸 + 200ms 限频，馈源优先 `_lastPlaybackRgba` 的 `'eqId'/'eqId#in'` 条目、GPU 链路径回退预览图回读，fire-and-forget 不阻塞走帧——连线渲染是仪器池热点的教训保留为节流而非逐帧），停播时再以最后一帧前后预览图统计补齐最终帧（`_refreshEqScopesFromPreviews`））、并联/串联合成单一 H 域 LUT 查表执行、GPU shader `isp_hsl_bands.frag`、C 导出整帧 func/lut 双模式 + 黑盒行核，对拍见 `test/isp_multi_band_eq_test.dart` 与 `test/isp_c_ref_compare_adjust_test.dart`；LUT 行核/整帧 lut_apply 的色环回绕用单次条件加减替代 `% m`（|shift| ≤ max/2 恒成立）、钳位取整用 `floor(v+0.5)`+进位修正替代 libm `round/lround`（运行时参数整数除法与 libm 函数调用是逐像素路径耗时大头，替换均与 Dart 逐位一致，另有 hsl_debugger/color_controller 行核同款优化）；另有 **lut_fixed 定点模式**（`codegenMode=lut_fixed`，黑盒行核专用：H 表同 lut 的 int16，S/L 乘子烘焙为 Q14 定点整数表，`bb_clamp_q14` 整数乘加——面向 A55 等无 FP64 SIMD 的嵌入式核（NEON 仅 FP32，FP64 只能标量 FPU），与 FP64 口径偏差 ≤1 LSB，对拍（Q14 逐位 + FP64 偏差）见 `test/isp_group_c_export_test.dart` 的 lut_fixed 用例；域失配与 lut 同口径回退 compose 直算）；当编组恰为**单个 lut_fixed 均衡器节点**（零延迟、无窗口、外部输入→单一外部输出）时，阶段发射走整行函数 `<id>_row`（`node_c_stream.dart` 的 `_lutFixedRowFn`：`#if defined(__ARM_NEON)` 的 NEON 变体——VLD3 解交织 + int16 通道 H 回绕 + 32 位通道 Q14 乘加（q ≥ 2^14 且超域先钳输入的向量化规则，与乘加后钳位逐位一致）+ VST3 重交织，标量变体与融合行核逐位一致——供 mix210 等设备上 `--dump-hash` 对拍验收）；该单节点形态的 top 层 y 循环另加 `#if defined(_OPENMP)` 守护的 `#pragma omp parallel for` 行域并行（整数路径与线程数无关逐位一致——FP 内核编组一律不加，见此前 omp 轮廓 FP 差异教训；A55 四核配 -fopenmp 即多核，不开 omp 自动串行；实测 x86 8 线程 run 段 26→3.9ms/帧）；该节点等效多个色彩控制器混叠，允许单节点编组（`canGroupSelectedNodes`/`groupSelectedNodes`/`validateGroupCExport` 三处放行，编组后右键即可查看/导出 C 代码））；深度评价节点（LPIPS/DISTS/FID/KID/MUSIQ/CLIPIQA）经 `pipeline/pyiqa_worker.dart` 调 Python 桥接进程计算；另有 Tools 分类「格式转换」节点（`format_converter`，纯工具节点无端口，不参与图像流水线）：经内置 ffmpeg 做 webm→mp4 转码（NVENC 优先、失败回退 libx264），编码器可选（自动硬件优先/CPU libx264/实测可用的 NVENC/QSV/AMF 硬件编码器——`-encoders` 编译支持解析 + 逐候选微缩试编码探测真实可用性）；NVENC 档转码走 NVDEC 硬解 + scale_cuda 零拷贝 GPU 链（`-hwaccel cuda -hwaccel_output_format cuda`，帧不回读内存，实测 4K60 ~1.45x 提速、CPU 近乎全闲；HDR→SDR 因 tonemap 在 CPU 保持软解链），单档 cuda 失败自动落下一档（无 cuda）；输入片源 HDR/SDR 自动识别（videoFileInfo），输出动态范围可选 自动（跟随片源）/SDR（zscale+tonemap 映射）/HDR（HEVC 10bit + bt2020/PQ/HLG 容器标记，CPU 兜底 libx265，h264 系编码器自动改对应 hevc 档），节点卡片内嵌终端面板流式显示 ffmpeg 输出（`\r` 进度行覆盖处理见 `appendConsoleText`；节点尺寸固定 1500x1200——min=max 钳制不可调、无拖动手柄，终端区整页显示处理信息），编码链逐档尝试（NVENC/QSV/AMF → libx264 兜底），实现见 `pipeline/format_convert.dart` 的 `runFormatConvert`；另有 Tools 分类「视频健康检查」节点（`video_health_check`，record-2024-09-26 卡顿排查检查项固化，纯工具节点无端口、尺寸固定 1500x1200 同格式转换）：元数据（codec/profile/pix_fmt/色彩三要素→SDR/HDR/音频）、帧率三角一致性（avg/VUI/pts 中位，VUI 虚标→CFR 复制/丢帧警告）、时间戳 gap/重复/B 帧重排（`-debug_ts` 包级扫描不解码）、关键帧间隔（`-skip_frame nokey`+showinfo）、完整模式加交付帧数对比（默认 CFR vs passthrough，复制倍率）与冻结帧（freezedetect+checksum 双口径），报告逐项 [✓]/[⚠]/[✗] 流式显示在内嵌终端，状态栏实时进度（阶段/已检帧/已检时间/完成度/预估剩余，`HealthCheckProgress` + `onProgress` 阶段加权），可中止（按钮变红色「停止检查」，`isCancelled` 轮询 kill 当前 ffmpeg 子进程返回 -2），实现见 `pipeline/video_health.dart` 的 `runVideoHealthCheck` |

应用强制暗色主题（`lib/main.dart` 中 `themeMode: ThemeMode.dark`），初始窗口尺寸 1658×869，启动时经 `windowManager.maximize()` 默认最大化；多显示器时先经 `screen_retriever` 获取主显示器工作区并把窗口定位到主屏居中，确保最大化落在第一个显示器。

## 技术栈与关键配置

- **语言/框架**：Dart `^3.12.2` + Flutter；目标平台为 **Windows 桌面**（`windows/` 为标准 runner；`web/` 目录存在但不是主要目标）。
- **关键配置文件**：
  - `pubspec.yaml` — 依赖与资源声明。主要依赖：`provider`（状态管理）、`window_manager`、`package_info_plus`（标题栏版本号）、`flutter_libserialport`、`dartssh2`、`file_selector`、`ffi`、`archive`、`image`、`flutter_svg`、`flutter_colorpicker`、`intl`。
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
- `lib/providers/` — 每个模块对应一个 `ChangeNotifier` 状态类（`AppState`、`TerminalState`（串口终端）、`NetworkTerminalState`（网络终端）、`OscilloscopeState`、`MacroState`、`HexEditorState`、`TextEditorState`、`FontExtractorState`、`UiDesignerState`、`IspStudioState`）。**状态管理统一用 Provider**，`OscilloscopeState` 通过 `ChangeNotifierProxyProvider` 依赖 `TerminalState`；两个终端状态类均实现 `terminal_session.dart` 的 `TerminalSession` 接口，供终端 UI 组件复用；`MacroState` 由两个终端共享。
- `lib/modules/<模块名>/` — 每个模块内含 `<模块名>_view.dart` 根视图，及 `models/`（纯数据/逻辑，尽量无 Flutter 依赖）、`widgets/`（UI 组件）等子目录；`ui_designer` 另有 `codegen/`（C 代码生成），`isp_studio` 另有 `pipeline/`（流水线执行、ISP 核、仪器、Worker）与 `codegen/`（编组导出嵌入式 C：每节点实例封装 + top 层 pipeline 生成，覆盖 Process 含 ColorTrans/Fluorescence + Datapath 共 49 个类型，拓扑序调用 + 调用方 scratch 竞技场，MSVC 语法编译测试在 `test/isp_group_c_export_test.dart`；规划层 `group_c_plan.dart` 与发射层 `group_c_export.dart` 分离；编组/黑盒代码页另有「运行验证（原尺寸）」/「运行验证（scale）」按钮（绿色播放图标为原尺寸——保持原生分辨率，让「处理 Xms」反映嵌入式目标的全尺寸帧耗时；蓝色播放图标为 scale——逐级减半降档至宽 ≤1280，四段耗时同比缩小，状态栏标注原分辨率；两者均经 `buildWinVerifyApp` 构建 + `stubMainWinSource` 生成 `main_win.c`：纯 Win32 前后对比窗口——并列/单视频双模式实时互切 + 单视频原图⇄处理后硬切 + `--frames N --dump-hash` 批模式 FNV-1a 哈希对拍（管线量化域 MAXV 随编组位深经 `lutDomainMaxOf` 推导传入 `buildWinVerifyApp(maxValue:)`——LUT 模式节点的查表快路径要求运行时 max_value 与烘焙域一致，否则逐像素回退直算；装帧/解包按 `* MAXV / 255` 缩放，MAXV=255 时恒等）；帧来源优先为编组上游视频/图片源——验证程序内嵌 ffmpeg 子进程管道流式解码（`--video`/`--ffmpeg` 传参，`rgb24` 原始帧，`-ss` 重启实现进度条点击跳转，EOF 循环重播，启动时横幅探测分辨率/时长/帧率；窗口模式优先尝试 CUDA 硬解链——NVDEC 解码 + `scale_cuda` GPU 缩放兼 10→8bit 转 nv12，**交付 nv12 由进程 omp 转 BT.709（Q8 定点）**（4K 原生交付 ~57→111fps、原尺寸播放 ~6→30fps 的关键；批模式/软解保持 ffmpeg 出 rgb24 不动哈希口径），首帧读取失败（如 Rext 4:2:2 NVDEC 不支持）自动回退软解，状态栏标注 GPU/SW，`--swdec` 强制软解；批模式恒软解保哈希对拍可复现；匿名管道缓冲 GPU 链开 6 帧作解码预读，软解保持 2 帧避免 ffmpeg 解码线程与管线 OpenMP 线程持续争抢 CPU；ffmpeg 子进程解码/滤镜线程封顶 `-threads 8 -filter_threads 8`（`FF_DEC_THREADS`，默认 auto 在 112 核机上软解 4K Rext 会起上百个解码线程打满内存带宽——内存硬件边缘状态的机器因此被压出 WHEA 可更正错误风暴乃至硬挂起；线程数不影响解码像素，批模式哈希口径不变）；OpenMP 线程数封顶 min(核数-2, 16)（大核数机上 vcomp 工作线程空转自旋会占满全机核），验证程序与 ffmpeg 子进程均以 BelowNormal 优先级运行（软解 8K/Rext 重载源不拖垮桌面）），窗口含播放/暂停按钮 + 可点击/拖动进度条（拖动即显示：按下/拖动走关键帧级低分辨率直显预览、跳过管线处理——预览工作线程池解码，UI 只递增请求序号写最新位置，worker 只认领最新序号（中间位置跳过）；Rext/HEVC 等高码率源单帧软解为单核瓶颈（实测与解码线程数无关），故池化 PREV_POOL=3 个独立 libav 实例并行解码，上屏按序号丢弃迟到帧；内嵌常驻解码器（`--avdir` 指向 tools/ffmpeg/bin 的 libav* DLL，main_win.c 运行时 LoadLibrary 免 import lib，`av_seek_frame` 关键帧直达 + 立即解一帧 + swscale 到预览宽 ≤640）优先，DLL/头文件缺失时编译期 `HAVE_AV=0` 或运行时回退 `-noaccurate_seek` 子进程单帧预览（单 worker），头文件经 buildWinVerifyApp 自动附加 `/I tools/ffmpeg/include`；并列模式只换左侧画面、右侧处理后画面冻结置灰（AlphaBlend 黑罩），单视频模式整幅预览，暂停中也可拖动且不改变播放状态；松开/点击落定封锁认领、等在途解码完成后做精确 seek + 全尺寸管线处理恢复前后对比）+ 底部状态栏（分辨率/实时帧率/播放位置）+ 控制条「处理 Xms」（上一帧管线本体耗时，不含读流/装帧/解包；分段均值见批模式 timing 行），无源时回退内置测试图案；仅单外部输入/输出帧且 rgb/hsl 端口时显示入口，main_win.c 不导出，产物 `scratch/cc_win_check/{top}_win.exe`）另有**黑盒行级流水变体** `group_c_export_bb.dart`：右键菜单「查看黑盒子C代码」，单文件 `isp_pipe_<组>_bb.h/.c` 只暴露编组输入/输出，点对点链最大化融合进行循环（中间结果不物化整帧），垂直窗口节点（dpc/sharpen/edge_extract/rgb_dnr/bayer_dnr/demosaic(bilinear)/highlight）与分离趟（morphology/gaussian_blur，c_ref 本即水平趟+垂直滑窗结构）经 scratch 环形行缓冲（行号取模寻址，含派生环与 gaussian double 卷积环/权重核），汇合延迟差经 FIFO 均衡，主循环后尾部冲刷补齐延迟行，`{TOP}_SCRATCH_BYTES` 宏逐项可见资源占用（无 h 因子，不存整帧）；面向嵌入式高实时场景。流式规划在 `stream_plan.dart`、行核发射在 `node_c_stream.dart`；拒绝集（校验报错并列出节点名）：ahe、fpn、fluoro_temporal/normalize/background/fusion、grgb_balance、white_balance auto、demosaic 非 bilinear/非 Bayer CFA、数据环；测试 `test/isp_group_c_blackbox_test.dart`（含整帧版 vs 黑盒版 MSVC 数值对拍，逐字节一致；另有 lut_fixed NEON 行核的 aarch64 交叉 gcc 实机编译用例——`__ARM_NEON` 分支在 MSVC/x86 编译中被预处理器剔除，只有交叉 gcc 真正编译该路径，无交叉工具链自动跳过，`-Wall` 零警告断言）。编组右键菜单另有「更改编组名」（`IspStudioState.renameGroup`）。
- `lib/utils/` — 跨模块工具（ANSI 解析、波形存储 `waveform_storage.dart` 等）。
- `lib/theme/app_theme.dart` — 暗色主题定义。

## 数据目录与文件格式（运行时依赖）

以下目录在代码中按**相对工作目录**访问，属于程序运行/打包的一部分：

- `DeviceProtocol/{I2C,SPI,Uart}/` — `.Regfile`（I2C/SPI 寄存器/命令定义）与 `.UartProtocol`（UART 帧格式定义）文件，均为 JSON 语法。格式规范见 `docs/Regfile_Format.md`、`docs/UartProtocol_Format.md`。
- `bussetup/` — `.bussetup` 总线配置（单行 JSON：引脚、缩放、解码器等）。
- `waveform/` — `.waveform` 波形存档：头部魔数 `WAVEFORM1.0` + JSON 元数据 + gzip 压缩的二进制采样数据。
- `IspFlow/` — `.ispflow` ISP 流程图文件（JSON 文本）；`IspFlow/ColorStyle/` 为多段色彩均衡器的 `.colorstyle` 色彩风格预设目录（运行期自建，打包随 IspFlow 整目录分发）。
- `UI_Project/` — `.uiproj` UI 设计器工程文件（JSON）；`UI_Project/exported_c/`、`gpu_effects_demo_c/` 为导出示例。
- `tools/ffmpeg/ffmpeg.exe` — ISP Studio 视频导出默认使用（节点属性 `ffmpegPath` 默认值 `tools/ffmpeg/ffmpeg.exe`）。`tools/ffmpeg/bin/`（libav* DLL，ffmpeg 9.0.2 full_build-shared，gyan.dev/GPL）与 `tools/ffmpeg/include/`（配套头文件）为验证程序内嵌拖动预览解码器的运行时/编译期依赖（见 `stubMainWinSource` 的 `--avdir`/`HAVE_AV` 分支），须随安装包分发（`.iss` 已递归打包 tools/）。
- `tools/iqa/` — 深度评价节点（LPIPS/DISTS/FID/KID/MUSIQ/CLIPIQA）的运行时资源与桥接。**默认进程内 Dart 计算**（`pipeline/metrics/*_dart.dart` + `pipeline/nn/` 推理引擎，经 `isp_studio_state.dart` 的 `_analyzeDeepIqa` 走共享 `NnPool` 常驻 isolate 池；**MUSIQ 例外**：经 `compute(musiqScoreInIsolate)` 整体在后台 isolate 执行并自起 NnPool（核数-4）——transformer 全部 GEMM 池并行、per-head softmax 经 Isolate.run 按头并行，与同步版位级一致，避免 transformer 同步计算冻结 UI），权重为 `tools/iqa/weights/*.nnw`（需随安装包分发），由 `tools/iqa/export_weights.py` 一次性生成——Python 环境（torch/torchmetrics/lpips/pyiqa，解释器路径常量 `pyIqaPythonPath`，开发机默认 `scratch/eval_venv/Scripts/python.exe`）仅用于权重导出与对拍。LPIPS/DISTS 的 VGG16 主干另有 **GPU 纹理驻留链**（`pipeline/metrics/vgg16_gpu.dart` + `pipeline/nn/nn_gpu.dart` 的 fp16 打包 FragmentShader，仅 UI isolate）：`_analyzeDeepIqa` 懒创建共享 `Vgg16Gpu`，输入上传一次后 13 conv+relu+4 pool 全部驻留执行、仅 5 个切片特征回读，任一步不支持/失败整链回退 CPU 池；DISTS/LPIPS 的打分头另有 GPU 归约快路径（优化 15/16：`nn_chstats_f16.frag` 按带计算逐通道 5 项统计，`GpuChannelStatsBatch` 单次物化回读，跳过切片全量下载；LPIPS 另有 `nn_pixnorm_f16.frag` 逐像素范数图 + `nn_lpips_stats_f16.frag` 3 项统计；`Vgg16AsyncForward.supportsChannelStats`/`supportsLpipsStats` 能力探测）；特征图折叠布局总纹素数 < 2^24 时走单纹理路径，超出（如 1024×768 以上大图）自动切**分块路径**——沿 H 切带、每带一张纹理（带预算 2^23 纹素），conv/L2pooling 带间 halo 经 `shaders/nn/nn_stitch3_f16.frag` 拼接为 padded 带（uYOff=1），maxpool/relu 逐带直接执行，规划见 `GpuNnBackend.planBandHeights`/`planConvOutBands`（含 stitch 覆盖 ≤3 与 maxpool 奇偶约束），仍不可行的形态预检抛 `UnsupportedError` 回退 CPU；全局开关 `Vgg16AsyncForward.enabled`，真机性能基准入口 `scratch/nn_gpu_vgg_bench_main.dart`。CLIPIQA 的 RN50 主干另有同构 **GPU 纹理驻留链**（`pipeline/metrics/clip_rn50_gpu.dart`：conv3x3 shader 支持 s1/s2，另有 avgpool2x2 与残差 addrelu shader，分块路径中 1x1 conv 走 noHalo 无 halo 拼接规划——深层高通道 1x1 的可行性关键；AttentionPool2d 只算 token 0——Linear 逐行独立故与全量位级一致——k/v 投影经 NnPool 并行），`_analyzeDeepIqa` 懒创建共享 `ClipRn50Gpu`，失败整链回退 CPU 池；fp16 存储下 CLIPIQA 分数 vs Python 偏差 ≤5e-3（已确认验收口径），全局开关 `ClipRn50Gpu.enabled`，真机基准入口 `scratch/nn_gpu_rn50_bench_main.dart`。FID/KID 的 InceptionV3 patch 特征提取另有同构 **GPU 纹理驻留链**（`pipeline/metrics/inception_v3_gpu.dart`：conv shader 已泛化至 k≤7 含非对称 1x7/7x1 与原生 1x1、pad≤3、relu 末 pass 融合；另有 pool3x3（max/avg countIncludePad=false）与 concat4（≤4 路通道组对齐纯字节拷贝）shader；patch 恒 299² 只走单纹理路径），`_analyzeDeepIqa` dist 分支懒创建共享 `InceptionV3Gpu`（`_deepIqaFeatOnGpu` 记录特征后端供缓存命中时回填徽标），失败整批回退 patch 并行 CPU 路径；fp16 下 FID vs Python 偏差 ~2.6e-3（既有口径 ≤1e-2），全局开关 `InceptionV3Gpu.enabled`，真机基准入口 `scratch/nn_gpu_inception_bench_main.dart`。KID 出分另走**每节点常驻 isolate 的增量核矩阵**（`pipeline/metrics/kid_score_worker.dart` + `fid_kid_dart.dart` 的 `KidGramAccum`：视频逐帧累计时新增样本只算核矩阵新增块，每帧 O(n·Δ·d) 替代全量重算 O(n²·d)，与全量 `kidCompute` 逐位一致；FID 统计仍每帧低秩重算 + `compute(fidScoreInIsolate)`）。`tools/iqa/iqa_bridge.py`（常驻子进程 + stdin/stdout JSON 行协议，Dart 侧封装为 `pipeline/pyiqa_worker.dart`）降级为**回退/对拍路径**：仅当权重文件缺失且 Python 环境可用时使用；两者都缺时节点显示「需要权重文件 tools/iqa/weights/… 或 Python 环境」，其余功能不受影响。
- `docs/Oscilloscope_Protocol.md` — 下位机（FPGA/MCU）二进制同步帧通信协议规范，修改示波器数据通路时应先阅读。

**Impeller 注意事项（Flutter 3.47+）**：Windows 端在 `windows/runner/main.cpp` 里显式 `set_impeller_switch(ImpellerSwitch::Disabled)`——Flutter 3.47 默认启用的 Impeller（ANGLE OpenGLESSDF）会使上述 NN fp16 shader 链产生数值漂移与越界损坏（fp16 加法截断、banded 带末行垃圾、部分 conv/concat 形态出 Inf，详见 `DEEP_IQA_PROGRESS.md` 优化 12 与 `scratch/nn_gpu_primitive_probe*.log`）；Skia 下全部恢复位级一致。`flutter run --no-enable-impeller` 在 3.47 的 Windows release 构建中不生效，只能靠 main.cpp 开关。引擎侧修复前不要移除该开关。

其余顶层目录多为**测试素材与参考资料**，不属于代码：`datasheet/`、`MSO8000/`、`SIGLENT/`（各厂编程手册 PDF）、`BayerRGGB/`（RAW 图测试数据）、`Font/`、`FontLib/`、`Memorydump/`、`binfile/`、`cfile/`、`vfile/` 等。

## 测试

- 测试位于 `test/`（约 58 个 `*_test.dart`），使用 `flutter_test`。
- 命名约定：`isp_*` 前缀对应 ISP Studio，`font_*` 对应字库提取，`ui_*` 对应 UI 设计器，`text_editor_*`/`folder_*` 对应文本对比模块。
- 运行：

```bash
flutter test                    # 全部测试
flutter test test/isp_kernels_test.dart   # 单个文件
```

- ISP C 参考实现对拍测试为 `test/isp_c_ref_compare_*_test.dart`（C harness 在 `test/c_ref/`，经 `scripts/c_build_harness.bat` 用 MSVC 构建为 `scratch/c_ref_check/c_ref_harness.exe`，无 MSVC 环境自动 skip）。

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

## 协作规则（AI 助手工作方式）

以下规则在与用户的长期协作中确立，每次会话开始即生效：

- **耗时任务一律后台执行**：`flutter build`、`flutter test`、`flutter analyze` 等耗时命令必须以后台任务方式运行（`run_in_background=true`），不要在前台阻塞等待；任务完成后再向用户汇报结果。前台对话优先，用户随时可以插入新需求。
- **构建互斥**：同一时间只允许一个 flutter 构建/运行命令在执行。多个 flutter 进程同时写 `.dart_tool/flutter_build` 和 `build/` 会互锁导致连锁编译错误（app.so 无法写入等）。助手后台有构建在跑时，应提醒用户不要在自己终端同时执行 `flutter run` / `flutter build`。
- **`flutter clean` 前先确认**运行中的 `debug_tool_set.exe` 已关闭，否则 `build/` 删不干净。
- **Flutter 版本敏感，不主动升级**：NN fp16 GPU shader 链在 Skia 下逐位验证过，依赖 `windows/runner/main.cpp` 的 Impeller 关闭开关（见「Impeller 注意事项」）。如确需升级 Flutter：`flutter clean` → 确认 Impeller 开关仍在且编译通过 → `flutter test` → 实测 ISP Studio GPU 预览与深度评价节点。
- **清理文件前核对运行时目录**（见「数据目录与文件格式」一节）：`tools/`、`bussetup/`、`DeviceProtocol/`、`waveform/`、`IspFlow/`、`UI_Project/` 等虽不参与编译，但删除会导致运行/打包失败。
- **版本与构建号**：`rebuild.bat`（clean → pub get → release 构建）成功后会自动执行 `scripts/bump_build_number.dart` 递增 `pubspec.yaml` 的构建号（`version: x.y.z+N` 中的 N）；`RunDebug.bat` / `RunRelease.bat` 日常调试运行不递增。应用内版本信息对话框（侧栏底部 ⓘ 图标，实现见 `lib/utils/build_info.dart`、`lib/layout/about_dialog.dart`）展示应用版本、Flutter/Dart SDK 版本（构建时 dart-define 自动注入）与 CMake 生成器（编译环境），排查环境问题先看这里。
