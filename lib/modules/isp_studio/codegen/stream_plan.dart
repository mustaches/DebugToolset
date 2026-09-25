/// ISP 节点编组「黑盒子 C 代码」（行级流水）导出的流式规划层。
///
/// 输入整帧版规划产物 [GroupCPlan]，输出行级流水的阶段组织：
///
/// - **流模型**：每条节点间连线是一支行流。点对点节点消费第 y 行、产出
///   第 y 行（行延迟 0）；垂直窗口节点（半径 r）消费第 y-r..y+r 行、产出
///   第 y 行——输出滞后输入 r 行，流延迟 = 路径上窗口半径之和。
/// - **最大化融合**：连续点对点链融合进同一个 `for (x)` 行循环，中间值
///   只在局部变量中传递，不物化任何缓冲；窗口节点输出为单消费者时同样
///   融合进下游阶段（窗口读取其输入环形缓冲，产出走局部变量）。
/// - **物化点**（scratch 环形缓冲，行号 ℓ 存于槽 ℓ % rows）：
///   1. 编组外部输出流：恒有阶段，写调用方整帧缓冲的第 y 行；
///   2. 扇出流（组内消费者 ≥ 2）：物化（rows 取各消费者需求最大值，
///      单行 rows=1 时同一行内先写后读、下一行覆写——不存整帧）；
///   3. 窗口节点输入流：强制物化为 (2r+1) 行环形缓冲（外部输入流例外——
///      调用方整帧缓冲直接寻址，不另配环形）；
///   4. 延迟均衡 FIFO：汇合节点（多输入）各输入流延迟不等时，较快支路
///      强制物化为 (delay 差 + 1) 行环形缓冲，汇合阶段按消费行号取模
///      读取，与慢支路行号对齐；
///   5. dpc 输出流：强制物化为 (2r+1) 行环形——dpc 是原地算法（c_ref
///      无快照，已处理像素参与后续邻域），后续窗口/消费者读已处理行。
/// - **驱动模型**：主循环 `for (y = 0; y < h; y++)` 中每个阶段（延迟 D）
///   计算其物化流的第 y-D 行（y < D 时跳过）；窗口阶段读输入环行
///   (y-D)±r（最新行 y-D+r 恰由上游本迭代写入）。主循环后尾部冲刷
///   `for (y = h; y < h + maxDelay; y++)` 由延迟阶段补齐底部 maxDelay
/// 行。垂直边界逐节点复刻 c_ref 语义（窗口节点为「越界裁剪」——邻域
///   收集时丢弃越界样本，行核按坐标判断；gaussian_blur 两趟均为「夹取/
///   边界复制」——tap 下标钳回图内端点）。
/// - **scratch**：物化环形缓冲 + 窗口/分离趟节点派生环（sharpen/
///   edge_extract 的亮度平面、rgb_dnr 的 yuv 平面，均 3 行 uint16；
///   morphology 的水平趟极值环 2r+1 行 uint16；gaussian_blur 的水平趟
///   卷积环 2r+1 行 double + k_len 个 double 权重核）+ gamma 色调映射
///   LUT，逐项列入 `{TOP}_SCRATCH_BYTES(w,h,max_value)`（资源占用编译期
///   可见）；纯点对点无扇出编组仍为 0（签名省略 scratch 形参）。
/// - gamma 穿透：与整帧版一致，gamma 的组内下游直接消费 gamma 的输入
///   流（gamma 不改输入）；gamma 自身恒为链尾物化点（rgba 输出，延迟 0）。
///
/// 数据环（splitter/combiner 回环）无法流水，由
/// [streamPlanDataCycleError] 检测并在校验期拒绝。
library;

import '../models/isp_graph.dart';
import 'group_c_plan.dart';
import 'node_c_gen.dart';

