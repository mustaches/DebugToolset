/// ILNIQE（特征增强型盲质量评价器，Zhang 15，无参考）：官方 MATLAB
/// 实现的 Dart 移植（对齐 IceClear/IL-NIQE 的 Python 复刻）。
///
/// 流程：RGB → MATLAB 风格抗锯齿双三次缩放归一化到 524×524 → 两个
/// 尺度（高斯滤波 + 隔点降采样）提取 109 通道复合特征图（O3 亮度
/// MSCN、对立色通道高斯导数梯度、对数通道强度/BY/RG、3 尺度 ×
/// 4 方向 log-Gabor 频域滤波响应及其导数与梯度）→ 84×84 分块提取
/// 234 维块特征（AGGD / Weibull / 均值方差）→ 两尺度拼接 468 维 →
/// 官方预训练 PCA 投影到 430 维 → 与 pristine 语料 MVG 模型的
/// 马氏距离逐块平均（越大越差）。
///
/// 纯 Dart + dart:typed_data，供后台 isolate 调用（计算量大，勿在
/// UI isolate 直接跑）。模型参数见 ilniqe_model.dart。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:debug_tool_set/modules/isp_studio/pipeline/ilniqe_model.dart';
import 'package:debug_tool_set/modules/isp_studio/pipeline/niqe.dart';

/// compute() 入口：`{'rgba': Uint8List, 'width': int, 'height': int}`
/// → ILNIQE 分值（double）。ILNIQE 计算量大，须放独立 isolate
/// （仪器 worker 的 5s 超时对它不适用）。
@pragma('vm:entry-point')
double ilniqeScoreInIsolate(Map<String, Object?> msg) => ilniqeScore(
    msg['rgba'] as Uint8List, msg['width'] as int, msg['height'] as int);

/// ---------------------------------------------------------------------------
/// 复数 FFT：2 的幂用迭代基-2，其余长度用 Bluestein 啾啾 z 变换
/// （任意长度的精确 DFT，524 = 4×131 含素数因子也可处理）。
/// ---------------------------------------------------------------------------

/// 就地基-2 FFT（[re]/[im] 交错存储不适用，这里按分量数组）。
/// [inverse] 为 true 时做 1/n 归一化的逆变换。
void _fftRadix2(Float64List re, Float64List im, bool inverse) {
  final n = re.length;
  // 位反转重排
  for (var i = 1, j = 0; i < n; i++) {
    var bit = n >> 1;
    for (; j & bit != 0; bit >>= 1) {
      j ^= bit;
    }
    j ^= bit;
    if (i < j) {
      final tr = re[i];
      re[i] = re[j];
      re[j] = tr;
      final ti = im[i];
      im[i] = im[j];
      im[j] = ti;
    }
  }
  final sign = inverse ? 1.0 : -1.0;
  for (var len = 2; len <= n; len <<= 1) {
    final ang = sign * 2 * math.pi / len;
    final wr = math.cos(ang);
    final wi = math.sin(ang);
    final half = len >> 1;
    for (var i = 0; i < n; i += len) {
      var cr = 1.0, ci = 0.0;
      for (var j = 0; j < half; j++) {
        final ur = re[i + j], ui = im[i + j];
        final vr = re[i + j + half] * cr - im[i + j + half] * ci;
        final vi = re[i + j + half] * ci + im[i + j + half] * cr;
        re[i + j] = ur + vr;
        im[i + j] = ui + vi;
        re[i + j + half] = ur - vr;
        im[i + j + half] = ui - vi;
        final ncr = cr * wr - ci * wi;
        ci = cr * wi + ci * wr;
        cr = ncr;
      }
    }
  }
  if (inverse) {
    for (var i = 0; i < n; i++) {
      re[i] /= n;
      im[i] /= n;
    }
  }
}

/// Bluestein 啾啾因子与「卷积核 b 的 FFT」缓存（键为变换长度 n）：
/// 滤波器组中同一长度的 1D FFT 重复上万次，这些表只与长度相关，
/// 算一次复用，数值与每次现算完全一致。isolate 内私有缓存。
final _bluesteinTables =
    <int, (Float64List, Float64List, Float64List, Float64List)>{};

(Float64List, Float64List, Float64List, Float64List) _bluesteinTableFor(
    int n, int m) {
  return _bluesteinTables.putIfAbsent(n, () {
    // 啾啾因子：k² 对 2n 取模避免大数精度问题。
    final chirpRe = Float64List(n);
    final chirpIm = Float64List(n);
    for (var k = 0; k < n; k++) {
      final kk = (k * k) % (2 * n);
      final ang = -math.pi * kk / n;
      chirpRe[k] = math.cos(ang);
      chirpIm[k] = math.sin(ang);
    }
    final bFftRe = Float64List(m);
    final bFftIm = Float64List(m);
    bFftRe[0] = 1;
    for (var k = 1; k < n; k++) {
      final kk = (k * k) % (2 * n);
      final ang = math.pi * kk / n;
      bFftRe[k] = bFftRe[m - k] = math.cos(ang);
      bFftIm[k] = bFftIm[m - k] = math.sin(ang);
    }
    _fftRadix2(bFftRe, bFftIm, false);
    return (chirpRe, chirpIm, bFftRe, bFftIm);
  });
}

