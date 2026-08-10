import 'dart:io';
import 'dart:math' as math;

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
      case 'menu':
        child = _menu();
      case 'value_item':
        child = _valueItem();
      case 'option_item':
        child = _optionItem();
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
    // Universal GPU-friendly transform props (rotation degrees, scale
    // and opacity percent; identity by default).
    final opacity = (model.props['opacity'] as num?)?.toDouble() ?? 100;
    final scalePct = (model.props['scale'] as num?)?.toDouble() ?? 100;
    final rotate = (model.props['rotate'] as num?)?.toDouble() ?? 0;
    if (opacity < 100) {
      child = Opacity(opacity: opacity / 100, child: child);
    }
    if (scalePct != 100) {
      child = Transform.scale(scale: scalePct / 100, child: child);
    }
    if (rotate != 0) {
      child = Transform.rotate(angle: rotate * math.pi / 180, child: child);
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
    final percent = max <= 0 ? 0 : (value * 100 / max).round();
    final info = model.props['text'] as String? ?? '';
    final infoSize =
        (model.props['fontSize'] as num?)?.toDouble() ?? 12;
    // Info row (info string left, percentage right) above the bar.
    final infoH = infoSize + 4;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: infoH,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  info,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: infoSize, color: Colors.white70),
                ),
              ),
              Text(
                '$percent%',
                style: TextStyle(fontSize: infoSize, color: Colors.white),
              ),
            ],
          ),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: _StripeFlow(
              frac: frac,
              color: argb(model.props['color'] as int? ?? 0xFF4CAF50),
              stripeColor:
                  argb(model.props['stripeColor'] as int? ?? 0xFF81C784),
              bgColor: argb(model.props['bgColor'] as int? ?? 0xFF424242),
            ),
          ),
        ),
      ],
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

  // ------------------------------------------------------------------
  // OSD widgets
  // ------------------------------------------------------------------

  List<String> get _csvOptions =>
      (model.props['options'] as String? ?? '')
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();

  /// Vertical OSD menu: highlight bar on the selected item, window
  /// centred on it. Key-driven (no touch scrolling).
  Widget _menu() {
    final items = (model.props['items'] as String? ?? '')
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (items.isEmpty) return const SizedBox.shrink();
    final selected = preview
        ? runtimeValue as int? ?? 0
        : (model.props['selectedIndex'] as num?)?.toInt() ?? 0;
    final sel = selected.clamp(0, items.length - 1);
    final highlight =
        argb(model.props['highlightColor'] as int? ?? 0xFF1E88E5);
    final textColor = argb(model.props['textColor'] as int? ?? 0xFFFFFFFF);
    final extent = (model.props['itemExtent'] as num?)?.toDouble() ?? 36;
    final visible = (model.height / extent).floor().clamp(1, items.length);
    var start = sel - visible ~/ 2;
    start = start.clamp(0, (items.length - visible).clamp(0, items.length));

    return ClipRect(
      child: Stack(
        children: [
          // Highlight bar slides to the selected item.
          AnimatedPositioned(
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOut,
            top: (sel - start) * extent,
            left: 0,
            right: 0,
            height: extent,
            child: Container(color: highlight),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = start;
                  i < start + visible && i < items.length;
                  i++)
                Container(
                  height: extent,
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    items[i],
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: _fontSize,
                      color: i == sel ? Colors.white : textColor,
                      fontWeight:
                          i == sel ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// OSD value row: label on the left, numeric value on the right.
  Widget _valueItem() {
    final value = preview
        ? runtimeValue as int? ?? 0
        : (model.props['value'] as num?)?.toInt() ?? 0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              model.props['text'] as String? ?? '',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: _fontSize,
                color: argb(model.props['textColor'] as int? ?? 0xFFFFFFFF),
              ),
            ),
          ),
          Text(
            '$value',
            style: TextStyle(
              fontSize: _fontSize,
              color:
                  argb(model.props['valueColor'] as int? ?? 0xFF4FC3F7),
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  /// OSD option row: label on the left, `<current option>` on the right.
  Widget _optionItem() {
    final options = _csvOptions;
    final idx = preview
        ? runtimeValue as int? ?? 0
        : (model.props['selectedIndex'] as num?)?.toInt() ?? 0;
    final text =
        options.isEmpty ? '' : options[idx.clamp(0, options.length - 1)];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              model.props['text'] as String? ?? '',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: _fontSize,
                color: argb(model.props['textColor'] as int? ?? 0xFFFFFFFF),
              ),
            ),
          ),
          Text(
            '< $text >',
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: _fontSize,
              color:
                  argb(model.props['valueColor'] as int? ?? 0xFF4FC3F7),
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

/// Two-tone diagonal-striped progress bar painter.
class _StripedProgressPainter extends CustomPainter {
  _StripedProgressPainter({
    required this.frac,
    required this.color,
    required this.stripeColor,
    required this.bgColor,
    this.offset = 0,
  });

  final double frac;
  final Color color, stripeColor, bgColor;

  /// Animated stripe phase, 0..period.
  final double offset;

  static const _stripeWidth = 6.0;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = bgColor);
    final fracW = size.width * frac;
    if (fracW <= 0) return;
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, fracW, size.height));
    canvas.drawRect(Rect.fromLTWH(0, 0, fracW, size.height),
        Paint()..color = color);
    // 45-degree stripes: (x + y) mod period picks the stripe color.
    final stripePaint = Paint()
      ..color = stripeColor
      ..strokeWidth = _stripeWidth;
    final period = _stripeWidth * 2;
    for (double x = -size.height - offset;
        x < fracW + size.height;
        x += period) {
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0),
          stripePaint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_StripedProgressPainter old) =>
      old.frac != frac ||
      old.color != color ||
      old.stripeColor != stripeColor ||
      old.bgColor != bgColor ||
      old.offset != offset;
}

/// Flowing-stripe animation driver for the progress bar.
class _StripeFlow extends StatefulWidget {
  const _StripeFlow({
    required this.frac,
    required this.color,
    required this.stripeColor,
    required this.bgColor,
  });

  final double frac;
  final Color color, stripeColor, bgColor;

  @override
  State<_StripeFlow> createState() => _StripeFlowState();
}

class _StripeFlowState extends State<_StripeFlow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 500),
  )..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) => CustomPaint(
        painter: _StripedProgressPainter(
          frac: widget.frac,
          color: widget.color,
          stripeColor: widget.stripeColor,
          bgColor: widget.bgColor,
          offset: _ctrl.value * _StripedProgressPainter._stripeWidth * 2,
        ),
      ),
    );
  }
}
