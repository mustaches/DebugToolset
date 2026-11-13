/// 色温调节器 IP 的**运行期控制与测量**定点参考实现。
///
/// 与 `color_temp.dart` 的关系：那里是 PC 侧（预览/导出）的 FP64 模型，
/// 参数在编译期烘焙；这里是 IP 里的硬件通路——目标色温由 14 位端口
/// `cct_in` 运行期给出，实测色温由硬件对输入帧统计后从 14 位端口
/// `cct_out` 输出，CCM（von Kries 对角增益）由内部自动算出、不对外
/// 暴露参数。
///
/// **全部整数运算**，与生成的 Verilog（`codegen/color_temp_ctrl_verilog.dart`）
/// 与 golden 模型逐位一致：
///
/// - 白点表：512 段覆盖整个 14 位域（段宽 32 K、网格偏移 8 K，
///   索引 = (K-8)>>5），
///   Q16 端点 + 线性插值；端点值由 FP64 公式 [cctToWhitePoint] 烘焙。
/// - 倒数表：Q16 白点值（步长 512，索引 = v>>9）→ Q30 倒数，线性插值，
///   用于「目标白点 / 参考白点」的通道增益比——避免硬件除法器。
/// - 测量：帧累加和 → sRGB→XYZ（Q16 系数）→ McCamy 色度比 → 一次整数
///   除法（长除法，硬件里是逐位减法）→ Q14 定点三次多项式，钳位
///   1800~12000 K。
///
/// 相对 FP64 模型的偏差：增益 ≈0.1%（表插值），测量色温 ≤3 K（Q14 的 n
/// 与三次项截断）——IP 与预览的差异属于定点化口径，测试里对两者都断言。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'color_temp.dart';

/// 14 位色温端口的满量程（K 值上限 16383，实际有效 1800~12000）。
const int kCtPortMax = (1 << 14) - 1;

/// 白点表段宽（K）：索引 = K >> 5，共 513 个端点（含末端点）。
const int kCtSegShift = 5;

/// 网格偏移（K）：段边界取 K ≡ 8 (mod 32)，让 6600（Tanner Helland 公式
/// r 通道 t<=66 / t>66 的分段点，阶跃约 2%）恰好落在**节点**上，避免跨
/// 断点的 32K 段把这条阶跃插值抹平（实测该段误差 8 LSB，其余 ≤2 LSB）。
const int kCtSegBias = 8;
const int kCtSegCount = ((kCtPortMax - kCtSegBias) >> kCtSegShift) + 2;

/// 白点表下标对应的开尔文值（端点）。
///
/// 端点按段边界取真实色温（不钳到 1800）——否则目标/参考恰好落在 1800 时
/// 会与上一段端点（1792，实际会钳成 1800）插值，低色温段 b 白点很小，
/// 这点偏差会被增益比放大到 3 LSB。公式在 1000K 以下失效，故下限取 1000。
int ctTableKelvin(int index) =>
    ((index << kCtSegShift) + kCtSegBias).clamp(1000, kColorTempMax);

/// Tanner Helland 白点 —— **单一分支**形式（仅供表烘焙用）。
///
/// [cctToWhitePoint]（FP64 预览口径）在 t=66（6600K）处三段公式全部换
/// 分支，r 通道有 ~1.9%、b 通道有 ~1.4% 的台阶。硬件表若用跨断点的
/// 32K 段插值会把这条台阶抹平（实测该段偏差 8 LSB），因此硬件按
/// [ctBranchKelvin] 选两套表：下支（log 形式，t<=66）与上支（pow 形式，
/// t>66），各自在自身分支内连续，插值误差降到 ≤2 LSB。
///
/// [upper] 为 true 时用 t>66 的 pow 形式（可外推到 6600K 以下，仅用于
/// 表烘焙填充，实际不会被查表命中）。
List<double> _whitePointBranch(int kelvin, {required bool upper}) {
  final t = kelvin.clamp(1000, 12000) / 100.0;
  final r = upper
      ? 329.698727446 * math.pow(math.max(t, 66.0001) - 60, -0.1332047592)
      : 255.0;
  final g = upper
      ? 288.1221695283 * math.pow(math.max(t, 66.0001) - 60, -0.0755148492)
      : 99.4708025861 * math.log(t) - 161.1195681661;
  final b = upper
      ? 255.0
      : (t <= 19 ? 0.0 : 138.5177312231 * math.log(t - 10) - 305.0447927307);
  final gc = g.clamp(1.0, 255.0);
  return [r.clamp(0.0, 255.0) / gc, 1.0, b.clamp(0.0, 255.0) / gc];
}

/// 白点公式的分支边界（t=66）：k <= 6600 用下支表，其余用上支表。
const int ctBranchKelvin = 6600;