/// 任意长度 1D FFT（Bluestein）：X[k] = Σ x[n]·e^(∓2πikn/N)。
void _fftAny(Float64List re, Float64List im, bool inverse) {
  final n = re.length;
  if (n & (n - 1) == 0) {
    _fftRadix2(re, im, inverse);
    return;
  }
  if (inverse) {
    // 逆变换 = 共轭后正变换再共轭，除以 n。
    for (var i = 0; i < n; i++) {
      im[i] = -im[i];
    }
    _fftAny(re, im, false);
    for (var i = 0; i < n; i++) {
      re[i] /= n;
      im[i] = -im[i] / n;
    }
    return;
  }
  // Bluestein：kn = (k²+n²-(k-n)²)/2，卷积长度 m = 2 的幂 ≥ 2n-1。
  var m = 1;
  while (m < 2 * n - 1) {
    m <<= 1;
  }
  final (chirpRe, chirpIm, bFftRe, bFftIm) = _bluesteinTableFor(n, m);
  final aRe = Float64List(m);
  final aIm = Float64List(m);
  for (var k = 0; k < n; k++) {
    aRe[k] = re[k] * chirpRe[k] - im[k] * chirpIm[k];
    aIm[k] = re[k] * chirpIm[k] + im[k] * chirpRe[k];
  }
  _fftRadix2(aRe, aIm, false);
  for (var i = 0; i < m; i++) {
    final tr = aRe[i] * bFftRe[i] - aIm[i] * bFftIm[i];
    aIm[i] = aRe[i] * bFftIm[i] + aIm[i] * bFftRe[i];
    aRe[i] = tr;
  }
  _fftRadix2(aRe, aIm, true);
  for (var k = 0; k < n; k++) {
    // y[k] = chirp[k]·c[k]（复数乘法）。
    final tr = aRe[k] * chirpRe[k] - aIm[k] * chirpIm[k];
    im[k] = aRe[k] * chirpIm[k] + aIm[k] * chirpRe[k];
    re[k] = tr;
  }
}

/// 2D FFT（先行后列；[inverse] 为逆变换）。复平面按 re/im 分量数组。
void _fft2(Float64List re, Float64List im, int w, int h, bool inverse) {
  final rowRe = Float64List(w);
  final rowIm = Float64List(w);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      rowRe[x] = re[y * w + x];
      rowIm[x] = im[y * w + x];
    }
    _fftAny(rowRe, rowIm, inverse);
    for (var x = 0; x < w; x++) {
      re[y * w + x] = rowRe[x];
      im[y * w + x] = rowIm[x];
    }
  }
  final colRe = Float64List(h);
  final colIm = Float64List(h);
  for (var x = 0; x < w; x++) {
    for (var y = 0; y < h; y++) {
      colRe[y] = re[y * w + x];
      colIm[y] = im[y * w + x];
    }
    _fftAny(colRe, colIm, inverse);
    for (var y = 0; y < h; y++) {
      re[y * w + x] = colRe[y];
      im[y * w + x] = colIm[y];
    }
  }
}

/// ---------------------------------------------------------------------------
/// 一维卷积（可分离核用）：[replicate] 为 true 时边界复制
/// （scipy.ndimage mode='nearest'），否则零填充（scipy.signal 'same'）。
/// 真卷积语义（核翻转）。
/// ---------------------------------------------------------------------------
Float64List _conv1d(Float64List data, int w, int h, Float64List kernel,
    {required bool horizontal, required bool replicate}) {
  final out = Float64List(data.length);
  final kLen = kernel.length;
  final half = kLen ~/ 2;
  final lineLen = horizontal ? w : h;
  final line = Float64List(lineLen);
  final lineOut = Float64List(lineLen);
  final count = horizontal ? h : w;
  for (var l = 0; l < count; l++) {
    for (var i = 0; i < lineLen; i++) {
      line[i] = horizontal ? data[l * w + i] : data[i * w + l];
    }
    for (var i = 0; i < lineLen; i++) {
      var s = 0.0;
      for (var k = 0; k < kLen; k++) {
        var idx = i + k - half;
        if (replicate) {
          if (idx < 0) {
            idx = 0;
          } else if (idx >= lineLen) {
            idx = lineLen - 1;
          }
        } else if (idx < 0 || idx >= lineLen) {
          continue; // 零填充
        }
        s += line[idx] * kernel[kLen - 1 - k]; // 翻转核 = 卷积
      }
      lineOut[i] = s;
    }
    for (var i = 0; i < lineLen; i++) {
      if (horizontal) {
        out[l * w + i] = lineOut[i];
      } else {
        out[i * w + l] = lineOut[i];
      }
    }
  }
  return out;
}

/// 可分离 2D 卷积：先水平核 [kx] 后垂直核 [ky]。
Float64List _conv2dSep(Float64List data, int w, int h, Float64List kx,
    Float64List ky, {required bool replicate}) {
  final tmp = _conv1d(data, w, h, kx, horizontal: true, replicate: replicate);
  return _conv1d(tmp, w, h, ky, horizontal: false, replicate: replicate);
}

/// 高斯导数核（IceClear gauDerivative 的可分离分解）：
/// dx[y][x] = x·exp(-(x²+y²)/2σ²) = (x·exp(-x²/2σ²))·(exp(-y²/2σ²))。
/// 返回 (水平导数核, 垂直平滑核)；dy 交换两核角色。
(Float64List, Float64List) _gauDerKernels(double sigma) {
  final half = (3 * sigma).ceil();
  final kx = Float64List(2 * half + 1);
  final ky = Float64List(2 * half + 1);
  for (var i = -half; i <= half; i++) {
    kx[i + half] = i * math.exp(-(i * i) / 2 / sigma / sigma);
    ky[i + half] = math.exp(-(i * i) / 2 / sigma / sigma);
  }
  return (kx, ky);
}

/// MATLAB fspecial('gaussian', n, sigma) 的可分离形式（先按一维高斯
/// 取值再归一化；本流程用到的 5×5 σ=5/6 与 6×6 σ=0.9 两个窗在
/// MATLAB 的 eps 截断规则下均无元素被截断，一维可分离分解精确成立）。
(Float64List, Float64List) _gaussianKernels(int n, double sigma) {
  final m = (n - 1) / 2;
  final k = Float64List(n);
  var sum = 0.0;
  for (var i = 0; i < n; i++) {
    final x = i - m;
    k[i] = math.exp(-(x * x) / (2 * sigma * sigma));
    sum += k[i];
  }
  for (var i = 0; i < k.length; i++) {
    k[i] /= sum;
  }
  return (k, k);
}

