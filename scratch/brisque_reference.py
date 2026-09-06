"""BRISQUE 交叉验证：numpy 复刻 rehanguha/brisque 的算法（无 scipy），
对测试图计算参考分值，供 Dart 实现比对。
输入：灰度图 raw 文件（uint8 灰度，w h 由参数给定）。
输出：参考 BRISQUE 分值。
"""
import pickle
import sys

import numpy as np


def gamma_lookup_table():
    from math import gamma, sin, pi

    def g(z):  # Lanczos 近似，与 Dart 侧一致
        p = [0.99999999999980993, 676.5203681218851, -1259.1392167224028,
             771.32342877765313, -176.61502916214059, 12.507343278686905,
             -0.13857109526572012, 9.9843695780195716e-6, 1.5056327351493116e-7]
        if z < 0.5:
            return pi / (sin(pi * z) * g(1 - z))
        z -= 1
        x = p[0]
        for i in range(1, 9):
            x += p[i] / (z + i)
        t = z + 7.5
        return (2 * pi) ** 0.5 * t ** (z + 0.5) * np.exp(-t) * x

    gam = np.arange(0.2, 10.001, 0.001)
    r_gam = np.array([g(2 / a) ** 2 / (g(1 / a) * g(3 / a)) for a in gam])
    return gam, r_gam, g


def aggd_raw(x, gam, r_gam):
    left = x[x < 0]
    right = x[x >= 0]
    if len(left) == 0 or len(right) == 0 or np.sum(x ** 2) == 0:
        return np.nan, np.nan, np.nan
    left_std = np.sqrt(np.mean(left ** 2))
    right_std = np.sqrt(np.mean(right ** 2))
    gammahat = left_std / right_std
    rhat = np.mean(np.abs(x)) ** 2 / np.mean(x ** 2)
    rhatnorm = rhat * (gammahat ** 3 + 1) * (gammahat + 1) / (gammahat ** 2 + 1) ** 2
    alpha = gam[np.argmin((r_gam - rhatnorm) ** 2)]
    return alpha, left_std, right_std


def gaussian_kernel2d(n, sigma):
    y, x = np.indices((n, n)) - n // 2
    k = np.exp(-(x ** 2 + y ** 2) / (2 * sigma ** 2)) / (2 * np.pi * sigma ** 2)
    return k / np.sum(k)


def conv2d_same(img, kernel):
    # 边界复制（scipy 'nearest' 同义），直接实现
    n = kernel.shape[0]
    pad = n // 2
    padded = np.pad(img, pad, mode='edge')
    out = np.zeros_like(img)
    for y in range(img.shape[0]):
        for x in range(img.shape[1]):
            out[y, x] = np.sum(padded[y:y + n, x:x + n] * kernel)
    return out


def features(img, gam, r_gam, g, kernel):
    C = 1 / 255
    mu = conv2d_same(img, kernel)
    sigma = np.sqrt(np.abs(mu ** 2 - conv2d_same(img ** 2, kernel)))
    mscn = (img - mu) / (sigma + C)

    feat = []
    alpha, sl, sr = aggd_raw(mscn.flatten(), gam, r_gam)
    feat += [alpha, (sl ** 2 + sr ** 2) / 2]

    prods = [
        mscn[:, :-1] * mscn[:, 1:],
        mscn[:-1, :] * mscn[1:, :],
        mscn[:-1, :-1] * mscn[1:, 1:],
        mscn[1:, :-1] * mscn[:-1, 1:],
    ]
    for p in prods:
        a, pl, pr = aggd_raw(p.flatten(), gam, r_gam)
        mean = (pr - pl) * np.sqrt(g(1 / a) / g(3 / a)) * (g(2 / a) / g(1 / a))
        feat += [a, mean, pl ** 2, pr ** 2]
    return feat


def main():
    path, w, h = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    gray = np.fromfile(path, dtype=np.uint8).reshape(h, w).astype(np.float64) / 255.0

    gam, r_gam, g = gamma_lookup_table()
    kernel = gaussian_kernel2d(7, 7 / 6)

    feat = features(gray, gam, r_gam, g, kernel)
    # 盒式降采样（与 Dart 侧一致；参考实现的双三次为已知口径差异）
    h2, w2 = h // 2, w // 2
    gray2 = gray[:h2 * 2, :w2 * 2].reshape(h2, 2, w2, 2).mean(axis=(1, 3))
    feat += features(gray2, gam, r_gam, g, kernel)
    feat = np.array(feat, dtype=np.float64)

    with open('scratch/brisque_normalize.pickle', 'rb') as f:
        scale = pickle.load(f)
    mn = np.array([float(v) for v in scale['min_']])
    mx = np.array([float(v) for v in scale['max_']])
    scaled = -1 + 2.0 / (mx - mn) * (feat - mn)

    # 解析 SVM 模型并回归
    gamma_svm = rho = None
    sv_lines = []
    with open('scratch/brisque_svm.txt') as f:
        in_sv = False
        for line in f:
            line = line.strip()
            if line == 'SV':
                in_sv = True
                continue
            if not in_sv:
                if line.startswith('gamma'):
                    gamma_svm = float(line.split()[1])
                elif line.startswith('rho'):
                    rho = float(line.split()[1])
            elif line:
                sv_lines.append(line)
    coefs = np.array([float(l.split()[0]) for l in sv_lines])
    svs = np.zeros((len(sv_lines), 36))
    for i, l in enumerate(sv_lines):
        for kv in l.split()[1:]:
            idx, v = kv.split(':')
            svs[i, int(idx) - 1] = float(v)
    d2 = np.sum((svs - scaled) ** 2, axis=1)
    score = np.sum(coefs * np.exp(-gamma_svm * d2)) - rho
    print(f'features[0..4]={feat[:5]}')
    print(f'BRISQUE={score:.6f}')


if __name__ == '__main__':
    main()
