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