/// ---------------------------------------------------------------------------
/// MATLAB 风格双三次缩放（matlab_resize.py 移植，抗锯齿核宽 4）。
/// ---------------------------------------------------------------------------

double _cubic(double x) {
  final ax = x.abs();
  if (ax <= 1) return 1.5 * ax * ax * ax - 2.5 * ax * ax + 1;
  if (ax <= 2) return -0.5 * ax * ax * ax + 2.5 * ax * ax - 4 * ax + 2;
  return 0;
}

/// 单维插值权重与索引（matlab_resize.get_weights_indices 移植）。
(Float64List, Int32List, int) _resizeWeights(
    int inLen, int outLen, double Function(double) kernel, double kernelWidth) {
  final scale = outLen / inLen;
  double Function(double) h = kernel;
  var kw = kernelWidth;
  if (scale < 1) {
    h = (x) => scale * kernel(scale * x);
    kw = kernelWidth / scale;
  }
  final p = kw.ceil() + 2;
  final weights = Float64List(outLen * p);
  final indices = Int32List(outLen * p);
  // 对称边界索引表（matlab_resize 的 aux/mod 逻辑）。
  final auxLen = inLen * 2;
  for (var o = 0; o < outLen; o++) {
    final u = (o + 1) / scale + 0.5 * (1 - 1 / scale);
    final left = (u - kw / 2).floor();
    var wSum = 0.0;
    for (var k = 0; k < p; k++) {
      var idx = (left + k) % auxLen;
      if (idx < 0) idx += auxLen;
      final src = idx < inLen ? idx : auxLen - 1 - idx;
      final wt = h(u - (left + k) - 1);
      indices[o * p + k] = src;
      weights[o * p + k] = wt;
      wSum += wt;
    }
    if (wSum != 0) {
      for (var k = 0; k < p; k++) {
        weights[o * p + k] /= wSum;
      }
    }
  }
  return (weights, indices, p);
}

/// 平面缩放到 (outW, outH)（先对小scale维度处理的顺序对结果有
/// 轻微影响，参考实现按 scale 升序处理）。
Float64List ilniqeResizePlane(
    Float64List plane, int w, int h, int outW, int outH) {
  final scaleX = outW / w;
  final scaleY = outH / h;
  final (wx, ix, px) = _resizeWeights(w, outW, _cubic, 4.0);
  final (wy, iy, py) = _resizeWeights(h, outH, _cubic, 4.0);
  // 参考实现按 scale 升序逐维缩放。
  final xFirst = scaleX <= scaleY;
  Float64List cur = plane;
  var cw = w, ch = h;
  for (var step = 0; step < 2; step++) {
    final horizontal = (step == 0) ? xFirst : !xFirst;
    if (horizontal) {
      final out = Float64List(outW * ch);
      for (var y = 0; y < ch; y++) {
        for (var o = 0; o < outW; o++) {
          var s = 0.0;
          for (var k = 0; k < px; k++) {
            s += cur[y * cw + ix[o * px + k]] * wx[o * px + k];
          }
          out[y * outW + o] = s;
        }
      }
      cur = out;
      cw = outW;
    } else {
      final out = Float64List(cw * outH);
      for (var o = 0; o < outH; o++) {
        for (var x = 0; x < cw; x++) {
          var s = 0.0;
          for (var k = 0; k < py; k++) {
            s += cur[iy[o * py + k] * cw + x] * wy[o * py + k];
          }
          out[o * cw + x] = s;
        }
      }
      cur = out;
      ch = outH;
    }
  }
  return cur;
}

/// ---------------------------------------------------------------------------
/// log-Gabor 频域滤波器组（IceClear logGabors 移植）。
/// ---------------------------------------------------------------------------

/// 构造 3 尺度 × 4 方向的 log-Gabor 频域滤波器（w×h，按 尺度主、
/// 方向次 的顺序返回 12 张）。
List<Float64List> _logGaborFilters(int w, int h, double minWaveLength,
    double sigmaOnf, double mult, double dThetaOnSigma) {
  const nScale = 3, nOrient = 4;
  final thetaSigma = math.pi / nOrient / dThetaOnSigma;
  final radius = Float64List(w * h);
  final theta = Float64List(w * h);
  for (var y = 0; y < h; y++) {
    // ifftshift 后的频率坐标（偶数尺寸：y - h/2）。
    final ys = (y - h ~/ 2 + h) % h;
    final yr = (h % 2 == 1)
        ? (ys - (h - 1) / 2) / (h - 1)
        : (ys - h / 2) / h;
    for (var x = 0; x < w; x++) {
      final xs = (x - w ~/ 2 + w) % w;
      final xr =
          (w % 2 == 1) ? (xs - (w - 1) / 2) / (w - 1) : (xs - w / 2) / w;
      radius[y * w + x] = math.sqrt(xr * xr + yr * yr);
      theta[y * w + x] = math.atan2(-yr, xr);
    }
  }
  radius[0] = 1; // 直流位置（ifftshift 后原点）
  final logSigma = math.log(sigmaOnf);
  final filters = <Float64List>[];
  for (var s = 0; s < nScale; s++) {
    final wavelength = minWaveLength * math.pow(mult, s);
    final fo = 1.0 / wavelength;
    final radial = Float64List(w * h);
    for (var i = 0; i < radial.length; i++) {
      final lr = math.log(radius[i] / fo);
      radial[i] = math.exp(-(lr * lr) / (2 * logSigma * logSigma));
    }
    radial[0] = 0;
    for (var o = 0; o < nOrient; o++) {
      final angl = o * math.pi / nOrient;
      final f = Float64List(w * h);
      for (var i = 0; i < f.length; i++) {
        final st = math.sin(theta[i]);
        final ct = math.cos(theta[i]);
        final ds = st * math.cos(angl) - ct * math.sin(angl);
        final dc = ct * math.cos(angl) + st * math.sin(angl);
        final dtheta = math.atan2(ds, dc).abs();
        f[i] = radial[i] *
            math.exp(-(dtheta * dtheta) / (2 * thetaSigma * thetaSigma));
      }
      filters.add(f);
    }
  }
  return filters;
}

