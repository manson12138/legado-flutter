import 'package:flutter/foundation.dart';

import '../domain/model/app_account.dart';

/// 保存当前已认证用户的本地数据作用域，不持有密码、Access Token 或 Refresh Token。
///
/// 书架、阅读历史、搜索历史和下载附属数据必须通过此作用域取得用户 ID，
/// 避免同一设备的不同账号共用明确要求隔离的本地记录。
final class CurrentUserScope {
  /// 创建初始为空的当前用户作用域。
  CurrentUserScope();

  /// 当前已认证用户 ID；登出或未认证时为空。
  final ValueNotifier<int?> userId = ValueNotifier<int?>(null);

  /// 用户作用域切换代次；每次用户 ID 变化都递增，用于拒绝旧异步任务结果。
  int _generation = 0;

  /// 当前作用域代次，只用于比较任务是否仍属于当前用户，不包含认证凭据。
  int get generation => _generation;

  /// 用认证会话更新当前用户作用域；会话为空时立即清除旧用户 ID。
  void applySession(AppAuthenticationSession? session) {
    final int? nextUserId = session?.account.id;
    if (userId.value == nextUserId) {
      return;
    }
    _generation += 1;
    userId.value = nextUserId;
  }

  /// 返回当前有效用户 ID；未认证业务访问属于调用链错误，不能静默写入公共数据。
  int requireUserId() {
    final int? value = userId.value;
    if (value == null) {
      throw StateError('当前没有已认证用户，不能访问用户本地数据');
    }
    return value;
  }

  /// 核对异步任务捕获的用户与代次是否仍等于当前作用域。
  bool matches({
    required int expectedUserId,
    required int expectedGeneration,
  }) {
    return userId.value == expectedUserId &&
        _generation == expectedGeneration;
  }

  /// 释放用户 ID 通知器，避免应用组合根销毁后保留监听器。
  void dispose() {
    userId.dispose();
  }
}
