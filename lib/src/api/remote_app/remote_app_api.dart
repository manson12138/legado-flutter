import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../http/http_contract.dart';
import 'remote_app_service_config.dart';

/// 远端 App API 的统一日志标识；不得记录密钥、签名、完整 URL 或响应正文。
const String remoteAppApiLogTag = 'REMOTE_APP_API';

/// HMAC 请求签名和统一响应信封的远端 App API 实现。
final class RemoteAppApi {
  /// 创建远端 App API。
  RemoteAppApi({required UnifiedHttpClient httpClient, required RemoteAppServiceConfig config})
      : _httpClient = httpClient,
        _config = config;

  /// 统一 HTTP 实现。
  final UnifiedHttpClient _httpClient;
  /// 服务配置。
  final RemoteAppServiceConfig _config;

  /// 获取启动聚合配置。
  Future<Map<String, Object?>> fetchBootstrap() => _signedGet('/api/v1/app/bootstrap', <String, String>{
    'productId': '${_config.productId}',
    'versionName': _config.appVersionName,
    'versionCode': '${_config.appVersionCode}',
    'channel': _config.channel,
  });

  /// 获取并校验应用准入与升级状态，供应用级阻断协调器使用。
  Future<RemoteAppBootstrapStatus> fetchBootstrapStatus() async {
    final Map<String, Object?> data = await fetchBootstrap();
    final Object? accessValue = data['access'];
    final Object? updateValue = data['update'];
    if (accessValue is! Map<Object?, Object?> || accessValue['allowed'] is! bool || updateValue is! Map<Object?, Object?> || updateValue['hasUpdate'] is! bool) {
      throw const UnifiedHttpException(HttpFailureKind.decode, '应用启动配置缺少准入或升级状态');
    }
    return RemoteAppBootstrapStatus(
      allowed: accessValue['allowed'] as bool,
      accessMessage: accessValue['message'] is String ? accessValue['message'] as String : null,
      hasUpdate: updateValue['hasUpdate'] as bool,
      forceUpdate: updateValue['forceUpdate'] == true,
      versionName: updateValue['latestVersion'] is String ? updateValue['latestVersion'] as String : null,
      latestVersionCode: updateValue['latestVersionCode'] is num ? (updateValue['latestVersionCode'] as num).toInt() : null,
      downloadUrl: updateValue['downloadUrl'] is String ? updateValue['downloadUrl'] as String : null,
      changelog: updateValue['changelog'] is String ? updateValue['changelog'] as String : null,
    );
  }

  /// 获取关键字过滤规则。
  Future<Map<String, Object?>> fetchKeywords() => _signedGet('/api/v1/filter/keywords', <String, String>{'productId': '${_config.productId}'});

  /// 获取域名过滤规则。
  Future<Map<String, Object?>> fetchDomains() => _signedGet('/api/v1/filter/domains', <String, String>{'productId': '${_config.productId}'});

  /// 获取当前版本可见的服务端公告。
  Future<List<Object?>> fetchAnnouncements() => _signedGetList('/api/v1/announcements', <String, String>{'productId': '${_config.productId}', 'versionCode': '${_config.appVersionCode}'});

  /// 获取当前产品的功能开关。
  Future<List<Object?>> fetchFeatureFlags() => _signedGetList('/api/v1/flags', <String, String>{'productId': '${_config.productId}'});

  /// 获取登录与注册使用的 RSA-OAEP-SHA256 公钥；仅允许调用方短暂保留在内存中。
  Future<RemotePasswordKey> fetchPasswordKey() async {
    final Object? data = await _executeEnvelope(HttpRequest(
      uri: _config.baseUri.replace(path: '/api/v1/auth/password-key'),
      headers: const <String, String>{'Accept': 'application/json'},
      cookieMode: HttpCookieMode.disabled,
      logContext: remoteAppApiLogTag,
    ));
    if (data is! Map<Object?, Object?> || data['algorithm'] != 'RSA-OAEP' || data['hash'] != 'SHA-256' || data['keyId'] is! String || (data['keyId'] as String).isEmpty || data['publicKey'] is! String || (data['publicKey'] as String).trim().isEmpty) {
      throw const UnifiedHttpException(HttpFailureKind.decode, '密码加密公钥无效');
    }
    return RemotePasswordKey(keyId: data['keyId'] as String, publicKey: data['publicKey'] as String);
  }

