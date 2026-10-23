/// ISP Studio 流程图文件的打开/保存对话框（画布右键菜单与主工具栏共用）。
library;

import 'dart:io';

import 'package:file_selector/file_selector.dart';

import '../../../providers/isp_studio_state.dart';

/// 流程图文件类型（JSON 文本，与 .waveform/.uiproj 同一约定）。
const flowTypeGroup = XTypeGroup(
  label: 'ISP 流程',
  extensions: ['ispflow'],
);

/// 打开/保存流程的默认目录（根目录下的 IspFlow，不存在则创建）。
/// 注意：必须使用平台分隔符拼接。Windows 上混用 '/' 会导致
/// file_selector 内部 SHCreateItemFromParsingName 失败（E_INVALIDARG），
/// 文件对话框静默回退到“上次使用的目录”而不是 IspFlow。
Future<Directory> flowDir() async {
  final dir = Directory(
    '${Directory.current.path}${Platform.pathSeparator}IspFlow',
  );
  if (!dir.existsSync()) await dir.create(recursive: true);
  return dir;
}

/// 选择 .ispflow 文件并打开（替换当前图）。
Future<void> openFlowWithDialog(IspStudioState state) async {
  final file = await openFile(
    acceptedTypeGroups: [flowTypeGroup],
    initialDirectory: (await flowDir()).path,
  );
  if (file != null) await state.importGraphFromFile(file.path);
}

/// 把当前流程图保存为 .ispflow 文件；返回是否真正保存
/// （用户在保存对话框中取消返回 false）。
Future<bool> saveFlowWithDialog(IspStudioState state) async {
  final loc = await getSaveLocation(
    suggestedName: '${state.graphTabTitle}.ispflow',
    acceptedTypeGroups: [flowTypeGroup],
    initialDirectory: (await flowDir()).path,
  );
  if (loc == null) return false;
  await state.saveGraphToFile(loc.path);
  return !state.statusMessage.startsWith('保存流程失败');
}
