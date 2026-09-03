#!/usr/bin/env python
# IQA 桥接服务：为 DebugToolSet ISP Studio 的深度评价节点
# （LPIPS / DISTS / FID / KID / MUSIQ / CLIPIQA）提供计算后端。
# 这些指标依赖 torch 深度模型，无法在 Dart 侧实现，故通过常驻
# 子进程 + stdin/stdout JSON 行协议调用（见 docs 与
# lib/modules/isp_studio/pipeline/pyiqa_worker.dart）。
#
# 环境：scratch/eval_venv（torch / torchmetrics / lpips / pyiqa）。
# 设备：CUDA 可用时默认用 GPU（torch cu126+，RTX 4090 实测 LPIPS/
# MUSIQ 提速约 13 倍）；IQA_DEVICE=cpu 可强制回退 CPU。
# 权重统一缓存在 ~/.cache/torch/hub/pyiqa/（国内网络经 hf-mirror 与
# ghfast.top 预置，见仓库工作记录）；CLIP RN50 由 clip 包首次加载时
# 从 openaipublic.azureedge.net 下载（~/.cache/clip）。
#
# 用法：
#   一次性：python iqa_bridge.py --metric lpips --a A.png --b B.png
#   常驻：  python iqa_bridge.py --serve
#
# 常驻协议（stdin/stdout 各一行一个 JSON 对象）：
#   -> {"cmd":"load","metric":"lpips"}
#   <- {"ok":true}
#   -> {"cmd":"pair","a":"A.png","b":"B.png"}       # lpips / dists
#   <- {"ok":true,"score":0.123}
#   -> {"cmd":"single","a":"A.png"}                  # musiq / clipiqa
#   <- {"ok":true,"score":63.2}
#   -> {"cmd":"add","side":"ref","a":"A.png"}        # fid / kid 累计样本
#   <- {"ok":true,"n":3}
#   -> {"cmd":"score"}                               # fid / kid 出分
#   <- {"ok":true,"score":12.3,"n_ref":10,"n_test":10}
#   -> {"cmd":"reset"}                               # fid / kid 清空累计
#   <- {"ok":true}
#   -> {"cmd":"quit"}
#   错误统一：{"ok":false,"error":"..."}

import argparse
import json
import os
import sys

import numpy as np
import torch
import torch.nn.functional as F
from PIL import Image

# 设备选择：默认有 CUDA 就用 GPU（IQA_DEVICE=cpu 可强制回退 CPU；
# IQA_DEVICE=cuda 且无可用 CUDA 时也回退 CPU）。
DEVICE = "cuda" if os.environ.get("IQA_DEVICE", "auto") != "cpu" and \
    torch.cuda.is_available() else "cpu"

# 各指标显示方向（Dart 侧 UI 提示用，经 {"cmd":"meta"} 返回）。
META = {
    "lpips": {"cn": "LPIPS 感知差异", "lower_better": True, "kind": "pair"},
    "dists": {"cn": "DISTS 深度结构差异", "lower_better": True, "kind": "pair"},
    "fid": {"cn": "FID 分布距离", "lower_better": True, "kind": "dist"},
    "kid": {"cn": "KID 分布距离", "lower_better": True, "kind": "dist"},
    "musiq": {"cn": "MUSIQ 多尺度质量", "lower_better": False, "kind": "single"},
    "clipiqa": {"cn": "CLIPIQA 感知质量", "lower_better": False, "kind": "single"},
}


def _load_rgb(path):
    """读图像为 [1,3,H,W] float32 0..1 张量。"""
    img = Image.open(path).convert("RGB")
    a = np.asarray(img, dtype=np.float32) / 255.0
    return torch.from_numpy(a).permute(2, 0, 1).unsqueeze(0)


class _LpipsPair:
    def __init__(self):
        import lpips as lpips_pkg
        self.net = lpips_pkg.LPIPS(net="vgg", verbose=False).to(DEVICE)

    def pair(self, a, b):
        with torch.no_grad():
            return float(self.net(a * 2 - 1, b * 2 - 1))


class _PyiqaPair:
    """pyiqa 全参考指标（dists）。"""

    def __init__(self, name):
        import pyiqa
        self.metric = pyiqa.create_metric(name, device=DEVICE)

    def pair(self, a, b):
        with torch.no_grad():
            return float(self.metric(a, b))


