/// ISP 节点编组导出 C 代码：校验 + top 层 pipeline 生成 + 写盘。
///
/// 生成物（写入用户选定目录，平铺）：
/// - 每个成员节点实例一对 `<节点名>.h/.c`（见 node_c_gen.dart 的 ABI 约定）；
/// - top 层 `isp_pipeline_<组>.h/.c`：run() 接收组外部输入/输出帧缓冲 +
///   一整块 scratch 竞技场，内部按 8 字节对齐切出中间缓冲，按拓扑序
///   逐节点调用；零动态分配（缓冲全部由调用方提供，与 c_ref 规范一致）；
/// - 引用到的 c_ref 算法文件（各封装 algoIncludes 的 .h/.c + isp_common
///   .h/.c）一并拷出，导出目录可独立编译。
///
/// 语义决策（也写进生成文件头注释）：
/// - gamma 有组内下游时：下游直接用 gamma 的输入缓冲（gamma 不改输入，
///   与 Dart 一致）；其 rgba 输出恒作为组输出。
/// - mux4 未选中支路为死路：与 Dart 预览一致裁剪（不调用其上游节点、
///   不分配边缓冲/scratch、不为组外死源生成 run() 形参）。
/// - fluoro_temporal 的 history 走竞技场持久区（scratch 起始段），
///   调用方跨帧复用同一 scratch 时该区数据得以保留。
/// - combiner 未连接的通道输入传 NULL（c_ref 内部填缺省值）。
///
/// 结构为 plan + emit 两段式：全部图推导（拓扑序、裁剪、缓冲布局）在
/// group_c_plan.dart 的 planGroupC 完成，本文件只负责把 GroupCPlan
/// 拼接为代码字符串并写盘。
library;

import 'dart:io';

import '../models/isp_graph.dart';
import '../models/isp_node.dart';
import '../pipeline/node_c_code.dart';
import 'c_ident.dart';
import 'group_c_plan.dart';
import 'group_c_target.dart';
import 'node_c_gen.dart';

export 'group_c_plan.dart'
    show GroupCExtPort, GroupCPlan, groupCTopName, lutDomainMaxOf, planGroupC;

/// 校验编组能否导出 C 代码；可导出返回 null，否则返回中文错误说明。
String? validateGroupCExport(IspGraph graph, IspNodeGroup group) {
  final members = [
    for (final id in group.nodeIds) ?graph.nodes[id],
  ];
  // 例外：多段色彩均衡器（等效多个色彩控制器混叠）与有整行行核的类型
  // 允许单节点编组（见 group_c_target.dart kSingleNodeGroupTypeIds）。
  if (members.length < 2 &&
      !(members.length == 1 &&
          kSingleNodeGroupTypeIds.contains(members.first.typeId))) {
    return '编组成员不足 2 个节点';
  }
  final unsupported = <String>[];
  for (final n in members) {
    if (!cExportSupportedTypeIds.contains(n.typeId)) {
      final display = IspNodeRegistry.byId(n.typeId)?.displayName ?? n.typeId;
      unsupported.add('${n.name}（$display）');
    }
  }
  if (unsupported.isNotEmpty) {
    return '以下节点暂不支持导出 C 代码：${unsupported.join('、')}。\n'
        '目前仅支持 Process（含 ColorTrans/Fluorescence）与 Datapath 类节点。';
  }
  // 多输入节点的全部输入必须已连接（组内或组外），否则生成代码无法
  // 取得对应缓冲。
  const requireAllInputs = {'blender', 'multiplier', 'adder'};
  for (final n in members) {
    if (!requireAllInputs.contains(n.typeId)) continue;
    final type = IspNodeRegistry.byId(n.typeId)!;
    for (final port in type.inputs) {
      if (graph.connectionAt(n.id, port.name) == null) {
        return '节点 ${n.name} 的输入端口 ${port.name} 未连接，无法导出。';
      }
    }
  }
  // mux4：被选中支路必须已连接。
  for (final n in members) {
    if (n.typeId != 'mux4') continue;
    final sel = ((n.paramValues['select'] as num?)?.toInt() ?? 1).clamp(1, 4);
    final type = IspNodeRegistry.byId('mux4')!;
    final connected = type.inputs.any((p) =>
        p.name.startsWith('in$sel') &&
        graph.connectionAt(n.id, p.name) != null);
    if (!connected) {
      return '节点 ${n.name} 选中的第 $sel 路输入未连接，无法导出。';
    }
  }
  return null;
}

/// 导出结果：写出的文件列表（文件名，不含目录）与 top 层名。
class GroupCExportResult {
  final List<String> files;
  final String topName;

  const GroupCExportResult(this.files, this.topName);
}

