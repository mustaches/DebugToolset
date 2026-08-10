import 'ui_event.dart';
import 'ui_widget.dart';

/// A full-screen page of the designed UI.
class UiPage {
  UiPage({
    required this.id,
    required this.name,
    this.bgColor = 0xFF000000,
    this.bgType = 'color',
    this.bgAssetId,
    this.bgVideoPath,
    this.bgAnim = 'none',
    List<UiWidgetModel>? widgets,
    List<UiEvent>? events,
  })  : widgets = widgets ?? [],
        events = events ?? [];

  String id;
  String name;

  /// Background color, ARGB int.
  int bgColor;

  /// Background kind: 'color' (solid), 'image' (screen-size asset) or
  /// 'video' (live video stream; the OSD draws on top).
  String bgType;

  /// Image asset id, used when [bgType] is 'image'.
  String? bgAssetId;

  /// Video file path, used when [bgType] is 'video'.
  String? bgVideoPath;

  /// Background animation for image backgrounds:
  /// 'none' | 'kenburns' (slow push/pan) | 'parallax' (horizontal drift).
  String bgAnim;

  /// Widgets in paint order; later entries are on top.
  List<UiWidgetModel> widgets;

  /// Page-level events: onShow / onHide / onTimer.
  List<UiEvent> events;

  UiWidgetModel? widgetById(String id) {
    for (final w in widgets) {
      if (w.id == id) return w;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'bgColor': bgColor,
        if (bgType != 'color') 'bgType': bgType,
        if (bgAssetId != null) 'bgAssetId': bgAssetId,
        if (bgVideoPath != null) 'bgVideoPath': bgVideoPath,
        if (bgAnim != 'none') 'bgAnim': bgAnim,
        'widgets': widgets.map((w) => w.toJson()).toList(),
        'events': events.map((e) => e.toJson()).toList(),
      };

  factory UiPage.fromJson(Map<String, dynamic> json) => UiPage(
        id: json['id'] as String,
        name: json['name'] as String,
        bgColor: (json['bgColor'] as num?)?.toInt() ?? 0xFF000000,
        bgType: json['bgType'] as String? ?? 'color',
        bgAssetId: json['bgAssetId'] as String?,
        bgVideoPath: json['bgVideoPath'] as String?,
        bgAnim: json['bgAnim'] as String? ?? 'none',
        widgets: (json['widgets'] as List?)
                ?.map((w) =>
                    UiWidgetModel.fromJson((w as Map).cast<String, dynamic>()))
                .toList() ??
            [],
        events: (json['events'] as List?)
                ?.map((e) => UiEvent.fromJson((e as Map).cast<String, dynamic>()))
                .toList() ??
            [],
      );
}
