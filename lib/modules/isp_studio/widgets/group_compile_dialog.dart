/// 编组 C 代码「编译验证」的目标选择对话框：目标机器（X86 / ARM /
/// Linux 交叉）+ 编译器路径（自动探测，可手改，会话内记住）。只负责
/// 选择，不执行编译——确认后把选择结果返回给编组代码页，由页面打开
/// 终端面板并调 compileGroupCFiles 流式编译。
///
/// 选「Linux 交叉」时的 WSL 探测（冷启动可能 10~30 秒）有明确状态流转：
/// 探测中（环形进度 + 等待文案，路径框保持可输入、结果不覆盖用户输入）
/// → 成功（绿色提示 + 仅当路径框为空时回填）/ 未找到（琥珀色安装提示）。
/// 探测结果缓存到进程级 sessionLinuxCrossWslToolchains：程序不退出时
/// 再次打开对话框直接呈现上次列表，不再探测。
library;

import 'package:flutter/material.dart';

import '../codegen/c_compile.dart';

/// 编译选择结果：目标机器 + 编译器路径（空串表示用自动探测）。
typedef GroupCompileChoice = ({CCompileTarget target, String compilerPath});

/// WSL 探测函数签名（对话框注入点：测试替换为可控延时的假实现；
/// 缺省为真实探测 detectLinuxCrossGccWslAll）。返回全部命中的工具链
///（多发行版/多编译器合并，下拉选择用）。阶段回调收到 'startup'
///（正在启动 WSL）/ 'detect'（正在探测编译器）。
typedef WslProber = Future<List<CToolchain>> Function(
    {Duration startupTimeout,
    Duration timeout,
    void Function(String phase)? onPhase});

/// 打开编译目标选择对话框；取消返回 null。
Future<GroupCompileChoice?> showGroupCompileDialog(BuildContext context,
    {WslProber? wslProber}) {
  return showDialog<GroupCompileChoice>(
    context: context,
    builder: (_) => GroupCompileDialog(wslProber: wslProber),
  );
}

class GroupCompileDialog extends StatefulWidget {
  /// WSL 探测函数注入点；null 时用真实探测。
  final WslProber? wslProber;

  const GroupCompileDialog({super.key, this.wslProber});

  @override
  State<GroupCompileDialog> createState() => _GroupCompileDialogState();
}

class _GroupCompileDialogState extends State<GroupCompileDialog> {
  CCompileTarget _target = CCompileTarget.x86;

  /// 各目标自动探测到的编译器路径（initState 时探测一次）。
  final Map<CCompileTarget, String?> _detected = {};

  /// Linux 交叉：全部探测到的候选编译器路径（Windows PATH + WSL 合并，
  /// 下拉菜单项）。
  final List<String> _crossCandidates = [];

  final _pathController = TextEditingController();

  // ---- Linux 交叉 WSL 探测状态 ----

  /// 探测进行中（显示等待文案与环形进度）。
  bool _probing = false;

  /// 探测结果：true=已探测到，false=未找到（琥珀色安装提示），null=进行中/未探测。
  bool? _probeFound;

  /// 当前探测阶段（'startup' 正在启动 WSL / 'detect' 正在探测编译器）：
  /// 等待文案与「未找到」提示按阶段区分。
  String _probePhase = 'startup';

  /// 探测序号（令牌）：切目标或重新探测时 +1，晚到的旧结果直接丢弃。
  int _probeSeq = 0;

  /// 本次对话框是否已做过 WSL 探测（只探一次，结果并入候选表）。
  bool _wslProbed = false;

  @override
  void initState() {
    super.initState();
    _detected[CCompileTarget.x86] = detectMsvc()?.compilerPath;
    _detected[CCompileTarget.arm] = detectArmGcc()?.compilerPath;
    _crossCandidates
        .addAll(detectLinuxCrossGccAll().map((t) => t.compilerPath));
    // 会话内已有 WSL 探测结果（程序未退出时重开对话框）：直接并入
    // 候选呈现，本次对话框不再探测。
    final cached = sessionLinuxCrossWslToolchains;
    if (cached != null) {
      _mergeCandidates(cached);
      _wslProbed = true;
    }
    _detected[CCompileTarget.linuxCross] = _crossCandidates.firstOrNull;
    _syncPathField();
    // 手动编辑路径时同步下拉折叠态选中项。
    _pathController.addListener(_onPathEdited);
  }

  void _onPathEdited() {
    if (!mounted) return;
    if (_target == CCompileTarget.linuxCross &&
        _crossCandidates.isNotEmpty) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _pathController.removeListener(_onPathEdited);
    _pathController.dispose();
    super.dispose();
  }