/// 内存生成编组 C 代码：文件名 → 内容（每节点封装 .h/.c、top 层 .h/.c、
/// 引用到的 c_ref 算法文件）。键顺序与 [exportGroupCCode] 的写盘顺序一致：
/// 节点封装（拓扑序）→ top 层 → c_ref 并集。读取失败的 c_ref 文件
///（如无对应 .c 的头文件）静默跳过，与 exportCRefFiles 行为等价。
/// 生成的 .h/.c 顶部带自动生成块注释（含生成时间，本地时间）；c_ref
/// 算法参考文件原样拷贝，不加注释。
/// [readFile] 测试注入用（c_ref 内容读取，默认 rootBundle 资产）。
/// [genTime] 文件头注释的生成时间：缺省取进入时的 DateTime.now()，
/// 一次调用内所有文件共用同一时间戳；测试可注入固定值保证比对稳定。
Future<Map<String, String>> buildGroupCFiles(
  IspGraph graph,
  IspNodeGroup group, {
  Future<String> Function(String path)? readFile,
  DateTime? genTime,
  GroupCTarget target = GroupCTarget.cortexA53_55,
}) async {
  genTime ??= DateTime.now();
  final plan = planGroupC(graph, group);
  final members = plan.members;
  final topo = plan.topo;
  final wrappers = plan.wrappers;
  final edgeBuffers = plan.edgeBuffers;
  final edgeBytes = plan.edgeBytes;
  final extInputParams = plan.extInputParams;
  final extOutputs = plan.extOutputs;
  final extOutputParams = plan.extOutputParams;
  final persistPorts = plan.persistPorts;
  final persistNames = plan.persistNames;
  final scratchMacros = plan.scratchMacros;
  final topName = plan.topName;

  // 多行宏：每行行尾必须带续行反斜杠。
  final scratchTotal = plan.scratchTerms.isEmpty
      ? '(size_t)0'
      : plan.scratchTerms.map((t) => 'ISP_PIPE_ALIGN8($t)').join(' +\\\n    ');

  // ---- top .h ----
  final runParams = <String>[
    for (final p in extInputParams) 'const ${p.cType} *${p.name}',
    'int w',
    'int h',
    'int max_value',
    for (final p in extOutputParams) '${p.cType} *${p.name}',
    'void *scratch',
    'size_t scratch_bytes',
  ];
  final macro = cMacroPrefix(topName);
  final topGuard = '${macro}_H';
  final topH = '''
#ifndef $topGuard
#define $topGuard

#include "isp_common.h"

#ifdef __cplusplus
extern "C" {
#endif

/* 8 字节对齐（竞技场各区分界）。 */
#define ISP_PIPE_ALIGN8(x) (((size_t)(x) + 7u) & ~(size_t)7u)

/* scratch 竞技场总大小 = 持久区（fluoro_temporal history，跨帧保留，
 * 调用方不得挪作他用） + 组内中间边缓冲 + 各节点 scratch 最大值。 */
#define ${macro}_SCRATCH_BYTES(w, h, max_value) \\
    ($scratchTotal)

/* 逐节点拓扑序调用。输入为组外部输入帧（组外连接或未连接的首要输入），
 * 输出为组外部输出帧（连到组外或组内无下游的成员输出）。 */
int ${topName}_run(${runParams.join(', ')});

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* $topGuard */
''';

  // ---- top .c：切缓冲 → 拓扑序调用 ----
  final carve = <String>['  uint8_t *isp_p = (uint8_t *)scratch;'];
  for (final pp in persistPorts) {
    final name = persistNames['${pp.nodeId}:${pp.port.name}']!;
    carve.add('  uint16_t *$name = (uint16_t *)isp_p;');
    carve.add('  isp_p += ISP_PIPE_ALIGN8(${pp.port.bytesExpr});');
  }
  for (final entry in edgeBuffers.entries) {
    carve.add('  uint16_t *${entry.value} = (uint16_t *)isp_p;');
    carve.add('  isp_p += ISP_PIPE_ALIGN8(${edgeBytes[entry.value]});');
  }
  if (scratchMacros.isNotEmpty) {
    carve.add('  void *node_scratch = (void *)isp_p;');
  }

  final calls = <String>[];
  for (final id in topo) {
    final w = wrappers[id]!;
    final args = <String>[];
    for (final cp in w.inputs) {
      // 未连接的次要输入（如 combiner 空通道）传 NULL。
      args.add(plan.inputBuffers['$id:${cp.name}'] ?? 'NULL');
    }
    args.addAll(['w', 'h', 'max_value']);
    final deferredCopies = <String>[];
    for (final cp in w.outputs) {
      if (cp.isPersistent) {
        args.add(persistNames['$id:${cp.name}']!);
        continue;
      }
      final regPort = cp.name == 'out_rgba' ? 'out' : cp.name;
      final edge = edgeBuffers['$id:$regPort'];
      final ext = extOutputs['$id:$regPort'];
      if (edge != null) {
        args.add(edge);
        // 既是组内边又是组输出：写边缓冲后补拷贝到外部形参。
        if (ext != null) {
          deferredCopies.add('  memcpy(${ext.name}, $edge, ${cp.bytesExpr});');
        }
      } else if (ext != null) {
        args.add(ext.name);
      } else {
        throw StateError(
            '节点 ${members[id]!.name} 的输出 ${cp.name} 既不是组内边也不是组输出');
      }
    }
    if (w.hasScratch) args.add('node_scratch');
    calls.add('  rc = ${w.fileName}_run(${args.join(', ')});');
    calls.add('  if (rc != ISP_OK) return rc;');
    calls.addAll(deferredCopies);
  }

  final topC = '''
#include "$topName.h"

#include <string.h>

${[for (final id in topo) '#include "${wrappers[id]!.fileName}.h"'].join('\n')}

int ${topName}_run(${runParams.join(', ')}) {
  int rc = 0;
  if (scratch == NULL ||
      scratch_bytes < ${macro}_SCRATCH_BYTES(w, h, max_value)) {
    return ISP_ERR_SIZE;
  }
${carve.join('\n')}
${calls.join('\n')}
  return ISP_OK;
}
''';

  // ---- 收集生成物（文件名 → 内容，插入序即写盘顺序）----
  // 生成的 .h/.c 顶部统一带自动生成块注释（同一时间戳）；c_ref 原样拷贝。
  final files = <String, String>{};
  for (final id in topo) {
    final w = wrappers[id]!;
    files['${w.fileName}.h'] = _fileDoc(group, members[id]!, genTime) + w.header;
    files['${w.fileName}.c'] = _fileDoc(group, members[id]!, genTime) + w.source;
  }
  files['$topName.h'] = _topDoc(group, genTime, target) + topH;
  files['$topName.c'] = _topDoc(group, genTime, target) + topC;

  // c_ref 并集：各封装算法头的 .h/.c + isp_common.h/.c（无对应 .c 的
  // 头文件读取失败，静默跳过）。
  final cRefFiles = <String>{
    'isp_common.h',
    'isp_common.c',
    for (final id in topo)
      for (final inc in wrappers[id]!.algoIncludes) ...[
        inc,
        inc.replaceAll('.h', '.c'),
      ],
  };
  for (final f in cRefFiles) {
    try {
      files[f] = await loadCRefFile(f, readFile: readFile);
    } catch (_) {
      // 与 exportCRefFiles 一致：单个文件失败不中断其余文件。
    }
  }
  // 目标微架构说明（加速宏定义 + 实现方案），随代码一并导出。
  files[target.microDocName] = buildTargetCodeMicroDoc(target, blackBox: false);
  return files;
}

