/**
 * @file harness.c
 * @brief Dart<->C 对拍 harness —— main、params 解析、帧 IO、op 注册表分发。
 *
 * 用法：c_ref_harness.exe <op> <case_dir>
 * 协议契约见 harness.h 文件头注释。
 *
 * 【组代理接入指引】
 * 1. op 注册表就在本文件 kOpTable，已一次性列全，不要改本文件；
 * 2. 只改自己功能组的 harness_<组>.c：把对应 op 的桩（return -99）
 *    替换为真实实现——从 CaseIO 读 params/in 帧、调 c_ref 内核、写 out/
 *    scalars；scratch 用 case_scratch 按内核头文件的 *_SCRATCH_BYTES 分配；
 * 3. 新增独立测试文件 test/isp_c_ref_compare_<组>_test.dart，经
 *    test/c_ref/compare_helper.dart 的 runCOp 驱动，逐字节断言。
 */

#include "harness.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---------------------------------------------------------------------------
 * op 处理器 extern 声明（实现分散在各 harness_<组>.c）
 * ------------------------------------------------------------------------- */

/* harness_unpack.c */
int op_unpack(CaseIO *io);
/* harness_raw1.c */
int op_black_level(CaseIO *io);
int op_dpc(CaseIO *io);
int op_lsc(CaseIO *io);
int op_grgb_balance(CaseIO *io);
/* harness_raw2.c */
int op_fpn(CaseIO *io);
int op_bayer_dnr(CaseIO *io);
int op_highlight(CaseIO *io);
int op_highlight_clip_lut(CaseIO *io);
/* harness_demosaic.c */
int op_demosaic_bilinear(CaseIO *io);
int op_demosaic_rccb(CaseIO *io);
int op_demosaic_rccc(CaseIO *io);
int op_demosaic_ryycy(CaseIO *io);
int op_demosaic_rgbir(CaseIO *io);
/* harness_demosaic_adv.c */
int op_demosaic_mhc(CaseIO *io);
int op_demosaic_aahd(CaseIO *io);
int op_demosaic_amaze(CaseIO *io);
int op_demosaic_lmmse(CaseIO *io);
int op_demosaic_igv(CaseIO *io);
/* harness_color1.c */
int op_white_balance_apply(CaseIO *io);
int op_white_balance_lut_apply(CaseIO *io);
int op_white_balance_auto(CaseIO *io);
int op_ccm(CaseIO *io);
int op_tonemap(CaseIO *io);
/* harness_clahe.c */
int op_clahe_rgb(CaseIO *io);
int op_clahe_mono(CaseIO *io);
/* harness_enhance.c */
int op_rgb_dnr(CaseIO *io);
int op_sharpen(CaseIO *io);
int op_edge_extract(CaseIO *io);
int op_gaussian_blur(CaseIO *io);
int op_morphology(CaseIO *io);
/* harness_csc.c */
int op_csc_rgb2yuv(CaseIO *io);
int op_csc_rgb2hsl(CaseIO *io);
int op_csc_yuv2rgb(CaseIO *io);
int op_csc_yuv2hsl(CaseIO *io);
int op_csc_hsl2rgb(CaseIO *io);
int op_csc_hsl2yuv(CaseIO *io);
/* harness_adjust.c */
int op_adjust_hsl(CaseIO *io);
int op_adjust_rgb(CaseIO *io);
int op_adjust_lut3_apply(CaseIO *io);
int op_adjust_bc_lut_apply(CaseIO *io);
int op_color_controller_lut_apply(CaseIO *io);
int op_multi_band_eq(CaseIO *io);
int op_adjust_yuv(CaseIO *io);
int op_adjust_satbright(CaseIO *io);
int op_adjust_brightcontrast(CaseIO *io);
int op_adjust_colorbalance(CaseIO *io);
int op_color_controller(CaseIO *io);
/* harness_levels_temp.c */
int op_levels_lut(CaseIO *io);
int op_levels_apply(CaseIO *io);
int op_color_temp_gains(CaseIO *io);
int op_color_temp_whitepoint(CaseIO *io);
int op_color_temp_ccm(CaseIO *io);
int op_color_temp_measure_cct(CaseIO *io);
/* harness_fluoro.c */
int op_fluoro_leak(CaseIO *io);
int op_fluoro_background(CaseIO *io);
int op_fluoro_normalize(CaseIO *io);
int op_fluoro_temporal(CaseIO *io);
int op_pseudo_color(CaseIO *io);
int op_pseudo_color_lut_apply(CaseIO *io);
int op_fluoro_fusion(CaseIO *io);
/* harness_blend_split.c */
int op_multiply(CaseIO *io);
int op_blend_mono(CaseIO *io);
int op_blend_mask(CaseIO *io);
int op_mux4(CaseIO *io);
int op_split_rgb(CaseIO *io);
int op_split_yuv(CaseIO *io);
int op_split_hsl(CaseIO *io);
int op_combine_rgb(CaseIO *io);
int op_combine_yuv(CaseIO *io);
int op_combine_hsl(CaseIO *io);

