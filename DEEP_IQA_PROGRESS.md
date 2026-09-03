# 深度评价节点去 Python 依赖 —— 进度快照（2026-09-03 夜）

> 本文件是开发进度存档，完成后可删除。配合 git 提交 `feat(isp_studio): 深度评价节点进程内计算` 阅读。

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
5. 测试约定：flutter_tester 是软件光栅，凡走 `_analyzeDeepIqa` 的测试须先 `Vgg16AsyncForward.enabled = false`（已在 isp_deep_iqa_integration_test / isp_eval_flow_repro_test 处理）。

## 进行中（半成品，下次继续）

**优化 1：GPU 链大图分块（解除 ~512×384 上限，目标支持 1688×3000 馈源）**
- 半成品位置：`shaders/nn/nn_stitch3_f16.frag`（分块拼接，未在 pubspec 登记或未接线）、`shaders/nn/nn_conv3x3_f16.frag` 与 `nn_l2pool_dists_f16.frag`（有改动）、`lib/modules/isp_studio/pipeline/nn/nn_gpu.dart`（已扩到 ~38KB）。
- 状态：可编译（flutter analyze 全工程无问题），但**未完成对拍验证**——接手时先跑 `flutter test test/isp_nn_gpu_test.dart test/isp_nn_gpu_vgg_test.dart` 确认现状，不一致就推倒该部分重来。
- 方案空间：空间分块+halo / 多纹理按 index 选 sampler / 按输出通道切多 pass；注意 SkSL 限制（循环界常量、sampler 不能作函数参数、uniform 数量有限）。
- 验收标准：大图 LPIPS/DISTS 走 GPU 且分数与 Python 基线偏差 ≤1e-3；小图路径位级不变。

## 排队待做

- **优化 2**：RN50 GPU 链（CLIPIQA——实跑最长尾，5MP 下 CPU 需 6 分钟以上）。
- **优化 3**：InceptionV3 GPU 链（FID/KID；patch 299² 本在上限内，需补 stride-2/非对称 kernel/pool3×3 的 shader）。
- **优化 4**：FID 2048² 特征值求解并行化（单核长尾 ~30-40s）；PSNR/SSIM/MS-SSIM/FSIM 节点内并行。

## 既有遗留（与本次改动无关，另行处理）

- 全量回归中 8 个失败为既有问题：folder_compare_view_test 4 个超时、isp_graph_test 节点数断言过期（74→80）、isp_studio_tabs_test、text_editor_gutter_alignment_test。
- `test/isp_eval_flow_repro_test.dart` 是手动诊断用例（skip 中），全流程约 45 分钟。
