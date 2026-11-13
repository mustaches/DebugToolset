import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../providers/isp_studio_state.dart';
import '../models/demo_prj_session.dart';
import 'code_browser.dart';

final _errorLogPattern = RegExp(
  r'\b(?:ERROR|FATAL|FAIL|FAILED|FAILURE)\b|CRITICAL WARNING',
  caseSensitive: false,
);
final _warningLogPattern = RegExp(r'\bWARNING\b', caseSensitive: false);
final _successLogPattern = RegExp(
  r'\b(?:PASS|PASSED|SUCCESS)\b|completed successfully',
  caseSensitive: false,
);
final _infoLogPattern = RegExp(r'\bINFO\b', caseSensitive: false);

TextStyle _logLineStyle(String line) {
  if (_errorLogPattern.hasMatch(line)) {
    return kCodeBrowserStyle.copyWith(color: const Color(0xFFF44747));
  }
  if (_warningLogPattern.hasMatch(line)) {
    return kCodeBrowserStyle.copyWith(color: const Color(0xFFD7BA7D));
  }
  if (_successLogPattern.hasMatch(line)) {
    return kCodeBrowserStyle.copyWith(color: const Color(0xFF4EC9B0));
  }
  if (_infoLogPattern.hasMatch(line)) {
    return kCodeBrowserStyle.copyWith(color: const Color(0xFF569CD6));
  }
  return kCodeBrowserStyle;
}

List<TextSpan> highlightVivadoLog(String text) {
  final lines = text.split('\n');
  return [
    for (var i = 0; i < lines.length; i++)
      TextSpan(
        text: i + 1 < lines.length ? '${lines[i]}\n' : lines[i],
        style: _logLineStyle(lines[i]),
      ),
  ];
}

class DemoPrjLogTab extends StatelessWidget {
  final String groupId;

  const DemoPrjLogTab({super.key, required this.groupId});

  @override
  Widget build(BuildContext context) {
    final session = context
        .watch<IspStudioState>()
        .demoPrjSessions['demo:$groupId'];
    if (session == null) {
      return const Center(child: Text('没有 demo 工程生成记录'));
    }
    return DemoPrjLogView(session: session);
  }
}

class DemoPrjLogView extends StatefulWidget {
  final DemoPrjSession session;

  const DemoPrjLogView({super.key, required this.session});

  @override
  State<DemoPrjLogView> createState() => _DemoPrjLogViewState();
}

class _DemoPrjLogViewState extends State<DemoPrjLogView> {
  final _codeController = CodeAreaController();

  @override
  void initState() {
    super.initState();
    widget.session.onChanged = _changed;
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToEnd());
  }

  @override
  void didUpdateWidget(DemoPrjLogView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      oldWidget.session.onChanged = null;
      widget.session.onChanged = _changed;
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToEnd());
    }
  }

  void _scrollToEnd() {
    if (!mounted || widget.session.log.isEmpty) return;
    final lineCount = '\n'.allMatches(widget.session.log.toString()).length + 1;
    _codeController.jumpTo(lineCount);
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToEnd());
  }

  @override
  void dispose() {
    widget.session.onChanged = null;
    _codeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final succeeded = session.result?.success ?? false;
    final color = session.running
        ? const Color(0xFFD7BA7D)
        : succeeded
        ? const Color(0xFF4CAF50)
        : const Color(0xFFCF6679);
    final status = session.running
        ? '生成中…'
        : succeeded
        ? '生成成功'
        : '生成失败';
    final logText = session.log.isEmpty
        ? '等待 Vivado 输出…'
        : session.log.toString();
    return Container(
      color: const Color(0xFF1E1E1E),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 42,
            color: const Color(0xFF252525),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                const Icon(Icons.terminal, size: 16, color: Colors.grey),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${session.projectName} — Vivado',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(status, style: TextStyle(color: color)),
              ],
            ),
          ),
          Expanded(
            child: Container(
              color: const Color(0xFF141414),
              child: CodeArea(
                controller: _codeController,
                spans: highlightVivadoLog(logText),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
