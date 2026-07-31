import 'package:flutter/services.dart';

/// Android 与 iOS 宿主读取实际安装包信息时共用的平台通道名称。
const String appPackageInfoPlatformChannel =
    'io.legado.flutter/app_package_info';

/// 当前 Android/iOS 安装包的实际版本身份。
final class InstalledAppPackageInfo {
  /// 创建经过平台服务校验的版本名称和构建号。
  const InstalledAppPackageInfo({
    required this.versionName,
    required this.versionCode,
  });

  /// Android versionName 或 iOS CFBundleShortVersionString。
  final String versionName;

  /// Android longVersionCode 或 iOS CFBundleVersion。
  final int versionCode;
}

/// 暴露当前安装包的实际版本名称和构建号。
abstract interface class AppPackageInfoService {
  /// 一次性读取 Android PackageInfo 或 iOS Bundle 中的版本身份。
  ///
  /// 宿主缺失、平台拒绝或返回非法值时返回 null，由调用方使用受控后备配置。
  Future<InstalledAppPackageInfo?> readPackageInfo();
}

/// 通过项目自有原生宿主读取安装包版本，不引入额外 Flutter 插件和 Gradle 依赖。
final class MethodChannelAppPackageInfoService
    implements AppPackageInfoService {
  /// 创建使用固定原生通道的安装包信息服务。
  const MethodChannelAppPackageInfoService({
    MethodChannel channel = const MethodChannel(appPackageInfoPlatformChannel),
  }) : _channel = channel;

  /// Android MainActivity 与 iOS AppDelegate 共用的窄平台通道。
  final MethodChannel _channel;

  @override
  Future<InstalledAppPackageInfo?> readPackageInfo() async {
    try {
      /// 宿主返回的未经信任安装包信息。
      final Map<Object?, Object?>? rawPackageInfo =
          await _channel.invokeMapMethod<Object?, Object?>('getPackageInfo');
      /// Android/iOS 返回的原始版本名称。
      final Object? rawVersionName = rawPackageInfo?['versionName'];
      /// 去除平台配置中可能存在的首尾空白。
      final String versionName =
          rawVersionName is String ? rawVersionName.trim() : '';
      /// Android 通常返回 int，iOS CFBundleVersion 通常返回数字字符串。
      final Object? rawVersionCode = rawPackageInfo?['versionCode'];
      final int? versionCode = switch (rawVersionCode) {
        int value => value,
        String value => int.tryParse(value.trim()),
        _ => null,
      };
      if (versionName.isEmpty || versionCode == null || versionCode < 0) {
        return null;
      }
      return InstalledAppPackageInfo(
        versionName: versionName,
        versionCode: versionCode,
      );
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
