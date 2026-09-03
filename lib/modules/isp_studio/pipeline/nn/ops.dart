/// 神经网络基础算子（纯 Dart，无 Flutter 依赖），语义与 torch 严格一致。
///
/// 全部为同步纯函数；输入输出均为 [NnTensor]（图像算子为 4 维 NCHW）。
/// 与 torch 的对拍黄金值见 test/golden/nn_ops_golden.{json,nnw}，
/// 测试在 test/isp_nn_ops_test.dart。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'gemm.dart';
import 'tensor.dart';

/// conv2d 输出空间尺寸（torch floor 模式）。
int convOutSize(int size, int kernel, int stride, int pad) =>
    (size + 2 * pad - kernel) ~/ stride + 1;

/// torch F.conv2d（NCHW）：weight [cout, cin/groups, kh, kw]，可选 bias，
/// 显式零 padding，支持非对称 kernel（1x7/7x1）与 groups（含 depthwise
/// 特化路径）。im2col + sGEMM 实现。
NnTensor conv2d(
  NnTensor x,
  NnTensor weight, {
  Float32List? bias,
  int strideH = 1,
  int strideW = 1,
  int padH = 0,
  int padW = 0,
  int groups = 1,
}) {
  if (x.rank != 4 || weight.rank != 4) {
    throw ArgumentError('conv2d 需要 4 维 NCHW 输入与 [cout,cin,kh,kw] 权重');
  }
  final n = x.batch, cin = x.channels, h = x.height, w = x.width;
  final cout = weight.shape[0], cpg = weight.shape[1];
  final kh = weight.shape[2], kw = weight.shape[3];
  if (cin % groups != 0 || cout % groups != 0 || cpg * groups != cin) {
    throw ArgumentError('conv2d: groups=$groups 与 cin=$cin/cout=$cout/'
        'weight=$cpg 不匹配');
  }
  final oh = convOutSize(h, kh, strideH, padH);
  final ow = convOutSize(w, kw, strideW, padW);
  if (oh <= 0 || ow <= 0) {
    throw ArgumentError('conv2d: 输出尺寸非正 ($oh x $ow)');
  }
  final out = NnTensor.zeros([n, cout, oh, ow]);
  final s = oh * ow;
  final opg = cout ~/ groups;

  if (groups == cin && cpg == 1) {
    // depthwise 特化：每组 1 个输入通道，直接滑窗，不做 im2col。
    for (var b = 0; b < n; b++) {
      for (var g = 0; g < groups; g++) {
        final xC = (b * cin + g) * h * w;
        for (var o = 0; o < opg; o++) {
          final wBase = (g * opg + o) * kh * kw;
          final oBase = (b * cout + g * opg + o) * s;
          for (var oy = 0; oy < oh; oy++) {
            final iy0 = oy * strideH - padH;
            var oi = oBase + oy * ow;
            for (var ox = 0; ox < ow; ox++, oi++) {
              final ix0 = ox * strideW - padW;
              var sum = 0.0;
              for (var r = 0; r < kh; r++) {
                final iy = iy0 + r;
                if (iy < 0 || iy >= h) {
                  continue;
                }
                final xRow = xC + iy * w;
                final wRow = wBase + r * kw;
                for (var c2 = 0; c2 < kw; c2++) {
                  final ix = ix0 + c2;
                  if (ix >= 0 && ix < w) {
                    sum += x.data[xRow + ix] * weight.data[wRow + c2];
                  }
                }
              }
              out.data[oi] = sum;
            }
          }
        }
      }
    }
  } else if (kh == 1 &&
      kw == 1 &&
      strideH == 1 &&
      strideW == 1 &&
      padH == 0 &&
      padW == 0 &&
      groups == 1) {
    // 1x1/s1/p0 快路径：im2col 结果就是 x 本身（NCHW 布局天然满足），
    // 直接 gemm W[cout,cin] @ x[b][cin, H*W] → out[b][cout, H*W]。
    for (var b = 0; b < n; b++) {
      sgemm(weight.data, x.data, out.data, cout, s, cin,
          bOffset: b * cin * s, cOffset: b * cout * s);
    }
  } else {
    // 通用卷积：im2col-on-the-fly + 打包面板 gemm。不物化完整 cols
    // 矩阵（大特征图下可达数百 MB），而是按列块把 im2col 结果直接
    // 打包进 B 面板 scratch（布局同 packBPanel），再调 sgemmPackedB。
    // cols 行序 k=(ci,r,c2) 与原实现一致；结果 [opg,s] 与输出 NCHW
    // 布局一致，直接写入 out 对应通道段。
    final k = cpg * kh * kw;
    const panelCols = 128;
    final bp = Float32List(
        packBStride(k) * ((panelCols + gemmPackNR - 1) ~/ gemmPackNR));
    for (var b = 0; b < n; b++) {
      for (var g = 0; g < groups; g++) {
        final xGroup = (b * cin + g * cpg) * h * w;
        for (var j0 = 0; j0 < s; j0 += panelCols) {
          final jb = math.min(panelCols, s - j0);
          _packIm2colPanel(x.data, xGroup, h, w, cpg, kh, kw, strideH,
              strideW, padH, padW, ow, j0, jb, bp);
          sgemmPackedB(weight.data, bp, out.data, opg, jb, k,
              aOffset: g * opg * k,
              cOffset: (b * cout + g * opg) * s + j0,
              cLd: s);
        }
      }
    }
  }

  if (bias != null) {
    for (var b = 0; b < n; b++) {
      for (var c = 0; c < cout; c++) {
        final base = (b * cout + c) * s;
        final bv = bias[c];
        for (var i = 0; i < s; i++) {
          out.data[base + i] += bv;
        }
      }
    }
  }
  return out;
}

