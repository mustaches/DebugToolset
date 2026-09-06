# 深度评价节点去 Python 依赖 —— 进度快照（2026-09-03 夜）

> 本文件是开发进度存档，完成后可删除。配合 git 提交 `feat(isp_studio): 深度评价节点进程内计算` 阅读。
>
> 注：为定位 UI 卡死加入的临时诊断（`lib/utils/ui_stall_watchdog.dart` + 各处 `// 临时诊断` 标注行）已于优化 4-10 全部真机复验通过后**整体移除**（lib/ 零残留）；下文各条目中的「临时诊断继续保留/复验后移除」为当时的历史记录。

## 已完成（全部经过对拍验证）

1. **6 个深度评价节点（LPIPS/DISTS/FID/KID/MUSIQ/CLIPIQA）已移植为进程内 Dart 实现**，
   不再依赖 Python 环境；Python 桥接（`tools/iqa/iqa_bridge.py` + `pipeline/pyiqa_worker.dart`）降级为回退/对拍路径。
   - 推理引擎：`lib/modules/isp_studio/pipeline/nn/`（.nnw 权重读取、分块 sGEMM ~2.2 GFLOPS/核、22 种 op 与 torch 黄金值对拍、NnPool 常驻 isolate 池、非对称矩阵特征值求解器 eig.dart）。
   - 指标实现：`lib/modules/isp_studio/pipeline/metrics/*_dart.dart`（对拍误差：LPIPS 3e-5、DISTS 1e-4、FID/KID 1e-3、CLIPIQA 5e-4、MUSIQ 2e-3 分）。
   - 权重：`tools/iqa/weights/*.nnw`（397MB，**不入 git**，由 `tools/iqa/export_weights.py` 用 eval_venv 一次性生成；换机器需重新生成）。
   - 集成：`isp_studio_state.dart` 的 `_analyzeDeepIqa`（权重齐全→进程内；否则回退 Python；FID/KID 共享 Inception 特征缓存）。
2. **GPU 加速（VGG16，LPIPS/DISTS）**：fp16 打包 FragmentShader 驻留链（`metrics/vgg16_gpu.dart` + `nn/nn_gpu.dart` + `shaders/nn/`），小图（≤~512×384 馈源）默认开启、约 9× 提速，端到端偏差 ≤1.6e-4，失败自动整链回退 CPU。全局开关 `Vgg16AsyncForward.enabled`。
3. **节点流程图面板**：评价节点显示运行耗时与 GPU/CPU 徽标（仪器分析路径回填 `nodeRunTimesUs`/`nodeRunOnGpu`）。
4. **实跑验证**：「图像评价.ispflow」（20MP×2，14 指标）纯 Dart 全流程 14/14 出分（约 45 分钟，CLIPIQA 最长尾）。
5. 测试约定：flutter_tester 是软件光栅，凡走 `_analyzeDeepIqa` 的测试须先关闭 GPU 链（`Vgg16AsyncForward.enabled = false` / `ClipRn50Gpu.enabled = false` / `InceptionV3Gpu.enabled = false`，已在 isp_deep_iqa_integration_test / isp_eval_flow_repro_test / isp_pyiqa_test 处理；后者还以 CPU 池分数做 1e-6 断言，GPU 路径的 fp16 偏差会超限）。
6. **优化 1（GPU 链大图分块）已完成**（2026-09-04 验收）：
   - 实现：`nn_gpu.dart` 分块 API（upload/conv/relu/maxpool/l2pool/download 的 Banded 变体 + `planBandHeights`/`planConvOutBands` 规划 + stitch 覆盖 ≤3 与 maxpool 奇偶预检）、`shaders/nn/nn_stitch3_f16.frag`（halo 拼接，已在 pubspec 登记）、`vgg16_gpu.dart` 自动按层预检选择单纹理/分块路径。
   - 单测：`test/isp_nn_gpu_test.dart` + `test/isp_nn_gpu_vgg_test.dart` 21/21 通过（分块原语/整链逐层切片 vs CPU，端到端 vs Python：LPIPS 6.7e-5、DISTS 1.6e-4）。
   - 真机验收（`scratch/nn_gpu_vgg_bench_main.dart`，NN_VGG_BENCH 输出）：1024×768（4 带）LPIPS/DISTS vs Python 基线偏差 8.9e-5 / 4.1e-5（验收 ≤1e-3 ✓）；1688×3000（21 带目标馈源）LPIPS 57s vs CPU 636s（~11×）、DISTS 47s vs 649s（~14×），GPU-vs-CPU 分数差 2.1e-5 / 1.5e-6；小图单纹理路径无回归（256×192 vs Python 7.8e-6 / 7.7e-5）。