/// 烘焙白点表（Q16，索引见 [ctTableKelvin]），[upper] 选分支。
///
/// 返回 (r, b) 两张表；g 通道恒为 1（白点归一化到 G=1），只需两张表。
/// Q16 精度是必要的：低色温段 b 通道白点很小（2000K 约 0.10），参考色温
/// 落在这里时低精度表的量化误差会被增益比放大到 2~3 LSB。
(List<int>, List<int>) ctWhiteTablesQ16({bool upper = false}) {
  final r = List<int>.filled(kCtSegCount, 0);
  final b = List<int>.filled(kCtSegCount, 0);
  for (var i = 0; i < kCtSegCount; i++) {
    final wp = _whitePointBranch(ctTableKelvin(i), upper: upper);
    r[i] = (wp[0] * 65536).round().clamp(0, 1 << 19);
    b[i] = (wp[2] * 65536).round().clamp(0, 1 << 19);
  }
  return (r, b);
}

/// 四张表的打包结果（下支 r/b + 上支 r/b），供 golden 与 RTL 共用。
class CtWhiteTables {
  final List<int> lowerR, lowerB, upperR, upperB;
  final List<int> recip;
  CtWhiteTables._(this.lowerR, this.lowerB, this.upperR, this.upperB,
      this.recip);

  factory CtWhiteTables() {
    final lo = ctWhiteTablesQ16();
    final up = ctWhiteTablesQ16(upper: true);
    return CtWhiteTables._(lo.$1, lo.$2, up.$1, up.$2, ctRecipTableQ30());
  }
}

/// 倒数表：Q16 白点值 → Q30 倒数（`2^30 / v`），步长 512、线性插值。
/// 下标 = v >> 9；v < 512 时钳到 512（白点为 0 的极端色温，增益取上限）。
const int kCtRecipShift = 9;
const int kCtRecipCount = (1 << 19) >> kCtRecipShift;

List<int> ctRecipTableQ30() {
  final t = List<int>.filled(kCtRecipCount, 0);
  for (var i = 0; i < kCtRecipCount; i++) {
    // 下标 0 也按 512 计（查表时 v 已钳到 >=512），免得表项超出 24 位。
    final v = math.max(1 << kCtRecipShift, i << kCtRecipShift);
    t[i] = ((1 << 30) / v).round().clamp(0, (1 << 24) - 1);
  }
  return t;
}

/// 定点白点查表（与 RTL 的 `ct_lookup` 逐位一致）：
/// `y = (y0*(S-f) + y1*f + S/2) >> shift`（S = 2^shift、shift = kCtSegShift），
/// 索引 = (K - kCtSegBias) >> shift。
int _lookupWhite(List<int> table, int kelvin) {
  final k = (kelvin - kCtSegBias).clamp(0, kCtPortMax - kCtSegBias);
  final i = (k >> kCtSegShift).clamp(0, kCtSegCount - 2);
  final f = k & ((1 << kCtSegShift) - 1);
  final y0 = table[i];
  final y1 = table[i + 1];
  return (y0 * ((1 << kCtSegShift) - f) + y1 * f + (1 << (kCtSegShift - 1))) >>
      kCtSegShift;
}

/// 定点倒数查表（与 RTL 的 `ct_recip` 逐位一致）。
int _recipQ(List<int> table, int v) {
  final vv = v.clamp(1 << kCtRecipShift, (kCtRecipCount - 1) << kCtRecipShift);
  final i = vv >> kCtRecipShift;
  final f = vv & ((1 << kCtRecipShift) - 1);
  final y0 = table[i];
  final y1 = table[i + 1];
  return (y0 * ((1 << kCtRecipShift) - f) +
          y1 * f +
          (1 << (kCtRecipShift - 1))) >>
      kCtRecipShift;
}

/// 14 位目标色温 + 14 位参考（测量）色温 → Q14 三通道增益（g 恒 16384）。
///
/// `gain = white(target)[c] / white(ref)[c]`，除法用烘焙倒数表实现
///（`(wt_q16 * 2^30/wr_q16 + 32768) >> 16`）；结果钳位到 [0, 65535]
///（Q14 上限 4.0；FP64 在低参考色温下 b 白点为 0 会得到 inf，硬件按 4.0
/// 饱和）。6600K 两侧按 [ctBranchKelvin] 选各自分支的表。与 RTL、golden
/// 逐位一致。
List<int> ctGainsQ14(
  int targetKelvin,
  int referenceKelvin, {
  CtWhiteTables? tables,
}) {
  final t = tables ?? CtWhiteTables();
  int gain(List<int> lo, List<int> up, int target, int reference) {
    final tc = target.clamp(kColorTempMin, kColorTempMax);
    final rc = reference.clamp(kColorTempMin, kColorTempMax);
    // 目标==参考即恒等：短路掉表插值的 ±1~2 LSB 残差（低色温白点很小，
    // 倒数插值放大误差），也与「同色温不该改变画质」的语义一致。
    if (tc == rc) return 16384;
    final wt = _lookupWhite(tc > ctBranchKelvin ? up : lo, tc);
    final wr = _lookupWhite(rc > ctBranchKelvin ? up : lo, rc);
    final g = (wt * _recipQ(t.recip, wr) + 32768) >> 16;
    return g.clamp(0, 65535);
  }

  return [
    gain(t.lowerR, t.upperR, targetKelvin, referenceKelvin),
    16384,
    gain(t.lowerB, t.upperB, targetKelvin, referenceKelvin),
  ];
}

