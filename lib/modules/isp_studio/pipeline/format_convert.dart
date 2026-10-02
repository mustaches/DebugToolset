// 格式转换节点（format_converter）的转换逻辑：内嵌终端流式运行内置
// ffmpeg 做 webm → mp4 转码（编码链逐档尝试：实测硬件编码器 → CPU
// 兜底），输出实时转发到节点卡片的终端面板。输入片源 HDR/SDR 自动
// 识别（videoFileInfo），输出动态范围可选：自动（跟随片源）/ SDR
// （zscale+tonemap 映射）/ HDR（HEVC 10bit + bt2020/PQ/HLG 容器标记）。
//
// 纯 Dart，无 Flutter 依赖。

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'video_source.dart'
    show VideoInfo, videoFileInfo, kHdrTonemapFilter;

/// 硬件编码器候选（mp4 容器只考虑 h264/hevc；av1 兼容性差不列，
/// mf 参数风险大不列）。探测与 auto 尝试顺序均按此表。
const kHwEncoderCandidates = [
  'h264_nvenc',
  'hevc_nvenc',
  'h264_qsv',
  'hevc_qsv',
  'h264_amf',
  'hevc_amf',
];

/// 硬件编码器 id 的显示名（属性面板下拉与终端步骤行共用）；
/// 未知 id 原样返回。
String hwEncoderDisplayName(String id) => switch (id) {
      'h264_nvenc' => 'NVIDIA NVENC H.264 (h264_nvenc)',
      'hevc_nvenc' => 'NVIDIA NVENC HEVC (hevc_nvenc)',
      'h264_qsv' => 'Intel QuickSync H.264 (h264_qsv)',
      'hevc_qsv' => 'Intel QuickSync HEVC (hevc_qsv)',
      'h264_amf' => 'AMD AMF H.264 (h264_amf)',
      'hevc_amf' => 'AMD AMF HEVC (hevc_amf)',
      _ => id,
    };

/// 从 `ffmpeg -hide_banner -encoders` 输出中解析出
/// [kHwEncoderCandidates] 里实际编译进的 id（按候选顺序返回）。
/// 按空白边界的独立词匹配，避免描述文本（如 "NVIDIA NVENC H.264
/// encoder"）误命中。
List<String> parseEncoderIds(String encodersOutput) {
  final found = <String>{};
  for (final id in kHwEncoderCandidates) {
    final re = RegExp('(^|\\s)${RegExp.escape(id)}(\\s|\$)');
    if (encodersOutput.contains(re)) found.add(id);
  }
  return [for (final id in kHwEncoderCandidates) if (found.contains(id)) id];
}

/// 探测实测可用的硬件编码器：先跑 `-encoders` 解析编译支持，再对每个
/// 编译支持的候选做微缩试编码验证硬件真实可用（exitCode==0 才算）。
/// 返回真实可用的 id 列表（候选顺序）；ffmpeg 不存在/异常时返回空表。
///
/// 已知教训：`-encoders` 列出不代表硬件可用（无 NVIDIA 的机器上
/// h264_nvenc 仍列出，实际编码报 "No capable devices found"）。
Future<List<String>> probeHwEncoders(String ffmpegPath) async {
  final exe = File(ffmpegPath).absolute.path;
  if (!File(exe).existsSync()) return const [];
  String encodersOut;
  try {
    final res = await Process.run(exe, ['-hide_banner', '-encoders'])
        .timeout(const Duration(seconds: 15));
    encodersOut = '${res.stdout}\n${res.stderr}';
  } catch (_) {
    return const [];
  }
  final ok = <String>[];
  for (final id in parseEncoderIds(encodersOut)) {
    try {
      // 微缩试编码（128x128/0.2s）：验证硬件真实可用，~15s 超时保护；
      // 任一候选失败/超时不影响其它候选。
      final r = await Process.run(exe, [
        '-hide_banner',
        '-y',
        '-f',
        'lavfi',
        '-i',
        'testsrc2=size=128x128:duration=0.2:rate=10',
        '-vf',
        'format=yuv420p',
        '-c:v',
        id,
        '-f',
        'null',
        '-',
      ]).timeout(const Duration(seconds: 15));
      if (r.exitCode == 0) ok.add(id);
    } catch (_) {}
  }
  return ok;
}

