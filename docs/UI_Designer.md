# UI 设计器模块说明

侧栏第 6 个模块（图标 `Icons.dashboard_customize`）。嵌入式 UI 设计器：
拖控件设计页面 → 工具内预览交互 → 导出 C 代码（含运行时与弱符号回调接口）。

## 功能闭环

1. **设计**：左侧控件箱（16 种控件，含滚动列表与 OSD 控件）点击加入页面；画布支持拖动、8 向缩放、
   框选/Ctrl 多选、方向键微调（Shift = 网格步进）、右键菜单（复制/粘贴/置顶/置底/删除）、
   网格吸附、缩放（适配窗口/50%~400%）。
2. **页面**：左下页面列表管理多页面；空选时右侧面板编辑屏幕分辨率、页面背景、
   页面事件（onShow/onHide/onTimer，onTimer 需填周期毫秒）。
   页面背景三种：**纯色** / **图片**（屏幕尺寸图片资源，导出时内嵌为 C 数组并
   拉伸绘制）/ **视频**（设计器内显示占位提示；固件侧运行时不清背景，OSD 直接
   叠加在实时视频流上，对应 `ui_page_t.bg_type` 0/1/2）。
3. **事件**：控件支持 onClick（仅单击）、onFocus（鼠标激活焦点）、onValueChange；
   动作二选一：调用回调（C 函数名，留空自动生成 `ui_cb_<控件名>_<事件>`）或跳转页面。
4. **预览**：顶栏「预览」进入模拟模式，支持方向键焦点导航 + OK 激活（见
   「按键焦点导航」），也可鼠标点击/拖动滑块/翻页，右侧面板显示回调日志。
   滚动列表在预览中是真实的惯性滚动列表：拖拽滚动、松手吸附到最近项、点击直接选中，
   选中变化触发 onValueChange。
5. **导出**：「导出代码」生成 7 个 C 文件（见下），C99、无动态分配。
6. **工具**：顶栏「图片转换」（PNG/JPG → C 数组 / bin / 工程资源，RGB565/RGB888/
   ARGB8888/灰度/1bpp，行/列扫描）；「图像提取」（bin 按偏移/宽高/行距/像素格式
   实时解析预览，可导出 PNG 或存为工程资源）。

### 滚动列表（scrolllist）

垂直或水平滚动的选项列表（如模拟器类型、游戏列表）。属性：方向、选项（逗号分隔）、
项尺寸、间距、选中项、字号、文字/选中颜色。事件：onValueChange。
固件侧运行时为「居中窗口」绘制：选中项始终居中，触摸某一项即选中并触发回调；
真正的惯性滚动是工具内预览效果，固件如需滚动动画可在 port 层自行扩展。

### OSD 控件（menu / value_item / option_item）

面向视频流叠加菜单（遥控器方向键 + OK）的三件套：

- **menu 菜单列表**：垂直菜单，高亮条随方向键上下移动（`wrap` 属性控制循环），
  OK 触发 onClick，高亮移动触发 onValueChange。属性：选项、选中项、项高度、字号、
  文字/高亮颜色、循环。
- **value_item 数值项**：左标签右数值（如 `曝光  50`），左右键按 `step` 调值并
  钳制到 `[min, max]`，触发 onValueChange。
- **option_item 选项项**：左标签右 `<选项>`（如 `白平衡 <自动>`），左右键循环切换，
  触发 onValueChange。

### 按键焦点导航（预览与固件运行时一致）

- 预览模式下：方向键移动焦点（空间最近邻，边界环绕）、Enter/Space = OK、Esc 清除焦点；
  menu 聚焦时上下键移动高亮，value_item/option_item/slider 聚焦时左右键调值；
  鼠标点击仍可聚焦+激活（辅助）。纯显示控件（线条/进度条）不可聚焦。
- 固件运行时新增 `ui_key(ui_key_t key)`（`UI_KEY_UP/DOWN/LEFT/RIGHT/OK`）与
  `ui_focused_widget()`，导航算法与设计器一致；焦点控件绘制青色高亮框。
  按键中断里调 `ui_key(...)` 即可，触摸接口 `ui_touch_*` 保留并存。