  /// 使用已加密密码登录并返回服务端 token；调用方不得记录或持久化该值。
  Future<String> login({required String username, required String passwordEncrypted}) async {
    final RemoteAppLoginResult result = await loginWithProfile(username: username, passwordEncrypted: passwordEncrypted);
    return result.accessToken;
  }

  /// 使用已加密密码登录并返回受控的用户资料和短期会话 token。
  Future<RemoteAppLoginResult> loginWithProfile({required String username, required String passwordEncrypted}) async {
    final Object? data = await _executeEnvelope(HttpRequest(
      uri: _config.baseUri.replace(path: '/api/v1/auth/login'),
      method: HttpRequestMethod.post,
      headers: const <String, String>{'Accept': 'application/json', 'Content-Type': 'application/json'},
      body: TextHttpRequestBody(jsonEncode(<String, Object?>{'productId': _config.productId, 'username': username, 'passwordEncrypted': passwordEncrypted}), contentType: 'application/json'),
      acceptHttpErrorStatus: true,
      cookieMode: HttpCookieMode.disabled,
      logContext: remoteAppApiLogTag,
    ));
    return _decodeLoginResult(data, action: '登录');
  }

  /// 使用 Refresh Token 和 App HMAC 轮换整套会话；不得使用 Bearer 或并发重放同一 Token。
  Future<RemoteAppLoginResult> refreshLogin(String refreshToken) async {
    final String body = jsonEncode(<String, Object?>{'refreshToken': refreshToken});
    final String timestamp = '${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
    final String nonce = base64UrlEncode(List<int>.generate(18, (_) => Random.secure().nextInt(256))).replaceAll('=', '');
    final String signature = Hmac(sha256, utf8.encode(_config.hmacSecret)).convert(utf8.encode('POST/api/v1/auth/refresh$timestamp$nonce$body')).toString();
    final Object? data = await _executeEnvelope(HttpRequest(
      uri: _config.baseUri.replace(path: '/api/v1/auth/refresh'),
      method: HttpRequestMethod.post,
      headers: <String, String>{'Accept': 'application/json', 'Content-Type': 'application/json', 'X-App-Timestamp': timestamp, 'X-App-Nonce': nonce, 'X-App-Signature': signature},
      body: TextHttpRequestBody(body, contentType: 'application/json'),
      acceptHttpErrorStatus: true,
      cookieMode: HttpCookieMode.disabled,
      logContext: remoteAppApiLogTag,
    ));
    return _decodeLoginResult(data, action: '刷新登录');
  }

  /// 使用当前 Refresh Token 撤销整组服务端会话；调用方无论结果如何都必须清除本地凭据。
  Future<void> logoutWithRefreshToken(String refreshToken) async {
    final String body = jsonEncode(<String, Object?>{'refreshToken': refreshToken});
    final String timestamp = '${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
    final String nonce = base64UrlEncode(List<int>.generate(18, (_) => Random.secure().nextInt(256))).replaceAll('=', '');
    final String signature = Hmac(sha256, utf8.encode(_config.hmacSecret)).convert(utf8.encode('POST/api/v1/auth/logout$timestamp$nonce$body')).toString();
    await _executeEnvelope(HttpRequest(
      uri: _config.baseUri.replace(path: '/api/v1/auth/logout'),
      method: HttpRequestMethod.post,
      headers: <String, String>{'Accept': 'application/json', 'Content-Type': 'application/json', 'X-App-Timestamp': timestamp, 'X-App-Nonce': nonce, 'X-App-Signature': signature},
      body: TextHttpRequestBody(body, contentType: 'application/json'),
      acceptHttpErrorStatus: true,
      cookieMode: HttpCookieMode.disabled,
      logContext: remoteAppApiLogTag,
    ));
  }

