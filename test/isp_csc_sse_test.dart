/// isp_csc_sse.h RGB↔HSL 双像素 SSE2 快路径对拍：与标量
/// isp_csc_rgb_to_hsl_px / isp_csc_hsl_to_rgb_px 逐位一致（tol=0）。
///
/// 背景：HSL 端口编组的 Win32 验证程序（main_win.c）每帧整帧 RGB→HSL
///（装帧）+ HSL→RGB（解包）FP64 逐像素转换是 4K 播放帧率瓶颈（omp16
/// ~15/17ms/帧）；SSE2 双像素快路径（分支改掩码选择，IEEE 运算逐位同
/// 口径）降到 ~6/8ms。批模式哈希对拍依赖装帧结果逐位一致，故本组对拍
/// 为全量穷举 + 多 max_value 抽样，零容差。
///
/// C 侧：test/c_ref/harness_csc.c 的 csc_sse_selfcheck op
///（lib/modules/isp_studio/c_ref/isp_csc_sse.h vs isp_csc_common.h 标量）。
library;

import 'package:flutter_test/flutter_test.dart';

import 'c_ref/compare_helper.dart';

const tag = '_grp_sse';

Future<void> main() async {
  final built = await ensureHarnessBuilt(tag: tag);

  group('isp_csc_sse: RGB↔HSL SSE2 双像素快路径 vs 标量逐位对拍',
      skip: built ? false : '无 MSVC 环境或 harness 构建失败', () {
    test('max_value=255：RGB/HSL 全 256^3 输入域穷举（双向）', () async {
      final r = await runCOp('csc_sse_selfcheck',
          tag: tag, params: {'max_value': 255}, outputCount: 0);
      expect(r.scalars['r2h_bad'], 0, reason: 'rgb→hsl 穷举不匹配对数');
      expect(r.scalars['h2r_bad'], 0, reason: 'hsl→rgb 穷举不匹配对数');
      expect(r.scalars['nv12_bad'], 0, reason: 'nv12→rgb 抽样不匹配数');
    });
    for (final mv in [1023, 4095, 65535]) {
      test('max_value=$mv：LCG 抽样 400 万对（含 hv 越界慢路径/超域）',
          () async {
        final r = await runCOp('csc_sse_selfcheck',
            tag: tag,
            params: {'max_value': mv, 'samples': 4000000},
            outputCount: 0);
        expect(r.scalars['r2h_bad'], 0, reason: 'rgb→hsl 抽样不匹配对数');
        expect(r.scalars['h2r_bad'], 0, reason: 'hsl→rgb 抽样不匹配对数');
        expect(r.scalars['nv12_bad'], 0, reason: 'nv12→rgb 抽样不匹配数');
      });
    }
  });
}