### GPU 特效（Mali 等 2D/3D 加速，平台无关 + port 钩子）

- **页面切换特效**：gotoPage 事件可选 无/左滑入/右滑入/淡入淡出/推入覆盖/立方体翻转，
  预览中实时演示；运行时经弱钩子 `ui_port_page_transition(from, to, type)` 交给
  port 层用 GPU 实现，默认瞬时切换。
- **控件变换**：每个控件通用 旋转°/缩放%/不透明% 属性（属性面板「变换」区）；
  运行时对非恒等变换的控件调用弱钩子 `ui_port_begin/end_transform` 包裹绘制。
- **微动效**：进度条斜条流动（运行时由 `ui_tick` 驱动重绘）、按钮按下缩放回弹
  （运行时经变换钩子 scale 92%）、菜单高亮滑动（预览效果，固件瞬时）。
- **背景动画**：图片背景可选 Ken Burns 缓推 / 视差滚动；运行时经弱钩子
  `ui_port_bg_anim_frame(page, anim, ms)` 逐帧交给 port 层，默认静态绘制。

## 工程文件

工程保存为 `.uiproj`（JSON）。图片资源保存时复制到 `<工程名>_assets/` 并在
JSON 中记相对路径。撤销/重做为 JSON 快照，栈深 50。

## 代码结构

```
lib/modules/ui_designer/
├── ui_designer_view.dart   # 主视图（顶栏/三栏/底栏/回调日志）
├── models/                 # UiProject/UiPage/UiWidgetModel/UiEvent/WidgetRegistry/序列化
├── editor/                 # canvas_view / widget_palette / page_list_panel / property_panel / widget_renderer
├── codegen/                # c_code_exporter / c_project_codegen / c_runtime_codegen / c_callbacks_codegen
└── tools/                  # pixel_formats / image_converter_dialog / raw_image_dialog
lib/providers/ui_designer_state.dart  # 模块状态（Provider）
```

新增控件类型只需在 `models/widget_registry.dart` 注册表加一项
（属性 schema 驱动属性面板），并在 `editor/widget_renderer.dart` 与
`codegen/` 中补对应渲染与映射。

## 导出的 C 代码

| 文件 | 内容 |
|------|------|
| `ui_pages.h/c` | 页面/控件常量表、`UI_SCREEN_WIDTH/HEIGHT`、`UI_START_PAGE`、内嵌图片数据 |
| `ui_runtime.h/c` | 平台无关运行时：`ui_init/ui_set_page/ui_draw/ui_touch_*/ui_key/ui_focused_widget/ui_tick/ui_get/set_widget_value` |
| `ui_port.h` | 移植层接口：`ui_port_fill_rect/draw_text/draw_image/millis`，需在固件中实现 |
| `ui_callbacks.h/c` | 每个回调的 `__weak` 空实现；用户在自己文件里定义同名函数即绑定。`ui_callbacks.c` 已存在时不覆盖 |

固件集成：实现 `ui_port_*` → `ui_init(UI_START_PAGE)` → 触摸中断里调
`ui_touch_down/move/up`（或按键中断里调 `ui_key`）→ 周期调 `ui_tick(elapsed_ms)`
→ 需要刷新时调 `ui_draw()`。

颜色均为 RGB565。`ui_props_t` 为通用属性结构，各字段含义见
`ui_runtime.h` 注释（如 button 的 `border_color` 复用为文字颜色）。

## 测试

- `test/ui_designer_test.dart`：序列化回环、注册表完整性、代码生成、像素格式转换。
- `test/ui_osd_widgets_test.dart`：OSD 控件注册表/渲染冒烟、预览按键导航
  （焦点移动/环绕、menu 高亮循环、调值钳制、OK 激活）、C 代码生成映射。
- `test/ui_codegen_dump_test.dart`：把示例工程的 C 代码导出到 `scratch/gen_c/` 供检查。
- `test/ui_sample_psp_project_test.dart`：生成 PSP 风格模拟器 UI 样例工程
  （`UI_Project/psp_emulator.uiproj`，480x282，垂直滚动列表选模拟器 +
  水平滚动列表选游戏），并把导出的 C 代码写到 `UI_Project/exported_c/`。
