import 'dart:io';

import 'package:path/path.dart' as p;

import '../codegen/vivado_runner.dart';

const demoPrjExportLogName = 'demo_prj_export.log';

/// demo 导出时，用户选择的是父目录；实际产物根目录追加工程名。
String demoPrjExportDirectory(String parentDirectory, String projectName) =>
    p.join(parentDirectory, projectName);

Future<void> saveDemoPrjExportLog(String directory, String log) {
  return File(
    '$directory${Platform.pathSeparator}$demoPrjExportLogName',
  ).writeAsString(log);
}

class DemoPrjSession {
  final String projectName;
  final StringBuffer log = StringBuffer();
  bool running = true;
  VivadoDemoResult? result;
  String? error;
  void Function()? onChanged;

  DemoPrjSession(this.projectName);

  void append(String chunk) {
    log.write(chunk);
    onChanged?.call();
  }

  void complete(VivadoDemoResult value) {
    result = value;
    running = false;
    onChanged?.call();
  }

  void fail(Object error) {
    this.error = '$error';
    running = false;
    onChanged?.call();
  }
}