  /// 使用已加密密码和邀请码注册 App 账号；注册不假定服务端会自动建立登录会话。
  Future<RemoteAppUser> register({required String username, required String passwordEncrypted, required String invitationCode}) async {
    final Object? data = await _executeEnvelope(HttpRequest(
      uri: _config.baseUri.replace(path: '/api/v1/auth/register'),
      method: HttpRequestMethod.post,
      headers: const <String, String>{'Accept': 'application/json', 'Content-Type': 'application/json'},
      body: TextHttpRequestBody(jsonEncode(<String, Object?>{'productId': _config.productId, 'username': username, 'passwordEncrypted': passwordEncrypted, 'invitationCode': invitationCode}), contentType: 'application/json'),
      acceptHttpErrorStatus: true,
      cookieMode: HttpCookieMode.disabled,
      logContext: remoteAppApiLogTag,
    ));
    if (data is! Map<Object?, Object?>) { throw const UnifiedHttpException(HttpFailureKind.decode, 'App 注册响应无效'); }
    return _decodeUser(data);
  }

  /// 获取当前已登录用户的服务端权限快照。
  Future<RemoteAppAccountPermissions> fetchAccountPermissions(String token) async {
    final Object? data = await _executeEnvelope(HttpRequest(
      uri: _config.baseUri.replace(path: '/api/v1/account/permissions'),
      headers: <String, String>{'Accept': 'application/json', 'Authorization': 'Bearer $token'},
      cookieMode: HttpCookieMode.disabled,
      logContext: remoteAppApiLogTag,
    ));
    if (data is! Map<Object?, Object?> || data['userRole'] is! String || data['canGenerateInvite'] is! bool || data['canSyncBookSource'] is! bool) {
      throw const UnifiedHttpException(HttpFailureKind.decode, '账号权限响应无效');
    }
    return RemoteAppAccountPermissions(
      userRole: data['userRole'] as String,
      canGenerateInvite: data['canGenerateInvite'] as bool,
      canSyncBookSource: data['canSyncBookSource'] as bool,
      inviteAvailableAt: data['inviteAvailableAt'] is String ? DateTime.tryParse(data['inviteAvailableAt'] as String) : null,
    );
  }

  /// 获取当前用户可用的邀请码；调用方须先检查权限，但服务端仍为最终判定。
  Future<RemoteAppInvitation> createInvitation(String token) async {
    final Object? data = await _executeEnvelope(HttpRequest(
      uri: _config.baseUri.replace(path: '/api/v1/invitations'),
      method: HttpRequestMethod.post,
      headers: <String, String>{'Accept': 'application/json', 'Authorization': 'Bearer $token'},
      cookieMode: HttpCookieMode.disabled,
      logContext: remoteAppApiLogTag,
    ));
    if (data is! Map<Object?, Object?> || data['code'] is! String || data['expiresAt'] is! String) {
      throw const UnifiedHttpException(HttpFailureKind.decode, '邀请码响应无效');
    }
    final DateTime? expiresAt = DateTime.tryParse(data['expiresAt'] as String);
    if (expiresAt == null) { throw const UnifiedHttpException(HttpFailureKind.decode, '邀请码过期时间无效'); }
    return RemoteAppInvitation(code: data['code'] as String, expiresAt: expiresAt);
  }

  /// 解码后端返回的 App 用户资料，避免动态 Map 穿透数据层。
  RemoteAppUser _decodeUser(Map<Object?, Object?> data) {
    if (data['id'] is! num || data['username'] is! String || data['status'] is! String) {
      throw const UnifiedHttpException(HttpFailureKind.decode, 'App 用户资料无效');
    }
    return RemoteAppUser(id: (data['id'] as num).toInt(), username: data['username'] as String, status: data['status'] as String);
  }