/// 各编码器的 ffmpeg 参数（不含 -i/输出/音频部分；hevc 带 hvc1 tag
/// 保证 mp4 容器兼容）。[hdrOut] = true 时映射到 HEVC 10bit 档：
/// h264 系 → 对应 hevc 档（补 `-pix_fmt p010le`），hevc 系原样补
/// p010le，libx264 → libx265（yuv420p10le + hvc1）。
List<String> encoderArgs(String encoderId, {bool hdrOut = false}) =>
    hdrOut ? _encoderArgsHdr(encoderId) : _encoderArgsSdr(encoderId);

List<String> _encoderArgsSdr(String encoderId) => switch (encoderId) {
      'libx264' => ['-c:v', 'libx264', '-preset', 'medium', '-crf', '23'],
      'h264_nvenc' => ['-c:v', 'h264_nvenc', '-preset', 'p5', '-cq', '23'],
      'hevc_nvenc' =>
        ['-c:v', 'hevc_nvenc', '-preset', 'p5', '-cq', '26', '-tag:v', 'hvc1'],
      'h264_qsv' =>
        ['-c:v', 'h264_qsv', '-preset', 'medium', '-global_quality', '23'],
      'hevc_qsv' => [
          '-c:v',
          'hevc_qsv',
          '-preset',
          'medium',
          '-global_quality',
          '26',
          '-tag:v',
          'hvc1',
        ],
      'h264_amf' => [
          '-c:v',
          'h264_amf',
          '-quality',
          'balanced',
          '-rc',
          'cqp',
          '-qp_i',
          '23',
          '-qp_p',
          '23',
        ],
      'hevc_amf' => [
          '-c:v',
          'hevc_amf',
          '-quality',
          'balanced',
          '-rc',
          'cqp',
          '-qp_i',
          '26',
          '-qp_p',
          '26',
          '-tag:v',
          'hvc1',
        ],
      // 未知 id 按 h264_nvenc 既有参数兜底（不应到达：选项来自探测结果）。
      _ => _encoderArgsSdr('h264_nvenc'),
    };

/// hdrOut 档对应的 HEVC 编码器 id（libx264 → libx265）。
String hevcEncoderFor(String encoderId) => switch (encoderId) {
      'h264_nvenc' || 'hevc_nvenc' => 'hevc_nvenc',
      'h264_qsv' || 'hevc_qsv' => 'hevc_qsv',
      'h264_amf' || 'hevc_amf' => 'hevc_amf',
      _ => 'libx265',
    };

List<String> _encoderArgsHdr(String encoderId) {
  final hevc = hevcEncoderFor(encoderId);
  if (hevc == 'libx265') {
    return [
      '-c:v', 'libx265', '-preset', 'medium', '-crf', '26',
      '-pix_fmt', 'yuv420p10le', '-tag:v', 'hvc1',
    ];
  }
  // hevc_nvenc 走 scale_cuda 零拷贝交付 p010le CUDA 帧：不能再给
  // -pix_fmt（会强制插入 auto_scale 软件转换 CUDA 帧，滤镜协商直接
  // 失败——实测 exit -40 "Function not implemented"）。
  if (hevc == 'hevc_nvenc') return _encoderArgsSdr(hevc);
  // qsv/amf：系统内存帧，10bit 输入经 -pix_fmt p010le。
  return [..._encoderArgsSdr(hevc), '-pix_fmt', 'p010le'];
}

/// HDR 输出的容器色彩标记（按输入 transfer）：PQ(1)/HLG(2)/SDR(空)。
List<String> colorTagArgs(int colorTransfer) => switch (colorTransfer) {
      1 => [
          '-color_primaries', 'bt2020',
          '-color_trc', 'smpte2084',
          '-colorspace', 'bt2020nc',
          '-color_range', 'tv',
        ],
      2 => [
          '-color_primaries', 'bt2020',
          '-color_trc', 'arib-std-b67',
          '-colorspace', 'bt2020nc',
          '-color_range', 'tv',
        ],
      _ => const [],
    };