/// conv2d 通用路径的 im2col 面板打包：把虚拟 cols 矩阵的
/// [k=(ci,r,c2)] 行、列区间 [j0, j0+jb)（j = oy*ow + ox 为输出空间
/// 线性索引）按 [packBPanel] 的条带布局写入 [bp]，值即 x 的滑窗采样
/// （越界补 0，语义与原物化 cols 的实现一致）；尾条带不足
/// [gemmPackNR] 列的车道补 0。
///
/// 循环按输出行 oy 切段，段内 ix 随 j 线性递增；strideW==1 且段内
/// ix 全部有效时走无边界判断的顺序读快路径。
void _packIm2colPanel(
  Float32List x,
  int xGroup,
  int h,
  int w,
  int cpg,
  int kh,
  int kw,
  int strideH,
  int strideW,
  int padH,
  int padW,
  int ow,
  int j0,
  int jb,
  Float32List bp,
) {
  final k = cpg * kh * kw;
  final k4 = packBStride(k);
  final strips = (jb + gemmPackNR - 1) >> 2;
  final jLimit = j0 + jb;
  final oy0 = j0 ~/ ow;
  final oy1 = (jLimit - 1) ~/ ow;

  var kk = 0;
  for (var ci = 0; ci < cpg; ci++) {
    final xC = xGroup + ci * h * w;
    for (var r = 0; r < kh; r++) {
      for (var c2 = 0; c2 < kw; c2++, kk++) {
        final kkBase = kk * gemmPackNR;
        var j = j0;
        for (var oy = oy0; oy <= oy1 && j < jLimit; oy++) {
          final jSegEnd = math.min(jLimit, (oy + 1) * ow);
          final iy = oy * strideH + r - padH;
          // 列 j 的面板内索引 jj 与写入位置 p 的映射：
          // p = (jj>>2)*k4 + kk*4 + (jj&3)。
          var jj = j - j0;
          if (iy < 0 || iy >= h) {
            for (; j < jSegEnd; j++, jj++) {
              bp[(jj >> 2) * k4 + kkBase + (jj & 3)] = 0.0;
            }
            continue;
          }
          final xRow = xC + iy * w;
          var ix = (j - oy * ow) * strideW + c2 - padW;
          if (strideW == 1 && ix >= 0 && ix + (jSegEnd - j) <= w) {
            // 快路径：段内 ix 连续且全部有效，顺序读。
            var src = xRow + ix;
            for (; j < jSegEnd; j++, jj++, src++) {
              bp[(jj >> 2) * k4 + kkBase + (jj & 3)] = x[src];
            }
          } else {
            for (; j < jSegEnd; j++, jj++, ix += strideW) {
              bp[(jj >> 2) * k4 + kkBase + (jj & 3)] =
                  (ix >= 0 && ix < w) ? x[xRow + ix] : 0.0;
            }
          }
        }
      }
    }
  }
  // 尾条带不足 gemmPackNR 列时，补零车道（避免残留上一面板的数据）。
  final rem = jb & (gemmPackNR - 1);
  if (rem != 0) {
    final stripBase = (strips - 1) * k4;
    for (var kk2 = 0; kk2 < k; kk2++) {
      final p = stripBase + kk2 * gemmPackNR;
      for (var t = rem; t < gemmPackNR; t++) {
        bp[p + t] = 0.0;
      }
    }
  }
}