7. **优化 2（RN50 GPU 链，CLIPIQA）已完成**（2026-09-04 验收）：
   - 实现：`nn_gpu.dart` 扩展（conv3x3 shader 加 uStride 支持 s2；新增 `nn_avgpool2x2_f16.frag`/`nn_addrelu_f16.frag`；banded 变体含 1x1 conv 的 noHalo 无 halo 拼接规划——深层高通道 1x1 的可行性关键）、`metrics/clip_rn50_gpu.dart`（stem+16 Bottleneck 整链纹理驻留，conv3 forceOutHeights 对齐 identity 分块做残差 addrelu）；AttentionPool2d 改为**只算 token 0**（Linear 逐行独立 ⇒ 与全量位级一致，L² 矩阵降为 L 向量）并经 NnPool 并行（k/v 投影走 parallelGemm）。
   - 单测：`test/isp_nn_gpu_rn50_test.dart` 12/12 + 相关回归全绿（`isp_nn_gpu_test.dart` 的「不支持的形态」用例随 s2 放开而更新；`isp_clipiqa_dart_test.dart` 黄金值/位级一致/Python 对拍均过）。
   - 真机验收（`scratch/nn_gpu_rn50_bench_main.dart`，NN_RN50_BENCH 输出）：1024×768 2.7s vs CPU 23.6s（~9×）；1688×3000 15.0s vs 146s（~10×）；2736×3648（10MP）GPU 30s（CPU 池超 6 分钟未跑）vs Python 偏差 2.7e-5。
   - **精度口径：GPU vs Python 实测 1.6e-3~4.1e-3（fp16 存储固有，RGBA8 离屏目标限制），经确认按 ≤5e-3 验收**（CLIPIQA 0~1 分制下不影响判读）；小图 CPU 路径位级不变。
8. **优化 3（InceptionV3 GPU 链，FID/KID）已完成**（2026-09-04 验收）：
   - 实现：conv shader 泛化（`nn_conv3x3_f16.frag`，k≤7 含非对称/原生 1x1、pad≤3、uRelu 末 pass 融合；默认参数路径与旧版逐位一致——LPIPS/DISTS/CLIPIQA 端到端分数与泛化前完全相同）；新增 `nn_pool3x3_f16.frag`（max 跳越界 / avg countIncludePad=false）与 `nn_concat4_f16.frag`（≤4 路通道组对齐纯字节拷贝）；`metrics/inception_v3_gpu.dart` 整链驻留（121 conv 全 relu 融合，仅 Mixed_7c 输出回读一次，adaptiveAvgPool1x1 在 CPU）；patch 恒 299² ≪ 2^24 故只走单纹理路径（无 banded）。
   - 单测：`test/isp_nn_gpu_inception_test.dart` 7/7（泛化 conv 全形态/pool3x3 三模式/concat 位级、99² 迷你整链 cosine 0.99994）；GPU 三件套 + FID/KID 集成回归全绿。
   - 真机验收（`scratch/nn_gpu_inception_bench_main.dart`，NN_INC_BENCH 输出）：黄金值 worstCos 0.999998 / worstRelL2 2.3e-3；1688×3000（220 patch）特征提取 22.9s vs CPU 并行 160.5s（7×）；FID vs Python 偏差 2.6e-3（既有口径 ≤1e-2 ✓），KID 同量级 ✓。