class _PyiqaSingle:
    """pyiqa 无参考指标（musiq / clipiqa）。"""

    def __init__(self, name):
        import pyiqa
        self.metric = pyiqa.create_metric(name, device=DEVICE)

    def single(self, a):
        with torch.no_grad():
            return float(self.metric(a))


class _InceptionFeature(torch.nn.Module):
    """FID/KID 特征提取：pyiqa 内置 InceptionV3（mseitzer pytorch-fid
    移植版，权重 pt_inception-2015-12-05-6726825d.pth 已预置缓存）。
    输入约定同 pyiqa fid_arch legacy_pytorch 口径：0..1 → (v*255-128)/128。"""

    def __init__(self):
        super().__init__()
        from pyiqa.archs.inception import InceptionV3
        block = InceptionV3.BLOCK_INDEX_BY_DIM[2048]
        self.incep = InceptionV3(output_blocks=[block]).to(DEVICE)
        self.incep.eval()

    def forward(self, x):
        # 标准 FID 口径：先双线性缩放到 299×299（Inception 输入尺寸），
        # 两侧帧尺寸不同时特征仍可比。
        x = F.interpolate(x, size=(299, 299), mode="bilinear",
                          align_corners=False)
        x = (x * 255 - 128) / 128
        f = self.incep(x.to(DEVICE), False, False)[0]
        return f.squeeze(-1).squeeze(-1)


def _patch_positions(dim, size):
    """一维切块起点：50% 重叠，末块贴边补齐（dim <= size 时单块）。"""
    if dim <= size:
        return [0]
    step = max(1, size // 2)
    pos = list(range(0, dim - size + 1, step))
    if pos[-1] != dim - size:
        pos.append(dim - size)
    return pos


class _DistMetric:
    """分布级指标（FID / KID）：逐次 add 累计特征，score 时出分。

    样本单位是**图像块**而非整帧：每帧按 ≤299×299（Inception 输入
    尺寸）、50% 重叠切块，每块一个样本——静态图片对（每侧仅一帧）
    也能积累足够样本出分（patch-FID 口径）；视频播放时逐帧累计
    等价于逐块累计。FID 需两侧各 ≥2 个样本（协方差才有定义），
    KID 的 subset_size 按样本量自适应（torchmetrics 默认 1000 对
    小样本集不适用）。
    """

    def __init__(self, kind):
        from torchmetrics.image.fid import FrechetInceptionDistance
        from torchmetrics.image.kid import KernelInceptionDistance
        self.kind = kind
        self.feature = _InceptionFeature()
        self._fid_cls = FrechetInceptionDistance
        self._kid_cls = KernelInceptionDistance
        self.reset()

    def reset(self):
        # 特征提取在 DEVICE（GPU）上，torchmetrics 的内部累计状态必须
        # 同步搬到同一设备，否则 update 时报设备不一致。
        if self.kind == "fid":
            self.metric = self._fid_cls(
                feature=self.feature, normalize=False).to(DEVICE)
        else:
            self.metric = self._kid_cls(
                feature=self.feature, normalize=False,
                subsets=50, subset_size=1000).to(DEVICE)
        self.n_ref = 0
        self.n_test = 0

    def add(self, side, a):
        # a: [1,3,H,W] 0..1 → ≤299²、50% 重叠切块，批量提特征。
        _, _, h, w = a.shape
        s = min(299, h, w)
        xs = _patch_positions(w, s)
        ys = _patch_positions(h, s)
        patches = torch.cat(
            [a[:, :, y:y + s, x:x + s] for y in ys for x in xs], dim=0)
        with torch.no_grad():
            # 分批防内存峰值；torchmetrics 自定义 feature 时不做范围校验。
            for i in range(0, patches.shape[0], 16):
                self.metric.update(patches[i:i + 16], real=(side == "ref"))
        n = len(xs) * len(ys)
        if side == "ref":
            self.n_ref += n
        else:
            self.n_test += n
        return self.n_ref if side == "ref" else self.n_test

    def score(self):
        n = min(self.n_ref, self.n_test)
        if n < 2:
            raise ValueError(
                f"样本不足：ref={self.n_ref}, test={self.n_test}，"
                f"FID/KID 需要两侧各 ≥2 个样本（图像按 299² 块计，"
                f"建议 ≥10 个）")
        if self.kind == "kid":
            # 小样本集：subset_size 不能超过任一侧样本数。
            size = min(1000, n)
            self.metric.subset_size = size
            self.metric.subsets = 50 if size >= 50 else 10
        with torch.no_grad():
            v = self.metric.compute()
            # torchmetrics KID 的 compute() 返回 (mean, std) 元组。
            return float(v[0] if isinstance(v, tuple) else v)


_LOADERS = {
    "lpips": _LpipsPair,
    "dists": lambda: _PyiqaPair("dists"),
    "musiq": lambda: _PyiqaSingle("musiq"),
    "clipiqa": lambda: _PyiqaSingle("clipiqa"),
    "fid": lambda: _DistMetric("fid"),
    "kid": lambda: _DistMetric("kid"),
}


class Bridge:
    def __init__(self):
        self.metric_name = None
        self.impl = None

    def handle(self, req):
        cmd = req.get("cmd")
        if cmd == "quit":
            return {"ok": True, "quit": True}
        if cmd == "meta":
            return {"ok": True, "meta": META}
        if cmd == "load":
            name = req["metric"]
            if name not in _LOADERS:
                raise ValueError(f"未知指标: {name}")
            if self.metric_name is not None and self.metric_name != name:
                raise ValueError(
                    f"本进程已加载 {self.metric_name}，一进程一指标，"
                    f"请另起进程加载 {name}")
            if self.impl is None:
                self.impl = _LOADERS[name]()
                self.metric_name = name
            return {"ok": True}
        if self.impl is None:
            raise ValueError("请先 load 指标")
        kind = META[self.metric_name]["kind"]
        if cmd == "pair" and kind == "pair":
            a = _load_rgb(req["a"]).to(DEVICE)
            b = _load_rgb(req["b"]).to(DEVICE)
            return {"ok": True, "score": self.impl.pair(a, b)}
        if cmd == "single" and kind == "single":
            a = _load_rgb(req["a"]).to(DEVICE)
            return {"ok": True, "score": self.impl.single(a)}
        if cmd == "add" and kind == "dist":
            a = _load_rgb(req["a"]).to(DEVICE)
            n = self.impl.add(req["side"], a)
            return {"ok": True, "n": n}
        if cmd == "score" and kind == "dist":
            return {"ok": True, "score": self.impl.score(),
                    "n_ref": self.impl.n_ref, "n_test": self.impl.n_test}
        if cmd == "reset" and kind == "dist":
            self.impl.reset()
            return {"ok": True}
        raise ValueError(f"指标 {self.metric_name}({kind}) 不支持命令 {cmd}")


def _print(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=True) + "\n")
    sys.stdout.flush()