/// 流式支持集：点对点类型 + 垂直窗口类型 + 分离趟类型（demosaic 仅限
/// algorithm=bilinear 与 Bayer CFA，校验期检查参数；fpn 需整帧多遍统计，
/// 拒绝——见 validateGroupBlackBoxExport 的拒绝说明）。
///
/// 核实结论（c_ref 出处）：
/// - dpc/bayer_dnr/highlight(recover)：3x3 邻域裁剪（Bayer 同相位步进
///   ±2 → 垂直半径 2，mono 半径 1），支持；dpc 为原地算法（无快照，
///   isp_dpc.c 直接读写同一缓冲），输出强制物化环形以复刻原地语义。
/// - sharpen/edge_extract/rgb_dnr：亮度/yuv 平面为逐像素派生（派生环 3
///   行）+ 3x3 窗口（半径 1），支持。
/// - demosaic(bilinear)：3x3 裁剪邻域 + 通道筛选（半径 1），支持；其余
///   algorithm 与非 Bayer CFA 路径（rccb/rccc/ryycy/rgb_ir）拒绝。
/// - highlight(clip)：纯逐像素膝点软压缩，按点对点支持（含 LUT 模式）。
/// - morphology/gaussian_blur：c_ref 本即「水平趟 + 垂直滑窗」分离结构
///   （isp_morphology.c / isp_gaussian_blur.c 均为惰性逐行推进 + 环形行
///   缓冲），水平趟作为派生环写入、垂直趟走窗口行核；morphology 极值
///   截断窗口（顺序无关），gaussian 卷积夹取窗口（边界复制）。
/// - fpn：isp_fpn.c 需全帧低通平面 + 全帧边缘掩膜 + 行/列残差中位数
///   （整帧多遍统计），无法行级流水，拒绝。
/// - fluoro_normalize（全帧均值）、fluoro_background（块均值）、
///   fluoro_fusion（offset 双线性跨行采样 + contour 3x3 邻域）、
///   grgb_balance（全帧 Gr/Gb 统计两遍法）、white_balance(auto)（灰度
///   世界全帧统计）均非逐像素/单遍可行，拒绝。
const Set<String> streamSupportedTypeIds = {
  // Process — RAW 域（点对点 + 窗口）
  'black_level', 'lsc', 'dpc', 'bayer_dnr',
  // Process — RGB 域（点对点）与链尾
  'white_balance', 'ccm', 'gamma',
  // Process — 窗口/分离趟（垂直窗口 + 水平趟/垂直趟分离）
  'demosaic', 'rgb_dnr', 'sharpen', 'edge_extract', 'highlight',
  'morphology', 'gaussian_blur',
  // Process — ColorTrans
  'csc_rgb2yuv', 'csc_rgb2hsl', 'csc_yuv2rgb', 'csc_yuv2hsl',
  'csc_hsl2rgb', 'csc_hsl2yuv',
  // Process — 调节器
  'hsl_debugger', 'rgb_debugger', 'yuv_debugger',
  'sat_bright_adjuster', 'bright_contrast_adjuster', 'levels_curves',
  'color_balance', 'color_temp_adjuster', 'color_controller',
  // Process — Fluorescence（逐像素子集）
  'fluoro_leak', 'pseudo_color',
  // Datapath
  'rgb_splitter', 'yuv_splitter', 'hsl_splitter',
  'rgb_combiner', 'yuv_combiner', 'hsl_combiner',
  'multiplier', 'adder', 'blender', 'mux4',
};

/// 行流来源解析结果：一个节点输入端口的供流方。
class StreamSrc {
  /// 内部流生产者节点 id；null 表示非内部流（外部输入或未连接）。
  final String? nodeId;

  /// 内部流的注册输出端口名（图端口名；gamma out_rgba 已归一为 out，
  /// 且 gamma 已被穿透、不会作为生产者出现）。
  final String? port;

  /// 内部流生产者 wrapper 的输出端口名（out_rgba 不归一），查行核输出
  /// 变量表用。
  final String? wrapperPort;

  /// 外部输入形参（nodeId 为 null 且已连接时非 null）。
  final GroupCExtPort? ext;

  /// 通道数（mono/bayer=1，rgb/yuv/hsl=3）。
  final int channels;

  /// 未连接的次要输入（combiner 缺省通道）：行核直接发射常量填充。
  final bool isUnconnected;

  const StreamSrc._(
      {this.nodeId,
      this.port,
      this.wrapperPort,
      this.ext,
      this.channels = 1,
      this.isUnconnected = false});

