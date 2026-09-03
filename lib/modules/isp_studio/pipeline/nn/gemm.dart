/// 单线程 cache/寄存器分块 sGEMM（纯 Dart，无 Flutter 依赖）。
///
/// C[M,N] = alpha · op(A)[M,K] · op(B)[K,N] + beta · C，行主序。
/// op(X) 由 transX 决定：false 表示按存储原样，true 表示按转置读取
///（transA 时 A 存储为 [K,M]，transB 时 B 存储为 [N,K]）。
///
/// 实现要点：
/// - 非 transB：B 按 4 列条带打包（panel packing，见 [packBStride]），
///   A 行流式读取，微内核为 4×4 寄存器块（16 个 double 累加器驻留
///   局部变量，全 K 一次累加后写回 C，C 每元素仅读/写一次）。
/// - transB：B 按 [N,K] 行连续，无需打包，同样 4×4 寄存块点积内核。
/// - 累加用 double（Float32List 读写自动按 fp32 舍入），比 fp32 逐步
///   累加精度更高；每个输出元素的 k 维累加顺序固定（kk 升序、单次
///   写回），与 M 维切分无关，因此 NnPool 并行结果与单线程位级一致。
///
/// [blockM]/[blockK] 保留仅为 API 兼容（当前实现全 K 寄存器累加，
/// 不再沿 K 分块）；[blockN] 为打包面板宽度。
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// 微内核列条带宽度（打包 B 面板每条带的列数）。
const int gemmPackNR = 4;

const int _mr = 4;

/// 打包 B 面板的行跨度（每条带占 [k]×[gemmPackNR] 个连续元素）。
int packBStride(int k) => k * gemmPackNR;

/// 分块 sGEMM。
///
/// [a]/[b]/[c] 为完整缓冲区，[aOffset]/[bOffset]/[cOffset] 为各自
/// 矩阵在缓冲区中的起始偏移（便于对大张量的子块直接运算，避免拷贝）。
/// [blockN] 为打包面板宽度（列方向 cache 块）。
void sgemm(
  Float32List a,
  Float32List b,
  Float32List c,
  int m,
  int n,
  int k, {
  bool transA = false,
  bool transB = false,
  double alpha = 1.0,
  double beta = 0.0,
  int aOffset = 0,
  int bOffset = 0,
  int cOffset = 0,
  int blockM = 64,
  int blockN = 128,
  int blockK = 64,
}) {
  if (m <= 0 || n <= 0) {
    return;
  }
  if (!transB) {
    // 打包面板宽度取 blockN，至少一个条带。
    final panelCols = math.max(gemmPackNR, math.min(blockN, n));
    final bp = Float32List(packBStride(k) * ((panelCols + gemmPackNR - 1) ~/ gemmPackNR));
    for (var j0 = 0; j0 < n; j0 += panelCols) {
      final jb = math.min(panelCols, n - j0);
      packBPanel(b, bOffset, k, n, j0, jb, bp);
      sgemmPackedB(a, bp, c, m, jb, k,
          transA: transA,
          alpha: alpha,
          beta: beta,
          aOffset: aOffset,
          cOffset: cOffset + j0,
          cLd: n);
    }
  } else {
    _sgemmTransB(a, b, c, m, n, k, transA, alpha, beta, aOffset, bOffset,
        cOffset);
  }
}

/// 将 B[kk][j0..j0+jb)（行主序 [K,N]，起始偏移 [bOffset]）打包进
/// [bp]：按 [gemmPackNR] 列一条带，带内 k 主序连续，条带之间按
/// [packBStride](k) 步进；不足一条带的尾列补 0。
///
/// kk 为外圈，B 按行顺序流式读取；写落在 L2 常驻的 [bp] 面板上。
void packBPanel(Float32List b, int bOffset, int k, int n, int j0, int jb,
    Float32List bp) {
  final stride = packBStride(k);
  final fullStrips = jb >> 2;
  final rem = jb & 3;
  var bi = bOffset + j0;
  for (var kk = 0; kk < k; kk++, bi += n) {
    var p = kk * gemmPackNR;
    var q = bi;
    for (var s = 0; s < fullStrips; s++, p += stride, q += gemmPackNR) {
      bp[p] = b[q];
      bp[p + 1] = b[q + 1];
      bp[p + 2] = b[q + 2];
      bp[p + 3] = b[q + 3];
    }
    if (rem != 0) {
      for (var t = 0; t < gemmPackNR; t++) {
        bp[p + t] = t < rem ? b[q + t] : 0.0;
      }
    }
  }
}

