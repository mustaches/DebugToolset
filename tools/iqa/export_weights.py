#!/usr/bin/env python
# 权重导出工具（一次性开发工具，非运行时依赖）：
# 把 6 个深度 IQA 模型的 torch 权重导出为自定义二进制格式 .nnw，
# 供后续纯 Dart 推理引擎使用。
#
# .nnw 格式：
#   字节 0-7   magic ASCII "DTSNNW01"
#   字节 8-15  uint64 LE = manifest JSON 字节长度
#   随后       manifest UTF-8 JSON：
#              {"format":1,"tensors":{"<name>":{"shape":[...],"dtype":"f32",
#               "offset":<int>,"nbytes":<int>}}}（offset 相对数据区起点）
#   随后       数据区：全部张量 raw fp32 little-endian，row-major（C 序）
#
# 用法（在仓库根目录，用 scratch/eval_venv 解释器）：
#   python tools/iqa/export_weights.py
#   python tools/iqa/export_weights.py --only lpips|dists|fid|musiq|clipiqa|vgg16
#
# 每个导出函数都会：写盘 → 读回校验 → 用导出的权重重建等价前向，
# 与原模型对拍（随机输入或 eval_set 真实图），全部通过脚本才算成功。

import argparse
import copy
import functools
import json
import os
import struct
import sys
import types

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

IQA_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(IQA_DIR, "..", ".."))
WEIGHTS_DIR = os.path.join(IQA_DIR, "weights")
EVAL_DIR = os.path.join(ROOT, "scratch", "eval_set")

TORCH_HUB = os.path.join(os.path.expanduser("~"), ".cache", "torch", "hub")
VGG16_PTH = os.path.join(TORCH_HUB, "checkpoints", "vgg16-397923af.pth")
DISTS_PTH = os.path.join(TORCH_HUB, "pyiqa", "DISTS_weights-f5e65c96.pth")
LPIPS_VGG_PTH = os.path.join(
    ROOT, "scratch", "eval_venv", "Lib", "site-packages",
    "lpips", "weights", "v0.1", "vgg.pth")

MAGIC = b"DTSNNW01"

# 全部验证在 CPU 上进行，保证可复现（GPU/CPU 浮点路径有差异）。
DEVICE = "cpu"


# ---------------------------------------------------------------- .nnw 读写

def write_nnw(path, tensors):
    """tensors: dict[str, torch.Tensor|np.ndarray]，统一写为 fp32 LE。"""
    entries = {}
    blobs = []
    offset = 0
    for name, t in tensors.items():
        if isinstance(t, torch.Tensor):
            a = t.detach().cpu().to(torch.float32).contiguous().numpy()
        else:
            a = np.ascontiguousarray(t, dtype=np.float32)
        b = a.tobytes(order="C")
        entries[name] = {
            "shape": list(a.shape),
            "dtype": "f32",
            "offset": offset,
            "nbytes": len(b),
        }
        blobs.append(b)
        offset += len(b)
    manifest = json.dumps(
        {"format": 1, "tensors": entries}, separators=(",", ":")).encode("utf-8")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(MAGIC)
        f.write(struct.pack("<Q", len(manifest)))
        f.write(manifest)
        for b in blobs:
            f.write(b)
    return entries


def read_nnw(path):
    """读回 .nnw → dict[str, np.ndarray(fp32)]。"""
    with open(path, "rb") as f:
        magic = f.read(8)
        assert magic == MAGIC, f"{path}: bad magic {magic!r}"
        (mlen,) = struct.unpack("<Q", f.read(8))
        manifest = json.loads(f.read(mlen).decode("utf-8"))
        assert manifest["format"] == 1
        data = f.read()
    out = {}
    for name, e in manifest["tensors"].items():
        assert e["dtype"] == "f32"
        a = np.frombuffer(
            data, dtype="<f4", count=int(np.prod(e["shape"])) if e["shape"] else 1,
            offset=e["offset"])
        out[name] = a.reshape(e["shape"]).copy()
    return out


