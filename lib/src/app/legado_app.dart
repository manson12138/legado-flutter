import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../domain/model/app_account.dart';
import '../ui/theme/app_theme.dart';
import '../ui/authentication/authentication_route.dart';
import 'app_dependencies.dart';
import 'app_access_coordinator.dart';
import 'app_error_boundary.dart';
import '../help/logging/app_logger.dart';
import 'app_navigation_observer.dart';
import 'app_route.dart';
import 'app_router.dart';
import '../help/logging/app_log_manager.dart';
import '../help/crash_reporting/crash_report_manager.dart';
import '../api/remote_app/remote_app_service_config.dart';

/// 在 Flutter 首帧后创建完整业务组合根，避免原生启动页等待数据库、网络和阅读器对象装配。
final class LegadoBootstrapApp extends StatefulWidget {
  /// 创建仅持有启动期基础设施的轻量应用壳。
  const LegadoBootstrapApp({
    required this.logger,
    required this.logManager,
    required this.crashReportManager,
    required this.remoteAppConfig,
    super.key,
  });

  /// 首帧前已可用的可降级日志服务。
  final AppLogger logger;

  /// 文件日志管理的延后实现。
  final AppLogManager logManager;

  /// 首帧后初始化目录的崩溃报告管理器。
  final CrashReportManager crashReportManager;

  /// 远端 App 契约的静态运行配置。
  final RemoteAppServiceConfig remoteAppConfig;

  @override
  State<LegadoBootstrapApp> createState() => _LegadoBootstrapAppState();
}

/// 管理完整依赖容器的延后创建与失败降级界面。
final class _LegadoBootstrapAppState extends State<LegadoBootstrapApp> {
  /// 创建完成后提供给正式应用组合根的完整依赖。
  AppDependencies? _dependencies;

  /// 同步组合根创建异常的受控摘要；不向用户展示内部错误对象。
  bool _initializationFailed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      _createDependenciesAfterFirstFrame();
    });
  }

  /// 在首帧提交后创建数据库、网络、JS、下载和阅读业务对象，避免阻塞原生启动页。
  void _createDependenciesAfterFirstFrame() {
    try {
      final AppDependencies dependencies = AppDependencies.create(
        logger: widget.logger,
        logManager: widget.logManager,
        crashReportManager: widget.crashReportManager,
        remoteAppConfig: widget.remoteAppConfig,
      );
      if (!mounted) {
        return;
      }
      widget.logger.info(tag: appStartupLogTag, message: 'stage=dependencies_ready');
      setState(() {
        _dependencies = dependencies;
      });
    } on Object catch (error, stackTrace) {
      widget.logger.fatal(
        tag: appStartupLogTag,
        message: 'stage=dependencies_failed',
        error: error,
        stackTrace: stackTrace,
      );
      widget.crashReportManager.record(
        source: 'dependency_bootstrap',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _initializationFailed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppDependencies? dependencies = _dependencies;
    if (dependencies != null) {
      return LegadoApp(dependencies: dependencies);
    }
    return MaterialApp(
      title: 'Legado Flutter',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      home: _initializationFailed
          ? const Material(
              child: SafeArea(
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text('应用初始化失败，请重启应用后重试。'),
                  ),
                ),
              ),
            )
          : const _AppStartupSplash(),
    );
  }
}

/// 应用启动期间认证会话与输入交互的可见阶段。
enum _AppStartupPhase {
  /// 根 Widget 已创建但尚未开始认证恢复。
  booting,

  /// 正在从安全存储恢复或刷新认证会话。
  restoringAuthentication,

  /// 认证门已挂载，正在等待 Navigator 与输入焦点树完成首帧稳定。
  preparingAuthenticationInput,

  /// 启动页已退出，认证表单可以接收焦点与提交。
  ready,
}

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
final class _LegadoAppState extends State<LegadoApp> {
  /// 写死的管理员账号；该账号进入主界面后不执行 App 准入或版本检查。
  static const String _administratorUsername = 'admin';

  /// 启动遮罩的最短可见时间，避免快速设备上品牌页一闪而过。
  static const Duration _minimumStartupSplashDuration = Duration(
    milliseconds: 500,
  );

  /// 从正式应用组合根创建起计时，用于保证启动页在认证本地恢复过快时仍可见。
  final Stopwatch _startupSplashStopwatch = Stopwatch();

  /// 当前主题模式监听器，首次启动默认跟随系统，并向已保留的一级页面同步变化。
  final ValueNotifier<ThemeMode> _themeModeNotifier = ValueNotifier<ThemeMode>(
    ThemeMode.system,
  );