  /// 校验登录或刷新响应中的 Token 生命周期与最小用户资料。
  RemoteAppLoginResult _decodeLoginResult(Object? data, {required String action}) {
    if (data is! Map<Object?, Object?> || data['accessToken'] is! String || (data['accessToken'] as String).isEmpty) {
      throw UnifiedHttpException(HttpFailureKind.decode, 'App $action响应缺少 accessToken');
    }
    if (data['accessExpiresAt'] is! String || DateTime.tryParse(data['accessExpiresAt'] as String) == null) {
      throw UnifiedHttpException(HttpFailureKind.decode, 'App $action响应缺少有效 accessExpiresAt');
    }
    if (data['refreshAfter'] is! String || DateTime.tryParse(data['refreshAfter'] as String) == null) {
      throw UnifiedHttpException(HttpFailureKind.decode, 'App $action响应缺少有效 refreshAfter');
    }
    if (data['refreshToken'] is! String || (data['refreshToken'] as String).isEmpty) {
      throw UnifiedHttpException(HttpFailureKind.decode, 'App $action响应缺少 refreshToken');
    }
    if (data['refreshExpiresAt'] is! String || DateTime.tryParse(data['refreshExpiresAt'] as String) == null) {
      throw UnifiedHttpException(HttpFailureKind.decode, 'App $action响应缺少有效 refreshExpiresAt');
    }
    if (data['user'] is! Map<Object?, Object?>) {
      throw UnifiedHttpException(HttpFailureKind.decode, 'App $action响应缺少 user');
    }
    return RemoteAppLoginResult(
      accessToken: data['accessToken'] as String,
      accessExpiresAt: DateTime.parse(data['accessExpiresAt'] as String).toUtc(),
      refreshAfter: DateTime.parse(data['refreshAfter'] as String).toUtc(),
      refreshToken: data['refreshToken'] as String,
      refreshExpiresAt: DateTime.parse(data['refreshExpiresAt'] as String).toUtc(),
      user: _decodeUser(data['user'] as Map<Object?, Object?>),
    );
  }

  /// 判断受控业务异常是否是后端明确配置的密码公钥失效，未配置时绝不自动重试。
  bool isPasswordKeyInvalidError(Object error) =>
      error is RemoteAppBusinessException && _config.passwordKeyInvalidBusinessCodes.contains(error.businessCode);

  /// 以不可变书源 ID 游标拉取当前账号可同步的启用书源。
  ///
  /// `beforeId` 仅能使用上一批成功落库后保存的服务端游标；首次同步不传该参数。
  Future<RemoteBookSourceCursorPage> fetchBookSourceCursorPage(
    String token, {
    int? beforeId,
  }) async {
    if (beforeId != null && beforeId <= 0) {
      throw const FormatException('书源同步游标必须为正整数');
    }
    final Map<String, String> query = <String, String>{};
    if (beforeId != null) {
      query['beforeId'] = '$beforeId';
    }
    final Object? data = await _signedAuthenticatedGetData(
      '/api/v1/booksource/page',
      token,
      query,
    );
    if (data is! Map<Object?, Object?> ||
        data['items'] is! List<Object?> ||
        data['total'] is! int ||
        data['pageSize'] is! int ||
        data['hasMore'] is! bool ||
        (data['nextCursor'] != null && data['nextCursor'] is! int)) {
      throw const UnifiedHttpException(HttpFailureKind.decode, '服务端书源游标同步响应无效');
    }
    final int? nextCursor = data['nextCursor'] == null
        ? null
        : data['nextCursor'] as int;
    return RemoteBookSourceCursorPage(
      items: List<Object?>.unmodifiable(data['items'] as List<Object?>),
      total: data['total'] as int,
      pageSize: data['pageSize'] as int,
      nextCursor: nextCursor,
      hasMore: data['hasMore'] as bool,
    );
  }

  /// 批量上报书源请求结果；调用方负责离线队列与失败重试。
  Future<void> reportBookSourceEvents(String token, List<Map<String, Object?>> events) async {
    if (events.isEmpty) { return; }
    await _executeEnvelope(HttpRequest(
      uri: _config.baseUri.replace(path: '/api/v1/booksource/event'),
      method: HttpRequestMethod.post,
      headers: <String, String>{'Accept': 'application/json', 'Content-Type': 'application/json', 'Authorization': 'Bearer $token'},
      body: TextHttpRequestBody(jsonEncode(<String, Object?>{'events': events}), contentType: 'application/json'),
      cookieMode: HttpCookieMode.disabled,
      logContext: remoteAppApiLogTag,
    ));
  }

