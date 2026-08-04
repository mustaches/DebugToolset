import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../providers/ui_designer_state.dart';
import '../models/ui_widget.dart';
import 'scroll_list_preview.dart';

Color argb(int v) => Color(v);

/// Renders the visual content of a [UiWidgetModel]. Used by the editor
/// canvas and by the preview simulator (with [preview] = true).
class UiWidgetContent extends StatelessWidget {
  const UiWidgetContent({
    super.key,
    required this.model,
    this.preview = false,
    this.runtimeValue,
    this.pressed = false,
    this.focused = false,
    this.onSliderChanged,
    this.onListSelected,
  });

  final UiWidgetModel model;
  final bool preview;

  /// Current runtime value in preview mode (slider position, checked...).
  final dynamic runtimeValue;
  final bool pressed;
  final bool focused;
  final ValueChanged<double>? onSliderChanged;
  final ValueChanged<int>? onListSelected;

  @override
  Widget build(BuildContext context) {
    final w = model;
    Widget child;
    switch (w.type) {
      case 'label':
        child = _label();
      case 'image':
        child = _image(context);
      case 'button':
        child = _button();
      case 'panel':
        child = _panel();
      case 'line':
        child = _line();
      case 'progress':
        child = _progress();
      case 'slider':
        child = _slider();
      case 'checkbox':
        child = _checkbox();
      case 'switch':
        child = _switch();
      case 'radio':
        child = _radio();
      case 'dropdown':
        child = _dropdown();
      case 'textfield':
        child = _textfield();
      case 'scrolllist':
        child = _scrolllist();
      default:
        child = Container(
          color: const Color(0x33FF0000),
          child: Center(
            child: Text(w.type, style: const TextStyle(fontSize: 10)),
          ),
        );
    }
    if (preview && focused) {
      child = Container(
        decoration: BoxDecoration(
          border: Border.all(color: Colors.cyanAccent, width: 1.5),
        ),
        child: child,
      );
    }
    return child;
  }

  double get _fontSize =>
      (model.props['fontSize'] as num?)?.toDouble() ?? 14;

