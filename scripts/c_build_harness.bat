@echo off
rem Build the Dart<->C comparison harness (test/c_ref) + all c_ref kernels.
rem Same manual MSVC environment as c_syntax_check.bat (vcvars64.bat is broken
rem on this machine), additionally setting LIB for linking.
rem Output exe: scratch\c_ref_check\c_ref_harness[tag].exe
rem usage: c_build_harness.bat [tag]   (run from the project root)
rem   tag: optional suffix for parallel per-group builds, e.g. "_grp_unpack"
rem   produces c_ref_harness_grp_unpack.exe with objects in temp\objs_grp_unpack.
setlocal
set "TAG=%~1"
set "VSROOT=C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC"
if not exist "%VSROOT%" set "VSROOT=C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\VC\Tools\MSVC"
set "MSVC="
for /d %%i in ("%VSROOT%\*") do set "MSVC=%%i"
if not defined MSVC (
  echo MSVC_NOT_FOUND
  exit /b 1
)
set "SDKINC=C:\Program Files (x86)\Windows Kits\10\Include"
set "SDKLIB=C:\Program Files (x86)\Windows Kits\10\Lib"
set "SDKVER="
for /d %%i in ("%SDKINC%\*") do set "SDKVER=%%~nxi"
if not defined SDKVER (
  echo WINSDK_NOT_FOUND
  exit /b 1
)
set "PATH=%MSVC%\bin\Hostx64\x64;%PATH%"
set "INCLUDE=%MSVC%\include;%SDKINC%\%SDKVER%\ucrt;%SDKINC%\%SDKVER%\um;%SDKINC%\%SDKVER%\shared"
set "LIB=%MSVC%\lib\x64;%SDKLIB%\%SDKVER%\ucrt\x64;%SDKLIB%\%SDKVER%\um\x64"
if not exist temp\objs%TAG% mkdir temp\objs%TAG%
if not exist scratch\c_ref_check mkdir scratch\c_ref_check
cl /nologo /O2 /utf-8 /I lib\modules\isp_studio\c_ref /I test\c_ref lib\modules\isp_studio\c_ref\*.c test\c_ref\*.c /Fe:scratch\c_ref_check\c_ref_harness%TAG%.exe /Fotemp\objs%TAG%\
if errorlevel 1 (
  echo BUILD_FAILED
  exit /b 1
)
if not exist scratch\c_ref_check\c_ref_harness%TAG%.exe (
  echo BUILD_FAILED_NO_EXE
  exit /b 1
)
echo BUILD_OK scratch\c_ref_check\c_ref_harness%TAG%.exe
