import 'package:flutter/foundation.dart';

import '../../api/http/http_contract.dart';
import '../../api/remote_app/remote_app_api.dart';
import '../local/secure_auth_session_store.dart';
import '../../domain/gateway/authentication_gateway.dart';
import '../../domain/model/app_account.dart';
import '../../help/logging/app_logger.dart';
import '../../platform/password_encryption_platform_service.dart';

/// 负责把远端认证接口转换为受控会话；Token 仅使用系统安全存储持久化。
final class AuthenticationRepository implements AuthenticationGateway {
  /// 创建认证仓储。
  AuthenticationRepository(this._api, this._passwordEncryptionService, this._logger, this._sessionStore);
  /// 远端 App API。
  final RemoteAppApi _api;
  /// 系统密码学加密服务；只在提交前短暂接收明文密码。
  final PasswordEncryptionService _passwordEncryptionService;
  /// 登录诊断使用的统一日志器；仅记录流程阶段和受控错误，不记录认证数据。
  final AppLogger _logger;
  /// Token 生命周期的系统安全存储边界。
  final SecureAuthenticationSessionStore _sessionStore;
  /// 当前会话监听器；页面只能读取安全领域状态。
  final ValueNotifier<AppAuthenticationSession?> _session = ValueNotifier<AppAuthenticationSession?>(null);
  /// 仅本仓储持有的 Access Token。
  String? _accessToken;
  /// 当前内存 Access Token 的过期时刻。
  DateTime? _accessExpiresAt;
  /// 当前内存 Access Token 的建议刷新时刻。
  DateTime? _refreshAfter;
  /// 仅用于轮换和退出的 Refresh Token。
  String? _refreshToken;
  /// 当前 Refresh Token 的过期时刻。
  DateTime? _refreshExpiresAt;
  /// 防止启动与前台恢复并发覆盖最新会话的任务。
  Future<void>? _restoreTask;
  /// 内存中缓存的服务端公钥，应用退出即释放。
  RemotePasswordKey? _cachedPasswordKey;
  /// 当前公钥缓存的失效时间。
  DateTime? _passwordKeyExpiresAt;
  /// 公钥允许在内存中复用的最长时间。
  static const Duration _passwordKeyCacheDuration = Duration(minutes: 5);

  @override
  ValueListenable<AppAuthenticationSession?> get session => _session;

  @override
  Future<AppAuthenticationSession> login({required String username, required String password}) async {
    _logger.info(tag: remoteAppApiLogTag, message: 'stage=login_started');
    final RemoteAppLoginResult result = await _submitWithPasswordRetry(
      password,
      (String passwordEncrypted) => _api.loginWithProfile(username: username, passwordEncrypted: passwordEncrypted),
    );
    try {
      final AppAuthenticationSession session = _createSession(result.user, await _api.fetchAccountPermissions(result.accessToken));
      await _persistAndApply(result, session);
      _logger.info(tag: remoteAppApiLogTag, message: 'stage=login_succeeded');
      return session;
    } catch (error) {
      await _clearSession();
      _logger.warning(
        tag: remoteAppApiLogTag,
        message: 'stage=login_failed phase=permission_fetch',
        error: error,
      );
      rethrow;
    }
  }

  @override
  Future<AppAccount> register({required String username, required String password, required String invitationCode}) async {
    final RemoteAppUser user = await _submitWithPasswordRetry(
      password,
      (String passwordEncrypted) => _api.register(username: username, passwordEncrypted: passwordEncrypted, invitationCode: invitationCode),
    );
    return AppAccount(id: user.id, username: user.username, status: user.status);
  }