/// ---------------------------------------------------------------------------
/// Weibull 拟合（IceClear fitweibull 移植：指数威布尔 a=1 的负对数似然
/// + Nelder-Mead 单纯形下降，xtol/ftol=0.01）。
/// ---------------------------------------------------------------------------

/// Nelder-Mead 单纯形最小化（二维，scipy fmin 口径的简化版）。
List<double> _nelderMead(double Function(List<double>) f, List<double> x0,
    {double xtol = 0.01, double ftol = 0.01, int maxIter = 400}) {
  final n = x0.length;
  // 初始单纯形：x0 与 x0 ± 5%（scipy nonzdelt=0.05）。
  final simplex = <List<double>>[
    List<double>.from(x0),
    for (var i = 0; i < n; i++)
      [
        for (var j = 0; j < n; j++)
          i == j ? x0[j] * 1.05 : x0[j],
      ],
  ];
  var fvals = [for (final p in simplex) f(p)];
  for (var iter = 0; iter < maxIter; iter++) {
    final order = List<int>.generate(n + 1, (i) => i)
      ..sort((a, b) => fvals[a].compareTo(fvals[b]));
    final sorted = [for (final i in order) simplex[i]];
    final sf = [for (final i in order) fvals[i]];
    // 收敛判定：点距与函数值距（scipy: max|rho-rho0|<=xtol 且
    // max|f-f0|<=ftol，相对 x0 点）。
    var maxPtDiff = 0.0, maxFunDiff = 0.0;
    for (var i = 1; i <= n; i++) {
      for (var j = 0; j < n; j++) {
        maxPtDiff = math.max(maxPtDiff, (sorted[i][j] - sorted[0][j]).abs());
      }
      maxFunDiff = math.max(maxFunDiff, (sf[i] - sf[0]).abs());
    }
    simplex.setAll(0, sorted);
    fvals = sf;
    if (maxPtDiff <= xtol && maxFunDiff <= ftol) break;
    // 质心（除最差点）
    final centroid = List<double>.filled(n, 0.0);
    for (var i = 0; i < n; i++) {
      for (var j = 0; j < n; j++) {
        centroid[j] += simplex[i][j] / n;
      }
    }
    List<double> evalPoint(List<double> p) {
      final fv = f(p);
      if (fv < fvals[0]) return p;
      return const [];
    }

    // 反射
    final xr = [for (var j = 0; j < n; j++) 2 * centroid[j] - simplex[n][j]];
    final fr = f(xr);
    if (fr < fvals[n - 1]) {
      if (fr < fvals[0]) {
        // 扩展
        final xe = [
          for (var j = 0; j < n; j++) 2 * xr[j] - centroid[j]
        ];
        final fe = f(xe);
        final best = evalPoint(fe < fr ? xe : xr);
        simplex[n] = best.isNotEmpty ? best : (fe < fr ? xe : xr);
        fvals[n] = fe < fr ? fe : fr;
      } else {
        simplex[n] = xr;
        fvals[n] = fr;
      }
    } else {
      // 收缩
      final xc = [
        for (var j = 0; j < n; j++) 0.5 * (centroid[j] + simplex[n][j])
      ];
      final fc = f(xc);
      if (fc < fvals[n]) {
        simplex[n] = xc;
        fvals[n] = fc;
      } else {
        // 全局收缩
        for (var i = 1; i <= n; i++) {
          for (var j = 0; j < n; j++) {
            simplex[i][j] = 0.5 * (simplex[0][j] + simplex[i][j]);
          }
          fvals[i] = f(simplex[i]);
        }
      }
    }
  }
  final best = List<int>.generate(n + 1, (i) => i)
    ..sort((a, b) => fvals[a].compareTo(fvals[b]));
  return simplex[best[0]];
}

/// Weibull 拟合（scipy exponweib a=1 的 MLE，fmin 初值同参考实现）。
/// 返回 (shape, scale)。数据须为正；退化（log 方差为 0）时返回 NaN。
/// 实现说明：Nelder-Mead 每次评估都要对全样本求和，先把正值样本的
/// log 缓存下来，NLL 按 Σ 展开（Σlog(x/s)=ΣlogV−n·log s，
/// Σ(x/s)^c=s^-c·Σexp(c·logV)），每次评估每样本仅需 1 次 exp
/// （原实现每样本 log+pow+除法，且 log(shape)/log(scale) 在循环内
/// 重复计算）；与原逐项计算存在浮点尾差，对分值影响可忽略。
(double, double) _fitWeibull(Float64List data) {
  var n = 0;
  final logV = Float64List(data.length);
  var sumLog = 0.0;
  for (final v in data) {
    if (v > 0) {
      logV[n++] = math.log(v);
      sumLog += logV[n - 1];
    }
  }
  if (n == 0) return (double.nan, double.nan);
  final logMean = sumLog / n;
  var logVar = 0.0;
  for (var i = 0; i < n; i++) {
    final d = logV[i] - logMean;
    logVar += d * d;
  }
  final logStd = math.sqrt(logVar / n);
  if (logStd == 0) return (double.nan, double.nan);
  final shape0 = 1.2 / logStd;
  final scale0 = math.exp(logMean + 0.572 / shape0);
  final nf = n.toDouble();

  double nll(List<double> theta) {
    final shape = theta[0];
    final scale = theta[1];
    if (shape <= 0 || scale <= 0) return double.infinity;
    // -Σlog pdf：-[log c - log s + (c-1)·log(x/s) - (x/s)^c] 求和展开。
    var sumPow = 0.0;
    for (var i = 0; i < n; i++) {
      sumPow += math.exp(shape * logV[i]);
    }
    final logScale = math.log(scale);
    return -nf * math.log(shape) +
        nf * logScale -
        (shape - 1) * (sumLog - nf * logScale) +
        sumPow / math.pow(scale, shape);
  }

  final best = _nelderMead(nll, [shape0, scale0]);
  return (best[0], best[1]);
}

