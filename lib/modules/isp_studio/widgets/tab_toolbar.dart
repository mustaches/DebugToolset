/// ISP Studio 标签页工具栏（标签栏下方那一行）的公共样式：所有标签页
/// （画布 / 节点代码 / 编组代码 / IP / 仿真波形）的工具栏同一高度，
/// 切换标签时工具栏条不跳动。内容约定：功能按钮在左，页面信息（编组名、
/// 变体、目标 CPU、只读标识等）经 Spacer 收在右侧。
library;

import 'package:flutter/material.dart';

/// 标签页工具栏统一高度（与画布主工具栏一致）。
const double kIspTabToolbarHeight = 30;

/// 标签页工具栏行的统一容器（高度 / 底色 / 下边框一致）。
Widget ispTabToolbarRow({required List<Widget> children}) {
  return Container(
    height: kIspTabToolbarHeight,
    decoration: const BoxDecoration(
      color: Color(0xFF252525),
      border: Border(bottom: BorderSide(color: Color(0xFF3A3A3A))),
    ),
    padding: const EdgeInsets.symmetric(horizontal: 8),
    child: Row(children: children),
  );
}

/// 工具栏右侧信息区的「只读」标识（锁图标 + 文字），各代码页共用。
Widget ispTabToolbarReadOnly() {
  return const Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(Icons.lock_outline, size: 12, color: Colors.grey),
      SizedBox(width: 4),
      Text('只读', style: TextStyle(fontSize: 11, color: Colors.grey)),
    ],
  );
}

/// 标签页工具栏的图标按钮：纯图标 + tooltip（悬停显示功能名），紧凑
/// 尺寸适配 [kIspTabToolbarHeight] 行高（28px 图标，无内边距）。
Widget ispTabIconButton({
  Key? key,
  required String tooltip,
  required Widget icon,
  VoidCallback? onTap,
}) {
  return IconButton(
    key: key,
    tooltip: tooltip,
    onPressed: onTap,
    icon: icon,
    style: IconButton.styleFrom(
      padding: EdgeInsets.zero,
      minimumSize: const Size(28, 28),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
  );
}

/// codicon PNG 工具栏图标（文件已重着色为纯白，28px）；禁用态传
/// [Colors.white38] 经 srcIn 压暗。
Widget ispTabAssetIcon(String path, {Color color = Colors.white}) {
  return Image.asset(
    path,
    width: 28,
    height: 28,
    color: color,
    colorBlendMode: BlendMode.srcIn,
  );
}

/// 代码页左右分栏（文件清单 | 代码区）的竖直分隔条：视觉仍为 1px
/// 分隔线，两侧各加 3px 隐形热区，鼠标悬停变左右拖动光标，水平拖动
/// 经 [onDelta] 回调增量（右拖为正），由调用方更新左栏宽度并钳位。
class IspVerticalDragDivider extends StatelessWidget {
  final void Function(double deltaDx) onDelta;

  const IspVerticalDragDivider({super.key, required this.onDelta});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (d) => onDelta(d.delta.dx),
        child: SizedBox(
          width: 7,
          height: double.infinity,
          child: Center(
            child: Container(width: 1, color: const Color(0xFF3A3A3A)),
          ),
        ),
      ),
    );
  }
}

/// 上下面板的水平分隔条：视觉仍为 1px 横线，上下各加 3px 隐形热区，
/// 垂直拖动经 [onDelta] 回调增量（下拖为正），由调用方更新面板高度。
class IspHorizontalDragDivider extends StatelessWidget {
  final void Function(double deltaDy) onDelta;

  const IspHorizontalDragDivider({super.key, required this.onDelta});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeUpDown,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: (d) => onDelta(d.delta.dy),
        child: SizedBox(
          height: 7,
          width: double.infinity,
          child: Center(
            child: Container(height: 1, color: const Color(0xFF3A3A3A)),
          ),
        ),
      ),
    );
  }
}