  factory StreamSrc.internal(
          String nodeId, String port, String wrapperPort, int channels) =>
      StreamSrc._(
          nodeId: nodeId,
          port: port,
          wrapperPort: wrapperPort,
          channels: channels);

  factory StreamSrc.external(GroupCExtPort ext) =>
      StreamSrc._(ext: ext, channels: ext.channels);

  factory StreamSrc.unconnected() => const StreamSrc._(isUnconnected: true);
}

/// scratch 环形缓冲布局项：行号 ℓ 存于槽 ℓ % rows。
class StreamLineBuffer {
  /// 缓冲名（物化流 e0/e1/...；派生环 `xxx_ys` / `xxx_yuv` / `xxx_h` /
  /// `xxx_gr`；gaussian 权重核 `xxx_gk`）。
  final String name;

  /// 帧通道数（非行缓冲时为总元素数，见 [rowWidth]）。
  final int channels;

  /// 环形行数（单行=1；窗口输入环=2r+1；延迟 FIFO=delay 差+1）。
  final int rows;

  /// 元素 C 类型（uint16_t 行缓冲；double：gaussian 水平趟 ring 与
  /// 权重核——卷积中间值按 c_ref 保持双精度）。
  final String cType;

  /// 行宽表达式（默认 `(size_t)(w)`；null = 非行缓冲，总元素数 =
  /// channels，如 gaussian 权重核 k_len 个 double）。
  final String? rowWidth;

  const StreamLineBuffer(this.name, this.channels,
      {this.rows = 1, this.cType = 'uint16_t', this.rowWidth = '(size_t)(w)'});

  /// scratch 字节数表达式项（行缓冲无 h 因子——不存整帧）。
  String get bytesExpr => rowWidth == null
      ? '(size_t)${channels}u * sizeof($cType)'
      : rows == 1
          ? '$rowWidth * ${channels}u * sizeof($cType)'
          : '$rowWidth * ${channels}u * ${rows}u * sizeof($cType)';
}

/// 阶段的一个物化输出目标。
class StreamTarget {
  /// 注册输出端口名（图端口名；gamma out_rgba 归一为 out）。
  final String port;

  /// wrapper 的输出端口名（查行核输出变量表用）。
  final String wrapperPort;

  /// 物化到的 scratch 环形缓冲索引（[GroupStreamPlan.lineBuffers]）；
  /// null 表示无组内消费者，仅写外部输出。
  final int? lineBuffer;

  /// 外部输出形参（该流同时是编组外部输出时非 null）。
  final GroupCExtPort? extOutput;

  /// 帧通道数与 C 类型（uint16_t / uint8_t——gamma rgba8）。
  final int channels;
  final String cType;

  const StreamTarget({
    required this.port,
    required this.wrapperPort,
    required this.lineBuffer,
    required this.extOutput,
    required this.channels,
    required this.cType,
  });
}

/// 一个行循环阶段：计算链尾节点全部物化输出流的第 y-delay 行。
class StreamStage {
  /// 链尾节点 id（物化流生产者）。
  final String nodeId;

  /// 融合链（拓扑序，含链尾本身）：链上非物化中间值走局部变量；
  /// 链中至多一个窗口节点（其输入流强制物化，链在此截断）。
  final List<String> chain;

  /// 物化输出目标（≥1；同节点多端口在同一行循环内计算）。
  final List<StreamTarget> targets;

  /// 链尾节点的行延迟（路径上窗口半径之和；阶段在驱动迭代 y 计算第
  /// y-delay 行）。
  final int delay;

  const StreamStage({
    required this.nodeId,
    required this.chain,
    required this.targets,
    required this.delay,
  });
}

/// 窗口节点的发射信息（[GroupStreamPlan.windowInfos]）。
class StreamWindowNodeInfo {
  /// 垂直半径 r（Bayer 同相位节点为 2，其余 1）。
  final int radius;

  /// wrapper 输入端口名（窗口节点全为单输入）。
  final String inputPort;

  /// 输入流环形缓冲索引（[GroupStreamPlan.lineBuffers]）；-1 表示输入为
  /// 外部输入帧（调用方整帧缓冲直接寻址，不另配环形）。
  final int inputBuffer;

