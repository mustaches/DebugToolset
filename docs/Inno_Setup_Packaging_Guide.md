# DebugToolSet Inno Setup 打包配置指南

针对 `DebugToolSet` 工程，本文档详细说明了使用 Inno Setup Script Wizard（脚本向导）进行配置的过程，并重点说明了如何正确添加工程根目录下的几个特殊配置文件夹。

## 准备工作
在开始配置之前，确保您已经将项目代码打包生成了一个主执行文件，例如 `DebugToolSet.exe`。

---

## 第一步：启动向导与基础信息
1. 打开 **Inno Setup Compiler** 软件。
2. 点击菜单栏 `File` -> `New`。
3. 勾选 **Create a new script file using the Script Wizard**（使用脚本向导创建新脚本），然后点击 **OK**。
4. **Application Information（应用信息）**:
   - **Application name**: 填写 `DebugToolSet`
   - **Application version**: 填写 `1.0`（或当前实际版本号）
   - **Application publisher**: （可选）填写您的名称或公司名
   - **Application website**: （可选）
   - 点击 **Next**。

5. **Application Folder（安装目录）**:
   - **Application destination base folder**: 保持默认的 `Program Files folder`
   - **Application folder name**: 保持默认的 `DebugToolSet`
   - 点击 **Next**。

---

## 第二步：添加主程序与关键文件夹（核心配置）
这是最关键的一步，确保主程序和 6 个特殊文件夹被正确打包。

1. **Application main executable file (主执行文件)**:
   - 点击 `Browse...`，找到并选择您编译好的主程序文件（例如 `G:\DebugToolSet\build\windows\runner\Release\DebugToolSet.exe` 或 `dist\DebugToolSet\DebugToolSet.exe`）。

2. **Other application files (其他文件/文件夹)**:
   - 这里需要将您指定的文件夹逐个添加进来。**请严格按照以下操作进行：**
   - 点击 **`Add folder...`** 按钮，在弹出的窗口中定位到 `G:\DebugToolSet\`，选中 `bussetup` 文件夹，点击确定。
   - 此时 Inno Setup 会弹窗询问："Should files in subdirectories of 'G:\DebugToolSet\bussetup' also be included?"（是否包含子目录中的文件？），**务必点击“是 (Yes)”**。
   - 重复点击 `Add folder...` 的操作，依次将剩下的 5 个文件夹添加进来：
     - `G:\DebugToolSet\DeviceProtocol`
     - `G:\DebugToolSet\docs`
     - `G:\DebugToolSet\Memorydump`
     - `G:\DebugToolSet\sequence`
     - `G:\DebugToolSet\waveform`

   > **⚠️ 关键修改说明**：
   > 在向导列表里，添加完文件夹后，它们的 `Destination` 默认会被放在 `{app}` 根目录，文件会被打散。
   > **请在此界面的列表中，双击刚刚添加的这几个文件夹条目**（或者选中后点 Edit），在弹出的编辑窗口中，将 **Destination subfolder** 分别修改为对应的文件夹名称，以保留文件目录结构：
   > - `bussetup` 的条目，Destination subfolder 填入 `bussetup`
   > - `DeviceProtocol` 的条目，Destination subfolder 填入 `DeviceProtocol`
   > - `docs` 的条目，Destination subfolder 填入 `docs`
   > - `Memorydump` 的条目，Destination subfolder 填入 `Memorydump`
   > - `sequence` 的条目，Destination subfolder 填入 `sequence`
   > - `waveform` 的条目，Destination subfolder 填入 `waveform`

3. 点击 **Next**。

---

## 第三步：快捷方式与其他设置
1. **Application Icons（快捷方式）**:
   - 勾选 `Allow user to create a desktop shortcut`（允许创建桌面快捷方式）。
   - 点击 **Next**。
2. **Application Documentation（文档）**:
   - 如果您有如 `readme.txt` 或许可协议，可以在这里指定，没有就直接留空点 **Next**。
3. **Setup Languages（语言）**:
   - 勾选您需要的安装语言，比如 `English` 和 `Chinese Simplified`。点击 **Next**。
4. **Compiler Settings（输出设置）**:
   - **Custom compiler output folder**: 点击 `Browse`，选择一个存放最终 `.exe` 安装包的目录，例如桌面的 `Output` 文件夹。
   - **Compiler output base file name**: 填写最终安装包的名称，例如 `DebugToolSet_Installer_v1.0`。
   - **Custom Setup icon file**: 如果您有程序的 `.ico` 图标，可以在这里选择作为安装包的图标。
   - 点击 **Next**。
5. **Inno Setup Preprocessor**: 保持勾选，点击 **Next**，然后点击 **Finish**。

---

## 第四步：核对与调整生成的代码
向导结束后，会询问是否立即编译，请点击 **否 (No)**。我们需要检查一下生成的 `.iss` 脚本。

在脚本中向下滚动，找到 **`[Files]`** 段落。请核对这一段，重点注意 `DestDir: "{app}\文件夹名"` 这一部分是否正确。它应该是类似下面这样：

```pascal
[Files]
; 这是您的主程序 (路径取决于您之前选择的实际exe路径)
Source: "G:\DebugToolSet\您的打包路径\DebugToolSet.exe"; DestDir: "{app}"; Flags: ignoreversion

; 以下是您添加的 6 个文件夹
; 注意 DestDir 后面的路径必须带有对应的子文件夹名称，否则文件会全部散落到根目录
Source: "G:\DebugToolSet\bussetup\*"; DestDir: "{app}\bussetup"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "G:\DebugToolSet\DeviceProtocol\*"; DestDir: "{app}\DeviceProtocol"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "G:\DebugToolSet\docs\*"; DestDir: "{app}\docs"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "G:\DebugToolSet\Memorydump\*"; DestDir: "{app}\Memorydump"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "G:\DebugToolSet\sequence\*"; DestDir: "{app}\sequence"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "G:\DebugToolSet\waveform\*"; DestDir: "{app}\waveform"; Flags: ignoreversion recursesubdirs createallsubdirs
```

> **补充检查项**：
> 如果主程序所在目录（例如 `dist\DebugToolSet\`）里还有其他 `.dll` 或依赖文件，记得在 `[Files]` 段落里把它们也加上：
> `Source: "G:\DebugToolSet\您的打包路径\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs`
> （注意排除不需要打包的源码文件）。

---

## 第五步：保存并编译
1. 按 `Ctrl + S` 将这个生成的 `.iss` 脚本文件保存在工程根目录（例如 `G:\DebugToolSet\installer_script.iss`），方便以后更新。
2. 点击顶部工具栏绿色的 **Run（运行）** 按钮，或者按 `Ctrl + F9` 进行编译。
3. Inno Setup 会将执行文件及那 6 个特殊文件夹打包压缩。完成后，您就可以在之前设置的 Output 目录里找到安装包了。