  /// 批量上报经用户同意的非敏感分析事件并读取幂等接收数量。
  Future<RemoteAnalyticsReceipt> reportAnalyticsEvents(
    String token,
    List<Map<String, Object?>> events,
  ) async {
    final Object? data = await _signedPostData(
      '/api/v1/analytics/batch',
      token,
      <String, Object?>{
        'schemaVersion': 1,
        'events': events,
      },
    );
    if (data is! Map<Object?, Object?> ||
        data['accepted'] is! num ||
        data['duplicate'] is! num) {
      throw const UnifiedHttpException(
        HttpFailureKind.decode,
        '匿名埋点响应无效',
      );
    }
    final int accepted = (data['accepted'] as num).toInt();
    final int duplicate = (data['duplicate'] as num).toInt();
    if (accepted < 0 || duplicate < 0) {
      throw const UnifiedHttpException(
        HttpFailureKind.decode,
        '匿名埋点响应计数无效',
      );
    }
    return RemoteAnalyticsReceipt(
      accepted: accepted,
      duplicate: duplicate,
    );
  }

  /// 上报本地聚合书源成功率，并读取未知书源地址。
  Future<RemoteBookSourceStatsReceipt> reportBookSourceStats(
    String token, {
    required List<Map<String, Object?>> reports,
    List<Map<String, Object?>> bookSources =
        const <Map<String, Object?>>[],
  }) async {
    final Map<String, Object?> payload = <String, Object?>{
      'reports': reports,
    };
    if (bookSources.isNotEmpty) {
      payload['bookSources'] = bookSources;
    }
    final Object? data = await _signedPostData(
      '/api/v1/booksource/stats/batch',
      token,
      payload,
    );
    if (data is! Map<Object?, Object?> ||
        data['acceptedReports'] is! num ||
        data['importedSources'] is! num ||
        data['missingBookSourceUrls'] is! List<Object?>) {
      throw const UnifiedHttpException(
        HttpFailureKind.decode,
        '书源成功率响应无效',
      );
    }
    final List<String> missingUrls = <String>[];
    for (final Object? value
        in data['missingBookSourceUrls'] as List<Object?>) {
      if (value is! String) {
        throw const UnifiedHttpException(
          HttpFailureKind.decode,
          '书源成功率缺失地址字段无效',
        );
      }
      missingUrls.add(value);
    }
    final int acceptedReports =
        (data['acceptedReports'] as num).toInt();
    final int importedSources =
        (data['importedSources'] as num).toInt();
    if (acceptedReports < 0 || importedSources < 0) {
      throw const UnifiedHttpException(
        HttpFailureKind.decode,
        '书源成功率响应计数无效',
      );
    }
    return RemoteBookSourceStatsReceipt(
      acceptedReports: acceptedReports,
      importedSources: importedSources,
      missingBookSourceUrls: List<String>.unmodifiable(missingUrls),
    );
  }

  /// 上传一份已脱敏的崩溃报告；Bearer 会话可选，App 签名始终参与请求。
  Future<RemoteCrashReportReceipt> uploadCrashReport({required Map<String, Object?> report, String? token}) async {
    final String body = jsonEncode(report);
    final String timestamp = '${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
    final String nonce = base64UrlEncode(List<int>.generate(18, (_) => Random.secure().nextInt(256))).replaceAll('=', '');
    final String signature = Hmac(sha256, utf8.encode(_config.hmacSecret)).convert(utf8.encode('POST/api/v1/crash-reports$timestamp$nonce$body')).toString();
    final Map<String, String> headers = <String, String>{'Accept': 'application/json', 'Content-Type': 'application/json', 'X-App-Timestamp': timestamp, 'X-App-Nonce': nonce, 'X-App-Signature': signature};
    if (token case final String value when value.isNotEmpty) {
      headers['Authorization'] = 'Bearer $value';
    }
    final Object? data = await _executeEnvelope(HttpRequest(
      uri: _config.baseUri.replace(path: '/api/v1/crash-reports'),
      method: HttpRequestMethod.post,
      headers: headers,
      body: TextHttpRequestBody(body, contentType: 'application/json'),
      cookieMode: HttpCookieMode.disabled,
      logContext: remoteAppApiLogTag,
    ));
    if (data is! Map<Object?, Object?> || data['accepted'] != true || data['receiptId'] is! String || data['retentionDays'] is! num) {
      throw const UnifiedHttpException(HttpFailureKind.decode, '崩溃报告上传响应无效');
    }
    return RemoteCrashReportReceipt(receiptId: data['receiptId'] as String, retentionDays: (data['retentionDays'] as num).toInt());
  }

