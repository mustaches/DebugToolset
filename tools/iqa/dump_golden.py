#!/usr/bin/env python
# 生成 op 级黄金值，供 Dart 纯推理引擎对拍（一次性开发工具）。
#
# 输出：
#   test/golden/nn_ops_golden.nnw   所有输入/权重/输出张量（.nnw 格式，
#                                   与 export_weights.py 相同）
#   test/golden/nn_ops_golden.json  case 描述：
#     {"name","op","attrs":{...},
#      "inputs":{"x":"tensor名","weight":"...","bias":"..."},
#      "output":"tensor名"}
#
# 固定种子 torch.manual_seed(0)，小张量，输入值域 [-2,2] 均匀随机。
#
# 用法（仓库根目录，scratch/eval_venv 解释器）：
#   python tools/iqa/dump_golden.py

import json
import os
import sys

import numpy as np
import torch
import torch.nn.functional as F

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from export_weights import write_nnw, read_nnw  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                    "..", ".."))
OUT_DIR = os.path.join(ROOT, "test", "golden")

TENSORS = {}
CASES = []


def rand(*shape):
    """[-2, 2] 均匀随机。"""
    return torch.rand(*shape) * 4 - 2


def add_case(name, op, attrs, inputs, out):
    for key, t in inputs.items():
        TENSORS[f"{name}.{key}"] = t
    TENSORS[f"{name}.out"] = out
    CASES.append({
        "name": name,
        "op": op,
        "attrs": attrs,
        "inputs": {k: f"{name}.{k}" for k in inputs},
        "output": f"{name}.out",
    })