/// 每档的输入侧选项（-i 前）：NVENC 档且非 HDR→SDR 时启用 NVDEC
/// 硬解 + 零拷贝 GPU 帧（`-hwaccel cuda -hwaccel_output_format cuda`——
/// 帧留在显存，vf 走 scale_cuda，不回读内存；实测 4K60 较软解链
/// ~1.45x 提速、CPU 近乎全闲）。其余档（QSV/AMF/CPU，以及一切
/// HDR→SDR——tonemap 在 CPU，硬解回读无收益）返回空走软解现状。
/// 回退安全性：某档 cuda 初始化/解码失败（老卡解不了 VP9 10bit 等）
/// exit 非 0，编码链逐档回退天然落到无 cuda 的下一档。
List<String> inputSideArgs(String encoderId,
    {required bool isHdr, required bool hdrOut}) {
  final isNvenc = encoderId == 'h264_nvenc' || encoderId == 'hevc_nvenc';
  if (!isNvenc || (isHdr && !hdrOut)) return const [];
  return const ['-hwaccel', 'cuda', '-hwaccel_output_format', 'cuda'];
}

/// 每档的 -vf 滤镜（null = 不加），与 [inputSideArgs] 配套：
/// - NVENC 零拷贝档：`scale_cuda`（HDR 出 → format=p010le；SDR 出 →
///   format=nv12，NVENC 原生输入格式）。
/// - HDR 输入出 SDR：[kHdrTonemapFilter]（zscale+tonemap CPU 链——
///   内置 ffmpeg 无 tonemap_cuda，保持软解；libx264 档也必须带，
///   否则输出仍是发灰的 10bit 截断）。
/// - HDR 输入出 HDR（非 NVENC 档）：`format=p010le`（保 10bit）。
/// - SDR：QSV/AMF 档 `format=yuv420p`（10bit 截 8bit 供硬件编码器）；
///   libx264 档 null（自身支持 10bit 输入转 8bit）。
String? stepVfFor(String encoderId,
    {required bool isHdr, required bool hdrOut}) {
  if (isHdr && !hdrOut) return kHdrTonemapFilter; // HDR→SDR：CPU tonemap
  final isNvenc = encoderId == 'h264_nvenc' || encoderId == 'hevc_nvenc';
  if (isNvenc) {
    return hdrOut ? 'scale_cuda=format=p010le' : 'scale_cuda=format=nv12';
  }
  if (isHdr) return 'format=p010le'; // HDR→HDR 非 NVENC 档
  return encoderId == 'libx264' ? null : 'format=yuv420p';
}

/// 输出动态范围解析（纯函数）：'auto' → 跟随输入；输入 SDR 而选 'hdr'
/// → 回退 'sdr'（第二元 = 是否发生回退，供终端输出说明）。
(String range, bool fellBack) resolveOutputRange(
    int inputTransfer, String choice) {
  if (choice == 'hdr' && inputTransfer == 0) return ('sdr', true);
  if (choice == 'auto') return (inputTransfer != 0 ? 'hdr' : 'sdr', false);
  return (choice, false);
}

/// 编码尝试链：`libx264` 只跑 CPU 一档；`auto` 依次尝试 [hwEncoders]
/// （实测可用的硬件编码器，为空则只试 h264_nvenc 兜底——未探测时的
/// 既有行为），全部失败后回退 libx264；具体 id 先试该编码器、
/// 失败回退 libx264。
List<String> encoderChainFor(String encoder, List<String> hwEncoders) =>
    switch (encoder) {
      'libx264' => const ['libx264'],
      'auto' => [
          ...(hwEncoders.isEmpty ? const ['h264_nvenc'] : hwEncoders),
          'libx264',
        ],
      _ => [encoder, 'libx264'],
    };

