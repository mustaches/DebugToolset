/// yosys `write_json` 网表模型（**纯 Dart，无 Flutter 依赖**）：把 yosys 的
/// RTL 级网表 JSON 解析成可绘制的模块/单元/引脚/总线结构，供自研电路图
/// 布局与绘制（`widgets/netlist_diagram.dart`）使用。
///
/// 与 netlistsvg 的关键差别：不依赖 ELK 布局与 SVG，全部结构信息（真实
/// 信号名、总线位宽与范围、常量网、单元源位置、子模块引用）在此解析后
/// 由应用自己排布与绘制。
///
/// yosys JSON 口径（实测本工程的 IP 包）：
/// - `cells.<名>.connections.<端口>`：数组（总线，**LSB 在前**）或单个数
///   （位宽 1），成员为网比特号；字符串 `"0"/"1"/"x"/"z"` 为常量绑定；
///   比特号 `0`/`1` 即常量 0/1 网；
/// - `cells.<名>.parameters.*`：字符串（位宽类是 32 位二进制串，如
///   `A_WIDTH="000…10001"`=17；`MEMID` 是存储器名）；
/// - `netnames.<名>.bits`：该名字覆盖的比特（据此把同名比特归组为总线并
///   给线标注真实信号名；范围后缀按比特在该网内的实际下标算，非简单长度）；
/// - 单元名含源位置，如 `$add$isp_ip_multi_band_eq_core.v:257$3108`；
///   子模块实例名形如 `$paramod$<hash>\<模块名>`；
/// - 子模块实例的端口方向按**被引用模块**的端口定义（第二趟解析）。
library;

import 'dart:convert' show jsonDecode;

/// 一条网（总线）：同名比特 + 位宽 + 可选范围。
class NetlistNet {
  /// 显示名（已清理 yosys 前缀；常量网为 `1'b0` 等）。
  final String name;

  /// 位宽范围后缀（整条网时为空）。
  final String range;

  /// 网比特号（LSB 在前）；`0`/`1` 为常量网，负数为 x/z。
  final List<int> bits;

  /// 是否常量网。
  final bool isConst;

  /// 常量值（[isConst] 时有效；含 x/z 为 null）。
  final int? constValue;

  const NetlistNet({
    required this.name,
    required this.bits,
    this.range = '',
    this.isConst = false,
    this.constValue,
  });

  int get width => bits.length;

  bool get isBus => width > 1;

  /// 绘制用显示名（带范围）。
  String get display => '$name$range';

  /// 名字是否由本模型自动派生（`<单元>_<端口>`，非真实信号名）。
  bool get isDerived => RegExp(r'^[a-zA-Z]+\d+_[A-Za-z_]+$').hasMatch(name);

  @override
  String toString() => display;
}

/// 单元引脚方向（绘制时贴块左缘/右缘）。
enum NetlistPortDir {
  /// 输入。
  input('I'),

  /// 输出。
  output('O'),

  /// 双向（inout / IOBUF 类端口）。
  inout('IO');

  const NetlistPortDir(this.label);

  /// 图上标注用的短名（`I`/`O`/`IO`）。
  final String label;

  /// 从 yosys `direction` 字段解析。
  static NetlistPortDir parse(String? s) => switch (s) {
    'output' => NetlistPortDir.output,
    'inout' => NetlistPortDir.inout,
    _ => NetlistPortDir.input,
  };
}

/// 单元引脚：一个 yosys 端口（可能归组为多段网）。
class NetlistPin {
  /// yosys 端口名（如 `A`/`Y`/`ADDR`）。
  final String port;

  /// 该端口连接的各段网（按位序）。
  final List<NetlistNet> nets;

  /// 方向（输入/输出/双向）。
  final NetlistPortDir dir;

  const NetlistPin({required this.port, required this.nets, required this.dir});

  bool get isOutput => dir == NetlistPortDir.output;

  bool get isInout => dir == NetlistPortDir.inout;

  int get width => nets.fold<int>(0, (a, n) => a + n.width);

  /// 引脚显示名（端口名 + 位宽范围；**双向引脚加 `IO` 前缀**，与输入/输出
  /// 引脚靠左右位置区分不同，双向没有天然侧向，需文字标注）。
  String get display {
    final base = width > 1 ? '$port[${width - 1}:0]' : port;
    return dir == NetlistPortDir.inout ? 'IO $base' : base;
  }

  /// 该引脚是否接了常量。
  bool get isConst => nets.isNotEmpty && nets.every((n) => n.isConst);
}

/// 网表单元类别（决定块标题与配色分组）。
enum NetlistCellKind {
  seq, // 时序：$dff/$adff/$dlatch
  mem, // 存储：$memrd/$mem
  arith, // 算术：$add/$sub/$mul
  compare, // 比较：$gt/$lt/$eq
  mux, // 选择：$mux/$pmux
  logic, // 逻辑：$and/$or/$not
  shift, // 移位：$shl/$shr
  instance, // 子模块实例
  other,
}