/* ---------------------------------------------------------------------------
 * op 注册表（组代理不要改这里）
 * ------------------------------------------------------------------------- */

typedef struct OpEntry {
  const char *name;
  OpHandler handler;
} OpEntry;

static const OpEntry kOpTable[] = {
    {"unpack", op_unpack},
    {"black_level", op_black_level},
    {"dpc", op_dpc},
    {"lsc", op_lsc},
    {"grgb_balance", op_grgb_balance},
    {"fpn", op_fpn},
    {"bayer_dnr", op_bayer_dnr},
    {"highlight", op_highlight},
    {"highlight_clip_lut", op_highlight_clip_lut},
    {"demosaic_bilinear", op_demosaic_bilinear},
    {"demosaic_rccb", op_demosaic_rccb},
    {"demosaic_rccc", op_demosaic_rccc},
    {"demosaic_ryycy", op_demosaic_ryycy},
    {"demosaic_rgbir", op_demosaic_rgbir},
    {"demosaic_mhc", op_demosaic_mhc},
    {"demosaic_aahd", op_demosaic_aahd},
    {"demosaic_amaze", op_demosaic_amaze},
    {"demosaic_lmmse", op_demosaic_lmmse},
    {"demosaic_igv", op_demosaic_igv},
    {"white_balance_apply", op_white_balance_apply},
    {"white_balance_lut_apply", op_white_balance_lut_apply},
    {"white_balance_auto", op_white_balance_auto},
    {"ccm", op_ccm},
    {"tonemap", op_tonemap},
    {"clahe_rgb", op_clahe_rgb},
    {"clahe_mono", op_clahe_mono},
    {"rgb_dnr", op_rgb_dnr},
    {"sharpen", op_sharpen},
    {"edge_extract", op_edge_extract},
    {"gaussian_blur", op_gaussian_blur},
    {"morphology", op_morphology},
    {"csc_rgb2yuv", op_csc_rgb2yuv},
    {"csc_rgb2hsl", op_csc_rgb2hsl},
    {"csc_yuv2rgb", op_csc_yuv2rgb},
    {"csc_yuv2hsl", op_csc_yuv2hsl},
    {"csc_hsl2rgb", op_csc_hsl2rgb},
    {"csc_hsl2yuv", op_csc_hsl2yuv},
    {"adjust_hsl", op_adjust_hsl},
    {"adjust_rgb", op_adjust_rgb},
    {"adjust_lut3_apply", op_adjust_lut3_apply},
    {"adjust_bc_lut_apply", op_adjust_bc_lut_apply},
    {"color_controller_lut_apply", op_color_controller_lut_apply},
    {"multi_band_eq", op_multi_band_eq},
    {"adjust_yuv", op_adjust_yuv},
    {"adjust_satbright", op_adjust_satbright},
    {"adjust_brightcontrast", op_adjust_brightcontrast},
    {"adjust_colorbalance", op_adjust_colorbalance},
    {"color_controller", op_color_controller},
    {"levels_lut", op_levels_lut},
    {"levels_apply", op_levels_apply},
    {"color_temp_gains", op_color_temp_gains},
    {"color_temp_whitepoint", op_color_temp_whitepoint},
    {"color_temp_ccm", op_color_temp_ccm},
    {"color_temp_measure_cct", op_color_temp_measure_cct},
    {"fluoro_leak", op_fluoro_leak},
    {"fluoro_background", op_fluoro_background},
    {"fluoro_normalize", op_fluoro_normalize},
    {"fluoro_temporal", op_fluoro_temporal},
    {"pseudo_color", op_pseudo_color},
    {"pseudo_color_lut_apply", op_pseudo_color_lut_apply},
    {"fluoro_fusion", op_fluoro_fusion},
    {"multiply", op_multiply},
    {"blend_mono", op_blend_mono},
    {"blend_mask", op_blend_mask},
    {"mux4", op_mux4},
    {"split_rgb", op_split_rgb},
    {"split_yuv", op_split_yuv},
    {"split_hsl", op_split_hsl},
    {"combine_rgb", op_combine_rgb},
    {"combine_yuv", op_combine_yuv},
    {"combine_hsl", op_combine_hsl},
};

/* ---------------------------------------------------------------------------
 * params 访问器
 * ------------------------------------------------------------------------- */