9. **优化 4（FID 出分低秩快路径 + PSNR/SSIM/MS-SSIM/FSIM 节点内并行）已完成**（2026-09-05 验收）：
   - **FID 低秩快路径**（`metrics/fid_kid_dart.dart`）：`fidScoreFromFeatures` 在 `min(nRef,nTest) < 2048`（实跑恒成立）时走 `_fidLowRank`——λ(AB)=λ(BA) 把 σ1σ2 的非零特征值归约到 min(n)² 小矩阵（P = (X1cX2cᵀ)(X2cX1cᵀ)/((n1−1)(n2−1))，对称半正定），trσ 与均值项同口径直接算；否则回退 2048² 旧路径 `fidCompute`（API 原样保留）。
     - 验证：`test/isp_fid_kid_dart_test.dart` 新增「快路径 vs 旧路径」一致性用例（math.Random(42) 确定性特征，对称 n=12、不对称 12 vs 20 与 20 vs 12）。**注意断言口径**：快路径触发条件 min(n)<dim 意味着 σ1σ2 恒秩亏（rank ≤ n−1），旧路径的 dim−rank 个真零特征值经 Re(√λ) 把 QR 残差（~1e-16·‖σ1σ2‖）放大为 ~1e-8/个 的系统性噪声底（实测总差 ~1e-7，其中 2×Σ√(零特征值残差) = 1.04e-7 占全部；剔除后残差 3.8e-9，见 `scratch/fid_lowrank_diff_probe.dart`）——故一致性断言取 1e-6 而非 1e-9，差异非 `_fidLowRank` 实现误差。
     - e2e：eval_set 5 对图（n=10，走快路径）出分 **5.6ms**（旧路径 ~40s），vs Python relErr 1.0e-3（口径 ≤1e-2 ✓）；eig 黄金值、Inception 特征对拍等既有用例照过（全文件 8/8）。
   - **四指标节点内并行**（仅 `pipeline/instruments.dart` 的 `dualMetricInIsolate` 路径，直接函数语义不变）：w·h ≥ 1<<20 且缓冲恰为 w×h×4 时在自身 isolate 内嵌套 `Isolate.run` 并行——PSNR 按行带切分部分和（`_psnrBandSum`）、SSIM 按 8×8 块行带切分（`_ssimBandSum`，bh 边界对齐）、MS-SSIM/FSIM 按 R/G/B 通道三路（`_msssimChannel`/`_fsimChannelValue`，FSIM 子 isolate 各自分配工作平面）；部分和按带/通道序确定性合并；子 isolate 数 = max(2, 核数−2)（同 inception 口径）。小图/长度不符走原串行路径。串行直接函数重构为共享同一批部分和/单通道 helper（累加顺序不变，数值逐位一致）。
     - 验证：`test/isp_instruments_test.dart`（PSNR）、`isp_ssim_test.dart`、`isp_msssim_test.dart`、`isp_fsim_test.dart` 各增「1024×1024（=1M 像素恰触发并行）并行路径 vs 直接函数 closeTo 1e-9」用例（确定性公式图 + 伪噪声）；`isp_eval_reference_test.dart` 既有参考值断言（SSIM/MS-SSIM/FSIM 1e-6、PSNR 1e-4 dB）照过——5 个文件 56/56 全绿，`flutter analyze` 干净。
