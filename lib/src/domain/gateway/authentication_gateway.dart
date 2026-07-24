import 'package:flutter/foundation.dart';

import '../model/app_account.dart';

/// 定义注册、登录、会话和权限读取的领域边界。
abstract interface class AuthenticationGateway {
  /// 监听当前内存会话；`null` 代表未登录。
  ValueListenable<AppAuthenticationSession?> get session;
  /// 使用账号密码登录并刷新权限快照。
  Future<AppAuthenticationSession> login({required String username, required String password});
  /// 使用邀请码创建账号；不自动创建会话。
  Future<AppAccount> register({required String username, required String password, required String invitationCode});
  /// 刷新当前用户的权限快照。
  Future<AppAuthenticationSession> refreshPermissions();
  /// 从系统安全存储恢复上次未过期会话，并按服务端策略刷新或校验。
  Future<void> restoreSession();
  /// 获取当前用户的邀请码。
  Future<AppInvitation> createInvitation();
  /// 清除内存会话和系统安全存储中的 token。
  Future<void> logout();
  /// 返回仅数据层可使用的当前 token；未登录时返回空。
  String? currentToken();
}
