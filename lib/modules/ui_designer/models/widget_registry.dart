import 'package:flutter/material.dart';

import 'ui_event.dart';

/// Property kinds the property panel knows how to edit.
enum PropType { text, multiline, intNum, doubleNum, color, boolean, choice, asset }

/// Schema entry for one widget property.
class PropDef {
  const PropDef(
    this.key,
    this.label,
    this.type,
    this.defaultValue, {
    this.options,
    this.min,
    this.max,
  });

  final String key;
  final String label;
  final PropType type;
  final dynamic defaultValue;

  /// Allowed values when [type] is [PropType.choice].
  final List<String>? options;

  final num? min, max;
}

/// Static description of a widget type: palette entry, default geometry,
/// editable properties and supported events.
class WidgetTypeDef {
  const WidgetTypeDef({
    required this.type,
    required this.label,
    required this.icon,
    required this.defaultWidth,
    required this.defaultHeight,
    required this.props,
    required this.events,
  });

  final String type;
  final String label;
  final IconData icon;
  final double defaultWidth, defaultHeight;
  final List<PropDef> props;
  final Set<UiEventType> events;

  Map<String, dynamic> defaultProps() =>
      {for (final p in props) p.key: p.defaultValue};
}

/// Central registry of all widget types the designer supports.
class WidgetRegistry {
  WidgetRegistry._();

  static const _interactive = {
    UiEventType.onClick,
    UiEventType.onFocus,
  };
  static const _valued = {
    UiEventType.onValueChange,
    UiEventType.onFocus,
  };

  static final Map<String, WidgetTypeDef> types = {
    for (final d in _defs) d.type: d,
  };

  static WidgetTypeDef? of(String type) => types[type];

  static List<WidgetTypeDef> get all => _defs;

