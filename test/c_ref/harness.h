/**
 * @file harness.h
 * @brief Dart<->C 对拍 harness —— 用例 IO 契约与 op 处理器签名。
 *
 * 用例目录协议（由 Dart 侧 test/c_ref/compare_helper.dart 生成）：
 * - params.txt：`key=value` 行（# 开头为注释行，空行忽略）。
 *   double 用 Dart double.toString() 的最短往返表示，C 侧 strtod 解析
 *   可精确往返；bool 写 0/1；int 直写。
 * - in0.bin / in1.bin ...：小端 uint16 数组（交织多通道帧按行优先展开）。
 * - inRaw0.bin：原始字节流（如 unpack 用例的打包 RAW 输入）。
 * 输出（harness 写回用例目录）：
 * - out0.bin / out1.bin ...：小端 uint16 数组；uint8 流输出（如 tonemap
 *   的 RGBA）经 case_write_out_u8 写字节流。
 * - scalars.txt：标量输出 `key=value`（%.17g），如 wb 增益、色温估计值。
 *
 * 错误约定：op handler 返回 ISP_OK(0) 成功；非零为失败（桩用 -99 表示
 * 「待组代理实现」）。IO 助手失败时返回 NULL/负值并填 io->err。
 *
 * 本 harness 层允许 malloc/free（内核零 malloc 的约束不约束 harness）。
 */

#ifndef C_REF_HARNESS_H
#define C_REF_HARNESS_H

#include <stdint.h>
#include <stddef.h>
#include <stdio.h>

#include "isp_common.h"

#ifdef __cplusplus
extern "C" {
#endif

/** params.txt 最大条目数。 */
#define CASE_MAX_PARAMS 128
/** 错误信息缓冲长度。 */
#define CASE_ERR_LEN 256

/**
 * @brief 用例 IO 上下文：目录、已解析 params、错误信息、scalars 输出。
 */
typedef struct CaseIO {
  /** 用例目录（命令行 argv[2]，无尾部斜杠）。 */
  const char *dir;
  /** params 键/值表（指向内部缓冲，只读）。 */
  char *keys[CASE_MAX_PARAMS];
  char *vals[CASE_MAX_PARAMS];
  int nparams;
  /** 最近一次错误信息（IO 助手填写，main 打印到 stderr）。 */
  char err[CASE_ERR_LEN];
  /** scalars.txt 句柄（首次 case_scalar 时懒打开，main 关闭）。 */
  FILE *scalars_fp;
} CaseIO;

/** op 处理器签名：成功返回 ISP_OK，失败返回非零（桩返回 -99）。 */
typedef int (*OpHandler)(CaseIO *io);

/* ---------------------------------------------------------------------------
 * params 访问器（key 不存在时返回 dflt，不视为错误）
 * ------------------------------------------------------------------------- */

/** 判断参数是否存在。 */
int case_param_has(CaseIO *io, const char *key);
/** 取字符串参数。 */
const char *case_param_str(CaseIO *io, const char *key, const char *dflt);
/** 取 double 参数（strtod 解析，与 Dart toString 精确往返）。 */
double case_param_double(CaseIO *io, const char *key, double dflt);
/** 取 int 参数（strtol 解析；bool 参数写 0/1 也走这里）。 */
int case_param_int(CaseIO *io, const char *key, int dflt);

/* ---------------------------------------------------------------------------
 * 帧 IO（失败返回 NULL/负值并填 io->err）
 * ------------------------------------------------------------------------- */

/**
 * @brief 加载 inN.bin 为小端 uint16 数组（malloc，调用方 free）。
 *
 * @param io           用例上下文。
 * @param idx          输入序号（0 -> in0.bin）。
 * @param expected_len 期望元素个数；文件字节数 != expected_len*2 时报错。
 * @return 像素缓冲，失败返回 NULL。
 */
uint16_t *case_load_in(CaseIO *io, int idx, size_t expected_len);

/**
 * @brief 加载 inRawN.bin 原始字节流（malloc，调用方 free）。
 *
 * @param io           用例上下文。
 * @param idx          输入序号（0 -> inRaw0.bin）。
 * @param expected_len 期望字节数；文件大小不符时报错。
 * @return 字节缓冲，失败返回 NULL。
 */
uint8_t *case_load_in_raw(CaseIO *io, int idx, size_t expected_len);

/** 写 outN.bin（小端 uint16）。成功返回 ISP_OK。 */
int case_write_out(CaseIO *io, int idx, const uint16_t *data, size_t len);
/** 写 outN.bin（uint8 字节流，如 tonemap RGBA）。成功返回 ISP_OK。 */
int case_write_out_u8(CaseIO *io, int idx, const uint8_t *data, size_t len);
/** 追加一条标量输出到 scalars.txt（%.17g）。成功返回 ISP_OK。 */
int case_scalar(CaseIO *io, const char *key, double value);

/**
 * @brief 分配 scratch 缓冲（malloc 封装；失败填 io->err 返回 NULL）。
 *
 * 各 kernel 所需大小见对应头文件的 ISP_XXX_SCRATCH_BYTES 宏。
 */
void *case_scratch(CaseIO *io, size_t bytes);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* C_REF_HARNESS_H */
