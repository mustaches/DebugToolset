#!/usr/bin/env python
# 评价指标参考对比脚本：用 torchmetrics / pyiqa / lpips 计算与 Dart 评价
# 类（instruments.dart / piqe.dart / niqe.dart / brisque.dart / ilniqe.dart）
# 同帧的参考值，供 test/ 下的 Dart 对拍测试引用。
#
# 运行：scratch/eval_venv/Scripts/python.exe scratch/eval_ref.py
# 输出：stdout 报告 + scratch/eval_ref_results.json
#
# 帧图案与 test/isp_piqe_test.dart 的 busyFrame 完全一致（确定性），
# 以便 Dart 侧逐值对拍。

import json
import math
import numpy as np
import torch

W, H = 256, 192


def make_frame(noisy=False):
    """与 Dart busyFrame 精确一致：sin/cos 逐像素 + 0.0..255.0 clamp + 截断取整。"""
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float64)
    r = 128 + 70 * np.sin(xx / 3.1) * np.cos(yy / 2.7) + 40 * np.sin((xx + 2 * yy) / 5.3)
    g = 128 + 70 * np.cos(xx / 4.1) * np.sin(yy / 3.3) + 40 * np.cos((2 * xx - yy) / 6.7)
    b = 128 + 70 * np.sin((xx - yy) / 3.7) * np.cos((xx + yy) / 4.9)
    # Dart clamp(0.0,255.0).toInt() = 截断向零（值恒非负 → 等价 floor）。
    out = np.stack([r, g, b], axis=-1)
    out = np.clip(out, 0.0, 255.0).astype(np.int64)
    if noisy:
        base = ((yy * W + xx) * 3).astype(np.int64)
        # Dart int 取模对非负被除数与 Python 一致。
        out[..., 0] = np.clip(out[..., 0] + (base * 31) % 61 - 30, 0, 255)
        out[..., 1] = np.clip(out[..., 1] + ((base + 1) * 31) % 61 - 30, 0, 255)
        out[..., 2] = np.clip(out[..., 2] + ((base + 2) * 31) % 61 - 30, 0, 255)
    return out.astype(np.uint8)


# --- Dart 口径的复刻（用于精确对拍） ---------------------------------------

def dart_psnr(a, b):
    """psnrRgba：RGB 三通道 MSE，psnr = 10·log10(255²/MSE)。"""
    d = a.astype(np.float64) - b.astype(np.float64)
    mse = np.mean(d * d)
    if mse == 0:
        return 0.0, float("inf")
    return mse, 10 * math.log10(255 * 255 / mse)


def _block_ssim_channel(pa, pb, w, h, blk=8):
    """Dart ssimRgba 单通道：8×8 非重叠块，总体方差，块均值。"""
    c1, c2 = 6.5025, 58.5225
    vals = []
    for by in range(0, h - blk + 1, blk):
        for bx in range(0, w - blk + 1, blk):
            va = pa[by:by + blk, bx:bx + blk].astype(np.float64).ravel()
            vb = pb[by:by + blk, bx:bx + blk].astype(np.float64).ravel()
            n = len(va)
            ma, mb = va.mean(), vb.mean()
            va_v = (va * va).mean() - ma * ma
            vb_v = (vb * vb).mean() - mb * mb
            cov = (va * vb).mean() - ma * mb
            vals.append(((2 * ma * mb + c1) * (2 * cov + c2)) /
                        ((ma * ma + mb * mb + c1) * (va_v + vb_v + c2)))
    return float(np.mean(vals))


def dart_ssim(a, b):
    per = [_block_ssim_channel(a[..., c], b[..., c], W, H) for c in range(3)]
    return sum(per) / 3, *per


def dart_msssim(a, b):
    weights = [0.0448, 0.2856, 0.3001, 0.2363, 0.1333
    ]
    blk = 8

    def block_terms(pa, pb, w, h):
        c1, c2 = 6.5025, 58.5225
        l_sum = cs_sum = 0.0
        cnt = 0
        for by in range(0, h - blk + 1, blk):
            for bx in range(0, w - blk + 1, blk):
                va = pa[by:by + blk, bx:bx + blk].astype(np.float64)
                vb = pb[by:by + blk, bx:bx + blk].astype(np.float64)
                ma, mb = va.mean(), vb.mean()
                va_v = (va * va).mean() - ma * ma
                vb_v = (vb * vb).mean() - mb * mb
                cov = (va * vb).mean() - ma * mb
                l_sum += (2 * ma * mb + c1) / (ma * ma + mb * mb + c1)
                cs_sum += (2 * cov + c2) / (va_v + vb_v + c2)
                cnt += 1
        return (1.0, 1.0) if cnt == 0 else (l_sum / cnt, cs_sum / cnt)

    per = []
    for c in range(3):
        pa = a[..., c].astype(np.float64)
        pb = b[..., c].astype(np.float64)
        cw, ch = W, H
        cs_list = []
        l_last = 1.0
        while cw >= blk and ch >= blk and len(cs_list) < len(weights):
            l, cs = block_terms(pa, pb, cw, ch)
            cs_list.append(min(max(cs, 0.0), 1.0))
            l_last = min(max(l, 0.0), 1.0)
            if len(cs_list) == len(weights):
                break
            w2, h2 = cw // 2, ch // 2
            if w2 < 1 or h2 < 1:
                break
            # Dart 2×2 均值降采样：(p0+p1+p2+p3+2)>>2（uint8 语义）——用 int32 复刻。
            def ds(p):
                q = p.astype(np.int64)
                q = (q[0:2 * h2:2, 0:2 * w2:2] + q[1:2 * h2:2, 0:2 * w2:2] +
                     q[0:2 * h2:2, 1:2 * w2:2] + q[1:2 * h2:2, 1:2 * w2:2] + 2) >> 2
                return q.astype(np.float64)
            # 注：Dart 在 Uint8List 平面上做（先转 uint8 再统计）。
            pa = ds(pa)
            pb = ds(pb)
            cw, ch = w2, h2
        w_sum = sum(weights[:len(cs_list)])
        msssim = 1.0
        for j, cs in enumerate(cs_list):
            msssim *= cs ** (weights[j] / w_sum)
        msssim *= l_last ** (weights[len(cs_list) - 1] / w_sum)
        per.append(msssim)
    return sum(per) / 3, *per


