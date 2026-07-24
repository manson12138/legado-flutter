/// 认证领域使用的当前 App 用户资料。
final class AppAccount {
  /// 创建 App 用户资料。
  const AppAccount({required this.id, required this.username, required this.status});
  /// 服务端用户标识。
  final int id;
  /// 当前用户显示名称。
  final String username;
  /// 服务端账号状态。
  final String status;
}

/// 服务端返回的账号权限，不把远端 DTO 传递到 UI。
final class AppAccountPermissions {
  /// 创建账号权限快照。
  const AppAccountPermissions({required this.userRole, required this.canGenerateInvite, required this.canSyncBookSource, this.inviteAvailableAt});
  /// 当前账号角色。
  final String userRole;
  /// 当前账号能否获取邀请码。
  final bool canGenerateInvite;
  /// 当前账号能否同步服务端书源。
  final bool canSyncBookSource;
  /// 未达到邀请资格时的开放时间。
  final DateTime? inviteAvailableAt;
}

/// 仅驻留内存的认证会话；token 不暴露给 UI。
final class AppAuthenticationSession {
  /// 创建当前认证会话。
  const AppAuthenticationSession({required this.account, required this.permissions});
  /// 已登录账号资料。
  final AppAccount account;
  /// 本次会话的权限快照。
  final AppAccountPermissions permissions;
}

/// 当前用户生成的邀请码。
final class AppInvitation {
  /// 创建邀请码领域结果。
  const AppInvitation({required this.code, required this.expiresAt});
  /// 仅供当前用户转交的邀请码文本。
  final String code;
  /// 过期时间。
  final DateTime expiresAt;
}