/// 以打包好的 B 面板 [bp]（布局见 [packBPanel]）计算
/// C[i][cOffset + i*cLd + j] = alpha·Σ_k op(A)[i,k]·Bpanel[k,j] + beta·C，
/// 其中 j ∈ [0, jb)（面板列可能按 [gemmPackNR] 补零，补零列不写回）。
///
/// 4 行 × [gemmPackNR] 列寄存器微内核，全 K 用 double 局部累加器一次
/// 累加后写回；m 方向余数行走 1×[gemmPackNR] 内核。逐元素累加顺序与
/// m 无关，故 M 维任意切分（NnPool 并行）结果位级一致。
void sgemmPackedB(
  Float32List a,
  Float32List bp,
  Float32List c,
  int m,
  int jb,
  int k, {
  bool transA = false,
  double alpha = 1.0,
  double beta = 0.0,
  int aOffset = 0,
  int cOffset = 0,
  int cLd = 0,
}) {
  final stride = packBStride(k);
  final strips = (jb + gemmPackNR - 1) >> 2;
  // A 元素 (i, kk) 地址：transA 时 aOffset + kk*m + i，否则 aOffset + i*k + kk。
  final aRowStep = transA ? 1 : k;
  final aKStep = transA ? m : 1;
  final hasBeta = beta != 0.0;
  // A 行块打包 scratch：4 行按 k 主序交错（ap[kk*4+di] = A[i+di, kk]），
  // 使微内核内 A 读连续、与 B 面板同样顺序流。
  final ap = Float32List(k * _mr);

  var i = 0;
  // 主循环：4 行一块。
  for (; i + _mr <= m; i += _mr) {
    // 打包 A 行块（每面板每行块一次，代价 m×k，相对计算可忽略）。
    var ai = aOffset + i * aRowStep;
    var q = 0;
    for (var kk = 0; kk < k; kk++) {
      ap[q] = a[ai];
      ap[q + 1] = a[ai + aRowStep];
      ap[q + 2] = a[ai + aRowStep * 2];
      ap[q + 3] = a[ai + aRowStep * 3];
      ai += aKStep;
      q += _mr;
    }
    final cRow = cOffset + i * cLd;
    for (var s = 0; s < strips; s++) {
      var av = 0;
      var p = s * stride;
      var acc00 = 0.0, acc01 = 0.0, acc02 = 0.0, acc03 = 0.0;
      var acc10 = 0.0, acc11 = 0.0, acc12 = 0.0, acc13 = 0.0;
      var acc20 = 0.0, acc21 = 0.0, acc22 = 0.0, acc23 = 0.0;
      var acc30 = 0.0, acc31 = 0.0, acc32 = 0.0, acc33 = 0.0;
      for (var kk = 0; kk < k; kk++) {
        final a0 = ap[av];
        final a1 = ap[av + 1];
        final a2 = ap[av + 2];
        final a3 = ap[av + 3];
        av += _mr;
        final b0 = bp[p];
        final b1 = bp[p + 1];
        final b2 = bp[p + 2];
        final b3 = bp[p + 3];
        p += gemmPackNR;
        acc00 += a0 * b0;
        acc01 += a0 * b1;
        acc02 += a0 * b2;
        acc03 += a0 * b3;
        acc10 += a1 * b0;
        acc11 += a1 * b1;
        acc12 += a1 * b2;
        acc13 += a1 * b3;
        acc20 += a2 * b0;
        acc21 += a2 * b1;
        acc22 += a2 * b2;
        acc23 += a2 * b3;
        acc30 += a3 * b0;
        acc31 += a3 * b1;
        acc32 += a3 * b2;
        acc33 += a3 * b3;
      }
      final jWidth = math.min(gemmPackNR, jb - s * gemmPackNR);
      _storeTile4(c, cRow + s * gemmPackNR, cLd, jWidth, alpha, beta, hasBeta, acc00, acc01,
          acc02, acc03, acc10, acc11, acc12, acc13, acc20, acc21, acc22,
          acc23, acc30, acc31, acc32, acc33);
    }
  }
  // m 方向余数行：1×NR 内核。
  for (; i < m; i++) {
    final aBase = aOffset + i * aRowStep;
    final cRow = cOffset + i * cLd;
    for (var s = 0; s < strips; s++) {
      var ai = aBase;
      var p = s * stride;
      var acc0 = 0.0, acc1 = 0.0, acc2 = 0.0, acc3 = 0.0;
      for (var kk = 0; kk < k; kk++) {
        final a0 = a[ai];
        ai += aKStep;
        acc0 += a0 * bp[p];
        acc1 += a0 * bp[p + 1];
        acc2 += a0 * bp[p + 2];
        acc3 += a0 * bp[p + 3];
        p += gemmPackNR;
      }
      final jBase = s * gemmPackNR;
      final jWidth = math.min(gemmPackNR, jb - jBase);
      if (jWidth > 0) {
        c[cRow + jBase] =
            hasBeta ? alpha * acc0 + beta * c[cRow + jBase] : alpha * acc0;
      }
      if (jWidth > 1) {
        c[cRow + jBase + 1] = hasBeta
            ? alpha * acc1 + beta * c[cRow + jBase + 1]
            : alpha * acc1;
      }
      if (jWidth > 2) {
        c[cRow + jBase + 2] = hasBeta
            ? alpha * acc2 + beta * c[cRow + jBase + 2]
            : alpha * acc2;
      }
      if (jWidth > 3) {
        c[cRow + jBase + 3] = hasBeta
            ? alpha * acc3 + beta * c[cRow + jBase + 3]
            : alpha * acc3;
      }
    }
  }
}