  /// 发送同时需要 App HMAC 与登录会话的 JSON POST 请求。
  Future<void> _signedPost(String path, String token, Map<String, Object?> payload) async {
    await _signedPostData(path, token, payload);
  }

  /// 发送 HMAC + Bearer JSON POST，并返回统一响应信封中的 data。
  Future<Object?> _signedPostData(
    String path,
    String token,
    Map<String, Object?> payload,
  ) async {
    final String body = jsonEncode(payload);
    final String timestamp = '${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
    final String nonce = base64UrlEncode(List<int>.generate(18, (_) => Random.secure().nextInt(256))).replaceAll('=', '');
    final String signature = Hmac(sha256, utf8.encode(_config.hmacSecret)).convert(utf8.encode('POST$path$timestamp$nonce$body')).toString();
    return _executeEnvelope(HttpRequest(
      uri: _config.baseUri.replace(path: path),
      method: HttpRequestMethod.post,
      headers: <String, String>{'Accept': 'application/json', 'Content-Type': 'application/json', 'Authorization': 'Bearer $token', 'X-App-Timestamp': timestamp, 'X-App-Nonce': nonce, 'X-App-Signature': signature},
      body: TextHttpRequestBody(body, contentType: 'application/json'),
      cookieMode: HttpCookieMode.disabled,
      logContext: remoteAppApiLogTag,
    ));
  }

  /// 发送无请求体的已签名 GET 请求并校验 `{code,message,data}` 信封。
  Future<Map<String, Object?>> _signedGet(String path, Map<String, String> query) async {
    final Object? data = await _signedGetData(path, query);
    if (data is! Map<Object?, Object?>) {
      throw const UnifiedHttpException(HttpFailureKind.decode, '远端 App 服务响应数据不是对象');
    }
    return data.map<String, Object?>((Object? key, Object? value) {
      if (key is! String) { throw const UnifiedHttpException(HttpFailureKind.decode, '远端 App 服务字段无效'); }
      return MapEntry<String, Object?>(key, value);
    });
  }

  /// 发送已签名 GET 请求并要求响应 data 为列表。
  Future<List<Object?>> _signedGetList(String path, Map<String, String> query) async {
    final Object? data = await _signedGetData(path, query);
    if (data is! List<Object?>) { throw const UnifiedHttpException(HttpFailureKind.decode, '远端 App 服务响应数据不是列表'); }
    return List<Object?>.unmodifiable(data);
  }

  /// 发送已签名 GET 请求并返回后端响应信封中的原始 data。
  Future<Object?> _signedGetData(String path, Map<String, String> query) async {
    final String timestamp = '${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
    final String nonce = base64UrlEncode(List<int>.generate(18, (_) => Random.secure().nextInt(256))).replaceAll('=', '');
    final String source = 'GET$path$timestamp$nonce';
    final String signature = Hmac(sha256, utf8.encode(_config.hmacSecret)).convert(utf8.encode(source)).toString();
    return _executeEnvelope(HttpRequest(
      uri: _config.baseUri.replace(path: path, queryParameters: query),
      headers: <String, String>{'Accept': 'application/json', 'X-App-Timestamp': timestamp, 'X-App-Nonce': nonce, 'X-App-Signature': signature},
      cookieMode: HttpCookieMode.disabled,
      logContext: remoteAppApiLogTag,
    ));
  }

