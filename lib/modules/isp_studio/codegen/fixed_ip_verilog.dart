import 'dart:typed_data';

import '../models/isp_node.dart';
import '../pipeline/color_temp.dart';
import '../pipeline/isp_kernels.dart';
import 'ip_gen_plan.dart';
import 'color_temp_ctrl_verilog.dart';
import 'hsl_pipe_verilog.dart';
import 'ip_target.dart';
import 'node_v_full_stream.dart';

String _romSigned(String name, List<int> values) {
  final wide = values.any((v) => v > 0x7FFFFFFF || v < -0x80000000);
  final bits = wide ? 64 : 32;
  final b = StringBuffer(
    '  reg signed [${bits - 1}:0] $name [0:${values.length - 1}];\n',
  );
  b.writeln('  initial begin');
  for (var i = 0; i < values.length; i++) {
    final v = values[i];
    final literal = v < 0 ? "-$bits'sd${-v}" : "$bits'sd$v";
    b.writeln('    $name[$i] = $literal;');
  }
  b.writeln('  end');
  return b.toString();
}

String _rom16(String name, List<int> values) {
  final b = StringBuffer('  reg [15:0] $name [0:${values.length - 1}];\n');
  b.writeln('  initial begin');
  for (var i = 0; i < values.length; i++) {
    b.writeln('    $name[$i] = 16\'d${values[i]};');
  }
  b.writeln('  end');
  return b.toString();
}

List<int> _products(List<int> coefficients, int maxValue, int half) {
  return Int64List.fromList([
    for (final coefficient in coefficients)
      for (var v = 0; v <= maxValue; v++) coefficient * (v - half),
  ]);
}

String _reciprocalSeedRom() {
  final b = StringBuffer('''
  function [31:0] f_recip_seed;
    input integer idx;
    begin
      case (idx)''');
  for (var i = 128; i < 256; i++) {
    b.writeln("        8'd$i: f_recip_seed = 32'd${(1 << 44) ~/ (i << 6)};");
  }
  b.writeln('''
        default: f_recip_seed = 32'd0;
      endcase
    end
  endfunction''');
  return b.toString();
}

List<int> _normQ14(int maxValue) {
  return Int32List.fromList([
    for (var c = 0; c < 3; c++)
      for (var v = 0; v <= maxValue; v++) (v * 16384 / maxValue).round(),
  ]);
}