/// 网表单元（RTL 级）。
class NetlistCell {
  /// yosys 单元名（含源位置与唯一 id）。
  final String name;

  /// yosys 类型（`$add`/`$mux`/…；实例为参数化模块名）。
  final String type;

  final NetlistCellKind kind;

  /// 块下方类型短名（`ADD`/`MUX`/`ADFF`/`ROM`）。
  final String typeLabel;

  /// 块上方实例名（短、唯一、人类可读）。
  final String label;

  /// 中文功能说明（提示/图例）。
  final String desc;

  /// 源位置（`core.v:257`），无则 null。
  final String? source;

  /// 子模块实例引用的模块名（非实例为 null）。
  final String? moduleRef;

  /// 存储器名（`$memrd`/`$mem` 的 `MEMID`），无则 null。
  final String? memId;

  final List<NetlistPin> ins;
  final List<NetlistPin> outs;

  /// 参数（位宽类 `WIDTH`/`Y_WIDTH`… 已由 32 位二进制串解析为整数）。
  final Map<String, int> params;

  const NetlistCell({
    required this.name,
    required this.type,
    required this.kind,
    required this.typeLabel,
    required this.label,
    required this.desc,
    this.source,
    this.moduleRef,
    this.memId,
    required this.ins,
    required this.outs,
    this.params = const {},
  });

  bool get isInstance => kind == NetlistCellKind.instance;

  /// 位宽（取 `WIDTH`/`Y_WIDTH`/`A_WIDTH`/`ABITS`，缺省 null）。
  int? get width =>
      params['WIDTH'] ??
      params['Y_WIDTH'] ??
      params['A_WIDTH'] ??
      params['ABITS'];

  /// 是否绘制（非逻辑单元——ROM 初始化 / 层次调试 / 形式断言——一律跳过：
  /// 每个 ROM 字一个常量框会把画布撑成不可读的长条）。
  static bool isDrawable(String type) {
    const skip = [
      r'$meminit',
      r'$scopeinfo',
      r'$print',
      r'$assert',
      r'$check',
      r'$cover',
      r'$specify',
      r'$connect',
    ];
    for (final s in skip) {
      if (type.startsWith(s)) return false;
    }
    return true;
  }
}

/// 模块端口（顶层 IO）：方向（输入/输出/双向）+ 网。
class NetlistPort {
  final String name;
  final NetlistPortDir dir;
  final NetlistNet net;

  const NetlistPort({required this.name, required this.dir, required this.net});

  bool get isInput => dir == NetlistPortDir.input;

  bool get isOutput => dir == NetlistPortDir.output;

  bool get isInout => dir == NetlistPortDir.inout;
}

/// 网表模块：端口 + 单元 + 比特→网名映射。
class NetlistModule {
  final String name;
  final List<NetlistPort> inputs;
  final List<NetlistPort> outputs;

  /// 双向端口（inout）。
  final List<NetlistPort> inouts;
  final List<NetlistCell> cells;

  /// 比特号 → 显示名（真实信号名优先，缺省用驱动单元派生名）。
  final Map<int, String> bitNames;

  const NetlistModule({
    required this.name,
    required this.inputs,
    required this.outputs,
    this.inouts = const [],
    required this.cells,
    required this.bitNames,
  });

  List<NetlistPort> get ports => [...inputs, ...outputs, ...inouts];

  /// 端口方向统计（I/O/IO 计数；工具栏显示与图例用）。
  Map<NetlistPortDir, int> get portDirCounts {
    final m = <NetlistPortDir, int>{};
    for (final p in ports) {
      m[p.dir] = (m[p.dir] ?? 0) + 1;
    }
    return m;
  }

  /// 子模块实例（下钻目标）。
  List<NetlistCell> get instances => [
    for (final c in cells)
      if (c.isInstance) c,
  ];

  /// 单元按类别计数（状态栏/图例用）。
  Map<NetlistCellKind, int> get kindCounts {
    final m = <NetlistCellKind, int>{};
    for (final c in cells) {
      m[c.kind] = (m[c.kind] ?? 0) + 1;
    }
    return m;
  }
}

/// 解析结果：全部模块（名字 → 模块）。
class YosysNetlist {
  final Map<String, NetlistModule> modules;

  const YosysNetlist(this.modules);