  /// 派生环形缓冲（sharpen/edge_extract 的亮度环 3 行 × 1ch、rgb_dnr 的
  /// yuv 环 3 行 × 3ch），计入 scratch 布局。
  final List<StreamLineBuffer> internalBuffers;

  /// dpc 原地语义：dy<=0 的窗口行读输出环（已处理行，含当前行——行循环
  /// 前先把输入当前行拷入输出环），dy>0 读输入环（未处理行）。
  final bool inPlace;

  const StreamWindowNodeInfo({
    required this.radius,
    required this.inputPort,
    required this.inputBuffer,
    this.internalBuffers = const [],
    this.inPlace = false,
  });
}

/// 行级流水规划产物：[planGroupStream] 的输出。
class GroupStreamPlan {
  /// 整帧版规划产物（拓扑序、wrappers、外部输入/输出等）。
  final GroupCPlan plan;

  /// 行循环阶段（执行序 = 链尾节点拓扑序）。
  final List<StreamStage> stages;

  /// scratch 环形缓冲布局项（物化流，阶段发现序）。
  final List<StreamLineBuffer> lineBuffers;

  /// 每节点每 wrapper 输入端口的流来源解析（'nodeId:port' → StreamSrc，
  /// 已含 gamma 穿透）。
  final Map<String, StreamSrc> inputSrcs;

  /// 物化内部流 → 行缓冲索引（'nodeId:port' → lineBuffers 下标）。
  final Map<String, int> streamBufferIndex;

  /// 链上 gamma 节点 id（拓扑序）：每个需要一块 max_value+1 字节的
  /// 色调映射 LUT scratch 区。
  final List<String> gammaLutNodeIds;

  /// scratch 竞技场总大小求和项（环形缓冲 → 派生环 → gamma LUT）。
  final List<String> scratchTerms;

  /// 每节点的行延迟（nodeId → delay = 上游最大延迟 + 本节点窗口半径）。
  final Map<String, int> streamDelays;

  /// 窗口节点信息（nodeId → StreamWindowNodeInfo）。
  final Map<String, StreamWindowNodeInfo> windowInfos;

  /// 最大阶段延迟（尾部冲刷行数；0 = 无冲刷，纯点对点形态）。
  final int maxDelay;

  const GroupStreamPlan({
    required this.plan,
    required this.stages,
    required this.lineBuffers,
    required this.inputSrcs,
    required this.streamBufferIndex,
    required this.gammaLutNodeIds,
    required this.scratchTerms,
    required this.streamDelays,
    required this.windowInfos,
    required this.maxDelay,
  });

  /// 是否需要 scratch 形参（有布局项时 run() 带 void *scratch +
  /// size_t scratch_bytes 与大小校验）。
  bool get needsScratch => scratchTerms.isNotEmpty;
}

