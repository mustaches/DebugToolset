import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../modules/ui_designer/models/project_serializer.dart';
import '../modules/ui_designer/models/ui_event.dart';
import '../modules/ui_designer/models/ui_page.dart';
import '../modules/ui_designer/models/ui_project.dart';
import '../modules/ui_designer/models/ui_widget.dart';
import '../modules/ui_designer/models/widget_registry.dart';

/// State backing the UI designer module: project data, editing selection,
/// undo/redo and the interactive preview simulation.
class UiDesignerState extends ChangeNotifier {
  UiDesignerState() {
    newProject();
  }

  // ------------------------------------------------------------------
  // Project
  // ------------------------------------------------------------------

  UiProject project = UiProject(name: 'untitled');
  String? projectFilePath;
  bool dirty = false;

  String? currentPageId;
  final Set<String> selectedIds = {};

  int gridSize = 8;
  bool snapEnabled = true;

  /// 0 means "fit to window".
  double zoom = 0;

  void toggleSnap() {
    snapEnabled = !snapEnabled;
    notifyListeners();
  }

  void setZoom(double value) {
    zoom = value;
    notifyListeners();
  }

  UiPage? get currentPage => project.pageById(currentPageId ?? '');

  void newProject() {
    project = UiProject(name: 'untitled');
    project.pages.add(UiPage(id: _newId('page'), name: '页面1'));
    currentPageId = project.pages.first.id;
    selectedIds.clear();
    projectFilePath = null;
    dirty = false;
    _undoStack.clear();
    _redoStack.clear();
    notifyListeners();
  }

  // ------------------------------------------------------------------
  // Undo / redo (JSON snapshots)
  // ------------------------------------------------------------------

  static const _undoLimit = 50;
  final List<String> _undoStack = [];
  final List<String> _redoStack = [];

  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;

  void _snapshot() {
    _undoStack.add(ProjectSerializer.encode(project));
    if (_undoStack.length > _undoLimit) _undoStack.removeAt(0);
    _redoStack.clear();
  }

  void _restore(String json) {
    project = ProjectSerializer.decode(json);
    if (project.pageById(currentPageId ?? '') == null) {
      currentPageId = project.pages.isEmpty ? null : project.pages.first.id;
    }
    selectedIds.removeWhere(
        (id) => currentPage?.widgetById(id) == null);
  }

  void undo() {
    if (_undoStack.isEmpty) return;
    _redoStack.add(ProjectSerializer.encode(project));
    _restore(_undoStack.removeLast());
    dirty = true;
    notifyListeners();
  }

  void redo() {
    if (_redoStack.isEmpty) return;
    _undoStack.add(ProjectSerializer.encode(project));
    _restore(_redoStack.removeLast());
    dirty = true;
    notifyListeners();
  }

  // ------------------------------------------------------------------
  // Pages
  // ------------------------------------------------------------------

  void addPage() {
    _snapshot();
    final page =
        UiPage(id: _newId('page'), name: _uniquePageName('页面'));
    project.pages.add(page);
    currentPageId = page.id;
    dirty = true;
    notifyListeners();
  }

  void removePage(String id) {
    if (project.pages.length <= 1) return;
    _snapshot();
    project.pages.removeWhere((pg) => pg.id == id);
    if (currentPageId == id) currentPageId = project.pages.first.id;
    dirty = true;
    notifyListeners();
  }

  void renamePage(String id, String name) {
    final page = project.pageById(id);
    if (page == null || name.trim().isEmpty) return;
    _snapshot();
    page.name = name.trim();
    dirty = true;
    notifyListeners();
  }

  void selectPage(String id) {
    if (currentPageId == id) return;
    currentPageId = id;
    selectedIds.clear();
    notifyListeners();
  }

  void setPageBgColor(String id, int color) {
    final page = project.pageById(id);
    if (page == null) return;
    _snapshot();
    page.bgColor = color;
    dirty = true;
    notifyListeners();
  }

  void setPageEvents(String id, List<UiEvent> events) {
    final page = project.pageById(id);
    if (page == null) return;
    _snapshot();
    page.events = events;
    dirty = true;
    notifyListeners();
  }

  void setScreenSize(int w, int h) {
    if (w < 16 || h < 16) return;
    _snapshot();
    project.screenWidth = w;
    project.screenHeight = h;
    dirty = true;
    notifyListeners();
  }

  // ------------------------------------------------------------------
  // Widgets
  // ------------------------------------------------------------------