  Widget _label() {
    final align = model.props['align'] as String? ?? 'left';
    return Container(
      alignment: align == 'center'
          ? Alignment.center
          : align == 'right'
              ? Alignment.centerRight
              : Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Text(
        model.props['text'] as String? ?? '',
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: _fontSize,
          color: argb(model.props['color'] as int? ?? 0xFFFFFFFF),
          fontWeight: (model.props['bold'] as bool? ?? false)
              ? FontWeight.bold
              : FontWeight.normal,
        ),
      ),
    );
  }

  Widget _image(BuildContext context) {
    final assetId = model.props['asset'] as String?;
    final state = context.read<UiDesignerState>();
    final asset = assetId == null ? null : state.project.assetById(assetId);
    final path = asset == null ? null : state.resolveAssetPath(asset);
    final mode = model.props['scaleMode'] as String? ?? 'fit';
    final fit = mode == 'fill'
        ? BoxFit.cover
        : mode == 'stretch'
            ? BoxFit.fill
            : BoxFit.contain;
    if (path != null && File(path).existsSync()) {
      return Image.file(
        File(path),
        fit: fit,
        width: model.width,
        height: model.height,
        errorBuilder: (_, _, _) => _imagePlaceholder(),
      );
    }
    return _imagePlaceholder();
  }

  Widget _imagePlaceholder() => Container(
        color: const Color(0xFF2E2E2E),
        child: const Center(
          child: Icon(Icons.image, color: Colors.grey, size: 24),
        ),
      );

  Widget _button() {
    final bg = pressed
        ? argb(model.props['pressedColor'] as int? ?? 0xFF0D47A1)
        : argb(model.props['bgColor'] as int? ?? 0xFF1E88E5);
    final radius =
        (model.props['radius'] as num?)?.toDouble() ?? 6;
    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(radius),
      ),
      alignment: Alignment.center,
      child: Text(
        model.props['text'] as String? ?? '',
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: _fontSize,
          color: argb(model.props['textColor'] as int? ?? 0xFFFFFFFF),
        ),
      ),
    );
  }

  Widget _panel() {
    final radius =
        (model.props['radius'] as num?)?.toDouble() ?? 0;
    final borderWidth =
        (model.props['borderWidth'] as num?)?.toDouble() ?? 0;
    return Container(
      decoration: BoxDecoration(
        color: argb(model.props['bgColor'] as int? ?? 0xFF2E2E2E),
        borderRadius: BorderRadius.circular(radius),
        border: borderWidth > 0
            ? Border.all(
                color:
                    argb(model.props['borderColor'] as int? ?? 0x00000000),
                width: borderWidth,
              )
            : null,
      ),
    );
  }

  Widget _line() {
    final thickness =
        (model.props['thickness'] as num?)?.toDouble() ?? 1;
    final horizontal = model.width >= model.height;
    return Center(
      child: Container(
        width: horizontal ? model.width : thickness,
        height: horizontal ? thickness : model.height,
        color: argb(model.props['color'] as int? ?? 0xFF9E9E9E),
      ),
    );
  }

  Widget _progress() {
    final max = (model.props['max'] as num?)?.toDouble() ?? 100;
    final value = preview
        ? (runtimeValue as num?)?.toDouble() ?? 0
        : (model.props['value'] as num?)?.toDouble() ?? 0;
    final radius =
        (model.props['radius'] as num?)?.toDouble() ?? 4;
    final frac = max <= 0 ? 0.0 : (value / max).clamp(0.0, 1.0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(
              color: argb(model.props['bgColor'] as int? ?? 0xFF424242)),
          FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: frac,
            child: Container(
                color: argb(model.props['color'] as int? ?? 0xFF4CAF50)),
          ),
        ],
      ),
    );
  }

  Widget _slider() {
    final min = (model.props['min'] as num?)?.toDouble() ?? 0;
    final max = (model.props['max'] as num?)?.toDouble() ?? 100;
    final value = preview
        ? (runtimeValue as num?)?.toDouble() ?? min
        : (model.props['value'] as num?)?.toDouble() ?? min;
    return SliderTheme(
      data: SliderThemeData(
        activeTrackColor: argb(model.props['color'] as int? ?? 0xFF1E88E5),
        inactiveTrackColor:
            argb(model.props['trackColor'] as int? ?? 0xFF616161),
        thumbColor: argb(model.props['color'] as int? ?? 0xFF1E88E5),
        overlayColor: Colors.transparent,
        trackHeight: 4,
      ),
      child: Slider(
        value: value.clamp(min, max),
        min: min,
        max: max,
        onChanged: preview ? onSliderChanged : null,
      ),
    );
  }

  Widget _checkbox() {
    final checked = preview
        ? runtimeValue as bool? ?? false
        : model.props['checked'] as bool? ?? false;
    final color = argb(model.props['color'] as int? ?? 0xFF1E88E5);
    return Row(
      children: [
        Icon(
          checked ? Icons.check_box : Icons.check_box_outline_blank,
          size: model.height.clamp(12.0, 24.0),
          color: checked ? color : Colors.grey,
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            model.props['text'] as String? ?? '',
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: _fontSize, color: Colors.white),
          ),
        ),
      ],
    );
  }

  Widget _switch() {
    final on = preview
        ? runtimeValue as bool? ?? false
        : model.props['on'] as bool? ?? false;
    final color = argb(model.props['color'] as int? ?? 0xFF1E88E5);
    return IgnorePointer(
      child: FittedBox(
        fit: BoxFit.contain,
        child: Switch(
          value: on,
          onChanged: (_) {},
          activeThumbColor: color,
        ),
      ),
    );
  }

  Widget _radio() {
    final checked = preview
        ? runtimeValue as bool? ?? false
        : model.props['checked'] as bool? ?? false;
    final color = argb(model.props['color'] as int? ?? 0xFF1E88E5);
    return Row(
      children: [
        Icon(
          checked
              ? Icons.radio_button_checked
              : Icons.radio_button_unchecked,
          size: model.height.clamp(12.0, 24.0),
          color: checked ? color : Colors.grey,
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            model.props['text'] as String? ?? '',
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: _fontSize, color: Colors.white),
          ),
        ),
      ],
    );
  }

  Widget _dropdown() {
    final options = (model.props['options'] as String? ?? '')
        .split(',')
        .map((s) => s.trim())
        .toList();
    final idx = preview
        ? runtimeValue as int? ?? 0
        : (model.props['selectedIndex'] as num?)?.toInt() ?? 0;
    final text = idx >= 0 && idx < options.length ? options[idx] : '';
    return Container(
      decoration: BoxDecoration(
        color: argb(model.props['bgColor'] as int? ?? 0xFF424242),
        borderRadius: BorderRadius.circular(4),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: _fontSize,
                color: argb(model.props['textColor'] as int? ?? 0xFFFFFFFF),
              ),
            ),
          ),
          const Icon(Icons.arrow_drop_down, size: 18, color: Colors.grey),
        ],
      ),
    );
  }

  Widget _textfield() {
    final text = model.props['text'] as String? ?? '';
    final hint = model.props['hint'] as String? ?? '';
    final showHint = text.isEmpty;
    final radius =
        (model.props['radius'] as num?)?.toDouble() ?? 4;
    return Container(
      decoration: BoxDecoration(
        color: argb(model.props['bgColor'] as int? ?? 0xFF2E2E2E),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: focused && preview ? Colors.cyanAccent : Colors.grey.shade700,
        ),
      ),
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Text(
        showHint ? hint : text,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: _fontSize,
          color: showHint
              ? Colors.grey
              : argb(model.props['textColor'] as int? ?? 0xFFFFFFFF),
        ),
      ),
    );
  }

  Widget _scrolllist() {
    if (preview) {
      return ScrollListPreview(
        model: model,
        selectedIndex: runtimeValue as int? ??
            (model.props['selectedIndex'] as num?)?.toInt() ??
            0,
        onSelected: (i) => onListSelected?.call(i),
      );
    }
    // Edit mode: static rendering centred on the selected item.
    final items = (model.props['items'] as String? ?? '')
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (items.isEmpty) return const SizedBox.shrink();
    final vertical =
        (model.props['orientation'] as String? ?? 'vertical') == 'vertical';
    final selected =
        (model.props['selectedIndex'] as num?)?.toInt() ?? 0;
    final selectedColor =
        argb(model.props['selectedColor'] as int? ?? 0xFF1E88E5);
    final textColor =
        argb(model.props['textColor'] as int? ?? 0xFFFFFFFF);
    final extent =
        (model.props['itemExtent'] as num?)?.toDouble() ?? 36;
    final spacing =
        (model.props['spacing'] as num?)?.toDouble() ?? 4;
    final step = extent + spacing;
    final mainAxis = vertical ? model.height : model.width;
    final visible = (mainAxis / step).ceil().clamp(1, items.length);
    var start = selected - visible ~/ 2;
    start = start.clamp(0, (items.length - visible).clamp(0, items.length));

    final children = <Widget>[
      for (var i = start; i < start + visible && i < items.length; i++)
        Container(
          width: vertical ? model.width : extent,
          height: vertical ? extent : model.height,
          margin: EdgeInsets.only(
              bottom: vertical ? spacing : 0,
              right: vertical ? 0 : spacing),
          decoration: BoxDecoration(
            color: i == selected
                ? selectedColor.withValues(alpha: 0.85)
                : Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(6),
          ),
          alignment: Alignment.center,
          child: Text(
            items[i],
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: _fontSize,
              color: i == selected ? Colors.white : textColor,
              fontWeight:
                  i == selected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ),
    ];
    return ClipRect(
      child: vertical
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children)
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children),
    );
  }
}