  /// 发送同时携带 App HMAC 与 Bearer 会话的无请求体 GET 请求。
  ///
  /// 签名原文严格使用 URL path，不包含查询参数，以匹配 API v2 的 canonical 定义。
  Future<Object?> _signedAuthenticatedGetData(
    String path,
    String token,
    Map<String, String> query,
  ) async {
    final String timestamp = '${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
    final String nonce = base64UrlEncode(
      List<int>.generate(18, (_) => Random.secure().nextInt(256)),
    ).replaceAll('=', '');
    final String signature = Hmac(sha256, utf8.encode(_config.hmacSecret))
        .convert(utf8.encode('GET$path$timestamp$nonce'))
        .toString();
    return _executeEnvelope(HttpRequest(
      uri: _config.baseUri.replace(path: path, queryParameters: query),
      headers: <String, String>{
        'Accept': 'application/json',
        'Authorization': 'Bearer $token',
        'X-App-Timestamp': timestamp,
        'X-App-Nonce': nonce,
        'X-App-Signature': signature,
      },
      cookieMode: HttpCookieMode.disabled,
      logContext: remoteAppApiLogTag,
    ));
  }

  /// 执行请求并校验后端统一响应信封后返回未转换的 `data` 值。
  Future<Object?> _executeEnvelope(HttpRequest request) async {
    final HttpResponse response = await _httpClient.execute(request);
    final Object? root;
    try { root = jsonDecode(utf8.decode(response.bytes)); } on FormatException { throw const UnifiedHttpException(HttpFailureKind.decode, '远端 App 服务响应格式无效'); }
    if (root is! Map<Object?, Object?> || root['code'] is! num) {
      throw const UnifiedHttpException(HttpFailureKind.decode, '远端 App 服务响应信封无效');
    }
    /// 后端业务失败必须优先保留机器可识别业务码，供认证层严格决定是否允许单次重试。
    final int businessCode = (root['code'] as num).toInt();
    if (businessCode != 0) {
      throw RemoteAppBusinessException(businessCode: businessCode, statusCode: response.statusCode);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw UnifiedHttpException(HttpFailureKind.httpStatus, '远端 App 服务返回异常状态', statusCode: response.statusCode);
    }
    return root['data'];
  }
}

/// 远端 App 的受控业务失败；仅保留状态和数字业务码，不保存服务端正文或敏感数据。
final class RemoteAppBusinessException implements Exception {
  /// 创建不向 UI 暴露原始响应的业务异常。
  const RemoteAppBusinessException({required this.businessCode, required this.statusCode});

  /// 后端统一响应信封中的机器可识别业务码。
  final int businessCode;
  /// 本次响应的 HTTP 状态；仅供数据层的受控判定使用。
  final int statusCode;
}

/// 服务端书源游标批次的受控 DTO；items 仍由既有导入解码器进行完整校验。
final class RemoteBookSourceCursorPage {
  /// 创建书源游标同步批次。
  const RemoteBookSourceCursorPage({
    required this.items,
    required this.total,
    required this.pageSize,
    required this.nextCursor,
    required this.hasMore,
  });

  /// 本页不可信书源 JSON 值。
  final List<Object?> items;
  /// 服务端本次声明的总书源数。
  final int total;
  /// 服务端固定的分页大小。
  final int pageSize;
  /// 当前批成功落库后，下次请求应携带的游标；完成时必须为 null。
  final int? nextCursor;
  /// 是否仍有下一批数据；它是本轮完成的唯一判定条件。
  final bool hasMore;
}

/// 匿名埋点批次的幂等接收结果。
final class RemoteAnalyticsReceipt {
  /// 创建匿名埋点接收结果。
  const RemoteAnalyticsReceipt({
    required this.accepted,
    required this.duplicate,
  });

  /// 本次首次接收的事件桶数量。
  final int accepted;

  /// 本次因 eventId 幂等命中的事件桶数量。
  final int duplicate;
}

/// 书源成功率批次的接收、导入和缺失结果。
final class RemoteBookSourceStatsReceipt {
  /// 创建书源成功率接收结果。
  const RemoteBookSourceStatsReceipt({
    required this.acceptedReports,
    required this.importedSources,
    required this.missingBookSourceUrls,
  });

  /// 本次被服务端计入的统计桶数量。
  final int acceptedReports;

  /// 第二阶段新导入的书源数量。
  final int importedSources;