# --- 参考库指标 -------------------------------------------------------------

def torchmetrics_scores(a_rgb, b_rgb):
    from torchmetrics.functional import (
        peak_signal_noise_ratio,
        structural_similarity_index_measure,
        multiscale_structural_similarity_index_measure,
    )
    ta = torch.from_numpy(a_rgb).permute(2, 0, 1).unsqueeze(0).float() / 255.0
    tb = torch.from_numpy(b_rgb).permute(2, 0, 1).unsqueeze(0).float() / 255.0
    out = {
        "psnr_tm": float(peak_signal_noise_ratio(tb, ta, data_range=1.0)),
        "ssim_tm": float(structural_similarity_index_measure(tb, ta, data_range=1.0)),
    }
    try:
        out["msssim_tm"] = float(
            multiscale_structural_similarity_index_measure(tb, ta, data_range=1.0))
    except Exception as e:  # 图像太小放不下 5 尺度高斯窗等
        out["msssim_tm"] = f"error: {e}"
    return out


def pyiqa_scores(a_rgb, b_rgb, device="cpu"):
    """pyiqa 无参考指标（对失真图 a）+ LPIPS（a vs b）。"""
    import pyiqa
    out = {}
    t = torch.from_numpy(a_rgb).permute(2, 0, 1).unsqueeze(0).float() / 255.0
    for name in ("niqe", "ilniqe", "brisque", "piqe"):
        try:
            metric = pyiqa.create_metric(name, device=device)
            out[f"{name}_pyiqa"] = float(metric(t))
        except Exception as e:
            out[f"{name}_pyiqa"] = f"error: {e}"
    return out


def lpips_score(a_rgb, b_rgb, device="cpu"):
    import lpips as lpips_pkg
    loss = lpips_pkg.LPIPS(net="vgg", verbose=False).to(device)
    ta = torch.from_numpy(a_rgb).permute(2, 0, 1).unsqueeze(0).float() / 255.0 * 2 - 1
    tb = torch.from_numpy(b_rgb).permute(2, 0, 1).unsqueeze(0).float() / 255.0 * 2 - 1
    with torch.no_grad():
        d = float(loss(ta, tb))
    return d


def main():
    a = make_frame(noisy=False)   # 纹理图（Dart 侧「参考」）
    b = make_frame(noisy=True)   # 加噪图（Dart 侧「测试图」）
    results = {"W": W, "H": H}

    results["dart_psnr"] = dart_psnr(a, b)[1]
    results["dart_ssim"] = dart_ssim(a, b)[0]
    results["dart_msssim"] = dart_msssim(a, b)[0]

    results.update(torchmetrics_scores(a, b))
    results.update(pyiqa_scores(b, a))  # 无参考指标评失真图 b
    results["lpips_vgg"] = lpips_score(b, a)

    # 报告
    print("=" * 62)
    print(f"帧 {W}x{H}：busyFrame（干净=参考 / 加噪=失真）")
    print("-" * 62)
    print(f"{'PSNR  Dart 口径 (dB)':34s} {results['dart_psnr']:12.6f}")
    print(f"{'PSNR  torchmetrics (dB)':34s} {results['psnr_tm']:12.6f}")
    print(f"{'SSIM  Dart 块口径':34s} {results['dart_ssim']:12.6f}")
    print(f"{'SSIM  torchmetrics(高斯窗)':34s} {results['ssim_tm']:12.6f}")
    print(f"{'MS-SSIM Dart 块口径':34s} {results['dart_msssim']:12.6f}")
    print(f"{'MS-SSIM torchmetrics':34s} {results['msssim_tm']}")
    print(f"{'LPIPS(vgg) 失真vs参考':34s} {results['lpips_vgg']:12.6f}")
    print("-" * 62)
    for k in ("niqe_pyiqa", "ilniqe_pyiqa", "brisque_pyiqa", "piqe_pyiqa"):
        print(f"{k:34s} {results[k]}")
    print("=" * 62)

    with open("scratch/eval_ref_results.json", "w", encoding="utf-8") as f:
        json.dump(results, f, indent=2, ensure_ascii=False)
    print("已写 scratch/eval_ref_results.json")


if __name__ == "__main__":
    main()
