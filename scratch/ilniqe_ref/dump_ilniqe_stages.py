"""ILNIQE 分阶段中间量转储（对拍 Dart 用）。

dump 内容（float64 小端 raw，524×524 或注明尺寸）：
  resized.rgb       — MATLAB 缩放后 RGB 三通道平面（r|g|b 顺序拼接）
  structdis.raw     — 尺度 1 的 O3 MSCN
  gmo1.raw          — 尺度 1 的 GMO1（高斯导数梯度幅度）
  intensity.raw     — 尺度 1 的 Intensity 对数通道
  ixo1.raw          — 尺度 1 的 IxO1
  logresp0.raw      — 尺度 1 第一个 log-Gabor 响应实部
  gm0.raw           — 尺度 1 第一个 log-Gabor 响应实部梯度
  block0_s1.raw     — 尺度 1 块 0 的 234 维特征
  block0_s2.raw     — 尺度 2 块 0 的 234 维特征
"""
import sys
import types

import numpy as np
import scipy.ndimage
import scipy.signal  # noqa: F401

if not hasattr(scipy.ndimage, 'filters'):
    scipy.ndimage.filters = scipy.ndimage
    sys.modules['scipy.ndimage.filters'] = scipy.ndimage

fake_cv2 = types.ModuleType('cv2')
sys.modules['cv2'] = fake_cv2
sys.path.insert(0, 'scratch/ilniqe_ref')
import importlib
ilm = importlib.import_module('IL-NIQE')
from matlab_resize import MATLABLikeResize


def dump(name, arr):
    np.ascontiguousarray(arr, dtype='<f8').tofile(f'scratch/ilniqe_dump_{name}')
    print(name, arr.shape, float(np.min(arr)), float(np.max(arr)))


def main():
    path, w, h = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    img = np.fromfile(path, dtype=np.uint8).reshape(h, w, 3).astype(np.float64)

    resize_func = MATLABLikeResize(output_shape=(524, 524))
    img = resize_func.resize_img(img)
    img = np.clip(img, 0.0, 255.0)
    dump('resized.rgb', np.stack([img[:, :, 0], img[:, :, 1], img[:, :, 2]]))

    img = img[0:504, 0:504]

    O1 = 0.3 * img[:, :, 0] + 0.04 * img[:, :, 1] - 0.35 * img[:, :, 2]
    O2 = 0.34 * img[:, :, 0] - 0.6 * img[:, :, 1] + 0.17 * img[:, :, 2]
    O3 = 0.06 * img[:, :, 0] + 0.63 * img[:, :, 1] + 0.27 * img[:, :, 2]
    RC, GC, BC = img[:, :, 0], img[:, :, 1], img[:, :, 2]

    gaussian_window = ilm.matlab_fspecial((5, 5), 5 / 6)
    gaussian_window = gaussian_window / np.sum(gaussian_window)

    from scipy.ndimage import convolve
    mu = convolve(O3, gaussian_window, mode='nearest')
    sigma = np.sqrt(np.abs(convolve(np.square(O3), gaussian_window, mode='nearest') - np.square(mu)))
    structdis = (O3 - mu) / (sigma + 1)
    dump('structdis.raw', structdis)

    dx, dy = ilm.gauDerivative(1.66 / (1 ** 0.28))
    compRes = ilm.conv2(O1, dx + 1j * dy, 'same')
    IxO1 = np.real(compRes)
    IyO1 = np.imag(compRes)
    GMO1 = np.sqrt(IxO1 ** 2 + IyO1 ** 2) + np.finfo(O1.dtype).eps
    dump('gmo1.raw', GMO1)
    dump('ixo1.raw', IxO1)

    logR = np.log(RC + 0.00001)
    logG = np.log(GC + 0.00001)
    logB = np.log(BC + 0.00001)
    logRMS = logR - np.mean(logR)
    logGMS = logG - np.mean(logG)
    logBMS = logB - np.mean(logB)
    Intensity = (logRMS + logGMS + logBMS) / np.sqrt(3)
    dump('intensity.raw', Intensity)

    LGFilters = ilm.logGabors(504, 504, 2.4 / (1 ** 0.87), 0.55, 1.31, 1.10)
    fftIm = np.fft.fft2(O3)
    f0 = LGFilters[0][0]
    response = np.fft.ifft2(f0 * fftIm)
    realRes = np.real(response)
    dump('logresp0.raw', realRes)
    compRes = ilm.conv2(realRes, dx + 1j * dy, 'same')
    realGM = np.sqrt(np.real(compRes) ** 2 + np.imag(compRes) ** 2) + np.finfo(float).eps
    dump('gm0.raw', realGM)

    # 完整尺度 1 复合特征图 → 块 0 特征
    def full_scale_features(img3, O1, O2, O3, scale):
        mu = convolve(O3, gaussian_window, mode='nearest')
        sigma = np.sqrt(np.abs(convolve(np.square(O3), gaussian_window, mode='nearest') - np.square(mu)))
        structdis = (O3 - mu) / (sigma + 1)
        dx, dy = ilm.gauDerivative(1.66 / (scale ** 0.28))
        mats = [structdis]
        for O in (O1, O2, O3):
            compRes = ilm.conv2(O, dx + 1j * dy, 'same')
            mats.append(np.sqrt(np.real(compRes) ** 2 + np.imag(compRes) ** 2) + np.finfo(float).eps)
        logR = np.log(img3[:, :, 0] + 0.00001)
        logG = np.log(img3[:, :, 1] + 0.00001)
        logB = np.log(img3[:, :, 2] + 0.00001)
        lR = logR - np.mean(logR)
        lG = logG - np.mean(logG)
        lB = logB - np.mean(logB)
        mats += [(lR + lG + lB) / np.sqrt(3), (lR + lG - 2 * lB) / np.sqrt(6), (lR - lG) / np.sqrt(2)]
        for O in (O1, O2, O3):
            compRes = ilm.conv2(O, dx + 1j * dy, 'same')
            mats += [np.real(compRes), np.imag(compRes)]
        hh, ww = O3.shape
        LGFilters = ilm.logGabors(hh, ww, 2.4 / (scale ** 0.87), 0.55, 1.31, 1.10)
        fftIm = np.fft.fft2(O3)
        logResponse, partialDer, GM = [], [], []
        for s in range(3):
            for o in range(4):
                response = np.fft.ifft2(LGFilters[s][o] * fftIm)
                realRes, imagRes = np.real(response), np.imag(response)
                cr = ilm.conv2(realRes, dx + 1j * dy, 'same')
                ci = ilm.conv2(imagRes, dx + 1j * dy, 'same')
                logResponse += [realRes, imagRes]
                partialDer += [np.real(cr), np.imag(cr), np.real(ci), np.imag(ci)]
                GM += [np.sqrt(np.real(cr) ** 2 + np.imag(cr) ** 2) + np.finfo(float).eps,
                       np.sqrt(np.real(ci) ** 2 + np.imag(ci) ** 2) + np.finfo(float).eps]
        mats += logResponse + partialDer + GM
        return mats

    mats1 = full_scale_features(img, O1, O2, O3, 1)
    feat0 = ilm.compute_feature(mats1, [0, 84, 0, 84])
    dump('block0_s1.raw', np.array(feat0))


if __name__ == '__main__':
    main()
