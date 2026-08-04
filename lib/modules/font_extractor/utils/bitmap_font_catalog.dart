/// 开源点阵（像素）字体的内置下载清单与纯函数工具。
///
/// 该文件不触网，只保存数据与名称匹配逻辑，便于单元测试。
library;

/// 一个可下载的点阵字体条目。
class BitmapFontEntry {
  /// 唯一标识，如 'ark-pixel-16px'。
  final String id;

  /// 显示名称，如 '方舟像素字体 16px (Ark Pixel)'。
  final String name;

  /// 简介（含许可证）。
  final String description;

  /// 设计像素尺寸，如 16。
  final int pixelSize;

  /// GitHub 仓库（owner/repo）；为 null 时使用 [directUrl] 固定地址。
  final String? githubRepo;

  /// 匹配 release 资产名的正则表达式。
  final String assetPattern;

  /// 固定下载地址（非 GitHub 来源时使用）。
  final String? directUrl;

  /// 落地保存的文件名。
  final String saveAs;

  const BitmapFontEntry({
    required this.id,
    required this.name,
    required this.description,
    required this.pixelSize,
    this.githubRepo,
    required this.assetPattern,
    this.directUrl,
    required this.saveAs,
  });
}

/// 内置点阵字体清单。
///
/// assetPattern 已对照 GitHub Release 实际资产名核实（2026-07-29）：
/// - ark-pixel-font:   ark-pixel-font-16px-monospaced-ttf-v2026.07.20.zip
/// - fusion-pixel-font: fusion-pixel-font-12px-monospaced-ttf-v2026.07.20.zip
/// - zpix-pixel-font:  zpix.ttf（release 直接挂 ttf，无需解压）
/// - GNU Unifont:      固定地址 otf（已 curl -I 核实 200）
const List<BitmapFontEntry> kBitmapFontCatalog = [
  BitmapFontEntry(
    id: 'ark-pixel-16px',
    name: '方舟像素字体 16px (Ark Pixel)',
    description: '开源泛中日韩像素字体，等宽 TTF 版 · OFL 许可证',
    pixelSize: 16,
    githubRepo: 'TakWolf/ark-pixel-font',
    assetPattern: r'^ark-pixel-font-16px-monospaced-ttf-v[\d.]+\.zip$',
    saveAs: 'ark-pixel-16px.ttf',
  ),
  BitmapFontEntry(
    id: 'fusion-pixel-12px',
    name: '缝合像素字体 12px (Fusion Pixel)',
    description: '缝合多个开源像素字体，等宽 TTF 版 · OFL 许可证',
    pixelSize: 12,
    githubRepo: 'TakWolf/fusion-pixel-font',
    assetPattern: r'^fusion-pixel-font-12px-monospaced-ttf-v[\d.]+\.zip$',
    saveAs: 'fusion-pixel-12px.ttf',
  ),
  BitmapFontEntry(
    id: 'zpix-12px',
    name: 'Zpix 最像素 12px',
    description: '中文像素字体，覆盖简繁日文 · OFL 类许可证',
    pixelSize: 12,
    githubRepo: 'SolidZORO/zpix-pixel-font',
    assetPattern: r'^zpix\.ttf$',
    saveAs: 'zpix.ttf',
  ),
  BitmapFontEntry(
    id: 'unifont-16px',
    name: 'GNU Unifont 16px',
    description: 'GNU 点阵字体，Unicode 全覆盖 · GPL-2.0+ 字体例外',
    pixelSize: 16,
    assetPattern: r'.*\.otf$',
    directUrl:
        'https://unifoundry.com/pub/unifont/unifont-17.0.05/font-builds/unifont-17.0.05.otf',
    saveAs: 'unifont-17.0.05.otf',
  ),
];

/// 在 [assetNames] 中返回第一个匹配 [pattern] 的资产名；无匹配返回 null。
String? matchAssetName(List<String> assetNames, String pattern) {
  final re = RegExp(pattern, caseSensitive: false);
  for (final name in assetNames) {
    if (re.hasMatch(name)) return name;
  }
  return null;
}

/// 从 URL 中提取落地文件名：去掉 query/fragment 后取最后一段路径。
/// 提取不到（空段或无扩展名）时回退为 'download.ttf'。
String fileNameFromUrl(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || uri.pathSegments.isEmpty) return 'download.ttf';
  final last = uri.pathSegments.last;
  if (last.isEmpty || !last.contains('.')) return 'download.ttf';
  return last;
}