static const char *case_find(CaseIO *io, const char *key) {
  int i;
  for (i = 0; i < io->nparams; i++) {
    if (strcmp(io->keys[i], key) == 0) return io->vals[i];
  }
  return NULL;
}

int case_param_has(CaseIO *io, const char *key) {
  return case_find(io, key) != NULL;
}

const char *case_param_str(CaseIO *io, const char *key, const char *dflt) {
  const char *v = case_find(io, key);
  return v != NULL ? v : dflt;
}

double case_param_double(CaseIO *io, const char *key, double dflt) {
  const char *v = case_find(io, key);
  return v != NULL ? strtod(v, NULL) : dflt;
}

int case_param_int(CaseIO *io, const char *key, int dflt) {
  const char *v = case_find(io, key);
  return v != NULL ? (int)strtol(v, NULL, 10) : dflt;
}

/* ---------------------------------------------------------------------------
 * 帧 IO
 * ------------------------------------------------------------------------- */

static void case_path(char *buf, size_t cap, const CaseIO *io,
                      const char *name) {
  snprintf(buf, cap, "%s\\%s", io->dir, name);
}

static long case_file_size(FILE *fp) {
  long cur = ftell(fp);
  long end;
  fseek(fp, 0, SEEK_END);
  end = ftell(fp);
  fseek(fp, cur, SEEK_SET);
  return end;
}

uint16_t *case_load_in(CaseIO *io, int idx, size_t expected_len) {
  char path[1024];
  char name[32];
  FILE *fp;
  long size;
  uint16_t *buf;
  snprintf(name, sizeof(name), "in%d.bin", idx);
  case_path(path, sizeof(path), io, name);
  fp = fopen(path, "rb");
  if (fp == NULL) {
    snprintf(io->err, CASE_ERR_LEN, "cannot open %s", path);
    return NULL;
  }
  size = case_file_size(fp);
  if (size != (long)(expected_len * 2)) {
    snprintf(io->err, CASE_ERR_LEN, "%s size %ld != expected %lu", path, size,
             (unsigned long)(expected_len * 2));
    fclose(fp);
    return NULL;
  }
  buf = (uint16_t *)malloc(expected_len * 2);
  if (buf == NULL) {
    snprintf(io->err, CASE_ERR_LEN, "out of memory (%lu bytes)",
             (unsigned long)(expected_len * 2));
    fclose(fp);
    return NULL;
  }
  /* 小端 uint16：x86-64 主机直接整块读即可。 */
  if (fread(buf, 2, expected_len, fp) != expected_len) {
    snprintf(io->err, CASE_ERR_LEN, "short read on %s", path);
    free(buf);
    fclose(fp);
    return NULL;
  }
  fclose(fp);
  return buf;
}

uint8_t *case_load_in_raw(CaseIO *io, int idx, size_t expected_len) {
  char path[1024];
  char name[32];
  FILE *fp;
  long size;
  uint8_t *buf;
  snprintf(name, sizeof(name), "inRaw%d.bin", idx);
  case_path(path, sizeof(path), io, name);
  fp = fopen(path, "rb");
  if (fp == NULL) {
    snprintf(io->err, CASE_ERR_LEN, "cannot open %s", path);
    return NULL;
  }
  size = case_file_size(fp);
  if (size != (long)expected_len) {
    snprintf(io->err, CASE_ERR_LEN, "%s size %ld != expected %lu", path, size,
             (unsigned long)expected_len);
    fclose(fp);
    return NULL;
  }
  buf = (uint8_t *)malloc(expected_len);
  if (buf == NULL) {
    snprintf(io->err, CASE_ERR_LEN, "out of memory (%lu bytes)",
             (unsigned long)expected_len);
    fclose(fp);
    return NULL;
  }
  if (fread(buf, 1, expected_len, fp) != expected_len) {
    snprintf(io->err, CASE_ERR_LEN, "short read on %s", path);
    free(buf);
    fclose(fp);
    return NULL;
  }
  fclose(fp);
  return buf;
}

static int case_write_file(CaseIO *io, int idx, const void *data, size_t len,
                           size_t elem) {
  char path[1024];
  char name[32];
  FILE *fp;
  snprintf(name, sizeof(name), "out%d.bin", idx);
  case_path(path, sizeof(path), io, name);
  fp = fopen(path, "wb");
  if (fp == NULL) {
    snprintf(io->err, CASE_ERR_LEN, "cannot write %s", path);
    return ISP_ERR_ARG;
  }
  if (fwrite(data, elem, len, fp) != len) {
    snprintf(io->err, CASE_ERR_LEN, "short write on %s", path);
    fclose(fp);
    return ISP_ERR_ARG;
  }
  fclose(fp);
  return ISP_OK;
}

