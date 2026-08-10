/// Event types a widget or a page can raise.
enum UiEventType {
  onClick('单击'),
  onFocus('获得焦点'),
  onValueChange('值变化'),
  onShow('页面显示'),
  onHide('页面隐藏'),
  onTimer('定时刷新');

  const UiEventType(this.label);
  final String label;
}

/// What happens when an event fires.
enum UiActionType {
  callback('调用回调'),
  gotoPage('跳转页面');

  const UiActionType(this.label);
  final String label;
}

/// A single event binding on a widget or page: when [type] fires, either
/// call the C function [callback] or switch to the page [targetPageId].
class UiEvent {
  UiEvent({
    required this.type,
    this.action = UiActionType.callback,
    this.callback = '',
    this.targetPageId,
    this.timerMs = 1000,
    this.transition = 'none',
  });

  UiEventType type;
  UiActionType action;

  /// C function name, used when [action] is [UiActionType.callback].
  String callback;

  /// Target page id, used when [action] is [UiActionType.gotoPage].
  String? targetPageId;

  /// Period in milliseconds, only for [UiEventType.onTimer].
  int timerMs;

  /// Page transition effect, used when [action] is [UiActionType.gotoPage]:
  /// 'none' | 'slideLeft' | 'slideRight' | 'fade' | 'pushLeft' | 'cube'.
  String transition;

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'action': action.name,
        'callback': callback,
        if (targetPageId != null) 'targetPageId': targetPageId,
        if (type == UiEventType.onTimer) 'timerMs': timerMs,
        if (action == UiActionType.gotoPage && transition != 'none')
          'transition': transition,
      };

  factory UiEvent.fromJson(Map<String, dynamic> json) => UiEvent(
        type: UiEventType.values.asNameMap()[json['type']] ??
            UiEventType.onClick,
        action: UiActionType.values.asNameMap()[json['action']] ??
            UiActionType.callback,
        callback: json['callback'] as String? ?? '',
        targetPageId: json['targetPageId'] as String?,
        timerMs: (json['timerMs'] as num?)?.toInt() ?? 1000,
        transition: json['transition'] as String? ?? 'none',
      );

  UiEvent copy() => UiEvent(
        type: type,
        action: action,
        callback: callback,
        targetPageId: targetPageId,
        timerMs: timerMs,
        transition: transition,
      );
}