String fixedIpCommonFunctions(int pb, {bool reciprocal = false}) {
  final div = reciprocal && pb == 8
      ? '''
  function signed [31:0] f_div_round;
    input signed [31:0] num;
    input signed [31:0] den;
    integer k, dn, idx;
    reg [31:0] mag, q, recip, y0, y1;
    reg signed [63:0] r;
    reg [63:0] product, e;
    begin
      if (den <= 0) f_div_round = 0;
      else begin
        mag = num < 0 ? -num : num;
        if (den >= 16384) k = -1;
        else if (den >= 8192) k = 0;
        else if (den >= 4096) k = 1;
        else if (den >= 2048) k = 2;
        else if (den >= 1024) k = 3;
        else if (den >= 512) k = 4;
        else if (den >= 256) k = 5;
        else if (den >= 128) k = 6;
        else if (den >= 64) k = 7;
        else if (den >= 32) k = 8;
        else if (den >= 16) k = 9;
        else if (den >= 8) k = 10;
        else if (den >= 4) k = 11;
        else if (den >= 2) k = 12;
        else k = 13;
        dn = k >= 0 ? den << k : den >> 1;
        idx = dn >> 6;
        y0 = f_recip_seed(idx);
        product = {32'd0, dn} * {32'd0, y0};
        e = product >> 14;
        product = {32'd0, y0} * ((64'd1 << 31) - e);
        y1 = product >> 30;
        recip = y1 >> (14 - k);
        product = {32'd0, mag} * {32'd0, recip};
        q = product >> 30;
        r = {32'd0, mag} - ({32'd0, q} * {32'd0, den});
        if (r < 0) begin q = q - 1; r = r + den; end
        if (r >= den) begin q = q + 1; r = r - den; end
        if ((r << 1) >= den) q = q + 1;
        f_div_round = num < 0 ? -q : q;
      end
    end
  endfunction'''
      : '''
  function signed [31:0] f_div_round;
    input signed [31:0] num;
    input signed [31:0] den;
    begin
      if (den <= 0) f_div_round = 0;
      else if (num >= 0) f_div_round = (num + (den >>> 1)) / den;
      else f_div_round = -((-num + (den >>> 1)) / den);
    end
  endfunction''';
  return '''
${reciprocal && pb == 8 ? _reciprocalSeedRom() : ''}
$div
  function signed [31:0] f_round_8192;
    input signed [31:0] num;
    begin
      if (num >= 0) f_round_8192 = (num + 4096) >>> 13;
      else f_round_8192 = -((-num + 4096) >>> 13);
    end
  endfunction
  function signed [31:0] f_q14_mul;
    input signed [31:0] a;
    input signed [31:0] b;
    begin f_q14_mul = (a * b + 8192) >>> 14; end
  endfunction
  function signed [15:0] f_norm_q14;
    input integer v;
    begin f_norm_q14 = f_div_round(v * 16384, MAXV); end
  endfunction
  function [${pb - 1}:0] f_clamp_q14;
    input signed [31:0] v;
    begin
      if (v < 0) f_clamp_q14 = 0;
      else if (v > MAXV) f_clamp_q14 = MAXV;
      else f_clamp_q14 = v[${pb - 1}:0];
    end
  endfunction
  function [${pb - 1}:0] f_scale_q14;
    input signed [31:0] v;
    reg signed [31:0] n;
    begin
      if (v >= 0) n = (v * MAXV + 8192) >>> 14;
      else n = -((-v * MAXV + 8192) >>> 14);
      f_scale_q14 = f_clamp_q14(n);
    end
  endfunction
  function integer f_hue_q14;
    input integer p;
    input integer q;
    input integer t;
    begin
      if (t < 0) t = t + 49152;
      if (t > 49152) t = t - 49152;
      if (t < 8192) f_hue_q14 = p + f_round_8192((q - p) * t);
      else if (t < 24576) f_hue_q14 = q;
      else if (t < 32768)
        f_hue_q14 = p + f_round_8192((q - p) * (32768 - t));
      else f_hue_q14 = p;
    end
  endfunction
  function [112:0] f_rgb2hsl_pre_q14;
    input integer r;
    input integer g;
    input integer b;
    integer mx, mn, d, l, den, num, base, wrap;
    begin
      mx = g > b ? g : b; mn = g < b ? g : b;
      if (r > mx) mx = r;
      if (r < mn) mn = r;
      d = mx - mn; l = (mx + mn) >>> 1;
      den = l > 8192 ? 32768 - mx - mn : mx + mn;
      wrap = mx == r;
      num = mx == r ? (g - b) * 16384
           : (mx == g ? (b - r) * 16384 : (r - g) * 16384);
      base = mx == r ? 0 : (mx == g ? 32768 : 65536);
      f_rgb2hsl_pre_q14 = {wrap[0], base, num, den[15:0], l[15:0], d[15:0]};
    end
  endfunction
  function [${3 * pb - 1}:0] f_rgb2hsl_post_q14;
    input [112:0] pre;
    integer d, l, s, h, t, den, num, base, wrap;
    begin
      d = pre[15:0]; l = pre[31:16]; den = pre[47:32];
      num = pre[79:48]; base = pre[111:80]; wrap = pre[112];
      s = 0; h = 0; t = 0;
      if (d > 0) begin
        s = f_div_round(d * 16384, den);
        t = f_div_round(num, d);
        if (wrap && t < 0) t = t + 98304;
        t = t + base;
        h = f_div_round(t, 6);
      end
      f_rgb2hsl_post_q14 = {
        f_scale_q14(h), f_scale_q14(s), f_scale_q14(l)
      };
    end
  endfunction
  function [${3 * pb - 1}:0] f_rgb2hsl_q14;
    input integer r;
    input integer g;
    input integer b;
    begin f_rgb2hsl_q14 = f_rgb2hsl_post_q14(f_rgb2hsl_pre_q14(r, g, b)); end
  endfunction
  function [${3 * pb - 1}:0] f_hsl2rgb_q14;
    input integer h;
    input integer s;
    input integer l;
    integer p, q, h3, r, g, b;
    begin
      h = h % 16384; if (h < 0) h = h + 16384;
      if (s == 0) begin r = l; g = l; b = l; end
      else begin
        q = l < 8192 ? l + f_q14_mul(l, s) : l + s - f_q14_mul(l, s);
        p = 2 * l - q; h3 = h * 3;
        r = f_hue_q14(p, q, h3 + 16384);
        g = f_hue_q14(p, q, h3);
        b = f_hue_q14(p, q, h3 - 16384);
      end
      f_hsl2rgb_q14 = {
        f_scale_q14(r), f_scale_q14(g), f_scale_q14(b)
      };
    end
  endfunction
''';
}