/// torch F.linear：y = x @ weightᵀ + bias，x [..., in]，weight [out, in]。
NnTensor linear(NnTensor x, NnTensor weight, {Float32List? bias}) {
  final inF = weight.shape[1], outF = weight.shape[0];
  if (x.shape.last != inF) {
    throw ArgumentError('linear: 输入末维 ${x.shape.last} != in_features $inF');
  }
  final rows = x.numel ~/ inF;
  final out = NnTensor.zeros([...x.shape.sublist(0, x.rank - 1), outF]);
  sgemm(x.data, weight.data, out.data, rows, outF, inF, transB: true);
  if (bias != null) {
    for (var r = 0; r < rows; r++) {
      final base = r * outF;
      for (var j = 0; j < outF; j++) {
        out.data[base + j] += bias[j];
      }
    }
  }
  return out;
}

/// torch relu（返回新张量）。
NnTensor relu(NnTensor x) {
  final out = NnTensor.zeros(x.shape);
  for (var i = 0; i < x.numel; i++) {
    final v = x.data[i];
    out.data[i] = v > 0.0 ? v : 0.0;
  }
  return out;
}

/// torch gelu approximate='none'（精确 erf 版，double 计算后舍入 fp32）。
NnTensor gelu(NnTensor x) {
  const invSqrt2 = 0.7071067811865476; // 1/sqrt(2)
  final out = NnTensor.zeros(x.shape);
  for (var i = 0; i < x.numel; i++) {
    final v = x.data[i];
    out.data[i] = 0.5 * v * (1.0 + erf(v * invSqrt2));
  }
  return out;
}

/// torch F.max_pool2d（NCHW），padding 以 -inf 参与。
NnTensor maxPool2d(NnTensor x, int kernelH, int kernelW, int strideH,
    int strideW, int padH, int padW) {
  final n = x.batch, c = x.channels, h = x.height, w = x.width;
  final oh = convOutSize(h, kernelH, strideH, padH);
  final ow = convOutSize(w, kernelW, strideW, padW);
  final out = NnTensor.zeros([n, c, oh, ow]);
  final s = oh * ow;
  for (var b = 0; b < n; b++) {
    for (var ch = 0; ch < c; ch++) {
      final xC = (b * c + ch) * h * w;
      final oC = (b * c + ch) * s;
      for (var oy = 0; oy < oh; oy++) {
        final iy0 = oy * strideH - padH;
        var oi = oC + oy * ow;
        for (var ox = 0; ox < ow; ox++, oi++) {
          final ix0 = ox * strideW - padW;
          var best = double.negativeInfinity;
          for (var r = 0; r < kernelH; r++) {
            final iy = iy0 + r;
            if (iy < 0 || iy >= h) {
              continue;
            }
            final xRow = xC + iy * w;
            for (var c2 = 0; c2 < kernelW; c2++) {
              final ix = ix0 + c2;
              if (ix >= 0 && ix < w) {
                final v = x.data[xRow + ix];
                if (v > best) {
                  best = v;
                }
              }
            }
          }
          out.data[oi] = best;
        }
      }
    }
  }
  return out;
}

