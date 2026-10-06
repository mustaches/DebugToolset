/// 编组 C 代码导出的目标 CPU（编组右键菜单「查看C代码/查看黑盒子C代码」
/// 按目标拆分）。
///
/// 目标只影响生成物的架构相关部分：lut_fixed 整行函数的 SIMD 变体
/// （ARM 目标为 NEON + 标量双变体，x86 目标为 SSE2 + 标量双变体，两者
/// 均与标量逐位一致）与文件头注释块（目标特征/推荐编译选项/定点建议）；
/// 其余生成代码为纯标量 C99，与目标无关、数值口径不变。
library;

/// 允许单节点编组的节点类型：编组后即可经右键菜单查看/导出 C 代码。
/// `multi_band_eq` 为既有例外（等效多个色彩控制器混叠）；其余为有整行
/// 行核（`<id>_row` NEON/SSE2 行核）的类型——单节点独占阶段走整行行核。
/// 与 `_rowNodeId`（group_c_export_bb.dart）的类型判断保持同步扩展。
const Set<String> kSingleNodeGroupTypeIds = {
  'multi_band_eq',
  'csc_rgb2yuv',
  'csc_yuv2rgb',
  'csc_hsl2rgb',
  'csc_rgb2hsl',
  'white_balance',
  'ccm',
  'levels_curves',
  'color_temp_adjuster',
  'pseudo_color',
  'highlight',
  'gamma',
  'sat_bright_adjuster',
  'black_level',
  'color_controller',
};

/// 编组导出目标 CPU 族（标签 key 以 `@<name>` 后缀携带，见
/// isp_studio_state.dart 的 openGroupCodeTab/openGroupBlackBoxCodeTab）。
enum GroupCTarget {
  /// Cortex-A32/A34/A35：ARMv8-A 顺序小核，可 AArch32 双态。
  cortexA32_35,

  /// Cortex-A53/A55：AArch64 顺序小核（默认目标，与既有生成物最接近）。
  cortexA53_55,

  /// Cortex-A72/A73/A75/A76/A77/A78：AArch64 乱序大核。
  cortexA72_78,

  /// Cortex-A510/A520：ARMv9 顺序小核。
  cortexA510_520,

  /// Cortex-A710/A715/A720/A725：ARMv9 乱序大核。
  cortexA710_725,

  /// x86/x64（SSE2 基线）。
  x86,
}

/// 目标 CPU 的展示与生成元数据。
extension GroupCTargetInfo on GroupCTarget {
  /// 菜单/页头显示名。
  String get displayName => switch (this) {
        GroupCTarget.cortexA32_35 => 'Cortex-A32/A34/A35',
        GroupCTarget.cortexA53_55 => 'Cortex-A53/A55',
        GroupCTarget.cortexA72_78 => 'Cortex-A72/A73/A75/A76/A77/A78',
        GroupCTarget.cortexA510_520 => 'Cortex-A510/A520',
        GroupCTarget.cortexA710_725 => 'Cortex-A710/A715/A720/A725',
        GroupCTarget.x86 => 'x86（SSE2）',
      };

  /// 标签页标题短名。
  String get tabShort => switch (this) {
        GroupCTarget.cortexA32_35 => 'A32/35',
        GroupCTarget.cortexA53_55 => 'A53/55',
        GroupCTarget.cortexA72_78 => 'A72-78',
        GroupCTarget.cortexA510_520 => 'A510/520',
        GroupCTarget.cortexA710_725 => 'A710-725',
        GroupCTarget.x86 => 'x86',
      };

  bool get isArm => this != GroupCTarget.x86;
  bool get isX86 => this == GroupCTarget.x86;

  /// 架构特征一句话（顺序/乱序、FP64 SIMD 强弱、AArch32 双态）。
  String get archNote => switch (this) {
        GroupCTarget.cortexA32_35 =>
          'ARMv8-A 顺序执行小核，可 AArch32 双态（AArch32 下 NEON 由 __ARM_NEON__ 预定义），FP64 SIMD 弱',
        GroupCTarget.cortexA53_55 =>
          'ARMv8.2-A AArch64 顺序执行小核，NEON FP64 仅标量级吞吐（FP64 SIMD 弱）',
        GroupCTarget.cortexA72_78 => 'AArch64 乱序执行大核，NEON FP64 SIMD 完整',
        GroupCTarget.cortexA510_520 => 'ARMv9 顺序执行小核，FP64 SIMD 弱',
        GroupCTarget.cortexA710_725 => 'ARMv9 乱序执行大核，FP64 SIMD 完整',
        GroupCTarget.x86 => 'x86/x64 基线 SSE2（x64 恒含 SSE2）',
      };

