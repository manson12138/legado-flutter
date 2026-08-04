import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../http/http_contract.dart';
import '../../help/logging/app_logger.dart';
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
    'platform': _config.platform,
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
    final String? downloadSha256 = updateValue['downloadSha256'] is String
        ? (updateValue['downloadSha256'] as String).trim().toLowerCase()
        : null;
    final int? downloadByteSize = updateValue['downloadByteSize'] is num
        ? (updateValue['downloadByteSize'] as num).toInt()
        : null;
    if ((downloadSha256 == null) != (downloadByteSize == null) ||
        (downloadSha256 != null &&
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(downloadSha256)) ||
        (downloadByteSize != null && downloadByteSize <= 0)) {
      throw const UnifiedHttpException(
        HttpFailureKind.decode,
        '应用启动配置的安装包校验信息无效',
      );
    }
    return RemoteAppBootstrapStatus(
      allowed: accessValue['allowed'] as bool,
      accessMessage: accessValue['message'] is String ? accessValue['message'] as String : null,
      hasUpdate: updateValue['hasUpdate'] as bool,
      forceUpdate: updateValue['forceUpdate'] == true,
      versionName: updateValue['latestVersion'] is String ? updateValue['latestVersion'] as String : null,
      latestVersionCode: updateValue['latestVersionCode'] is num ? (updateValue['latestVersionCode'] as num).toInt() : null,
      downloadUrl: updateValue['downloadUrl'] is String ? updateValue['downloadUrl'] as String : null,
      downloadSha256: downloadSha256,
      downloadByteSize: downloadByteSize,
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

  /// 使用管理员邀请码兑换只存在于内存中的游客书源凭证。
  ///
  /// 原始邀请码只会进入本次签名请求体，不得由调用方记录或持久化。
  Future<RemoteGuestBookSourceSession> createGuestBookSourceSession(
    String invitationCode, {
    HttpCancellationToken? cancellationToken,
  }) async {
    /// 去除输入外围空白后的邀请码；内部字符由服务端做最终校验。
    final String candidate = invitationCode.trim();
    if (candidate.isEmpty) {
      throw const FormatException('邀请码不能为空');
    }
    /// 游客凭证兑换接口固定路径，也是 HMAC canonical 的 URL_PATH。
    const String path = '/api/v1/booksource/guest/session';
    /// 实际发送且参与 HMAC 的原始 JSON 请求体。
    final String body = jsonEncode(<String, Object?>{
      'productId': _config.productId,
      'invitationCode': candidate,
    });
    /// Unix 秒时间戳；服务端允许五分钟时钟偏差。
    final String timestamp =
        '${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
    /// 每次请求独立生成的随机 nonce，不写入客户端持久化。
    final String nonce = base64UrlEncode(
      List<int>.generate(18, (_) => Random.secure().nextInt(256)),
    ).replaceAll('=', '');
    /// 严格按 POST + URL_PATH + TIMESTAMP + NONCE + RAW_BODY 计算签名。
    final String signature = Hmac(sha256, utf8.encode(_config.hmacSecret))
        .convert(utf8.encode('POST$path$timestamp$nonce$body'))
        .toString();
    /// 统一信封中的游客会话数据。
    final Object? data = await _executeEnvelope(
      HttpRequest(
        uri: _config.baseUri.replace(path: path),
        method: HttpRequestMethod.post,
        headers: <String, String>{
          'Accept': 'application/json',
          'Content-Type': 'application/json',
          'X-App-Timestamp': timestamp,
          'X-App-Nonce': nonce,
          'X-App-Signature': signature,
        },
        body: TextHttpRequestBody(body, contentType: 'application/json'),
        acceptHttpErrorStatus: true,
        cookieMode: HttpCookieMode.disabled,
        logContext: guestBookSourceImportLogTag,
      ),
      cancellationToken: cancellationToken,
    );
    if (data is! Map<Object?, Object?> ||
        data['guestToken'] is! String ||
        data['expiresAt'] is! String) {
      throw const UnifiedHttpException(
        HttpFailureKind.decode,
        '游客书源凭证响应无效',
      );
    }
    /// 服务端返回的临时 Bearer 凭证。
    final String guestToken = data['guestToken'] as String;
    /// 服务端声明的游客凭证失效时间。
    final DateTime? expiresAt =
        DateTime.tryParse(data['expiresAt'] as String)?.toUtc();
    if (guestToken.length != 43 ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(guestToken) ||
        expiresAt == null ||
        !expiresAt.isAfter(DateTime.now().toUtc())) {
      throw const UnifiedHttpException(
        HttpFailureKind.decode,
        '游客书源凭证字段无效',
      );
    }
    return RemoteGuestBookSourceSession(
      guestToken: guestToken,
      expiresAt: expiresAt,
    );
  }

  /// 使用临时游客凭证按不可变书源 ID 游标获取一批启用书源。
  Future<RemoteBookSourceCursorPage> fetchGuestBookSourceCursorPage(
    String guestToken, {
    int? beforeId,
    HttpCancellationToken? cancellationToken,
  }) async {
    if (guestToken.isEmpty) {
      throw const FormatException('游客书源凭证不能为空');
    }
    if (beforeId != null && beforeId <= 0) {
      throw const FormatException('游客书源同步游标必须为正整数');
    }
    /// 游客书源分页接口固定路径，也是 HMAC canonical 的 URL_PATH。
    const String path = '/api/v1/booksource/guest/page';
    /// 首次请求为空，后续只使用服务端上一批返回的游标。
    final Map<String, String> query = <String, String>{};
    if (beforeId != null) {
      query['beforeId'] = '$beforeId';
    }
    /// Unix 秒时间戳；每个分页请求都重新计算。
    final String timestamp =
        '${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
    /// 每个分页请求独立生成的随机 nonce。
    final String nonce = base64UrlEncode(
      List<int>.generate(18, (_) => Random.secure().nextInt(256)),
    ).replaceAll('=', '');
    /// GET 无 RAW_BODY，查询参数不进入用户提供的 URL_PATH canonical。
    final String signature = Hmac(sha256, utf8.encode(_config.hmacSecret))
        .convert(utf8.encode('GET$path$timestamp$nonce'))
        .toString();
    /// 统一响应信封中的游客书源分页对象。
    final Object? data = await _executeEnvelope(
      HttpRequest(
        uri: _config.baseUri.replace(path: path, queryParameters: query),
        headers: <String, String>{
          'Accept': 'application/json',
          'Authorization': 'Bearer $guestToken',
          'X-App-Timestamp': timestamp,
          'X-App-Nonce': nonce,
          'X-App-Signature': signature,
        },
        acceptHttpErrorStatus: true,
        cookieMode: HttpCookieMode.disabled,
        logContext: guestBookSourceImportLogTag,
      ),
      cancellationToken: cancellationToken,
    );
    if (data is! Map<Object?, Object?> ||
        data['items'] is! List<Object?> ||
        data['total'] is! int ||
        data['pageSize'] is! int ||
        data['hasMore'] is! bool ||
        (data['nextCursor'] != null && data['nextCursor'] is! int)) {
      throw const UnifiedHttpException(
        HttpFailureKind.decode,
        '游客书源游标同步响应无效',
      );
    }
    /// 后续批次使用的可空游标。
    final int? nextCursor =
        data['nextCursor'] == null ? null : data['nextCursor'] as int;
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
    if (data is! Map<Object?, Object?> || data['accepted'] != true || data['receiptId'] is! String || data['retentionDays'] is! num || data['duplicate'] is! bool) {
      throw const UnifiedHttpException(HttpFailureKind.decode, '崩溃报告上传响应无效');
    }
    return RemoteCrashReportReceipt(receiptId: data['receiptId'] as String, retentionDays: (data['retentionDays'] as num).toInt(), duplicate: data['duplicate'] as bool);
  }

  /// 初始化或幂等恢复当前账号的备份上传会话。
  Future<RemoteAccountBackupUpload> initializeAccountBackup(
    String token,
    Map<String, Object?> payload,
  ) async {
    final Object? data = await _signedAccountBackupPostData(
      '/api/v1/backups/uploads',
      token,
      payload,
    );
    if (data is! Map<Object?, Object?>) {
      throw const UnifiedHttpException(HttpFailureKind.decode, '备份上传初始化响应无效');
    }
    return RemoteAccountBackupUpload.fromJson(data, baseUri: _config.baseUri);
  }

  /// 使用 Bearer 与一次性上传凭据发送原始 `.pnbak` 字节。
  Future<void> uploadAccountBackupContent({
    required String token,
    required RemoteAccountBackupUpload upload,
    required Uint8List bytes,
  }) async {
    if (upload.state == 'READY') {
      return;
    }
    final Uri? uploadUri = upload.uploadUri;
    if (uploadUri == null) {
      throw const UnifiedHttpException(HttpFailureKind.decode, '备份上传地址缺失');
    }
    final Object? data = await _executeEnvelope(HttpRequest(
      uri: uploadUri,
      method: HttpRequestMethod.put,
      headers: <String, String>{
        ...upload.uploadHeaders,
        'Authorization': 'Bearer $token',
      },
      body: BytesHttpRequestBody(bytes, contentType: 'application/octet-stream'),
      connectTimeout: const Duration(seconds: 60),
      sendTimeout: const Duration(minutes: 3),
      receiveTimeout: const Duration(seconds: 60),
      totalTimeout: const Duration(minutes: 4),
      followRedirects: false,
      acceptHttpErrorStatus: true,
      cookieMode: HttpCookieMode.disabled,
      logContext: remoteAccountBackupLogTag,
    ));
    if (data is! Map<Object?, Object?> || data['uploaded'] != true) {
      throw const UnifiedHttpException(HttpFailureKind.decode, '备份文件上传响应无效');
    }
  }

  /// 完成上传并要求服务端返回已经进入 `READY` 的备份元数据。
  Future<RemoteAccountBackupMetadata> completeAccountBackup({
    required String token,
    required String uploadId,
    required String clientBackupId,
    required int byteSize,
    required String sha256Value,
  }) async {
    final String endpointPath = '/api/v1/backups/uploads/${Uri.encodeComponent(uploadId)}/complete';
    final Object? data = await _signedAccountBackupPostData(
      endpointPath,
      token,
      <String, Object?>{
        'clientBackupId': clientBackupId,
        'byteSize': byteSize,
        'sha256': sha256Value,
      },
    );
    if (data is! Map<Object?, Object?>) {
      throw const UnifiedHttpException(HttpFailureKind.decode, '备份完成响应无效');
    }
    final RemoteAccountBackupMetadata metadata =
        RemoteAccountBackupMetadata.fromJson(data);
    if (metadata.state != 'READY') {
      throw const UnifiedHttpException(HttpFailureKind.decode, '服务端未确认备份完成');
    }
    return metadata;
  }

  /// 按服务端完成时间倒序读取当前账号的备份列表。
  Future<RemoteAccountBackupPage> fetchAccountBackups(
    String token, {
    String? beforeId,
    int limit = 20,
  }) async {
    if (limit < 1 || limit > 50) {
      throw ArgumentError.value(limit, 'limit', '备份分页大小必须为 1～50');
    }
    final Map<String, String> query = <String, String>{'limit': '$limit'};
    if (beforeId case final String value when value.trim().isNotEmpty) {
      query['beforeId'] = value.trim();
    }
    final Object? data = await _signedAccountBackupGetData(
      '/api/v1/backups',
      token,
      query,
    );
    if (data is! Map<Object?, Object?>) {
      throw const UnifiedHttpException(HttpFailureKind.decode, '备份列表响应无效');
    }
    return RemoteAccountBackupPage.fromJson(data);
  }

  /// 获取当前账号最近完成的一份备份；从未备份时返回空。
  Future<RemoteAccountBackupMetadata?> fetchLatestAccountBackup(
    String token,
  ) async {
    final Object? data = await _signedAccountBackupGetData(
      '/api/v1/backups/latest',
      token,
      const <String, String>{},
    );
    if (data == null) {
      return null;
    }
    if (data is! Map<Object?, Object?>) {
      throw const UnifiedHttpException(HttpFailureKind.decode, '最新备份响应无效');
    }
    return RemoteAccountBackupMetadata.fromJson(data);
  }

  /// 创建只读短期下载地址。
  Future<RemoteAccountBackupDownload> createAccountBackupDownload(
    String token,
    String backupId,
  ) async {
    final String endpointPath = '/api/v1/backups/${Uri.encodeComponent(backupId)}/download';
    final Object? data = await _signedAccountBackupPostData(
      endpointPath,
      token,
      const <String, Object?>{},
    );
    if (data is! Map<Object?, Object?>) {
      throw const UnifiedHttpException(HttpFailureKind.decode, '备份下载地址响应无效');
    }
    return RemoteAccountBackupDownload.fromJson(data, baseUri: _config.baseUri);
  }

  /// 从短期只读地址下载原始备份字节；调用方必须继续校验大小和 SHA-256。
  Future<Uint8List> downloadAccountBackupContent(
    RemoteAccountBackupDownload download,
  ) async {
    final HttpResponse response = await _httpClient.execute(HttpRequest(
      uri: download.downloadUri,
      headers: const <String, String>{'Accept': 'application/octet-stream'},
      connectTimeout: const Duration(seconds: 60),
      receiveTimeout: const Duration(minutes: 3),
      totalTimeout: const Duration(minutes: 4),
      followRedirects: false,
      cookieMode: HttpCookieMode.disabled,
      logContext: remoteAccountBackupLogTag,
    ));
    return response.bytes;
  }

  /// 幂等删除当前账号的一份服务端备份。
  Future<void> deleteAccountBackup(String token, String backupId) async {
    final String endpointPath = '/api/v1/backups/${Uri.encodeComponent(backupId)}';
    final Object? data = await _signedAccountBackupDeleteData(
      endpointPath,
      token,
    );
    if (data is! Map<Object?, Object?> ||
        data['deleted'] != true ||
        data['backupId'] != backupId) {
      throw const UnifiedHttpException(HttpFailureKind.decode, '备份删除响应无效');
    }
  }

  /// 发送账号备份专用 HMAC + Bearer JSON POST，并保留服务端业务错误信封。
  Future<Object?> _signedAccountBackupPostData(
    String path,
    String token,
    Map<String, Object?> payload,
  ) async {
    final String body = jsonEncode(payload);
    final Map<String, String> headers = _signedHeaders(
      method: 'POST',
      path: path,
      body: body,
      token: token,
    );
    headers['Content-Type'] = 'application/json';
    return _executeEnvelope(HttpRequest(
      uri: _config.baseUri.replace(path: path),
      method: HttpRequestMethod.post,
      headers: headers,
      body: TextHttpRequestBody(body, contentType: 'application/json'),
      acceptHttpErrorStatus: true,
      cookieMode: HttpCookieMode.disabled,
      logContext: remoteAccountBackupLogTag,
    ));
  }

  /// 发送账号备份专用 HMAC + Bearer GET；查询参数不进入 v2 签名原文。
  Future<Object?> _signedAccountBackupGetData(
    String path,
    String token,
    Map<String, String> query,
  ) async {
    final Map<String, String> headers = _signedHeaders(
      method: 'GET',
      path: path,
      body: '',
      token: token,
    );
    return _executeEnvelope(HttpRequest(
      uri: _config.baseUri.replace(path: path, queryParameters: query),
      headers: headers,
      acceptHttpErrorStatus: true,
      cookieMode: HttpCookieMode.disabled,
      logContext: remoteAccountBackupLogTag,
    ));
  }

  /// 发送账号备份专用 HMAC + Bearer DELETE；该接口没有请求体。
  Future<Object?> _signedAccountBackupDeleteData(
    String path,
    String token,
  ) async {
    final Map<String, String> headers = _signedHeaders(
      method: 'DELETE',
      path: path,
      body: '',
      token: token,
    );
    return _executeEnvelope(HttpRequest(
      uri: _config.baseUri.replace(path: path),
      method: HttpRequestMethod.delete,
      headers: headers,
      acceptHttpErrorStatus: true,
      cookieMode: HttpCookieMode.disabled,
      logContext: remoteAccountBackupLogTag,
    ));
  }

  /// 创建账号备份控制接口使用的 App HMAC 与 Bearer Header。
  Map<String, String> _signedHeaders({
    required String method,
    required String path,
    required String body,
    required String token,
  }) {
    final String timestamp = '${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
    final String nonce = base64UrlEncode(
      List<int>.generate(18, (_) => Random.secure().nextInt(256)),
    ).replaceAll('=', '');
    final String signature = Hmac(sha256, utf8.encode(_config.hmacSecret))
        .convert(utf8.encode('$method$path$timestamp$nonce$body'))
        .toString();
    return <String, String>{
      'Accept': 'application/json',
      'Authorization': 'Bearer $token',
      'X-App-Timestamp': timestamp,
      'X-App-Nonce': nonce,
      'X-App-Signature': signature,
    };
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
  Future<Object?> _executeEnvelope(
    HttpRequest request, {
    HttpCancellationToken? cancellationToken,
  }) async {
    final HttpResponse response = await _httpClient.execute(
      request,
      cancellationToken: cancellationToken,
    );
    final Object? root;
    try { root = jsonDecode(utf8.decode(response.bytes)); } on FormatException { throw const UnifiedHttpException(HttpFailureKind.decode, '远端 App 服务响应格式无效'); }
    if (root is! Map<Object?, Object?> || root['code'] is! num) {
      throw const UnifiedHttpException(HttpFailureKind.decode, '远端 App 服务响应信封无效');
    }
    /// 后端业务失败必须优先保留机器可识别业务码，供认证层严格决定是否允许单次重试。
    final int businessCode = (root['code'] as num).toInt();
    if (businessCode != 0) {
      throw RemoteAppBusinessException(
        businessCode: businessCode,
        statusCode: response.statusCode,
        failureKind: _classifyBusinessFailure(
          businessCode: businessCode,
          statusCode: response.statusCode,
          messageValue: root['message'],
        ),
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw UnifiedHttpException(HttpFailureKind.httpStatus, '远端 App 服务返回异常状态', statusCode: response.statusCode);
    }
    return root['data'];
  }

  /// 将注册接口已确认的稳定文案转换为受控分类，不保存或向上透传任意服务端正文。
  RemoteAppBusinessFailureKind _classifyBusinessFailure({
    required int businessCode,
    required int statusCode,
    required Object? messageValue,
  }) {
    if (messageValue is! String) {
      return RemoteAppBusinessFailureKind.unknown;
    }
    /// 只检查有限长度的错误标识，避免异常服务端响应造成无界字符串处理。
    final String message = messageValue.trim();
    if (message.isEmpty || message.length > 200) {
      return RemoteAppBusinessFailureKind.unknown;
    }
    /// 英文兼容值用于当前已部署后端；中文值对应用户确认的新注册契约。
    final String lowerMessage = message.toLowerCase();
    if ((statusCode == 409 || businessCode == 40900) &&
        (message == '该用户名已被当前产品使用' ||
            lowerMessage ==
                'username already exists for this product')) {
      return RemoteAppBusinessFailureKind.usernameConflict;
    }
    if (statusCode != 400 || businessCode != 40000) {
      return RemoteAppBusinessFailureKind.unknown;
    }
    if (lowerMessage == 'invalid encrypted password' ||
        message == '加密密码无效') {
      return RemoteAppBusinessFailureKind.invalidEncryptedPassword;
    }
    if (message == '缺少字段' ||
        message == '缺少必填字段' ||
        message == '注册信息缺少必填字段' ||
        message.contains('缺少') && message.contains('字段') ||
        lowerMessage.contains('field validation for') &&
            lowerMessage.contains('required')) {
      return RemoteAppBusinessFailureKind.missingField;
    }
    if (message == '用户名长度不合法' ||
        message == '用户名必须为4～32位' ||
        message == '用户名必须为 4～32 位') {
      return RemoteAppBusinessFailureKind.invalidUsernameLength;
    }
    if (message.contains('用户名') &&
        (message.contains('长度') ||
            message.contains('4～32') ||
            message.contains('4-32'))) {
      return RemoteAppBusinessFailureKind.invalidUsernameLength;
    }
    if (message == '用户名字符不合法' ||
        message == '用户名只能包含英文字母、数字和下划线') {
      return RemoteAppBusinessFailureKind.invalidUsernameCharacters;
    }
    if (message.contains('用户名') &&
        (message.contains('字符') ||
            message.contains('字母') ||
            message.contains('下划线'))) {
      return RemoteAppBusinessFailureKind.invalidUsernameCharacters;
    }
    if (lowerMessage ==
        'username must be 4-32 characters using letters, numbers, or underscore') {
      return RemoteAppBusinessFailureKind.invalidUsername;
    }
    if (message == '密码长度不合法' ||
        message == '密码必须为8～72位' ||
        message == '密码必须为 8～72 位' ||
        lowerMessage == 'password must be between 8 and 72 characters') {
      return RemoteAppBusinessFailureKind.invalidPasswordLength;
    }
    if (message.contains('密码') &&
        (message.contains('长度') ||
            message.contains('8～72') ||
            message.contains('8-72'))) {
      return RemoteAppBusinessFailureKind.invalidPasswordLength;
    }
    if (message == '邀请码格式不合法' ||
        message == '邀请码格式错误' ||
        message.contains('邀请码') && message.contains('格式')) {
      return RemoteAppBusinessFailureKind.invalidInvitationFormat;
    }
    if (message == '邀请码已使用' ||
        message == '邀请码已被使用' ||
        message.contains('邀请码') && message.contains('已使用')) {
      return RemoteAppBusinessFailureKind.usedInvitation;
    }
    if (message == '邀请码已过期' ||
        message.contains('邀请码') && message.contains('过期')) {
      return RemoteAppBusinessFailureKind.expiredInvitation;
    }
    if (message == '邀请码无效' ||
        message.contains('邀请码') && message.contains('无效')) {
      return RemoteAppBusinessFailureKind.invalidInvitation;
    }
    if (lowerMessage == 'invalid or expired invitation code') {
      return RemoteAppBusinessFailureKind.invalidOrExpiredInvitation;
    }
    return RemoteAppBusinessFailureKind.unknown;
  }
}

/// 初始化接口返回的受控上传会话。
final class RemoteAccountBackupUpload {
  /// 创建经过严格解码的上传会话。
  RemoteAccountBackupUpload({
    required this.uploadId,
    required this.backupId,
    required this.state,
    required this.uploadUri,
    required Map<String, String> uploadHeaders,
    required this.expiresAt,
    required this.maximumByteSize,
    required this.userQuotaBytes,
    required this.retainedVersionLimit,
  }) : uploadHeaders = Map<String, String>.unmodifiable(uploadHeaders);

  /// 从不可信统一响应 data 中解码上传会话。
  factory RemoteAccountBackupUpload.fromJson(
    Map<Object?, Object?> json, {
    required Uri baseUri,
  }) {
    final String backupId = _requiredBackupString(json, 'backupId');
    final String state = _requiredBackupString(json, 'state');
    if (state != 'UPLOADING' && state != 'READY') {
      throw const UnifiedHttpException(HttpFailureKind.decode, '备份上传状态无效');
    }
    final String? uploadId = _optionalBackupString(json, 'uploadId');
    final Uri? uploadUri;
    final Map<String, String> uploadHeaders;
    final DateTime? expiresAt;
    if (state == 'UPLOADING') {
      if (json['uploadMethod'] != 'PUT' || uploadId == null) {
        throw const UnifiedHttpException(HttpFailureKind.decode, '备份上传会话字段无效');
      }
      uploadUri = _decodeBackupTransferUri(
        json['uploadUrl'],
        baseUri: baseUri,
        fieldName: 'uploadUrl',
        requireSameOrigin: true,
      );
      uploadHeaders = _decodeBackupUploadHeaders(json['uploadHeaders']);
      expiresAt = _requiredBackupDateTime(json, 'expiresAt');
    } else {
      uploadUri = null;
      uploadHeaders = const <String, String>{};
      expiresAt = null;
    }
    final int? maximumByteSize = _optionalBackupInt(json, 'maximumByteSize');
    final int? userQuotaBytes = _optionalBackupInt(json, 'userQuotaBytes');
    final int? retainedVersionLimit =
        _optionalBackupInt(json, 'retainedVersionLimit');
    if ((maximumByteSize != null && maximumByteSize <= 0) ||
        (userQuotaBytes != null && userQuotaBytes < 0) ||
        (retainedVersionLimit != null && retainedVersionLimit <= 0)) {
      throw const UnifiedHttpException(HttpFailureKind.decode, '备份上传限制字段无效');
    }
    return RemoteAccountBackupUpload(
      uploadId: uploadId,
      backupId: backupId,
      state: state,
      uploadUri: uploadUri,
      uploadHeaders: uploadHeaders,
      expiresAt: expiresAt,
      maximumByteSize: maximumByteSize,
      userQuotaBytes: userQuotaBytes,
      retainedVersionLimit: retainedVersionLimit,
    );
  }

  /// 服务端上传会话标识；幂等命中 READY 时允许省略。
  final String? uploadId;

  /// 最终备份标识。
  final String backupId;

  /// `UPLOADING` 或 `READY`。
  final String state;

  /// 一次性二进制 PUT 地址；READY 时为空。
  final Uri? uploadUri;

  /// 只允许 Content-Type 与 X-Upload-Token 的上传 Header。
  final Map<String, String> uploadHeaders;

  /// 上传会话到期时间；READY 时为空。
  final DateTime? expiresAt;

  /// 服务端当前单文件上限。
  final int? maximumByteSize;

  /// 当前用户备份总配额。
  final int? userQuotaBytes;

  /// 服务端保留的历史版本数量。
  final int? retainedVersionLimit;
}

/// 服务端 READY 备份的安全元数据。
final class RemoteAccountBackupMetadata {
  /// 创建备份元数据。
  RemoteAccountBackupMetadata({
    required this.backupId,
    required this.state,
    required this.formatVersion,
    required this.byteSize,
    required this.sha256,
    required this.createdAt,
    required this.completedAt,
    required this.appVersionName,
    required this.appVersionCode,
    required this.databaseSchemaVersion,
    required this.platform,
    required Map<String, int> itemCounts,
  }) : itemCounts = Map<String, int>.unmodifiable(itemCounts);

  /// 从列表、latest 或完成接口的不同字段子集解码元数据。
  factory RemoteAccountBackupMetadata.fromJson(Map<Object?, Object?> json) {
    final String state = _optionalBackupString(json, 'state') ?? 'READY';
    if (state != 'READY') {
      throw const UnifiedHttpException(HttpFailureKind.decode, '备份元数据状态无效');
    }
    final int formatVersion = _requiredBackupInt(json, 'formatVersion');
    final int byteSize = _requiredBackupInt(json, 'byteSize');
    final String digest = _requiredBackupString(json, 'sha256');
    if (formatVersion != 1 || byteSize <= 0 || !_isSha256(digest)) {
      throw const UnifiedHttpException(HttpFailureKind.decode, '备份元数据完整性字段无效');
    }
    return RemoteAccountBackupMetadata(
      backupId: _requiredBackupString(json, 'backupId'),
      state: state,
      formatVersion: formatVersion,
      byteSize: byteSize,
      sha256: digest,
      createdAt: _optionalBackupDateTime(json, 'createdAt'),
      completedAt: _requiredBackupDateTime(json, 'completedAt'),
      appVersionName: _optionalBackupString(json, 'appVersionName'),
      appVersionCode: _optionalBackupInt(json, 'appVersionCode'),
      databaseSchemaVersion: _optionalBackupInt(json, 'databaseSchemaVersion'),
      platform: _optionalBackupString(json, 'platform'),
      itemCounts: _decodeBackupItemCounts(json['itemCounts']),
    );
  }

  /// 服务端备份标识。
  final String backupId;

  /// 固定为 READY。
  final String state;

  /// 客户端备份格式版本。
  final int formatVersion;

  /// 备份对象真实大小。
  final int byteSize;

  /// 备份对象 SHA-256。
  final String sha256;

  /// 客户端创建时间；latest 响应允许省略。
  final DateTime? createdAt;

  /// 服务端完成时间。
  final DateTime completedAt;

  /// 创建备份的应用版本名；部分响应允许省略。
  final String? appVersionName;

  /// 创建备份的应用构建号；部分响应允许省略。
  final int? appVersionCode;

  /// 创建备份时的数据库版本；部分响应允许省略。
  final int? databaseSchemaVersion;

  /// 创建备份的平台；部分响应允许省略。
  final String? platform;

  /// 服务端保存的数据集计数摘要。
  final Map<String, int> itemCounts;
}

/// 服务端备份游标分页结果。
final class RemoteAccountBackupPage {
  /// 创建严格解码后的分页结果。
  RemoteAccountBackupPage({
    required List<RemoteAccountBackupMetadata> items,
    required this.nextCursor,
    required this.hasMore,
    required this.totalReadyCount,
    required this.usedQuotaBytes,
    required this.userQuotaBytes,
  }) : items = List<RemoteAccountBackupMetadata>.unmodifiable(items);

  /// 从不可信列表响应解码分页结果。
  factory RemoteAccountBackupPage.fromJson(Map<Object?, Object?> json) {
    final Object? itemsValue = json['items'];
    if (itemsValue is! List<Object?> || json['hasMore'] is! bool) {
      throw const UnifiedHttpException(HttpFailureKind.decode, '备份分页字段无效');
    }
    final List<RemoteAccountBackupMetadata> items = <RemoteAccountBackupMetadata>[];
    for (final Object? itemValue in itemsValue) {
      if (itemValue is! Map<Object?, Object?>) {
        throw const UnifiedHttpException(HttpFailureKind.decode, '备份列表项目无效');
      }
      items.add(RemoteAccountBackupMetadata.fromJson(itemValue));
    }
    final String? nextCursor = _optionalBackupString(json, 'nextCursor');
    final bool hasMore = json['hasMore'] as bool;
    if (hasMore && nextCursor == null) {
      throw const UnifiedHttpException(HttpFailureKind.decode, '备份下一页游标缺失');
    }
    return RemoteAccountBackupPage(
      items: items,
      nextCursor: nextCursor,
      hasMore: hasMore,
      totalReadyCount: _requiredNonNegativeBackupInt(json, 'totalReadyCount'),
      usedQuotaBytes: _requiredNonNegativeBackupInt(json, 'usedQuotaBytes'),
      userQuotaBytes: _requiredNonNegativeBackupInt(json, 'userQuotaBytes'),
    );
  }

  /// 当前页备份。
  final List<RemoteAccountBackupMetadata> items;

  /// 下一页不透明游标。
  final String? nextCursor;

  /// 是否仍有下一页。
  final bool hasMore;

  /// 当前账号 READY 备份总数。
  final int totalReadyCount;

  /// 当前账号已用备份容量。
  final int usedQuotaBytes;

  /// 当前账号备份总配额。
  final int userQuotaBytes;
}

/// 服务端签发的短期备份下载凭据。
final class RemoteAccountBackupDownload {
  /// 创建经过地址和完整性校验的下载凭据。
  const RemoteAccountBackupDownload({
    required this.backupId,
    required this.downloadUri,
    required this.expiresAt,
    required this.byteSize,
    required this.sha256,
  });

  /// 从不可信下载地址响应解码短期凭据。
  factory RemoteAccountBackupDownload.fromJson(
    Map<Object?, Object?> json, {
    required Uri baseUri,
  }) {
    final int byteSize = _requiredBackupInt(json, 'byteSize');
    final String digest = _requiredBackupString(json, 'sha256');
    if (byteSize <= 0 || !_isSha256(digest)) {
      throw const UnifiedHttpException(HttpFailureKind.decode, '备份下载完整性字段无效');
    }
    return RemoteAccountBackupDownload(
      backupId: _requiredBackupString(json, 'backupId'),
      downloadUri: _decodeBackupTransferUri(
        json['downloadUrl'],
        baseUri: baseUri,
        fieldName: 'downloadUrl',
        requireSameOrigin: false,
      ),
      expiresAt: _requiredBackupDateTime(json, 'expiresAt'),
      byteSize: byteSize,
      sha256: digest,
    );
  }

  /// 服务端备份标识。
  final String backupId;

  /// 默认五分钟有效的只读地址。
  final Uri downloadUri;

  /// 下载地址到期时间。
  final DateTime expiresAt;

  /// 下载后必须匹配的字节数。
  final int byteSize;

  /// 下载后必须匹配的 SHA-256。
  final String sha256;
}

/// 读取必填非空字符串备份字段。
String _requiredBackupString(Map<Object?, Object?> json, String key) {
  final Object? value = json[key];
  if (value is! String || value.trim().isEmpty || value.length > 2048) {
    throw UnifiedHttpException(HttpFailureKind.decode, '备份字段 $key 无效');
  }
  return value.trim();
}

/// 读取可选非空字符串备份字段。
String? _optionalBackupString(Map<Object?, Object?> json, String key) {
  final Object? value = json[key];
  if (value == null) {
    return null;
  }
  if (value is! String || value.trim().isEmpty || value.length > 2048) {
    throw UnifiedHttpException(HttpFailureKind.decode, '备份字段 $key 无效');
  }
  return value.trim();
}

/// 读取必填整数备份字段。
int _requiredBackupInt(Map<Object?, Object?> json, String key) {
  final Object? value = json[key];
  if (value is! num || !value.isFinite || value.toInt() != value) {
    throw UnifiedHttpException(HttpFailureKind.decode, '备份字段 $key 无效');
  }
  return value.toInt();
}

/// 读取可选整数备份字段。
int? _optionalBackupInt(Map<Object?, Object?> json, String key) {
  if (json[key] == null) {
    return null;
  }
  return _requiredBackupInt(json, key);
}

/// 读取必填非负整数备份字段。
int _requiredNonNegativeBackupInt(Map<Object?, Object?> json, String key) {
  final int value = _requiredBackupInt(json, key);
  if (value < 0) {
    throw UnifiedHttpException(HttpFailureKind.decode, '备份字段 $key 无效');
  }
  return value;
}

/// 读取必填 ISO-8601 备份时间。
DateTime _requiredBackupDateTime(Map<Object?, Object?> json, String key) {
  final DateTime? value = _optionalBackupDateTime(json, key);
  if (value == null) {
    throw UnifiedHttpException(HttpFailureKind.decode, '备份字段 $key 无效');
  }
  return value;
}

/// 读取可选 ISO-8601 备份时间并统一转换为 UTC。
DateTime? _optionalBackupDateTime(Map<Object?, Object?> json, String key) {
  final String? source = _optionalBackupString(json, key);
  if (source == null) {
    return null;
  }
  final DateTime? value = DateTime.tryParse(source);
  if (value == null) {
    throw UnifiedHttpException(HttpFailureKind.decode, '备份字段 $key 无效');
  }
  return value.toUtc();
}

/// 解码只允许非负整数值的数据集数量摘要。
Map<String, int> _decodeBackupItemCounts(Object? value) {
  if (value == null) {
    return const <String, int>{};
  }
  if (value is! Map<Object?, Object?> || value.length > 32) {
    throw const UnifiedHttpException(HttpFailureKind.decode, '备份数据计数无效');
  }
  final Map<String, int> counts = <String, int>{};
  for (final MapEntry<Object?, Object?> entry in value.entries) {
    if (entry.key is! String || entry.value is! num) {
      throw const UnifiedHttpException(HttpFailureKind.decode, '备份数据计数无效');
    }
    final String key = entry.key as String;
    final num number = entry.value as num;
    if (key.isEmpty || key.length > 64 || !number.isFinite || number.toInt() != number || number < 0) {
      throw const UnifiedHttpException(HttpFailureKind.decode, '备份数据计数无效');
    }
    counts[key] = number.toInt();
  }
  return counts;
}

/// 解码服务端指定的二进制上传 Header，并拒绝任意额外凭据。
Map<String, String> _decodeBackupUploadHeaders(Object? value) {
  if (value is! Map<Object?, Object?>) {
    throw const UnifiedHttpException(HttpFailureKind.decode, '备份上传 Header 无效');
  }
  final Map<String, String> headers = <String, String>{};
  for (final MapEntry<Object?, Object?> entry in value.entries) {
    if (entry.key is! String || entry.value is! String) {
      throw const UnifiedHttpException(HttpFailureKind.decode, '备份上传 Header 无效');
    }
    final String key = entry.key as String;
    final String headerValue = entry.value as String;
    final String lowerKey = key.toLowerCase();
    if ((lowerKey != 'content-type' && lowerKey != 'x-upload-token') ||
        headerValue.isEmpty ||
        headerValue.length > 4096) {
      throw const UnifiedHttpException(HttpFailureKind.decode, '备份上传 Header 不受支持');
    }
    headers[key] = headerValue;
  }
  String? contentType;
  String? uploadToken;
  for (final MapEntry<String, String> entry in headers.entries) {
    if (entry.key.toLowerCase() == 'content-type') {
      contentType = entry.value;
    }
    if (entry.key.toLowerCase() == 'x-upload-token') {
      uploadToken = entry.value;
    }
  }
  if (contentType?.toLowerCase() != 'application/octet-stream' ||
      uploadToken == null ||
      uploadToken.isEmpty) {
    throw const UnifiedHttpException(HttpFailureKind.decode, '备份上传凭据缺失');
  }
  return headers;
}

/// 限制服务端下发的上传下载地址，HTTP 只允许回到当前配置主机。
Uri _decodeBackupTransferUri(
  Object? value, {
  required Uri baseUri,
  required String fieldName,
  required bool requireSameOrigin,
}) {
  if (value is! String || value.length > 4096) {
    throw UnifiedHttpException(HttpFailureKind.decode, '备份字段 $fieldName 无效');
  }
  final Uri? uri = Uri.tryParse(value);
  if (uri == null ||
      !uri.isAbsolute ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      (requireSameOrigin &&
          (uri.scheme != baseUri.scheme ||
              uri.host != baseUri.host ||
              uri.port != baseUri.port)) ||
      (!requireSameOrigin &&
          uri.scheme != 'https' &&
          !(uri.scheme == 'http' &&
              uri.host == baseUri.host &&
              uri.port == baseUri.port))) {
    throw UnifiedHttpException(HttpFailureKind.decode, '备份字段 $fieldName 地址无效');
  }
  return uri;
}

/// 判断字符串是否为 64 位小写 SHA-256 十六进制摘要。
bool _isSha256(String value) => RegExp(r'^[0-9a-f]{64}$').hasMatch(value);

/// 远端 App 业务失败的安全分类；不包含服务端原始正文。
enum RemoteAppBusinessFailureKind {
  /// 未进入白名单的业务失败。
  unknown,

  /// 请求缺少注册必填字段。
  missingField,

  /// 注册用户名长度不合法。
  invalidUsernameLength,

  /// 注册用户名包含不允许的字符。
  invalidUsernameCharacters,

  /// 旧后端无法细分长度和字符时返回的用户名规则失败。
  invalidUsername,

  /// 注册密码长度不合法。
  invalidPasswordLength,

  /// 邀请码格式不合法。
  invalidInvitationFormat,

  /// 邀请码不存在或不属于当前产品。
  invalidInvitation,

  /// 邀请码已经过期。
  expiredInvitation,

  /// 普通用户邀请码已经成功使用。
  usedInvitation,

  /// 旧后端无法细分无效和过期时返回的邀请码失败。
  invalidOrExpiredInvitation,

  /// 用户名在当前产品内重复。
  usernameConflict,

  /// 服务端无法解密密码密文。
  invalidEncryptedPassword,
}

/// 远端 App 的受控业务失败；仅保留状态、数字业务码和白名单分类。
final class RemoteAppBusinessException implements Exception {
  /// 创建不向 UI 暴露原始响应的业务异常。
  const RemoteAppBusinessException({
    required this.businessCode,
    required this.statusCode,
    required this.failureKind,
  });

  /// 后端统一响应信封中的机器可识别业务码。
  final int businessCode;
  /// 本次响应的 HTTP 状态；仅供数据层的受控判定使用。
  final int statusCode;
  /// 从稳定服务端标识转换出的安全失败分类。
  final RemoteAppBusinessFailureKind failureKind;
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

/// 管理员邀请码兑换得到的内存态游客书源会话。
final class RemoteGuestBookSourceSession {
  /// 创建严格解码后的游客书源会话。
  const RemoteGuestBookSourceSession({
    required this.guestToken,
    required this.expiresAt,
  });

  /// 最长一小时有效且只能访问游客书源分页接口的 Bearer 凭证。
  final String guestToken;

  /// 服务端声明的 UTC 失效时间。
  final DateTime expiresAt;
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
  const RemoteCrashReportReceipt({required this.receiptId, required this.retentionDays, required this.duplicate});

  /// 服务端回执标识。
  final String receiptId;

  /// 原始报告在服务端的保留天数。
  final int retentionDays;

  /// 本次请求是否命中服务端幂等去重。
  final bool duplicate;
}

final class RemoteAppBootstrapStatus {
  /// 创建准入与升级状态。
  const RemoteAppBootstrapStatus({required this.allowed, required this.hasUpdate, required this.forceUpdate, this.accessMessage, this.versionName, this.latestVersionCode, this.downloadUrl, this.downloadSha256, this.downloadByteSize, this.changelog});
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
  /// Android 服务端 APK 的小写 SHA-256；手动外链和 iOS TestFlight 为空。
  final String? downloadSha256;
  /// Android 服务端 APK 的精确字节数；手动外链和 iOS TestFlight 为空。
  final int? downloadByteSize;
  /// 服务端提供的版本更新说明。
  final String? changelog;
}
