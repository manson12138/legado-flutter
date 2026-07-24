import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../ui/theme/app_theme.dart';
import '../ui/authentication/authentication_route.dart';
import 'app_dependencies.dart';
import 'app_access_coordinator.dart';
import 'app_error_boundary.dart';
import 'app_navigation_observer.dart';
import 'app_route.dart';
import 'app_router.dart';

/// Flutter 应用组合根，统一连接依赖、主题、路由和全局错误边界。
final class LegadoApp extends StatefulWidget {
  /// 创建应用组合根。
  const LegadoApp({required this.dependencies, super.key});

  /// 启动阶段组装完成的应用级依赖。
  final AppDependencies dependencies;

  /// 创建保存应用主题模式的组合根状态。
  @override
  State<LegadoApp> createState() => _LegadoAppState();
}

/// 保存当前会话主题模式，并把修改能力向“我的”页面传递。
final class _LegadoAppState extends State<LegadoApp> with WidgetsBindingObserver {
  /// 当前主题模式监听器，首次启动默认跟随系统，并向已保留的一级页面同步变化。
  final ValueNotifier<ThemeMode> _themeModeNotifier = ValueNotifier<ThemeMode>(
    ThemeMode.system,
  );

  /// 标记安全会话是否正在从持久化存储恢复，期间不展示业务路由。
  final ValueNotifier<bool> _isRestoringAuthentication = ValueNotifier<bool>(true);

  /// 启动期书源导入和下载恢复的可见状态，确保耗时初始化不再暴露为系统白屏。
  final ValueNotifier<_AppStartupState> _startupState =
      ValueNotifier<_AppStartupState>(const _AppStartupLoading());

  /// 首帧后启动前台准入轮询，避免在 build 中发起网络请求。
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      unawaited(_initializeStartup());
    });
  }

  /// 回到前台后检查安全会话的刷新时间；仓储会抑制并发恢复任务。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_restoreAuthenticationSession());
    }
  }

  /// 修改当前会话主题，并触发整个应用重新应用颜色方案。
  void _changeThemeMode(ThemeMode mode) {
    if (_themeModeNotifier.value == mode) {
      return;
    }
    setState(() {
      _themeModeNotifier.value = mode;
    });
  }

  /// 释放主题监听器，避免应用组合根销毁后保留监听资源。
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.dependencies.appAccessCoordinator.dispose();
    _themeModeNotifier.dispose();
    _isRestoringAuthentication.dispose();
    _startupState.dispose();
    super.dispose();
  }

  /// 构建只包含应用级装配职责的 MaterialApp。
  @override
  Widget build(BuildContext context) {
    /// 路由器通过构造参数获得依赖，并在页面入口继续向下传递。
    final AppRouter router = AppRouter(
      dependencies: widget.dependencies,
      themeModeListenable: _themeModeNotifier,
      onChangeThemeMode: _changeThemeMode,
    );
    /// 全局路由观察器，统一记录所有 Navigator 页面跳转。
    final AppNavigationObserver navigationObserver = AppNavigationObserver(
      logger: widget.dependencies.logger,
    );
    return MaterialApp(
      title: 'Legado Flutter',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: _themeModeNotifier.value,
      initialRoute: AppRoute.welcome,
      onGenerateRoute: router.onGenerateRoute,
      navigatorObservers: <NavigatorObserver>[navigationObserver],
      builder: (BuildContext context, Widget? child) {
        /// 透明系统导航栏可以让 edge-to-edge 内容在其后完整显示，因此每个页面
        /// 底部会自动露出该页面自身的背景色，不需要逐页手动同步导航栏颜色。
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: _systemOverlayStyleFor(Theme.of(context).brightness),
          child: _AppStartupOverlay(
            startupState: _startupState,
            onRetry: _retryStartup,
            child: _AppAccessOverlay(
              coordinator: widget.dependencies.appAccessCoordinator,
              dependencies: widget.dependencies,
              isRestoringAuthentication: _isRestoringAuthentication,
              child: AppErrorBoundary(child: child),
            ),
          ),
        );
      },
    );
  }

  /// 根据当前生效主题亮度生成透明系统栏样式，避免系统默认的导航栏黑色对比度保护层。
  SystemUiOverlayStyle _systemOverlayStyleFor(Brightness brightness) {
    final bool isDark = brightness == Brightness.dark;
    return SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
      systemNavigationBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      systemNavigationBarContrastEnforced: false,
    );
  }

  /// 在首帧渲染后串行执行启动数据库工作，再启用依赖同一连接的后台服务。
  Future<void> _initializeStartup() async {
    if (_startupState.value is _AppStartupLoading) {
      try {
        await widget.dependencies.defaultBookSourceBootstrapper.importIfEmpty();
        if (mounted) {
          _startupState.value = const _AppStartupReady();
        }
      } on Object catch (error) {
        if (mounted) {
          _startupState.value = _AppStartupFailed(error.toString());
        }
        return;
      }
    }
    await widget.dependencies.downloadCoordinator.start();
    if (!mounted) {
      return;
    }
    widget.dependencies.appAccessCoordinator.start();
    unawaited(_restoreAuthenticationSession());
  }

  /// 将失败的启动导入重新置为加载态，并复用同一条受控初始化链路。
  void _retryStartup() {
    if (_startupState.value is _AppStartupLoading) {
      return;
    }
    _startupState.value = const _AppStartupLoading();
    unawaited(_initializeStartup());
  }

  /// 恢复或刷新持久化安全会话，并在完成前保持认证门覆盖业务页面。
  Future<void> _restoreAuthenticationSession() async {
    if (!_isRestoringAuthentication.value) {
      _isRestoringAuthentication.value = true;
    }
    try {
      await widget.dependencies.authenticationGateway.restoreSession();
    } finally {
      if (mounted) {
        _isRestoringAuthentication.value = false;
      }
    }
  }
}

