import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../../providers/ui_designer_state.dart';
import '../models/ui_event.dart';
import '../models/ui_page.dart';
import '../models/ui_widget.dart';
import '../models/widget_registry.dart';

/// Right-hand inspector: edits the selected widget's geometry, schema
/// properties and events; with no selection it edits project / page
/// settings instead.
class PropertyPanel extends StatelessWidget {
  const PropertyPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<UiDesignerState>();
    final page = state.currentPage;

    return Container(
      color: const Color(0xFF252525),
      child: page == null
          ? const SizedBox.shrink()
          : state.selectedIds.isEmpty
              ? _ProjectPageSettings(state: state)
              : state.selectedIds.length == 1
                  ? _SingleWidgetInspector(
                      state: state,
                      widget: page.widgetById(state.selectedIds.first),
                    )
                  : Center(
                      child: Text(
                        '已选 ${state.selectedIds.length} 个控件\n右键可进行对齐/排序操作',
                        textAlign: TextAlign.center,
                        style:
                            const TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    ),
    );
  }
}

// --------------------------------------------------------------------
// Project / page settings (nothing selected)
// --------------------------------------------------------------------

class _ProjectPageSettings extends StatefulWidget {
  const _ProjectPageSettings({required this.state});

  final UiDesignerState state;

  @override
  State<_ProjectPageSettings> createState() => _ProjectPageSettingsState();
}

class _ProjectPageSettingsState extends State<_ProjectPageSettings> {
  late final TextEditingController _wCtrl;
  late final TextEditingController _hCtrl;

  @override
  void initState() {
    super.initState();
    _wCtrl =
        TextEditingController(text: '${widget.state.project.screenWidth}');
    _hCtrl =
        TextEditingController(text: '${widget.state.project.screenHeight}');
  }

  @override
  void dispose() {
    _wCtrl.dispose();
    _hCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final page = state.currentPage!;
    if (_wCtrl.text != '${state.project.screenWidth}') {
      _wCtrl.text = '${state.project.screenWidth}';
    }
    if (_hCtrl.text != '${state.project.screenHeight}') {
      _hCtrl.text = '${state.project.screenHeight}';
    }
    return ListView(
      padding: const EdgeInsets.all(10),
      children: [
        const _PanelTitle('工程设置'),
        Row(
          children: [
            Expanded(child: _numField('屏宽', _wCtrl, _applySize)),
            const SizedBox(width: 8),
            Expanded(child: _numField('屏高', _hCtrl, _applySize)),
          ],
        ),
        const SizedBox(height: 12),
        const _PanelTitle('页面'),
        _row('背景类型', _bgTypeDropdown(state, page)),
        if (page.bgType == 'color')
          _row('背景颜色', _colorSwatch(
            context,
            page.bgColor,
            (c) => state.setPageBgColor(page.id, c),
          )),
        if (page.bgType == 'image') ...[
          _row('背景图片', _bgAssetPicker(state, page)),
          _row('背景动画', _bgAnimDropdown(state, page)),
        ],
        if (page.bgType == 'video') _row('背景视频', _bgVideoPicker(state, page)),
        const SizedBox(height: 12),
        const _PanelTitle('页面事件'),
        _PageEventsEditor(state: state, page: page),
      ],
    );
  }

  void _applySize() {
    final w = int.tryParse(_wCtrl.text);
    final h = int.tryParse(_hCtrl.text);
    if (w != null && h != null) widget.state.setScreenSize(w, h);
  }

  Widget _bgTypeDropdown(UiDesignerState state, UiPage page) {
    return DropdownButton<String>(
      value: page.bgType,
      isDense: true,
      style: const TextStyle(fontSize: 12),
      items: const [
        DropdownMenuItem(value: 'color', child: Text('纯色')),
        DropdownMenuItem(value: 'image', child: Text('图片')),
        DropdownMenuItem(value: 'video', child: Text('视频')),
      ],
      onChanged: (v) {
        if (v != null) state.setPageBackground(page.id, v);
      },
    );
  }

