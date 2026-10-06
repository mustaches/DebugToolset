@echo off
rem NOTE: keep this file pure ASCII. Non-ASCII (UTF-8 Chinese) batch files
rem are parsed unreliably by cmd.exe even with chcp 65001.
chcp 65001 >nul
rem DebugToolSet one-click packaging:
rem   stage 1 - release build via rebuild.bat
rem   stage 2 - Inno Setup compile (Windows_setup\DebugToolSet.iss)
rem Installer output: Windows_setup\Output\

set "ISCC=C:\Program Files\Inno Setup 7\ISCC.exe"
set "ISS=G:\DebugToolSet\Windows_setup\DebugToolSet.iss"

rem flutter clean deletes build/, which fails while the app is running
tasklist /FI "IMAGENAME eq debug_tool_set.exe" /NH | findstr /I "debug_tool_set" >nul
if %errorlevel% equ 0 (
    echo ERROR: debug_tool_set.exe is running. Close it before packaging.
    pause
    exit /b 1
)

if not exist "%ISCC%" (
    echo ERROR: Inno Setup compiler not found: %ISCC%
    pause
    exit /b 1
)

echo ========================================
echo  Stage 1/2: Flutter release build
echo ========================================
call "%~dp0rebuild.bat" nopause
if %errorlevel% neq 0 (
    echo ERROR: Flutter build failed, packaging aborted.
    pause
    exit /b 1
)

echo.
echo ========================================
echo  Stage 2/2: Inno Setup compile
echo ========================================
"%ISCC%" "%ISS%"
if %errorlevel% neq 0 (
    echo ERROR: Inno Setup compile failed
    pause
    exit /b 1
)

echo.
echo Packaging finished! Installer is in Windows_setup\Output\
pause
