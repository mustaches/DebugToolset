import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/ui_project.dart';
import 'c_callbacks_codegen.dart';
import 'c_project_codegen.dart';
import 'c_runtime_codegen.dart';

/// Orchestrates C code export: writes ui_runtime.c/h, ui_port.h,
/// ui_pages.c/h and ui_callbacks.c/h into [outputDir].
class CCodeExporter {
  CCodeExporter._();

  /// Returns the list of files written. `ui_callbacks.c` is never
  /// overwritten once it exists (users may have filled in the stubs).
  static Future<List<String>> export(
    UiProject project,
    String outputDir, {
    String? projectDir,
  }) async {
    final written = <String>[];

    Future<List<int>?> assetReader(UiAsset asset) async {
      final bin = asset.binFile;
      if (bin == null) return null;
      final path = p.isAbsolute(bin)
          ? bin
          : (projectDir == null ? null : p.normalize(p.join(projectDir, bin)));
      if (path == null) return null;
      final file = File(path);
      if (!file.existsSync()) return null;
      return file.readAsBytes();
    }

    final result =
        await CProjectCodegen.generate(project, assetReader: assetReader);

    Future<void> write(String name, String content) async {
      final path = p.join(outputDir, name);
      await File(path).writeAsString(content);
      written.add(path);
    }

    await write('ui_runtime.h', CRuntimeCodegen.runtimeHeader());
    await write('ui_runtime.c', CRuntimeCodegen.runtimeSource());
    await write('ui_port.h', CRuntimeCodegen.portHeader());
    await write('ui_pages.h', result.header);
    await write('ui_pages.c', result.source);
    await write('ui_callbacks.h', CCallbacksCodegen.header(result.callbacks));

    final callbacksC = p.join(outputDir, 'ui_callbacks.c');
    if (!File(callbacksC).existsSync()) {
      await File(callbacksC)
          .writeAsString(CCallbacksCodegen.source(result.callbacks));
      written.add(callbacksC);
    }

    if (result.warnings.isNotEmpty) {
      stderr.writeln(result.warnings.join('\n'));
    }
    return written;
  }
}
