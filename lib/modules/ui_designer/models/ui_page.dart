import 'ui_event.dart';
import 'ui_widget.dart';

/// A full-screen page of the designed UI.
class UiPage {
  UiPage({
    required this.id,
    required this.name,
    this.bgColor = 0xFF000000,
    List<UiWidgetModel>? widgets,
    List<UiEvent>? events,
  })  : widgets = widgets ?? [],
        events = events ?? [];

  String id;
  String name;

  /// Background color, ARGB int.
  int bgColor;

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
        'widgets': widgets.map((w) => w.toJson()).toList(),
        'events': events.map((e) => e.toJson()).toList(),
      };

  factory UiPage.fromJson(Map<String, dynamic> json) => UiPage(
        id: json['id'] as String,
        name: json['name'] as String,
        bgColor: (json['bgColor'] as num?)?.toInt() ?? 0xFF000000,
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