  Widget _bgAssetPicker(UiDesignerState state, UiPage page) {
    final currentId = page.bgAssetId;
    return Row(
      children: [
        // Expanded + isExpanded: long asset names ellipsize instead of
        // pushing the import button out of the panel.
        Expanded(
          child: DropdownButton<String>(
            value: state.project.assets.any((a) => a.id == currentId)
                ? currentId
                : null,
            hint: const Text('未选择',
                style: TextStyle(fontSize: 12),
                overflow: TextOverflow.ellipsis),
            isDense: true,
            isExpanded: true,
            style: const TextStyle(fontSize: 12),
            items: [
              for (final a in state.project.assets)
                DropdownMenuItem(
                    value: a.id,
                    child: Text(a.name, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) => state.setPageBackground(page.id, 'image',
                assetId: v),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.add_photo_alternate,
              size: 16, color: Colors.cyanAccent),
          tooltip: '导入图片',
          onPressed: () async {
            final file = await openFile(
              acceptedTypeGroups: const [
                XTypeGroup(label: '图片', extensions: ['png', 'jpg', 'bmp'])
              ],
            );
            if (file == null) return;
            final asset = state.importAsset(file.path);
            state.setPageBackground(page.id, 'image', assetId: asset.id);
          },
        ),
      ],
    );
  }

  Widget _bgAnimDropdown(UiDesignerState state, UiPage page) {
    return DropdownButton<String>(
      value: page.bgAnim,
      isDense: true,
      isExpanded: true,
      style: const TextStyle(fontSize: 12),
      items: const [
        DropdownMenuItem(
            value: 'none',
            child: Text('无', overflow: TextOverflow.ellipsis)),
        DropdownMenuItem(
            value: 'kenburns',
            child: Text('Ken Burns 缓推', overflow: TextOverflow.ellipsis)),
        DropdownMenuItem(
            value: 'parallax',
            child: Text('视差滚动', overflow: TextOverflow.ellipsis)),
      ],
      onChanged: (v) {
        if (v != null) {
          state.setPageBackground(page.id, 'image', anim: v);
        }
      },
    );
  }

  Widget _bgVideoPicker(UiDesignerState state, UiPage page) {    final path = page.bgVideoPath;
    return Row(
      children: [
        Flexible(
          child: Text(
            path == null ? '未选择' : p.basename(path),
            style: const TextStyle(fontSize: 12),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        IconButton(
          icon: const Icon(Icons.video_file,
              size: 16, color: Colors.cyanAccent),
          tooltip: '选择视频文件',
          onPressed: () async {
            final file = await openFile(
              acceptedTypeGroups: const [
                XTypeGroup(
                    label: '视频',
                    extensions: ['mp4', 'avi', 'mkv', 'mov', 'ts'])
              ],
            );
            if (file == null) return;
            state.setPageBackground(page.id, 'video', videoPath: file.path);
          },
        ),
      ],
    );
  }
}

class _PageEventsEditor extends StatelessWidget {
  const _PageEventsEditor({required this.state, required this.page});

  final UiDesignerState state;
  final UiPage page;

  @override
  Widget build(BuildContext context) {
    const types = [
      UiEventType.onShow,
      UiEventType.onHide,
      UiEventType.onTimer,
    ];
    return Column(
      children: [
        for (final type in types)
          _EventRow(
            type: type,
            events: page.events,
            hint: '回调函数名',
            onChanged: (events) => state.setPageEvents(page.id, events),
          ),
      ],
    );
  }
}

// --------------------------------------------------------------------
// Single widget inspector
// --------------------------------------------------------------------

class _SingleWidgetInspector extends StatelessWidget {
  const _SingleWidgetInspector({required this.state, required this.widget});

  final UiDesignerState state;
  final UiWidgetModel? widget;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    if (w == null) return const SizedBox.shrink();
    final def = WidgetRegistry.of(w.type);

    return ListView(
      padding: const EdgeInsets.all(10),
      children: [
        _PanelTitle('${def?.label ?? w.type} · ${w.name}'),
        _row('名称', _textInput(
          w.name,
          (v) => state.renameWidget(w.id, v),
        )),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(child: _intInput('X', w.x, (v) => _setRect(state, w, x: v))),
            const SizedBox(width: 6),
            Expanded(child: _intInput('Y', w.y, (v) => _setRect(state, w, y: v))),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(child: _intInput('宽', w.width, (v) => _setRect(state, w, width: v))),
            const SizedBox(width: 6),
            Expanded(child: _intInput('高', w.height, (v) => _setRect(state, w, height: v))),
          ],
        ),
        const SizedBox(height: 12),
        const _PanelTitle('变换'),
        Row(
          children: [
            Expanded(
                child: _intInput(
                    '旋转°',
                    (w.props['rotate'] as num?)?.toDouble() ?? 0,
                    (v) => state.updateWidgetProps(
                        w.id, {'rotate': v.round().clamp(0, 359)}))),
            const SizedBox(width: 6),
            Expanded(
                child: _intInput(
                    '缩放%',
                    (w.props['scale'] as num?)?.toDouble() ?? 100,
                    (v) => state.updateWidgetProps(
                        w.id, {'scale': v.round().clamp(10, 400)}))),
            const SizedBox(width: 6),
            Expanded(
                child: _intInput(
                    '不透明%',
                    (w.props['opacity'] as num?)?.toDouble() ?? 100,
                    (v) => state.updateWidgetProps(
                        w.id, {'opacity': v.round().clamp(0, 100)}))),
          ],
        ),
        if (def != null) ...[
          const SizedBox(height: 12),
          const _PanelTitle('属性'),
          for (final prop in def.props) ...[
            _PropEditor(prop: prop, widget: w, state: state),
            const SizedBox(height: 8),
          ],
          if (def.events.isNotEmpty) ...[
            const SizedBox(height: 4),
            const _PanelTitle('事件'),
            for (final type in def.events)
              _EventRow(
                type: type,
                events: w.events,
                hint: '回调函数名',
                onChanged: (events) => state.setWidgetEvents(w.id, events),
              ),
          ],
        ],
      ],
    );
  }

  void _setRect(UiDesignerState state, UiWidgetModel w,
      {double? x, double? y, double? width, double? height}) {
    state.setWidgetRect(
      w.id,
      Rect.fromLTWH(
        x ?? w.x,
        y ?? w.y,
        (width ?? w.width).clamp(4, 4096),
        (height ?? w.height).clamp(4, 4096),
      ),
    );
  }
}

// --------------------------------------------------------------------
// Property editors
// --------------------------------------------------------------------

class _PropEditor extends StatelessWidget {
  const _PropEditor(
      {required this.prop, required this.widget, required this.state});

