import 'dart:ui';

import 'ui_event.dart';

/// One widget instance on a page. Geometry is in logical pixels of the
/// project's screen coordinate space.
class UiWidgetModel {
  UiWidgetModel({
    required this.id,
    required this.type,
    required this.name,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    Map<String, dynamic>? props,
    List<UiEvent>? events,
  })  : props = props ?? {},
        events = events ?? [];

  /// Unique id within the project (stable, used for selection/runtime state).
  String id;

  /// Registry key, e.g. `button`, `label`.
  String type;

  /// C identifier shown in the designer and used in generated code.
  String name;

  double x, y, width, height;

  /// Type-specific properties (defaults come from the registry schema).
  Map<String, dynamic> props;

  List<UiEvent> events;

  Rect get rect => Rect.fromLTWH(x, y, width, height);

  void setRect(Rect r) {
    x = r.left;
    y = r.top;
    width = r.width;
    height = r.height;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'name': name,
        'x': x,
        'y': y,
        'width': width,
        'height': height,
        'props': props,
        'events': events.map((e) => e.toJson()).toList(),
      };

  factory UiWidgetModel.fromJson(Map<String, dynamic> json) => UiWidgetModel(
        id: json['id'] as String,
        type: json['type'] as String,
        name: json['name'] as String,
        x: (json['x'] as num).toDouble(),
        y: (json['y'] as num).toDouble(),
        width: (json['width'] as num).toDouble(),
        height: (json['height'] as num).toDouble(),
        props: (json['props'] as Map?)?.cast<String, dynamic>() ?? {},
        events: (json['events'] as List?)
                ?.map((e) => UiEvent.fromJson((e as Map).cast<String, dynamic>()))
                .toList() ??
            [],
      );

  UiWidgetModel copy({String? newId}) => UiWidgetModel(
        id: newId ?? id,
        type: type,
        name: name,
        x: x,
        y: y,
        width: width,
        height: height,
        props: Map<String, dynamic>.from(props),
        events: events.map((e) => e.copy()).toList(),
      );
}
