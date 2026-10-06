@echo off
rem NOTE: keep this file pure ASCII. Non-ASCII (UTF-8 Chinese) batch files
rem are parsed unreliably by cmd.exe even with chcp 65001.
chcp 65001 >nul
echo Starting Flutter build flow...

echo [1/4] flutter clean ...
call flutter clean
if %errorlevel% neq 0 (
    echo ERROR: flutter clean failed
    if not "%1"=="nopause" pause
    exit /b 1
)

echo [2/4] flutter pub get ...
call flutter pub get
if %errorlevel% neq 0 (
    echo ERROR: flutter pub get failed
    if not "%1"=="nopause" pause
    exit /b 1
)

echo [3/4] flutter build windows --release ...
rem Detect the CMake generator and bake it into the binary via dart-define,
rem so the installed app's About dialog can still show the build toolchain.
rem Parallel MSBuild: flutter tool calls "cmake --build" without --parallel;
rem this env var maps to MSBuild /m (project-level parallelism for wrapper/plugins).
rem The ~65s Dart AOT phase (kernel snapshot + gen_snapshot) is single-threaded
rem and cannot be accelerated this way. Measured: 113s -> 92s on a 112-core box.
set "CMAKE_BUILD_PARALLEL_LEVEL=8"
set "CMAKE_GEN="
for /f "usebackq delims=" %%G in (`dart scripts/cmake_generator.dart`) do set "CMAKE_GEN=%%G"
if defined CMAKE_GEN (
    echo Detected CMake generator: %CMAKE_GEN%
    call flutter build windows --release "--dart-define=CMAKE_GENERATOR=%CMAKE_GEN%"
) else (
    call flutter build windows --release
)
if %errorlevel% neq 0 (
    echo ERROR: flutter build windows failed
    if not "%1"=="nopause" pause
    exit /b 1
)

echo [4/4] bumping build number ...
call dart scripts/bump_build_number.dart
if %errorlevel% neq 0 (
    echo WARNING: failed to bump build number ^(build artifacts are unaffected^)
)

echo.
echo Build finished!
if not "%1"=="nopause" pause