  /// 解析 yosys `write_json` 产物。
  static YosysNetlist parse(String json) {
    final root = jsonDecode(json) as Map<String, dynamic>;
    final raw =
        (root['modules'] as Map<String, dynamic>?) ?? const <String, dynamic>{};

    // 第一趟：收集每个模块的端口方向（子模块实例的引脚方向据此判定，
    // 否则实例的 out_data 会被误判成输入）。同时按「清理后的模块名」
    // 建索引——实例类型是参数化名（`$paramod$hash\core`），而 JSON 里的
    // 模块键也可能是参数化名，两侧都要能对上。
    final dirs = <String, Map<String, NetlistPortDir>>{};
    final dirsClean = <String, Map<String, NetlistPortDir>>{};
    for (final e in raw.entries) {
      final ports =
          ((e.value as Map<String, dynamic>)['ports']
              as Map<String, dynamic>?) ??
          const <String, dynamic>{};
      final m = <String, NetlistPortDir>{};
      for (final pe in ports.entries) {
        m[pe.key] = NetlistPortDir.parse(
          (pe.value as Map<String, dynamic>)['direction'] as String?,
        );
      }
      dirs[e.key] = m;
      final clean = instanceModuleName(e.key);
      if (clean != null) dirsClean[clean] = m;
    }

    // 第二趟：解析模块。
    final modules = <String, NetlistModule>{};
    for (final e in raw.entries) {
      modules[e.key] = _parseModule(
        e.key,
        e.value as Map<String, dynamic>,
        dirs,
        dirsClean,
      );
    }
    return YosysNetlist(modules);
  }

  /// 取模块：精确名 → 参数化后缀匹配（`$paramod$hash\name`）。
  NetlistModule? module(String name) {
    final exact = modules[name];
    if (exact != null) return exact;
    final clean = instanceModuleName(name);
    if (clean != null && modules.containsKey(clean)) return modules[clean];
    for (final e in modules.entries) {
      if (e.key.endsWith('\\$name')) return e.value;
    }
    return modules.length == 1 ? modules.values.first : null;
  }

  /// 解析实例引用的模块（`$paramod$hash\name` → 模块）。
  NetlistModule? resolveInstance(String cellType) => module(cellType);
}

/// `$paramod$hash\mod` → `mod`；普通名原样返回（非实例返回 null）。
String? instanceModuleName(String type) {
  if (type.isEmpty) return null;
  if (!type.startsWith(r'$')) return type;
  final m = RegExp(r'^\$paramod(?:\$[0-9a-f]+)?\\(.+)$').firstMatch(type);
  return m?.group(1);
}