  /// 控制启动页、认证恢复和表单输入开放时机的应用级状态。
  final ValueNotifier<_AppStartupPhase> _startupPhase =
      ValueNotifier<_AppStartupPhase>(_AppStartupPhase.booting);

  /// 是否已经在登录成功后启动过主界面后台初始化，防止会话刷新重复触发导入和恢复。
  bool _hasStartedMainBackgroundServices = false;

  /// 首帧后启动前台准入轮询，避免在 build 中发起网络请求。
  @override
  void initState() {
    super.initState();
    _startupSplashStopwatch.start();
    widget.dependencies.authenticationGateway.session.addListener(
      _onAuthenticationSessionChanged,
    );
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      unawaited(_restoreAuthenticationSession());
    });
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
    widget.dependencies.authenticationGateway.session.removeListener(
      _onAuthenticationSessionChanged,
    );
    widget.dependencies.appAccessCoordinator.dispose();
    _themeModeNotifier.dispose();
    _startupPhase.dispose();
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
          child: _AppAccessOverlay(
            coordinator: widget.dependencies.appAccessCoordinator,
            dependencies: widget.dependencies,
            startupPhase: _startupPhase,
            child: AppErrorBoundary(child: child),
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

  /// 会话恢复或用户登录成功后，才异步启动主界面所需的书源和下载后台工作。
  void _onAuthenticationSessionChanged() {
    final AppAuthenticationSession? session =
        widget.dependencies.authenticationGateway.session.value;
    if (session == null ||
        _hasStartedMainBackgroundServices) {
      return;
    }
    _hasStartedMainBackgroundServices = true;
    unawaited(_initializeMainBackgroundServices(session));
  }

  /// 串行导入内置书源并恢复下载队列，避免两项工作并发占用同一 SQLite 连接。
  Future<void> _initializeMainBackgroundServices(
    AppAuthenticationSession session,
  ) async {
    widget.dependencies.logger.info(
      tag: appStartupLogTag,
      message: 'stage=main_background_services_started',
    );
    try {
      widget.dependencies.logger.info(
        tag: appStartupLogTag,
        message: 'stage=default_book_source_import_started',
      );
      await widget.dependencies.defaultBookSourceBootstrapper.importIfEmpty();
      widget.dependencies.logger.info(
        tag: appStartupLogTag,
        message: 'stage=default_book_source_import_ready',
      );
    } on Object catch (error) {
      widget.dependencies.logger.error(
        tag: appStartupLogTag,
        message: 'stage=default_book_source_import_failed',
        error: error,
      );
      rethrow;
    } finally {
      widget.dependencies.logger.info(
        tag: appStartupLogTag,
        message: 'stage=download_restore_started',
      );
      try {
        await widget.dependencies.downloadCoordinator.start();
        widget.dependencies.logger.info(
          tag: appStartupLogTag,
          message: 'stage=download_restore_ready',
        );
      } on Object catch (error) {
        widget.dependencies.logger.error(
          tag: appStartupLogTag,
          message: 'stage=download_restore_failed',
          error: error,
        );
        rethrow;
      }
      if (mounted && !_isAdministrator(session)) {
        widget.dependencies.logger.info(
          tag: appStartupLogTag,
          message: 'stage=app_access_polling_started',
        );
        widget.dependencies.appAccessCoordinator.start();
        widget.dependencies.logger.info(
          tag: appStartupLogTag,
          message: 'stage=app_access_polling_ready',
        );
      }
      widget.dependencies.logger.info(
        tag: appStartupLogTag,
        message: 'stage=main_background_services_ready',
      );
    }
  }

  /// 仅用户名精确为 `admin` 的硬编码管理员账号跳过准入和版本检查。
  bool _isAdministrator(AppAuthenticationSession session) {
    return session.account.username == _administratorUsername;
  }

  /// 恢复或刷新持久化安全会话，并在完成前保持认证门覆盖业务页面。
  Future<void> _restoreAuthenticationSession() async {
    _startupPhase.value = _AppStartupPhase.restoringAuthentication;
    widget.dependencies.logger.info(
      tag: appStartupLogTag,
      message: 'stage=authentication_gate_restore_started',
    );
    try {
      await widget.dependencies.authenticationGateway.restoreSession();
    } finally {
      await _prepareAuthenticationInput();
    }
  }

  /// 在认证门已挂载后等待首帧和下一事件循环，再开放输入框以避免冷启动首击过早请求系统键盘。
  Future<void> _prepareAuthenticationInput() async {
    if (!mounted) {
      return;
    }
    _startupPhase.value = _AppStartupPhase.preparingAuthenticationInput;
    widget.dependencies.logger.info(
      tag: appStartupLogTag,
      message: 'stage=authentication_input_preparing',
    );
    await _waitForNextFrame();
    await Future<void>.delayed(Duration.zero);
    /// 认证本地快照恢复可能非常快，补足最短展示时间以保持启动过渡稳定。
    final Duration remaining =
        _minimumStartupSplashDuration - _startupSplashStopwatch.elapsed;
    if (!remaining.isNegative && remaining > Duration.zero) {
      await Future<void>.delayed(remaining);
    }
    if (!mounted) {
      return;
    }
    _startupPhase.value = _AppStartupPhase.ready;
    widget.dependencies.logger.info(
      tag: appStartupLogTag,
      message: 'stage=authentication_gate_restore_finished input_ready=true',
    );
  }

  /// 等待下一绘制帧结束，确保认证根 Navigator、Overlay 和 FocusScope 已完成挂载。
  Future<void> _waitForNextFrame() {
    final Completer<void> completer = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      completer.complete();
    });
    return completer.future;
  }
}