/// torch F.avg_pool2d（NCHW），countIncludePad 两种语义：
/// 分母按 torch 的 pool_size（窗口与 [0, H+pad)×[0, W+pad) 的交集，
/// 再视 countIncludePad 决定是否为有效区交集）。
NnTensor avgPool2d(NnTensor x, int kernelH, int kernelW, int strideH,
    int strideW, int padH, int padW, {bool countIncludePad = true}) {
  final n = x.batch, c = x.channels, h = x.height, w = x.width;
  final oh = convOutSize(h, kernelH, strideH, padH);
  final ow = convOutSize(w, kernelW, strideW, padW);
  final out = NnTensor.zeros([n, c, oh, ow]);
  final s = oh * ow;
  for (var b = 0; b < n; b++) {
    for (var ch = 0; ch < c; ch++) {
      final xC = (b * c + ch) * h * w;
      final oC = (b * c + ch) * s;
      for (var oy = 0; oy < oh; oy++) {
        var oi = oC + oy * ow;
        for (var ox = 0; ox < ow; ox++, oi++) {
          final hs0 = oy * strideH - padH;
          final ws0 = ox * strideW - padW;
          final poolH = math.min(hs0 + kernelH, h + padH) - hs0;
          final poolW = math.min(ws0 + kernelW, w + padW) - ws0;
          final hs = math.max(hs0, 0);
          final ws = math.max(ws0, 0);
          final he = math.min(hs0 + kernelH, h);
          final we = math.min(ws0 + kernelW, w);
          final div =
              countIncludePad ? poolH * poolW : (he - hs) * (we - ws);
          var sum = 0.0;
          for (var iy = hs; iy < he; iy++) {
            final xRow = xC + iy * w;
            for (var ix = ws; ix < we; ix++) {
              sum += x.data[xRow + ix];
            }
          }
          out.data[oi] = sum / div;
        }
      }
    }
  }
  return out;
}

/// torch F.adaptive_avg_pool2d(x, (1,1))：逐通道全局均值。
NnTensor adaptiveAvgPool1x1(NnTensor x) {
  final n = x.batch, c = x.channels, s = x.height * x.width;
  final out = NnTensor.zeros([n, c, 1, 1]);
  for (var b = 0; b < n; b++) {
    for (var ch = 0; ch < c; ch++) {
      final base = (b * c + ch) * s;
      var sum = 0.0;
      for (var i = 0; i < s; i++) {
        sum += x.data[base + i];
      }
      out.data[b * c + ch] = sum / s;
    }
  }
  return out;
}

/// torch F.interpolate(mode='bilinear', align_corners=False)（NCHW），
/// 半像素规则：src = (dst + 0.5) * scale - 0.5，scale = in/out。
NnTensor resizeBilinear(NnTensor x, int outH, int outW) {
  final n = x.batch, c = x.channels, h = x.height, w = x.width;
  final out = NnTensor.zeros([n, c, outH, outW]);
  final scaleH = h / outH, scaleW = w / outW;
  for (var b = 0; b < n; b++) {
    for (var ch = 0; ch < c; ch++) {
      final xC = (b * c + ch) * h * w;
      final oC = (b * c + ch) * outH * outW;
      for (var oy = 0; oy < outH; oy++) {
        var fy = (oy + 0.5) * scaleH - 0.5;
        if (fy < 0) {
          fy = 0;
        }
        final y0 = fy.floor();
        final y1 = math.min(y0 + 1, h - 1);
        final ly = fy - y0;
        final r0 = xC + y0 * w, r1 = xC + y1 * w;
        var oi = oC + oy * outW;
        for (var ox = 0; ox < outW; ox++, oi++) {
          var fx = (ox + 0.5) * scaleW - 0.5;
          if (fx < 0) {
            fx = 0;
          }
          final x0 = fx.floor();
          final x1 = math.min(x0 + 1, w - 1);
          final lx = fx - x0;
          final top = x.data[r0 + x0] * (1 - lx) + x.data[r0 + x1] * lx;
          final bot = x.data[r1 + x0] * (1 - lx) + x.data[r1 + x1] * lx;
          out.data[oi] = top * (1 - ly) + bot * ly;
        }
      }
    }
  }
  return out;
}

