import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../utils/build_info.dart';

/// 显示「版本信息」对话框：应用版本、开发环境（编译所用 SDK）、
/// 编译环境（CMake 生成器 / VS 版本）与运行环境。
Future<void> showAppAboutDialog(BuildContext context) async {
  String appVersion = '未知';
  String buildNumber = '';
  try {
    final info = await PackageInfo.fromPlatform();
    if (info.version.isNotEmpty) appVersion = info.version;
    buildNumber = info.buildNumber;
  } catch (_) {
    // 读取失败时保持默认值
  }
  final buildInfo =
      await loadBuildInfo(appVersion: appVersion, buildNumber: buildNumber);
  if (!context.mounted) return;

  showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('版本信息', style: TextStyle(fontSize: 16)),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _InfoGroup(
              title: '应用',
              rows: [
                'DebugToolSet v${buildInfo.appVersion}'
                    '${buildInfo.buildNumber.isNotEmpty ? '+${buildInfo.buildNumber}' : ''}'
                    ' · ${buildInfo.buildMode} 构建',
              ],
            ),
            _InfoGroup(
              title: '开发环境（编译所用 SDK）',
              rows: [
                'Flutter ${buildInfo.flutterVersion} (${buildInfo.flutterChannel})',
                'Dart ${buildInfo.dartVersion}',
                'Framework ${buildInfo.frameworkRevision}'
                    ' · Engine ${buildInfo.engineRevision}',
              ],
            ),
            _InfoGroup(
              title: '编译环境',
              rows: [
                buildInfo.cmakeGenerator ?? '未知（非开发环境）',
              ],
            ),
            _InfoGroup(
              title: '运行环境',
              rows: [
                buildInfo.osVersion,
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}

class _InfoGroup extends StatelessWidget {
  final String title;
  final List<String> rows;

  const _InfoGroup({required this.title, required this.rows});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.only(left: 8, top: 2),
              child: SelectableText(
                row,
                style: const TextStyle(fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }
}