String emitFixedIpNode(
  IspNode node,
  String id,
  int pb, {
  String? rgbHslStage,
  String? yuvStandard,
}) {
  final bw = 3 * pb;
  final type = node.typeId;
  final useLut = node.paramValues['codegenMode'] == 'lut_fixed';
  final bypass = node.paramValues['bypass'] == true;
  // 涉及 YUV 矩阵的四类节点（YUV↔RGB / YUV↔HSL / HSL↔YUV）默认 BT.2020。
  final usesYuvStandard =
      type == 'csc_yuv2rgb' ||
      type == 'csc_rgb2yuv' ||
      type == 'csc_yuv2hsl' ||
      type == 'csc_hsl2yuv';
  final effectiveStandard =
      yuvStandard ??
      '${node.paramValues['standard'] ?? (usesYuvStandard ? 'bt2020' : 'bt601')}';
  if (rgbHslStage == 'pre') {
    return '''
  function [112:0] ${id}_convert;
    input [47:0] px;
    integer r, g, b;
    begin
      r = px[47:32]; g = px[31:16]; b = px[15:0];
      ${id}_convert = f_rgb2hsl_pre_q14(r, g, b);
    end
  endfunction
''';
  }
  if (rgbHslStage == 'post') {
    return '''
  function [$bw-1:0] ${id}_convert;
    input [112:0] px;
    begin ${id}_convert = f_rgb2hsl_post_q14(px); end
  endfunction
''';
  }
  final rom = StringBuffer();
  if (useLut && type == 'color_temp_adjuster') {
    final gains = colorTempGains(
      (node.paramValues['temperature'] as num?)?.toDouble() ?? 6500,
      (node.paramValues['measured_cct'] as num?)?.toInt() ?? 0,
    );
    for (var c = 0; c < 3; c++) {
      rom.write(
        _rom16(
          '${id}_lut_${'rgb'[c]}',
          adjustQ14GainLut(gains[c], (1 << pb) - 1),
        ),
      );
    }
  }
  if (useLut && (type == 'csc_rgb2yuv' || type == 'csc_hsl2yuv')) {
    final c = rgbToYuvCoefficients(effectiveStandard);
    rom.write(
      _romSigned(
        '${id}_lut',
        _products(
          [c.cyR, c.cyG, c.cyB, c.cuR, c.cuG, 32768, 32768, c.cvG, c.cvB],
          (1 << pb) - 1,
          0,
        ),
      ),
    );
  }
  if (useLut && (type == 'csc_yuv2rgb' || type == 'csc_yuv2hsl')) {
    final c = yuvToRgbCoefficients(effectiveStandard);
    rom.write(
      _romSigned(
        '${id}_lut',
        _products(
          [c.crV, c.cgU, c.cgV, c.cbU],
          (1 << pb) - 1,
          ((1 << pb) - 1) >> 1,
        ),
      ),
    );
  }
  if (useLut &&
      (type == 'csc_rgb2hsl' ||
          type == 'csc_yuv2hsl' ||
          type == 'csc_hsl2rgb')) {
    rom.write(_romSigned('${id}_norm_lut', _normQ14((1 << pb) - 1)));
  }

  final body = StringBuffer();
  body.writeln(
    '  function [${rgbHslStage == 'normalize' ? 47 : bw - 1}:0] ${id}_convert;',
  );
  body.writeln('    input [$bw-1:0] px;');
  body.writeln('    integer r, g, b, y, u, v, rr, gg, bb;');
  body.writeln('    integer du, dv, halfV, offY;');
  body.writeln('    reg [$bw-1:0] tmp;');
  body.writeln('    begin');
  body.writeln('      r = px[$bw-1 -: $pb];');
  body.writeln('      g = px[${2 * pb}-1 -: $pb];');
  body.writeln('      b = px[$pb-1:0];');
  body.writeln('      halfV = MAXV >> 1;');
  if (bypass) {
    body.writeln('      ${id}_convert = px;');
    body.writeln('    end');
    body.writeln('  endfunction');
    return '$rom$body';
  }

  String coefficient(int value) {
    if (pb <= 8) return '$value';
    return value < 0 ? "-64'sd${-value}" : "64'sd$value";
  }

  if (type == 'color_temp_adjuster') {
    final gains = colorTempGains(
      (node.paramValues['temperature'] as num?)?.toDouble() ?? 6500,
      (node.paramValues['measured_cct'] as num?)?.toInt() ?? 0,
    );
    final q14 = [for (final gain in gains) (gain * 16384).round()];
    if (useLut) {
      body.writeln('      rr = ${id}_lut_r[r];');
      body.writeln('      gg = ${id}_lut_g[g];');
      body.writeln('      bb = ${id}_lut_b[b];');
      body.writeln(
        '      ${id}_convert = {rr[${pb - 1}:0], gg[${pb - 1}:0], bb[${pb - 1}:0]};',
      );
    } else {
      body.writeln('      rr = (r * ${q14[0]} + 8192) >>> 14;');
      body.writeln('      gg = (g * ${q14[1]} + 8192) >>> 14;');
      body.writeln('      bb = (b * ${q14[2]} + 8192) >>> 14;');
      body.writeln(
        '      ${id}_convert = {f_clamp_q14(rr), f_clamp_q14(gg), f_clamp_q14(bb)};',
      );
    }
  } else if (type == 'csc_rgb2yuv' || type == 'csc_hsl2yuv') {
    if (type == 'csc_hsl2yuv') {
      body.writeln(
        '      tmp = f_hsl2rgb_q14(f_norm_q14(r), f_norm_q14(g), f_norm_q14(b));',
      );
      body.writeln('      r = tmp[$bw-1 -: $pb];');
      body.writeln('      g = tmp[${2 * pb}-1 -: $pb];');
      body.writeln('      b = tmp[$pb-1:0];');
    }
    final c601 = rgbToYuvCoefficients('bt601');
    final c709 = rgbToYuvCoefficients('bt709');
    final c2020 = rgbToYuvCoefficients('bt2020');
    String sel(int a, int b, int c) => type == 'csc_rgb2yuv'
        ? '((YUV_STANDARD == 0) ? ${coefficient(a)} : '
              '((YUV_STANDARD == 1) ? ${coefficient(b)} : ${coefficient(c)}))'
        : coefficient(a);
    final cy = [
      sel(c601.cyR, c709.cyR, c2020.cyR),
      sel(c601.cyG, c709.cyG, c2020.cyG),
      sel(c601.cyB, c709.cyB, c2020.cyB),
    ];
    final cu = [
      sel(c601.cuR, c709.cuR, c2020.cuR),
      sel(c601.cuG, c709.cuG, c2020.cuG),
      coefficient(32768),
    ];
    final cv = [
      coefficient(32768),
      sel(c601.cvG, c709.cvG, c2020.cvG),
      sel(c601.cvB, c709.cvB, c2020.cvB),
    ];
    if (useLut) {
      body.writeln(
        '      y = (${id}_lut[r] + ${id}_lut[MAXV + 1 + g] + ${id}_lut[2 * (MAXV + 1) + b] + 32768) >>> 16;',
      );
      body.writeln(
        '      u = ((${id}_lut[3 * (MAXV + 1) + r] + ${id}_lut[4 * (MAXV + 1) + g] + ${id}_lut[5 * (MAXV + 1) + b] + 32768) >>> 16) + halfV;',
      );
      body.writeln(
        '      v = ((${id}_lut[6 * (MAXV + 1) + r] + ${id}_lut[7 * (MAXV + 1) + g] + ${id}_lut[8 * (MAXV + 1) + b] + 32768) >>> 16) + halfV;',
      );
    } else {
      body.writeln(
        '      y = (${cy[0]} * r + ${cy[1]} * g + ${cy[2]} * b + 32768) >>> 16;',
      );
      body.writeln(
        '      u = ((${cu[0]} * r + ${cu[1]} * g + ${cu[2]} * b + 32768) >>> 16) + halfV;',
      );
      body.writeln(
        '      v = ((${cv[0]} * r + ${cv[1]} * g + ${cv[2]} * b + 32768) >>> 16) + halfV;',
      );
    }
    if (node.paramValues['range'] == 'limited') {
      body.writeln(
        '      y = ((MAXV * 16 + 127) / 255) + (y * 219 + 127) / 255;',
      );
      body.writeln(
        '      u = halfV + ((u - halfV) * 224 + ((u - halfV) >= 0 ? 127 : -127)) / 255;',
      );
      body.writeln(
        '      v = halfV + ((v - halfV) * 224 + ((v - halfV) >= 0 ? 127 : -127)) / 255;',
      );
    }
    body.writeln(
      '      ${id}_convert = {f_clamp_q14(y), f_clamp_q14(u), f_clamp_q14(v)};',
    );
  } else if (type == 'csc_yuv2rgb' || type == 'csc_yuv2hsl') {
    if (useLut) {
      body.writeln('      rr = r + ((${id}_lut[b] + 32768) >>> 16);');
      body.writeln(
        '      gg = r + ((${id}_lut[MAXV + 1 + g] + ${id}_lut[2 * (MAXV + 1) + b] + 32768) >>> 16);',
      );
      body.writeln(
        '      bb = r + ((${id}_lut[3 * (MAXV + 1) + g] + 32768) >>> 16);',
      );
    } else {
      final c601 = yuvToRgbCoefficients('bt601');
      final c709 = yuvToRgbCoefficients('bt709');
      final c2020 = yuvToRgbCoefficients('bt2020');
      String sel(int a, int b, int c) =>
          '((YUV_STANDARD == 0) ? ${coefficient(a)} : '
          '((YUV_STANDARD == 1) ? ${coefficient(b)} : '
          '${coefficient(c)}))';
      body.writeln(
        '      rr = r + ((${sel(c601.crV, c709.crV, c2020.crV)} * '
        '(b - halfV) + 32768) >>> 16);',
      );
      body.writeln(
        '      gg = r + ((${sel(c601.cgU, c709.cgU, c2020.cgU)} * '
        '(g - halfV) + ${sel(c601.cgV, c709.cgV, c2020.cgV)} * '
        '(b - halfV) + 32768) >>> 16);',
      );
      body.writeln(
        '      bb = r + ((${sel(c601.cbU, c709.cbU, c2020.cbU)} * '
        '(g - halfV) + 32768) >>> 16);',
      );
    }
    body.writeln(
      '      rr = f_clamp_q14(rr); gg = f_clamp_q14(gg); bb = f_clamp_q14(bb);',
    );
    if (type == 'csc_yuv2hsl') {
      if (useLut) {
        body.writeln('      rr = ${id}_norm_lut[rr];');
        body.writeln('      gg = ${id}_norm_lut[MAXV + 1 + gg];');
        body.writeln('      bb = ${id}_norm_lut[2 * (MAXV + 1) + bb];');
      } else {
        body.writeln(
          '      rr = f_norm_q14(rr); gg = f_norm_q14(gg); bb = f_norm_q14(bb);',
        );
      }
      body.writeln(
        rgbHslStage == 'normalize'
            ? '      ${id}_convert = {rr[15:0], gg[15:0], bb[15:0]};'
            : '      ${id}_convert = f_rgb2hsl_q14(rr, gg, bb);',
      );
    } else {
      body.writeln(
        '      ${id}_convert = {rr[${pb - 1}:0], gg[${pb - 1}:0], bb[${pb - 1}:0]};',
      );
    }
  } else {
    if (useLut) {
      body.writeln('      r = ${id}_norm_lut[r];');
      body.writeln('      g = ${id}_norm_lut[MAXV + 1 + g];');
      body.writeln('      b = ${id}_norm_lut[2 * (MAXV + 1) + b];');
    } else {
      body.writeln(
        '      r = f_norm_q14(r); g = f_norm_q14(g); b = f_norm_q14(b);',
      );
    }
    body.writeln(
      type == 'csc_rgb2hsl'
          ? (rgbHslStage == 'normalize'
                ? '      ${id}_convert = {r[15:0], g[15:0], b[15:0]};'
                : '      ${id}_convert = f_rgb2hsl_q14(r, g, b);')
          : '      ${id}_convert = f_hsl2rgb_q14(r, g, b);',
    );
  }
  body.writeln('    end');
  body.writeln('  endfunction');
  return '$rom$body';
}

