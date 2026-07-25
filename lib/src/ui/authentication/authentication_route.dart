import 'dart:async';
import 'dart:ui' show FlutterView;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_dependencies.dart';
import '../../domain/model/app_account.dart';
import '../../help/logging/app_logger.dart';
import '../components/app_scaffold.dart';
import 'authentication_view_model.dart';

/// 登录、注册和已登录账号资料的统一入口。
final class AuthenticationRoute extends StatefulWidget {
  /// 创建认证入口；嵌入模式用于阻止未登录用户访问业务页面。
  const AuthenticationRoute({
    required this.dependencies,
    this.embedded = false,
    this.inputEnabled = true,
    super.key,
  });

  /// 应用级依赖，用于创建认证 ViewModel。
  final AppDependencies dependencies;

  /// 是否作为根部认证门展示，嵌入时不允许返回业务路由。
  final bool embedded;

  /// 根部启动页完成认证输入就绪前为 `false`，此时表单不可获得焦点或提交。
  final bool inputEnabled;

  /// 创建认证入口状态。
  @override
  State<AuthenticationRoute> createState() => _AuthenticationRouteState();
}

/// 管理表单控制器、焦点和密码可见性的认证入口状态。
final class _AuthenticationRouteState extends State<AuthenticationRoute>
    with WidgetsBindingObserver {
  /// 登录与注册共用的账号输入控制器。
  final TextEditingController _usernameController = TextEditingController();

  /// 登录与注册共用的密码输入控制器。
  final TextEditingController _passwordController = TextEditingController();

  /// 注册时确认密码的输入控制器。
  final TextEditingController _confirmPasswordController =
      TextEditingController();

  /// 注册时邀请码的输入控制器。
  final TextEditingController _invitationCodeController =
      TextEditingController();

  /// 账号输入焦点，用于提交后定位无效内容。
  final FocusNode _usernameFocusNode = FocusNode();

  /// 密码输入焦点，用于提交后定位无效内容。
  final FocusNode _passwordFocusNode = FocusNode();

  /// 确认密码输入焦点。
  final FocusNode _confirmPasswordFocusNode = FocusNode();

  /// 邀请码输入焦点。
  final FocusNode _invitationCodeFocusNode = FocusNode();

  /// 表单校验与提交状态的锚点。
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  /// 当前认证操作的业务状态。
  late final AuthenticationViewModel _viewModel;

  /// 登录密码是否以明文显示。
  bool _isPasswordVisible = false;

  /// 确认密码是否以明文显示。
  bool _isConfirmPasswordVisible = false;

  /// 上一次已记录的软键盘可见性，避免同一状态的窗口度量变化重复写入日志。
  bool? _lastKeyboardVisible;

  /// 首次获取焦点后用于补发键盘请求的单次计时器，避免系统输入法尚未响应时首击无键盘。
  Timer? _keyboardFallbackTimer;

  /// 初始化认证 ViewModel，避免在 build 中重复订阅会话。
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _usernameFocusNode.addListener(_logInputFocusChanged);
    _passwordFocusNode.addListener(_logInputFocusChanged);
    _confirmPasswordFocusNode.addListener(_logInputFocusChanged);
    _invitationCodeFocusNode.addListener(_logInputFocusChanged);
    _viewModel = AuthenticationViewModel(widget.dependencies.authenticationGateway);
  }

  /// 释放所有输入和焦点资源，避免路由销毁后继续持有页面对象。
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _usernameFocusNode.removeListener(_logInputFocusChanged);
    _passwordFocusNode.removeListener(_logInputFocusChanged);
    _confirmPasswordFocusNode.removeListener(_logInputFocusChanged);
    _invitationCodeFocusNode.removeListener(_logInputFocusChanged);
    _keyboardFallbackTimer?.cancel();
    _viewModel.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _invitationCodeController.dispose();
    _usernameFocusNode.dispose();
    _passwordFocusNode.dispose();
    _confirmPasswordFocusNode.dispose();
    _invitationCodeFocusNode.dispose();
    super.dispose();
  }

  /// 记录软键盘展示或隐藏，帮助定位输入框焦点与系统输入法之间的时序问题。
  @override
  void didChangeMetrics() {
    final bool isKeyboardVisible =
        WidgetsBinding.instance.platformDispatcher.views.any(
      (FlutterView view) => view.viewInsets.bottom > 0,
    );
    if (_lastKeyboardVisible == isKeyboardVisible) {
      return;
    }
    _lastKeyboardVisible = isKeyboardVisible;
    widget.dependencies.logger.info(
      tag: authenticationLogTag,
      message: 'stage=keyboard_visibility_changed visible=$isKeyboardVisible',
    );
  }

  /// 根据认证状态构建表单或账号资料，并在根部模式禁止返回。
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<AuthenticationUiState>(
        valueListenable: _viewModel.state,
        builder: (BuildContext context, AuthenticationUiState state, Widget? child) {
          final Widget content = SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(24, 28, 24, 36),
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.manual,
                  children: <Widget>[
                    _buildBrand(context, state.session == null),
                    const SizedBox(height: 28),
                    if (state.session == null)
                      _buildCredentials(context, state)
                    else
                      _buildAccount(context, state),
                  ],
                ),
              ),
            ),
          );
          if (widget.embedded) {
            return PopScope(canPop: false, child: Material(child: content));
          }
          return AppScaffold(
            appBar: AppBar(title: const Text('账号与安全')),
            body: content,
          );
        },
      );

  /// 构建认证门与独立路由共用的品牌说明。
  Widget _buildBrand(BuildContext context, bool isUnauthenticated) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            Icons.auto_stories_rounded,
            size: 48,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 12),
          Text(
            isUnauthenticated ? '欢迎使用 Legado' : '账号与安全',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 8),
          Text(
            isUnauthenticated ? '登录后即可同步并使用书架、阅读与书源服务。' : '查看当前账号权限并管理邀请码。',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ],
      );

  /// 构建登录或注册表单，并避免在提交过程中触发重复请求。
  Widget _buildCredentials(BuildContext context, AuthenticationUiState state) {
    final bool isRegistering = state.formMode == AuthenticationFormMode.register;
    /// 输入交互由启动页就绪状态和认证请求状态共同决定，避免冷启动期间建立过早的输入连接。
    final bool isInputEnabled = widget.inputEnabled && !state.isSubmitting;
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SegmentedButton<AuthenticationFormMode>(
            segments: const <ButtonSegment<AuthenticationFormMode>>[
              ButtonSegment<AuthenticationFormMode>(
                value: AuthenticationFormMode.login,
                label: Text('登录'),
                icon: Icon(Icons.login_rounded),
              ),
              ButtonSegment<AuthenticationFormMode>(
                value: AuthenticationFormMode.register,
                label: Text('注册'),
                icon: Icon(Icons.person_add_alt_1_rounded),
              ),
            ],
            selected: <AuthenticationFormMode>{state.formMode},
            onSelectionChanged: !isInputEnabled
                ? null
                : (Set<AuthenticationFormMode> selection) {
                    final AuthenticationFormMode? formMode =
                        selection.isEmpty ? null : selection.first;
                    if (formMode == null) {
                      return;
                    }
                    _viewModel.changeFormMode(formMode);
                  },
          ),
          const SizedBox(height: 24),
          Text(
            isRegistering ? '使用邀请码创建账号' : '使用你的账号继续',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _usernameController,
            focusNode: _usernameFocusNode,
            enabled: isInputEnabled,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.next,
            autofillHints: const <String>[AutofillHints.username],
            onTap: () => _requestInputFocus(_usernameFocusNode),
            onTapOutside: (_) => _dismissKeyboard(),
            decoration: const InputDecoration(
              labelText: '账号',
              prefixIcon: Icon(Icons.person_outline_rounded),
            ),
            validator: _validateUsername,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _passwordController,
            focusNode: _passwordFocusNode,
            enabled: isInputEnabled,
            obscureText: !_isPasswordVisible,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: isRegistering ? TextInputAction.next : TextInputAction.done,
            autofillHints: isRegistering
                ? const <String>[AutofillHints.newPassword]
                : const <String>[AutofillHints.password],
            onTap: () => _requestInputFocus(_passwordFocusNode),
            onTapOutside: (_) => _dismissKeyboard(),
            decoration: InputDecoration(
              labelText: '密码',
              prefixIcon: const Icon(Icons.lock_outline_rounded),
              suffixIcon: IconButton(
                tooltip: _isPasswordVisible ? '隐藏密码' : '显示密码',
                onPressed: () {
                  setState(() {
                    _isPasswordVisible = !_isPasswordVisible;
                  });
                },
                icon: Icon(
                  _isPasswordVisible
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
              ),
            ),
            validator: _validatePassword,
            onFieldSubmitted: (_) {
              if (!isRegistering) {
                _submitCredentials();
              }
            },
          ),
          if (isRegistering) ...<Widget>[
            const SizedBox(height: 12),
            TextFormField(
              controller: _confirmPasswordController,
              focusNode: _confirmPasswordFocusNode,
              enabled: isInputEnabled,
              obscureText: !_isConfirmPasswordVisible,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.next,
              autofillHints: const <String>[AutofillHints.newPassword],
              onTap: () => _requestInputFocus(_confirmPasswordFocusNode),
              onTapOutside: (_) => _dismissKeyboard(),
              decoration: InputDecoration(
                labelText: '确认密码',
                prefixIcon: const Icon(Icons.lock_reset_outlined),
                suffixIcon: IconButton(
                  tooltip: _isConfirmPasswordVisible ? '隐藏密码' : '显示密码',
                  onPressed: () {
                    setState(() {
                      _isConfirmPasswordVisible = !_isConfirmPasswordVisible;
                    });
                  },
                  icon: Icon(
                    _isConfirmPasswordVisible
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                  ),
                ),
              ),
              validator: _validateConfirmPassword,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _invitationCodeController,
              focusNode: _invitationCodeFocusNode,
              enabled: isInputEnabled,
              autocorrect: false,
              enableSuggestions: false,
              textCapitalization: TextCapitalization.characters,
              textInputAction: TextInputAction.done,
              onTap: () => _requestInputFocus(_invitationCodeFocusNode),
              onTapOutside: (_) => _dismissKeyboard(),
              decoration: const InputDecoration(
                labelText: '邀请码',
                prefixIcon: Icon(Icons.key_outlined),
              ),
              validator: _validateInvitationCode,
              onFieldSubmitted: (_) => _submitCredentials(),
            ),
          ],
          if (state.message case final String message) ...<Widget>[
            const SizedBox(height: 16),
            _buildMessage(context, message, state.isError),
          ],
          const SizedBox(height: 24),
          FilledButton(
            onPressed: isInputEnabled ? _submitCredentials : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: state.isSubmitting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(isRegistering ? '创建账号' : '登录'),
            ),
          ),
        ],
      ),
    );
  }

  /// 构建不展示敏感内容的成功或失败反馈。
  Widget _buildMessage(BuildContext context, String message, bool isError) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final Color foreground = isError ? colorScheme.error : colorScheme.primary;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: foreground.withOpacity(0.10),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: <Widget>[
            Icon(isError ? Icons.error_outline_rounded : Icons.check_circle_outline_rounded, color: foreground),
            const SizedBox(width: 10),
            Expanded(child: Text(message, style: TextStyle(color: foreground))),
          ],
        ),
      ),
    );
  }

  /// 构建已登录账号的权限、邀请码和退出入口。
  Widget _buildAccount(BuildContext context, AuthenticationUiState state) {
    final AppAuthenticationSession? session = state.session;
    if (session == null) {
      return const SizedBox.shrink();
    }
    final DateTime? inviteAvailableAt = session.permissions.inviteAvailableAt;
    final String inviteAvailability = session.permissions.canGenerateInvite
        ? '可以生成邀请码'
        : inviteAvailableAt == null
            ? '暂不具备生成邀请码资格'
            : '邀请码资格开放时间：${inviteAvailableAt.toLocal()}';
    final AppInvitation? invitation = state.invitation;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(session.account.username, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Text('账号状态：${session.account.status} · 角色：${session.permissions.userRole}'),
                const SizedBox(height: 8),
                Text(session.permissions.canSyncBookSource ? '已获得服务器书源同步权限' : '暂未获得服务器书源同步权限'),
                const SizedBox(height: 8),
                Text(inviteAvailability),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: state.isSubmitting ? null : _viewModel.refreshPermissions,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('刷新权限'),
        ),
        if (session.permissions.canGenerateInvite) ...<Widget>[
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            onPressed: state.isSubmitting ? null : _viewModel.createInvitation,
            icon: const Icon(Icons.key_rounded),
            label: const Text('获取邀请码'),
          ),
        ],
        if (invitation != null) ...<Widget>[
          const SizedBox(height: 12),
          SelectableText('邀请码：${invitation.code}\n有效至：${invitation.expiresAt.toLocal()}'),
        ],
        if (state.message case final String message) ...<Widget>[
          const SizedBox(height: 16),
          _buildMessage(context, message, state.isError),
        ],
        const SizedBox(height: 24),
        TextButton.icon(
          onPressed: state.isSubmitting ? null : _viewModel.logout,
          icon: const Icon(Icons.logout_rounded),
          label: const Text('退出登录'),
        ),
      ],
    );
  }

  /// 校验账号输入，空白账号不会发送到认证接口。
  String? _validateUsername(String? value) {
    if ((value ?? '').trim().isEmpty) {
      return '请输入账号';
    }
    return null;
  }

  /// 校验密码输入，避免将空密码提交给服务端。
  String? _validatePassword(String? value) {
    if ((value ?? '').isEmpty) {
      return '请输入密码';
    }
    return null;
  }

  /// 校验两次密码保持一致。
  String? _validateConfirmPassword(String? value) {
    if ((value ?? '').isEmpty) {
      return '请再次输入密码';
    }
    if (value != _passwordController.text) {
      return '两次输入的密码不一致';
    }
    return null;
  }

  /// 校验邀请码输入，邀请码为空时不发起注册请求。
  String? _validateInvitationCode(String? value) {
    if ((value ?? '').trim().isEmpty) {
      return '请输入邀请码';
    }
    return null;
  }

  /// 确保触摸输入框时立即获得焦点，避免根部认证门的嵌入路由延迟软键盘展示。
  void _requestInputFocus(FocusNode focusNode) {
    if (!widget.inputEnabled) {
      return;
    }
    widget.dependencies.logger.info(
      tag: authenticationLogTag,
      message: 'stage=input_tapped field=${_inputFieldName(focusNode)} has_focus=${focusNode.hasFocus}',
    );
    if (!focusNode.hasFocus) {
      FocusScope.of(context).requestFocus(focusNode);
    }
  }

  /// 点击认证表单外的非输入区域时释放当前焦点并收起系统软键盘。
  void _dismissKeyboard() {
    _keyboardFallbackTimer?.cancel();
    final FocusNode? primaryFocus = FocusManager.instance.primaryFocus;
    if (primaryFocus == null || !primaryFocus.hasFocus) {
      return;
    }
    widget.dependencies.logger.info(
      tag: authenticationLogTag,
      message: 'stage=keyboard_dismiss_requested',
    );
    primaryFocus.unfocus();
  }

  /// 记录认证输入框焦点变化，不包含文本内容或任何认证凭据。
  void _logInputFocusChanged() {
    final String fieldName = _focusedInputFieldName();
    widget.dependencies.logger.info(
      tag: authenticationLogTag,
      message: 'stage=input_focus_changed field=$fieldName has_focus=${fieldName != 'none'}',
    );
    final FocusNode? focusedNode = _focusedInputNode();
    if (focusedNode == null) {
      _keyboardFallbackTimer?.cancel();
      return;
    }
    _scheduleKeyboardFallback(focusedNode);
  }

  /// 焦点建立后等待 100ms；系统键盘仍未出现时才补发一次受控显示请求。
  void _scheduleKeyboardFallback(FocusNode focusNode) {
    _keyboardFallbackTimer?.cancel();
    _keyboardFallbackTimer = Timer(const Duration(milliseconds: 100), () {
      if (!mounted || !focusNode.hasFocus || _isKeyboardVisible()) {
        return;
      }
      widget.dependencies.logger.info(
        tag: authenticationLogTag,
        message: 'stage=keyboard_fallback_requested field=${_inputFieldName(focusNode)}',
      );
      unawaited(
        SystemChannels.textInput.invokeMethod<void>('TextInput.show').catchError(
          (Object error) {
            widget.dependencies.logger.warning(
              tag: authenticationLogTag,
              message: 'stage=keyboard_fallback_degraded',
              error: error,
            );
          },
        ),
      );
    });
  }

  /// 读取当前任一 Flutter 视图的键盘 Insets，避免可见键盘上重复发送显示请求。
  bool _isKeyboardVisible() => WidgetsBinding.instance.platformDispatcher.views
      .any((FlutterView view) => view.viewInsets.bottom > 0);

  /// 返回当前拥有焦点的认证输入框；没有焦点时不安排键盘兜底任务。
  FocusNode? _focusedInputNode() {
    if (_usernameFocusNode.hasFocus) {
      return _usernameFocusNode;
    }
    if (_passwordFocusNode.hasFocus) {
      return _passwordFocusNode;
    }
    if (_confirmPasswordFocusNode.hasFocus) {
      return _confirmPasswordFocusNode;
    }
    if (_invitationCodeFocusNode.hasFocus) {
      return _invitationCodeFocusNode;
    }
    return null;
  }

  /// 返回当前触发监听的输入框；没有焦点时记录为 `none`，避免泄露输入文本。
  String _focusedInputFieldName() {
    if (_usernameFocusNode.hasFocus) {
      return 'username';
    }
    if (_passwordFocusNode.hasFocus) {
      return 'password';
    }
    if (_confirmPasswordFocusNode.hasFocus) {
      return 'confirm_password';
    }
    if (_invitationCodeFocusNode.hasFocus) {
      return 'invitation_code';
    }
    return 'none';
  }

  /// 将输入框焦点映射为固定诊断字段名，禁止把用户填写的内容写入日志。
  String _inputFieldName(FocusNode focusNode) {
    if (identical(focusNode, _usernameFocusNode)) {
      return 'username';
    }
    if (identical(focusNode, _passwordFocusNode)) {
      return 'password';
    }
    if (identical(focusNode, _confirmPasswordFocusNode)) {
      return 'confirm_password';
    }
    if (identical(focusNode, _invitationCodeFocusNode)) {
      return 'invitation_code';
    }
    return 'none';
  }

  /// 提交已通过本地表单校验的登录或注册请求。
  Future<void> _submitCredentials() async {
    if (!widget.inputEnabled) {
      return;
    }
    final FormState? formState = _formKey.currentState;
    if (formState == null || !formState.validate()) {
      return;
    }
    final AuthenticationUiState currentState = _viewModel.state.value;
    final String username = _usernameController.text.trim();
    final String password = _passwordController.text;
    if (currentState.formMode == AuthenticationFormMode.login) {
      await _viewModel.login(username: username, password: password);
      return;
    }
    final bool registered = await _viewModel.register(
      username: username,
      password: password,
      invitationCode: _invitationCodeController.text.trim(),
    );
    if (!mounted || !registered) {
      return;
    }
    _passwordController.clear();
    _confirmPasswordController.clear();
    _invitationCodeController.clear();
    _viewModel.changeFormMode(AuthenticationFormMode.login);
    _passwordFocusNode.requestFocus();
  }
}