  final PropDef prop;
  final UiWidgetModel widget;
  final UiDesignerState state;

  @override
  Widget build(BuildContext context) {
    final value = widget.props[prop.key];
    switch (prop.type) {
      case PropType.boolean:
        return _row(
          prop.label,
          SizedBox(
            width: 18,
            height: 18,
            child: Checkbox(
              value: value as bool? ?? false,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              onChanged: (v) =>
                  state.updateWidgetProps(widget.id, {prop.key: v ?? false}),
            ),
          ),
        );
      case PropType.color:
        return _row(
          prop.label,
          _colorSwatch(
            context,
            value as int? ?? 0xFFFFFFFF,
            (c) => state.updateWidgetProps(widget.id, {prop.key: c}),
          ),
        );
      case PropType.choice:
        return _row(
          prop.label,
          DropdownButton<String>(
            value: (value as String?) ?? prop.options!.first,
            isDense: true,
            style: const TextStyle(fontSize: 12),
            items: [
              for (final o in prop.options!)
                DropdownMenuItem(value: o, child: Text(o)),
            ],
            onChanged: (v) {
              if (v != null) {
                state.updateWidgetProps(widget.id, {prop.key: v});
              }
            },
          ),
        );
      case PropType.asset:
        return _row(prop.label, _assetPicker(context));
      case PropType.intNum:
      case PropType.doubleNum:
        return _row(
          prop.label,
          _textInput(
            '$value',
            (v) {
              final n = prop.type == PropType.intNum
                  ? int.tryParse(v)
                  : double.tryParse(v);
              if (n != null) {
                state.updateWidgetProps(widget.id, {prop.key: n});
              }
            },
          ),
        );
      case PropType.text:
      case PropType.multiline:
        return _row(
          prop.label,
          _textInput(
            value as String? ?? '',
            (v) => state.updateWidgetProps(widget.id, {prop.key: v}),
          ),
        );
    }
  }