  /// 路径输入框内容：会话内手动值优先，否则自动探测结果。
  void _syncPathField() {
    _pathController.text =
        sessionCompilerPaths[_target] ?? _detected[_target] ?? '';
  }

  /// Windows PATH 未命中时异步补 WSL 探测（两阶段：先确认 WSL 启动
  ///（60 秒宽超时覆盖冷启动），就绪后再正式探测（15 秒，从就绪后起算））。
  /// 每次对话框只探一次；结果合并进候选表（下拉菜单），路径框为空时
  /// 回填首个候选，不覆盖用户输入。
  void _startWslProbe() {
    if (_wslProbed) return;
    _wslProbed = true;
    final seq = ++_probeSeq;
    setState(() {
      _probing = true;
      _probeFound = null;
      _probePhase = 'startup';
    });
    final prober = widget.wslProber ?? detectLinuxCrossGccWslAll;
    prober(
      startupTimeout: const Duration(seconds: 60),
      timeout: const Duration(seconds: 15),
      onPhase: (phase) {
        if (!mounted || seq != _probeSeq) return;
        setState(() => _probePhase = phase);
      },
    ).then((list) {
      // 结果写入会话缓存（含空表：探过未命中同样缓存），程序不退出
      // 时重开对话框直接呈现、不再探测；对话框中途关闭也保留缓存。
      sessionLinuxCrossWslToolchains = list;
      // 切目标/重新探测使旧结果失效；对话框已关闭同样丢弃。
      if (!mounted || seq != _probeSeq) return;
      setState(() {
        _probing = false;
        _mergeCandidates(list);
        if (_crossCandidates.isNotEmpty) {
          if (_target == CCompileTarget.linuxCross &&
              _pathController.text.trim().isEmpty) {
            _syncPathField();
          }
          _probeFound = true;
        } else {
          _probeFound = false;
        }
      });
    });
  }

  /// 把探测到的工具链按完整路径去重并入候选表，并刷新 linuxCross 的
  /// 默认探测结果（首个候选，仅在尚未有值时回填）。
  void _mergeCandidates(List<CToolchain> list) {
    for (final tc in list) {
      if (!_crossCandidates.contains(tc.compilerPath)) {
        _crossCandidates.add(tc.compilerPath);
      }
    }
    _detected[CCompileTarget.linuxCross] ??= _crossCandidates.firstOrNull;
  }

  void _switchTarget(CCompileTarget target) {
    if (target == _target) return;
    setState(() {
      _target = target;
      _probing = false; // 离开 Linux 交叉即结束等待态（旧结果凭序号丢弃）
      _probeFound = null;
      _probeSeq++;
      _syncPathField();
    });
    if (target == CCompileTarget.linuxCross) _startWslProbe();
  }

  /// 确认：记住手动路径（会话内），把选择返回给调用方。
  void _confirm() {
    final path = _pathController.text.trim();
    // 手动值会话内记住；与探测结果一致时不必记录。
    if (path.isNotEmpty && path != _detected[_target]) {
      sessionCompilerPaths[_target] = path;
    }
    Navigator.of(context)
        .pop((target: _target, compilerPath: path));
  }