String buildFixedIpCore(IpPlan plan, {bool ctRuntimeEnabled = true}) {
  final top = plan.topName;
  final pb = plan.pixBits;
  final bw = 3 * pb;
  var hasYuvMatrix = false;
  var yuvStandard = 'bt601';
  for (final node in plan.cPlan.members.values) {
    if (node.typeId == 'csc_yuv2rgb' ||
        node.typeId == 'csc_rgb2yuv' ||
        node.typeId == 'csc_yuv2hsl' ||
        node.typeId == 'csc_hsl2yuv') {
      hasYuvMatrix = true;
      yuvStandard = effectiveYuvStandard(
        plan.options.yuvStandard,
        '${node.paramValues['standard'] ?? 'bt2020'}',
      );
      break;
    }
  }
  // HSL 转换含除法/条件分支：组合函数数据通路里三级乘法串在同一条组合链上，
  // DSP 内部寄存器无法插进去（DPIP/DPOP 建议的来源）。因此：
  //   - 面积档（GSTRATEGY=0）：保持组合函数 + 模块级 `use_dsp="no"`，
  //     零 DSP、零 DSP 流水建议；
  //   - 平衡/性能档（且 DSP_PIPE=3）：改走 hsl_pipe_verilog 的全流水数据通路，
  //     每级乘法前后都有寄存器、由 DSP48E2 原语的 AREG/BREG/MREG/PREG 吸收，
  //     同样零 DPIP/DPOP，且真正使用 DSP（11 个）。
  final hslNodes = plan.cPlan.members.values.any(
    (node) =>
        node.typeId == 'csc_rgb2hsl' ||
        node.typeId == 'csc_yuv2hsl' ||
        node.typeId == 'csc_hsl2rgb' ||
        node.typeId == 'csc_hsl2yuv' ||
        node.typeId == 'csc_yuv2hsl',
  );
  final hslModuleAttr = hslNodes && plan.options.gstrategy == 0
      ? '(* use_dsp = "no" *)\n'
      : '';
  bool hslPiped(IspNode node) =>
      (node.typeId == 'csc_rgb2hsl' ||
          node.typeId == 'csc_hsl2rgb' ||
          node.typeId == 'csc_hsl2yuv' ||
          node.typeId == 'csc_yuv2hsl') &&
      node.paramValues['codegenMode'] != 'lut_fixed' &&
      node.paramValues['bypass'] != true &&
      plan.options.gstrategy != 0 &&
      plan.options.dspPipe == 3;
  bool pipelinedHsl(IspNode node) =>
      node.typeId == 'csc_rgb2hsl' && hslPiped(node);
  bool pipelinedHsl2Rgb(IspNode node) =>
      node.typeId == 'csc_hsl2rgb' && hslPiped(node);
  bool pipelinedHsl2Yuv(IspNode node) =>
      node.typeId == 'csc_hsl2yuv' && hslPiped(node);
  bool pipelinedYuv2Hsl(IspNode node) =>
      node.typeId == 'csc_yuv2hsl' && hslPiped(node);
  // RGB→HSL 专用子模块（_hsl_m/_hsl_q/_hsl_corr）与 HSL→RGB 专用子模块
  // （_hsl2rgb_n/_q/_c）按需发射，避免把不相干的模块塞进 IP 文件。
  final needsRgb2HslBlocks = plan.cPlan.members.values.any(
    (node) => pipelinedHsl(node) || pipelinedYuv2Hsl(node),
  );
  final needsHsl2RgbBlocks = plan.cPlan.members.values.any(
    (node) => pipelinedHsl2Rgb(node) || pipelinedHsl2Yuv(node),
  );
  final needsHslPipe = needsRgb2HslBlocks || needsHsl2RgbBlocks;
  final needsYuvDsp = plan.cPlan.topo.any((nodeId) {
    final node = plan.cPlan.members[nodeId]!;
    return (node.typeId == 'csc_yuv2rgb' || node.typeId == 'csc_rgb2yuv') &&
        node.paramValues['codegenMode'] != 'lut_fixed' &&
        node.paramValues['bypass'] != true &&
        plan.options.gstrategy != 0 &&
        plan.options.dspPipe == 3;
  });
  // 运行期色温控制端口：仅当色温节点是**编组首节点**时启用（本工程的
  // IP 生成规则是每节点独立 IP，首节点即唯一节点）；此时帧统计累加的是
  // 模块输入像素，测量与控制语义完整。多节点编组里夹在中间的色温节点
  // 仍用生成期烘焙的增益（没有 cct_in/cct_out 端口）。
  String? ctRuntimeId;
  if (ctRuntimeEnabled && plan.cPlan.topo.isNotEmpty) {
    final first = plan.cPlan.members[plan.cPlan.topo.first]!;
    if (first.typeId == 'color_temp_adjuster' &&
        first.paramValues['bypass'] != true) {
      ctRuntimeId = plan.cPlan.idents[plan.cPlan.topo.first];
    }
  }
  final ctEnabled = ctRuntimeId != null;
  final nodes = StringBuffer();
  final stageWires = <String>[];
  final stageRegs = <String>[];
  var previous = 'in_data';
  void addStage(IspNode node, String id, int width, String? stage) {
    nodes.write(
      emitFixedIpNode(
        node,
        id,
        pb,
        rgbHslStage: stage,
        yuvStandard:
            node.typeId == 'csc_yuv2rgb' || node.typeId == 'csc_rgb2yuv'
            ? yuvStandard
            : null,
      ),
    );
    nodes.writeln('  wire [${width - 1}:0] $id = ${id}_convert($previous);');
    nodes.writeln('  reg [${width - 1}:0] ${id}_reg;');
    stageWires.add(id);
    stageRegs.add('${id}_reg');
    previous = '${id}_reg';
  }

  void addRawStage(String id, int width, String source, String expr) {
    nodes.write(source);
    nodes.writeln('  wire [${width - 1}:0] $id = $expr;');
    nodes.writeln('  reg [${width - 1}:0] ${id}_reg;');
    stageWires.add(id);
    stageRegs.add('${id}_reg');
    previous = '${id}_reg';
  }

  for (final nodeId in plan.cPlan.topo) {
    final node = plan.cPlan.members[nodeId]!;
    final id = plan.cPlan.idents[nodeId]!;
    final pipelinedYuv =
        node.typeId == 'csc_yuv2rgb' &&
        node.paramValues['codegenMode'] != 'lut_fixed' &&
        node.paramValues['bypass'] != true &&
        plan.options.gstrategy != 0 &&
        plan.options.dspPipe == 3;
    if (pipelinedYuv) {
      final sw = pb + 1;
      final aw = 2 * sw + pb;
      const pw = 40;
      final stageIndex = stageWires.length;
      final c601 = yuvToRgbCoefficients('bt601');
      final c709 = yuvToRgbCoefficients('bt709');
      final c2020 = yuvToRgbCoefficients('bt2020');
      String lit18(int v) => v < 0 ? "-18'sd${-v}" : "18'sd$v";
      String dspB(int a, int b, int c) =>
          "(YUV_STANDARD == 0) ? ${lit18(a)} : "
          "((YUV_STANDARD == 1) ? ${lit18(b)} : ${lit18(c)})";
      final bR = dspB(c601.crV, c709.crV, c2020.crV);
      final bGu = dspB(c601.cgU, c709.cgU, c2020.cgU);
      final bGv = dspB(c601.cgV, c709.cgV, c2020.cgV);
      final bBu = dspB(c601.cbU, c709.cbU, c2020.cbU);
      addRawStage('${id}_pre', aw, '''
  function [${aw - 1}:0] ${id}_prep;
    input [${bw - 1}:0] px;
    integer yy, uu, vv;
    reg [${pb - 1}:0] half;
    reg signed [${sw - 1}:0] du, dv;
    begin
      yy = px[${bw - 1} -: $pb];
      uu = px[${2 * pb - 1} -: $pb];
      vv = px[${pb - 1}:0];
      half = MAXV >> 1;
      du = \$signed({1'b0, uu[${pb - 1}:0]}) - \$signed({1'b0, half});
      dv = \$signed({1'b0, vv[${pb - 1}:0]}) - \$signed({1'b0, half});
      ${id}_prep = {du, dv, yy[${pb - 1}:0]};
    end
  endfunction
''', '${id}_prep($previous)');
      addRawStage('${id}_d1', aw, '', '${id}_pre_reg');
      addRawStage('${id}_d2', aw, '', '${id}_d1_reg');
      addRawStage(
        id,
        bw,
        '''
  wire signed [${pw - 1}:0] ${id}_mul_rr, ${id}_mul_gg1;
  wire signed [${pw - 1}:0] ${id}_mul_gg2, ${id}_mul_bb;
  ${top}_dsp_mul #(
      .AW($sw), .BW(18), .PW($pw), .SIGNED_A(1), .SIGNED_B(1)
  ) ${id}_u_rr (
      .clk(clk), .en(stage_ready[$stageIndex]),
      .a(${id}_pre[${sw + pb - 1} -: $sw]), .b($bR),
      .p(${id}_mul_rr));
  ${top}_dsp_mul #(
      .AW($sw), .BW(18), .PW($pw), .SIGNED_A(1), .SIGNED_B(1)
  ) ${id}_u_gg1 (
      .clk(clk), .en(stage_ready[$stageIndex]),
      .a(${id}_pre[${aw - 1} -: $sw]), .b($bGu),
      .p(${id}_mul_gg1));
  ${top}_dsp_mul #(
      .AW($sw), .BW(18), .PW($pw), .SIGNED_A(1), .SIGNED_B(1)
  ) ${id}_u_gg2 (
      .clk(clk), .en(stage_ready[$stageIndex]),
      .a(${id}_pre[${sw + pb - 1} -: $sw]), .b($bGv),
      .p(${id}_mul_gg2));
  ${top}_dsp_mul #(
      .AW($sw), .BW(18), .PW($pw), .SIGNED_A(1), .SIGNED_B(1)
  ) ${id}_u_bb (
      .clk(clk), .en(stage_ready[$stageIndex]),
      .a(${id}_pre[${aw - 1} -: $sw]), .b($bBu),
      .p(${id}_mul_bb));
  wire signed [$pw:0] ${id}_sr = ${id}_mul_rr + 41'sd32768;
  wire signed [$pw:0] ${id}_sg =
      ${id}_mul_gg1 + ${id}_mul_gg2 + 41'sd32768;
  wire signed [$pw:0] ${id}_sb = ${id}_mul_bb + 41'sd32768;
  wire signed [$pw:0] ${id}_rr =
      \$signed({1'b0, ${id}_d2_reg[${pb - 1}:0]}) + (${id}_sr >>> 16);
  wire signed [$pw:0] ${id}_gg =
      \$signed({1'b0, ${id}_d2_reg[${pb - 1}:0]}) + (${id}_sg >>> 16);
  wire signed [$pw:0] ${id}_bb =
      \$signed({1'b0, ${id}_d2_reg[${pb - 1}:0]}) + (${id}_sb >>> 16);''',
        '{f_clamp_q14(${id}_rr), f_clamp_q14(${id}_gg), '
            'f_clamp_q14(${id}_bb)}',
      );
    } else if (node.typeId == 'csc_rgb2yuv' &&
        node.paramValues['codegenMode'] != 'lut_fixed' &&
        node.paramValues['bypass'] != true &&
        plan.options.gstrategy != 0 &&
        plan.options.dspPipe == 3) {
      const pw = 40;
      final stageIndex = stageWires.length;
      final c601 = rgbToYuvCoefficients('bt601');
      final c709 = rgbToYuvCoefficients('bt709');
      final c2020 = rgbToYuvCoefficients('bt2020');
      String lit18(int v) => v < 0 ? "-18'sd${-v}" : "18'sd$v";
      String dspB(int a, int b, int c) =>
          "(YUV_STANDARD == 0) ? ${lit18(a)} : "
          "((YUV_STANDARD == 1) ? ${lit18(b)} : ${lit18(c)})";
      final mulSource = StringBuffer();
      final terms = <(String, String, String)>[
        ('yr', dspB(c601.cyR, c709.cyR, c2020.cyR), 'R'),
        ('yg', dspB(c601.cyG, c709.cyG, c2020.cyG), 'G'),
        ('yb', dspB(c601.cyB, c709.cyB, c2020.cyB), 'B'),
        ('ur', dspB(c601.cuR, c709.cuR, c2020.cuR), 'R'),
        ('ug', dspB(c601.cuG, c709.cuG, c2020.cuG), 'G'),
        ('ub', '18\'sd32768', 'B'),
        ('vr', '18\'sd32768', 'R'),
        ('vg', dspB(c601.cvG, c709.cvG, c2020.cvG), 'G'),
        ('vb', dspB(c601.cvB, c709.cvB, c2020.cvB), 'B'),
      ];
      String sliceOf(String channel) => switch (channel) {
        'R' => '${bw - 1} -: $pb',
        'G' => '${2 * pb - 1} -: $pb',
        _ => '${pb - 1}:0',
      };
      for (final (tag, b, channel) in terms) {
        mulSource.writeln('''
  wire signed [${pw - 1}:0] ${id}_$tag;
  ${top}_dsp_mul #(
      .AW($pb), .BW(18), .PW($pw), .SIGNED_A(0), .SIGNED_B(1)
  ) ${id}_u_$tag (
      .clk(clk), .en(stage_ready[$stageIndex]),
      .a(${id}_pre[${sliceOf(channel)}]), .b($b),
      .p(${id}_$tag));''');
      }
      mulSource.writeln('''
  wire signed [$pw:0] ${id}_ys =
      ${id}_yr + ${id}_yg + ${id}_yb + 41'sd32768;
  wire signed [$pw:0] ${id}_us =
      ${id}_ur + ${id}_ug + ${id}_ub + 41'sd32768;
  wire signed [$pw:0] ${id}_vs =
      ${id}_vr + ${id}_vg + ${id}_vb + 41'sd32768;
  wire signed [$pw:0] ${id}_half =
      \$signed({1'b0, MAXV}) >>> 1;
  wire signed [$pw:0] ${id}_yraw = ${id}_ys >>> 16;
  wire signed [$pw:0] ${id}_uraw = (${id}_us >>> 16) + ${id}_half;
  wire signed [$pw:0] ${id}_vraw = (${id}_vs >>> 16) + ${id}_half;''');
      String yOut = '${id}_yraw';
      String uOut = '${id}_uraw';
      String vOut = '${id}_vraw';
      if (node.paramValues['range'] == 'limited') {
        mulSource.writeln('''
  wire signed [$pw:0] ${id}_ylim =
      ((MAXV * 16 + 127) / 255) + (${id}_yraw * 219 + 127) / 255;
  wire signed [$pw:0] ${id}_du = ${id}_uraw - ${id}_half;
  wire signed [$pw:0] ${id}_dv = ${id}_vraw - ${id}_half;
  wire signed [$pw:0] ${id}_ulim = ${id}_half +
      (${id}_du * 224 + ((${id}_du >= 0) ? 127 : -127)) / 255;
  wire signed [$pw:0] ${id}_vlim = ${id}_half +
      (${id}_dv * 224 + ((${id}_dv >= 0) ? 127 : -127)) / 255;''');
        yOut = '${id}_ylim';
        uOut = '${id}_ulim';
        vOut = '${id}_vlim';
      }
      addRawStage('${id}_pre', bw, '', previous);
      addRawStage('${id}_d1', bw, '', '${id}_pre_reg');
      addRawStage('${id}_d2', bw, '', '${id}_d1_reg');
      addRawStage(
        id,
        bw,
        mulSource.toString(),
        '{f_clamp_q14($yOut), f_clamp_q14($uOut), f_clamp_q14($vOut)}',
      );
    } else if (pipelinedHsl(node)) {
      for (final st in buildHslPipeStages(
        top: top,
        id: id,
        pb: pb,
        input: previous,
        baseStage: stageWires.length,
        mul: '${top}_hsl_mul',
      )) {
        addRawStage(st.id, st.width, st.source, st.expr);
      }
    } else if (pipelinedYuv2Hsl(node)) {
      for (final st in buildYuv2HslPipeStages(
        top: top,
        id: id,
        pb: pb,
        input: previous,
        baseStage: stageWires.length,
        mul: '${top}_hsl_mul',
      )) {
        addRawStage(st.id, st.width, st.source, st.expr);
      }
    } else if (pipelinedHsl2Yuv(node)) {
      for (final st in buildHsl2YuvPipeStages(
        top: top,
        id: id,
        pb: pb,
        input: previous,
        baseStage: stageWires.length,
        mul: '${top}_hsl_mul',
      )) {
        addRawStage(st.id, st.width, st.source, st.expr);
      }
    } else if (pipelinedHsl2Rgb(node)) {
      for (final st in buildHsl2RgbPipeStages(
        top: top,
        id: id,
        pb: pb,
        input: previous,
        baseStage: stageWires.length,
        mul: '${top}_hsl_mul',
      )) {
        addRawStage(st.id, st.width, st.source, st.expr);
      }
    } else if (node.typeId == 'csc_rgb2hsl' || node.typeId == 'csc_yuv2hsl') {
      addStage(node, '${id}_norm', 48, 'normalize');
      addStage(node, '${id}_pre', 113, 'pre');
      addStage(node, '${id}_post', bw, 'post');
    } else if (ctEnabled && id == ctRuntimeId) {
      addRawStage(
        id,
        bw,
        ctCoreGlue(
          top: top,
          id: id,
          pixBits: pb,
          bw: bw,
          input: previous,
        ),
        '{${id}_r, ${id}_g, ${id}_b}',
      );
    } else {
      addStage(node, id, bw, null);
    }
  }
  final count = stageWires.length;
  final control = StringBuffer();
  for (var i = count - 1; i >= 0; i--) {
    control.writeln(
      i == count - 1
          ? '  assign stage_ready[$i] = ~valid_pipe[$i] | out_ready;'
          : '  assign stage_ready[$i] = ~valid_pipe[$i] | stage_ready[${i + 1}];',
    );
  }
  for (var i = 0; i < count; i++) {
    final valid = i == 0 ? 'in_valid' : 'valid_pipe[${i - 1}]';
    final sof = i == 0 ? 'in_sof' : 'sof_pipe[${i - 1}]';
    final eol = i == 0 ? 'in_eol' : 'eol_pipe[${i - 1}]';
    final last = i == count - 1;
    control.writeln('''
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_pipe[$i] <= 1'b0; sof_pipe[$i] <= 1'b0; eol_pipe[$i] <= 1'b0;
      ${last ? 'out_data <= {$bw{1\'b0}};' : ''}
    end else if (stage_ready[$i]) begin
      valid_pipe[$i] <= $valid;
      sof_pipe[$i] <= $sof;
      eol_pipe[$i] <= $eol;
      if ($valid) begin
        ${stageRegs[i]} <= ${stageWires[i]};
        ${last ? 'out_data <= ${stageWires[i]};' : ''}
      end
    end
  end''');
  }
  // 文件头（生成信息 + timescale）必须排在所有模块定义之前：`` `timescale ``
  // 只对其后的模块生效，放在子模块之后会让前面的模块失去时间单位。
  final fileHeader = '''
// Generated by DebugToolSet ISP Studio (fixed-point Verilog IP package).
// Target vendor: ${plan.options.vendor.name}
// Pixel bits PIX_BITS=$pb (MAXV=${plan.maxValue}), LUT domain 0..${plan.maxValue}
`timescale 1ns/1ps
''';
  final helperModules = StringBuffer();
  if (needsYuvDsp) {
    helperModules.write(
      '${mbDspMulDef(top, plan.options.vendor.isVivado && plan.options.vivadoFamily == 'zynquplus')}\n',
    );
  }
  if (needsRgb2HslBlocks) helperModules.write('${hslBlockDefs(top)}\n');
  if (needsHsl2RgbBlocks) helperModules.write('${hsl2RgbBlockDefs(top)}\n');
  if (needsHslPipe) {
    helperModules.write(
      '${hslDspMulDef(top, plan.options.vendor.isVivado && plan.options.vivadoFamily == 'zynquplus')}\n',
    );
  }
  if (ctEnabled) {
    // 色温控制块的 nq^2 / nq^3 用 DSP48 原语（全流水、零 DRC 建议）。
    helperModules.write(
      '${mbDspMulDef(top, plan.options.vendor.isVivado && plan.options.vivadoFamily == 'zynquplus')}\n',
    );
    helperModules.write(
      '${ctCtrlVerilog(top, useBram: plan.options.useBram)}\n',
    );
  }
  return '''
$fileHeader$helperModules${hslModuleAttr}module ${top}_core #(
    parameter integer PIX_BITS = $pb,
    parameter integer MAX_WIDTH = ${plan.options.maxWidth},
    parameter integer GSTRATEGY = ${plan.options.gstrategy},
    parameter integer FOLD = ${plan.options.fold},
    parameter integer DSP_PIPE = ${plan.options.dspPipe}${hasYuvMatrix ? ', parameter integer YUV_STANDARD = ${yuvStandardCode(yuvStandard)}' : ''}${ctEnabled ? ', parameter integer USE_BRAM = ${plan.options.useBram ? 1 : 0}' : ''}
) (
    input wire clk, input wire rst_n,
    input wire in_valid, output wire in_ready,
    input wire in_sof, input wire in_eol,
    input wire [$bw-1:0] in_data,
    output wire out_valid, input wire out_ready,
    output wire out_sof, output wire out_eol,
    output reg [$bw-1:0] out_data${ctEnabled ? ''',
    input wire [13:0] cct_in,
    output wire [13:0] cct_out''' : ''}
);
  localparam [$pb-1:0] MAXV = (1 << PIX_BITS) - 1;
${fixedIpCommonFunctions(pb, reciprocal: plan.cPlan.members.values.any((node) => node.typeId == 'csc_rgb2hsl' || node.typeId == 'csc_yuv2hsl'))}
  reg [$count-1:0] valid_pipe, sof_pipe, eol_pipe;
  wire [$count-1:0] stage_ready;
$nodes
$control
  assign in_ready = stage_ready[0];
  assign out_valid = valid_pipe[$count-1];
  assign out_sof = sof_pipe[$count-1];
  assign out_eol = eol_pipe[$count-1];
endmodule
''';
}