/// 执行行级流水规划。调用前应先经 validateGroupBlackBoxExport 校验
/// （类型支持集 + demosaic 算法 + 无数据环）；本函数对有环图不死循环
/// （visited 防御），但产出的链顺序无意义。
GroupStreamPlan planGroupStream(GroupCPlan plan) {
  final members = plan.members;

  IspConnection? inGroupConnAt(String nodeId, String port) {
    for (final c in plan.inGroupConns) {
      if (c.toNodeId == nodeId && c.toPort == port) return c;
    }
    return null;
  }

  // 内部流生产者 wrapper 输出端口（regPort → wrapper 端口）。
  CPort? producerOutPort(String nodeId, String regPort) {
    for (final cp in plan.wrappers[nodeId]!.outputs) {
      if ((cp.name == 'out_rgba' ? 'out' : cp.name) == regPort) return cp;
    }
    return null;
  }

  // 消费端口 → 流来源（gamma 直通沿其输入向上解析，与整帧版
  // inputBufferOf 同口径；组内连接只查裁剪后的活边 inGroupConns）。
  StreamSrc resolveSrc(String nodeId, String portName) {
    final conn = inGroupConnAt(nodeId, portName);
    if (conn == null) {
      final ext = plan.extInputs['$nodeId:$portName'];
      if (ext != null) return StreamSrc.external(ext);
      return StreamSrc.unconnected();
    }
    var producer = conn.fromNodeId;
    var producerPort = conn.fromPort;
    var guard = 0;
    while (members[producer]!.typeId == 'gamma' && guard++ < 32) {
      final up = inGroupConnAt(producer, 'in');
      if (up == null) {
        final ext = plan.extInputs['$producer:in'];
        if (ext != null) return StreamSrc.external(ext);
        return StreamSrc.unconnected();
      }
      producer = up.fromNodeId;
      producerPort = up.fromPort;
    }
    final cp = producerOutPort(producer, producerPort);
    return StreamSrc.internal(
        producer, producerPort, cp?.name ?? producerPort, cp?.channels ?? 1);
  }

  final inputSrcs = <String, StreamSrc>{
    for (final id in plan.topo)
      for (final cp in plan.wrappers[id]!.inputs)
        '$id:${cp.name}': resolveSrc(id, cp.name),
  };

  // RAW 域双形态选路（与 node_c_gen_raw.dart _isMonoPath 同口径：活动
  // 输入为 in_mono 时按 mono；两端口都不在按 in/bayer）。
  bool isMonoNode(String id) {
    final names = {for (final cp in plan.wrappers[id]!.inputs) cp.name};
    if (names.contains('in')) return false;
    return names.contains('in_mono');
  }

  // 节点窗口半径（0 = 点对点；highlight clip 为纯逐像素，按点对点；
  // morphology radius<=0 / gaussian_blur sigma 或 strength <=0 时 c_ref
  // 为空操作，按点对点直通处理）。
  int windowRadiusOf(String id) {
    final n = members[id]!;
    switch (n.typeId) {
      case 'dpc':
      case 'bayer_dnr':
        return isMonoNode(id) ? 1 : 2;
      case 'sharpen':
      case 'edge_extract':
      case 'rgb_dnr':
      case 'demosaic': // 校验已限定 bilinear
        return 1;
      case 'highlight':
        return n.paramValues['mode'] == 'clip' ? 0 : (isMonoNode(id) ? 1 : 2);
      case 'morphology':
        // 方形结构元半径（缺省 1，与类型默认值一致）。
        final radius = (n.paramValues['radius'] as num?)?.toInt() ?? 1;
        return radius <= 0 ? 0 : radius;
      case 'gaussian_blur':
        // radius = ceil(3σ)（Dart 与 C 同为 IEEE double ceil，逐位一致，
        // 生成期烘焙）；strength/sigma <= 0 时 c_ref 空操作。
        final sigma = (n.paramValues['sigma'] as num?)?.toDouble() ?? 1.0;
        final strength = (n.paramValues['strength'] as num?)?.toDouble() ?? 1.0;
        if (strength <= 0.0 || sigma <= 0.0) return 0;
        return (3.0 * sigma).ceil();
    }
    return 0;
  }

  // ---- 行延迟传播：d(节点) = max(输入流延迟) + 本节点窗口半径 ----
  final streamDelays = <String, int>{};
  for (final id in plan.topo) {
    var d = 0;
    for (final cp in plan.wrappers[id]!.inputs) {
      final src = inputSrcs['$id:${cp.name}']!;
      final sn = src.nodeId;
      if (sn != null && streamDelays[sn]! > d) d = streamDelays[sn]!;
    }
    streamDelays[id] = d + windowRadiusOf(id);
  }

  // ---- 物化规则 ----
  // 消费者环形行数需求与强制物化集：
  // - 窗口节点输入流：强制物化，rows ≥ 2r+1；
  // - 汇合输入流 delay 差 > 0：强制物化（延迟 FIFO），rows ≥ diff+1；
  // - dpc 输出流：强制物化，rows ≥ 2r+1（原地语义：后续读已处理行）。
  // 外部输入流不物化（调用方整帧缓冲直接寻址）。
  final rowDemand = <String, int>{};
  final forceMaterialize = <String>{};
  void demand(String key, int rows) {
    forceMaterialize.add(key);
    final cur = rowDemand[key] ?? 1;
    if (rows > cur) rowDemand[key] = rows;
  }

  for (final id in plan.topo) {
    final r = windowRadiusOf(id);
    final d = streamDelays[id]!;
    for (final cp in plan.wrappers[id]!.inputs) {
      final src = inputSrcs['$id:${cp.name}']!;
      final sn = src.nodeId;
      if (sn == null) continue;
      final key = '$sn:${src.port}';
      final sd = streamDelays[sn]!;
      if (r > 0) {
        demand(key, 2 * r + 1);
      } else if (d > sd) {
        demand(key, d - sd + 1);
      }
    }
    if (members[id]!.typeId == 'dpc') {
      final regPort = isMonoNode(id) ? 'out_mono' : 'out';
      demand('$id:$regPort', 2 * r + 1);
    }
  }

  // 组内消费者计数（穿透后）。
  final consumers = <String, int>{};
  for (final src in inputSrcs.values) {
    if (src.nodeId != null) {
      final key = '${src.nodeId}:${src.port}';
      consumers[key] = (consumers[key] ?? 0) + 1;
    }
  }

  // 物化判定：强制（窗口输入/FIFO/dpc 输出）| 外部输出 | 组内消费者 ≥ 2。
  bool isMaterialized(String nodeId, String regPort) {
    final key = '$nodeId:$regPort';
    return forceMaterialize.contains(key) ||
        plan.extOutputs.containsKey(key) ||
        (consumers[key] ?? 0) >= 2;
  }

  // 融合链收集：从物化流生产者向上递归非物化祖先（后序 = 拓扑序）。
  List<String> collectChain(String stageProducer) {
    final chain = <String>[];
    final visited = <String>{};
    void visit(String id) {
      if (!visited.add(id)) return; // 防御（数据环由校验期拒绝）
      for (final cp in plan.wrappers[id]!.inputs) {
        final src = inputSrcs['$id:${cp.name}']!;
        final sn = src.nodeId;
        if (sn != null && !isMaterialized(sn, src.port!)) visit(sn);
      }
      chain.add(id);
    }

    visit(stageProducer);
    return chain;
  }

  // ---- 行缓冲分配 + 阶段分组（按链尾节点合并物化输出目标）----
  final stages = <StreamStage>[];
  final lineBuffers = <StreamLineBuffer>[];
  final streamBufferIndex = <String, int>{};
  final windowInfos = <String, StreamWindowNodeInfo>{};
  for (final id in plan.topo) {
    final targets = <StreamTarget>[];
    for (final cp in plan.wrappers[id]!.outputs) {
      if (cp.isPersistent) continue;
      final regPort = cp.name == 'out_rgba' ? 'out' : cp.name;
      final key = '$id:$regPort';
      final ext = plan.extOutputs[key];
      final nConsumers = consumers[key] ?? 0;
      if (!isMaterialized(id, regPort)) continue;
      int? bufIdx;
      if (nConsumers >= 1 || forceMaterialize.contains(key)) {
        bufIdx = lineBuffers.length;
        lineBuffers.add(StreamLineBuffer('e$bufIdx', cp.channels,
            rows: rowDemand[key] ?? 1));
        streamBufferIndex[key] = bufIdx;
      }
      targets.add(StreamTarget(
        port: regPort,
        wrapperPort: cp.name,
        lineBuffer: bufIdx,
        extOutput: ext,
        channels: cp.channels,
        cType: cp.cType,
      ));
    }
    // 窗口节点信息（radius > 0）。
    final r = windowRadiusOf(id);
    if (r > 0) {
      final wrapper = plan.wrappers[id]!;
      final inPort = wrapper.inputs.single.name;
      final src = inputSrcs['$id:$inPort']!;
      var bufIdx = -1;
      if (src.nodeId != null) {
        bufIdx = streamBufferIndex['${src.nodeId}:${src.port}']!;
      }
      final typeId = members[id]!.typeId;
      final internal = <StreamLineBuffer>[
        if (typeId == 'sharpen' || typeId == 'edge_extract')
          StreamLineBuffer('${plan.idents[id]}_ys', 1, rows: 2 * r + 1),
        if (typeId == 'rgb_dnr')
          StreamLineBuffer('${plan.idents[id]}_yuv', 3, rows: 2 * r + 1),
        // 分离趟（c_ref 本即为水平趟 + 垂直滑窗结构，见 isp_morphology.c /
        // isp_gaussian_blur.c 文件头）：
        // - morphology：水平趟极值结果环（uint16，2r+1 行）；
        // - gaussian_blur：水平趟卷积结果环（double，2r+1 行）+ 归一化
        //   权重核（k_len 个 double，运行期按 c_ref 同式构建——与整帧版
        //   同 libm，逐位一致）。
        if (typeId == 'morphology')
          StreamLineBuffer('${plan.idents[id]}_h', isMonoNode(id) ? 1 : 3,
              rows: 2 * r + 1),
        if (typeId == 'gaussian_blur') ...[
          StreamLineBuffer('${plan.idents[id]}_gk', 2 * r + 1,
              cType: 'double', rowWidth: null),
          StreamLineBuffer('${plan.idents[id]}_gr', isMonoNode(id) ? 1 : 3,
              rows: 2 * r + 1, cType: 'double'),
        ],
      ];
      windowInfos[id] = StreamWindowNodeInfo(
        radius: r,
        inputPort: inPort,
        inputBuffer: bufIdx,
        internalBuffers: internal,
        inPlace: typeId == 'dpc',
      );
    }
    if (targets.isNotEmpty) {
      stages.add(StreamStage(
        nodeId: id,
        chain: collectChain(id),
        targets: targets,
        delay: streamDelays[id]!,
      ));
    }
  }

  // gamma 色调映射 LUT scratch（每个 gamma 节点一项）。
  final gammaLutNodeIds = [
    for (final id in plan.topo)
      if (members[id]!.typeId == 'gamma') id,
  ];
  final scratchTerms = <String>[
    for (final b in lineBuffers) b.bytesExpr,
    for (final wi in windowInfos.values)
      for (final b in wi.internalBuffers) b.bytesExpr,
    for (final _ in gammaLutNodeIds)
      '(size_t)(max_value + 1) * sizeof(uint8_t)',
  ];
  var maxDelay = 0;
  for (final d in streamDelays.values) {
    if (d > maxDelay) maxDelay = d;
  }

  return GroupStreamPlan(
    plan: plan,
    stages: stages,
    lineBuffers: lineBuffers,
    inputSrcs: inputSrcs,
    streamBufferIndex: streamBufferIndex,
    gammaLutNodeIds: gammaLutNodeIds,
    scratchTerms: scratchTerms,
    streamDelays: streamDelays,
    windowInfos: windowInfos,
    maxDelay: maxDelay,
  );
}