  @override
  Future<AppAuthenticationSession> refreshPermissions() async {
    final String token = _requireAccessToken();
    final AppAuthenticationSession? existing = _session.value;
    if (existing == null) { throw const FormatException('请先登录 App 账号'); }
    final AppAuthenticationSession refreshed = _createSession(
      RemoteAppUser(id: existing.account.id, username: existing.account.username, status: existing.account.status),
      await _api.fetchAccountPermissions(token),
    );
    final DateTime? accessExpiresAt = _accessExpiresAt;
    final DateTime? refreshAfter = _refreshAfter;
    final String? refreshToken = _refreshToken;
    final DateTime? refreshExpiresAt = _refreshExpiresAt;
    if (accessExpiresAt == null || refreshAfter == null || refreshToken == null || refreshExpiresAt == null) { throw const FormatException('登录会话期限无效'); }
    await _persistCurrent(accessToken: token, accessExpiresAt: accessExpiresAt, refreshAfter: refreshAfter, refreshToken: refreshToken, refreshExpiresAt: refreshExpiresAt, session: refreshed);
    _session.value = refreshed;
    return refreshed;
  }

  @override
  Future<void> restoreSession() {
    final Future<void>? existing = _restoreTask;
    if (existing != null) {
      return existing;
    }
    final Future<void> task = _restoreStoredSession();
    final Future<void> trackedTask = task.whenComplete(() { _restoreTask = null; });
    _restoreTask = trackedTask;
    return trackedTask;
  }

  @override
  Future<AppInvitation> createInvitation() async {
    final String token = _requireAccessToken();
    final AppAuthenticationSession? existing = _session.value;
    if (existing == null || !existing.permissions.canGenerateInvite) { throw const FormatException('当前账号暂时不能生成邀请码'); }
    final RemoteAppInvitation invitation = await _api.createInvitation(token);
    return AppInvitation(code: invitation.code, expiresAt: invitation.expiresAt);
  }

  @override
  Future<void> logout() async {
    final String? refreshToken = _refreshToken;
    if (refreshToken != null && refreshToken.isNotEmpty) {
      try {
        await _api.logoutWithRefreshToken(refreshToken);
      } on Object catch (error) {
        _logger.warning(tag: remoteAppApiLogTag, message: 'stage=session_logout_degraded', error: error);
      }
    }
    await _clearSession();
  }

  @override
  String? currentToken() => _accessToken;

  /// 恢复未过期的本地安全会话，并在需要时由服务端刷新或校验权限。
  Future<void> _restoreStoredSession() async {
    try {
      final StoredAuthenticationSession? stored = await _sessionStore.read();
      if (stored == null) { return; }
      final DateTime now = DateTime.now().toUtc();
      if (!now.isBefore(stored.refreshExpiresAt)) {
        await _clearSession();
        return;
      }
      _accessToken = stored.accessToken;
      _accessExpiresAt = stored.accessExpiresAt;
      _refreshAfter = stored.refreshAfter;
      _refreshToken = stored.refreshToken;
      _refreshExpiresAt = stored.refreshExpiresAt;
      _session.value = _sessionFromStored(stored);
      if (!now.isBefore(stored.accessExpiresAt) || !now.isBefore(stored.refreshAfter)) {
        await _refreshStoredToken(stored.refreshToken);
      } else {
        await _refreshRestoredPermissions(stored.accessToken);
      }
    } on Object catch (error) {
      if (_isUnauthorized(error)) {
        await _clearSession();
        return;
      }
      _logger.warning(tag: remoteAppApiLogTag, message: 'stage=session_restore_degraded reason=remote_unavailable', error: error);
    }
  }

  /// 刷新达到服务端建议时间的 Token，并以新记录替换旧记录。
  Future<void> _refreshStoredToken(String refreshToken) async {
    final RemoteAppLoginResult result = await _api.refreshLogin(refreshToken);
    final AppAuthenticationSession session = _createSession(result.user, await _api.fetchAccountPermissions(result.accessToken));
    await _persistAndApply(result, session);
    _logger.info(tag: remoteAppApiLogTag, message: 'stage=session_restored action=token_refreshed');
  }

