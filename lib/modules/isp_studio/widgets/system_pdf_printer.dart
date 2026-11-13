import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';

class SystemPdfPrinter {
  static Future<bool> printDocument({
    required Uint8List bytes,
    required String name,
    required PdfPageFormat format,
    void Function(int completed, int total)? onProgress,
  }) async {
    if (!Platform.isWindows) {
      return Printing.layoutPdf(
        onLayout: (format) async => bytes,
        name: name,
        format: format,
        dynamicLayout: false,
      );
    }

    final tempDirectory = await Directory.systemTemp.createTemp(
      'debug_tool_set_print_',
    );
    try {
      final pdfFile = File('${tempDirectory.path}\\document.pdf');
      await pdfFile.writeAsBytes(bytes, flush: true);
      final executable = File(Platform.resolvedExecutable);
      final worker = '${executable.parent.path}\\debug_pdf_printer.exe';
      final process = await Process.start(worker, [
        pdfFile.path,
        name,
        format.width.toString(),
        format.height.toString(),
      ]);
      final stderrFuture = process.stderr.transform(utf8.decoder).join();
      await for (final line
          in process.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        if (!line.startsWith('PROGRESS ')) continue;
        final parts = line.split(' ');
        if (parts.length == 3) {
          onProgress?.call(int.parse(parts[1]), int.parse(parts[2]));
        }
      }
      final exitCode = await process.exitCode;
      final error = await stderrFuture;
      if (exitCode == 0) return true;
      if (exitCode == 2) return false;
      throw StateError(
        error.trim().isEmpty ? '打印进程异常退出（$exitCode）' : error.trim(),
      );
    } finally {
      await tempDirectory.delete(recursive: true);
    }
  }
}