/// ---------------------------------------------------------------------------
/// ILNIQE 主流程
/// ---------------------------------------------------------------------------

const int _kIlniqeBlock = 84;
const double _kIlniqeInfConst = 10000;
const double _kIlniqeNanConst = 2000;

/// 对称矩阵伪逆（Jacobi 特征分解；|λ| ≤ 1e-15·λmax 置零，
/// numpy.linalg.pinv 默认 rcond 口径）。
/// 扫描策略为 Numerical Recipes 的阈值循环 Jacobi：前 4 扫按非
/// 对角元量级设旋转门限，之后的扫把浮点意义上已可忽略的元素
/// 正式置零并跳过——绝大多数微小旋转被跳过，收敛轮次与最终
/// 对角化精度不变（机器精度），430² 矩阵从约 10s 降到亚秒级。
Float64List _pinvSymmetric(Float64List a, int n) {
  // Jacobi 旋转求特征分解 A = QΛQᵀ。
  final m = Float64List.fromList(a);
  final q = Float64List(n * n);
  for (var i = 0; i < n; i++) {
    q[i * n + i] = 1.0;
  }
  var rotCount = 0;
  var off0 = -1.0;
  for (var sweep = 0; sweep < 100; sweep++) {
    var off = 0.0;
    for (var p = 0; p < n; p++) {
      for (var r = p + 1; r < n; r++) {
        off += m[p * n + r].abs();
      }
    }
    print('sweep $sweep off=$off rotsofar=$rotCount');
    if (off == 0.0) break;
    if (off0 < 0) off0 = off;
    // 收敛判据：非对角元总量相对首扫降到 1e-12 以下时剩余旋转对
    // 特征值的影响已低于 pinv 截断（1e-15·λmax）数个量级，可停。
    if (sweep > 3 && off <= 1e-12 * off0) break;
    // 门限全程有效（随 off 单调收缩），配合后期的「浮点可忽略
    // 置零」判据；旋转数学不变，最终对角化精度不变（机器精度）。
    final tresh = 0.2 * off / (n * n);
    for (var p = 0; p < n; p++) {
      for (var r = p + 1; r < n; r++) {
        final apr = m[p * n + r];
        final absApr = apr.abs();
        if (absApr == 0.0) continue;
        if (absApr <= tresh) {
          continue;
        }
        if (sweep > 3) {
          // 后期扫：|apr| 相对对角元在浮点意义上可忽略（NR: g=100·
          // |apr|，|app|+g==|app| 且 |arr|+g==|arr|），正式置零。
          final g = 100.0 * absApr;
          final app = m[p * n + p].abs();
          final arr = m[r * n + r].abs();
          if (app + g == app && arr + g == arr) {
            m[p * n + r] = 0.0;
            m[r * n + p] = 0.0; // 本实现维护完整对称矩阵，两边都置零
            continue;
          }
        }
        rotCount++;
        final app = m[p * n + p];
        final arr = m[r * n + r];
        final phi = 0.5 * math.atan2(2 * apr, arr - app);
        final c = math.cos(phi);
        final s = math.sin(phi);
        for (var k = 0; k < n; k++) {
          final mkp = m[k * n + p];
          final mkr = m[k * n + r];
          m[k * n + p] = c * mkp - s * mkr;
          m[k * n + r] = s * mkp + c * mkr;
        }
        for (var k = 0; k < n; k++) {
          final mpk = m[p * n + k];
          final mrk = m[r * n + k];
          m[p * n + k] = c * mpk - s * mrk;
          m[r * n + k] = s * mpk + c * mrk;
        }
        for (var k = 0; k < n; k++) {
          final qkp = q[k * n + p];
          final qkr = q[k * n + r];
          q[k * n + p] = c * qkp - s * qkr;
          q[k * n + r] = s * qkp + c * qkr;
        }
      }
    }
  }
  var lamMax = 0.0;
  for (var i = 0; i < n; i++) {
    lamMax = math.max(lamMax, m[i * n + i].abs());
  }
  final cutoff = lamMax * 1e-15;
  final inv = Float64List(n * n);
  for (var i = 0; i < n; i++) {
    final lam = m[i * n + i];
    if (lam.abs() <= cutoff) continue;
    final invLam = 1 / lam;
    for (var r = 0; r < n; r++) {
      for (var c = 0; c < n; c++) {
        inv[r * n + c] += q[r * n + i] * invLam * q[c * n + i];
      }
    }
  }
  return inv;
}

