import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../../providers/font_extractor_state.dart';
import '../utils/bitmap_font_catalog.dart';
import '../utils/font_downloader.dart';
import '../utils/font_info.dart';

/// 打开「点阵字库检测与下载」对话框。
Future<void> showBitmapFontDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const BitmapFontDialog(),
  );
}

/// 本地字体的检测结论。
class _LocalFontVerdict {
  /// 内嵌点阵尺寸列表（EBLC/CBLC/bloc 的 ppemY）；空表示无内嵌点阵。
  final List<int> bitmapSizes;

  /// 检测到的设计点阵尺寸（内嵌 strike 或名称中的 Npx 提示）；空表示未知。
  final List<int> designSizes;

  /// 名称启发式判断为像素风格字体（仅推断，不代表一定清晰）。
  final bool looksPixel;

  const _LocalFontVerdict({
    required this.bitmapSizes,
    required this.designSizes,
    required this.looksPixel,
  });
}

/// 在线字体条目的运行时状态。
class _OnlineEntryState {
  BitmapFontRelease? release;
  bool checking = false;
  bool downloading = false;
  int received = 0;
  int total = 0;
  bool downloaded = false;
  String? error;

  /// 从 release 资产中按正则匹配到的下载地址。
  String? resolvedUrl;
  String? resolvedAssetName;
  int resolvedSize = 0;
}

/// 点阵字库检测与下载对话框：本地检测 + 在线清单 + 自定义 URL。
class BitmapFontDialog extends StatefulWidget {
  const BitmapFontDialog({super.key});

  /// 会话内记忆的下载目录（用户用「更改…」选过的目录）。
  static String? sessionDownloadDir;

  @override
  State<BitmapFontDialog> createState() => _BitmapFontDialogState();
}

class _BitmapFontDialogState extends State<BitmapFontDialog> {
  static const _fontExts = {'.ttf', '.otf', '.ttc'};

  late String _downloadDir;

  /// 本地检测条目：路径 → (是否已加载到级联列表, 检测结论)。
  final Map<String, bool> _localLoaded = {};
  final Map<String, _LocalFontVerdict?> _localVerdicts = {};

  final Map<String, _OnlineEntryState> _onlineStates = {
    for (final e in kBitmapFontCatalog) e.id: _OnlineEntryState(),
  };

  final _urlController = TextEditingController();
  bool _customDownloading = false;
  int _customReceived = 0;
  int _customTotal = 0;

  @override
  void initState() {
    super.initState();
    _downloadDir = BitmapFontDialog.sessionDownloadDir ??
        p.join(Directory.current.path, 'Font');
    _startLocalDetection();
    _refreshOnlineInfo();
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------
  // 本地检测
  // ------------------------------------------------------------------

  Future<void> _startLocalDetection() async {
    final state = context.read<FontExtractorState>();
    final candidates = <String, bool>{
      for (final path in state.fontPaths) path: true,
    };
    // 再扫描 Font/ 目录（含下载目录）里未加载的字体。
    for (final dirPath in {p.join(Directory.current.path, 'Font'), _downloadDir}) {
      final dir = Directory(dirPath);
      if (!dir.existsSync()) continue;
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final ext = p.extension(entity.path).toLowerCase();
        if (_fontExts.contains(ext) && !candidates.containsKey(entity.path)) {
          candidates[entity.path] = false;
        }
      }
    }
    if (!mounted) return;
    setState(() {
      _localLoaded
        ..clear()
        ..addAll(candidates);
    });
    // 逐个异步检测，完成一个刷新一个。
    for (final path in candidates.keys) {
      final sizes = await readEmbeddedBitmapSizes(path);
      final designSizes = await detectPixelFontDesignSizes(path);
      if (!mounted) return;
      setState(() {
        _localVerdicts[path] = _LocalFontVerdict(
          bitmapSizes: sizes,
          designSizes: designSizes,
          looksPixel: _looksPixelFont(path),
        );
      });
    }
  }

