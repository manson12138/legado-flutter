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
  });

  /// 创建当前后端开发环境的默认配置；线上必须用 dart-define 覆盖密钥。
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
  );

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
  /// 发布渠道。
  final String channel;
  /// HMAC 密钥，仅用于内存中的签名计算。
  final String hmacSecret;
  /// 后端约定的密码公钥失效业务码；为空时禁用自动重试，避免误重放认证请求。
  final Set<int> passwordKeyInvalidBusinessCodes;
}