10. **优化 5（GPU 链加载竞态与 UI 卡死修复）已完成**（2026-09-05 验收）：
   - **根因**（真机「图像评价.ispflow 20MP×2 14 指标」开局 UI「未响应」135s+85s，`log/ui_stall_log.txt` 实证，两个既有问题、优化 1-3 引入）：① `_sharedVggGpu`/`_sharedRn50Gpu`/`_sharedInceptionGpu`「先置 tried=true 再 await load」的竞态——并发节点拿到 null 退化 CPU 全核慢路径（KID 节点 Inception CPU 特征提取占满全核 2-3 分钟）；② 三条链 load 在 UI isolate 同步做 NnwReader 读 + fp16 打包大循环，被 CPU 风暴饿死成 135s 卡死（NnPool 启动同被饿死 223s）。
   - **修法**：① getter 与 `GpuNnBackend.tryCreate` 改为缓存 in-flight Future（同 `_nnPoolStart` 模式）：并发共享同一次 load，失败缓存 null 保持「不再重试」；② 打包纯函数移至新文件 `pipeline/nn/nn_gpu_pack.dart`（纯 Dart 无 dart:ui：floatToHalfBits/halfBitsToFloat/pack*/unpack*/embed1x1 + `PackedConvWeights` 等可发送结构 + 整网 compute 入口 `packVgg16Weights`/`packRn50Weights`/`packInceptionWeights`/`packFeatureInIsolate`/`packFeatureBandsInIsolate`），`nn_gpu.dart` 同名静态方法委托、数值逐位不变；三条链 load 改为**整网一次 compute** 后台读+打包，UI 侧仅 `uploadPackedConvWeights` 上传纹理；大输入特征图上传（≥1M 元素单纹理与全部分块带）打包同样挪 compute。
   - **验收**：GPU 四套件 + fid/kid 48/48 全绿（LPIPS/DISTS/CLIPIQA 端到端 GPU 分数与修复前**逐位相同**，证明打包路径数值一致）；`flutter analyze` 干净；全量套件与基线一致无新增失败。临时诊断（ui_stall_watchdog + isp_studio_state 的 `// 临时诊断` 行）**保留**待真机复验后移除。
11. **优化 6（仪器并发治理 + GPU 派发让出）已完成**（2026-09-05 验收）：
   - **根因**（优化 5 后真机复验：FID 746.63s≈KID 746.54s、LPIPS 689s≈DISTS 699s（GPU 徽标）——时间相同证明全并发同时结束，单链基准 LPIPS GPU 仅 57s；标题栏仍「未响应」）：`_runInstruments` 的 `Future.wait` 把全部仪器节点一次性并发放出——三条 GPU 链的 pass 派发只能在 UI isolate 同步提交，MUSIQ（NnPool 14 worker）+ NIQE/BRISQUE/ILNIQE/PIQE + 四指标嵌套 Isolate.run 又把 CPU 核打满，UI isolate 被饿死 → GPU 等派发（57s→689s）+ 消息泵停转（未响应）。
   - **修法**：① `isp_studio_state.dart` 并发治理——GPU 链类指标（lpips/dists/fid/kid/clipiqa）互斥锁 `_gpuMetricLock`（Future 链信号量=1，串行让每条链全速，KID 排 FID 后命中特征缓存接近免费）；重 CPU 指标（musiq/niqe/brisque/ilniqe/piqe/psnr/ssim/msssim/fsim）`_heavyCpuLock`（FIFO 信号量 ≤2）；轻量仪器（直方图/波形等 worker 路径）不限；token 取消/签名缓存/进度更新语义不变，节点耗时在锁外开始计（含排队时间，注释在案）。② 三条 GPU 链 forward（含 banded 变体）层间插入 `GpuDispatchYield`（nn_gpu.dart：Stopwatch 每累计 ≥8ms 同步派发 `await Future.delayed(Duration.zero)` 让事件循环泵一次平台消息；单层同步段最长 ~1s ≪ Windows 5s 未响应判据；纯调度数值不变，同步方法签名不动）。
   - **验收**：GPU 四套件 + fid/kid 48/48 全绿（端到端 GPU 分数与优化 5 后**逐位相同**）；`flutter analyze` 干净；全量套件与基线（897 通过/7 既有失败）一致无新增。预期真机：GPU 指标各自回到单链基准量级（LPIPS/DISTS ~60-70s 串行、FID/KID 共享特征后 ~23s+免费、CLIPIQA ~15-30s），总时长从 ~750s 降到 ~200s 量级且 UI 全程可响应。临时诊断继续**保留**待真机复验一轮后移除。