  /// 未到刷新时刻时仅校验权限，避免不必要地换取 Token。
  Future<void> _refreshRestoredPermissions(String token) async {
    final AppAuthenticationSession? existing = _session.value;
    final DateTime? accessExpiresAt = _accessExpiresAt;
    final DateTime? refreshAfter = _refreshAfter;
    final String? refreshToken = _refreshToken;
    final DateTime? refreshExpiresAt = _refreshExpiresAt;
    if (existing == null || accessExpiresAt == null || refreshAfter == null || refreshToken == null || refreshExpiresAt == null) { return; }
    final AppAuthenticationSession session = _createSession(
      RemoteAppUser(id: existing.account.id, username: existing.account.username, status: existing.account.status),
      await _api.fetchAccountPermissions(token),
    );
    await _persistCurrent(accessToken: token, accessExpiresAt: accessExpiresAt, refreshAfter: refreshAfter, refreshToken: refreshToken, refreshExpiresAt: refreshExpiresAt, session: session);
    _session.value = session;
    _logger.info(tag: remoteAppApiLogTag, message: 'stage=session_restored action=permissions_refreshed');
  }

  /// 将新 Token、期限与会话完整写入安全存储后，再替换内存状态。
  Future<void> _persistAndApply(RemoteAppLoginResult result, AppAuthenticationSession session) async {
    await _persistCurrent(accessToken: result.accessToken, accessExpiresAt: result.accessExpiresAt, refreshAfter: result.refreshAfter, refreshToken: result.refreshToken, refreshExpiresAt: result.refreshExpiresAt, session: session);
    _accessToken = result.accessToken;
    _accessExpiresAt = result.accessExpiresAt;
    _refreshAfter = result.refreshAfter;
    _refreshToken = result.refreshToken;
    _refreshExpiresAt = result.refreshExpiresAt;
    _session.value = session;
  }

  /// 保存当前会话的最小恢复快照；不包含密码、公钥或任何日志文本。
  Future<void> _persistCurrent({required String accessToken, required DateTime accessExpiresAt, required DateTime refreshAfter, required String refreshToken, required DateTime refreshExpiresAt, required AppAuthenticationSession session}) => _sessionStore.write(
        StoredAuthenticationSession(
          accessToken: accessToken,
          accessExpiresAt: accessExpiresAt,
          refreshAfter: refreshAfter,
          refreshToken: refreshToken,
          refreshExpiresAt: refreshExpiresAt,
          userId: session.account.id,
          username: session.account.username,
          status: session.account.status,
          userRole: session.permissions.userRole,
          canGenerateInvite: session.permissions.canGenerateInvite,
          canSyncBookSource: session.permissions.canSyncBookSource,
          inviteAvailableAt: session.permissions.inviteAvailableAt,
        ),
      );

  /// 把安全存储的受控字段还原为 UI 可观察但不含 Token 的领域会话。
  AppAuthenticationSession _sessionFromStored(StoredAuthenticationSession stored) => AppAuthenticationSession(
        account: AppAccount(id: stored.userId, username: stored.username, status: stored.status),
        permissions: AppAccountPermissions(userRole: stored.userRole, canGenerateInvite: stored.canGenerateInvite, canSyncBookSource: stored.canSyncBookSource, inviteAvailableAt: stored.inviteAvailableAt),
      );

  /// 判断服务端明确拒绝当前会话时必须清理本地凭据。
  bool _isUnauthorized(Object error) =>
      error is RemoteAppBusinessException && error.statusCode == 401 ||
      error is UnifiedHttpException && error.statusCode == 401;

  /// 无论安全存储删除是否成功，都先停止在内存中使用旧 Token。
  Future<void> _clearSession() async {
    _accessToken = null;
    _accessExpiresAt = null;
    _refreshAfter = null;
    _refreshToken = null;
    _refreshExpiresAt = null;
    _session.value = null;
    try {
      await _sessionStore.clear();
    } on Object catch (error) {
      _logger.warning(tag: remoteAppApiLogTag, message: 'stage=session_clear_degraded', error: error);
    }
  }

  /// 使用本次公钥加密并提交；只有后端明确的密钥失效码允许重新取钥和重试一次。
  Future<T> _submitWithPasswordRetry<T>(String password, Future<T> Function(String passwordEncrypted) submit) async {
    _EncryptedPassword encryptedPassword = await _encryptPassword(password);
    try {
      return await submit(encryptedPassword.value);
    } catch (error) {
      if (!_api.isPasswordKeyInvalidError(error)) {
        _logger.warning(
          tag: remoteAppApiLogTag,
          message: 'stage=login_failed phase=credential_submit',
          error: error,
        );
        rethrow;
      }
      _logger.info(tag: remoteAppApiLogTag, message: 'stage=login_password_key_retry');
      _clearPasswordKeyIfMatches(encryptedPassword.keyId);
      encryptedPassword = await _encryptPassword(password);
      try {
        return await submit(encryptedPassword.value);
      } catch (retryError) {
        _logger.warning(
          tag: remoteAppApiLogTag,
          message: 'stage=login_failed phase=credential_submit_retry',
          error: retryError,
        );
        rethrow;
      }
    }
  }

