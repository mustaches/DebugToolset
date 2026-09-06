#!/usr/bin/env python
# 将 IspFlow/DemoPhoto 中的 JPG 照片"反向 ISP"还原为 Bayer RGGB RAW：
#   sRGB(8bit) -> sRGB EOTF 还原线性光 -> 按 RGGB 抽取马赛克 -> 10bit 线性
# 输出格式与 IspFlow/BayerRGGB/ 现有文件一致：uint16 小端 unpacked（10bit 存 16bit 低对齐），
# 附同名 .txt 元数据。输出到 IspFlow/DemoPhoto/ 下。
import os
import numpy as np
from PIL import Image

SRC = r"G:\DebugToolSet\IspFlow\DemoPhoto"
BITS = 10
MAXV = (1 << BITS) - 1


def srgb_to_linear(c):
    """标准 sRGB EOTF（分段），输入 0..1 编码值，输出 0..1 线性光。"""
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def convert(path, name):
    im = Image.open(path).convert("RGB")
    w, h = im.size
    if w % 2 or h % 2:
        im = im.crop((0, 0, w - w % 2, h - h % 2))
        w, h = im.size
    rgb = np.asarray(im, dtype=np.float64) / 255.0
    lin = srgb_to_linear(rgb)

    # RGGB 马赛克化
    raw = np.zeros((h, w))
    raw[0::2, 0::2] = lin[0::2, 0::2, 0]  # R
    raw[0::2, 1::2] = lin[0::2, 1::2, 1]  # Gr
    raw[1::2, 0::2] = lin[1::2, 0::2, 1]  # Gb
    raw[1::2, 1::2] = lin[1::2, 1::2, 2]  # B
    raw16 = np.clip(raw * MAXV, 0, MAXV).round().astype("<u2")

    base = os.path.join(SRC, f"RAW_{w}x{h}_{BITS}bits_RGGB_Linear_1frame_{name}")
    with open(base + ".raw", "wb") as f:
        f.write(raw16.tobytes())
    with open(base + ".txt", "w", encoding="ascii") as f:
        f.write(f"[common]\nWidth={w}\nHeight={h}\nBits={BITS}\nBayer=RGGB\n"
                "BlackLevel_R=0\nBlackLevel_Gr=0\nBlackLevel_Gb=0\nBlackLevel_B=0\n")
    print(f"OK {os.path.basename(base)}.raw  {w}x{h}  min={raw16.min()} max={raw16.max()}")


for f in sorted(os.listdir(SRC)):
    name, ext = os.path.splitext(f)
    if ext.lower() in (".jpg", ".jpeg", ".png"):
        convert(os.path.join(SRC, f), name)