  Widget _assetPicker(BuildContext context) {
    final currentId = widget.props['asset'] as String?;
    return Row(
      children: [
        Expanded(
          child: DropdownButton<String>(
            value: state.project.assets.any((a) => a.id == currentId)
                ? currentId
                : null,
            hint: const Text('未选择',
                style: TextStyle(fontSize: 12),
                overflow: TextOverflow.ellipsis),
            isDense: true,
            isExpanded: true,
            style: const TextStyle(fontSize: 12),
            items: [
              for (final a in state.project.assets)
                DropdownMenuItem(
                    value: a.id,
                    child: Text(a.name, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) =>
                state.updateWidgetProps(widget.id, {'asset': v}),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.add_photo_alternate,
              size: 16, color: Colors.cyanAccent),
          tooltip: '导入图片',
          onPressed: () async {
            final file = await openFile(
              acceptedTypeGroups: const [
                XTypeGroup(label: '图片', extensions: ['png', 'jpg', 'bmp'])
              ],
            );
            if (file == null) return;
            final asset = state.importAsset(file.path);
            state.updateWidgetProps(widget.id, {'asset': asset.id});
          },
        ),
      ],
    );
  }
}

// --------------------------------------------------------------------
// Event row
// --------------------------------------------------------------------

class _EventRow extends StatelessWidget {
  const _EventRow({
    required this.type,
    required this.events,
    required this.hint,
    required this.onChanged,
  });

  final UiEventType type;
  final List<UiEvent> events;
  final String hint;
  final ValueChanged<List<UiEvent>> onChanged;

  @override
  Widget build(BuildContext context) {
    final state = context.read<UiDesignerState>();
    final existing = events.where((e) => e.type == type).firstOrNull;
    final enabled = existing != null;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 18,
                height: 18,
                child: Checkbox(
                  value: enabled,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onChanged: (v) {
                    final next = events
                        .where((e) => e.type != type)
                        .map((e) => e.copy())
                        .toList();
                    if (v ?? false) next.add(UiEvent(type: type));
                    onChanged(next);
                  },
                ),
              ),
              const SizedBox(width: 6),
              Text(type.label, style: const TextStyle(fontSize: 12)),
              const Spacer(),
              if (enabled)
                DropdownButton<UiActionType>(
                  value: existing.action,
                  isDense: true,
                  style: const TextStyle(fontSize: 12),
                  items: [
                    for (final a in UiActionType.values)
                      DropdownMenuItem(value: a, child: Text(a.label)),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    final next = events.map((e) => e.copy()).toList();
                    next.firstWhere((e) => e.type == type).action = v;
                    onChanged(next);
                  },
                ),
            ],
          ),
          if (enabled)
            Padding(
              padding: const EdgeInsets.only(left: 24, top: 4),
              child: existing.action == UiActionType.callback
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _textInput(
                          existing.callback,
                          (v) {
                            final next = events.map((e) => e.copy()).toList();
                            next.firstWhere((e) => e.type == type).callback =
                                v;
                            onChanged(next);
                          },
                          hint: hint,
                        ),
                        if (type == UiEventType.onTimer) ...[
                          const SizedBox(height: 4),
                          _textInput(
                            '${existing.timerMs}',
                            (v) {
                              final ms = int.tryParse(v);
                              if (ms == null) return;
                              final next =
                                  events.map((e) => e.copy()).toList();
                              next.firstWhere((e) => e.type == type).timerMs =
                                  ms;
                              onChanged(next);
                            },
                            hint: '周期 (毫秒)',
                          ),
                        ],
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        DropdownButton<String>(
                          value: state.project.pages
                                  .any((p) => p.id == existing.targetPageId)
                              ? existing.targetPageId
                              : null,
                          hint: const Text('选择目标页面',
                              style: TextStyle(fontSize: 12)),
                          isDense: true,
                          style: const TextStyle(fontSize: 12),
                          items: [
                            for (final p in state.project.pages)
                              DropdownMenuItem(
                                  value: p.id, child: Text(p.name)),
                          ],
                          onChanged: (v) {
                            final next =
                                events.map((e) => e.copy()).toList();
                            next
                                .firstWhere((e) => e.type == type)
                                .targetPageId = v;
                            onChanged(next);
                          },
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            const Text('切换特效',
                                style: TextStyle(
                                    fontSize: 11, color: Colors.grey)),
                            const SizedBox(width: 8),
                            DropdownButton<String>(
                              value: existing.transition,
                              isDense: true,
                              style: const TextStyle(fontSize: 12),
                              items: const [
                                DropdownMenuItem(
                                    value: 'none', child: Text('无')),
                                DropdownMenuItem(
                                    value: 'slideLeft',
                                    child: Text('左滑入')),
                                DropdownMenuItem(
                                    value: 'slideRight',
                                    child: Text('右滑入')),
                                DropdownMenuItem(
                                    value: 'fade',
                                    child: Text('淡入淡出')),
                                DropdownMenuItem(
                                    value: 'pushLeft',
                                    child: Text('推入覆盖')),
                                DropdownMenuItem(
                                    value: 'cube',
                                    child: Text('立方体翻转')),
                              ],
                              onChanged: (v) {
                                if (v == null) return;
                                final next =
                                    events.map((e) => e.copy()).toList();
                                next
                                    .firstWhere((e) => e.type == type)
                                    .transition = v;
                                onChanged(next);
                              },
                            ),
                          ],
                        ),
                      ],
                    ),
            ),
        ],
      ),
    );
  }
}