  static const List<WidgetTypeDef> _defs = [
    WidgetTypeDef(
      type: 'label',
      label: '文本标签',
      icon: Icons.text_fields,
      defaultWidth: 120,
      defaultHeight: 24,
      props: [
        PropDef('text', '文本', PropType.text, 'Label'),
        PropDef('fontSize', '字号', PropType.intNum, 14, min: 6, max: 96),
        PropDef('color', '颜色', PropType.color, 0xFFFFFFFF),
        PropDef('align', '对齐', PropType.choice, 'left',
            options: ['left', 'center', 'right']),
        PropDef('bold', '加粗', PropType.boolean, false),
      ],
      events: _interactive,
    ),
    WidgetTypeDef(
      type: 'image',
      label: '图片',
      icon: Icons.image,
      defaultWidth: 64,
      defaultHeight: 64,
      props: [
        PropDef('asset', '图片资源', PropType.asset, null),
        PropDef('scaleMode', '缩放', PropType.choice, 'fit',
            options: ['fit', 'fill', 'stretch']),
      ],
      events: _interactive,
    ),
    WidgetTypeDef(
      type: 'button',
      label: '按钮',
      icon: Icons.smart_button,
      defaultWidth: 100,
      defaultHeight: 40,
      props: [
        PropDef('text', '文本', PropType.text, 'Button'),
        PropDef('fontSize', '字号', PropType.intNum, 14, min: 6, max: 96),
        PropDef('textColor', '文字颜色', PropType.color, 0xFFFFFFFF),
        PropDef('bgColor', '背景颜色', PropType.color, 0xFF1E88E5),
        PropDef('pressedColor', '按下颜色', PropType.color, 0xFF0D47A1),
        PropDef('radius', '圆角', PropType.intNum, 6, min: 0, max: 100),
      ],
      events: _interactive,
    ),
    WidgetTypeDef(
      type: 'panel',
      label: '矩形面板',
      icon: Icons.crop_square,
      defaultWidth: 160,
      defaultHeight: 100,
      props: [
        PropDef('bgColor', '填充颜色', PropType.color, 0xFF2E2E2E),
        PropDef('radius', '圆角', PropType.intNum, 0, min: 0, max: 100),
        PropDef('borderColor', '边框颜色', PropType.color, 0x00000000),
        PropDef('borderWidth', '边框宽度', PropType.intNum, 0, min: 0, max: 20),
      ],
      events: _interactive,
    ),
    WidgetTypeDef(
      type: 'line',
      label: '线条',
      icon: Icons.horizontal_rule,
      defaultWidth: 120,
      defaultHeight: 2,
      props: [
        PropDef('color', '颜色', PropType.color, 0xFF9E9E9E),
        PropDef('thickness', '粗细', PropType.intNum, 1, min: 1, max: 40),
      ],
      events: {},
    ),
    WidgetTypeDef(
      type: 'progress',
      label: '进度条',
      icon: Icons.percent,
      defaultWidth: 160,
      defaultHeight: 14,
      props: [
        PropDef('value', '当前值', PropType.intNum, 40, min: 0),
        PropDef('max', '最大值', PropType.intNum, 100, min: 1),
        PropDef('color', '进度颜色', PropType.color, 0xFF4CAF50),
        PropDef('bgColor', '背景颜色', PropType.color, 0xFF424242),
        PropDef('radius', '圆角', PropType.intNum, 4, min: 0, max: 100),
      ],
      events: {},
    ),
    WidgetTypeDef(
      type: 'slider',
      label: '滑块',
      icon: Icons.linear_scale,
      defaultWidth: 180,
      defaultHeight: 30,
      props: [
        PropDef('value', '当前值', PropType.intNum, 50, min: 0),
        PropDef('min', '最小值', PropType.intNum, 0),
        PropDef('max', '最大值', PropType.intNum, 100, min: 1),
        PropDef('color', '滑块颜色', PropType.color, 0xFF1E88E5),
        PropDef('trackColor', '轨道颜色', PropType.color, 0xFF616161),
      ],
      events: _valued,
    ),
    WidgetTypeDef(
      type: 'checkbox',
      label: '复选框',
      icon: Icons.check_box,
      defaultWidth: 120,
      defaultHeight: 28,
      props: [
        PropDef('checked', '选中', PropType.boolean, false),
        PropDef('text', '文本', PropType.text, 'Check'),
        PropDef('fontSize', '字号', PropType.intNum, 14, min: 6, max: 96),
        PropDef('color', '颜色', PropType.color, 0xFF1E88E5),
      ],
      events: _valued,
    ),
    WidgetTypeDef(
      type: 'switch',
      label: '开关',
      icon: Icons.toggle_on,
      defaultWidth: 52,
      defaultHeight: 30,
      props: [
        PropDef('on', '开启', PropType.boolean, false),
        PropDef('color', '颜色', PropType.color, 0xFF1E88E5),
      ],
      events: _valued,
    ),
    WidgetTypeDef(
      type: 'radio',
      label: '单选框',
      icon: Icons.radio_button_checked,
      defaultWidth: 120,
      defaultHeight: 28,
      props: [
        PropDef('checked', '选中', PropType.boolean, false),
        PropDef('text', '文本', PropType.text, 'Radio'),
        PropDef('group', '分组名', PropType.text, 'group1'),
        PropDef('fontSize', '字号', PropType.intNum, 14, min: 6, max: 96),
        PropDef('color', '颜色', PropType.color, 0xFF1E88E5),
      ],
      events: _valued,
    ),
    WidgetTypeDef(
      type: 'dropdown',
      label: '下拉框',
      icon: Icons.arrow_drop_down_circle,
      defaultWidth: 140,
      defaultHeight: 32,
      props: [
        PropDef('options', '选项(逗号分隔)', PropType.text, '选项1,选项2,选项3'),
        PropDef('selectedIndex', '选中项', PropType.intNum, 0, min: 0),
        PropDef('fontSize', '字号', PropType.intNum, 14, min: 6, max: 96),
        PropDef('textColor', '文字颜色', PropType.color, 0xFFFFFFFF),
        PropDef('bgColor', '背景颜色', PropType.color, 0xFF424242),
      ],
      events: _valued,
    ),
    WidgetTypeDef(
      type: 'textfield',
      label: '输入框',
      icon: Icons.input,
      defaultWidth: 160,
      defaultHeight: 36,
      props: [
        PropDef('text', '文本', PropType.text, ''),
        PropDef('hint', '提示文字', PropType.text, '请输入...'),
        PropDef('fontSize', '字号', PropType.intNum, 14, min: 6, max: 96),
        PropDef('textColor', '文字颜色', PropType.color, 0xFFFFFFFF),
        PropDef('bgColor', '背景颜色', PropType.color, 0xFF2E2E2E),
        PropDef('radius', '圆角', PropType.intNum, 4, min: 0, max: 100),
      ],
      events: _valued,
    ),
    WidgetTypeDef(
      type: 'scrolllist',
      label: '滚动列表',
      icon: Icons.view_list,
      defaultWidth: 200,
      defaultHeight: 160,
      props: [
        PropDef('orientation', '方向', PropType.choice, 'vertical',
            options: ['vertical', 'horizontal']),
        PropDef('items', '选项(逗号分隔)', PropType.text, '项目1,项目2,项目3'),
        PropDef('itemExtent', '项尺寸', PropType.intNum, 36, min: 12, max: 200),
        PropDef('spacing', '间距', PropType.intNum, 4, min: 0, max: 40),
        PropDef('selectedIndex', '选中项', PropType.intNum, 0, min: 0),
        PropDef('fontSize', '字号', PropType.intNum, 16, min: 6, max: 96),
        PropDef('textColor', '文字颜色', PropType.color, 0xFFFFFFFF),
        PropDef('selectedColor', '选中颜色', PropType.color, 0xFF1E88E5),
      ],
      events: _valued,
    ),
  ];
}
