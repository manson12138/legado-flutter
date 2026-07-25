import 'package:flutter/foundation.dart';

import '../model/app_account.dart';

/// 启动时本地安全会话恢复的同步入口状态，不包含账号或 Token。
enum AuthenticationRestoreState {
  /// 本地没有可恢复会话。
  none,

  /// 已恢复未到刷新时刻的本地会话，后台仅校验权限。
  restored,

  /// 已恢复本地会话，后台需要刷新 Token。
  refreshRequired,
}

/// 本地会话恢复入口完成后立即可用的非敏感摘要。
final class AuthenticationRestoreStart {
  /// 创建恢复入口摘要。
  const AuthenticationRestoreStart({
    required this.state,
    required this.refreshAttempted,
  });

  /// 本地恢复状态。
  final AuthenticationRestoreState state;

  /// 后台校验是否会尝试刷新 Token。
  final bool refreshAttempted;
}

/// 后台远端校验的最终分类。
enum AuthenticationRestoreResultKind {
  /// 权限校验或 Token 刷新成功。
  success,

  /// 本地 Refresh Token 已过期。
  expired,

  /// 服务端明确拒绝当前会话。
  unauthorized,

  /// 网络不可用时保留未过期本地会话继续降级使用。
  networkDegraded,
}

/// 后台会话校验结束时发布的非敏感结果。
final class AuthenticationRestoreResult {
  /// 创建恢复结果摘要。
  const AuthenticationRestoreResult({
    required this.kind,
    required this.refreshAttempted,
  });

  /// 最终结果分类。
  final AuthenticationRestoreResultKind kind;

  /// 本轮是否尝试过刷新 Token。
  final bool refreshAttempted;
}

/// 认证提交失败的领域分类；不携带服务端正文、密码或其他认证凭据。
enum AuthenticationFailureKind {
  /// 注册请求缺少必填字段。
  missingField,

  /// 注册用户名长度不合法。
  invalidUsernameLength,

  /// 注册用户名包含不允许的字符。
  invalidUsernameCharacters,

  /// 旧服务端无法细分长度和字符时返回的用户名规则失败。
  invalidUsername,

  /// 注册密码长度不合法。
  invalidPasswordLength,

  /// 邀请码格式不合法。
  invalidInvitationFormat,

  /// 邀请码不存在或不属于当前产品。
  invalidInvitation,

  /// 邀请码已经过期。
  expiredInvitation,

  /// 普通用户邀请码已经被成功使用。
  usedInvitation,

  /// 旧服务端无法细分无效和过期时返回的邀请码失败。
  invalidOrExpiredInvitation,

  /// 用户名在当前产品内重复。
  usernameConflict,

  /// 密码加密准备或服务端密文解密失败。
  passwordSecurity,

  /// 无法解析服务器地址。
  dns,

  /// 无法与服务器建立连接。
  connection,

  /// TLS 安全连接失败。
  tls,

  /// 认证请求超时。
  timeout,

  /// 注册请求触发服务端频率限制。
  rateLimited,

  /// 服务端内部错误。
  server,

  /// 服务端响应格式或状态不符合契约。
  response,

  /// 未能安全细分的认证失败。
  unknown,
}

/// 认证领域的受控失败；仅保留 UI 可安全使用的分类和数字状态。
final class AuthenticationFailureException implements Exception {
  /// 创建不包含敏感数据的认证失败。
  const AuthenticationFailureException(
    this.kind, {
    this.businessCode,
    this.statusCode,
  });

  /// 认证失败分类。
  final AuthenticationFailureKind kind;

  /// 可选后端业务码；未知业务失败时用于提供可追踪反馈。
  final int? businessCode;

  /// 可选 HTTP 状态；不得从该值反推出或展示响应正文。
  final int? statusCode;

  @override
  String toString() =>
      'AuthenticationFailureException($kind, businessCode: $businessCode, statusCode: $statusCode)';
}

/// 定义注册、登录、会话和权限读取的领域边界。
abstract interface class AuthenticationGateway {
  /// 监听当前内存会话；`null` 代表未登录。
  ValueListenable<AppAuthenticationSession?> get session;
  /// 监听启动恢复的后台校验结果；没有可恢复会话时保持为空。
  ValueListenable<AuthenticationRestoreResult?> get restoreResult;
  /// 使用账号密码登录并刷新权限快照。
  Future<AppAuthenticationSession> login({required String username, required String password});
  /// 使用邀请码创建账号；不自动创建会话。
  Future<AppAccount> register({required String username, required String password, required String invitationCode});
  /// 刷新当前用户的权限快照。
  Future<AppAuthenticationSession> refreshPermissions();
  /// 从系统安全存储恢复上次未过期会话，并按服务端策略刷新或校验。
  Future<AuthenticationRestoreStart> restoreSession();
  /// 获取当前用户的邀请码。
  Future<AppInvitation> createInvitation();
  /// 清除内存会话和系统安全存储中的 token。
  Future<void> logout();
  /// 返回仅数据层可使用的当前 token；未登录时返回空。
  String? currentToken();
}