/// 终端文本追加：处理 ffmpeg 的 `\r` 覆盖行语义（进度行
/// `frame= ...\rframe= ...` 只保留最新一帧）。`\r` 写入缓冲作未决
/// 占位（可跨 chunk 保留），下一普通字符先把缓冲截断回当前行行首再
/// 写入；`\n`/`\r\n` 落定当前行（行尾未决 `\r` 剥掉）。结果超
/// [maxChars] 时保留尾部（截断到最近的换行边界）。
String appendConsoleText(String current, String chunk,
    {int maxChars = 200 * 1024}) {
  final buf = StringBuffer(current);
  // 当前行行首在 buf 中的位置（\r 覆盖时回退到这里）。
  var lineStart = current.lastIndexOf('\n') + 1;
  // 缓冲以 \r 结尾 = 有未决的覆盖标记（可能来自上一 chunk 末尾）。
  var pendingCr = current.endsWith('\r');
  void truncateTo(int length) {
    final kept = buf.toString().substring(0, length);
    buf.clear();
    buf.write(kept);
  }

  for (var i = 0; i < chunk.length; i++) {
    final c = chunk[i];
    if (c == '\r') {
      if (i + 1 < chunk.length && chunk[i + 1] == '\n') {
        // \r\n 组合：普通换行。
        i++;
        if (pendingCr) {
          truncateTo(buf.length - 1);
          pendingCr = false;
        }
        buf.write('\n');
        lineStart = buf.length;
      } else if (!pendingCr) {
        // 覆盖标记：写入 \r 占位（连续 \r 等价单个，不重复写入）。
        buf.write('\r');
        pendingCr = true;
      }
    } else if (c == '\n') {
      // 未决覆盖行直接落定（\r 换 \n）。
      if (pendingCr) {
        truncateTo(buf.length - 1);
        pendingCr = false;
      }
      buf.write('\n');
      lineStart = buf.length;
    } else {
      if (pendingCr) {
        // \r 覆盖行：截断回当前行行首再写入。
        truncateTo(lineStart);
        pendingCr = false;
      }
      buf.write(c);
    }
  }
  var result = buf.toString();
  if (result.length > maxChars) {
    final cut = result.indexOf('\n', result.length - maxChars);
    result = cut >= 0
        ? result.substring(cut + 1)
        : result.substring(result.length - maxChars);
  }
  return result;
}

/// 输出路径兜底为 .mp4 容器：本节点产出 H.264/HEVC + AAC，webm 封装器
/// 只接受 VP8/VP9/AV1 + Vorbis/Opus——输出名误带 .webm 等扩展名时
/// ffmpeg 写 header 即失败（"Only VP8 or VP9 or AV1 video ... supported
/// for WebM"）。非 .mp4 扩展名替换为 .mp4，无扩展名直接补上。
String ensureMp4Output(String path) {
  final sep = math.max(path.lastIndexOf('/'), path.lastIndexOf('\\'));
  final dot = path.lastIndexOf('.');
  if (dot > sep && path.substring(dot).toLowerCase() == '.mp4') return path;
  return '${dot > sep ? path.substring(0, dot) : path}.mp4';
}