/// torch F.interpolate(mode='bicubic', align_corners=False, antialias=False)
/// （NCHW）。半像素规则 + Keys 三次卷积核 a=-0.75（torch 固定值，注意
/// 并非 Catmull-Rom 的 a=-0.5），越界索引 clamp 到边缘，权重不归一化。
NnTensor resizeBicubic(NnTensor x, int outH, int outW) {
  const a = -0.75;
  double cubicW(double t) {
    t = t.abs();
    if (t <= 1.0) {
      return ((a + 2) * t - (a + 3)) * t * t + 1.0;
    }
    if (t < 2.0) {
      return (((t - 5) * a) * t + 8 * a) * t - 4 * a;
    }
    return 0.0;
  }

  final n = x.batch, c = x.channels, h = x.height, w = x.width;
  final out = NnTensor.zeros([n, c, outH, outW]);
  final scaleH = h / outH, scaleW = w / outW;
  final wy = List<double>.filled(outH * 4, 0.0);
  final iy = List<int>.filled(outH * 4, 0);
  final wx = List<double>.filled(outW * 4, 0.0);
  final ix = List<int>.filled(outW * 4, 0);
  for (var oy = 0; oy < outH; oy++) {
    final fy = (oy + 0.5) * scaleH - 0.5;
    final y0 = fy.floor();
    for (var t = 0; t < 4; t++) {
      wy[oy * 4 + t] = cubicW(fy - (y0 - 1 + t));
      iy[oy * 4 + t] = (y0 - 1 + t).clamp(0, h - 1);
    }
  }
  for (var ox = 0; ox < outW; ox++) {
    final fx = (ox + 0.5) * scaleW - 0.5;
    final x0 = fx.floor();
    for (var t = 0; t < 4; t++) {
      wx[ox * 4 + t] = cubicW(fx - (x0 - 1 + t));
      ix[ox * 4 + t] = (x0 - 1 + t).clamp(0, w - 1);
    }
  }
  for (var b = 0; b < n; b++) {
    for (var ch = 0; ch < c; ch++) {
      final xC = (b * c + ch) * h * w;
      final oC = (b * c + ch) * outH * outW;
      for (var oy = 0; oy < outH; oy++) {
        var oi = oC + oy * outW;
        for (var ox = 0; ox < outW; ox++, oi++) {
          var sum = 0.0;
          for (var r = 0; r < 4; r++) {
            final rowBase = xC + iy[oy * 4 + r] * w;
            var rowSum = 0.0;
            for (var t = 0; t < 4; t++) {
              rowSum += wx[ox * 4 + t] * x.data[rowBase + ix[ox * 4 + t]];
            }
            sum += wy[oy * 4 + r] * rowSum;
          }
          out.data[oi] = sum;
        }
      }
    }
  }
  return out;
}

/// torch F.layer_norm：对末尾 normalizedShape 维归一化（biased 方差），
/// 再按 weight/bias 仿射。
NnTensor layerNorm(NnTensor x, List<int> normalizedShape,
    Float32List? weight, Float32List? bias,
    {double eps = 1e-5}) {
  var d = 1;
  for (final s in normalizedShape) {
    d *= s;
  }
  final rows = x.numel ~/ d;
  if (rows * d != x.numel) {
    throw ArgumentError('layerNorm: normalizedShape $normalizedShape '
        '与输入 $x 不匹配');
  }
  final out = NnTensor.zeros(x.shape);
  for (var r = 0; r < rows; r++) {
    final base = r * d;
    var mean = 0.0;
    for (var i = 0; i < d; i++) {
      mean += x.data[base + i];
    }
    mean /= d;
    var varSum = 0.0;
    for (var i = 0; i < d; i++) {
      final v = x.data[base + i] - mean;
      varSum += v * v;
    }
    final inv = 1.0 / math.sqrt(varSum / d + eps);
    for (var i = 0; i < d; i++) {
      var v = (x.data[base + i] - mean) * inv;
      if (weight != null) {
        v *= weight[i];
      }
      if (bias != null) {
        v += bias[i];
      }
      out.data[base + i] = v;
    }
  }
  return out;
}

/// torch F.group_norm（NCHW）：每组 (C/groups)×空间 归一化（biased 方差），
/// 再按通道仿射。
NnTensor groupNorm(NnTensor x, int groups, Float32List? weight,
    Float32List? bias,
    {double eps = 1e-5}) {
  final n = x.batch, c = x.channels;
  final spatial = x.numel ~/ (n * c);
  if (c % groups != 0) {
    throw ArgumentError('groupNorm: C=$c 不能整除 groups=$groups');
  }
  final cpg = c ~/ groups;
  final block = cpg * spatial;
  final out = NnTensor.zeros(x.shape);
  for (var b = 0; b < n; b++) {
    for (var g = 0; g < groups; g++) {
      final base = (b * c + g * cpg) * spatial;
      var mean = 0.0;
      for (var i = 0; i < block; i++) {
        mean += x.data[base + i];
      }
      mean /= block;
      var varSum = 0.0;
      for (var i = 0; i < block; i++) {
        final v = x.data[base + i] - mean;
        varSum += v * v;
      }
      final inv = 1.0 / math.sqrt(varSum / block + eps);
      for (var ci = 0; ci < cpg; ci++) {
        final ch = g * cpg + ci;
        final wv = weight != null ? weight[ch] : 1.0;
        final bv = bias != null ? bias[ch] : 0.0;
        final cBase = base + ci * spatial;
        for (var i = 0; i < spatial; i++) {
          out.data[cBase + i] = (x.data[cBase + i] - mean) * inv * wv + bv;
        }
      }
    }
  }
  return out;
}