NetlistModule _parseModule(
  String name,
  Map<String, dynamic> j,
  Map<String, Map<String, NetlistPortDir>> dirs,
  Map<String, Map<String, NetlistPortDir>> dirsClean,
) {
  final rawPorts = (j['ports'] as Map<String, dynamic>?) ?? const {};
  final rawCells = (j['cells'] as Map<String, dynamic>?) ?? const {};
  final rawNets = (j['netnames'] as Map<String, dynamic>?) ?? const {};

  // ---- 网名候选：比特 → [(名字, 该比特在网内下标)] ----
  final cand = <int, List<_NameRef>>{};
  for (final e in rawNets.entries) {
    final cleaned = _cleanName(e.key);
    final bits = _bitsOf((e.value as Map<String, dynamic>)['bits']);
    for (var i = 0; i < bits.length; i++) {
      (cand[bits[i]] ??= []).add(_NameRef(cleaned, i, bits.length));
    }
  }

  // ---- 端口（端口名即最权威的网名，插到候选最前）----
  final inputs = <NetlistPort>[];
  final outputs = <NetlistPort>[];
  final inouts = <NetlistPort>[];
  for (final e in rawPorts.entries) {
    final pj = e.value as Map<String, dynamic>;
    final bits = _bitsOf(pj['bits']);
    final dir = NetlistPortDir.parse(pj['direction'] as String?);
    for (var i = 0; i < bits.length; i++) {
      (cand[bits[i]] ??= []).insert(0, _NameRef(e.key, i, bits.length));
    }
    final net = NetlistNet(name: e.key, bits: bits);
    final port = NetlistPort(name: e.key, dir: dir, net: net);
    switch (dir) {
      case NetlistPortDir.input:
        inputs.add(port);
      case NetlistPortDir.output:
        outputs.add(port);
      case NetlistPortDir.inout:
        inouts.add(port);
    }
  }

  // ---- 单元 ----
  final cells = <NetlistCell>[];
  for (final e in rawCells.entries) {
    final cj = e.value as Map<String, dynamic>;
    final type = (cj['type'] as String?) ?? '';
    if (!NetlistCell.isDrawable(type)) continue;
    final conns = (cj['connections'] as Map<String, dynamic>?) ?? const {};
    final rawParams = (cj['parameters'] as Map<String, dynamic>?) ?? const {};
    final params = _parseParams(rawParams);
    final kind = kindOf(type);
    final ref = instanceModuleName(type);
    final refDirs = ref == null
        ? null
        : (dirs[type] ?? dirsClean[ref] ?? dirs[ref]);
    final ins = <NetlistPin>[];
    final outs = <NetlistPin>[];
    for (final ce in conns.entries) {
      final bits = _bitsOf(ce.value);
      final dir = _dirOfPort(type, ce.key, refDirs);
      final pin = NetlistPin(
        port: ce.key,
        nets: _groupBits(bits, cand),
        dir: dir,
      );
      // 双向引脚放块右缘（左侧留给输入）——否则 inout 端口与块左缘的引脚
      // 相连会横穿块体。
      ((pin.isOutput || pin.isInout) ? outs : ins).add(pin);
    }
    // 引脚顺序：实例按被引用模块的端口声明序；其余按类型惯例表。
    if (refDirs != null) {
      final order = refDirs.keys.toList();
      int idx(String p) => order.indexOf(p);
      ins.sort((a, b) => idx(a.port).compareTo(idx(b.port)));
      outs.sort((a, b) => idx(a.port).compareTo(idx(b.port)));
    } else {
      ins.sort(
        (a, b) => _portOrder(type, a.port).compareTo(_portOrder(type, b.port)),
      );
      outs.sort(
        (a, b) => _portOrder(type, a.port).compareTo(_portOrder(type, b.port)),
      );
    }

    // 子模块实例：块上方为**实例名**（Verilog 里的 `u_core`），块下方为
    // **模块名**；逻辑单元：上方为短实例名（`add836`），下方为类型名（`ADD`）。
    final (String, String) meta = ref != null ? (ref, '子模块实例') : cellMeta(type);
    cells.add(
      NetlistCell(
        name: e.key,
        type: type,
        kind: kind,
        typeLabel: meta.$1,
        label: ref != null
            ? _instanceName(e.key, ref)
            : instanceLabel(e.key, type, meta.$1),
        desc: meta.$2,
        source: sourceOf(e.key),
        moduleRef: ref,
        memId: _cleanMemId(rawParams['MEMID']?.toString()),
        ins: ins,
        outs: outs,
        params: params,
      ),
    );
  }

  // 布局顺序：先时序/存储（图上方的参考点），再按类型与名字稳定排序。
  cells.sort((a, b) {
    final k = a.kind.index.compareTo(b.kind.index);
    return k != 0 ? k : a.name.compareTo(b.name);
  });
  _dedupLabels(cells);

  // ---- 比特名：真实名优先；否则用驱动单元派生名 ----
  final bitNames = <int, String>{};
  for (final e in cand.entries) {
    var best = e.value.first;
    for (final r in e.value) {
      if (_cmpRef(r, best) > 0) best = r;
    }
    bitNames[e.key] = best.name;
  }
  bitNames[0] = "1'b0";
  bitNames[1] = "1'b1";
  for (final c in cells) {
    for (final p in c.outs) {
      for (final n in p.nets) {
        for (final b in n.bits) {
          final cur = bitNames[b];
          if (cur == null || _isGeneratedName(cur)) {
            bitNames[b] = '${c.label}_${p.port}';
          }
        }
      }
    }
  }

  return NetlistModule(
    name: name,
    inputs: inputs,
    outputs: outputs,
    inouts: inouts,
    cells: cells,
    bitNames: bitNames,
  );
}

/// 同名标签去重（同名单元追加唯一 id 尾号）。
void _dedupLabels(List<NetlistCell> cells) {
  final seen = <String, int>{};
  for (var i = 0; i < cells.length; i++) {
    final c = cells[i];
    final n = (seen[c.label] ?? 0) + 1;
    seen[c.label] = n;
    if (n > 1) {
      final id = RegExp(r'\$(\d+)$').firstMatch(c.name)?.group(1);
      final label = id == null ? '${c.label}_$n' : '${c.label}_$id';
      cells[i] = NetlistCell(
        name: c.name,
        type: c.type,
        kind: c.kind,
        typeLabel: c.typeLabel,
        label: label,
        desc: c.desc,
        source: c.source,
        moduleRef: c.moduleRef,
        memId: c.memId,
        ins: c.ins,
        outs: c.outs,
        params: c.params,
      );
    }
  }
}

/// 网名引用：名字 + 该比特在网内下标 + 该网总宽。
class _NameRef {
  final String name;
  final int index;
  final int width;
  const _NameRef(this.name, this.index, this.width);
}

