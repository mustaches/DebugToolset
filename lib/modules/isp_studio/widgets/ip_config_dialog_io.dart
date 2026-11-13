/// IP 配置文件对话框的共享路径选择与错误提示。
library;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../codegen/ip_gen_config.dart';

Future<String?> pickSaveIpConfigPath(String extension) async {
  final dir = ipConfigDirectory(extension);
  await dir.create(recursive: true);
  final location = await getSaveLocation(
    suggestedName: 'config.$extension',
    initialDirectory: dir.path,
    confirmButtonText: '保存配置',
    acceptedTypeGroups: [
      XTypeGroup(label: extension, extensions: [extension]),
    ],
  );
  return location?.path;
}

Future<String?> pickOpenIpConfigPath(String extension) async {
  final dir = ipConfigDirectory(extension);
  await dir.create(recursive: true);
  final file = await openFile(
    initialDirectory: dir.path,
    acceptedTypeGroups: [
      XTypeGroup(label: extension, extensions: [extension]),
    ],
  );
  return file?.path;
}

Future<void> showIpConfigError(BuildContext context, Object error) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('配置文件操作失败'),
      content: Text('$error'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('确定'),
        ),
      ],
    ),
  );
}