  /// 读取短期缓存的公钥，并将明文仅交给原生系统密码学实现以生成本次密文。
  Future<_EncryptedPassword> _encryptPassword(String password) async {
    try {
      final RemotePasswordKey passwordKey = await _loadPasswordKey();
      final String encrypted = await _passwordEncryptionService.encryptRsaOaepSha256(
        publicKeyPem: passwordKey.publicKey,
        password: password,
      );
      return _EncryptedPassword(keyId: passwordKey.keyId, value: encrypted);
    } on UnifiedHttpException catch (error) {
      if (error.kind == HttpFailureKind.decode) {
        throw const FormatException('密码安全处理失败，请重试');
      }
      rethrow;
    } catch (error) {
      _logger.warning(
        tag: remoteAppApiLogTag,
        message: 'stage=login_failed phase=password_encrypt',
        error: error,
      );
      rethrow;
    }
  }

  /// 仅在内存中按有效期复用当前 keyId 对应公钥，避免重复网络请求和长期留存。
  Future<RemotePasswordKey> _loadPasswordKey() async {
    final RemotePasswordKey? cachedPasswordKey = _cachedPasswordKey;
    final DateTime? expiresAt = _passwordKeyExpiresAt;
    if (cachedPasswordKey != null && expiresAt != null && DateTime.now().isBefore(expiresAt)) {
      return cachedPasswordKey;
    }
    try {
      _logger.info(tag: remoteAppApiLogTag, message: 'stage=login_password_key_fetch_started');
      final RemotePasswordKey fetchedPasswordKey = await _api.fetchPasswordKey();
      _cachedPasswordKey = fetchedPasswordKey;
      _passwordKeyExpiresAt = DateTime.now().add(_passwordKeyCacheDuration);
      return fetchedPasswordKey;
    } catch (error) {
      _logger.warning(
        tag: remoteAppApiLogTag,
        message: 'stage=login_failed phase=password_key_fetch',
        error: error,
      );
      rethrow;
    }
  }

  /// 只清除触发密钥失效的同一 keyId，避免并发提交错误丢弃新获取的公钥。
  void _clearPasswordKeyIfMatches(String keyId) {
    final RemotePasswordKey? cachedPasswordKey = _cachedPasswordKey;
    if (cachedPasswordKey == null || cachedPasswordKey.keyId != keyId) {
      return;
    }
    _cachedPasswordKey = null;
    _passwordKeyExpiresAt = null;
  }

  /// 将远端资料和权限映射成不可变领域会话。
  AppAuthenticationSession _createSession(RemoteAppUser user, RemoteAppAccountPermissions permissions) => AppAuthenticationSession(
    account: AppAccount(id: user.id, username: user.username, status: user.status),
    permissions: AppAccountPermissions(userRole: permissions.userRole, canGenerateInvite: permissions.canGenerateInvite, canSyncBookSource: permissions.canSyncBookSource, inviteAvailableAt: permissions.inviteAvailableAt),
  );

  /// 确保当前调用拥有内存 token。
  String _requireAccessToken() {
    final String? token = _accessToken;
    if (token == null || token.isEmpty) { throw const FormatException('请先登录 App 账号'); }
    return token;
  }
}

/// 单次认证提交使用的内存密文及其来源 keyId；不得持久化或写入日志。
final class _EncryptedPassword {
  /// 创建一次性密码密文记录。
  const _EncryptedPassword({required this.keyId, required this.value});

  /// 生成本密文的服务端公钥标识，用于精确失效缓存。
  final String keyId;
  /// 仅在当前提交调用栈短暂存在的 Base64 密文。
  final String value;
}
