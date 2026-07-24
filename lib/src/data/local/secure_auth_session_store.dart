import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 仅用于安全存储的会话原始记录；禁止向 UI、日志或普通缓存暴露 token。
final class StoredAuthenticationSession {
  /// 创建已验证字段的安全会话记录。
  const StoredAuthenticationSession({
    required this.accessToken,
    required this.accessExpiresAt,
    required this.refreshAfter,
    required this.refreshToken,
    required this.refreshExpiresAt,
    required this.userId,
    required this.username,
    required this.status,
    required this.userRole,
    required this.canGenerateInvite,
    required this.canSyncBookSource,
    this.inviteAvailableAt,
  });

  /// Bearer 业务接口使用的 Access Token。
  final String accessToken;
  /// 服务端声明的 Access Token 过期时刻。
  final DateTime accessExpiresAt;
  /// 服务端建议刷新的最早时刻。
  final DateTime refreshAfter;
  /// 仅用于刷新与退出的 Refresh Token。
  final String refreshToken;
  /// 服务端声明的 Refresh Token 过期时刻。
  final DateTime refreshExpiresAt;
  /// 当前用户标识。
  final int userId;
  /// 当前用户显示名。
  final String username;
  /// 当前账号状态。
  final String status;
  /// 当前角色。
  final String userRole;
  /// 是否可生成邀请码。
  final bool canGenerateInvite;
  /// 是否可同步书源。
  final bool canSyncBookSource;
  /// 邀请资格开放时间。
  final DateTime? inviteAvailableAt;
}

/// Android Keystore 与 iOS Keychain 的认证会话读写边界。
final class SecureAuthenticationSessionStore {
  /// 创建系统安全存储会话仓储。
  SecureAuthenticationSessionStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  /// 安全存储实现。
  final FlutterSecureStorage _storage;

  /// 当前 App 唯一会话记录的固定键名。
  static const String _sessionKey = 'legado_remote_app_auth_session_v1';

  /// 读取并严格校验已持久化会话；损坏数据会被删除后按未登录处理。
  Future<StoredAuthenticationSession?> read() async {
    final String? raw = await _storage.read(key: _sessionKey);
    if (raw == null || raw.isEmpty) {
      return null;
    }
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map<Object?, Object?>) {
        throw const FormatException('安全会话根对象无效');
      }
      final Object? accessTokenValue = decoded['accessToken'];
      final Object? accessExpiresValue = decoded['accessExpiresAt'];
      final Object? refreshValue = decoded['refreshAfter'];
      final Object? refreshTokenValue = decoded['refreshToken'];
      final Object? refreshExpiresValue = decoded['refreshExpiresAt'];
      final Object? userValue = decoded['user'];
      final Object? permissionsValue = decoded['permissions'];
      final String? accessToken = accessTokenValue is String ? accessTokenValue : null;
      final String? accessExpiresRaw = accessExpiresValue is String ? accessExpiresValue : null;
      final String? refreshRaw = refreshValue is String ? refreshValue : null;
      final String? refreshToken = refreshTokenValue is String ? refreshTokenValue : null;
      final String? refreshExpiresRaw = refreshExpiresValue is String ? refreshExpiresValue : null;
      final Map<Object?, Object?>? user = userValue is Map<Object?, Object?> ? userValue : null;
      final Map<Object?, Object?>? permissions = permissionsValue is Map<Object?, Object?> ? permissionsValue : null;
      final DateTime? accessExpiresAt = accessExpiresRaw == null ? null : DateTime.tryParse(accessExpiresRaw)?.toUtc();
      final DateTime? refreshAfter = refreshRaw == null ? null : DateTime.tryParse(refreshRaw)?.toUtc();
      final DateTime? refreshExpiresAt = refreshExpiresRaw == null ? null : DateTime.tryParse(refreshExpiresRaw)?.toUtc();
      final DateTime? inviteAvailableAt = permissions?['inviteAvailableAt'] is String
          ? DateTime.tryParse(permissions?['inviteAvailableAt'] as String)?.toUtc()
          : null;
      if (accessToken == null || accessToken.isEmpty || accessExpiresAt == null || refreshAfter == null ||
          refreshToken == null || refreshToken.isEmpty || refreshExpiresAt == null ||
          user?['id'] is! num || user?['username'] is! String || user?['status'] is! String ||
          permissions?['userRole'] is! String || permissions?['canGenerateInvite'] is! bool ||
          permissions?['canSyncBookSource'] is! bool) {
        throw const FormatException('安全会话字段无效');
      }
      return StoredAuthenticationSession(
        accessToken: accessToken,
        accessExpiresAt: accessExpiresAt,
        refreshAfter: refreshAfter,
        refreshToken: refreshToken,
        refreshExpiresAt: refreshExpiresAt,
        userId: (user?['id'] as num).toInt(),
        username: user?['username'] as String,
        status: user?['status'] as String,
        userRole: permissions?['userRole'] as String,
        canGenerateInvite: permissions?['canGenerateInvite'] as bool,
        canSyncBookSource: permissions?['canSyncBookSource'] as bool,
        inviteAvailableAt: inviteAvailableAt,
      );
    } on FormatException {
      await clear();
      return null;
    }
  }

  /// 原子替换整个会话记录，避免 Token 生命周期字段分散写入。
  Future<void> write(StoredAuthenticationSession session) => _storage.write(
        key: _sessionKey,
        value: jsonEncode(<String, Object?>{
          'accessToken': session.accessToken,
          'accessExpiresAt': session.accessExpiresAt.toUtc().toIso8601String(),
          'refreshAfter': session.refreshAfter.toUtc().toIso8601String(),
          'refreshToken': session.refreshToken,
          'refreshExpiresAt': session.refreshExpiresAt.toUtc().toIso8601String(),
          'user': <String, Object?>{'id': session.userId, 'username': session.username, 'status': session.status},
          'permissions': <String, Object?>{
            'userRole': session.userRole,
            'canGenerateInvite': session.canGenerateInvite,
            'canSyncBookSource': session.canSyncBookSource,
            'inviteAvailableAt': session.inviteAvailableAt?.toUtc().toIso8601String(),
          },
        }),
      );

  /// 删除本地会话；用户退出、Token 过期与服务端 401 均调用此方法。
  Future<void> clear() => _storage.delete(key: _sessionKey);
}