int case_write_out(CaseIO *io, int idx, const uint16_t *data, size_t len) {
  return case_write_file(io, idx, data, len, 2);
}

int case_write_out_u8(CaseIO *io, int idx, const uint8_t *data, size_t len) {
  return case_write_file(io, idx, data, len, 1);
}

int case_scalar(CaseIO *io, const char *key, double value) {
  if (io->scalars_fp == NULL) {
    char path[1024];
    case_path(path, sizeof(path), io, "scalars.txt");
    io->scalars_fp = fopen(path, "wb");
    if (io->scalars_fp == NULL) {
      snprintf(io->err, CASE_ERR_LEN, "cannot write %s", path);
      return ISP_ERR_ARG;
    }
  }
  /* %.17g 保证 double 精确往返。 */
  fprintf(io->scalars_fp, "%s=%.17g\n", key, value);
  return ISP_OK;
}

void *case_scratch(CaseIO *io, size_t bytes) {
  void *p = malloc(bytes);
  if (p == NULL) {
    snprintf(io->err, CASE_ERR_LEN, "scratch out of memory (%lu bytes)",
             (unsigned long)bytes);
  }
  return p;
}

/* ---------------------------------------------------------------------------
 * params.txt 解析：读全文，就地切分 key/value
 * ------------------------------------------------------------------------- */

static int case_load_params(CaseIO *io) {
  char path[1024];
  FILE *fp;
  long size;
  char *text;
  char *p;
  case_path(path, sizeof(path), io, "params.txt");
  fp = fopen(path, "rb");
  if (fp == NULL) {
    /* params.txt 缺失按空参数表处理（宽进，由 handler 自己校验必需参数）。 */
    return ISP_OK;
  }
  size = case_file_size(fp);
  text = (char *)malloc((size_t)size + 1);
  if (text == NULL) {
    snprintf(io->err, CASE_ERR_LEN, "out of memory reading %s", path);
    fclose(fp);
    return ISP_ERR_ARG;
  }
  if (fread(text, 1, (size_t)size, fp) != (size_t)size) {
    snprintf(io->err, CASE_ERR_LEN, "short read on %s", path);
    free(text);
    fclose(fp);
    return ISP_ERR_ARG;
  }
  fclose(fp);
  text[size] = '\0';

  p = text;
  while (*p != '\0' && io->nparams < CASE_MAX_PARAMS) {
    char *line = p;
    char *eol = strpbrk(p, "\r\n");
    char *eq;
    if (eol != NULL) {
      *eol = '\0';
      p = eol + 1;
      /* 跳过连续的 CR/LF。 */
      while (*p == '\r' || *p == '\n') p++;
    } else {
      p += strlen(p);
    }
    if (line[0] == '\0' || line[0] == '#') continue;
    eq = strchr(line, '=');
    if (eq == NULL) continue;
    *eq = '\0';
    io->keys[io->nparams] = line;
    io->vals[io->nparams] = eq + 1;
    io->nparams++;
  }
  /* text 生命周期与进程一致，不 free（退出即释放）。 */
  return ISP_OK;
}

/* ---------------------------------------------------------------------------
 * main
 * ------------------------------------------------------------------------- */

int main(int argc, char **argv) {
  CaseIO io;
  size_t i;
  int ret;

  if (argc != 3) {
    fprintf(stderr, "usage: c_ref_harness.exe <op> <case_dir>\n");
    fprintf(stderr, "available ops:");
    for (i = 0; i < sizeof(kOpTable) / sizeof(kOpTable[0]); i++) {
      fprintf(stderr, " %s", kOpTable[i].name);
    }
    fprintf(stderr, "\n");
    return 2;
  }

  memset(&io, 0, sizeof(io));
  io.dir = argv[2];

  if (case_load_params(&io) != ISP_OK) {
    fprintf(stderr, "harness: %s\n", io.err);
    return 1;
  }

  for (i = 0; i < sizeof(kOpTable) / sizeof(kOpTable[0]); i++) {
    if (strcmp(kOpTable[i].name, argv[1]) == 0) {
      ret = kOpTable[i].handler(&io);
      if (io.scalars_fp != NULL) fclose(io.scalars_fp);
      if (ret != ISP_OK) {
        fprintf(stderr, "harness: op %s failed rc=%d%s%s\n", argv[1], ret,
                io.err[0] != '\0' ? ": " : "", io.err);
        return 1;
      }
      return 0;
    }
  }

  fprintf(stderr, "harness: unknown op '%s'\n", argv[1]);
  return 2;
}