  /// 本阶段尚未存在、因此未计数的书源地址。
  final List<String> missingBookSourceUrls;
}

/// 服务端下发的 RSA-OAEP 公钥；算法与哈希已在 API 层完成严格校验。
final class RemotePasswordKey {
  /// 创建受控的公钥 DTO。
  const RemotePasswordKey({required this.keyId, required this.publicKey});

  /// 服务端密钥标识，仅用于内存缓存失效判断。
  final String keyId;

  /// PEM 格式 RSA 公钥；不得写入日志或持久化。
  final String publicKey;
}

/// 登录或刷新接口返回的双 Token 与用户资料。
final class RemoteAppLoginResult {
  /// 创建登录结果。
  const RemoteAppLoginResult({required this.accessToken, required this.accessExpiresAt, required this.refreshAfter, required this.refreshToken, required this.refreshExpiresAt, required this.user});
  /// 用于 Bearer 业务接口的短期 Access Token。
  final String accessToken;
  /// 服务端声明的 Access Token 过期时刻。
  final DateTime accessExpiresAt;
  /// 服务端建议的 Token 刷新时刻。
  final DateTime refreshAfter;
  /// 仅用于刷新与退出的长效 Refresh Token。
  final String refreshToken;
  /// 服务端声明的 Refresh Token 过期时刻。
  final DateTime refreshExpiresAt;
  /// 当前登录用户。
  final RemoteAppUser user;
}

/// 后端返回的最小 App 用户资料。
final class RemoteAppUser {
  /// 创建 App 用户资料。
  const RemoteAppUser({required this.id, required this.username, required this.status});
  /// 服务端用户标识。
  final int id;
  /// 服务端用户名。
  final String username;
  /// 服务端账号状态。
  final String status;
}

/// 后端判定的当前账号权限快照。
final class RemoteAppAccountPermissions {
  /// 创建账号权限快照。
  const RemoteAppAccountPermissions({required this.userRole, required this.canGenerateInvite, required this.canSyncBookSource, this.inviteAvailableAt});
  /// 服务端角色名称。
  final String userRole;
  /// 是否允许生成邀请码。
  final bool canGenerateInvite;
  /// 是否允许同步服务端书源。
  final bool canSyncBookSource;
  /// 邀请资格开放时间；为空代表服务端未返回。
  final DateTime? inviteAvailableAt;
}

/// 当前用户获得的邀请码及其到期时间。
final class RemoteAppInvitation {
  /// 创建邀请码结果。
  const RemoteAppInvitation({required this.code, required this.expiresAt});
  /// 一次性邀请码。
  final String code;
  /// 邀请码的服务端到期时间。
  final DateTime expiresAt;
}

/// 服务端启动配置中受控的准入与升级状态。
/// 服务端接受崩溃报告后返回的最小回执，不向 UI 暴露动态响应 Map。
final class RemoteCrashReportReceipt {
  /// 创建已被服务端接收或幂等去重的回执。
  const RemoteCrashReportReceipt({required this.receiptId, required this.retentionDays});

  /// 服务端回执标识。
  final String receiptId;

  /// 原始报告在服务端的保留天数。
  final int retentionDays;
}

final class RemoteAppBootstrapStatus {
  /// 创建准入与升级状态。
  const RemoteAppBootstrapStatus({required this.allowed, required this.hasUpdate, required this.forceUpdate, this.accessMessage, this.versionName, this.latestVersionCode, this.downloadUrl, this.changelog});
  /// 服务端是否允许当前版本继续运行。
  final bool allowed;
  /// 准入拒绝时可展示的服务端文案。
  final String? accessMessage;
  /// 是否有可用更新。
  final bool hasUpdate;
  /// 是否必须升级后才能继续使用。
  final bool forceUpdate;
  /// 服务端推荐的版本名称。
  final String? versionName;
  /// 服务端声明的最新构建号。
  final int? latestVersionCode;
  /// 服务端提供的升级下载地址；调用方必须先校验为安全外部链接。
  final String? downloadUrl;
  /// 服务端提供的版本更新说明。
  final String? changelog;
}