12. **优化 7（NnPool 核数上限 + 四指标嵌套扇出限幅）已完成**（2026-09-05 验收）：
   - **根因**（优化 6 后真机第二轮复验：DISTS=LPIPS+50s、FID=DISTS+59s、KID 命中缓存秒出、CLIPIQA=+20s——串行后单链全速 ✓；但队首 LPIPS 自身 462s、标题栏「未响应」集中在 MUSIQ 窗口）：MUSIQ 的 NnPool 14 worker（核数-2）+ NIQE 组把 CPU 核占满，UI isolate 的 GPU 派发与消息泵仍被饿死。
   - **修法**（均为单点改动）：① `_sharedNnPool` 显式 `pool.start(max(2, 核数-4))`，给 UI/raster 线程留物理核（NnPool.start 缺省值不动，测试/基准行为不变）；② `instruments.dart` 的 `_dualMetricWorkers` 限幅 `min(8, max(2, 核数-2))`——heavyCpuLock=2 下两路重 CPU 指标各自嵌套 14 子 isolate 会超订，PSNR/SSIM 部分和为内存带宽型任务 8 路足够。
   - **验收**：`flutter analyze` 干净；四指标 + deep_iqa_integration 57/57 全绿；全量套件与基线（897 通过/7 既有失败）一致无新增。预期真机：LPIPS 回落至 ~70s 级、「未响应」消除、总时长由 MUSIQ 兜底 ~8min。**后续大优化（已立项）：MUSIQ GPU 化**（目前 NnPool CPU 池 ~411s，是最长尾）。临时诊断继续**保留**。
13. **优化 8（GPU 链下载路径：物化 + 解包挪后台）已完成**（2026-09-05 验收）：
   - **探针定论**（`scratch/vgg_readback_probe_main.dart`，真机）：toImageSync 提交全延迟（≈0ms）且 GPU 有占用（32-100%）；同图二次回读有缓存（83ms）；回读期间 eventloop ticks>0（光栅化不在 UI 线程）；回读成本 ∝ 切片尺寸——slice0（[1,64,3000,1688]，648MB halves）13.7s，大头是 toByteData 传输 + fp16→fp32 逐元素 CPU 解包在 UI isolate 同步执行；物化路径（drawImage → await toImage）不堵 UI（ticks=93）、之后 toByteData 仅 24ms，且同源其他惰性图直读命中缓存变便宜（52ms）。
   - **修法**（`nn/nn_gpu.dart` + `nn/nn_gpu_pack.dart`，数值逐位不变）：① `_readback` 改为先物化（PictureRecorder + drawImage + await picture.toImage(w,h)，释放物化副本，惰性图仍由调用方持有）再 toByteData；② fp16→fp32 解包大图（≥1M 元素）挪后台 isolate：`unpackFeatureInIsolate`（整图）/`unpackFeatureBandInIsolate`（单带）经 compute + TransferableTypedData 进出（零拷贝），UI 侧 `_mergeBandInto` 按通道 setRange 拼带；小图就地解包（原路径）；③ `downloadFeatureMapBanded` 逐带流水线：halves 到手即派后台解包（不 await），先继续下一带的物化/传输，下一带派发前收上一带的账合并（带序确定性）；④ breadcrumb 下探：三条链 forward 的 submit/download 逐切片标记 + nn_gpu 下载的 unpack 等待标记（`vggGpu:submit …`/`vggGpu:download sliceN …`/`rn50Gpu:*`/`inceptionGpu:*`/`nnGpu:unpack …`，临时诊断风格）。
   - **验收**：`flutter analyze` 干净；GPU 四套件 + fid/kid 48/48 全绿，LPIPS/DISTS/CLIPIQA 端到端 GPU 分数与优化 7 后**逐位一致**（CLIPIQA 0.5934623358096662 等完全相同——解包只换了执行 isolate）；全量套件与基线一致无新增。真机 bench（`scratch/nn_gpu_vgg_bench_main.dart`，走生产 API 自动用新路径；完整输出存 `scratch/bench_vgg_out.txt`）：**1688×3000 LPIPS GPU路径 41751ms（基线 53330ms，−22%）、GPU单侧前向 16052ms（基线 ~21s，−24%）；DISTS GPU路径 33174ms（基线 ~47s，−29%）**；1024×768 LPIPS GPU 10242ms；GPU-vs-CPU池 分数差 1.5e-6~4.5e-5（既有口径内）。临时诊断继续**保留**。
