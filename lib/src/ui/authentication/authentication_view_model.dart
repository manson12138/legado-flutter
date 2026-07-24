import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../domain/gateway/authentication_gateway.dart';
import '../../domain/model/app_account.dart';

/// 认证表单当前展示的操作模式。
enum AuthenticationFormMode {
  /// 使用已有账号建立会话。
  login,

  /// 使用邀请码创建新账号。
  register,
}

/// 认证页面的不变状态；不保存密码和 Token。
final class AuthenticationUiState {
  /// 创建认证页面状态。
  const AuthenticationUiState({
    this.session,
    this.invitation,
    this.formMode = AuthenticationFormMode.login,
    this.isSubmitting = false,
    this.message,
    this.isError = false,
  });

  /// 当前内存会话；为空表示尚未登录。
  final AppAuthenticationSession? session;

  /// 当前会话生成的邀请码；离开页面即可丢弃。
  final AppInvitation? invitation;

  /// 当前显示登录还是注册表单。
  final AuthenticationFormMode formMode;

  /// 是否正在提交网络请求。
  final bool isSubmitting;

  /// 仅供 UI 展示的受控提示，不包含服务端响应原文。
  final String? message;

  /// 当前提示是否为失败反馈。
  final bool isError;
}

/// 编排登录、注册、权限刷新和邀请码操作的认证 ViewModel。
final class AuthenticationViewModel {
  /// 创建认证 ViewModel 并订阅现有内存会话。
  AuthenticationViewModel(this._gateway) {
    _gateway.session.addListener(_onSessionChanged);
    _state.value = AuthenticationUiState(session: _gateway.session.value);
  }

  /// 认证领域边界。
  final AuthenticationGateway _gateway;

  /// 向 Route 发布不可变认证状态。
  final ValueNotifier<AuthenticationUiState> _state =
      ValueNotifier<AuthenticationUiState>(const AuthenticationUiState());

  /// 当前可渲染状态。
  ValueListenable<AuthenticationUiState> get state => _state;

  /// 切换登录或注册表单，并清除上一次操作提示。
  void changeFormMode(AuthenticationFormMode formMode) {
    if (_state.value.isSubmitting || _state.value.formMode == formMode) {
      return;
    }
    _publish(formMode: formMode);
  }

  /// 登录并刷新服务端权限；返回值表示请求是否成功。
  Future<bool> login({required String username, required String password}) =>
      _submit(
        () async {
          await _gateway.login(username: username, password: password);
        },
        successMessage: '登录成功',
      );

  /// 使用邀请码注册；成功后保持未登录并引导用户登录。
  Future<bool> register({
    required String username,
    required String password,
    required String invitationCode,
  }) =>
      _submit(
        () async {
          await _gateway.register(
            username: username,
            password: password,
            invitationCode: invitationCode,
          );
        },
        successMessage: '注册成功，请使用新账号登录',
      );

  /// 刷新当前会话的服务端权限。
  Future<bool> refreshPermissions() => _submit(
        () async {
          await _gateway.refreshPermissions();
        },
        successMessage: '账号权限已刷新',
      );

  /// 获取当前用户的邀请码。
  Future<bool> createInvitation() => _submit(
        () async {
          final AppInvitation invitation = await _gateway.createInvitation();
          _publish(invitation: invitation, keepMessage: true);
        },
      );

  /// 退出登录并清除本地安全会话。
  Future<void> logout() async {
    if (_state.value.isSubmitting) {
      return;
    }
    _publish(isSubmitting: true);
    try {
      await _gateway.logout();
      _publish(message: '已退出登录');
    } catch (_) {
      _publish(message: '退出登录失败，请稍后重试', isError: true);
    }
  }

  /// 释放会话监听与状态通知器。
  void dispose() {
    _gateway.session.removeListener(_onSessionChanged);
    _state.dispose();
  }

  /// 会话被其他入口更新时同步页面，避免账户资料显示过期。
  void _onSessionChanged() {
    _publish(keepMessage: true);
  }

  /// 执行异步认证操作并映射为不包含敏感信息的页面状态。
  Future<bool> _submit(
    Future<void> Function() action, {
    String? successMessage,
  }) async {
    if (_state.value.isSubmitting) {
      return false;
    }
    _publish(isSubmitting: true);
    try {
      await action();
      _publish(message: successMessage);
      return true;
    } on FormatException {
      _publish(message: '输入内容不符合要求，请检查后重试', isError: true);
      return false;
    } catch (_) {
      _publish(message: '请求失败，请检查网络与输入后重试', isError: true);
      return false;
    }
  }

  /// 统一派发新状态，避免遗漏会话、表单模式或邀请码。
  void _publish({
    AppInvitation? invitation,
    AuthenticationFormMode? formMode,
    bool? isSubmitting,
    String? message,
    bool isError = false,
    bool keepMessage = false,
  }) {
    final AuthenticationUiState previous = _state.value;
    _state.value = AuthenticationUiState(
      session: _gateway.session.value,
      invitation: invitation ?? previous.invitation,
      formMode: formMode ?? previous.formMode,
      isSubmitting: isSubmitting ?? false,
      message: keepMessage ? previous.message : message,
      isError: keepMessage ? previous.isError : isError,
    );
  }
}