/// 4×4 累加块写回 C（[jWidth] < 4 时只写前 [jWidth] 列）。
void _storeTile4(
  Float32List c,
  int cRow,
  int cLd,
  int jWidth,
  double alpha,
  double beta,
  bool hasBeta,
  double acc00,
  double acc01,
  double acc02,
  double acc03,
  double acc10,
  double acc11,
  double acc12,
  double acc13,
  double acc20,
  double acc21,
  double acc22,
  double acc23,
  double acc30,
  double acc31,
  double acc32,
  double acc33,
) {
  if (jWidth == gemmPackNR && !hasBeta) {
    // 快路径：整块覆盖写。
    c[cRow] = alpha * acc00;
    c[cRow + 1] = alpha * acc01;
    c[cRow + 2] = alpha * acc02;
    c[cRow + 3] = alpha * acc03;
    c[cRow + cLd] = alpha * acc10;
    c[cRow + cLd + 1] = alpha * acc11;
    c[cRow + cLd + 2] = alpha * acc12;
    c[cRow + cLd + 3] = alpha * acc13;
    final cRow2 = cRow + cLd * 2;
    c[cRow2] = alpha * acc20;
    c[cRow2 + 1] = alpha * acc21;
    c[cRow2 + 2] = alpha * acc22;
    c[cRow2 + 3] = alpha * acc23;
    final cRow3 = cRow2 + cLd;
    c[cRow3] = alpha * acc30;
    c[cRow3 + 1] = alpha * acc31;
    c[cRow3 + 2] = alpha * acc32;
    c[cRow3 + 3] = alpha * acc33;
    return;
  }
  for (var di = 0; di < _mr; di++) {
    final base = cRow + di * cLd;
    final a0 = di == 0
        ? acc00
        : di == 1
            ? acc10
            : di == 2
                ? acc20
                : acc30;
    final a1 = di == 0
        ? acc01
        : di == 1
            ? acc11
            : di == 2
                ? acc21
                : acc31;
    final a2 = di == 0
        ? acc02
        : di == 1
            ? acc12
            : di == 2
                ? acc22
                : acc32;
    final a3 = di == 0
        ? acc03
        : di == 1
            ? acc13
            : di == 2
                ? acc23
                : acc33;
    if (jWidth > 0) {
      c[base] = hasBeta ? alpha * a0 + beta * c[base] : alpha * a0;
    }
    if (jWidth > 1) {
      c[base + 1] = hasBeta ? alpha * a1 + beta * c[base + 1] : alpha * a1;
    }
    if (jWidth > 2) {
      c[base + 2] = hasBeta ? alpha * a2 + beta * c[base + 2] : alpha * a2;
    }
    if (jWidth > 3) {
      c[base + 3] = hasBeta ? alpha * a3 + beta * c[base + 3] : alpha * a3;
    }
  }
}