def main():
    torch.manual_seed(0)

    # ---------------- conv2d ----------------
    # 3x3/s1/p1 带 bias（cin=5, cout=7）
    x, w, b = rand(2, 5, 10, 11), rand(7, 5, 3, 3), rand(7)
    add_case("conv2d_3x3_s1_p1", "conv2d",
             {"kernel_size": [3, 3], "stride": [1, 1], "padding": [1, 1],
              "groups": 1},
             {"x": x, "weight": w, "bias": b},
             F.conv2d(x, w, b, 1, 1))

    # 1x1（cin=8, cout=6）
    x, w, b = rand(2, 8, 10, 11), rand(6, 8, 1, 1), rand(6)
    add_case("conv2d_1x1", "conv2d",
             {"kernel_size": [1, 1], "stride": [1, 1], "padding": [0, 0],
              "groups": 1},
             {"x": x, "weight": w, "bias": b},
             F.conv2d(x, w, b, 1, 0))

    # 3x3/s2/p0
    x, w, b = rand(2, 5, 10, 11), rand(7, 5, 3, 3), rand(7)
    add_case("conv2d_3x3_s2_p0", "conv2d",
             {"kernel_size": [3, 3], "stride": [2, 2], "padding": [0, 0],
              "groups": 1},
             {"x": x, "weight": w, "bias": b},
             F.conv2d(x, w, b, 2, 0))

    # 1x7 非对称，p(0,3)
    x, w, b = rand(2, 5, 10, 11), rand(7, 5, 1, 7), rand(7)
    add_case("conv2d_1x7_p0_3", "conv2d",
             {"kernel_size": [1, 7], "stride": [1, 1], "padding": [0, 3],
              "groups": 1},
             {"x": x, "weight": w, "bias": b},
             F.conv2d(x, w, b, 1, (0, 3)))

    # 7x1 非对称，p(3,0)
    x, w, b = rand(2, 5, 10, 11), rand(7, 5, 7, 1), rand(7)
    add_case("conv2d_7x1_p3_0", "conv2d",
             {"kernel_size": [7, 1], "stride": [1, 1], "padding": [3, 0],
              "groups": 1},
             {"x": x, "weight": w, "bias": b},
             F.conv2d(x, w, b, 1, (3, 0)))

    # depthwise 3x3/s2/p1（groups=cin=4）
    x, w, b = rand(2, 4, 10, 11), rand(4, 1, 3, 3), rand(4)
    add_case("conv2d_dw_3x3_s2_p1", "conv2d",
             {"kernel_size": [3, 3], "stride": [2, 2], "padding": [1, 1],
              "groups": 4},
             {"x": x, "weight": w, "bias": b},
             F.conv2d(x, w, b, 2, 1, groups=4))

    # ---------------- maxpool2d ----------------
    x = rand(2, 5, 10, 11)
    add_case("maxpool2d_k2_s2", "maxpool2d",
             {"kernel_size": [2, 2], "stride": [2, 2], "padding": [0, 0]},
             {"x": x}, F.max_pool2d(x, 2, 2, 0))

    x = rand(2, 5, 10, 11)
    add_case("maxpool2d_k3_s2_p0", "maxpool2d",
             {"kernel_size": [3, 3], "stride": [2, 2], "padding": [0, 0]},
             {"x": x}, F.max_pool2d(x, 3, 2, 0))

    x = rand(2, 5, 10, 11)
    add_case("maxpool2d_k3_s1_p1", "maxpool2d",
             {"kernel_size": [3, 3], "stride": [1, 1], "padding": [1, 1]},
             {"x": x}, F.max_pool2d(x, 3, 1, 1))

    # ---------------- avgpool2d ----------------
    x = rand(2, 5, 10, 11)
    add_case("avgpool2d_k3_s1_p1_cip1", "avgpool2d",
             {"kernel_size": [3, 3], "stride": [1, 1], "padding": [1, 1],
              "count_include_pad": True},
             {"x": x}, F.avg_pool2d(x, 3, 1, 1, count_include_pad=True))

    x = rand(2, 5, 10, 11)
    add_case("avgpool2d_k3_s1_p1_cip0", "avgpool2d",
             {"kernel_size": [3, 3], "stride": [1, 1], "padding": [1, 1],
              "count_include_pad": False},
             {"x": x}, F.avg_pool2d(x, 3, 1, 1, count_include_pad=False))

    x = rand(2, 5, 10, 11)
    add_case("avgpool2d_k2_s2", "avgpool2d",
             {"kernel_size": [2, 2], "stride": [2, 2], "padding": [0, 0],
              "count_include_pad": True},
             {"x": x}, F.avg_pool2d(x, 2, 2, 0))

    # ---------------- adaptive_avgpool 1x1 ----------------
    x = rand(2, 5, 10, 11)
    add_case("adaptive_avgpool_1x1", "adaptive_avgpool2d",
             {"output_size": [1, 1]},
             {"x": x}, F.adaptive_avg_pool2d(x, (1, 1)))

    # ---------------- resize ----------------
    x = rand(1, 3, 12, 9)
    add_case("resize_bilinear_12x9_7x5", "resize_bilinear",
             {"size": [7, 5], "align_corners": False},
             {"x": x},
             F.interpolate(x, size=(7, 5), mode="bilinear",
                           align_corners=False))

    x = rand(1, 3, 12, 9)
    add_case("resize_bicubic_12x9_7x5", "resize_bicubic",
             {"size": [7, 5], "align_corners": False},
             {"x": x},
             F.interpolate(x, size=(7, 5), mode="bicubic",
                           align_corners=False))

    # ---------------- 归一化层 ----------------
    x, w, b = rand(2, 10, 24), rand(24), rand(24)
    add_case("layernorm", "layernorm",
             {"normalized_shape": [24], "eps": 1e-6},
             {"x": x, "weight": w, "bias": b},
             F.layer_norm(x, (24,), w, b, eps=1e-6))

    x, w, b = rand(2, 8, 10, 11), rand(8), rand(8)
    add_case("groupnorm_g4", "groupnorm",
             {"num_groups": 4, "eps": 1e-6},
             {"x": x, "weight": w, "bias": b},
             F.group_norm(x, 4, w, b, eps=1e-6))

    # ---------------- 激活 / 其他 ----------------
    x = rand(2, 3, 4, 5)
    add_case("gelu_erf", "gelu", {"approximate": "none"},
             {"x": x}, F.gelu(x))  # 精确 erf 版

    x = rand(2, 3, 4, 5)
    add_case("softmax_last", "softmax", {"dim": -1},
             {"x": x}, F.softmax(x, dim=-1))

    x, w, b = rand(2, 10), rand(6, 10), rand(6)
    add_case("linear", "linear", {"in_features": 10, "out_features": 6},
             {"x": x, "weight": w, "bias": b}, F.linear(x, w, b))

    # 沿 C 维 L2 归一化（LPIPS normalize_tensor 口径，eps=1e-10）
    x = rand(2, 5, 10, 11)
    add_case("l2_normalize_channels", "l2_normalize_channels",
             {"dim": 1, "eps": 1e-10},
             {"x": x},
             x / (x.pow(2).sum(1, keepdim=True).sqrt() + 1e-10))

    # DISTS L2pooling：depthwise 3x3 hanning 核作用在 x² 上，s2/p1，
    # 输出 sqrt(out+1e-12)
    x = rand(1, 3, 12, 12)
    kern = torch.tensor([[0.0625, 0.125, 0.0625],
                         [0.125, 0.25, 0.125],
                         [0.0625, 0.125, 0.0625]], dtype=torch.float32)
    filt = kern[None, None].repeat(3, 1, 1, 1)
    out = F.conv2d(x ** 2, filt, stride=2, padding=1, groups=3)
    add_case("l2pooling_dists", "l2pooling_dists",
             {"kernel_size": [3, 3], "stride": [2, 2], "padding": [1, 1],
              "sqrt_eps": 1e-12},
             {"x": x, "weight": filt},
             (out + 1e-12).sqrt())

    # ---------------- 写盘 ----------------
    os.makedirs(OUT_DIR, exist_ok=True)
    nnw_path = os.path.join(OUT_DIR, "nn_ops_golden.nnw")
    json_path = os.path.join(OUT_DIR, "nn_ops_golden.json")
    write_nnw(nnw_path, TENSORS)
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump({"seed": 0, "nnw": "nn_ops_golden.nnw", "cases": CASES},
                  f, ensure_ascii=False, indent=2)

    # 自检：回读并与内存值逐一比对
    rd = read_nnw(nnw_path)
    worst = 0.0
    for name, t in TENSORS.items():
        got = rd[name]
        ref = t.numpy()
        assert list(got.shape) == list(ref.shape), name
        worst = max(worst, float(abs(got - ref).max()))
    assert worst == 0.0
    print(f"写出 {nnw_path}：{os.path.getsize(nnw_path)} 字节，"
          f"{len(rd)} 个张量")
    print(f"写出 {json_path}：{len(CASES)} 个 case")
    print(f"回读校验通过：max|diff|={worst}")

    dump_eig_golden()
    return 0