  int _idCounter = 0;
  String _newId(String prefix) =>
      '${prefix}_${DateTime.now().microsecondsSinceEpoch}_${_idCounter++}';

  String _uniquePageName(String base) {
    final names = project.pages.map((e) => e.name).toSet();
    var i = project.pages.length + 1;
    var name = '$base$i';
    while (names.contains(name)) {
      i++;
      name = '$base$i';
    }
    return name;
  }

  String _uniqueWidgetName(String base) {
    final names = <String>{
      for (final pg in project.pages)
        for (final w in pg.widgets) w.name,
    };
    var i = 1;
    var name = '${base}_$i';
    while (names.contains(name)) {
      i++;
      name = '${base}_$i';
    }
    return name;
  }

  double _snap(double v) =>
      snapEnabled ? (v / gridSize).round() * gridSize.toDouble() : v;

  /// Adds a widget of [type] to the current page and selects it.
  void addWidget(String type, {Offset? at}) {
    final page = currentPage;
    final def = WidgetRegistry.of(type);
    if (page == null || def == null) return;
    _snapshot();
    final w = UiWidgetModel(
      id: _newId('w'),
      type: type,
      name: _uniqueWidgetName(type),
      x: _snap(at?.dx ?? (project.screenWidth - def.defaultWidth) / 2),
      y: _snap(at?.dy ?? (project.screenHeight - def.defaultHeight) / 2),
      width: def.defaultWidth,
      height: def.defaultHeight,
      props: def.defaultProps(),
    );
    page.widgets.add(w);
    selectedIds
      ..clear()
      ..add(w.id);
    dirty = true;
    notifyListeners();
  }

  void setSelection(Iterable<String> ids) {
    selectedIds
      ..clear()
      ..addAll(ids);
    notifyListeners();
  }

  void toggleSelected(String id) {
    if (!selectedIds.add(id)) selectedIds.remove(id);
    notifyListeners();
  }

  void clearSelection() {
    if (selectedIds.isEmpty) return;
    selectedIds.clear();
    notifyListeners();
  }

  /// Snapshots once before a drag (move/resize) begins; the canvas then
  /// mutates rects directly and calls [notifyMove] / [commitMove].
  void beginMove() => _snapshot();

  /// Called continuously while a drag mutates widget geometry.
  void notifyMove() {
    dirty = true;
    notifyListeners();
  }

  /// Called when a drag ends; the pre-drag snapshot is already stacked.
  void commitMove() {
    dirty = true;
    notifyListeners();
  }

  /// Keyboard nudge of the selection by [delta] (no snapping).
  void nudgeSelected(Offset delta) {
    final page = currentPage;
    if (page == null || selectedIds.isEmpty) return;
    _snapshot();
    for (final id in selectedIds) {
      final w = page.widgetById(id);
      if (w == null) continue;
      w.x += delta.dx;
      w.y += delta.dy;
    }
    dirty = true;
    notifyListeners();
  }

  void setWidgetRect(String id, Rect rect, {bool commit = true}) {
    final w = currentPage?.widgetById(id);
    if (w == null) return;
    if (commit) _snapshot();
    w.setRect(rect);
    dirty = true;
    notifyListeners();
  }

  void updateWidgetProps(String id, Map<String, dynamic> updates) {
    final w = currentPage?.widgetById(id);
    if (w == null) return;
    _snapshot();
    w.props.addAll(updates);
    dirty = true;
    notifyListeners();
  }

  void renameWidget(String id, String name) {
    final w = currentPage?.widgetById(id);
    final clean = sanitizeCIdentifier(name);
    if (w == null || clean == null) return;
    _snapshot();
    w.name = clean;
    dirty = true;
    notifyListeners();
  }

  void setWidgetEvents(String id, List<UiEvent> events) {
    final w = currentPage?.widgetById(id);
    if (w == null) return;
    _snapshot();
    w.events = events;
    dirty = true;
    notifyListeners();
  }

  void deleteSelected() {
    final page = currentPage;
    if (page == null || selectedIds.isEmpty) return;
    _snapshot();
    page.widgets.removeWhere((w) => selectedIds.contains(w.id));
    selectedIds.clear();
    dirty = true;
    notifyListeners();
  }

  List<UiWidgetModel>? _clipboard;

  void copySelected() {
    final page = currentPage;
    if (page == null || selectedIds.isEmpty) return;
    _clipboard = [
      for (final w in page.widgets)
        if (selectedIds.contains(w.id)) w.copy(),
    ];
  }