/// 块特征（IceClear compute_feature 移植）：复合特征图 [channels]
/// （每张 w×h）的 [bx,by] 块（块边长 bs）→ 234 维。
List<double> _ilniqeBlockFeatures(List<Float64List> channels, int w,
    int bx, int by, int bs) {
  Float64List crop(int ch) {
    final src = channels[ch];
    final out = Float64List(bs * bs);
    for (var y = 0; y < bs; y++) {
      for (var x = 0; x < bs; x++) {
        out[y * bs + x] = src[(by + y) * w + bx + x];
      }
    }
    return out;
  }

  final feat = <double>[];
  // 通道 0：结构失真 MSCN 的 AGGD + 4 方向邻积（环绕平移）。
  final d0 = crop(0);
  final (a0, bl0, br0) = nssEstimateAggd(d0);
  feat.add(a0);
  feat.add((bl0 + br0) / 2);
  const shifts = [
    [0, 1],
    [1, 0],
    [1, 1],
    [1, -1],
  ];
  for (final s in shifts) {
    final prod = Float64List(bs * bs);
    for (var y = 0; y < bs; y++) {
      final sy = (y + s[0]) % bs;
      for (var x = 0; x < bs; x++) {
        final sx = (x + s[1] + bs) % bs;
        prod[y * bs + x] = d0[y * bs + x] * d0[sy * bs + sx];
      }
    }
    final (a, bl, br) = nssEstimateAggd(prod);
    final mean = a.isNaN
        ? double.nan
        : (br - bl) * (nssGamma(2 / a) / nssGamma(1 / a));
    feat.addAll([a, mean, bl, br]);
  }
  // 通道 1-3：对立色梯度幅度的 Weibull（scale, shape）。
  for (var ch = 1; ch <= 3; ch++) {
    final (shape, scale) = _fitWeibull(crop(ch));
    feat.addAll([scale, shape]);
  }
  // 通道 4-6：对数通道（Intensity/BY/RG）的均值与方差。
  for (var ch = 4; ch <= 6; ch++) {
    final d = crop(ch);
    var mu = 0.0;
    for (final v in d) {
      mu += v;
    }
    mu /= d.length;
    var varSum = 0.0;
    for (final v in d) {
      varSum += (v - mu) * (v - mu);
    }
    feat.addAll([mu, varSum / d.length]);
  }
  // 通道 7-84：导数/log-Gabor 响应的 AGGD（α, (β_l+β_r)/2）。
  for (var ch = 7; ch <= 84; ch++) {
    final (a, bl, br) = nssEstimateAggd(crop(ch));
    feat.addAll([a, (bl + br) / 2]);
  }
  // 通道 85-108：log-Gabor 梯度幅度的 Weibull（scale, shape）。
  for (var ch = 85; ch <= 108; ch++) {
    final (shape, scale) = _fitWeibull(crop(ch));
    feat.addAll([scale, shape]);
  }
  return feat;
}

