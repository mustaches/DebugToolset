import 'ui_page.dart';

/// An image asset of the project: the source picture plus the converted
/// raw payload produced by the image converter tool.
class UiAsset {
  UiAsset({
    required this.id,
    required this.name,
    required this.srcFile,
    this.binFile,
    this.format = 'rgb565',
    this.width = 0,
    this.height = 0,
  });

  String id;

  /// C identifier, e.g. `img_logo`.
  String name;

  /// Source image (png/jpg). Absolute path, or relative to the project file.
  String srcFile;

  /// Converted raw data file, relative to the project file (nullable until
  /// the converter tool has produced it).
  String? binFile;

  /// Pixel format of [binFile]: rgb565 / rgb888 / argb8888 / gray8 / mono1.
  String format;

  int width, height;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'srcFile': srcFile,
        if (binFile != null) 'binFile': binFile,
        'format': format,
        'width': width,
        'height': height,
      };

  factory UiAsset.fromJson(Map<String, dynamic> json) => UiAsset(
        id: json['id'] as String,
        name: json['name'] as String,
        srcFile: json['srcFile'] as String,
        binFile: json['binFile'] as String?,
        format: json['format'] as String? ?? 'rgb565',
        width: (json['width'] as num?)?.toInt() ?? 0,
        height: (json['height'] as num?)?.toInt() ?? 0,
      );
}

/// The whole UI design project.
class UiProject {
  UiProject({
    required this.name,
    this.screenWidth = 480,
    this.screenHeight = 320,
    List<UiPage>? pages,
    List<UiAsset>? assets,
  })  : pages = pages ?? [],
        assets = assets ?? [];

  String name;
  int screenWidth, screenHeight;
  List<UiPage> pages;
  List<UiAsset> assets;

  UiPage? pageById(String id) {
    for (final p in pages) {
      if (p.id == id) return p;
    }
    return null;
  }

  UiAsset? assetById(String id) {
    for (final a in assets) {
      if (a.id == id) return a;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        'version': 1,
        'name': name,
        'screenWidth': screenWidth,
        'screenHeight': screenHeight,
        'pages': pages.map((p) => p.toJson()).toList(),
        'assets': assets.map((a) => a.toJson()).toList(),
      };

  factory UiProject.fromJson(Map<String, dynamic> json) => UiProject(
        name: json['name'] as String? ?? 'untitled',
        screenWidth: (json['screenWidth'] as num?)?.toInt() ?? 480,
        screenHeight: (json['screenHeight'] as num?)?.toInt() ?? 320,
        pages: (json['pages'] as List?)
                ?.map((p) => UiPage.fromJson((p as Map).cast<String, dynamic>()))
                .toList() ??
            [],
        assets: (json['assets'] as List?)
                ?.map((a) => UiAsset.fromJson((a as Map).cast<String, dynamic>()))
                .toList() ??
            [],
      );
}