// --------------------------------------------------------------------
// Small shared controls
// --------------------------------------------------------------------

class _PanelTitle extends StatelessWidget {
  const _PanelTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: const TextStyle(
            fontSize: 11, color: Colors.grey, fontWeight: FontWeight.bold),
      ),
    );
  }
}

Widget _row(String label, Widget control) {
  return Row(
    children: [
      SizedBox(
        width: 72,
        child: Text(label,
            style: const TextStyle(fontSize: 12, color: Colors.grey)),
      ),
      Expanded(child: Align(alignment: Alignment.centerLeft, child: control)),
    ],
  );
}

Widget _textInput(String value, ValueChanged<String> onChanged,
    {String? hint}) {
  return _LazyTextField(value: value, hint: hint, onChanged: onChanged);
}

Widget _intInput(String label, double value, ValueChanged<double> onChanged) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(fontSize: 10, color: Colors.grey)),
      const SizedBox(height: 2),
      _LazyTextField(
        value: value.toStringAsFixed(0),
        onChanged: (v) {
          final n = double.tryParse(v);
          if (n != null) onChanged(n);
        },
      ),
    ],
  );
}

Widget _numField(
    String label, TextEditingController controller, VoidCallback onDone) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(fontSize: 10, color: Colors.grey)),
      const SizedBox(height: 2),
      TextField(
        controller: controller,
        style: const TextStyle(fontSize: 12, fontFamily: 'Consolas'),
        decoration: _inputDecoration(),
        onSubmitted: (_) => onDone(),
        onEditingComplete: onDone,
      ),
    ],
  );
}

InputDecoration _inputDecoration({String? hint}) => InputDecoration(
      isDense: true,
      hintText: hint,
      hintStyle: const TextStyle(fontSize: 11, color: Colors.grey),
      filled: true,
      fillColor: const Color(0xFF1E1E1E),
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(4),
        borderSide: BorderSide(color: Colors.grey.shade800),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(4),
        borderSide: BorderSide(color: Colors.grey.shade800),
      ),
    );

/// A text field that keeps its own controller and only reports on submit /
/// focus loss, so typing is not disturbed by external rebuilds.
class _LazyTextField extends StatefulWidget {
  const _LazyTextField({required this.value, required this.onChanged, this.hint});

  final String value;
  final String? hint;
  final ValueChanged<String> onChanged;

  @override
  State<_LazyTextField> createState() => _LazyTextFieldState();
}

class _LazyTextFieldState extends State<_LazyTextField> {
  late final TextEditingController _controller;
  late final FocusNode _focus;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value);
    _focus = FocusNode()..addListener(_onFocusChange);
  }

  void _onFocusChange() {
    if (!_focus.hasFocus && _controller.text != widget.value) {
      widget.onChanged(_controller.text);
    }
  }

  @override
  void didUpdateWidget(_LazyTextField old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus && _controller.text != widget.value) {
      _controller.text = widget.value;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      focusNode: _focus,
      style: const TextStyle(fontSize: 12, fontFamily: 'Consolas'),
      decoration: _inputDecoration(hint: widget.hint),
      onSubmitted: widget.onChanged,
    );
  }
}

Widget _colorSwatch(
    BuildContext context, int argbValue, ValueChanged<int> onChanged) {
  return InkWell(
    onTap: () async {
      var picked = Color(argbValue);
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF2E2E2E),
          title: const Text('选择颜色', style: TextStyle(fontSize: 14)),
          content: SingleChildScrollView(
            child: ColorPicker(
              pickerColor: picked,
              onColorChanged: (c) => picked = c,
              enableAlpha: true,
              labelTypes: const [],
              pickerAreaHeightPercent: 0.6,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('确定'),
            ),
          ],
        ),
      );
      if (confirmed ?? false) onChanged(picked.toARGB32());
    },
    child: Container(
      width: 48,
      height: 22,
      decoration: BoxDecoration(
        color: Color(argbValue),
        border: Border.all(color: Colors.white38),
        borderRadius: BorderRadius.circular(4),
      ),
    ),
  );
}