/// 根页面启动期的不可变可见状态，避免业务路由在基础数据尚未完成准备时暴露出来。
sealed class _AppStartupState {
  /// 创建启动状态。
  const _AppStartupState();
}

/// 表示内置书源正在导入的启动状态。
final class _AppStartupLoading extends _AppStartupState {
  /// 创建加载状态。
  const _AppStartupLoading();
}

/// 表示启动基础数据已经可安全使用的状态。
final class _AppStartupReady extends _AppStartupState {
  /// 创建就绪状态。
  const _AppStartupReady();
}

/// 表示启动基础数据导入失败，并保留可显示的错误摘要。
final class _AppStartupFailed extends _AppStartupState {
  /// 创建失败状态。
  const _AppStartupFailed(this.message);

  /// 不包含敏感业务数据的启动错误摘要。
  final String message;
}

/// 在首帧之后覆盖业务路由，显示启动进度或可重试的导入失败反馈。
final class _AppStartupOverlay extends StatelessWidget {
  /// 创建启动可见状态覆盖层。
  const _AppStartupOverlay({
    required this.startupState,
    required this.onRetry,
    required this.child,
  });

  /// 应用根维护的启动状态通知器。
  final ValueListenable<_AppStartupState> startupState;

  /// 导入失败后重新执行启动流程的回调。
  final VoidCallback onRetry;

  /// 启动完成后显示的认证和业务路由树。
  final Widget child;

  /// 根据当前启动状态选择加载页、错误页或已准备好的业务路由。
  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<_AppStartupState>(
        valueListenable: startupState,
        builder: (BuildContext context, _AppStartupState state, Widget? child) {
          if (state is _AppStartupReady) {
            return child ?? const SizedBox.shrink();
          }
          if (state is _AppStartupFailed) {
            return _buildFailedPage(context, state);
          }
          return _buildLoadingPage(context);
        },
        child: child,
      );

  /// 构建不依赖业务路由的轻量启动加载页面。
  Widget _buildLoadingPage(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surface,
    child: const SafeArea(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('正在准备书源数据…'),
          ],
        ),
      ),
    ),
  );

  /// 构建启动导入失败后的明确反馈与重试入口。
  Widget _buildFailedPage(BuildContext context, _AppStartupFailed state) => Material(
    color: Theme.of(context).colorScheme.surface,
    child: SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.error_outline,
                size: 52,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 20),
              Text('启动准备失败', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 12),
              Text(state.message, textAlign: TextAlign.center),
              const SizedBox(height: 24),
              FilledButton(onPressed: onRetry, child: const Text('重试')),
            ],
          ),
        ),
      ),
    ),
  );
}

/// 覆盖业务页面展示服务端准入阻断和升级提示的应用级 UI。
final class _AppAccessOverlay extends StatefulWidget {
  /// 创建应用准入覆盖层。
  const _AppAccessOverlay({
    required this.coordinator,
    required this.dependencies,
    required this.isRestoringAuthentication,
    required this.child,
  });
  /// 前台准入协调器。
  final AppAccessCoordinator coordinator;
  /// 认证门创建 Route 所需的应用级依赖。
  final AppDependencies dependencies;
  /// 表示 Token 恢复过程的应用级通知器。
  final ValueListenable<bool> isRestoringAuthentication;
  /// 被覆盖的正常应用内容。
  final Widget? child;
  @override
  State<_AppAccessOverlay> createState() => _AppAccessOverlayState();
}

/// 保存本次会话中已关闭的非强制升级提示版本。
final class _AppAccessOverlayState extends State<_AppAccessOverlay> {
  /// 本次运行期间用户已暂缓的版本名称。
  String? _dismissedVersion;
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<AppAccessState>(
    valueListenable: widget.coordinator.state,
    builder: (BuildContext context, AppAccessState state, Widget? child) {
      /// 已规范化的服务端更新说明，避免在 UI 中使用强制空断言。
      final String changelog = state.changelog?.trim() ?? '';
      final bool showOptionalUpdate = state.hasUpdate && !state.forceUpdate && state.versionName != _dismissedVersion;
      return Stack(children: <Widget>[
        _AppAuthenticationGate(
          dependencies: widget.dependencies,
          isRestoringAuthentication: widget.isRestoringAuthentication,
          child: child ?? const SizedBox.shrink(),
        ),
        if (showOptionalUpdate) _buildOptionalUpdate(context, state, changelog),
        if (state.isBlocking) _buildBlockingPage(context, state),
      ]);
    },
    child: widget.child,
  );