/// 依次尝试编码链，流式转发 ffmpeg 输出；返回最终 exitCode（0=成功）。
/// 每档失败（exitCode 非 0）自动尝试下一档；全部失败返回最后一档的
/// exitCode。前置校验失败先 onOutput 一行错误描述并返回 -1。
///
/// [outputRange]：'auto'（跟随输入片源）/ 'sdr'（HDR 输入经
/// zscale+tonemap 映射为正确的 SDR）/ 'hdr'（HEVC 10bit + bt2020
/// PQ/HLG 容器标记；输入为 SDR 时回退 sdr 并输出说明）。
Future<int> runFormatConvert({
  required String ffmpegPath,
  required String inputFile,
  required String outputFile,
  String encoder = 'auto',
  List<String> hwEncoders = const [],
  String outputRange = 'auto',
  required void Function(String chunk) onOutput,
}) async {
  if (inputFile.trim().isEmpty) {
    onOutput('未设置输入文件（webm）\n');
    return -1;
  }
  if (outputFile.trim().isEmpty) {
    onOutput('未设置输出文件（mp4）\n');
    return -1;
  }
  if (ffmpegPath.trim().isEmpty) {
    onOutput('未设置 ffmpeg 路径\n');
    return -1;
  }
  // 相对路径（如默认的 tools/ffmpeg/ffmpeg.exe）基于工作目录解析。
  final ffmpegAbs = File(ffmpegPath).absolute.path;
  final inputAbs = File(inputFile).absolute.path;
  var outputAbs = File(outputFile).absolute.path;
  final outputFixed = ensureMp4Output(outputAbs);
  if (outputFixed != outputAbs) {
    onOutput('[NOTE] 输出容器须为 MP4（H.264/HEVC + AAC），'
        '已改写到 "$outputFixed"\n');
    outputAbs = outputFixed;
  }
  if (!File(ffmpegAbs).existsSync()) {
    onOutput('ffmpeg 不存在：$ffmpegAbs\n');
    return -1;
  }
  if (!File(inputAbs).existsSync()) {
    onOutput('输入文件不存在：$inputAbs\n');
    return -1;
  }
  // ffmpeg 不会自建目录：确保输出目录存在。
  try {
    await File(outputAbs).parent.create(recursive: true);
  } catch (e) {
    onOutput('无法创建输出目录：$e\n');
    return -1;
  }

  // 输入元数据探测（videoFileInfo 有缓存，开销一次）：识别 HDR/SDR。
  VideoInfo? info;
  try {
    info = await videoFileInfo(inputAbs, ffmpegPath: ffmpegAbs);
  } catch (_) {}
  final transfer = info?.colorTransfer ?? 0;
  final isHdrIn = transfer != 0;
  final (range, fellBack) = resolveOutputRange(transfer, outputRange);
  final hdrOut = range == 'hdr';
  final inputTag = switch (transfer) {
    1 => 'HDR(PQ)',
    2 => 'HDR(HLG)',
    _ => 'SDR',
  };
  onOutput('Input : $inputAbs [$inputTag]\n');
  onOutput('Output: $outputAbs [${hdrOut ? 'HDR HEVC 10bit' : 'SDR 8bit'}]\n');
  if (info == null) onOutput('（输入元数据探测失败，按 SDR 处理）\n');
  if (fellBack) onOutput('（输入为 SDR，HDR 输出不可用：已回退 SDR 输出）\n');
  if (hdrOut && encoder != 'auto' && encoder.startsWith('h264')) {
    onOutput('（HDR 输出需要 HEVC 编码：已自动改用 '
        '${hwEncoderDisplayName(hevcEncoderFor(encoder))}）\n');
  }

  final chain = encoderChainFor(encoder, hwEncoders);
  var lastExit = -1;
  for (var i = 0; i < chain.length; i++) {
    final id = chain[i];
    // hdrOut 时各档映射到 HEVC 10bit 档（CPU 兜底 libx265）。
    final name = !hdrOut
        ? (id == 'libx264' ? 'CPU encoder (libx264)' : hwEncoderDisplayName(id))
        : (hevcEncoderFor(id) == 'libx265'
            ? 'CPU encoder (libx265)'
            : hwEncoderDisplayName(hevcEncoderFor(id)));
    onOutput('==== [${i + 1}/${chain.length}] Try $name ====\n');
    // 解码/滤镜线程封顶 8（与导出/播放路径同口径：大核数机默认 auto
    // 会爆发式占满全核）。NVENC 档（非 HDR→SDR）走 NVDEC 硬解 +
    // scale_cuda 零拷贝 GPU 链（见 inputSideArgs/stepVfFor）。
    final vf = stepVfFor(id, isHdr: isHdrIn, hdrOut: hdrOut);
    final args = [
      '-hide_banner',
      '-y',
      '-threads',
      '8',
      '-filter_threads',
      '8',
      ...inputSideArgs(id, isHdr: isHdrIn, hdrOut: hdrOut),
      '-i',
      inputAbs,
      if (vf != null) ...['-vf', vf],
      ...encoderArgs(id, hdrOut: hdrOut),
      if (hdrOut) ...colorTagArgs(transfer),
      '-c:a',
      'aac',
      '-b:a',
      '192k',
      outputAbs,
    ];
    int exit;
    try {
      final proc = await Process.start(ffmpegAbs, args);
      // ffmpeg 进度走 stderr（含 \r 覆盖行——原始 chunk 原样转发，
      // \r 处理放 UI 层 appendConsoleText）。
      proc.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(onOutput);
      proc.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(onOutput);
      exit = await proc.exitCode;
    } catch (e) {
      onOutput('启动 ffmpeg 失败：$e\n');
      exit = -1;
    }
    lastExit = exit;
    if (exit == 0) return 0;
    if (i + 1 < chain.length) {
      onOutput(
          '\n[step ${i + 1}/${chain.length}] $name failed (exit $exit), trying next…\n');
    } else {
      onOutput(
          '\n[step ${i + 1}/${chain.length}] $name failed (exit $exit), no more fallback\n');
    }
  }
  return lastExit;
}