  /// 名称启发式：文件名含 pixel/点阵/像素/unifont/zpix 等关键字。
  bool _looksPixelFont(String path) {
    final lower = p.basename(path).toLowerCase();
    const keywords = ['pixel', 'bitmap', 'unifont', 'zpix', '点阵', '像素'];
    return keywords.any(lower.contains);
  }

  // ------------------------------------------------------------------
  // 在线清单
  // ------------------------------------------------------------------

  Future<void> _refreshOnlineInfo() async {
    for (final entry in kBitmapFontCatalog) {
      final s = _onlineStates[entry.id]!;
      s.downloaded = File(p.join(_downloadDir, entry.saveAs)).existsSync();
      if (entry.directUrl != null) {
        s.resolvedUrl = entry.directUrl;
        s.resolvedAssetName = fileNameFromUrl(entry.directUrl!);
      } else if (entry.githubRepo != null) {
        setState(() => s.checking = true);
        final release = await fetchLatestRelease(entry.githubRepo!);
        if (!mounted) return;
        setState(() {
          s.checking = false;
          s.release = release;
          if (release != null) {
            final names = release.assets.map((a) => a.name).toList();
            final matched = matchAssetName(names, entry.assetPattern);
            if (matched != null) {
              final asset =
                  release.assets.firstWhere((a) => a.name == matched);
              s.resolvedUrl = asset.downloadUrl;
              s.resolvedAssetName = asset.name;
              s.resolvedSize = asset.size;
            } else {
              s.error = '未找到匹配的资产 (正则: ${entry.assetPattern})';
            }
          } else {
            s.error = '检测失败（网络不可达或被限流）';
          }
        });
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _downloadEntry(BitmapFontEntry entry) async {
    final s = _onlineStates[entry.id]!;
    final url = s.resolvedUrl;
    if (url == null || s.downloading) return;
    setState(() {
      s.downloading = true;
      s.received = 0;
      s.total = 0;
      s.error = null;
    });
    try {
      final path = await downloadFont(
        url,
        _downloadDir,
        entry.saveAs,
        onProgress: (received, total) {
          if (mounted) {
            setState(() {
              s.received = received;
              s.total = total;
            });
          }
        },
      );
      if (!mounted) return;
      setState(() {
        s.downloading = false;
        s.downloaded = true;
      });
      await _afterDownload(path, entry.name);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        s.downloading = false;
        s.error = '下载失败: $e';
      });
    }
  }

  Future<void> _downloadCustomUrl() async {
    final url = _urlController.text.trim();
    if (url.isEmpty || _customDownloading) return;
    final saveAs = fileNameFromUrl(url);
    setState(() {
      _customDownloading = true;
      _customReceived = 0;
      _customTotal = 0;
    });
    try {
      final path = await downloadFont(
        url,
        _downloadDir,
        saveAs,
        onProgress: (received, total) {
          if (mounted) {
            setState(() {
              _customReceived = received;
              _customTotal = total;
            });
          }
        },
      );
      if (!mounted) return;
      setState(() => _customDownloading = false);
      await _afterDownload(path, saveAs);
    } catch (e) {
      if (!mounted) return;
      setState(() => _customDownloading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(backgroundColor: Colors.redAccent, content: Text('下载失败: $e')),
      );
    }
  }

  /// 下载完成后的统一处理：fallback 模式自动加载到级联列表。
  Future<void> _afterDownload(String path, String label) async {
    final state = context.read<FontExtractorState>();
    if (state.extractMode == FontExtractMode.fallback) {
      await state.addFontFile(path);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.green,
          content: Text(state.fontPaths.contains(path)
              ? '$label 已下载并加载到字体列表'
              : '$label 已下载，但加载失败: ${state.lastError ?? ''}'),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.green,
          content: Text('$label 已保存到 $path（多语言模式请手动绑定）'),
        ),
      );
    }
  }

  Future<void> _changeDownloadDir() async {
    final dir = await getDirectoryPath(confirmButtonText: '选择下载目录');
    if (dir == null || !mounted) return;
    setState(() {
      _downloadDir = dir;
      BitmapFontDialog.sessionDownloadDir = dir;
      for (final entry in kBitmapFontCatalog) {
        final s = _onlineStates[entry.id]!;
        s.downloaded = File(p.join(dir, entry.saveAs)).existsSync();
      }
    });
  }

  // ------------------------------------------------------------------
  // UI
  // ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF1E1E1E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      child: SizedBox(
        width: 720,
        height: 580,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.grid_on, size: 16, color: Colors.cyanAccent),
                  const SizedBox(width: 6),
                  const Text(
                    '点阵字库检测与下载',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  InkWell(
                    onTap: () => Navigator.of(context).pop(),
                    child: const Icon(Icons.close, size: 16, color: Colors.grey),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _buildDownloadDirRow(),
              const SizedBox(height: 8),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildLocalSection(),
                      const SizedBox(height: 12),
                      _buildOnlineSection(),
                      const SizedBox(height: 12),
                      _buildCustomUrlSection(),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDownloadDirRow() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF252525),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          const Text('下载目录：',
              style: TextStyle(fontSize: 11, color: Colors.grey)),
          Expanded(
            child: Tooltip(
              message: _downloadDir,
              child: Text(
                _downloadDir,
                style: const TextStyle(
                    fontSize: 11,
                    color: Colors.cyanAccent,
                    fontFamily: 'Consolas'),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          TextButton(
            onPressed: _changeDownloadDir,
            style: TextButton.styleFrom(
              foregroundColor: Colors.cyanAccent,
              minimumSize: const Size(0, 24),
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            child: const Text('更改…', style: TextStyle(fontSize: 11)),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, String hint) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Text(title,
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: Colors.cyanAccent)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(hint,
                style: const TextStyle(fontSize: 10, color: Colors.grey),
                overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }

  Widget _buildLocalSection() {
    final paths = _localLoaded.keys.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSectionHeader('本地检测', '检测已加载字体与 Font/ 目录字体是否为点阵字体'),
        if (paths.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 6),
            child: Text('暂无本地字体（加载字体或将字体放入 Font/ 目录后可在此检测）',
                style: TextStyle(fontSize: 11, color: Colors.grey)),
          )
        else
          ...paths.map(_buildLocalRow),
      ],
    );
  }

  Widget _buildLocalRow(String path) {
    final loaded = _localLoaded[path] ?? false;
    final verdict = _localVerdicts[path]; // null = 检测中
    final state = context.read<FontExtractorState>();
    final displayName =
        loaded ? state.fontDisplayName(path) : p.basename(path);

    Widget badge;
    if (verdict == null) {
      badge = _badge('检测中…', Colors.grey);
    } else if (verdict.bitmapSizes.isNotEmpty) {
      badge = _badge('内嵌点阵 ${verdict.bitmapSizes}', Colors.green);
    } else if (verdict.looksPixel) {
      badge = _badge('像素风格字体（名称推断）', Colors.green);
    } else {
      badge = _badge('纯矢量，小字号会糊', Colors.orangeAccent);
    }
    // 无内嵌点阵但从名称推断出设计尺寸时，额外标注。
    final Widget? designBadge =
        (verdict != null &&
                verdict.bitmapSizes.isEmpty &&
                verdict.designSizes.isNotEmpty)
            ? _badge('设计尺寸 ${verdict.designSizes.join("/")}px',
                Colors.cyanAccent)
            : null;

    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF252525),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.grey.shade800),
      ),
      child: Row(
        children: [
          Expanded(
            child: Tooltip(
              message: path,
              child: Text(
                displayName,
                style: const TextStyle(fontSize: 11),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          badge,
          if (designBadge != null) ...[
            const SizedBox(width: 4),
            designBadge,
          ],
          if (!loaded) ...[
            const SizedBox(width: 6),
            ElevatedButton(
              onPressed: () async {
                final st = context.read<FontExtractorState>();
                await st.addFontFile(path);
                if (mounted) setState(() => _localLoaded[path] = true);
              },
              style: _smallBtnStyle(),
              child: const Text('加载', style: TextStyle(fontSize: 10)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildOnlineSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSectionHeader('在线点阵字体', '打开对话框时自动检测最新版本'),
        ...kBitmapFontCatalog.map(_buildOnlineRow),
      ],
    );
  }

  Widget _buildOnlineRow(BitmapFontEntry entry) {
    final s = _onlineStates[entry.id]!;

    // 状态行：版本 / 资产大小 / 进度 / 错误。
    String statusText;
    if (s.downloading) {
      statusText = s.total > 0
          ? '下载中 ${(s.received * 100 / s.total).toStringAsFixed(0)}%'
          : '下载中 ${_formatBytes(s.received)}';
    } else if (s.checking) {
      statusText = '检测中…';
    } else if (s.error != null) {
      statusText = s.error!;
    } else if (s.release != null) {
      final sizeText =
          s.resolvedSize > 0 ? ' · ${_formatBytes(s.resolvedSize)}' : '';
      statusText = '最新版本 ${s.release!.tagName}$sizeText';
    } else {
      statusText = '可直接下载';
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF252525),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.grey.shade800),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(entry.name,
                          style: const TextStyle(
                              fontSize: 11, fontWeight: FontWeight.w500),
                          overflow: TextOverflow.ellipsis),
                    ),
                    const SizedBox(width: 4),
                    _badge('设计尺寸 ${entry.pixelSize}px', Colors.cyanAccent),
                  ],
                ),
                Text(entry.description,
                    style: const TextStyle(fontSize: 9, color: Colors.grey)),
                Text(
                  statusText,
                  style: TextStyle(
                    fontSize: 9,
                    color: s.error != null
                        ? Colors.redAccent
                        : (s.downloaded ? Colors.green : Colors.grey),
                  ),
                ),
              ],
            ),
          ),
          if (s.downloaded) _badge('已下载', Colors.green),
          const SizedBox(width: 6),
          if (s.downloading)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.cyanAccent),
            )
          else ...[
            if (s.downloaded)
              ElevatedButton(
                onPressed: () =>
                    _afterDownload(p.join(_downloadDir, entry.saveAs), entry.name),
                style: _smallBtnStyle(),
                child: const Text('加载', style: TextStyle(fontSize: 10)),
              ),
            const SizedBox(width: 4),
            ElevatedButton(
              onPressed: s.resolvedUrl == null
                  ? null
                  : () => _downloadEntry(entry),
              style: _smallBtnStyle(),
              child: Text(s.downloaded ? '重新下载' : '下载',
                  style: const TextStyle(fontSize: 10)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCustomUrlSection() {
    final progressText = _customDownloading
        ? (_customTotal > 0
            ? ' ${(_customReceived * 100 / _customTotal).toStringAsFixed(0)}%'
            : ' ${_formatBytes(_customReceived)}')
        : '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSectionHeader('自定义 URL', '输入 .ttf/.otf/.zip 直链下载点阵字体'),
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 30,
                child: TextField(
                  controller: _urlController,
                  style: const TextStyle(fontSize: 11, fontFamily: 'Consolas'),
                  decoration: InputDecoration(
                    hintText: 'https://example.com/pixel-font.ttf',
                    hintStyle:
                        const TextStyle(fontSize: 11, color: Colors.grey),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 8),
                    filled: true,
                    fillColor: const Color(0xFF252525),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(4),
                      borderSide: BorderSide(color: Colors.grey.shade800),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(4),
                      borderSide: BorderSide(color: Colors.grey.shade800),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            ElevatedButton(
              onPressed: _customDownloading ? null : _downloadCustomUrl,
              style: _smallBtnStyle(),
              child: Text(_customDownloading ? '下载中$progressText' : '下载',
                  style: const TextStyle(fontSize: 10)),
            ),
          ],
        ),
      ],
    );
  }

  Widget _badge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(2),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(text, style: TextStyle(fontSize: 9, color: color)),
    );
  }

  ButtonStyle _smallBtnStyle() {
    return ElevatedButton.styleFrom(
      backgroundColor: const Color(0xFF0A4A5A),
      foregroundColor: Colors.cyanAccent,
      disabledBackgroundColor: const Color(0xFF333333),
      disabledForegroundColor: Colors.grey,
      minimumSize: const Size(0, 24),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      elevation: 0,
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '$bytes B';
  }
}
