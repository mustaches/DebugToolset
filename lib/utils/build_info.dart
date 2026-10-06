import 'dart:io';

import 'package:flutter/foundation.dart';

/// 应用构建/开发/编译环境版本信息。
///
/// Flutter SDK 与 Dart 版本来自 flutter tool 构建时自动注入的
/// dart-define（FLUTTER_VERSION / FLUTTER_DART_VERSION 等），
/// 打包后的二进制中同样可用；编译环境（CMake 生成器，即 VS 版本）
/// 经 rebuild.bat 传入的 --dart-define=CMAKE_GENERATOR 烘焙，
/// 未烘焙时回退为开发机上运行时解析 build/windows/x64/CMakeCache.txt。
class BuildInfo {
  final String appVersion;
  final String buildNumber;
  final String flutterVersion;
  final String flutterChannel;
  final String dartVersion;
  final String frameworkRevision;
  final String engineRevision;
  final String buildMode;
  final String? cmakeGenerator;
  final String osVersion;

  const BuildInfo({
    required this.appVersion,
    required this.buildNumber,
    required this.flutterVersion,
    required this.flutterChannel,
    required this.dartVersion,
    required this.frameworkRevision,
    required this.engineRevision,
    required this.buildMode,
    required this.cmakeGenerator,
    required this.osVersion,
  });
}

/// 从 CMakeCache.txt 文本中解析 CMAKE_GENERATOR（如 "Visual Studio 18 2026"）。
/// 找不到时返回 null。
String? parseCmakeGenerator(String cmakeCacheText) {
  final match = RegExp(r'^CMAKE_GENERATOR:INTERNAL=(.*)$', multiLine: true)
      .firstMatch(cmakeCacheText);
  final value = match?.group(1)?.trim();
  return (value == null || value.isEmpty) ? null : value;
}

/// 构建时经 --dart-define=CMAKE_GENERATOR=... 烘焙进二进制的 CMake 生成器
///（rebuild.bat 调用 scripts/cmake_generator.dart 自动注入；直接
/// flutter build 时为空）。打包后的二进制中同样可用。
const String _bakedCmakeGenerator = String.fromEnvironment('CMAKE_GENERATOR');

/// 综合烘焙值与 CMakeCache 文本解析编译环境标识：烘焙值优先
///（安装版无 build/ 目录时仍可用），其次开发机上运行时读取的缓存。
String? resolveCmakeGenerator({String? baked, String? cmakeCacheText}) {
  if (baked != null && baked.isNotEmpty) return baked;
  if (cmakeCacheText == null) return null;
  return parseCmakeGenerator(cmakeCacheText);
}

/// 解析 CMake 生成器标识；构建时烘焙值优先，缺失时回退读取开发机上的
/// CMakeCache.txt，两者都没有（如手工 flutter build 的打包机器）返回 null。
Future<String?> loadCmakeGenerator() async {
  String? cacheText;
  try {
    final file = File('build/windows/x64/CMakeCache.txt');
    if (file.existsSync()) cacheText = await file.readAsString();
  } catch (_) {
    // 忽略读取失败，继续走烘焙值
  }
  return resolveCmakeGenerator(
      baked: _bakedCmakeGenerator, cmakeCacheText: cacheText);
}

String _shortRevision(String rev) =>
    rev.isEmpty ? '未知' : rev.substring(0, rev.length < 10 ? rev.length : 10);

/// 汇总全部版本信息。[appVersion] / [buildNumber] 由调用方经
/// package_info_plus 获取后传入。
Future<BuildInfo> loadBuildInfo({
  String? appVersion,
  String? buildNumber,
}) async {
  const flutterVersion = String.fromEnvironment('FLUTTER_VERSION');
  const flutterChannel = String.fromEnvironment('FLUTTER_CHANNEL');
  const dartVersion = String.fromEnvironment('FLUTTER_DART_VERSION');
  const frameworkRev = String.fromEnvironment('FLUTTER_FRAMEWORK_REVISION');
  const engineRev = String.fromEnvironment('FLUTTER_ENGINE_REVISION');

  // dart-define 缺失时退回 Dart 运行时自报的版本
  final dartVersionText =
      dartVersion.isNotEmpty ? dartVersion : Platform.version.split(' ').first;

  final String mode;
  if (kDebugMode) {
    mode = 'Debug';
  } else if (kProfileMode) {
    mode = 'Profile';
  } else {
    mode = 'Release';
  }

  return BuildInfo(
    appVersion: appVersion ?? '未知',
    buildNumber: buildNumber ?? '',
    flutterVersion: flutterVersion.isNotEmpty ? flutterVersion : '未知',
    flutterChannel: flutterChannel.isNotEmpty ? flutterChannel : '未知',
    dartVersion: dartVersionText,
    frameworkRevision: _shortRevision(frameworkRev),
    engineRevision: _shortRevision(engineRev),
    buildMode: mode,
    cmakeGenerator: await loadCmakeGenerator(),
    osVersion: Platform.operatingSystemVersion,
  );
}
