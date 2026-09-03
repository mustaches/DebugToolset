#!/usr/bin/env python
# 导出 busyFrame（256x192 干净/加噪，图案同 test/isp_pyiqa_test.dart，
# PNG 复用 scratch/eval_a.png / eval_b.png）的 CLIP RN50 图像特征黄金值，
# 供 Dart 进程内实现（lib/.../metrics/clip_rn50_dart.dart、
# clipiqa_dart.dart）对拍（一次性开发工具）。
#
# 口径完全复用 pyiqa 的 CLIPIQA（model_type='clipiqa'，
# pos_embedding=False）：0..1 → (x-mean)/std（OPENAI_CLIP_MEAN/STD）
# → clip_model.visual（ModifiedResNet + AttentionPool2d，不加位置
# 嵌入）→ [1024] 图像特征（未 L2 归一化）。另附 metric 端到端分数
# 供参考。
#
# 输出：
#   test/golden/clipiqa_feats_golden.nnw   {"clean.feats","noisy.feats"}
#                                         各 [1,1024] fp32
#   test/golden/clipiqa_feats_golden.json  元信息（文件名/尺寸/分数）
#
# 用法（仓库根目录，scratch/eval_venv 解释器）：
#   python tools/iqa/dump_clipiqa_feats.py
#
# 强制 CPU（IQA_DEVICE=cpu）保证可复现（须在 import iqa_bridge 前设置）。

import json
import os
import sys

os.environ["IQA_DEVICE"] = "cpu"

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import torch  # noqa: E402
from export_weights import write_nnw, read_nnw  # noqa: E402
from iqa_bridge import _load_rgb  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                    "..", ".."))
OUT_DIR = os.path.join(ROOT, "test", "golden")

# scratch/eval_a.png / eval_b.png 即 256x192 busyFrame 干净/加噪图
# （像素与 Dart busyFrame 逐字节一致，已核验）。
IMAGES = {"clean": "scratch/eval_a.png", "noisy": "scratch/eval_b.png"}

MEAN = (0.48145466, 0.4578275, 0.40821073)
STD = (0.26862954, 0.26130258, 0.27577711)


def main():
    import pyiqa
    metric = pyiqa.create_metric("clipiqa", device="cpu")
    clip_model = metric.net.clip_model[0]
    mean = torch.tensor(MEAN).view(1, 3, 1, 1)
    std = torch.tensor(STD).view(1, 3, 1, 1)

    tensors = {}
    meta = {"images": {}}
    for key, rel in IMAGES.items():
        a = _load_rgb(os.path.join(ROOT, rel))
        _, _, h, w = a.shape
        x = (a - mean) / std
        with torch.no_grad():
            feat = clip_model.visual(x, pos_embedding=False).cpu()
            score = float(metric(a))
        tensors[f"{key}.feats"] = feat
        meta["images"][f"{key}.feats"] = {
            "file": rel,
            "width": w,
            "height": h,
            "feature_dim": int(feat.shape[-1]),
            "score": score,
        }
        print(f"  {rel}: {w}x{h}, feat {list(feat.shape)}, score={score}")

    os.makedirs(OUT_DIR, exist_ok=True)
    nnw_path = os.path.join(OUT_DIR, "clipiqa_feats_golden.nnw")
    json_path = os.path.join(OUT_DIR, "clipiqa_feats_golden.json")
    write_nnw(nnw_path, tensors)
    with open(json_path, "w", encoding="utf-8") as fp:
        json.dump(meta, fp, ensure_ascii=False, indent=2)

    # 自检：回读并与内存值逐一比对
    rd = read_nnw(nnw_path)
    worst = 0.0
    for name, t in tensors.items():
        got = rd[name]
        ref = t.numpy()
        assert list(got.shape) == list(ref.shape), name
        worst = max(worst, float(abs(got - ref).max()))
    assert worst == 0.0
    print(f"写出 {nnw_path}：{os.path.getsize(nnw_path)} 字节，"
          f"{len(rd)} 个张量")
    print(f"写出 {json_path}")
    print(f"回读校验通过：max|diff|={worst}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
