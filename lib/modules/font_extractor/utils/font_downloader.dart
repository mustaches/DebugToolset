import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

/// GitHub Release 的一个资产。
class BitmapFontAsset {
  final String name;
  final String downloadUrl;
  final int size;

  const BitmapFontAsset({
    required this.name,
    required this.downloadUrl,
    required this.size,
  });
}

/// GitHub 仓库最新 Release 的信息。
class BitmapFontRelease {
  final String tagName;
  final List<BitmapFontAsset> assets;

  const BitmapFontRelease({required this.tagName, required this.assets});
}

/// 查询 [repo]（owner/repo）最新 Release 的标签与资产列表。
/// 网络失败、限流或 JSON 异常时返回 null。
Future<BitmapFontRelease?> fetchLatestRelease(String repo) async {
  HttpClient? client;
  try {
    client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 15);
    final request = await client.getUrl(
      Uri.parse('https://api.github.com/repos/$repo/releases/latest'),
    );
    // GitHub API 要求带 User-Agent。
    request.headers.set(HttpHeaders.userAgentHeader, 'DebugToolSet');
    final response =
        await request.close().timeout(const Duration(seconds: 20));
    if (response.statusCode != HttpStatus.ok) return null;
    final body = await response.transform(utf8.decoder).join();
    final json = jsonDecode(body);
    if (json is! Map<String, dynamic>) return null;
    final tagName = json['tag_name'] as String? ?? '';
    final assets = <BitmapFontAsset>[];
    final rawAssets = json['assets'];
    if (rawAssets is List) {
      for (final a in rawAssets) {
        if (a is! Map<String, dynamic>) continue;
        final name = a['name'] as String?;
        final url = a['browser_download_url'] as String?;
        if (name == null || url == null) continue;
        assets.add(BitmapFontAsset(
          name: name,
          downloadUrl: url,
          size: (a['size'] as num?)?.toInt() ?? 0,
        ));
      }
    }
    return BitmapFontRelease(tagName: tagName, assets: assets);
  } catch (_) {
    return null;
  } finally {
    client?.close();
  }
}

/// 下载 [url] 指向的字体文件到 [saveDir]/[saveAs]，返回最终文件路径。
///
/// - 自动跟随重定向（GitHub 资产会跳转 CDN）。
/// - [onProgress] 按 (已收字节, 总字节) 回调；总字节未知时为 0。
/// - URL 以 .zip 结尾时下载后解压，取包内第一个 .ttf/.otf 存为 [saveAs]。
/// - HTTP 非 200、zip 内无字体文件等情况抛异常。
Future<String> downloadFont(
  String url,
  String saveDir,
  String saveAs, {
  void Function(int received, int total)? onProgress,
}) async {
  final dir = Directory(saveDir);
  if (!dir.existsSync()) dir.createSync(recursive: true);

  final isZip = Uri.parse(url).path.toLowerCase().endsWith('.zip');
  final targetPath = p.join(saveDir, saveAs);
  // zip 先落到临时文件，解压成功后再删。
  final downloadPath =
      isZip ? p.join(saveDir, '$saveAs.download.zip') : targetPath;

  final client = HttpClient();
  client.connectionTimeout = const Duration(seconds: 15);
  try {
    final request = await client.getUrl(Uri.parse(url));
    request.headers.set(HttpHeaders.userAgentHeader, 'DebugToolSet');
    final response =
        await request.close().timeout(const Duration(minutes: 2));
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(url));
    }

    final total = response.contentLength > 0 ? response.contentLength : 0;
    var received = 0;
    final sink = File(downloadPath).openWrite();
    try {
      await for (final chunk in response.timeout(const Duration(minutes: 5))) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
  } finally {
    client.close();
  }

  if (!isZip) return targetPath;

  try {
    final zipBytes = await File(downloadPath).readAsBytes();
    final fontBytes = extractFirstFontFromZip(zipBytes);
    if (fontBytes == null) {
      throw const FormatException('zip 压缩包中未找到 .ttf/.otf 字体文件');
    }
    await File(targetPath).writeAsBytes(fontBytes, flush: true);
    return targetPath;
  } finally {
    final tmp = File(downloadPath);
    if (tmp.existsSync()) tmp.deleteSync();
  }
}

/// 从 zip 字节流中取出第一个 .ttf/.otf 文件的内容；无字体文件返回 null。
/// 单独成函数便于不触网的单元测试。
Uint8List? extractFirstFontFromZip(List<int> zipBytes) {
  final archive = ZipDecoder().decodeBytes(zipBytes);
  for (final file in archive.files) {
    if (!file.isFile) continue;
    final lower = file.name.toLowerCase();
    if (lower.endsWith('.ttf') || lower.endsWith('.otf')) {
      final content = file.content;
      if (content is List<int>) return Uint8List.fromList(content);
    }
  }
  return null;
}