  /// 构建可暂缓的升级弹窗；仅 Android 且服务端提供安全地址时展示外部升级入口。
  Widget _buildOptionalUpdate(BuildContext context, AppAccessState state, String changelog) => Stack(children: <Widget>[
    const ModalBarrier(dismissible: false, color: Color(0x66000000)),
    Center(child: AlertDialog(
      title: const Text('发现新版本'),
      content: Text('已有新版本${state.versionName == null ? '' : ' ${state.versionName}'}可用。${changelog.isEmpty ? '' : '\n\n$changelog'}'),
      actions: <Widget>[
        if (_canOpenDownload(state)) FilledButton(onPressed: () => _openDownload(state.downloadUrl), child: const Text('立即更新')),
        TextButton(onPressed: () => setState(() { _dismissedVersion = state.versionName; }), child: const Text('稍后再说')),
      ],
    )),
  ]);

  /// 构建拒绝运行或强制升级时不可绕过的全屏页面。
  Widget _buildBlockingPage(BuildContext context, AppAccessState state) => Material(
    color: Theme.of(context).colorScheme.surface,
    child: SafeArea(child: Center(child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
        Icon(Icons.system_update_alt, size: 52, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 20),
        Text(state.forceUpdate ? '请升级 App' : '当前版本暂不可用', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 12),
        Text(state.message ?? '请更新到最新版本后再继续使用。', textAlign: TextAlign.center),
        if (state.versionName != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text('推荐版本：${state.versionName}')),
        if (state.changelog case final String value when value.trim().isNotEmpty) Padding(padding: const EdgeInsets.only(top: 12), child: Text(value, textAlign: TextAlign.center)),
        const SizedBox(height: 24),
        if (_canOpenDownload(state)) FilledButton(onPressed: () => _openDownload(state.downloadUrl), child: const Text('立即更新')),
        if (_canOpenDownload(state)) const SizedBox(height: 8),
        FilledButton.tonal(onPressed: widget.coordinator.refresh, child: const Text('重新检查')),
        const SizedBox(height: 8),
        if (defaultTargetPlatform == TargetPlatform.android) TextButton(onPressed: SystemNavigator.pop, child: const Text('退出应用')),
      ]),
    ))),
  );

  /// 仅允许 Android 打开服务端下发的 HTTPS 外部下载地址。
  bool _canOpenDownload(AppAccessState state) {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }
    final Uri? uri = Uri.tryParse(state.downloadUrl ?? '');
    return uri != null && uri.hasAuthority && uri.scheme == 'https';
  }

  /// 委托系统浏览器处理升级地址；失败时保留当前阻断状态并反馈给用户。
  Future<void> _openDownload(String? rawUrl) async {
    final Uri? uri = Uri.tryParse(rawUrl ?? '');
    if (uri == null || !uri.hasAuthority || uri.scheme != 'https') {
      return;
    }
    final bool launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!mounted || launched) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('无法打开升级地址，请稍后重试')));
  }
}

/// 在应用根部协调恢复中、未登录和已登录三种会话可见性状态。
final class _AppAuthenticationGate extends StatelessWidget {
  /// 创建应用根部认证门。
  const _AppAuthenticationGate({
    required this.dependencies,
    required this.isRestoringAuthentication,
    required this.child,
  });

  /// 创建认证 UI 与读取会话所需的应用依赖。
  final AppDependencies dependencies;

  /// 安全会话恢复状态，防止业务页面在启动时短暂闪现。
  final ValueListenable<bool> isRestoringAuthentication;

  /// 已登录时允许显示的业务路由树。
  final Widget child;

  /// 根据认证恢复与会话状态选择唯一可见内容。
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: isRestoringAuthentication,
    builder: (BuildContext context, bool isRestoring, Widget? child) {
      if (isRestoring) {
        return _buildRestoringPage(context);
      }
      return ValueListenableBuilder(
        valueListenable: dependencies.authenticationGateway.session,
        builder: (BuildContext context, Object? session, Widget? child) {
          if (session == null) {
            return AuthenticationRoute(dependencies: dependencies, embedded: true);
          }
          return child ?? const SizedBox.shrink();
        },
        child: child,
      );
    },
    child: child,
  );

  /// 构建不泄漏业务路由的轻量会话恢复页。
  Widget _buildRestoringPage(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surface,
    child: const SafeArea(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('正在恢复登录状态…'),
          ],
        ),
      ),
    ),
  );
}
