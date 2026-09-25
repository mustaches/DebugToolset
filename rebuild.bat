@echo off
chcp 65001 >nul
echo 开始 Flutter 构建流程...

echo [1/4] 正在执行 flutter clean...
call flutter clean
if %errorlevel% neq 0 (
    echo 错误：flutter clean 执行失败
    pause
    exit /b 1
)

echo [2/4] 正在执行 flutter pub get...
call flutter pub get
if %errorlevel% neq 0 (
    echo 错误：flutter pub get 执行失败
    pause
    exit /b 1
)

echo [3/4] 正在执行 flutter build windows --release...
call flutter build windows --release
if %errorlevel% neq 0 (
    echo 错误：flutter build windows 执行失败
    pause
    exit /b 1
)

echo [4/4] 正在递增构建号...
call dart scripts/bump_build_number.dart
if %errorlevel% neq 0 (
    echo 警告：构建号递增失败（不影响本次构建产物）
)

echo.
echo 构建完成！
pause