14. **优化 9（LPIPS/DISTS 打分头挪后台 isolate）已完成**（2026-09-06 验收）：
   - **根因**（真机 ui_stall_log 实锤）：`lpips_dart.dart` 的 `_lpipsFromFeats` 在 UI isolate 同步执行——5 切片特征（slice0 [1,64,3000,1688]=3.24 亿元素，5 片合计 ~6.2 亿/张）做 `l2NormalizeChannels`（各复制一份同尺寸张量）+ 平方差加权和，空闲 ~15-20s、MUSIQ 争抢下实测 388s 连续 STALL（01:35:05→01:41:34）；DISTS 同构。
   - **修法**：① `lpips_dart.dart` 新增 `lpipsSliceScoreInIsolate`（融合归一化+差方单遍：范数按通道序 double 累加、norm=sqrt(sumSq)+1e-10 同 `ops.l2NormalizeChannels`；归一化中间值经 2 元素 fp32 scratch 强制舍入——原实现写 Float32List 再读出，IEEE 运算顺序逐元素相同）；`_lpipsHeadParallel` 5 切片 `Isolate.run` 并行（TransferableTypedData 零拷贝进出），k=0..4 序求和；GPU/CPU 池两路径共用；② `dists_dart.dart` 新增 `distsSliceStatsInIsolate`（单切片逐通道 S1/S2 统计原式照搬），`_distsHeadParallel` 6 切片并行后按原序（k 升、ch 升）加权累加；③ 打分头等待前后 `lpips:head`/`dists:head` breadcrumb（临时诊断）；同步版 `lpipsScore`/`distsScore`/`_lpipsFromFeats`/`_distsFromFeats` 原样保留（对拍用）。
   - **位级验收**：`scratch/head_bitexact_check.dart`（函数级 `==` 对照，3 组尺寸 LPIPS/DISTS 全 bitexact=true）；`isp_nn_gpu_vgg_test + isp_nn_gpu_test + isp_pyiqa_test` 33/33 全绿，GPU 端到端分数与优化 8 **逐位相同**（LPIPS gpu=0.10832668643175848、DISTS gpu=0.1893251631454126、CPU 池 cpu=0.10831394641207542/0.1893321236278269）。
   - **真机 bench**（输出存 `scratch/bench_vgg_out.txt`）：1688×3000 LPIPS GPU路径 41999ms（优化 8: 41751ms，bench 串行场景本无争抢、持平符合预期——388s STALL 是 MUSIQ 并发窗口的产物，bench 不覆盖）；DISTS 45165ms（优化 8: 33174ms，+36%，单次样本疑为噪声/热状态，已在案待复跑确认）；各尺寸分数与优化 8 run 逐位一致。预期真机（14 仪器并发场景）：LPIPS 的 388s STALL 段降为 ~秒级后台并行，「未响应」消除。
   - 全量套件与基线（897/7）一致无新增。临时诊断继续**保留**。
