# 安装版「编译 / 运行验证」卡死问题修复说明

## 问题现象

项目经 Inno Setup 打包安装后（默认安装到 `C:\Program Files\DebugToolSet\`），
在 ISP Studio 编组/节点代码页点「编译」（或「运行验证（原尺寸/scale）」），
界面停留在「编译中…」状态不再变化，终端面板一片空白，只能重启应用。

开发环境（`flutter run` / 工程根目录直接运行）一切正常，问题仅在安装版出现。

## 根因分析

### 1. 直接机制：异常未捕获，状态永远不复位

`lib/modules/isp_studio/widgets/code_browser.dart` 的 `_startCompile` 与
`_startWinVerify` 对 `filesLoader()` / `builder()` / `runner()` 的 `await`
**没有 try/catch/finally**。任何一步抛异常，`_compiling` 标志永远保持
`true`——按钮持续禁用并显示「编译中…」、终端面板空白，观感即「卡死」。
开发环境不触发异常，所以该缺陷长期未暴露。

### 2. 安装版特有的两个异常抛点

**抛点 A：`isp_csc_common.h` 磁盘读取（普通「编译」按钮，HSL 端口编组必中）**

- `group_code_page.dart` 的编译 `filesLoader`：编组外部输入/输出为 HSL 且
  文件集缺 `isp_csc_common.h` 时，从
  `${Directory.current}/lib/modules/isp_studio/c_ref/isp_csc_common.h` **读盘**。
- `c_compile.dart` 的 `buildWinVerifyApp` 内有同样一处读盘。

c_ref 源码是以 **Flutter asset**（rootBundle）形式打包的（见
`pubspec.yaml` 的 assets 声明与 `node_c_code.dart` 的 `loadCRefFile`），
Inno 安装包**不含 `lib/` 目录**——安装版该磁盘路径不存在，
`readAsString` 抛 `FileSystemException`。

**抛点 B：产物目录不可写（「运行验证」按钮，普通用户必中）**

`buildWinVerifyApp` 把产物目录固定写到
`${Directory.current}/scratch/cc_win_check`。Inno 快捷方式未设 WorkingDir，
默认 `{app}`（即 `C:\Program Files\DebugToolSet\`），标准用户**不可写**，
`Directory.create()` 抛 `FileSystemException`。

### 3. 为什么不怀疑其他路径

- 普通「编译」的临时目录走 `Directory.systemTemp`（用户临时目录），安装版可写；
- 目标机未装 MSVC 不会卡：对话框/编译函数均有「未检测到」的明示路径；
- 「Linux 交叉」目标的 WSL 探测最长 ~75 秒但有进度文案，属设计行为；
- 杀软首扫 cl.exe 只会变慢（终端有「临时目录：…」输出），不会终端全白。

## 修复内容（三处）

### 修复 1：异常兜底（`code_browser.dart`）

`_startCompile` / `_startWinVerify` 包 try/catch：生成/编译过程任何异常
写入终端面板（「编译过程出错：…」/「构建过程出错：…」）并复位
`_compiling`。这是兜底——此后任何失败都会显示错误文本而不是卡死。

### 修复 2：`isp_csc_common.h` 改走资产包（`group_code_page.dart`、`c_compile.dart`）

- 编译 `filesLoader`：磁盘读取改为
  `await loadCRefFile('isp_csc_common.h')`（rootBundle，开发/安装一致）；
- `buildWinVerifyApp` 新增可选参数 `cscCommonHeader`，由调用方
  （`group_code_page.dart` 的 `_buildAndRunWinVerify`）经 rootBundle
  注入——`c_compile.dart` 是纯 Dart（不依赖 Flutter），不能直接使用
  rootBundle；参数缺省时保留磁盘回退（测试/开发环境行为不变）。

### 修复 3：「运行验证」产物目录可写性回退（`c_compile.dart`）

`buildWinVerifyApp` 仍优先使用 `工作目录/scratch/cc_win_check`（开发机
行为不变）；创建抛 `FileSystemException` 时（安装到 Program Files 后
普通用户运行）自动回退到 `%LOCALAPPDATA%\DebugToolSet\cc_win_check\`
（无 LOCALAPPDATA 再用系统临时目录），并在终端面板打印实际产物路径。
「固定产物目录、可双击运行」的语义保留；目录被运行中的验证程序占用时
改用时间戳备用目录的原有行为也保留。

## 涉及文件

| 文件 | 改动 |
|---|---|
| `lib/modules/isp_studio/widgets/code_browser.dart` | `_startCompile`/`_startWinVerify` 加 try/catch 兜底 |
| `lib/modules/isp_studio/widgets/group_code_page.dart` | `filesLoader` 与 `_buildAndRunWinVerify` 的 csc 头改经 `loadCRefFile`（rootBundle）注入 |
| `lib/modules/isp_studio/codegen/c_compile.dart` | `buildWinVerifyApp` 新增 `cscCommonHeader` 参数；产物目录不可写时回退 `%LOCALAPPDATA%\DebugToolSet\cc_win_check\` |
| `AGENTS.md` | 「运行验证」产物目录描述同步更新 |

## 验证

- `flutter analyze`（改动文件）：通过（仅 1 条与本次无关的既有 info 提示）；
- `flutter test test/isp_c_compile_test.dart test/isp_group_code_page_test.dart test/isp_node_code_page_test.dart`：42/42 通过；
- `flutter test test/isp_group_c_export_test.dart`：26/26 通过（含
  `buildWinVerifyApp` 的 MSVC 实机构建 + 批模式哈希对拍集成用例）；
- 安装版人工验证要点：
  1. HSL 端口编组（如多段色彩均衡器单节点编组）点「编译」——原必中路径；
  2. 「运行验证」构建成功后终端面板应显示
     `%LOCALAPPDATA%\DebugToolSet\cc_win_check\...` 产物路径；
  3. 若仍异常，终端面板必留有错误文本（修复 1 的兜底），据此进一步排查。