/// torch F.softmax(dim=-1)：沿最后一维。
NnTensor softmax(NnTensor x) {
  final d = x.shape.last;
  final rows = x.numel ~/ d;
  final out = NnTensor.zeros(x.shape);
  for (var r = 0; r < rows; r++) {
    final base = r * d;
    var maxV = double.negativeInfinity;
    for (var i = 0; i < d; i++) {
      final v = x.data[base + i];
      if (v > maxV) {
        maxV = v;
      }
    }
    var sum = 0.0;
    for (var i = 0; i < d; i++) {
      final e = math.exp(x.data[base + i] - maxV);
      out.data[base + i] = e;
      sum += e;
    }
    for (var i = 0; i < d; i++) {
      out.data[base + i] = out.data[base + i] / sum;
    }
  }
  return out;
}

/// LPIPS normalize_tensor 口径：沿 C 维 L2 归一化，
/// out = x / (sqrt(Σ_c x²) + eps)（eps 加在根号外）。
NnTensor l2NormalizeChannels(NnTensor x, {double eps = 1e-10}) {
  final n = x.batch, c = x.channels;
  final s = x.numel ~/ (n * c);
  final out = NnTensor.zeros(x.shape);
  for (var b = 0; b < n; b++) {
    final xN = b * c * s;
    final oN = b * c * s;
    for (var i = 0; i < s; i++) {
      var sumSq = 0.0;
      for (var ch = 0; ch < c; ch++) {
        final v = x.data[xN + ch * s + i];
        sumSq += v * v;
      }
      final norm = math.sqrt(sumSq) + eps;
      for (var ch = 0; ch < c; ch++) {
        out.data[oN + ch * s + i] = x.data[xN + ch * s + i] / norm;
      }
    }
  }
  return out;
}

/// DISTS L2pooling 用的 3×3 Hanning 核（单通道）。
const List<double> distsHanningKernel3x3 = [
  0.0625, 0.125, 0.0625, //
  0.125, 0.25, 0.125,
  0.0625, 0.125, 0.0625,
];

/// DISTS 的 L2pooling：x² → depthwise 3×3 Hanning 核 conv（s2/p1）
/// → sqrt(out + sqrtEps)。[weight] 为 [C,1,3,3] 的 depthwise 核，
/// 缺省用常量 Hanning 核生成。
NnTensor l2PoolingDists(NnTensor x,
    {Float32List? weight, double sqrtEps = 1e-12}) {
  final c = x.channels;
  final sq = NnTensor.zeros(x.shape);
  for (var i = 0; i < x.numel; i++) {
    final v = x.data[i];
    sq.data[i] = v * v;
  }
  Float32List filt;
  if (weight != null) {
    filt = weight;
  } else {
    filt = Float32List(c * 9);
    for (var ch = 0; ch < c; ch++) {
      for (var i = 0; i < 9; i++) {
        filt[ch * 9 + i] = distsHanningKernel3x3[i];
      }
    }
  }
  final pooled = conv2d(sq, NnTensor(filt, [c, 1, 3, 3]),
      strideH: 2, strideW: 2, padH: 1, padW: 1, groups: c);
  for (var i = 0; i < pooled.numel; i++) {
    pooled.data[i] = math.sqrt(pooled.data[i] + sqrtEps);
  }
  return pooled;
}

/// torch torch.cat(dim=1)：沿 C 维拼接 4 维 NCHW 张量。
NnTensor concatChannels(List<NnTensor> tensors) {
  if (tensors.isEmpty) {
    throw ArgumentError('concatChannels: 空列表');
  }
  final n = tensors.first.batch;
  final h = tensors.first.height, w = tensors.first.width;
  var cAll = 0;
  for (final t in tensors) {
    if (t.rank != 4 || t.batch != n || t.height != h || t.width != w) {
      throw ArgumentError('concatChannels: 形状不一致: ${t.shape}');
    }
    cAll += t.channels;
  }
  final out = NnTensor.zeros([n, cAll, h, w]);
  final s = h * w;
  for (var b = 0; b < n; b++) {
    var cOff = 0;
    for (final t in tensors) {
      final tc = t.channels;
      final dst = (b * cAll + cOff) * s;
      final src = b * tc * s;
      out.data.setRange(dst, dst + tc * s, t.data, src);
      cOff += tc;
    }
  }
  return out;
}