def check_roundtrip(path, tensors, atol=0.0):
    """读回文件并与内存中的张量逐一比对。"""
    rd = read_nnw(path)
    assert set(rd) == set(tensors), f"{path}: 键集合不一致"
    for name, t in tensors.items():
        ref = t.detach().cpu().to(torch.float32).numpy() \
            if isinstance(t, torch.Tensor) else np.asarray(t, np.float32)
        got = rd[name]
        assert list(got.shape) == list(ref.shape), f"{name}: shape {got.shape} != {ref.shape}"
        diff = float(np.abs(got - ref).max()) if ref.size else 0.0
        assert diff <= atol, f"{name}: 回读误差 {diff}"
    print(f"    回读校验通过：{len(rd)} 个张量")


def file_info(path):
    rd = read_nnw(path)
    size = os.path.getsize(path)
    print(f"    {os.path.basename(path)}: {size/1024/1024:.2f} MiB, "
          f"{len(rd)} 个张量")


def fold_bn(conv_w, bn):
    """BN 折叠：w′=w·γ/√(var+eps)，b′=β−mean·γ/√(var+eps)。"""
    scale = bn.weight / torch.sqrt(bn.running_var + bn.eps)
    w = conv_w * scale.view(-1, 1, 1, 1)
    b = bn.bias - bn.running_mean * scale
    return w.detach().clone(), b.detach().clone()


def load_eval_image(name):
    from PIL import Image
    img = Image.open(os.path.join(EVAL_DIR, name)).convert("RGB")
    a = np.asarray(img, dtype=np.float32) / 255.0
    return torch.from_numpy(a).permute(2, 0, 1).unsqueeze(0)


# ---------------------------------------------------------------- vgg16

def _vgg16_state_dict():
    sd = torch.load(VGG16_PTH, map_location="cpu", weights_only=True)
    return sd


def _vgg16_tensors():
    """torchvision vgg16 features[0..29] 中的全部 conv weight+bias。"""
    sd = _vgg16_state_dict()
    tensors = {}
    for i in range(30):
        kw, kb = f"features.{i}.weight", f"features.{i}.bias"
        if kw in sd:
            tensors[kw] = sd[kw]
            tensors[kb] = sd[kb]
    return tensors


def _load_vgg16_tensors():
    """优先读已导出的 vgg16.nnw，否则从缓存权重现取（用于交叉验证）。"""
    path = os.path.join(WEIGHTS_DIR, "vgg16.nnw")
    if os.path.isfile(path):
        rd = read_nnw(path)
        return {k: torch.from_numpy(v) for k, v in rd.items()}
    return _vgg16_tensors()


def _vgg_run(x, tensors, upto=30):
    """用导出的 vgg 权重重建 features[0..upto) 前向（conv+relu / maxpool2）。
    返回各层输出列表（按层索引）。"""
    import torchvision
    feats = torchvision.models.vgg16().features  # 只用其结构（层类型/顺序）
    outs = {}
    h = x
    for i in range(upto):
        m = feats[i]
        if isinstance(m, nn.Conv2d):
            h = F.conv2d(h, tensors[f"features.{i}.weight"],
                         tensors[f"features.{i}.bias"], m.stride, m.padding)
        elif isinstance(m, nn.ReLU):
            h = F.relu(h)
        elif isinstance(m, nn.MaxPool2d):
            h = F.max_pool2d(h, m.kernel_size, m.stride, m.padding)
        else:
            raise AssertionError(f"未知层 {i}: {type(m)}")
        outs[i] = h
    return outs


def export_vgg16():
    print("[vgg16] 导出 torchvision vgg16 features[0..29] conv 权重")
    tensors = _vgg16_tensors()
    path = os.path.join(WEIGHTS_DIR, "vgg16.nnw")
    write_nnw(path, tensors)
    check_roundtrip(path, tensors)

    # 验证：用文件中的权重重建前向，与 torchvision 模型对拍
    import torchvision
    model = torchvision.models.vgg16()
    model.load_state_dict(_vgg16_state_dict())
    model.eval()
    rd = {k: torch.from_numpy(v) for k, v in read_nnw(path).items()}
    torch.manual_seed(0)
    x = torch.rand(1, 3, 64, 64)
    with torch.no_grad():
        ref = x
        for i in range(30):
            ref = model.features[i](ref)
        got = _vgg_run(x, rd, 30)[29]
    diff = float((ref - got).abs().max())
    assert torch.allclose(ref, got, atol=1e-5), f"vgg16 重建误差 {diff}"
    print(f"    重建前向对拍通过：max|diff|={diff:.3e}")
    file_info(path)
    return tensors


