import '../../platform/app_package_info_service.dart';

/// 远端 App 服务的集中配置；所有值均可通过 `--dart-define` 覆盖。
///
/// HMAC 密钥按当前决策仅用于提高滥用成本，不能视为客户端机密；不得写入日志或持久化。
final class RemoteAppServiceConfig {
  /// 创建远端 App 服务配置。
  const RemoteAppServiceConfig({
    required this.baseUri,
    required this.productId,
    required this.appVersionName,
    required this.appVersionCode,
    required this.channel,
    required this.hmacSecret,
    required this.passwordKeyInvalidBusinessCodes,
    this.hasInstalledVersionIdentity = true,
  });

  /// 创建当前后端开发环境的后备配置；线上必须用 dart-define 覆盖密钥。
  ///
  /// 该配置尚未读取实际安装包版本，不能用于恢复需要版本隔离的准入缓存。
  factory RemoteAppServiceConfig.fromEnvironment() => RemoteAppServiceConfig(
    baseUri: Uri.parse(const String.fromEnvironment('REMOTE_APP_BASE_URL', defaultValue: 'http://47.109.99.126')),
    productId: const int.fromEnvironment('REMOTE_APP_PRODUCT_ID', defaultValue: 1),
    appVersionName: const String.fromEnvironment('LEGADO_APP_VERSION_NAME', defaultValue: '1.0.0'),
    appVersionCode: const int.fromEnvironment('LEGADO_APP_VERSION_CODE', defaultValue: 6),
    channel: const String.fromEnvironment('REMOTE_APP_CHANNEL', defaultValue: 'official'),
    hmacSecret: const String.fromEnvironment('REMOTE_APP_HMAC_SECRET', defaultValue: 'dev-app-signature-change-me'),
    passwordKeyInvalidBusinessCodes: _parseBusinessCodes(
      const String.fromEnvironment('REMOTE_APP_PASSWORD_KEY_INVALID_CODES'),
    ),
    hasInstalledVersionIdentity: false,
  );

  /// 读取 Android/iOS 实际安装包版本，并与服务地址、渠道和签名配置合并。
  ///
  /// `versionName` 是准入缓存跨平台失效的唯一版本依据；build number 只继续用于服务端契约，
  /// 不参与持久化升级状态是否属于当前安装包的判断。
  static Future<RemoteAppServiceConfig> fromInstalledPackage({
    AppPackageInfoService packageInfoService =
        const MethodChannelAppPackageInfoService(),
  }) async {
    /// 服务地址、产品、渠道和签名仍来自统一编译配置。
    final RemoteAppServiceConfig environment = RemoteAppServiceConfig.fromEnvironment();
    /// Android/iOS 宿主返回的实际语义版本名。
    final String? installedVersionName =
        await packageInfoService.readVersionName();
    if (installedVersionName == null) {
      return environment;
    }
    return RemoteAppServiceConfig(
      baseUri: environment.baseUri,
      productId: environment.productId,
      appVersionName: installedVersionName,
      appVersionCode: environment.appVersionCode,
      channel: environment.channel,
      hmacSecret: environment.hmacSecret,
      passwordKeyInvalidBusinessCodes:
          environment.passwordKeyInvalidBusinessCodes,
      hasInstalledVersionIdentity: true,
    );
  }

  /// 解析由逗号分隔的后端密钥失效业务码；非法值不参与自动重试。
  static Set<int> _parseBusinessCodes(String rawCodes) => Set<int>.unmodifiable(
    rawCodes.split(',').map(int.tryParse).whereType<int>(),
  );

  /// 服务根地址，不包含 `/api/v1`。
  final Uri baseUri;
  /// 管理平台中的产品标识。
  final int productId;
  /// 当前构建版本号。
  final String appVersionName;
  /// 当前构建号。
  final int appVersionCode;
  /// 是否已经从当前 Android/iOS 安装包读取到可信的语义版本身份。
  final bool hasInstalledVersionIdentity;
  /// 发布渠道。
  final String channel;
  /// HMAC 密钥，仅用于内存中的签名计算。
  final String hmacSecret;
  /// 后端约定的密码公钥失效业务码；为空时禁用自动重试，避免误重放认证请求。
  final Set<int> passwordKeyInvalidBusinessCodes;
}