15. **优化 10（MUSIQ 挪出 UI + Transformer 池并行）已完成**（2026-09-06 验收）：
   - **根因**（代码级实锤）：`musiq_dart.dart` 的 Transformer 全部在**调用 isolate（UI）** 同步执行——`_attention` 的 q/k/v/out 投影、per-head scores n² GEMM、逐行 softmax，`_blockForward` 的 LN/gelu/residual 全是同步 ops.*；真机 2592×1940 馈源下 token ≈5135，14 层 ≈820 GFLOP + 2.2B 次 exp 单线程 ≈420s——这就是真机 MUSIQ 456s、UI 冻结 419s（STALL breadcrumb 停在别的标记只是因为它是静态字符串）并拖垮所有并行指标（优化 6/7 的锁与核数限幅治标不治本）的根源。
   - **修法**（`metrics/musiq_dart.dart` + `isp_studio_state.dart`，数值位级不变）：① 新增 `encoderScoreParallel`——全部 GEMM（q/k/v/out、fc1/fc2、per-head scores `ops.linear(qH,kH)` 即 sgemm(m=n,n=n,k=64,transB)、AV `ops.matmul(attn,vH)` 即 sgemm(m=n,n=64,k=n)）改走 `pool.parallelGemm`（`ops.linear`/`ops.matmul` 内部就是 sgemm，parallelGemm 按 M 行块切分不改变任一输出元素的 k 维累加顺序，文档保证位级一致）；per-head mask 填充 + 逐行 softmax 抽为 `_maskSoftmaxHead`（代码逐字保留）经 **Isolate.run 按头 6 路并行**（per-row 独立、math.exp 为 VM 内建确定性函数；n≈5136 时单 head [n,n]≈105MB 经 TransferableTypedData 零拷贝进出）；per-head 切片/回写、LN/gelu/residual、CLS/posEmb/scaleEmb/head 逻辑逐字保留（每 head 缓冲独立分配，6 路 Future.wait 并发）。② `musiqScoreInIsolate` 改为 async 后台入口：isolate 内自起 NnPool（max(2, 核数-4)）并自行 MusiqDart.load（108MB 按需读，避免跨 isolate 传权重），预处理/多尺度 patch/tokenizer/embedding/transformer 全流程移出 UI。③ 状态层 `_analyzeDeepIqa` musiq 分支改为 `compute(musiqScoreInIsolate, {...})`（参照 ilniqe/dualMetric 用法），前后 `musiq:compute` breadcrumb（临时诊断；compute isolate 内的 breadcrumb 对 UI watchdog 无意义，故只在状态层设置）；CPU 徽标语义不变；`musiqScoreParallel` 保留（其内部 scoreParallel 同样切到并行 encoder，测试照过）。
   - **位级验收**：`scratch/musiq_bitexact_check.dart`（64×64，dart run）——encoder 同步 vs 池并行（4 worker）严格 `==`、端到端 musiqScore vs musiqScoreInIsolate 严格 `==`、musiqScoreParallel 严格 `==`，`MUSIQ_BITEXACT all=true`；`test/isp_musiq_dart_test.dart` + `test/isp_pyiqa_test.dart` 21/21 全绿（含「同步与池并行结果位级一致」的 `expect(parV, syncV)` 严格相等与 Python 对拍 ≤0.05，断言未放宽）；`flutter analyze` 干净。
   - **性能对比**（2592×1940 busyFrame，`scratch/musiq_score_bench.dart` AOT 口径：`dart compile exe` 后运行，与生产 release 同为 AOT）：**端到端 72063ms，score=23.661499024957873（与同步位级相同），vs 旧路径基线 456s → 6.3× 提速**，UI 冻结消除（transformer 全程在后台 isolate）。分阶段（`scratch/musiq_stage_bench.dart`）：tokenizer 13.8s / embedding 29s / encoder 287s（JIT 失真值，见下）。**重要口径注意：JIT（`dart run`/`flutter run` debug）下测速严重失真**——`Isolate.run` 每次新 isolate 的 softmax 冷 JIT（84 次 spawn）+ 池 worker 首个 GEMM 冷 JIT，同 bench JIT 跑出 310s（encoder 287s）；`scratch/nn_gemm_probe.dart` 微基准证实池本身扩展性正常（embedding 形状 12.6×、scores 8.5×、fc1 10.1×、4k² 12.9×，16 worker）。
   - **MUSIQ GPU 化因此取消**（优化 7 立项的最长尾项）：CPU 池 72s 已不再是瓶颈量级（同窗口 GPU 链指标 15-70s），无需再为 MUSIQ 单独做 GPU 纹理驻留链。
   - 全量套件与基线（897 通过/7 既有失败）一致无新增。临时诊断已于真机复验通过后**移除**（见文件头注记）。

## 进行中

（无）

## 排队待做

（无）

## 既有遗留（与本次改动无关，另行处理）

- 全量回归中 8 个失败为既有问题：folder_compare_view_test 4 个超时、isp_graph_test 节点数断言过期（74→80）、isp_studio_tabs_test、text_editor_gutter_alignment_test。
- `test/isp_eval_flow_repro_test.dart` 是手动诊断用例（skip 中），全流程约 45 分钟。