/// 把引脚的比特序列归组为总线：同名比特为一段（范围按网内实际下标算），
/// 常量比特（0/1/负数）合并为常量段。
///
/// 选名是**引脚感知**的：端口常是多个信号的拼接、同一批比特有多个别名
///（如 `out_data = {n1_res_h, n1_res_s, n1_res_l}`、`n1_hv17 = in_h` 的
/// 低 8 位），因此优先取「能覆盖整条引脚、且宽度最紧贴引脚跨度」的名字，
/// 这样引脚显示为一个完整总线而不是被拆成碎片。
List<NetlistNet> _groupBits(List<int> bits, Map<int, List<_NameRef>> cand) {
  if (bits.isEmpty) return const [];
  final pinW = bits.length;
  _NameRef pref(int bit) {
    final l = cand[bit];
    if (l == null || l.isEmpty) return _NameRef('n$bit', 0, 1);
    var best = l.first;
    for (final r in l) {
      if (_cmpForPin(r, best, pinW) > 0) best = r;
    }
    return best;
  }

  final out = <NetlistNet>[];
  var i = 0;
  while (i < bits.length) {
    final b = bits[i];
    if (b == 0 || b == 1 || b < 0) {
      var j = i;
      while (j < bits.length && bits[j] == b) {
        j++;
      }
      out.add(_constNet(bits.sublist(i, j)));
      i = j;
      continue;
    }
    final best = pref(b);
    var j = i + 1;
    while (j < bits.length && bits[j] > 1) {
      if (pref(bits[j]).name != best.name) break;
      j++;
    }
    out.add(
      NetlistNet(
        name: best.name,
        bits: bits.sublist(i, j),
        range: _rangeOf(bits.sublist(i, j), cand),
      ),
    );
    i = j;
  }
  return out;
}

/// 引脚内的选名比较：可读名优先 → 能覆盖整条引脚者优先（两者都能时取
/// 宽度更紧贴引脚跨度者）→ 覆盖更宽者优先 → 打分高者优先。
int _cmpForPin(_NameRef a, _NameRef b, int pinW) {
  final ag = _isGeneratedName(a.name), bg = _isGeneratedName(b.name);
  if (ag != bg) return ag ? -1 : 1;
  final ac = a.width >= pinW, bc = b.width >= pinW;
  if (ac != bc) return ac ? 1 : -1;
  if (ac && bc) {
    if (a.width != b.width) return a.width < b.width ? 1 : -1;
  } else if (a.width != b.width) {
    return a.width > b.width ? 1 : -1;
  }
  return _scoreName(a.name).compareTo(_scoreName(b.name));
}

/// 段的范围后缀：整条网（下标连续覆盖 0..w-1）无后缀，否则 `[hi:lo]`。
String _rangeOf(List<int> run, Map<int, List<_NameRef>> cand) {
  final refs = <_NameRef>[];
  for (final b in run) {
    refs.add(_bestRef(b, cand));
  }
  final width = refs.first.width;
  if (refs.length == width) {
    final idx = [for (final r in refs) r.index]..sort();
    var full = true;
    for (var i = 0; i < idx.length; i++) {
      if (idx[i] != i) {
        full = false;
        break;
      }
    }
    if (full) return '';
  }
  var hi = -1, lo = 1 << 30;
  for (final r in refs) {
    hi = r.index > hi ? r.index : hi;
    lo = r.index < lo ? r.index : lo;
  }
  if (hi < 0 || lo > hi) return '';
  return '[$hi:$lo]';
}

/// 由常量比特序列构造常量网（`1'b0` / `8'hFF` / `4'bx`）。
NetlistNet _constNet(List<int> bits) {
  final hasX = bits.any((b) => b < 0);
  if (bits.length == 1) {
    final v = bits.first;
    final name = v == 0
        ? "1'b0"
        : v == 1
        ? "1'b1"
        : "1'bx";
    return NetlistNet(
      name: name,
      bits: bits,
      isConst: !hasX,
      constValue: hasX ? null : v,
    );
  }
  if (hasX) return NetlistNet(name: "${bits.length}'bx", bits: bits);
  var v = 0;
  for (var i = 0; i < bits.length; i++) {
    if (bits[i] == 1) v |= 1 << i;
  }
  final hex = v
      .toRadixString(16)
      .toUpperCase()
      .padLeft((bits.length + 3) ~/ 4, '0');
  return NetlistNet(
    name: "${bits.length}'h$hex",
    bits: bits,
    isConst: true,
    constValue: v,
  );
}

/// 网名优劣比较：**可读名优先**（非 yosys 自动名）→ **覆盖更窄者优先**
/// （端口常是多个信号的拼接，别名同一批比特；此时更窄的内部信号名更贴近
/// 该比特的真实命名，如 `out_data = {n1_res_h, n1_res_s, n1_res_l}`）→
/// 打分更高者优先。返回正数表示 [a] 更优。
int _cmpRef(_NameRef a, _NameRef b) {
  final ag = _isGeneratedName(a.name), bg = _isGeneratedName(b.name);
  if (ag != bg) return ag ? -1 : 1;
  if (a.width != b.width) return a.width < b.width ? 1 : -1;
  return _scoreName(a.name).compareTo(_scoreName(b.name));
}

/// 某比特的最优网名引用。
_NameRef _bestRef(int bit, Map<int, List<_NameRef>> cand) {
  final l = cand[bit];
  if (l == null || l.isEmpty) return _NameRef('n$bit', 0, 1);
  var best = l.first;
  for (final r in l) {
    if (_cmpRef(r, best) > 0) best = r;
  }
  return best;
}

