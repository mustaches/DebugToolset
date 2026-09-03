#!/usr/bin/env python
# 导出 busyFrame（256x192 干净/加噪，图案同 test/isp_pyiqa_test.dart，
# PNG 复用 scratch/eval_a.png / eval_b.png）的 MUSIQ（koniq10k）中间量
# 黄金值，供 Dart 进程内实现（lib/.../metrics/musiq_dart.dart）分层
# 对拍（一次性开发工具）。
#
# 口径完全复用 pyiqa 的 MUSIQ（scratch/eval_venv/Lib/site-packages/
# pyiqa/archs/musiq_arch.py + data/multiscale_trans_util.py）：
#   0..1 → (x-0.5)*2 → get_multiscale_patches（224/384 双线性?? 不，
#   bicubic 缩放 + SAME 零填充切 32x32 patch + HSE/尺度索引 + mask，
#   224/384 尺度一律 pad/cut 到 max_seq_len=49/144，原始尺度不截断）
#   → patch tokenizer（conv_root→GN→relu→ExactPadding2d→maxPool→
#   Bottleneck→NHWC 展平 16384 维）→ embedding Linear(16384→384)。
#
# 输出：
#   test/golden/musiq_golden.nnw   每图：
#       "{key}.patches"  [S,3072]  全部 patch（[C][H][W] 展平，含补零行）
#       "{key}.hse"      [S]       HSE 哈希位置索引（补零行为 0）
#       "{key}.mask"     [S]       输入 mask（补零行为 0）
#       "{key}.tok{i}"   [16384]   tokenizer 输出样本（i 见 json）
#       "{key}.emb"      [S,384]   embedding 输出（全序列）
#   test/golden/musiq_golden.json  元信息（每尺度 rh/rw/patch 数/hse
#                                  样本/mask 和、tok 样本索引、分数）
#
# 用法（仓库根目录，scratch/eval_venv 解释器）：
#   python tools/iqa/dump_musiq_golden.py
#
# 强制 CPU（IQA_DEVICE=cpu）保证可复现（须在 import iqa_bridge 前设置）。

import json
import math
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


def main():
    import pyiqa
    from pyiqa.data.multiscale_trans_util import (
        get_multiscale_patches,
        resize_preserve_aspect_ratio,
        get_hashed_spatial_pos_emb_index,
    )

    metric = pyiqa.create_metric("musiq", device="cpu")
    net = metric.net
    opts = net.data_preprocess_opts
    patch = opts["patch_size"]
    longer = sorted(opts["longer_side_lengths"])

    tensors = {}
    meta = {"images": {}}
    for key, rel in IMAGES.items():
        a = _load_rgb(os.path.join(ROOT, rel))
        _, _, h, w = a.shape
        x = (a - 0.5) * 2

        # 逐尺度元信息（与 get_multiscale_patches 内部一致地重算）。
        scales = []
        for scale_id, side in enumerate(longer):
            resized, rh, rw = resize_preserve_aspect_ratio(x, h, w, side)
            count_h = math.ceil(rh / patch)
            count_w = math.ceil(rw / patch)
            real = count_h * count_w
            seq_len = int(math.ceil(side / patch) ** 2)
            hse = get_hashed_spatial_pos_emb_index(
                opts["hse_grid_size"], count_h, count_w).reshape(-1)
            scales.append({
                "scale_id": scale_id,
                "longer_side": side,
                "rh": rh, "rw": rw,
                "count_h": count_h, "count_w": count_w,
                "real_patches": real,
                "seq_len": seq_len,  # pad/cut 后固定为该值
                "hse_first": [int(v) for v in hse[:8]],
                "hse_last": [int(v) for v in hse[-4:]],
            })
            del resized
        count_h = math.ceil(h / patch)
        count_w = math.ceil(w / patch)
        hse = get_hashed_spatial_pos_emb_index(
            opts["hse_grid_size"], count_h, count_w).reshape(-1)
        scales.append({
            "scale_id": len(longer),
            "longer_side": None,  # 原始分辨率
            "rh": h, "rw": w,
            "count_h": count_h, "count_w": count_w,
            "real_patches": count_h * count_w,
            "seq_len": count_h * count_w,  # 不 pad/cut
            "hse_first": [int(v) for v in hse[:8]],
            "hse_last": [int(v) for v in hse[-4:]],
        })

        with torch.no_grad():
            out = get_multiscale_patches(x, **opts)  # [1,S,3075]
            seq = out[0]
            patches = seq[:, :-3]                     # [S,3072]
            hse_all = seq[:, -3]
            mask_all = seq[:, -1]
            total = seq.shape[0]

            # tokenizer：与 musiq_arch.MUSIQ.forward 逐行一致。
            t = patches.reshape(-1, 3, patch, patch)
            t = net.conv_root(t)
            t = net.gn_root(t)
            t = net.root_pool(t)
            t = net.block1(t)
            t = t.permute(0, 2, 3, 1).reshape(1, total, -1)  # NHWC 展平
            emb = net.embedding(t)                            # [1,S,384]

            score = float(metric(a))

        # tokenizer 16384 维输出样本：各尺度首/末（含补零行）。
        bounds = [0]
        for s in scales:
            bounds.append(bounds[-1] + s["seq_len"])
        tok_idx = sorted(set([
            0, 1,
            bounds[0] + scales[0]["real_patches"] - 1,  # 224 尺度末真实 patch
            bounds[1] - 1,                              # 224 尺度末槽（补零）
            bounds[1],                                  # 384 尺度首
            bounds[2] - 1,                              # 384 尺度末槽（补零）
            bounds[2],                                  # 原始尺度首
            total - 1,                                  # 原始尺度末
        ]))
        for i in tok_idx:
            tensors[f"{key}.tok{i}"] = t[0, i]
        tensors[f"{key}.patches"] = patches
        tensors[f"{key}.hse"] = hse_all
        tensors[f"{key}.mask"] = mask_all
        tensors[f"{key}.emb"] = emb[0]
        meta["images"][key] = {
            "file": rel,
            "width": w, "height": h,
            "total_seq": total,
            "scales": scales,
            "mask_sum": int(mask_all.sum().item()),
            "tok_indices": tok_idx,
            "score": score,
        }
        print(f"  {rel}: {w}x{h}, total_seq={total}, "
              f"real={sum(s['real_patches'] for s in scales)}, score={score}")

    os.makedirs(OUT_DIR, exist_ok=True)
    nnw_path = os.path.join(OUT_DIR, "musiq_golden.nnw")
    json_path = os.path.join(OUT_DIR, "musiq_golden.json")
    write_nnw(nnw_path, tensors)
    with open(json_path, "w", encoding="utf-8") as fp:
        json.dump(meta, fp, ensure_ascii=False, indent=2)

    # 自检：回读并与内存值逐一比对
    rd = read_nnw(nnw_path)
    worst = 0.0
    for name, t in tensors.items():
        got = rd[name]
        ref = t.detach().cpu().to(torch.float32).numpy()
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