// ---------------------------------------------------------------------------
// 测量（固定点 McCamy）
// ---------------------------------------------------------------------------

/// McCamy 色度比 `n = A/B` 的**合并系数**（Q16），由 sRGB→XYZ 矩阵与
/// `x = X/S`、`y = Y/S` 预先合成：
///   A = (0.332 - x)·S = 0.332·S − X，B = (y − 0.1858)·S = Y − 0.1858·S
/// 直接对帧累加和做线性组合，省掉 X/Y/Z/S 的中间舍入与 12 次宽乘法（6 次即可）。
/// 与 LUT 版本（先算 X/Y/Z 再组合）差 ≤1 K。
const List<int> kCtCoefA = [-13008, 2500, 14351];
const List<int> kCtCoefB = [6088, 32356, -9918];

/// 三次多项式系数（Q16 域，见库注释的推导）。
const int kCtPolyC3 = 449;
const int kCtPolyC2 = 3525;
/// n 项系数：取 6823.0（原式 6823.3，差 0.3 K）——6823 的二进制只有 7 个 1 位，
/// 硬件移位加比 6823.3 的 23 位常数省一半 LUT。`(kCtPolyC1 * n) >> 8` = 6823*n*4。
const int kCtPolyC1 = 6823 * 1024;
/// 常数项：取 5520.0（原式 5520.33，差 0.33 K）。
const int kCtPolyConstQ16 = 5520 * 65536;

/// 一帧的 R/G/B 累加和 → 固定点 McCamy 色温（K）。
///
/// 与 RTL 的测量 FSM 逐位一致：
/// 1. `X/Y/Z = (Σc*S[c] + 32768) >> 16`；
/// 2. `S = X+Y+Z`；`A = (0.332*S) - X`，`B = Y - (0.1858*S)`；
/// 3. `B <= 0` 或 `S == 0`（全黑）→ 返回 null（RTL 保持上一次测量）；
/// 4. `nq = sign(A) * ((|A| << 14) / B)`（整数除，向零截断）；
/// 5. `cct = ((449*nq³ >> 26) + (3525*nq² >> 12) + (C1*nq >> 8) +
///    Const + 32768) >> 16`，钳位到 1800~12000。
int? ctMeasureCct(int sumR, int sumG, int sumB) {
  if (sumR == 0 && sumG == 0 && sumB == 0) return null;
  int lin(List<int> c) =>
      (c[0] * sumR + c[1] * sumG + c[2] * sumB + 32768) >> 16;
  final a = lin(kCtCoefA);
  final b = lin(kCtCoefB);
  if (b <= 0) return null;
  final aMag = a.abs();
  // |nq| 钳到 32767：与 RTL 一致（真实 n 在 ±0.6 内，钳位只为防极端色度溢出）。
  final nqMag = ((aMag << 14) ~/ b).clamp(0, 32767);
  final nq = a < 0 ? -nqMag : nqMag;
  final n2 = nq * nq;
  final n3 = n2 * nq;
  final q16 = ((kCtPolyC3 * n3) >> 26) +
      ((kCtPolyC2 * n2) >> 12) +
      ((kCtPolyC1 * nq) >> 8) +
      kCtPolyConstQ16;
  final cct = (q16 + 32768) >> 16;
  return cct.clamp(kColorTempMin, kColorTempMax);
}

/// 定点测量相对 FP64 [measureCctMean] 的偏差（测试用）。
int? measureCctMeanFixed(int sumR, int sumG, int sumB, int count) {
  if (count <= 0) return null;
  final rgba = Uint8List(4);
  // 仅用于对照：把累加和折算回平均色，直接调用 FP64 路径。
  rgba[0] = (sumR / count).round().clamp(0, 255);
  rgba[1] = (sumG / count).round().clamp(0, 255);
  rgba[2] = (sumB / count).round().clamp(0, 255);
  rgba[3] = 255;
  return measureCctFromRgba(rgba, 1, 1);
}