  /// 推荐编译选项（写入文件头注释）。
  String get cFlags => switch (this) {
        GroupCTarget.cortexA32_35 => '-mcpu=cortex-a35 -mfpu=neon -O2',
        GroupCTarget.cortexA53_55 => '-mcpu=cortex-a55 -O2',
        GroupCTarget.cortexA72_78 => '-mcpu=cortex-a76 -O2',
        GroupCTarget.cortexA510_520 => '-mcpu=cortex-a520 -O2',
        GroupCTarget.cortexA710_725 => '-mcpu=cortex-a725 -O2',
        GroupCTarget.x86 => '-msse2 -O2（MSVC /arch:SSE2；x64 恒含 SSE2）',
      };

  /// FP64 SIMD 弱（顺序小核）：LUT 模式建议 lut_fixed（Q14 定点）。
  bool get fp64Weak => switch (this) {
        GroupCTarget.cortexA32_35 ||
        GroupCTarget.cortexA53_55 ||
        GroupCTarget.cortexA510_520 =>
          true,
        _ => false,
      };

  /// 文件头注释的目标块（每行带 ` * ` 前缀，直接嵌入现有块注释）。
  List<String> headerBlock() => [
        ' * 目标 CPU：$displayName（$archNote）。',
        ' * 推荐编译选项：$cFlags',
        if (fp64Weak)
          ' * FP64 SIMD 弱：LUT 模式建议 codegenMode=lut_fixed（Q14 定点，避免逐像素 FP64 乘加）。',
      ];

  /// 本目标的 SIMD 变体名（micro 文档/注释复用）。
  String get simdKind => isX86 ? 'SSE2' : 'NEON';

  /// 微架构说明文档文件名（`<slug>_code_micro.md`，随 C 代码一并导出）。
  String get microDocName {
    final slug = switch (this) {
      GroupCTarget.cortexA32_35 => 'cortex_a32_35',
      GroupCTarget.cortexA53_55 => 'cortex_a53_55',
      GroupCTarget.cortexA72_78 => 'cortex_a72_78',
      GroupCTarget.cortexA510_520 => 'cortex_a510_520',
      GroupCTarget.cortexA710_725 => 'cortex_a710_725',
      GroupCTarget.x86 => 'x86',
    };
    return '${slug}_code_micro.md';
  }
}