  void paste() {
    final page = currentPage;
    final clip = _clipboard;
    if (page == null || clip == null || clip.isEmpty) return;
    _snapshot();
    final newIds = <String>[];
    for (final src in clip) {
      final w = src.copy(newId: _newId('w'));
      w.name = _uniqueWidgetName(w.type);
      w.x = _snap(w.x + gridSize);
      w.y = _snap(w.y + gridSize);
      page.widgets.add(w);
      newIds.add(w.id);
    }
    selectedIds
      ..clear()
      ..addAll(newIds);
    dirty = true;
    notifyListeners();
  }

  /// [front] true brings to top, false sends to bottom.
  void reorderSelected({required bool front}) {
    final page = currentPage;
    if (page == null || selectedIds.isEmpty) return;
    _snapshot();
    final sel = page.widgets
        .where((w) => selectedIds.contains(w.id))
        .toList(growable: false);
    page.widgets.removeWhere((w) => selectedIds.contains(w.id));
    if (front) {
      page.widgets.addAll(sel);
    } else {
      page.widgets.insertAll(0, sel);
    }
    dirty = true;
    notifyListeners();
  }

  // ------------------------------------------------------------------
  // Assets
  // ------------------------------------------------------------------

  /// Directory containing the project file, used to resolve relative
  /// asset paths. Null when the project was never saved.
  String? get projectDir =>
      projectFilePath == null ? null : p.dirname(projectFilePath!);

  /// Resolves an asset source path to an absolute path for display.
  String? resolveAssetPath(UiAsset asset) {
    if (p.isAbsolute(asset.srcFile)) return asset.srcFile;
    final dir = projectDir;
    if (dir == null) return null;
    return p.normalize(p.join(dir, asset.srcFile));
  }

  /// Imports an image file as an asset (kept as an absolute path until the
  /// project is saved, then copied into `<project>_assets/`).
  UiAsset importAsset(String absPath, {String? name}) {
    _snapshot();
    final base = sanitizeCIdentifier(
            name ?? p.basenameWithoutExtension(absPath)) ??
        'img';
    final asset = UiAsset(
      id: _newId('asset'),
      name: _uniqueWidgetName(base),
      srcFile: absPath,
    );
    project.assets.add(asset);
    dirty = true;
    notifyListeners();
    return asset;
  }

  // ------------------------------------------------------------------
  // Save / load
  // ------------------------------------------------------------------

  Future<void> saveProject(String path) async {
    if (!path.toLowerCase().endsWith('.uiproj')) path = '$path.uiproj';
    final dir = p.dirname(path);
    final assetsDir = p.join(
        dir, '${p.basenameWithoutExtension(path)}_assets');
    // Copy absolute asset sources next to the project and rewrite paths
    // to relative ones.
    for (final asset in project.assets) {
      if (p.isAbsolute(asset.srcFile) && File(asset.srcFile).existsSync()) {
        await Directory(assetsDir).create(recursive: true);
        final dest =
            p.join(assetsDir, '${asset.name}${p.extension(asset.srcFile)}');
        if (p.normalize(asset.srcFile) != p.normalize(dest)) {
          await File(asset.srcFile).copy(dest);
        }
        asset.srcFile = p.relative(dest, from: dir);
      }
    }
    await File(path)
        .writeAsString(ProjectSerializer.encode(project));
    projectFilePath = path;
    dirty = false;
    notifyListeners();
  }

  Future<void> loadProject(String path) async {
    final text = await File(path).readAsString();
    final loaded = ProjectSerializer.decode(text);
    project = loaded;
    projectFilePath = path;
    currentPageId = project.pages.isEmpty ? null : project.pages.first.id;
    selectedIds.clear();
    dirty = false;
    previewMode = false;
    _undoStack.clear();
    _redoStack.clear();
    notifyListeners();
  }

  // ------------------------------------------------------------------
  // Preview simulation
  // ------------------------------------------------------------------

  bool previewMode = false;

  /// Runtime values of interactive widgets, keyed by widget id.
  final Map<String, dynamic> runtimeValues = {};
  String? focusedWidgetId;
  String? pressedWidgetId;
  final List<String> callbackLog = [];
  Timer? _pageTimer;

  void enterPreview() {
    previewMode = true;
    selectedIds.clear();
    focusedWidgetId = null;
    pressedWidgetId = null;
    callbackLog.clear();
    runtimeValues.clear();
    if (project.pages.isNotEmpty) {
      currentPageId = project.pages.first.id;
    }
    _firePageEvent(UiEventType.onShow);
    _restartPageTimer();
    notifyListeners();
  }

