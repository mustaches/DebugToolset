#!/usr/bin/env python
# 导出 eval_set 一对图（ref_0/test_0）的 InceptionV3 patch 特征黄金值，
# 供 Dart 进程内实现（lib/.../metrics/inception_dart.dart）对拍
# （一次性开发工具）。
#
# 口径完全复用 iqa_bridge.py 的 _DistMetric.add：s=min(299,h,w)、50%
# 重叠切块（末块贴边）、每 patch 双线性 resize 到 299² →
# (x*255-128)/128 → _InceptionFeature（pyiqa FID 版 InceptionV3
# pool3，2048 维）。
#
# 输出：
#   test/golden/inception_feats_golden.nnw   {"ref_0.feats","test_0.feats"}
#                                            各 [n,2048] fp32
#   test/golden/inception_feats_golden.json  元信息（文件名/尺寸/patch 网格）
#
# 用法（仓库根目录，scratch/eval_venv 解释器）：
#   python tools/iqa/dump_inception_feats.py
#
# 强制 CPU（IQA_DEVICE=cpu）保证可复现（须在 import iqa_bridge 前设置）。

import json
import os
import sys

os.environ["IQA_DEVICE"] = "cpu"

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import torch  # noqa: E402
from export_weights import write_nnw, read_nnw  # noqa: E402
from iqa_bridge import _InceptionFeature, _load_rgb, _patch_positions  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                    "..", ".."))
OUT_DIR = os.path.join(ROOT, "test", "golden")
EVAL_DIR = os.path.join(ROOT, "scratch", "eval_set")

IMAGES = ["ref_0.png", "test_0.png"]


def main():
    feat = _InceptionFeature()
    tensors = {}
    meta = {"images": {}}
    for name in IMAGES:
        a = _load_rgb(os.path.join(EVAL_DIR, name))
        _, _, h, w = a.shape
        s = min(299, h, w)
        xs = _patch_positions(w, s)
        ys = _patch_positions(h, s)
        patches = torch.cat(
            [a[:, :, y:y + s, x:x + s] for y in ys for x in xs], dim=0)
        outs = []
        with torch.no_grad():
            for i in range(0, patches.shape[0], 16):
                outs.append(feat(patches[i:i + 16]))
        f = torch.cat(outs, dim=0).cpu()
        key = name.replace(".png", "") + ".feats"
        tensors[key] = f
        meta["images"][key] = {
            "file": name,
            "width": w,
            "height": h,
            "patch_size": s,
            "patches": int(f.shape[0]),
            "xs": xs,
            "ys": ys,
        }
        print(f"  {name}: {w}x{h}, patch_size={s}, patches={f.shape[0]}")

    os.makedirs(OUT_DIR, exist_ok=True)
    nnw_path = os.path.join(OUT_DIR, "inception_feats_golden.nnw")
    json_path = os.path.join(OUT_DIR, "inception_feats_golden.json")
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
