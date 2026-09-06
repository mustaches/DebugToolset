"""ILNIQE Python 参考实现运行器（对拍 Dart 用）。

剥掉 cv2 依赖（仅主入口用到 imread/cvtColor），RGB float64 直接喂
ilniqe()；兼容新版 scipy（ndimage.filters 已移除时打补丁）。

用法：python run_ilniqe_ref.py <rgb.raw> <w> <h> [raw255]
  rgb.raw：uint8 RGB 交织（w*h*3）。
"""
import sys
import types

import numpy as np
import scipy.ndimage

# 兼容：旧式 scipy.ndimage.filters / signal 导入路径
if not hasattr(scipy.ndimage, 'filters'):
    scipy.ndimage.filters = scipy.ndimage
    sys.modules['scipy.ndimage.filters'] = scipy.ndimage
import scipy.signal  # noqa: F401

# 假 cv2（IL-NIQE.py 顶层 import，本运行器不走 cv2 路径）
fake_cv2 = types.ModuleType('cv2')
sys.modules['cv2'] = fake_cv2

sys.path.insert(0, 'scratch/ilniqe_ref')
import importlib
ilniqe_mod = importlib.import_module('IL-NIQE')


def main():
    path, w, h = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    img = np.fromfile(path, dtype=np.uint8).reshape(h, w, 3).astype(np.float64)

    import scipy.io
    import math
    model_mat = scipy.io.loadmat('scratch/templateModel.mat')
    tm = model_mat['templateModel'][0]
    mu_pris_param, cov_pris_param, meanOfSampleData, principleVectors = tm

    gaussian_window = ilniqe_mod.matlab_fspecial((5, 5), 5 / 6)
    gaussian_window = gaussian_window / np.sum(gaussian_window)

    import warnings
    with warnings.catch_warnings():
        warnings.simplefilter('ignore', category=RuntimeWarning)
        t0 = __import__('time').time()
        score = ilniqe_mod.ilniqe(img, mu_pris_param, cov_pris_param,
                                  gaussian_window, principleVectors,
                                  meanOfSampleData, resize=True)
        dt = __import__('time').time() - t0
    print(f'ILNIQE={float(np.real(score)):.6f}  time={dt:.1f}s')


if __name__ == '__main__':
    main()
