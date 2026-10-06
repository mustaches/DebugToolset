@echo off
rem Parallel MSBuild for the native compile phase (maps to MSBuild /m)
set "CMAKE_BUILD_PARALLEL_LEVEL=8"
flutter run --release