/// 把编组导出为 C 代码并写入 [dir]（须已校验，见 [validateGroupCExport]）。
/// [readFile] 测试注入用（c_ref 内容读取，默认 rootBundle 资产）；
/// [genTime] 文件头注释的生成时间（缺省取当前本地时间），测试注入用。
Future<GroupCExportResult> exportGroupCCode(
  IspGraph graph,
  IspNodeGroup group,
  String dir, {
  Future<String> Function(String path)? readFile,
  DateTime? genTime,
  GroupCTarget target = GroupCTarget.cortexA53_55,
}) async {
  final files = await buildGroupCFiles(graph, group,
      readFile: readFile, genTime: genTime, target: target);
  final written = <String>[];
  for (final e in files.entries) {
    await File('$dir/${e.key}').writeAsString(e.value);
    written.add(e.key);
  }
  return GroupCExportResult(written, groupCTopName(group));
}

/// 文件头注释里的生成时间（本地时间，yyyy-MM-dd HH:mm:ss）。
String _fmtGenTime(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} '
      '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

String _fileDoc(IspNodeGroup group, IspNode node, DateTime genTime) => '''
/* 本文件由 DebugToolSet ISP Studio 自动生成：编组「${group.name}」
 * 成员节点 ${node.name}（${node.typeId}）的 C 封装。
 * 生成时间：${_fmtGenTime(genTime)}
 */
''';

String _topDoc(IspNodeGroup group, DateTime genTime, GroupCTarget target) => '''
/* 本文件由 DebugToolSet ISP Studio 自动生成：编组「${group.name}」的
 * top 层 ISP pipeline。语义说明：
 * - gamma 节点的组内下游直接使用 gamma 的输入帧（gamma 不改输入）；
 * - mux4 未选中支路为死路：与 Dart 预览一致裁剪，不生成其上游调用与
 *   缓冲（见 group_c_export.dart 裁剪说明）；
 * - fluoro_temporal 的 history 在 scratch 起始的持久区，跨帧保留；
 * - combiner 未连接的通道输入为 NULL（c_ref 内部填缺省值）。
${target.headerBlock().join('\n')}
 * 生成时间：${_fmtGenTime(genTime)}
 */
''';