/// transB 路径：B 按 [N,K] 存储（行连续）。4×4 寄存器块点积内核，
/// A、B 各 4 条顺序流，全 K double 累加后写回。
void _sgemmTransB(
  Float32List a,
  Float32List b,
  Float32List c,
  int m,
  int n,
  int k,
  bool transA,
  double alpha,
  double beta,
  int aOffset,
  int bOffset,
  int cOffset,
) {
  // A 元素 (i, kk) 地址：transA 时 aOffset + kk*m + i，否则 aOffset + i*k + kk。
  final aRowStep = transA ? 1 : k;
  final aKStep = transA ? m : 1;
  final aRowStep2 = aRowStep * 2;
  final aRowStep3 = aRowStep * 3;
  final k2 = k * 2;
  final k3 = k * 3;
  final hasBeta = beta != 0.0;

  var i = 0;
  for (; i + _mr <= m; i += _mr) {
    final aBase = aOffset + i * aRowStep;
    var j = 0;
    for (; j + gemmPackNR <= n; j += gemmPackNR) {
      final bBase = bOffset + j * k;
      var ai = aBase;
      var bi = bBase;
      var acc00 = 0.0, acc01 = 0.0, acc02 = 0.0, acc03 = 0.0;
      var acc10 = 0.0, acc11 = 0.0, acc12 = 0.0, acc13 = 0.0;
      var acc20 = 0.0, acc21 = 0.0, acc22 = 0.0, acc23 = 0.0;
      var acc30 = 0.0, acc31 = 0.0, acc32 = 0.0, acc33 = 0.0;
      for (var kk = 0; kk < k; kk++) {
        final a0 = a[ai];
        final a1 = a[ai + aRowStep];
        final a2 = a[ai + aRowStep2];
        final a3 = a[ai + aRowStep3];
        ai += aKStep;
        final b0 = b[bi];
        final b1 = b[bi + k];
        final b2 = b[bi + k2];
        final b3 = b[bi + k3];
        bi++;
        acc00 += a0 * b0;
        acc01 += a0 * b1;
        acc02 += a0 * b2;
        acc03 += a0 * b3;
        acc10 += a1 * b0;
        acc11 += a1 * b1;
        acc12 += a1 * b2;
        acc13 += a1 * b3;
        acc20 += a2 * b0;
        acc21 += a2 * b1;
        acc22 += a2 * b2;
        acc23 += a2 * b3;
        acc30 += a3 * b0;
        acc31 += a3 * b1;
        acc32 += a3 * b2;
        acc33 += a3 * b3;
      }
      _storeTile4(c, cOffset + i * n + j, n, gemmPackNR, alpha, beta,
          hasBeta, acc00, acc01, acc02, acc03, acc10, acc11, acc12, acc13,
          acc20, acc21, acc22, acc23, acc30, acc31, acc32, acc33);
    }
    // n 方向余数列：逐列点积。
    for (; j < n; j++) {
      final bRow = bOffset + j * k;
      for (var di = 0; di < _mr; di++) {
        var ai = aBase + di * aRowStep;
        var bi = bRow;
        var sum = 0.0;
        for (var kk = 0; kk < k; kk++) {
          sum += a[ai] * b[bi];
          ai += aKStep;
          bi++;
        }
        final ci = cOffset + (i + di) * n + j;
        c[ci] = hasBeta ? alpha * sum + beta * c[ci] : alpha * sum;
      }
    }
  }
  // m 方向余数行。
  for (; i < m; i++) {
    final aRow = aOffset + i * aRowStep;
    for (var j = 0; j < n; j++) {
      var ai = aRow;
      var bi = bOffset + j * k;
      var sum = 0.0;
      for (var kk = 0; kk < k; kk++) {
        sum += a[ai] * b[bi];
        ai += aKStep;
        bi++;
      }
      final ci = cOffset + i * n + j;
      c[ci] = hasBeta ? alpha * sum + beta * c[ci] : alpha * sum;
    }
  }
}