def serve():
    # 协议只走真实 stdout：pyiqa/torch 加载时的 print（如
    # "Loading pretrained model ..."）全部改道 stderr，避免污染协议。
    global _print
    proto_out = sys.stdout
    sys.stdout = sys.stderr

    def _proto_print(obj):
        proto_out.write(json.dumps(obj, ensure_ascii=True) + "\n")
        proto_out.flush()

    _print = _proto_print

    bridge = Bridge()
    _print({"ok": True, "ready": True, "device": DEVICE})
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
            resp = bridge.handle(req)
        except Exception as e:  # 单个请求失败不退出进程
            resp = {"ok": False, "error": f"{type(e).__name__}: {e}"}
        _print(resp)
        if resp.get("quit"):
            break


def oneshot(args):
    bridge = Bridge()
    bridge.handle({"cmd": "load", "metric": args.metric})
    kind = META[args.metric]["kind"]
    if kind == "pair":
        resp = bridge.handle({"cmd": "pair", "a": args.a, "b": args.b})
    elif kind == "single":
        resp = bridge.handle({"cmd": "single", "a": args.a})
    else:
        resp = {"ok": False, "error": "分布级指标请用 --serve 模式逐帧 add"}
    _print(resp)
    return 0 if resp.get("ok") else 1


def main():
    p = argparse.ArgumentParser(description="DebugToolSet IQA 桥接服务")
    p.add_argument("--serve", action="store_true", help="常驻 stdin/stdout 服务模式")
    p.add_argument("--metric", choices=sorted(META), help="一次性模式指标名")
    p.add_argument("--a", help="图像 A（pair 模式的参考图）")
    p.add_argument("--b", help="图像 B（pair 模式的测试图）")
    args = p.parse_args()
    if args.serve:
        serve()
        return 0
    if args.metric:
        return oneshot(args)
    p.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