/// 2 维 matmul：[M,K] × [K,N] → [M,N]。
NnTensor matmul(NnTensor a, NnTensor b) {
  if (a.rank != 2 || b.rank != 2 || a.shape[1] != b.shape[0]) {
    throw ArgumentError('matmul: 形状不匹配 ${a.shape} × ${b.shape}');
  }
  final m = a.shape[0], k = a.shape[1], n = b.shape[1];
  final out = NnTensor.zeros([m, n]);
  sgemm(a.data, b.data, out.data, m, n, k);
  return out;
}

/// batchMatmul（attention 用）：[B,M,K] × [B,K,N] → [B,M,N]。
NnTensor batchMatmul(NnTensor a, NnTensor b) {
  if (a.rank != 3 || b.rank != 3 ||
      a.shape[0] != b.shape[0] ||
      a.shape[2] != b.shape[1]) {
    throw ArgumentError('batchMatmul: 形状不匹配 ${a.shape} × ${b.shape}');
  }
  final bs = a.shape[0], m = a.shape[1], k = a.shape[2], n = b.shape[2];
  final out = NnTensor.zeros([bs, m, n]);
  for (var i = 0; i < bs; i++) {
    sgemm(a.data, b.data, out.data, m, n, k,
        aOffset: i * m * k, bOffset: i * k * n, cOffset: i * m * n);
  }
  return out;
}

/// TensorFlow SAME 的精确 padding 计算（MUSIQ 阶段用）：
/// out = ceil(h/s)，pad_total = max((out-1)*s + k - h, 0)，
/// 前 = pad_total // 2，后 = pad_total - 前。
({int outH, int outW, int padTop, int padBottom, int padLeft, int padRight})
    exactPaddingTfSame(int h, int w, int kH, int kW, int sH, int sW) {
  final outH = (h + sH - 1) ~/ sH;
  final outW = (w + sW - 1) ~/ sW;
  final padTotalH = math.max((outH - 1) * sH + kH - h, 0);
  final padTotalW = math.max((outW - 1) * sW + kW - w, 0);
  final padTop = padTotalH ~/ 2;
  final padLeft = padTotalW ~/ 2;
  return (
    outH: outH,
    outW: outW,
    padTop: padTop,
    padBottom: padTotalH - padTop,
    padLeft: padLeft,
    padRight: padTotalW - padLeft,
  );
}