/// 检测组内数据环（splitter/combiner 回环等）：对全部组内成员与全部
/// 组内边（含 mux4 死边——裁剪语义外的保守判定）做 Kahn 拓扑排序，排
/// 不完即有环。无环返回 null，否则返回中文错误说明（列出环上节点名）。
/// 注意不能复用 [GroupCPlan.inGroupConns]（环上节点会被 live 裁剪剔除，
/// 连边随之消失），故直接读图。
String? streamPlanDataCycleError(IspGraph graph, IspNodeGroup group) {
  final memberIds = <String>{
    for (final id in group.nodeIds)
      if (graph.nodes.containsKey(id)) id,
  };
  final conns = [
    for (final c in graph.connections)
      if (memberIds.contains(c.fromNodeId) && memberIds.contains(c.toNodeId))
        c,
  ];
  final indeg = <String, int>{for (final id in memberIds) id: 0};
  for (final c in conns) {
    indeg[c.toNodeId] = indeg[c.toNodeId]! + 1;
  }
  final queue = [for (final e in indeg.entries) if (e.value == 0) e.key];
  var done = 0;
  while (queue.isNotEmpty) {
    final id = queue.removeLast();
    done++;
    for (final c in conns) {
      if (c.fromNodeId == id) {
        final d = indeg[c.toNodeId]! - 1;
        indeg[c.toNodeId] = d;
        if (d == 0) queue.add(c.toNodeId);
      }
    }
  }
  if (done == indeg.length) return null;
  final remaining = [
    for (final e in indeg.entries)
      if (e.value > 0) graph.nodes[e.key]!.name,
  ];
  return '编组内存在数据环（涉及节点：${remaining.join('、')}），'
      '行级流水无法调度。';
}