def dump_eig_golden():
    """一般实矩阵特征值求解器（lib/.../nn/eig.dart，Hessenberg + Francis
    双移位 QR）的黄金值：numpy.linalg.eigvals。

    独立文件 eig_golden.json（纯 JSON、fp64 十进制全精度，不经 .nnw
    的 fp32 量化），不影响 nn_ops_golden 的既有 22 个 case。用 numpy
    独立 RandomState，不占用 torch 随机流（既有 case 值不变）。
    """
    rng = np.random.RandomState(20240607)
    cases = []

    def add(name, a):
        a = np.asarray(a, dtype=np.float64)
        ev = np.linalg.eigvals(a)
        cases.append({
            "name": name,
            "n": int(a.shape[0]),
            "x": a.tolist(),
            "eig_re": [float(v.real) for v in ev],
            "eig_im": [float(v.imag) for v in ev],
        })

    a = rng.uniform(-2, 2, size=(4, 4))
    add("eig_sym_4x4", a + a.T)  # 对称（全实特征值）
    add("eig_nonsym_4x4", rng.uniform(-2, 2, size=(4, 4)))
    add("eig_nonsym_8x8", rng.uniform(-2, 2, size=(8, 8)))
    add("eig_nonsym_16x16", rng.uniform(-2, 2, size=(16, 16)))
    # FID 口径：两个半正定协方差之积（秩亏，特征值实非负 + 大量零值）
    x1 = rng.uniform(-1, 1, size=(8, 16))
    s1 = x1.T @ x1 / 7 + 0.1 * np.eye(16)
    x2 = rng.uniform(-1, 1, size=(8, 16))
    s2 = x2.T @ x2 / 7 + 0.1 * np.eye(16)
    add("eig_psd_prod_16x16", s1 @ s2)

    path = os.path.join(OUT_DIR, "eig_golden.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump({"cases": cases}, f, ensure_ascii=False)
    # 自检：回读并与内存值逐一比对（JSON 十进制应全精度往返）
    with open(path, "r", encoding="utf-8") as f:
        back = json.load(f)
    worst = 0.0
    for c0, c1 in zip(cases, back["cases"]):
        worst = max(worst,
                    float(np.abs(np.array(c0["x"]) -
                                 np.array(c1["x"])).max()),
                    float(np.abs(np.array(c0["eig_re"]) -
                                 np.array(c1["eig_re"])).max()))
    assert worst == 0.0
    print(f"写出 {path}：{len(cases)} 个 case，回读校验通过")


if __name__ == "__main__":
    sys.exit(main())