# ---------------------------------------------------------------- lpips

def _vgg_slices(x, tensors):
    """LPIPS/DISTS 共用的 vgg 切片输出：relu1_2..relu5_3（层 3/8/15/22/29）。"""
    outs = _vgg_run(x, tensors, 30)
    return [outs[3], outs[8], outs[15], outs[22], outs[29]]


def export_lpips():
    print("[lpips] 导出 lpips v0.1 vgg.pth 的 5 个线性头")
    sd = torch.load(LPIPS_VGG_PTH, map_location="cpu", weights_only=True)
    tensors = {f"lin{i}.model.1.weight": sd[f"lin{i}.model.1.weight"]
               for i in range(5)}
    path = os.path.join(WEIGHTS_DIR, "lpips_vgg01.nnw")
    write_nnw(path, tensors)
    check_roundtrip(path, tensors)

    # 验证：vgg16.nnw + lpips_vgg01.nnw 端到端重建 LPIPS 分数
    import lpips as lpips_pkg
    vgg_t = _load_vgg16_tensors()
    rd = {k: torch.from_numpy(v) for k, v in read_nnw(path).items()}
    net = lpips_pkg.LPIPS(net="vgg", verbose=False).to(DEVICE).eval()
    shift = torch.tensor([-.030, -.088, -.188]).view(1, 3, 1, 1)
    scale = torch.tensor([.458, .448, .450]).view(1, 3, 1, 1)

    def rebuilt_lpips(a, b):
        a = (a * 2 - 1 - shift) / scale
        b = (b * 2 - 1 - shift) / scale
        fa, fb = _vgg_slices(a, vgg_t), _vgg_slices(b, vgg_t)
        val = 0.0
        for i in range(5):
            na = fa[i] / (fa[i].pow(2).sum(1, keepdim=True).sqrt() + 1e-10)
            nb = fb[i] / (fb[i].pow(2).sum(1, keepdim=True).sqrt() + 1e-10)
            d = (na - nb) ** 2
            d = F.conv2d(d, rd[f"lin{i}.model.1.weight"])
            val = val + d.mean([2, 3], keepdim=True)
        return val

    worst = 0.0
    with torch.no_grad():
        for i in range(3):
            a = load_eval_image(f"ref_{i}.png")
            b = load_eval_image(f"test_{i}.png")
            s_ref = float(net(a * 2 - 1, b * 2 - 1))
            s_new = float(rebuilt_lpips(a, b))
            worst = max(worst, abs(s_ref - s_new))
            print(f"    ref_{i}/test_{i}: 原始={s_ref:.6f} 重建={s_new:.6f}")
    assert worst < 1e-4, f"LPIPS 重建误差 {worst}"
    print(f"    端到端对拍通过：max|Δscore|={worst:.3e}")
    file_info(path)


# ---------------------------------------------------------------- dists

def _l2pool(x, channels):
    """DISTS L2pooling：3x3 hanning 核 depthwise 作用在 x² 上，s2/p1。"""
    a = np.hanning(5)[1:-1]
    g = torch.tensor(a[:, None] * a[None, :], dtype=torch.float32)
    g = g / g.sum()
    filt = g[None, None].repeat(channels, 1, 1, 1)
    out = F.conv2d(x ** 2, filt, stride=2, padding=1, groups=x.shape[1])
    return (out + 1e-12).sqrt()


def _dists_feats(x, vgg_t):
    """复刻 DISTS.forward_once：返回 [x, relu1_2, ..., relu5_3]。"""
    mean = torch.tensor([0.485, 0.456, 0.406]).view(1, -1, 1, 1)
    std = torch.tensor([0.229, 0.224, 0.225]).view(1, -1, 1, 1)
    import torchvision
    feats = torchvision.models.vgg16().features

    def run(h, lo, hi):
        for i in range(lo, hi):
            m = feats[i]
            if isinstance(m, nn.Conv2d):
                h = F.conv2d(h, vgg_t[f"features.{i}.weight"],
                             vgg_t[f"features.{i}.bias"], m.stride, m.padding)
            else:
                h = F.relu(h)
        return h

    h = (x - mean) / std
    r1 = run(h, 0, 4)
    r2 = run(_l2pool(r1, 64), 5, 9)
    r3 = run(_l2pool(r2, 128), 10, 16)
    r4 = run(_l2pool(r3, 256), 17, 23)
    r5 = run(_l2pool(r4, 512), 24, 30)
    return [x, r1, r2, r3, r4, r5]