/// 覆盖业务页面展示服务端准入阻断和升级提示的应用级 UI。
final class _AppAccessOverlay extends StatefulWidget {
  /// 创建应用准入覆盖层。
  const _AppAccessOverlay({
    required this.coordinator,
    required this.dependencies,
    required this.startupPhase,
    required this.child,
  });
  /// 前台准入协调器。
  final AppAccessCoordinator coordinator;
  /// 认证门创建 Route 所需的应用级依赖。
  final AppDependencies dependencies;
  /// 启动页和认证输入门控的应用级状态。
  final ValueListenable<_AppStartupPhase> startupPhase;
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
        _AppStartupGate(
          dependencies: widget.dependencies,
          startupPhase: widget.startupPhase,
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

/// 在应用根部协调启动页、未登录认证门和已登录业务路由的可见性状态。
final class _AppStartupGate extends StatelessWidget {
  /// 创建应用根部认证门。
  const _AppStartupGate({
    required this.dependencies,
    required this.startupPhase,
    required this.child,
  });

  /// 创建认证 UI 与读取会话所需的应用依赖。
  final AppDependencies dependencies;

  /// 启动页和认证输入就绪状态。
  final ValueListenable<_AppStartupPhase> startupPhase;

  /// 已登录时允许显示的业务路由树。
  final Widget child;

  /// 认证门始终先挂载在启动页下方；启动页结束前，认证输入框保持不可交互。
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<_AppStartupPhase>(
    valueListenable: startupPhase,
    builder: (BuildContext context, _AppStartupPhase phase, Widget? child) => Stack(
      fit: StackFit.expand,
      children: <Widget>[
        ValueListenableBuilder(
        valueListenable: dependencies.authenticationGateway.session,
        builder: (BuildContext context, Object? session, Widget? child) {
          if (session == null) {
            /// 根部认证门不在主 Navigator 路由树中，因此提供独立 Navigator，同时拥有稳定的 Overlay 与焦点作用域。
            return Navigator(
              /// 初始 Route 会缓存其 builder 参数；输入门从关闭变为开放时必须重建，
              /// 否则认证页会永久持有首次创建时的 `inputEnabled=false`。
              key: ValueKey<bool>(phase == _AppStartupPhase.ready),
              onGenerateRoute: (RouteSettings settings) => MaterialPageRoute<void>(
                settings: settings,
                builder: (BuildContext context) => AuthenticationRoute(
                  dependencies: dependencies,
                  embedded: true,
                  inputEnabled: phase == _AppStartupPhase.ready,
                ),
              ),
            );
          }
          return child ?? const SizedBox.shrink();
        },
        child: child,
        ),
        /// 启动遮罩淡出而不是直接移除，让最低展示时长结束后平滑过渡到认证页或主界面。
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          transitionBuilder: (Widget child, Animation<double> animation) =>
              FadeTransition(opacity: animation, child: child),
          child: phase != _AppStartupPhase.ready
              ? const _AppStartupSplash(key: ValueKey<String>('startup_splash'))
              : const SizedBox(key: ValueKey<String>('startup_splash_hidden')),
        ),
      ],
    ),
    child: child,
  );
}

/// 冷启动期间覆盖认证门的极简启动页，只展示品牌图标且不暴露可点击的表单控件。
final class _AppStartupSplash extends StatelessWidget {
  /// 创建居中展示应用图标的启动页。
  const _AppStartupSplash({super.key});

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surface,
    child: SafeArea(
      child: Center(
        child: Icon(
          Icons.auto_stories_rounded,
          size: 72,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    ),
  );
}
