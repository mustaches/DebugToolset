#!/usr/bin/env python
# 生成 1920x1080 10bit RGGB 风景 RAW（日落山水），供 ISP Studio CIS RAW 源测试。
# 输出与 IspFlow/BayerRGGB/ 现有文件同格式：uint16 小端、 unpacked（10bit 存 16bit），
# 附同名 .txt 元数据。另存 preview.png（简易双线性去马赛克预览）用于人工检查。
import numpy as np
from PIL import Image

W, H = 1920, 1080
BITS = 10
MAXV = (1 << BITS) - 1
OUT = r"G:\DebugToolSet\IspFlow\BayerRGGB\RAW_1920x1080_10bits_RGGB_Linear_1frame_landscape"

rng = np.random.default_rng(20260821)


def fbm1d(n, octaves=5, rough=0.55, seed=0):
    """1D 分形噪声（山脊线用），输出 0..1。"""
    r = np.random.default_rng(seed)
    out = np.zeros(n)
    amp, freq = 1.0, 4
    total = 0.0
    for _ in range(octaves):
        xs = np.linspace(0, 1, freq + 1)
        ys = r.random(freq + 1)
        out += amp * np.interp(np.arange(n) / n, xs, ys)
        total += amp
        amp *= rough
        freq *= 2
    return out / total


def fbm2d(h, w, octaves=4, seed=1):
    """2D 分形噪声（云/草地纹理），输出 0..1。"""
    r = np.random.default_rng(seed)
    out = np.zeros((h, w))
    amp, freq = 1.0, 4
    total = 0.0
    for _ in range(octaves):
        small = r.random((freq, freq))
        img = np.array(Image.fromarray((small * 255).astype(np.uint8)).resize((w, h), Image.BILINEAR)) / 255.0
        out += amp * img
        total += amp
        amp *= 0.5
        freq *= 2
    return out / total


yy, xx = np.mgrid[0:H, 0:W].astype(np.float64)
u = xx / W  # 0..1 水平
v = yy / H  # 0..1 垂直

horizon = 0.62  # 地平线（远山底部）

# ---- 天空：日落渐变（顶深蓝 → 中紫 → 地平线暖橙）----
sky = np.zeros((H, W, 3))
t = np.clip(v / horizon, 0, 1)[..., None]  # 0 顶 1 地平线
top = np.array([0.10, 0.16, 0.38])
mid = np.array([0.45, 0.25, 0.45])
low = np.array([0.98, 0.55, 0.25])
c1 = top + (mid - top) * np.clip(t * 2, 0, 1)
c2 = mid + (low - mid) * np.clip(t * 2 - 1, 0, 1)
sky[:] = np.where(t < 0.5, c1, c2)

# ---- 太阳：亮盘 + 径向辉光 ----
sun_x, sun_y, sun_r = 0.66, 0.52, 0.045
d = np.sqrt(((u - sun_x) * W / H) ** 2 + (v - sun_y) ** 2)  # 近似圆形
disc = np.clip(1 - d / sun_r, 0, 1) ** 0.6
glow = np.exp(-((d / (sun_r * 3.2)) ** 2)) * 0.8
sun_col = np.array([1.0, 0.85, 0.55])
sky += disc[..., None] * sun_col * 1.2 + glow[..., None] * sun_col * 0.6

# ---- 云：分形噪声调制的横向条带，被夕阳染色 ----
cloud = fbm2d(H // 4, W // 4, octaves=4, seed=7)
cloud = np.array(Image.fromarray((cloud * 255).astype(np.uint8)).resize((W, H), Image.BILINEAR)) / 255.0
band = np.clip(1 - np.abs(v - 0.30) / 0.28, 0, 1)
cmask = np.clip((cloud - 0.52) * 4, 0, 1) * band
cmask = cmask ** 1.5 * 0.55
cloud_col = np.array([1.0, 0.62, 0.45])  # 暖色云
sky = sky * (1 - cmask[..., None]) + (cloud_col * (0.6 + 0.4 * cloud[..., None])) * cmask[..., None]

# ---- 三层远山：分形山脊线 + 大气透视（越远越亮越蓝）----
scene = sky.copy()
ridge_specs = [  # (基准高度, 起伏幅度, 颜色, seed)
    (0.60, 0.10, np.array([0.42, 0.38, 0.52]), 11),  # 最远
    (0.66, 0.12, np.array([0.28, 0.26, 0.38]), 22),
    (0.73, 0.13, np.array([0.16, 0.15, 0.22]), 33),  # 最近最暗
]
for base, amp, col, seed in ridge_specs:
    ridge = base - fbm1d(W, octaves=5, seed=seed) * amp
    m = v > ridge[None, :]
    # 山脊边缘 1px 过渡带，避免硬边
    edge = np.clip((v - ridge[None, :]) * H / 2, 0, 1)
    scene = scene * (1 - edge[..., None]) + col * edge[..., None]

# ---- 近景草地：深绿 + 噪声纹理 + 轻微起伏 ----
grass_base = np.array([0.10, 0.20, 0.08])
grass_hi = np.array([0.22, 0.34, 0.12])
gtex = fbm2d(H // 2, W // 2, octaves=5, seed=5)
gtex = np.array(Image.fromarray((gtex * 255).astype(np.uint8)).resize((W, H), Image.BILINEAR)) / 255.0
grass = grass_base + (grass_hi - grass_base) * gtex[..., None]
gm = np.clip((v - 0.73) * H / 3, 0, 1)  # 草地与山脚过渡带
scene = scene * (1 - gm[..., None]) + grass * gm[..., None]

# ---- 全局：轻晕影 + 传感器噪声 ----
vig = 1 - 0.25 * ((u - 0.5) ** 2 + (v - 0.5) ** 2) * 2
scene = np.clip(scene * vig[..., None], 0, 1.2)
scene = np.clip(scene, 0, 1.0)

# ---- 马赛克化为 RGGB Bayer（10bit 线性）----
lin = scene ** 2.2  # 场景按显示亮度设计，转回线性光
raw = np.zeros((H, W))
raw[0::2, 0::2] = lin[0::2, 0::2, 0]  # R
raw[0::2, 1::2] = lin[0::2, 1::2, 1]  # Gr
raw[1::2, 0::2] = lin[1::2, 0::2, 1]  # Gb
raw[1::2, 1::2] = lin[1::2, 1::2, 2]  # B
raw16 = np.clip(raw * MAXV + rng.normal(0, 1.2, (H, W)), 0, MAXV).round().astype(np.uint16)

with open(OUT + ".raw", "wb") as f:
    f.write(raw16.astype("<u2").tobytes())

with open(OUT + ".txt", "w", encoding="ascii") as f:
    f.write("[common]\nWidth=1920\nHeight=1080\nBits=10\nBayer=RGGB\n"
            "BlackLevel_R=0\nBlackLevel_Gr=0\nBlackLevel_Gb=0\nBlackLevel_B=0\n")

# ---- 预览：直接用马赛克前的场景图（预览仅验证构图，不验证插值质量）----
Image.fromarray((np.clip(scene, 0, 1) ** (1 / 2.2) * 255).astype(np.uint8)).save(
    r"G:\DebugToolSet\scratch\landscape_preview.png")
print("OK", OUT + ".raw", raw16.shape, raw16.dtype, "min", raw16.min(), "max", raw16.max())