def export_dists():
    print("[dists] 导出 DISTS_weights 的 alpha/beta")
    try:
        sd = torch.load(DISTS_PTH, map_location="cpu", weights_only=True)
    except Exception:
        sd = torch.load(DISTS_PTH, map_location="cpu", weights_only=False)
    tensors = {"alpha": sd["alpha"], "beta": sd["beta"]}
    path = os.path.join(WEIGHTS_DIR, "dists.nnw")
    write_nnw(path, tensors)
    check_roundtrip(path, tensors)

    # 验证：vgg16.nnw + dists.nnw 端到端重建 DISTS 分数
    import pyiqa
    vgg_t = _load_vgg16_tensors()
    rd = {k: torch.from_numpy(v) for k, v in read_nnw(path).items()}
    metric = pyiqa.create_metric("dists", device=DEVICE)
    chns = [3, 64, 128, 256, 512, 512]

    def rebuilt_dists(a, b):
        fa, fb = _dists_feats(a, vgg_t), _dists_feats(b, vgg_t)
        alpha, beta = rd["alpha"], rd["beta"]
        w_sum = alpha.sum() + beta.sum()
        alphas = torch.split(alpha / w_sum, chns, dim=1)
        betas = torch.split(beta / w_sum, chns, dim=1)
        dist1 = dist2 = 0.0
        c1 = c2 = 1e-6
        for k in range(6):
            xm = fa[k].mean([2, 3], keepdim=True)
            ym = fb[k].mean([2, 3], keepdim=True)
            s1 = (2 * xm * ym + c1) / (xm ** 2 + ym ** 2 + c1)
            dist1 = dist1 + (alphas[k] * s1).sum(1, keepdim=True)
            xv = ((fa[k] - xm) ** 2).mean([2, 3], keepdim=True)
            yv = ((fb[k] - ym) ** 2).mean([2, 3], keepdim=True)
            cov = (fa[k] * fb[k]).mean([2, 3], keepdim=True) - xm * ym
            s2 = (2 * cov + c2) / (xv + yv + c2)
            dist2 = dist2 + (betas[k] * s2).sum(1, keepdim=True)
        return 1 - (dist1 + dist2)

    worst = 0.0
    with torch.no_grad():
        for i in range(3):
            a = load_eval_image(f"ref_{i}.png")
            b = load_eval_image(f"test_{i}.png")
            s_ref = float(metric(a, b))
            s_new = float(rebuilt_dists(a, b).squeeze())
            worst = max(worst, abs(s_ref - s_new))
            print(f"    ref_{i}/test_{i}: 原始={s_ref:.6f} 重建={s_new:.6f}")
    assert worst < 1e-4, f"DISTS 重建误差 {worst}"
    print(f"    端到端对拍通过：max|Δscore|={worst:.3e}")
    file_info(path)


# ---------------------------------------------------------------- fid (InceptionV3)

def _fold_inception(incep, tensors=None):
    """把 torchvision inception 的所有 BasicConv2d 的 BN 折叠进 conv。
    tensors 为 None 时用模型自身 BN 折叠；否则从导出文件读折叠后权重。
    返回 {模块名: (w, b)} 映射（torchvision 命名，如 Conv2d_1a_3x3.conv）。"""
    from torchvision.models.inception import BasicConv2d
    folded = {}
    for name, m in incep.named_modules():
        if isinstance(m, BasicConv2d):
            if tensors is None:
                w, b = fold_bn(m.conv.weight, m.bn)
            else:
                w = torch.from_numpy(tensors[f"{name}.conv.weight"]).clone()
                b = torch.from_numpy(tensors[f"{name}.conv.bias"]).clone()
            m.conv.weight.data = w
            if m.conv.bias is None:
                m.conv.bias = nn.Parameter(torch.zeros_like(b))
            m.conv.bias.data = b
            m.bn = nn.Identity()
            folded[name] = (w, b)
    return folded