  void exitPreview() {
    previewMode = false;
    _pageTimer?.cancel();
    _pageTimer = null;
    notifyListeners();
  }

  dynamic runtimeValueOf(UiWidgetModel w) =>
      runtimeValues[w.id] ?? w.props['value'] ?? w.props['checked'] ??
      w.props['on'] ?? w.props['selectedIndex'];

  void _log(String message) {
    final t = DateTime.now();
    callbackLog.insert(
        0,
        '[${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}:'
        '${t.second.toString().padLeft(2, '0')}] $message');
    if (callbackLog.length > 200) callbackLog.removeLast();
  }

  void _fireEvent(UiEvent e, UiWidgetModel? widget, [String? arg]) {
    if (e.action == UiActionType.callback) {
      final cb = e.callback.trim();
      if (cb.isNotEmpty) {
        _log('回调 $cb(${arg ?? ''})'
            '${widget != null ? '  ← ${widget.name}' : ''}');
      }
    } else if (e.action == UiActionType.gotoPage &&
        e.targetPageId != null &&
        project.pageById(e.targetPageId!) != null) {
      _firePageEvent(UiEventType.onHide);
      currentPageId = e.targetPageId;
      focusedWidgetId = null;
      _log('跳转到页面「${project.pageById(e.targetPageId!)!.name}」');
      _firePageEvent(UiEventType.onShow);
      _restartPageTimer();
    }
  }

  void _firePageEvent(UiEventType type) {
    final page = currentPage;
    if (page == null) return;
    for (final e in page.events.where((e) => e.type == type)) {
      _fireEvent(e, null);
    }
  }

  void _restartPageTimer() {
    _pageTimer?.cancel();
    _pageTimer = null;
    final page = currentPage;
    if (page == null) return;
    final timerEvents =
        page.events.where((e) => e.type == UiEventType.onTimer).toList();
    if (timerEvents.isEmpty) return;
    final interval = timerEvents.first.timerMs;
    if (interval <= 0) return;
    _pageTimer = Timer.periodic(Duration(milliseconds: interval), (_) {
      if (!previewMode) return;
      for (final e in timerEvents) {
        _fireEvent(e, null);
        if (e.action == UiActionType.callback) {
          _log('定时器(${interval}ms) 触发');
        }
      }
      notifyListeners();
    });
  }

  /// Tap in preview mode: focus activation then click event.
  void previewTap(UiWidgetModel w) {
    final def = WidgetRegistry.of(w.type);
    if (def == null) return;
    if (def.events.contains(UiEventType.onFocus) && focusedWidgetId != w.id) {
      focusedWidgetId = w.id;
      for (final e in w.events.where((e) => e.type == UiEventType.onFocus)) {
        _fireEvent(e, w);
      }
      if (def.events.contains(UiEventType.onFocus)) {
        _log('焦点激活 → ${w.name}');
      }
    }
    for (final e in w.events.where((e) => e.type == UiEventType.onClick)) {
      _fireEvent(e, w);
    }
    // Built-in behaviour for value widgets with no explicit binding.
    switch (w.type) {
      case 'checkbox':
        previewSetValue(w, !(runtimeValueOf(w) as bool? ?? false));
      case 'switch':
        previewSetValue(w, !(runtimeValueOf(w) as bool? ?? false));
      case 'radio':
        previewSetValue(w, true);
      case 'dropdown':
        final options =
            (w.props['options'] as String? ?? '').split(',');
        if (options.length > 1) {
          final cur = runtimeValueOf(w) as int? ?? 0;
          previewSetValue(w, (cur + 1) % options.length);
        }
    }
    notifyListeners();
  }

  void previewSetValue(UiWidgetModel w, dynamic value) {
    final old = runtimeValueOf(w);
    runtimeValues[w.id] = value;
    if (old != value) {
      for (final e
          in w.events.where((e) => e.type == UiEventType.onValueChange)) {
        _fireEvent(e, w, '$value');
      }
      if (w.events.every((e) => e.type != UiEventType.onValueChange)) {
        _log('${w.name} 值变化 → $value');
      }
    }
    notifyListeners();
  }

  void previewPressDown(UiWidgetModel w) {
    pressedWidgetId = w.id;
    notifyListeners();
  }

  void previewPressUp() {
    pressedWidgetId = null;
    notifyListeners();
  }
}