/// ILNIQE 质量分（无参考，越大越差）。内部归一化到 524×524，
/// 与输入尺寸无关；宽或高 < 2 时返回 NaN。
/// [debug] 非空时填入分阶段中间量（测试/调试用）：'resized'
/// （缩放后 R|G|B 拼接，524×524 每通道）、'structdis'、'gmo1'、
/// 'ixo1'、'intensity'、'logresp0'、'gm0'（均为尺度 1、504×504）、
/// 'block0_s1'/'block0_s2'（块 0 的 234 维特征）。
double ilniqeScore(Uint8List rgba, int width, int height,
    {Map<String, Float64List>? debug}) {
  if (width < 2 || height < 2 || rgba.length < width * height * 4) {
    return double.nan;
  }
  const sigmaForGauDerivative = 1.66;
  const kForLog = 0.00001;
  const normalizedWidth = 524;
  const minWaveLength = 2.4;
  const sigmaOnf = 0.55;
  const mult = 1.31;
  const dThetaOnSigma = 1.10;
  const scaleFactorForLoG = 0.87;
  const scaleFactorForGaussianDer = 0.28;
  const sigmaForDownsample = 0.9;
  const eps = 2.220446049250313e-16;

  // RGB 平面（0..255，取整与参考实现一致）。
  var w = width, h = height;
  var r = Float64List(w * h);
  var g = Float64List(w * h);
  var b = Float64List(w * h);
  for (var i = 0, j = 0; i < w * h; i++, j += 4) {
    r[i] = rgba[j].toDouble();
    g[i] = rgba[j + 1].toDouble();
    b[i] = rgba[j + 2].toDouble();
  }
  // MATLAB 风格抗锯齿双三次缩放到 524×524。
  r = ilniqeResizePlane(r, w, h, normalizedWidth, normalizedWidth);
  g = ilniqeResizePlane(g, w, h, normalizedWidth, normalizedWidth);
  b = ilniqeResizePlane(b, w, h, normalizedWidth, normalizedWidth);
  for (var i = 0; i < r.length; i++) {
    r[i] = r[i].clamp(0.0, 255.0);
    g[i] = g[i].clamp(0.0, 255.0);
    b[i] = b[i].clamp(0.0, 255.0);
  }
  w = h = normalizedWidth;
  if (debug != null) {
    debug['resized'] = Float64List.fromList([...r, ...g, ...b]);
  }
  // 裁剪到 84 的整数倍（524 → 504；参考实现在计算对立通道前裁剪，
  // 后续卷积/FFT 都在裁剪后的平面上进行）。
  final nb = normalizedWidth ~/ _kIlniqeBlock;
  final cw = nb * _kIlniqeBlock;
  Float64List cropPlane(Float64List p) {
    final out = Float64List(cw * cw);
    for (var y = 0; y < cw; y++) {
      for (var x = 0; x < cw; x++) {
        out[y * cw + x] = p[y * normalizedWidth + x];
      }
    }
    return out;
  }

  r = cropPlane(r);
  g = cropPlane(g);
  b = cropPlane(b);
  w = h = cw;

  // 对立色空间（log 变换前的线性对立通道）。
  var o1 = Float64List(w * h);
  var o2 = Float64List(w * h);
  var o3 = Float64List(w * h);
  for (var i = 0; i < w * h; i++) {
    o1[i] = 0.3 * r[i] + 0.04 * g[i] - 0.35 * b[i];
    o2[i] = 0.34 * r[i] - 0.6 * g[i] + 0.17 * b[i];
    o3[i] = 0.06 * r[i] + 0.63 * g[i] + 0.27 * b[i];
  }

  // 5×5 高斯窗（σ=5/6，截尾归一化同 MATLAB fspecial）。
  final (gk5, _) = _gaussianKernels(5, 5 / 6);
  // 降采样高斯（σ=0.9，⌈6σ⌉=6）。
  final (gks, _) = _gaussianKernels(6, sigmaForDownsample);

  final allFeatures = <List<double>>[];
  for (var scale = 1; scale <= 2; scale++) {
    // 结构失真：O3 的 MSCN。
    final mu3 = _conv2dSep(o3, w, h, gk5, gk5, replicate: true);
    final sq3 = Float64List(w * h);
    for (var i = 0; i < sq3.length; i++) {
      sq3[i] = o3[i] * o3[i];
    }
    final sig3 = _conv2dSep(sq3, w, h, gk5, gk5, replicate: true);
    final structDis = Float64List(w * h);
    for (var i = 0; i < structDis.length; i++) {
      final s2 = (sig3[i] - mu3[i] * mu3[i]).abs();
      structDis[i] = (o3[i] - mu3[i]) / (math.sqrt(s2) + 1);
    }

    // 高斯导数梯度（尺度相关 σ；零填充真卷积）。
    final sigmaDer = sigmaForGauDerivative /
        math.pow(scale, scaleFactorForGaussianDer);
    final (kx, ky) = _gauDerKernels(sigmaDer);
    Float64List gradX(Float64List p) =>
        _conv2dSep(p, w, h, kx, ky, replicate: false);
    Float64List gradY(Float64List p) =>
        _conv2dSep(p, w, h, ky, kx, replicate: false);
    final ix1 = gradX(o1), iy1 = gradY(o1);
    final ix2 = gradX(o2), iy2 = gradY(o2);
    final ix3 = gradX(o3), iy3 = gradY(o3);
    final gm1 = Float64List(w * h);
    final gm2 = Float64List(w * h);
    final gm3 = Float64List(w * h);
    for (var i = 0; i < gm1.length; i++) {
      gm1[i] = math.sqrt(ix1[i] * ix1[i] + iy1[i] * iy1[i]) + eps;
      gm2[i] = math.sqrt(ix2[i] * ix2[i] + iy2[i] * iy2[i]) + eps;
      gm3[i] = math.sqrt(ix3[i] * ix3[i] + iy3[i] * iy3[i]) + eps;
    }

    // 对数通道（均值减除）与强度/色度组合。
    double meanOf(Float64List p) {
      var s = 0.0;
      for (final v in p) {
        s += v;
      }
      return s / p.length;
    }

    final logR = Float64List(w * h);
    final logG = Float64List(w * h);
    final logB = Float64List(w * h);
    for (var i = 0; i < logR.length; i++) {
      logR[i] = math.log(r[i] + kForLog);
      logG[i] = math.log(g[i] + kForLog);
      logB[i] = math.log(b[i] + kForLog);
    }
    final mR = meanOf(logR), mG = meanOf(logG), mB = meanOf(logB);
    final intensity = Float64List(w * h);
    final by = Float64List(w * h);
    final rg = Float64List(w * h);
    for (var i = 0; i < intensity.length; i++) {
      final lr = logR[i] - mR;
      final lg = logG[i] - mG;
      final lb = logB[i] - mB;
      intensity[i] = (lr + lg + lb) / math.sqrt(3);
      by[i] = (lr + lg - 2 * lb) / math.sqrt(6);
      rg[i] = (lr - lg) / math.sqrt(2);
    }

    final channels = <Float64List>[
      structDis, gm1, gm2, gm3, intensity, by, rg,
      ix1, iy1, ix2, iy2, ix3, iy3,
    ];
    if (scale == 1 && debug != null) {
      debug['structdis'] = structDis;
      debug['gmo1'] = gm1;
      debug['ixo1'] = ix1;
      debug['intensity'] = intensity;
    }

    // log-Gabor 频域滤波（O3）：3 尺度 × 4 方向。
    final filters = _logGaborFilters(
        w, h, minWaveLength / math.pow(scale, scaleFactorForLoG), sigmaOnf,
        mult, dThetaOnSigma);
    final fftRe = Float64List.fromList(o3);
    final fftIm = Float64List(w * h);
    _fft2(fftRe, fftIm, w, h, false);
    for (var f = 0; f < 12; f++) {
      final fRe = Float64List(w * h);
      final fIm = Float64List(w * h);
      final filt = filters[f];
      for (var i = 0; i < fRe.length; i++) {
        fRe[i] = filt[i] * fftRe[i];
        fIm[i] = filt[i] * fftIm[i];
      }
      _fft2(fRe, fIm, w, h, true);
      final realRes = fRe;
      final imagRes = fIm;
      final prx = gradX(realRes);
      final pry = gradY(realRes);
      final pix = gradX(imagRes);
      final piy = gradY(imagRes);
      final realGm = Float64List(w * h);
      final imagGm = Float64List(w * h);
      for (var i = 0; i < realGm.length; i++) {
        realGm[i] = math.sqrt(prx[i] * prx[i] + pry[i] * pry[i]) + eps;
        imagGm[i] = math.sqrt(pix[i] * pix[i] + piy[i] * piy[i]) + eps;
      }
      if (scale == 1 && f == 0 && debug != null) {
        debug['logresp0'] = Float64List.fromList(realRes);
        debug['gm0'] = Float64List.fromList(realGm);
      }
      channels.addAll([realRes, imagRes, prx, pry, pix, piy, realGm, imagGm]);
    }
    // 重排为参考实现的通道顺序（参考按滤波器逐个交错追加：
    // logResponse 为 real0,imag0,real1,imag1,...，partialDer 与 GM 同理）。
    final ordered = <Float64List>[
      ...channels.sublist(0, 13),
      for (var f = 0; f < 12; f++) ...[
        channels[13 + f * 8], // realRes
        channels[13 + f * 8 + 1], // imagRes
      ],
      for (var f = 0; f < 12; f++) ...[
        channels[13 + f * 8 + 2], // prx
        channels[13 + f * 8 + 3], // pry
        channels[13 + f * 8 + 4], // pix
        channels[13 + f * 8 + 5], // piy
      ],
      for (var f = 0; f < 12; f++) ...[
        channels[13 + f * 8 + 6], // realGm
        channels[13 + f * 8 + 7], // imagGm
      ],
    ];

    // 分块特征（块边长 84/scale）。
    final bs = _kIlniqeBlock ~/ scale;
    for (var by = 0; by < nb; by++) {
      for (var bx = 0; bx < nb; bx++) {
        final feat =
            _ilniqeBlockFeatures(ordered, w, bx * bs, by * bs, bs);
        if (debug != null && by == 0 && bx == 0) {
          debug[scale == 1 ? 'block0_s1' : 'block0_s2'] =
              Float64List.fromList(feat);
        }
        allFeatures.add(feat);
      }
    }

    if (scale == 1) {
      // 高斯平滑 + 隔点降采样（边界复制）。
      Float64List down(Float64List p) {
        final sm = _conv2dSep(p, w, h, gks, gks, replicate: true);
        final w2 = w ~/ 2, h2 = h ~/ 2;
        final out = Float64List(w2 * h2);
        for (var y = 0; y < h2; y++) {
          for (var x = 0; x < w2; x++) {
            out[y * w2 + x] = sm[y * 2 * w + x * 2];
          }
        }
        return out;
      }

      o1 = down(o1);
      o2 = down(o2);
      o3 = down(o3);
      r = down(r);
      g = down(g);
      b = down(b);
      w ~/= 2;
      h ~/= 2;
    }
  }

  // 两尺度特征按块拼接为 468 维。
  final blocks = nb * nb;
  final distparam = <List<double>>[
    for (var i = 0; i < blocks; i++)
      [...allFeatures[i], ...allFeatures[blocks + i]],
  ];
  // inf 截断。
  for (final row in distparam) {
    for (var j = 0; j < row.length; j++) {
      if (row[j] > _kIlniqeInfConst) row[j] = _kIlniqeInfConst;
    }
  }

  // PCA 投影：finalFeatures = (Pᵀ·(Fᵀ-M))ᵀ = (F-Mᵀ)·P，430 维。
  const pcaDim = ilniqePcaDim;
  const featDim = ilniqeFeatureDim;
  final finalFeatures = <Float64List>[];
  for (final row in distparam) {
    final out = Float64List(pcaDim);
    for (var k = 0; k < pcaDim; k++) {
      var s = 0.0;
      for (var j = 0; j < featDim; j++) {
        s += (row[j] - ilniqeMeanOfSample[j]) * ilniqePrincipleVectors[j * pcaDim + k];
      }
      out[k] = s;
    }
    finalFeatures.add(out);
  }

  // 逐行均值（NaN 剔除，全 NaN 维置 nanConst）。
  final muDist = Float64List(pcaDim);
  final counts = List<int>.filled(pcaDim, 0);
  for (final row in finalFeatures) {
    for (var j = 0; j < pcaDim; j++) {
      if (!row[j].isNaN) {
        muDist[j] += row[j];
        counts[j]++;
      }
    }
  }
  for (var j = 0; j < pcaDim; j++) {
    muDist[j] =
        counts[j] > 0 ? muDist[j] / counts[j] : _kIlniqeNanConst;
  }
  // 协方差（无 NaN 行，ddof=1）。
  final validRows = [
    for (final row in finalFeatures)
      if (!row.any((v) => v.isNaN)) row,
  ];
  final covDist = Float64List(pcaDim * pcaDim);
  if (validRows.length >= 2) {
    final nv = validRows.length;
    final means = Float64List(pcaDim);
    for (final row in validRows) {
      for (var j = 0; j < pcaDim; j++) {
        means[j] += row[j];
      }
    }
    for (var j = 0; j < pcaDim; j++) {
      means[j] /= nv;
    }
    for (final row in validRows) {
      for (var i = 0; i < pcaDim; i++) {
        final di = row[i] - means[i];
        for (var j = 0; j < pcaDim; j++) {
          covDist[i * pcaDim + j] += di * (row[j] - means[j]);
        }
      }
    }
    for (var i = 0; i < pcaDim * pcaDim; i++) {
      covDist[i] /= (nv - 1);
    }
  }

  // 逐块马氏距离平均（块内 NaN 用均值替换）。
  final avgCov = Float64List(pcaDim * pcaDim);
  for (var i = 0; i < pcaDim * pcaDim; i++) {
    avgCov[i] = (ilniqeCovPris[i] + covDist[i]) / 2;
  }
  final swP = Stopwatch()..start();
  final invCov = _pinvSymmetric(avgCov, pcaDim);
  print('pinv: ${swP.elapsedMilliseconds}ms');
  var scoreSum = 0.0;
  for (final row in finalFeatures) {
    final diff = Float64List(pcaDim);
    for (var j = 0; j < pcaDim; j++) {
      final v = row[j].isNaN ? muDist[j] : row[j];
      diff[j] = v - ilniqeMuPris[j];
    }
    var q = 0.0;
    for (var i = 0; i < pcaDim; i++) {
      var acc = 0.0;
      for (var j = 0; j < pcaDim; j++) {
        acc += invCov[i * pcaDim + j] * diff[j];
      }
      q += diff[i] * acc;
    }
    scoreSum += math.sqrt(q < 0 ? 0 : q);
  }
  return scoreSum / finalFeatures.length;
}