def _incep_blocks(incep):
    """按 pyiqa InceptionV3 的 block 划分组装前向序列。"""
    block0 = [incep.Conv2d_1a_3x3, incep.Conv2d_2a_3x3, incep.Conv2d_2b_3x3,
              nn.MaxPool2d(kernel_size=3, stride=2)]
    block1 = [incep.Conv2d_3b_1x1, incep.Conv2d_4a_3x3,
              nn.MaxPool2d(kernel_size=3, stride=2)]
    block2 = [incep.Mixed_5b, incep.Mixed_5c, incep.Mixed_5d, incep.Mixed_6a,
              incep.Mixed_6b, incep.Mixed_6c, incep.Mixed_6d, incep.Mixed_6e]
    block3 = [incep.Mixed_7a, incep.Mixed_7b, incep.Mixed_7c,
              nn.AdaptiveAvgPool2d(output_size=(1, 1))]
    return [nn.Sequential(*b) for b in (block0, block1, block2, block3)]


def export_fid():
    print("[fid] 导出 pyiqa InceptionV3（BN 折叠进 conv，eps=1e-3）")
    from pyiqa.archs.inception import InceptionV3, fid_inception_v3

    raw = fid_inception_v3()  # 加载缓存的 pt_inception 权重
    folded = _fold_inception(raw)
    tensors = {}
    for name, (w, b) in folded.items():
        tensors[f"{name}.conv.weight"] = w
        tensors[f"{name}.conv.bias"] = b
    tensors["fc.weight"] = raw.fc.weight  # 对拍用
    tensors["fc.bias"] = raw.fc.bias
    path = os.path.join(WEIGHTS_DIR, "inception_v3_fid.nnw")
    write_nnw(path, tensors)
    check_roundtrip(path, tensors)

    # 验证：从文件读折叠后权重重建等价前向（conv+bias+relu，无 BN），
    # 随机 299×299 输入下 pool3 特征与原 InceptionV3 allclose。
    rd = read_nnw(path)
    rebuilt = fid_inception_v3()
    _fold_inception(rebuilt, rd)
    ref_model = InceptionV3(output_blocks=[3]).to(DEVICE).eval()
    torch.manual_seed(0)
    x = torch.rand(2, 3, 299, 299)
    with torch.no_grad():
        f_ref = ref_model(x, False, False)[0]
        h = x
        for blk in _incep_blocks(rebuilt):
            h = blk(h)
    diff = float((f_ref - h).abs().max())
    assert torch.allclose(f_ref, h, atol=1e-4), f"Inception 重建误差 {diff}"
    print(f"    pool3 特征对拍通过：max|diff|={diff:.3e} (shape {list(h.shape)})")
    file_info(path)


# ---------------------------------------------------------------- musiq

def _baked_stdconv_forward(self, x):
    """烘焙权重后的 StdConv 前向：same 精确 padding + 普通 conv。"""
    from pyiqa.matlab_utils import exact_padding_2d
    x = exact_padding_2d(x, self.kernel_size, self.stride, mode="same")
    return F.conv2d(x, self.weight, self.bias, self.stride)


def _patch_stdconv(net, baked_tensors=None):
    """把 net 中所有 StdConv 替换为普通卷积前向。
    baked_tensors 为 None 时就地烘焙权重；否则用导出文件中的权重。"""
    from pyiqa.archs.musiq_arch import StdConv
    n = 0
    for name, m in net.named_modules():
        if isinstance(m, StdConv):
            if baked_tensors is None:
                w = m.weight.data
                w = w - w.mean((1, 2, 3), keepdim=True)
                w = w / (w.std((1, 2, 3), keepdim=True) + 1e-5)
                m.weight.data = w
            else:
                m.weight.data = torch.from_numpy(
                    baked_tensors[f"{name}.weight"]).clone()
            m.forward = types.MethodType(_baked_stdconv_forward, m)
            n += 1
    return n


