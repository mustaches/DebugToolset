# DebugToolSet 安装说明

本文档介绍 DebugToolSet 在 **Windows** 与 **Ubuntu** 上的安装与卸载方法。

安装包获取途径：

- GitHub 仓库 [Releases 页面](https://github.com/mustaches/DebugToolset/releases)下载（如有发布）；
- 或自行从源码构建，见文末「从源码构建」。

---

## Windows

### 系统要求

- Windows 10 / 11（64 位）
- 串口功能需要本机有可用串口设备；网络终端/LXI 功能需要网络连接

### 安装步骤

1. 双击运行 `DebugToolset_setup.exe`（Inno Setup 安装包）。
2. 按向导选择安装目录（默认 `C:\Program Files\DebugToolSet`），一路下一步完成安装。
3. 安装包会同时部署程序运行所需的数据目录（`bussetup/`、`DeviceProtocol/`、`docs/`、`waveform/`、`tools/ffmpeg/`），无需额外配置。
4. 从开始菜单或桌面快捷方式启动 **DebugToolSet**。

详细的打包/安装向导说明见 [Inno_Setup_Packaging_Guide.md](Inno_Setup_Packaging_Guide.md)。

### 卸载

通过「设置 → 应用 → 已安装的应用」找到 DebugToolSet 卸载，或运行安装目录下的 `unins000.exe`。

---

## Ubuntu（.deb 安装包）

### 系统要求

- Ubuntu 22.04 / 24.04（64 位，amd64），其他使用 dpkg 的发行版（Debian 12+ 等）一般也可用
- 桌面环境（GNOME 等）；WSL2 用户需要 WSLg（Windows 11 或最新版 WSL 自带）

### 安装步骤

```bash
sudo apt install ./debug-tool-set_1.0.0_amd64.deb
```

用 `apt` 安装（而不是 `dpkg -i`）会自动补齐全部依赖，包括：

- GTK3 等图形运行库（`libgtk-3-0t64`、`libepoxy0` 等，共 60 余项，由包内 `Depends` 自动声明）；
- `ffmpeg` —— ISP Studio 的视频源解码与 MP4 导出依赖；
- `fonts-noto-cjk` —— 中文字体。**缺少它界面中文会显示为方框**，务必随包装好。

### 启动

- 在应用菜单中搜索 **DebugToolSet** 点击启动；或终端执行：

```bash
debug-tool-set
```

首次启动时，启动器会把数据目录（`bussetup/`、`DeviceProtocol/`、`docs/`、`waveform/`、`IspFlow/`、`UI_Project/`）复制到 `~/.local/share/debug_tool_set/` 并以其为工作目录运行——应用按工作目录相对路径访问这些数据，而安装目录 `/opt` 对普通用户不可写。之后对波形、ISP 流程、UI 工程的保存都发生在该用户目录下。

程序本体位于 `/opt/debug_tool_set/`，如需重置用户数据，删除 `~/.local/share/debug_tool_set/` 后重新启动即可（会重新从安装目录复制初始数据）。

### 卸载

```bash
sudo apt remove debug-tool-set
```

卸载不会删除 `~/.local/share/debug_tool_set/` 下的用户数据，需要时手动删除。

### WSL2 注意事项

- 需要 WSLg 提供图形显示（`wsl --version` 确认 WSLg 存在）；渲染警告（EGL/ZINK）不影响使用。
- 若 WSL 内完全无网络，检查 `~/.wslconfig` 的 `networkingMode`：`mirrored` 模式在部分环境会失效导致网卡不出现，改回 `NAT` 后 `wsl --shutdown` 重启即可。
- 串口设备在 WSL2 默认不可见，需要用 usbipd 透传 USB 串口。

---

## 从源码构建（开发者）

### 通用准备

```bash
git clone https://github.com/mustaches/DebugToolset.git
cd DebugToolset
flutter pub get
```

要求 Flutter stable（Dart `^3.12.2`）。**必须从工程根目录启动应用**，因为程序按 `Directory.current` 相对路径访问 `DeviceProtocol/`、`bussetup/` 等数据目录。

### Windows

```bash
flutter run -d windows            # 调试运行
flutter build windows --release   # 产出 build/windows/x64/runner/Release/
```

打包安装包：用 Inno Setup 编译 `Windows_setup/DebugToolSet.iss`，输出到 `Windows_setup/Output/`。

### Ubuntu / Linux

```bash
# 编译依赖（Ubuntu 24.04）
sudo apt install -y clang cmake ninja-build pkg-config libgtk-3-dev \
  liblzma-dev libstdc++-12-dev ffmpeg fonts-noto-cjk

flutter run -d linux              # 调试运行
flutter build linux --release     # 产出 build/linux/x64/release/bundle/
bash Linux_setup/build_deb.sh     # 打包 .deb 到 Linux_setup/Output/
```

---

## 发布新版本（维护者）

完整的发版流程如下（版本号以 `pubspec.yaml` 的 `version:` 为准，发版前先更新它）：

1. **构建 Windows 安装包**

   ```bash
   flutter build windows --release
   # 用 Inno Setup 编译 Windows_setup/DebugToolSet.iss
   # 产出 Windows_setup/Output/DebugToolset_setup.exe
   ```

2. **构建 Ubuntu 安装包**（在 WSL 或 Ubuntu 机器上）

   ```bash
   flutter build linux --release
   bash Linux_setup/build_deb.sh
   # 产出 Linux_setup/Output/debug-tool-set_<版本>_amd64.deb
   ```

3. **提交代码并打标签**

   ```bash
   git add -A && git commit -m "chore(release): v<版本>"
   git push origin main
   ```

4. **创建 GitHub Release 并上传安装包**

   有 `gh` CLI 时最简单（需 `repo` 权限的登录）：

   ```bash
   gh release create v<版本> \
     Windows_setup/Output/DebugToolset_setup.exe \
     Linux_setup/Output/debug-tool-set_<版本>_amd64.deb \
     --title "DebugToolSet v<版本>" --notes "版本说明……"
   ```

   没有 `gh` 时走 REST API（`<TOKEN>` 为有 `repo` scope 的 token；本机已用 git 凭据管理器登录过 GitHub 的话，可用
   `printf 'protocol=https\nhost=github.com\n\n' | git credential fill` 取出）：

   ```bash
   # 创建 Release，记下返回的 id
   curl -s -X POST -H "Authorization: token <TOKEN>" \
     https://api.github.com/repos/mustaches/DebugToolset/releases \
     -d '{"tag_name":"v<版本>","name":"DebugToolSet v<版本>","body":"版本说明……"}'

   # 逐个上传资产（URL 中是上一步的 Release id）
   curl -s -X POST -H "Authorization: token <TOKEN>" \
     -H "Content-Type: application/octet-stream" \
     --data-binary @<安装包路径> \
     "https://uploads.github.com/repos/mustaches/DebugToolset/releases/<id>/assets?name=<文件名>"
   ```

注意：安装包体积较大（约 70~100M），**不要**提交进 git 仓库（`Linux_setup/Output/` 已在 `.gitignore` 中），只作为 Release 资产分发。
