@echo off
rem Compile+link generated C files into an exe (blackbox A/B comparison harness).
rem Same manual MSVC environment as c_build_harness.bat (vcvars64.bat is broken
rem on this machine), additionally setting LIB for linking.
rem usage: c_link_check.bat <out.exe> <file1.c> [file2.c ...]
rem   (paths Windows-style; .obj intermediates go to %TEMP%\isp_bb_objs_<exename>)
setlocal
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
set "OBJDIR=%TEMP%\isp_bb_objs_%~n1"
if not exist "%OBJDIR%" mkdir "%OBJDIR%"
set "OUT=%~1"
set "FILES="
:loop
if "%~2"=="" goto done
set "FILES=%FILES% "%~2""
shift
goto loop
:done
cl /nologo /O2 /utf-8 %FILES% /Fo"%OBJDIR%\\" /Fe"%OUT%"
if errorlevel 1 (
  echo BUILD_FAILED
  exit /b 1
)
echo BUILD_OK %OUT%
