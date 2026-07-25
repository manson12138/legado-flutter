import 'package:flutter/services.dart';

/// Android 与 iOS 宿主读取实际安装包信息时共用的平台通道名称。
const String appPackageInfoPlatformChannel =
    'io.legado.flutter/app_package_info';

/// 只暴露准入缓存需要的实际安装包语义版本名。
abstract interface class AppPackageInfoService {
  /// 读取 Android versionName 或 iOS CFBundleShortVersionString。
  ///
  /// 宿主缺失、平台拒绝或返回空值时返回 null，由调用方禁止恢复旧版本准入缓存。
  Future<String?> readVersionName();
}

/// 通过项目自有原生宿主读取版本名，不引入额外 Flutter 插件和 Gradle 依赖。
final class MethodChannelAppPackageInfoService
    implements AppPackageInfoService {
  /// 创建使用固定原生通道的安装包信息服务。
  const MethodChannelAppPackageInfoService({
    MethodChannel channel = const MethodChannel(appPackageInfoPlatformChannel),
  }) : _channel = channel;

  /// Android MainActivity 与 iOS AppDelegate 共用的窄平台通道。
  final MethodChannel _channel;

  @override
  Future<String?> readVersionName() async {
    try {
      /// 宿主返回的未经信任版本名。
      final String? rawVersionName =
          await _channel.invokeMethod<String>('getVersionName');
      /// 去除平台配置中可能存在的首尾空白。
      final String versionName = rawVersionName?.trim() ?? '';
      return versionName.isEmpty ? null : versionName;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