/// erf 误差函数：fdlibm（FreeBSD msun s_erf.c）的 Dart 移植，
/// double 全程误差 ~1e-16，远小于与 torch erf 对拍所需的 1e-7。
double erf(double x) {
  const tiny = 1e-300;
  const erx = 8.45062911510467529297e-01;
  const pp0 = 1.28379167095512558561e-01;
  const pp1 = -3.25042107247001499370e-01;
  const pp2 = -2.84817495755985104766e-02;
  const pp3 = -5.77027029648944159157e-03;
  const pp4 = -2.37630166566501626084e-05;
  const qq1 = 3.97917223959155352819e-01;
  const qq2 = 6.50222499887672944485e-02;
  const qq3 = 5.08130628187576562776e-03;
  const qq4 = 1.32494738004321644526e-04;
  const qq5 = -3.96022827877536812320e-06;
  const pa0 = -2.36211856075265944077e-03;
  const pa1 = 4.14856118683748335566e-01;
  const pa2 = -3.72207876035701323847e-01;
  const pa3 = 3.18346619901161753674e-01;
  const pa4 = -1.10894694282396677476e-01;
  const pa5 = 3.54783043256182359371e-02;
  const pa6 = -2.16637559486879084300e-03;
  const qa1 = 1.06420880400844228286e-01;
  const qa2 = 5.40397917702171048937e-01;
  const qa3 = 7.18286544141962662868e-02;
  const qa4 = 1.26171219808761642112e-01;
  const qa5 = 1.36370839120290507362e-02;
  const qa6 = 1.19844998467991074170e-02;
  const ra0 = -9.86494403484714822705e-03;
  const ra1 = -6.93858572707181789572e-01;
  const ra2 = -1.05586262253232909814e+01;
  const ra3 = -6.23753324503260060396e+01;
  const ra4 = -1.62396669462573470355e+02;
  const ra5 = -1.84605092906711035994e+02;
  const ra6 = -8.12874355063065934246e+01;
  const ra7 = -9.81432934416914548592e+00;
  const sa1 = 1.96512716674392571292e+01;
  const sa2 = 1.37657754143519042600e+02;
  const sa3 = 4.34565877475229228821e+02;
  const sa4 = 6.45387271733267880336e+02;
  const sa5 = 4.29008140027567833386e+02;
  const sa6 = 1.08635005541779435134e+02;
  const sa7 = 6.57024977031928170135e+00;
  const sa8 = -6.04244152148580987438e-02;
  const rb0 = -9.86494292470009928597e-03;
  const rb1 = -7.99283237680523006574e-01;
  const rb2 = -1.77579549177547519889e+01;
  const rb3 = -1.60636384885821916062e+02;
  const rb4 = -6.37566443368689627778e+02;
  const rb5 = -1.02509513161107724954e+03;
  const rb6 = -4.83519191608651397019e+02;
  const sb1 = 3.03380607434824582924e+01;
  const sb2 = 3.25792512996573918826e+02;
  const sb3 = 1.53672958608443695994e+03;
  const sb4 = 3.19985821950859553908e+03;
  const sb5 = 2.55305040643316442583e+03;
  const sb6 = 4.74528541206955367215e+02;
  const sb7 = -2.24409524465858183362e+01;

  if (x.isNaN) {
    return double.nan;
  }
  final ax = x.abs();
  if (ax < 0.84375) {
    if (ax < 3.725290298461914e-09) {
      // |x| < 2^-28
      return 0.125 * (8.0 * x + pp0 * x);
    }
    final z = x * x;
    final r = pp0 + z * (pp1 + z * (pp2 + z * (pp3 + z * pp4)));
    final s = 1.0 + z * (qq1 + z * (qq2 + z * (qq3 + z * (qq4 + z * qq5))));
    return x + x * (r / s);
  }
  if (ax < 1.25) {
    final s = ax - 1.0;
    final p =
        pa0 + s * (pa1 + s * (pa2 + s * (pa3 + s * (pa4 + s * (pa5 + s * pa6)))));
    final q = 1.0 +
        s * (qa1 + s * (qa2 + s * (qa3 + s * (qa4 + s * (qa5 + s * qa6)))));
    return x >= 0 ? erx + p / q : -erx - p / q;
  }
  if (ax >= 6.0) {
    return x >= 0 ? 1.0 - tiny : tiny - 1.0;
  }
  final s = 1.0 / (ax * ax);
  double r, sDen;
  if (ax < 2.857142857142857) {
    // |x| < 1/0.35
    r = ra0 +
        s * (ra1 +
            s * (ra2 +
                s * (ra3 +
                    s * (ra4 +
                        s * (ra5 + s * (ra6 + s * ra7))))));
    sDen = 1.0 +
        s * (sa1 +
            s * (sa2 +
                s * (sa3 +
                    s * (sa4 +
                        s * (sa5 +
                            s * (sa6 + s * (sa7 + s * sa8)))))));
  } else {
    r = rb0 +
        s * (rb1 +
            s * (rb2 +
                s * (rb3 + s * (rb4 + s * (rb5 + s * rb6)))));
    sDen = 1.0 +
        s * (sb1 +
            s * (sb2 +
                s * (sb3 +
                    s * (sb4 +
                        s * (sb5 + s * (sb6 + s * sb7))))));
  }
  // z = ax 清零低 32 位（fdlibm 的 SET_LOW_WORD(z,0)）。
  _bitsBuf.setFloat64(0, ax);
  _bitsBuf.setUint64(
      0, _bitsBuf.getUint64(0) & 0xFFFFFFFF00000000);
  final z = _bitsBuf.getFloat64(0);
  final rr = math.exp(-z * z - 0.5625) *
      math.exp((z - ax) * (z + ax) + r / sDen);
  return x >= 0 ? 1.0 - rr / ax : rr / ax - 1.0;
}

final ByteData _bitsBuf = ByteData(8);
