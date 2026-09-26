@echo off
rem C syntax check wrapper for the ISP C reference implementations.
rem The machine's vcvars64.bat is broken, so INCLUDE/PATH are set manually.
rem usage: c_syntax_check.bat file1.c [file2.c ...]   (Windows-style paths)
setlocal
rem MSVC 探测：vswhere（版本无关，VS2026 的 "18" 目录也可定位）→
rem 目录枚举兜底（任意年份/SKU）→ 历史硬编码根。
set "VSROOT="
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if exist "%VSWHERE%" (
  for /f "usebackq delims=" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do (
    if exist "%%i\VC\Tools\MSVC" set "VSROOT=%%i\VC\Tools\MSVC"
  )
)
if not defined VSROOT (
  for /d %%y in ("C:\Program Files\Microsoft Visual Studio\*") do (
    for /d %%e in ("%%y\*") do (
      if exist "%%e\VC\Tools\MSVC" set "VSROOT=%%e\VC\Tools\MSVC"
    )
  )
)
if not defined VSROOT (
  for /d %%y in ("C:\Program Files (x86)\Microsoft Visual Studio\*") do (
    for /d %%e in ("%%y\*") do (
      if exist "%%e\VC\Tools\MSVC" set "VSROOT=%%e\VC\Tools\MSVC"
    )
  )
)
if not defined VSROOT set "VSROOT=C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC"
if not exist "%VSROOT%" set "VSROOT=C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\VC\Tools\MSVC"
set "MSVC="
for /d %%i in ("%VSROOT%\*") do set "MSVC=%%i"
if not defined MSVC (
  echo MSVC_NOT_FOUND
  exit /b 1
)
set "SDKROOT=C:\Program Files (x86)\Windows Kits\10\Include"
set "SDKVER="
for /d %%i in ("%SDKROOT%\*") do set "SDKVER=%%~nxi"
if not defined SDKVER (
  echo WINSDK_NOT_FOUND
  exit /b 1
)
set "PATH=%MSVC%\bin\Hostx64\x64;%PATH%"
set "INCLUDE=%MSVC%\include;%SDKROOT%\%SDKVER%\ucrt;%SDKROOT%\%SDKVER%\um;%SDKROOT%\%SDKVER%\shared"
cl /nologo /Zs /I lib\modules\isp_studio\c_ref %*
