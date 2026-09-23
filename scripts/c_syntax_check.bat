@echo off
rem C syntax check wrapper for the ISP C reference implementations.
rem The machine's vcvars64.bat is broken, so INCLUDE/PATH are set manually.
rem usage: c_syntax_check.bat file1.c [file2.c ...]   (Windows-style paths)
setlocal
set "VSROOT=C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC"
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