/// 生成 `<目标处理器>_code_micro.md`：说明针对该处理器的**加速宏定义**与
/// **加速实现方案**，随 C 代码一并导出。[blackBox] 区分导出变体——整帧版
/// 为标量参考实现（c_ref），SIMD 行核与 OpenMP 行域并行只在黑盒版生效。
String buildTargetCodeMicroDoc(GroupCTarget target, {required bool blackBox}) {
  final simd = target.simdKind;
  final guard = target.isX86
      ? '`__SSE2__` / `_M_X64` / `_M_IX86_FP>=2`'
      : '`__ARM_NEON` / `__ARM_NEON__`';

  // ---- 黑盒整行行核方案表（目标分叉）----
  final deint = target.isX86
      ? '`and`/字节移位/`or` 三路 16 位解交织（SSE2 无 pshufb）'
      : '`VLD3` 解交织';
  final reint = target.isX86 ? '`and`/移位/`or` 三路重交织' : '`VST3` 重交织';
  final gatherNote =
      '标量 gather 查烘焙表（域匹配 `max_value == 烘焙域`，失配标量回退直算，与融合行核逐位一致）';
  final q14 = target.isX86
      ? '`_mm_mul_epu32` 偶/奇 lane 双趟取积低 32 位重组（无 `_mm_mullo_epi32`）→ 偏置 `packs` 窄化'
      : 'int16 通道 `vaddq_s16`/`vbslq_s16` 色环回绕 → 32 位 `vmulq_s32`/`vshrq_n_s32` Q14 乘加 → `vminq`/`vmaxq` 钳位 → `vmovn` 窄化';
  final cscQ16 = target.isX86
      ? 'Q16 定点 int32 乘加（`_mm_mul_epu32` 低 32 位重组）→ 偏置右移 → 钳位 → `packs`'
      : 'Q16 定点 int32 乘加（`vmovl` + `vmulq_s32`/`vmlaq_s32`）→ `vshrq_n_s32` 偏置右移 → 钳位 → `vmovn`';
  final ccm64 = target.isX86
      ? '`_mm_mul_epu32` int64 累加（负系数取 |m| 乘再 `sub_epi64` 显式取负——64 位积对负系数非有符号积）→ 2^63 偏置还原算术 `>>20`（无 `_mm_srai_epi64`）→ 提取低 32 位 → int32 钳位 → `packs`'
      : '`vmull_n_s32`/`vmlal_n_s32` int64 累加 → `vshrq_n_s64` 算术 `>>20` → `vmovn_s64` 收窄 int32 → 钳位（AArch32 无 64 位比较，钳位在 32 位域）→ `vmovn`';
  final gammaImpl = target.isX86
      ? '解交织 → 钳上界（`min_epu16` 经 `subs`/`sub` 模拟——SSE2 无 min_epu16）→ gather 运行期 LUT → `unpacklo_epi8` 两对 + `unpack_epi16` 两半 4 通道字节重交织（无 pshufb）'
      : '`VLD3` 解交织 → `vminq_u16` 钳上界 → gather 运行期 LUT → `VST4`（RGBA，alpha 恒 255）';
  final fp64Note = target.isX86
      ? 'FP64 双像素（双分支都算 + 掩码选择、混合分母后单除法，`isp_csc_clamp2` 与 `bb_clamp_to` 逐位一致）'
      : '（本目标无 FP64 SIMD：保持融合行核标量，OpenMP 行域并行已覆盖）';
  final List<String> rowTable = [
    '| 节点（模式） | 形态 | $simd 实现要点 |',
    '|---|---|---|',
    '| multi_band_eq（lut_fixed） | HSL 3ch→3ch | $deint → $gatherNote → $q14 → $reint；与 FP64 口径偏差 ≤1 LSB、与标量变体逐位一致 |',
    '| multi_band_eq（lut） | HSL 3ch→3ch | 标量行核（FP64 三表 + compose 回退；收益为整行函数化 + 行域并行） |',
    '| csc_rgb2yuv / csc_yuv2rgb | RGB↔YUV 3ch→3ch | $deint → $cscQ16 → $reint（系数随生成期烘焙；`max_value ≤ 32767` SIMD 域保证） |',
    '| ccm | RGB 3ch→3ch | $deint → $ccm64 → $reint（Q20 矩阵 int64 累加，|m| ≤ INT32_MAX 生成期守卫） |',
    '| white_balance / levels_curves / color_temp / pseudo_color / highlight clip | LUT gather 类 | $deint → $gatherNote → $reint（pseudo_color 为 mono→RGB 1→3 形态：`VLD1`/`_mm_loadu` 载入） |',
    '| gamma | RGB 3ch→4ch 8bit | $gammaImpl；行核带运行期色调映射 LUT 指针形参（top 层 scratch 构建） |',
    '| csc_hsl2rgb / csc_rgb2hsl | HSL↔RGB 3ch→3ch | $fp64Note（复用 `isp_csc_sse.h` 双像素，x86 专属） |',
    '| sat_bright（rgb） | RGB 3ch→3ch | $fp64Note（亮度加权插值 + 双增益，x86 专属） |',
    '| black_level | Bayer 1ch→1ch | $fp64Note（行核带 y 形参——同行两相位偏移常量对；`cmple` 掩码截零 + `cvttpd(v+0.5)` 四舍五入，x86 专属） |',
    '| color_controller（lut） | HSL 3ch→3ch | $fp64Note（H 通道 int32 双像素 gather + 条件回绕、S/L 通道 FP64 双像素 gather 乘子，x86 专属） |',
  ];
  final excludeNote = '''
- **不适用行核**：`bright_contrast`——rgb 形态为亮度比例 FP 路径（`ratio =
  map(round(y))/y` 数据相关除法，无法干净 SIMD 化）；mono/yuv/hsl 单通道
  LUT 形态对单节点编组不可达（无连接时活动端口恒为首端口 `in`=rgb），
  故该节点保持融合行核（OpenMP 行域并行仍生效）。''';
  final buildLine = target.isX86
      ? '- MSVC：`cl /O2 /arch:SSE2 /openmp ...`（x64 恒含 SSE2）\n'
          '- GCC/Clang：`gcc -O2 -msse2 -fopenmp ...`'
      : '- 交叉 gcc：`aarch64-linux-gnu-gcc ${target.cFlags} -fopenmp ...`'
          '（不开 `-fopenmp` 自动串行；`__ARM_NEON` 由 `-mcpu` 自动定义）';
  final accelSection = blackBox
      ? '''
### 3.1 整行 SIMD 行核（$simd，单节点独占编组）
- **适用**：单节点编组（零延迟、无窗口、外部输入→单一外部输出）。阶段整行
  走 `<节点>_row`（SIMD 主循环 + 标量尾双变体，随导出目标分叉；`max_value`
  域不匹配自动标量回退），供 `--dump-hash` 对拍验收——全部与标量融合行核
  逐位一致：

${rowTable.join('\n')}
$excludeNote
### 3.2 OpenMP 行域并行
- **适用**：无行缓冲的编组（`lineBuffers.isEmpty`，即纯线性点操作链，
  无扇出/汇合/窗口物化缓冲）。
- **实现**：top 层 y 循环 `#pragma omp parallel for`（`_OPENMP` 守卫），行间
  无依赖，与线程数无关逐位一致；整行 `<id>_row` 单节点阶段无 x 变量，其余
  加 `private(x)`。
- **排除**：行缓冲/窗口/滑窗/跨行归约类编组不加（scratch 行缓冲多行共享，
  并行会竞态）。

### 3.3 标量回退
- 未命中 SIMD 的路径走标量 C（与 c_ref 循环体逐位一致）；钳位取整用
  `floor(v+0.5)`+进位修正替代 libm `round/lround`，色环回绕用单次条件加减替代 `%`。'''
      : '''
> **本导出为整帧版（标量参考实现，c_ref 算法文件）**：无 SIMD 行核。
> 上述 SIMD 行核与 OpenMP 行域并行仅在「查看黑盒C代码」（行级流水）
> 导出中生效。整帧版主要面向数值对拍/验证；性能关键路径请用黑盒版。''';
  return '''
# ${target.displayName} 目标加速说明（code_micro）

> 本文件由 DebugToolSet ISP Studio 自动生成，随 C 代码一并导出。
> 说明针对该处理器的**加速宏定义**与**加速实现方案**，与生成的 `.h/.c`
> 中的条件编译守卫一一对应。

## 1. 目标处理器

| 项 | 值 |
|---|---|
| 处理器 | ${target.displayName} |
| 架构 | ${target.archNote} |
| 推荐编译选项 | `${target.cFlags}` |
| SIMD 变体 | $simd（整行行核，随导出目标分叉） |
| FP64 SIMD | ${target.fp64Weak ? '弱（仅标量 FPU）→ LUT 模式建议 `codegenMode=lut_fixed`；FP64 形态节点（HSL 转换/sat_bright/black_level/color_controller）保持融合行核' : '完整（FP64 双像素 SSE2 快路径，x86 专属）'} |

## 2. 加速宏定义

### 2.1 编译器守卫宏（编译时自动探测，无需手写）

| 宏 | 含义 | 本目标 |
|---|---|---|
| $guard | 启用 $simd 整行行核 | 是 |
| `_OPENMP` | 启用 OpenMP 行域并行（编译加 `-fopenmp` / `/openmp`） | 可选（开则并行） |

### 2.2 生成的功能宏与烘焙表

| 宏/表 | 含义 |
|---|---|
| `ISP_PIPE_ALIGN8(x)` | 8 字节对齐（scratch 各区分界） |
| `<TOP>_SCRATCH_BYTES(w,h,max_value)` | scratch 竞技场总大小（行缓冲/派生环/gamma LUT 区，无 h 因子） |
| `BB_CSC_CY_R_601` 等 | BT.601 全范围 Q16 定点 CSC 系数（标量与 SIMD 共用） |
| `<节点>_shift_lut` / `<节点>_s_mul_q14` / `<节点>_l_mul_q14` | multi_band_eq lut_fixed Q14 定点表（H 偏移 int16 / S·L 乘子 Q14） |
| `<节点>_m[9]` | ccm Q20 定点矩阵（int64 烘焙，行核内 int32 splat） |
| `<节点>_lut`（levels 4096 级）/ `<节点>_lut_r/g/b`（color_temp、pseudo_color）/ `<节点>_clip_lut`（highlight clip） | LUT 模式烘焙查找表（域 0..烘焙域） |
| `<节点>_shift_lut`/`_s_mul_lut`/`_l_mul_lut` | color_controller LUT 三表（H 偏移 int32 / S·L 乘子 FP64） |
| `<节点>_off[4]` | black_level 四相位偏移（生成期按烘焙 Bayer pattern 解析） |
| `<节点>_lut`（运行期构建） | gamma 色调映射 LUT（top 层 scratch 构建，行核经形参传入） |

## 3. 加速实现方案

$accelSection

## 4. 构建

$buildLine
''';
}