def export_musiq():
    print("[musiq] 导出 pyiqa musiq(koniq10k) 全部权重（StdConv 已烘焙）")
    import pyiqa
    metric = pyiqa.create_metric("musiq", device=DEVICE)
    net = metric.net

    baked = copy.deepcopy(net)
    n_conv = _patch_stdconv(baked)
    print(f"    烘焙 StdConv 层数：{n_conv}")
    tensors = dict(baked.state_dict())
    path = os.path.join(WEIGHTS_DIR, "musiq_koniq.nnw")
    write_nnw(path, tensors)
    check_roundtrip(path, tensors)

    # 验证：从文件读烘焙后权重重建前向（普通 conv 替代 StdConv），
    # 真实图像下分数与原模型一致（abs 差 < 1e-3）。
    rd = read_nnw(path)
    rebuilt = copy.deepcopy(net)
    _patch_stdconv(rebuilt, rd)
    rebuilt.load_state_dict({k: torch.from_numpy(v) for k, v in rd.items()})
    rebuilt.eval()
    worst = 0.0
    with torch.no_grad():
        for i in range(3):
            x = load_eval_image(f"test_{i}.png")
            s_ref = float(metric(x))
            s_new = float(rebuilt(x))
            worst = max(worst, abs(s_ref - s_new))
            print(f"    test_{i}: 原始={s_ref:.6f} 重建={s_new:.6f}")
    assert worst < 1e-3, f"MUSIQ 重建误差 {worst}"
    print(f"    分数对拍通过：max|Δscore|={worst:.3e}")
    file_info(path)


# ---------------------------------------------------------------- clipiqa

def _fold_clip_visual(visual, tensors=None):
    """折叠 CLIP RN50 visual 的全部 BN（eps=1e-5，含 downsample 分支）。
    tensors 为 None 时就地折叠；否则从导出文件读折叠后权重。"""
    pairs = [(visual.conv1, visual.bn1, "conv1"),
             (visual.conv2, visual.bn2, "conv2"),
             (visual.conv3, visual.bn3, "conv3")]
    for lname in ["layer1", "layer2", "layer3", "layer4"]:
        layer = getattr(visual, lname)
        for bi, b in enumerate(layer):
            pairs.append((b.conv1, b.bn1, f"{lname}.{bi}.conv1"))
            pairs.append((b.conv2, b.bn2, f"{lname}.{bi}.conv2"))
            pairs.append((b.conv3, b.bn3, f"{lname}.{bi}.conv3"))
            if b.downsample is not None:
                # downsample = Sequential('-1': AvgPool2d, '0': Conv2d, '1': BN)
                pairs.append((b.downsample[1], b.downsample[2],
                              f"{lname}.{bi}.downsample.0"))
    for conv, bn, name in pairs:
        if tensors is None:
            w, b_ = fold_bn(conv.weight, bn)
        else:
            w = torch.from_numpy(tensors[f"visual.{name}.weight"]).clone()
            b_ = torch.from_numpy(tensors[f"visual.{name}.bias"]).clone()
        conv.weight.data = w
        if conv.bias is None:
            conv.bias = nn.Parameter(torch.zeros_like(b_))
        conv.bias.data = b_
    # BN → Identity
    visual.bn1 = visual.bn2 = visual.bn3 = nn.Identity()
    for lname in ["layer1", "layer2", "layer3", "layer4"]:
        for b in getattr(visual, lname):
            b.bn1 = b.bn2 = b.bn3 = nn.Identity()
            if b.downsample is not None:
                b.downsample[2] = nn.Identity()