/// 网名打分：真实信号名优先，yosys 自动名靠后。
/// 判据：Verilog 标识符**中间不会出现 `$`**（`$` 只在 yosys 内部名/生成名
/// 里出现，如 `$procmux$18253_Y`、`\s0$ternary$…`），故含 `$` 或含源码
/// 位置的都按生成名重罚，让「驱动单元派生名」接管显示。
int _scoreName(String n) {
  var s = 0;
  if (n.contains(RegExp(r'\.v:\d+'))) s -= 60;
  if (n.contains(r'$')) s -= 50;
  if (n.startsWith(r'$')) s -= 40;
  if (RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(n)) s += 30;
  s -= n.length ~/ 4;
  return s;
}

/// 名字是否由 yosys 自动生成（不可读）。
bool _isGeneratedName(String n) =>
    n.contains(RegExp(r'\.v:\d+')) || n.contains(r'$');

/// yosys 名字清理：去 `$flatten\`/`$paramod$hash\` 层次前缀与 `$<n>\` 别名
/// 前缀，去位宽后缀（`foo[7:0]` → `foo`，位宽由比特数决定）。
String _cleanName(String raw) {
  var s = raw;
  while (true) {
    final m = RegExp(r'^\$?(?:flatten|paramod\$[0-9a-f]+)\\+').firstMatch(s);
    if (m == null) break;
    s = s.substring(m.end);
  }
  final alias = RegExp(r'^\$\d+\\').firstMatch(s);
  if (alias != null) s = s.substring(alias.end);
  // yosys 转义标识符前缀（`\s0$procmux$…` → `s0$procmux$…`）。
  while (s.startsWith(r'\')) {
    s = s.substring(1);
  }
  return s.replaceFirst(RegExp(r'\[\d+:\d+\]$'), '');
}

/// 存储器名清理：去 yosys 层次转义前缀（`\n1_l_mul_q14`）与作用域路径
/// （`u_core.n1_l_mul_q14` → `n1_l_mul_q14`）。
String? _cleanMemId(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  var s = raw.replaceAll(r'\', '');
  final dot = s.lastIndexOf('.');
  if (dot >= 0) s = s.substring(dot + 1);
  return s.isEmpty ? null : s;
}

/// 单元源位置（`…core.v:257$3108` → `core.v:257`）。
String? sourceOf(String cellName) {
  final m = RegExp(r'([A-Za-z0-9_\-.]+\.v):(\d+)').firstMatch(cellName);
  if (m == null) return null;
  final file = m.group(1)!.split(RegExp(r'[/\\]')).last;
  return '$file:${m.group(2)}';
}

/// 子模块实例的实例名（yosys 单元键即 Verilog 实例名；参数化键取尾段）。
String _instanceName(String cellName, String moduleRef) {
  final tail = cellName.split(r'\').last;
  if (tail == cellName) return cellName; // 普通实例名（`u_core`）
  return tail.isEmpty ? moduleRef : tail;
}

/// 单元块上方的实例名：短且唯一（`add257` / `mux5` / 子模块名）。
String instanceLabel(String cellName, String type, String typeLabel) {
  final mod = instanceModuleName(type);
  if (mod != null) return mod;
  final src = sourceOf(cellName);
  final line = src?.split(':').last;
  final id = RegExp(r'\$(\d+)$').firstMatch(cellName)?.group(1);
  final base = typeLabel.toLowerCase();
  if (line != null) return '$base$line';
  if (id != null) return '$base$id';
  final tail = cellName.split(r'$').last;
  return tail.isEmpty ? base : tail;
}

/// 单元类型 →（类型短名, 中文说明, 输出端口集合）；第三项 null = 未知。
(String, String, Set<String>?) cellInfo(String type) {
  const table = <String, (String, String, Set<String>)>{
    r'$add': ('ADD', '加法器', {'Y'}),
    r'$sub': ('SUB', '减法器', {'Y'}),
    r'$mul': ('MUL', '乘法器', {'Y'}),
    r'$div': ('DIV', '除法器', {'Y'}),
    r'$mod': ('MOD', '取模', {'Y'}),
    r'$neg': ('NEG', '取负', {'Y'}),
    r'$pos': ('POS', '取正', {'Y'}),
    r'$and': ('AND', '按位与', {'Y'}),
    r'$or': ('OR', '按位或', {'Y'}),
    r'$xor': ('XOR', '按位异或', {'Y'}),
    r'$xnor': ('XNOR', '按位同或', {'Y'}),
    r'$not': ('NOT', '按位取反', {'Y'}),
    r'$logic_not': ('LNOT', '逻辑非', {'Y'}),
    r'$logic_and': ('LAND', '逻辑与', {'Y'}),
    r'$logic_or': ('LOR', '逻辑或', {'Y'}),
    r'$reduce_and': ('RAND', '归约与', {'Y'}),
    r'$reduce_or': ('ROR', '归约或', {'Y'}),
    r'$reduce_xor': ('RXOR', '归约异或', {'Y'}),
    r'$reduce_bool': ('RBOOL', '归约布尔', {'Y'}),
    r'$shl': ('SHL', '左移', {'Y'}),
    r'$shr': ('SHR', '右移', {'Y'}),
    r'$sshl': ('SSHL', '算术左移', {'Y'}),
    r'$sshr': ('SSHR', '算术右移', {'Y'}),
    r'$shift': ('SHIFT', '移位', {'Y'}),
    r'$shiftx': ('SHIFTX', '带未知移位', {'Y'}),
    r'$lt': ('LT', '小于比较', {'Y'}),
    r'$le': ('LE', '小于等于', {'Y'}),
    r'$gt': ('GT', '大于比较', {'Y'}),
    r'$ge': ('GE', '大于等于', {'Y'}),
    r'$eq': ('EQ', '相等比较', {'Y'}),
    r'$ne': ('NE', '不等比较', {'Y'}),
    r'$mux': ('MUX', '二选一', {'Y'}),
    r'$pmux': ('PMUX', '多路选择', {'Y'}),
    r'$bmux': ('BMUX', '位选择', {'Y'}),
    r'$dff': ('DFF', 'D 触发器', {'Q'}),
    r'$dffe': ('DFFE', '带使能 D 触发器', {'Q'}),
    r'$adff': ('ADFF', '异步复位 D 触发器', {'Q'}),
    r'$adffe': ('ADFFE', '异步复位带使能 DFF', {'Q'}),
    r'$sdff': ('SDFF', '同步复位 D 触发器', {'Q'}),
    r'$sdffe': ('SDFFE', '同步复位带使能 DFF', {'Q'}),
    r'$aldff': ('ALDFF', '异步加载 D 触发器', {'Q'}),
    r'$dffsr': ('DFFSR', '置位复位 D 触发器', {'Q'}),
    r'$dffs': ('DFFS', '置位 D 触发器', {'Q'}),
    r'$dffr': ('DFFR', '复位 D 触发器', {'Q'}),
    r'$dlatch': ('LATCH', 'D 锁存器', {'Q'}),
    r'$adlatch': ('ALATCH', '异步复位锁存器', {'Q'}),
    r'$sr': ('SRL', 'SR 锁存器', {'Q'}),
    r'$memrd': ('ROM', 'ROM 读口', {'DATA'}),
    r'$memrd_v2': ('ROM', 'ROM 读口', {'DATA'}),
    r'$memwr': ('MEMWR', '存储器写口', <String>{}),
    r'$memwr_v2': ('MEMWR', '存储器写口', <String>{}),
    r'$mem': ('MEM', '存储器', {'RD_DATA'}),
    r'$tribuf': ('TBUF', '三态缓冲', {'Y'}),
  };
  return table[type] ?? (type.replaceFirst(r'$', '').toUpperCase(), '单元', null);
}

/// 单元类型 →（类型短名, 中文说明）。
(String, String) cellMeta(String type) {
  final i = cellInfo(type);
  return (i.$1, i.$2);
}

/// 单元端口方向：按被引用模块 > 类型表 > 常见端口名启发式判定。
NetlistPortDir _dirOfPort(
  String type,
  String port,
  Map<String, NetlistPortDir>? refDirs,
) {
  if (refDirs != null) return refDirs[port] ?? NetlistPortDir.input;
  final outs = cellInfo(type).$3;
  if (outs != null) {
    return outs.contains(port) ? NetlistPortDir.output : NetlistPortDir.input;
  }
  return (port == 'Y' || port == 'Q' || port == 'DATA' || port == 'RD_DATA')
      ? NetlistPortDir.output
      : NetlistPortDir.input;
}

/// 绘制时端口排序权重（数据输入在上、控制输入在下）。
int _portOrder(String type, String port) {
  const order = <String, int>{
    'A': 0,
    'B': 1,
    'S': 2,
    'ADDR': 0,
    'D': 0,
    'DATA': 3,
    'EN': 4,
    'CLK': 5,
    'ARST': 6,
    'SRST': 7,
    'SET': 8,
    'CLR': 9,
    'RD_ADDR': 0,
    'RD_DATA': 1,
    'RD_EN': 4,
    'RD_CLK': 5,
    'WR_ADDR': 0,
    'WR_DATA': 1,
    'WR_EN': 4,
    'WR_CLK': 5,
    'Y': 0,
    'Q': 0,
  };
  return order[port] ?? 3;
}

/// `parameters` 解析：位宽类为 32 位二进制串 → 整数；其余按十进制。
Map<String, int> _parseParams(Map<String, dynamic> raw) {
  final out = <String, int>{};
  for (final e in raw.entries) {
    final v = e.value;
    if (v is int) {
      out[e.key] = v;
      continue;
    }
    final s = v?.toString() ?? '';
    if (s.isEmpty) continue;
    if (RegExp(r'^[01]{2,}$').hasMatch(s)) {
      out[e.key] = int.parse(s, radix: 2);
    } else {
      final d = int.tryParse(s);
      if (d != null) out[e.key] = d;
    }
  }
  return out;
}

/// 连接值归一化为比特列表（数组 LSB 在前；单数为位宽 1；字符串常量）。
List<int> _bitsOf(dynamic v) {
  if (v == null) return const [];
  if (v is int) return [v];
  if (v is String) return [_constBit(v)];
  if (v is List) {
    return [
      for (final e in v)
        if (e is int) e else _constBit(e?.toString() ?? 'x'),
    ];
  }
  return const [];
}

int _constBit(String s) {
  switch (s) {
    case '0':
      return 0;
    case '1':
      return 1;
    case 'x':
      return -1;
    case 'z':
      return -2;
    default:
      return -1;
  }
}

/// 单元类型 → 类别。
NetlistCellKind kindOf(String type) {
  if (!type.startsWith(r'$')) return NetlistCellKind.instance;
  switch (type) {
    case r'$add':
    case r'$sub':
    case r'$mul':
    case r'$div':
    case r'$mod':
    case r'$neg':
    case r'$pos':
      return NetlistCellKind.arith;
    case r'$and':
    case r'$or':
    case r'$xor':
    case r'$xnor':
    case r'$not':
    case r'$logic_not':
    case r'$logic_and':
    case r'$logic_or':
    case r'$reduce_and':
    case r'$reduce_or':
    case r'$reduce_xor':
    case r'$reduce_bool':
    case r'$tribuf':
      return NetlistCellKind.logic;
    case r'$lt':
    case r'$le':
    case r'$gt':
    case r'$ge':
    case r'$eq':
    case r'$ne':
      return NetlistCellKind.compare;
    case r'$shl':
    case r'$shr':
    case r'$sshl':
    case r'$sshr':
    case r'$shift':
    case r'$shiftx':
      return NetlistCellKind.shift;
    case r'$mux':
    case r'$pmux':
    case r'$bmux':
      return NetlistCellKind.mux;
    case r'$dff':
    case r'$dffe':
    case r'$adff':
    case r'$adffe':
    case r'$sdff':
    case r'$sdffe':
    case r'$aldff':
    case r'$dffsr':
    case r'$dffs':
    case r'$dffr':
    case r'$dlatch':
    case r'$adlatch':
    case r'$sr':
      return NetlistCellKind.seq;
    default:
      if (type.startsWith(r'$mem')) return NetlistCellKind.mem;
      if (type.startsWith(r'$paramod')) return NetlistCellKind.instance;
      return NetlistCellKind.other;
  }
}

/// 生成当前模块的人类可读网表文本（「查看网表」对话框与复制用）。
String netlistModuleText(NetlistModule module) {
  final b = StringBuffer();
  b.writeln('module ${module.name}');
  b.writeln();
  b.writeln('ports (${module.ports.length}):');
  for (final p in module.ports) {
    final dir = switch (p.dir) {
      NetlistPortDir.input => 'input',
      NetlistPortDir.output => 'output',
      NetlistPortDir.inout => 'inout',
    };
    final width = p.net.width;
    final name = width > 1 ? '${p.name}[${width - 1}:0]' : p.name;
    b.writeln('  ${dir.padRight(6)} $name');
  }
  b.writeln();
  b.writeln('cells (${module.cells.length}):');
  for (final c in module.cells) {
    final src = c.source == null ? '' : '  // ${c.source}';
    b.writeln('  ${c.typeLabel.padRight(6)} ${c.label}  (${c.type})$src');
    for (final p in c.ins) {
      b.writeln('    in   ${p.display.padRight(14)} <- ${_nlPinNets(p)}');
    }
    for (final p in c.outs) {
      b.writeln('    out  ${p.display.padRight(14)} -> ${_nlPinNets(p)}');
    }
  }
  final nets = <String, NetlistNet>{};
  for (final p in module.ports) {
    nets[p.net.display] = p.net;
  }
  for (final c in module.cells) {
    for (final p in [...c.ins, ...c.outs]) {
      for (final n in p.nets) {
        nets[n.display] = n;
      }
    }
  }
  b.writeln();
  b.writeln('nets (${nets.length}):');
  for (final n in nets.values) {
    final kind = n.isConst ? '  const' : '';
    b.writeln('  ${n.display.padRight(26)} ${n.width} bit$kind');
  }
  return b.toString();
}

String _nlPinNets(NetlistPin pin) =>
    pin.nets.isEmpty ? '-' : pin.nets.map((n) => n.display).join(', ');