  Widget _targetRadio(CCompileTarget target, String label) {
    return InkWell(
      onTap: () => _switchTarget(target),
      borderRadius: BorderRadius.circular(3),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Radio<CCompileTarget>(
              value: target,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
            Text(label,
                style:
                    const TextStyle(fontSize: 12, color: Colors.white70)),
          ],
        ),
      ),
    );
  }

  /// 候选路径 basename（Windows 与 wsl: 形式均按 / 与 \ 分段）。
  static String _crossBaseName(String path) {
    final segs = path.split(RegExp(r'[/\\]'));
    return segs.isEmpty ? path : segs.last;
  }

  /// 候选来源标签：wsl: <发行版> / Windows。
  static String _crossOrigin(String path) {
    final wsl = parseWslCompilerPath(path);
    return wsl == null ? 'Windows' : 'wsl: ${wsl.distro ?? '默认'}';
  }

  /// Linux 交叉：已探测到的候选编译器下拉菜单（选中写入路径框，
  /// 路径框仍可手动编辑）。
  Widget _crossDropdown() {
    final current = _pathController.text.trim();
    return Row(
      children: [
        const Text('已探测到：',
            style: TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(width: 4),
        Expanded(
          child: DropdownButton<String>(
            isExpanded: true,
            itemHeight: 52,
            dropdownColor: const Color(0xFF2E2E2E),
            hint: const Text('选择已探测到的编译器…',
                style: TextStyle(fontSize: 11, color: Colors.grey)),
            value: _crossCandidates.contains(current) ? current : null,
            // 折叠态单行：basename（来源）。
            selectedItemBuilder: (context) => [
              for (final c in _crossCandidates)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${_crossBaseName(c)}（${_crossOrigin(c)}）',
                    style: const TextStyle(
                        fontSize: 12, color: Colors.white70),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            // 菜单项两行：basename（来源）+ 完整路径。
            items: [
              for (final c in _crossCandidates)
                DropdownMenuItem<String>(
                  value: c,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${_crossBaseName(c)}（${_crossOrigin(c)}）',
                        style: const TextStyle(
                            fontSize: 12, color: Colors.white70),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        c,
                        style: const TextStyle(
                            fontSize: 10, color: Colors.grey),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
            ],
            onChanged: (v) {
              if (v != null) setState(() => _pathController.text = v);
            },
          ),
        ),
      ],
    );
  }

  /// Linux 交叉探测的状态行：等待中 / 已探测到 / 未找到安装提示。
  Widget _probeStatus() {
    if (_probing) {
      return Row(
        children: [
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
                _probePhase == 'startup'
                    ? '正在启动 WSL…'
                    : '正在探测交叉编译器（含 WSL）…',
                style:
                    const TextStyle(fontSize: 11, color: Colors.white70)),
          ),
        ],
      );
    }
    if (_probeFound == true) {
      return const Row(
        children: [
          Icon(Icons.check_circle_outline,
              size: 12, color: Color(0xFF4CAF50)),
          SizedBox(width: 6),
          Expanded(
            child: Text('已自动探测到交叉编译器',
                style: TextStyle(fontSize: 11, color: Color(0xFF4CAF50))),
          ),
        ],
      );
    }
    if (_probeFound == false) {
      // 阶段一（WSL 启动）就失败时补一句「未检测到可用的 WSL」。
      return Text(
        '${_probePhase == 'startup' ? '未检测到可用的 WSL 或交叉工具链。' : '未检测到 Linux 交叉编译器。'}'
        '请安装 aarch64-mix210-linux 或 riscv32-cfg5-musl-…-elf 工具链'
        '（可装在 Windows PATH 或 WSL 发行版的 ~/toolchains 下，'
        '多发行版/多编译器会列入上方下拉菜单），或在上方手动填写 gcc '
        '完整路径（支持 wsl:<发行版>:<路径> 语法）。',
        style: const TextStyle(fontSize: 11, color: Color(0xFFD7BA7D)),
      );
    }
    return const SizedBox.shrink();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF2E2E2E),
      title: const Text('编译验证',
          style: TextStyle(color: Colors.white, fontSize: 14)),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Text('目标机器：',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
                Expanded(
                  child: RadioGroup<CCompileTarget>(
                    groupValue: _target,
                    onChanged: (v) => _switchTarget(v!),
                    // Wrap：三个选项超宽时换行，避免小窗口溢出。
                    child: Wrap(
                      children: [
                        _targetRadio(CCompileTarget.x86, 'X86（本机 MSVC）'),
                        const SizedBox(width: 8),
                        _targetRadio(
                            CCompileTarget.arm, 'ARM（arm-none-eabi-gcc）'),
                        const SizedBox(width: 8),
                        _targetRadio(CCompileTarget.linuxCross, 'Linux 交叉'),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_target == CCompileTarget.linuxCross &&
                _crossCandidates.isNotEmpty) ...[
              _crossDropdown(),
              const SizedBox(height: 8),
            ],
            Row(
              children: [
                const Text('编译器：',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(width: 4),
                Expanded(
                  child: SizedBox(
                    height: 28,
                    child: TextField(
                      controller: _pathController,
                      style: const TextStyle(
                          fontSize: 11,
                          fontFamily: 'Consolas',
                          color: Colors.white70),
                      decoration: InputDecoration(
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 6),
                        border: const OutlineInputBorder(),
                        hintText: switch (_target) {
                          CCompileTarget.x86 => '未检测到 MSVC，留空则编译时再自动探测',
                          CCompileTarget.arm =>
                            '未检测到 arm-none-eabi-gcc，留空则编译时再自动探测',
                          CCompileTarget.linuxCross =>
                            'aarch64-…/riscv32-…-elf-gcc.exe 完整路径，'
                            '或 wsl:发行版:/home/…/bin/…-gcc',
                        },
                        hintStyle: const TextStyle(
                            fontSize: 11, color: Colors.grey),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (_target == CCompileTarget.linuxCross &&
                (_probing || _probeFound != null)) ...[
              const SizedBox(height: 6),
              _probeStatus(),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        ElevatedButton(
          onPressed: _confirm,
          child: const Text('开始编译', style: TextStyle(fontSize: 12)),
        ),
      ],
    );
  }
}