def export_clipiqa():
    print("[clipiqa] 导出 CLIPIQA RN50 图像编码器（BN 折叠）+ 文本特征")
    import pyiqa
    from pyiqa.archs.constants import OPENAI_CLIP_MEAN, OPENAI_CLIP_STD
    metric = pyiqa.create_metric("clipiqa", device=DEVICE)
    arch = metric.net
    clip_model = arch.clip_model[0]

    folded = copy.deepcopy(clip_model)
    _fold_clip_visual(folded.visual)

    tensors = {}
    for name, m in folded.visual.named_modules():
        if isinstance(m, nn.Conv2d):
            tensors[f"visual.{name}.weight"] = m.weight
            tensors[f"visual.{name}.bias"] = m.bias
    ap = folded.visual.attnpool
    for p in ["k_proj", "q_proj", "v_proj", "c_proj"]:
        tensors[f"visual.attnpool.{p}.weight"] = getattr(ap, p).weight
        tensors[f"visual.attnpool.{p}.bias"] = getattr(ap, p).bias
    tensors["visual.attnpool.positional_embedding"] = ap.positional_embedding
    tensors["logit_scale"] = folded.logit_scale.detach().reshape(1)

    # 预计算 5 对 prompt 的文本特征（L2 归一化，[10,1024]）
    with torch.no_grad():
        tf = clip_model.encode_text(arch.prompt_pairs)
        tf = tf / tf.norm(dim=-1, keepdim=True)
    tensors["text_features"] = tf.float()

    path = os.path.join(WEIGHTS_DIR, "clipiqa_rn50.nnw")
    write_nnw(path, tensors)
    check_roundtrip(path, tensors)

    # 验证 1：从文件重建 encode_image（折叠权重，无 BN），随机 224×224
    rd = read_nnw(path)
    rebuilt = copy.deepcopy(clip_model)
    _fold_clip_visual(rebuilt.visual, rd)
    rap = rebuilt.visual.attnpool
    for p in ["k_proj", "q_proj", "v_proj", "c_proj"]:
        getattr(rap, p).weight.data = torch.from_numpy(
            rd[f"visual.attnpool.{p}.weight"])
        getattr(rap, p).bias.data = torch.from_numpy(
            rd[f"visual.attnpool.{p}.bias"])
    rap.positional_embedding.data = torch.from_numpy(
        rd["visual.attnpool.positional_embedding"])
    rebuilt.logit_scale.data = torch.from_numpy(rd["logit_scale"]).reshape(())

    mean = torch.tensor(OPENAI_CLIP_MEAN).view(1, 3, 1, 1)
    std = torch.tensor(OPENAI_CLIP_STD).view(1, 3, 1, 1)
    torch.manual_seed(0)
    x = torch.rand(1, 3, 224, 224)
    x_pre = (x - mean) / std
    with torch.no_grad():
        f_ref = clip_model.encode_image(x_pre, False)
        f_new = rebuilt.encode_image(x_pre, False)
    diff = float((f_ref - f_new).abs().max())
    assert torch.allclose(f_ref, f_new, atol=1e-4), f"CLIPIQA 图像特征误差 {diff}"
    print(f"    encode_image 对拍通过：max|diff|={diff:.3e}")

    # 验证 2：重建管线算 clipiqa 分数与原 metric 对比
    tf_t = torch.from_numpy(rd["text_features"])
    ls = torch.from_numpy(rd["logit_scale"]).exp()
    worst = 0.0
    with torch.no_grad():
        for i in range(3):
            img = load_eval_image(f"test_{i}.png")
            feat = rebuilt.encode_image((img - mean) / std, False)
            feat = feat / feat.norm(dim=-1, keepdim=True)
            logits = ls * feat @ tf_t.t()
            probs = logits.reshape(1, -1, 2).softmax(dim=-1)
            s_new = float(probs[..., 0].mean())
            s_ref = float(metric(img))
            worst = max(worst, abs(s_ref - s_new))
            print(f"    test_{i}: 原始={s_ref:.6f} 重建={s_new:.6f}")
    assert worst < 1e-4, f"CLIPIQA 分数误差 {worst}"
    print(f"    分数对拍通过：max|Δscore|={worst:.3e}")
    file_info(path)


# ---------------------------------------------------------------- main

EXPORTERS = {
    "vgg16": export_vgg16,
    "lpips": export_lpips,
    "dists": export_dists,
    "fid": export_fid,
    "musiq": export_musiq,
    "clipiqa": export_clipiqa,
}


def main():
    p = argparse.ArgumentParser(description="导出 IQA 模型权重为 .nnw")
    p.add_argument("--only", choices=sorted(EXPORTERS), help="只导出单个模型")
    args = p.parse_args()

    os.makedirs(WEIGHTS_DIR, exist_ok=True)
    torch.manual_seed(0)

    names = [args.only] if args.only else list(EXPORTERS)
    for name in names:
        EXPORTERS[name]()
        print()

    print("全部导出与验证通过。输出目录：", WEIGHTS_DIR)
    total = 0
    for f in sorted(os.listdir(WEIGHTS_DIR)):
        if f.endswith(".nnw"):
            fp = os.path.join(WEIGHTS_DIR, f)
            n = len(read_nnw(fp))
            size = os.path.getsize(fp)
            total += size
            print(f"  {f:24s} {size/1024/1024:8.2f} MiB  {n:4d} tensors")
    print(f"  {'合计':24s} {total/1024/1024:8.2f} MiB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
