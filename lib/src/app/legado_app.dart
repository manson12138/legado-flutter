import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../domain/model/app_account.dart';
import '../domain/gateway/authentication_gateway.dart';
import '../data/local/preferences/app_preferences_bootstrap.dart';
import '../data/local/preferences/app_preferences_store.dart';
import '../ui/theme/app_theme.dart';
import 'app_dependencies.dart';
import 'app_access_coordinator.dart';
import 'app_error_boundary.dart';
import '../help/logging/app_logger.dart';
import 'app_navigation_observer.dart';
import 'app_route.dart';
import 'app_router.dart';
import 'current_user_scope.dart';
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
      unawaited(_createDependenciesAfterFirstFrame());
    });
  }

  /// 在首帧提交后初始化偏好并创建完整业务对象，避免阻塞原生启动页。
  Future<void> _createDependenciesAfterFirstFrame() async {
    try {
      final AppPreferencesStore preferencesStore =
          await AppPreferencesBootstrap.initialize(logger: widget.logger);
      if (!mounted) {
        return;
      }
      final AppDependencies dependencies = AppDependencies.create(
        logger: widget.logger,
        logManager: widget.logManager,
        crashReportManager: widget.crashReportManager,
        remoteAppConfig: widget.remoteAppConfig,
        preferencesStore: preferencesStore,
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

/// 应用启动期间认证会话恢复与业务界面开放的可见阶段。
enum _AppStartupPhase {
  /// 根 Widget 已创建但尚未开始认证恢复。
  booting,

  /// 正在从安全存储恢复或刷新认证会话。
  restoringAuthentication,

  /// 会话恢复已完成，正在等待业务 Navigator 首帧稳定。
  preparingApplication,

  /// 启动页已退出，游客或账号业务界面可以交互。
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
final class _LegadoAppState extends State<LegadoApp>
    with WidgetsBindingObserver {
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

  /// 控制启动页、认证恢复和业务界面开放时机的应用级状态。
  final ValueNotifier<_AppStartupPhase> _startupPhase =
      ValueNotifier<_AppStartupPhase>(_AppStartupPhase.booting);

  /// 是否已经为当前游客或账号作用域启动后台初始化。
  bool _hasStartedMainBackgroundServices = false;

  /// 防止同一恢复结果被 ValueNotifier 重复发布时产生重复事件。
  AuthenticationRestoreResult? _reportedAuthenticationRestoreResult;

  /// 首帧后启动前台准入轮询，避免在 build 中发起网络请求。
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startupSplashStopwatch.start();
    widget.dependencies.authenticationGateway.session.addListener(
      _onAuthenticationSessionChanged,
    );
    widget.dependencies.authenticationGateway.restoreResult.addListener(
      _onAuthenticationRestoreResultChanged,
    );
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      unawaited(_restoreAuthenticationSession());
    });
  }

  /// 系统内存压力时立即释放可重建的应用级处理后正文。
  @override
  void didHaveMemoryPressure() {
    widget.dependencies.readerProcessedContentStartupPreloader
        .handleMemoryPressure();
    widget.dependencies.readerProcessedContentCache.clear();
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
    widget.dependencies.authenticationGateway.session.removeListener(
      _onAuthenticationSessionChanged,
    );
    widget.dependencies.authenticationGateway.restoreResult.removeListener(
      _onAuthenticationRestoreResultChanged,
    );
    widget.dependencies.bookshelfHistoryAutoRefreshService.cancel(
      reason: 'app_disposed',
    );
    widget.dependencies.readerProcessedContentStartupPreloader.dispose();
    widget.dependencies.readerProcessedContentCache.clear();
    widget.dependencies.currentUserScope.dispose();
    widget.dependencies.appAccessCoordinator.dispose();
    unawaited(widget.dependencies.adultContentGateway.dispose());
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
    return ValueListenableBuilder<int?>(
      valueListenable: widget.dependencies.currentUserScope.userId,
      builder: (BuildContext context, int? userId, Widget? child) {
        return MaterialApp(
          key: ValueKey<String>('local-user-scope-$userId'),
          title: 'Legado Flutter',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: _themeModeNotifier.value,
          initialRoute: AppRoute.welcome,
          onGenerateRoute: router.onGenerateRoute,
          navigatorObservers: <NavigatorObserver>[navigationObserver],
          builder: (BuildContext context, Widget? routedChild) {
            /// 透明系统导航栏可以让 edge-to-edge 内容在其后完整显示，因此每个页面
            /// 底部会自动露出该页面自身的背景色，不需要逐页手动同步导航栏颜色。
            return AnnotatedRegion<SystemUiOverlayStyle>(
              value: _systemOverlayStyleFor(Theme.of(context).brightness),
              child: _AppAccessOverlay(
                coordinator: widget.dependencies.appAccessCoordinator,
                dependencies: widget.dependencies,
                startupPhase: _startupPhase,
                child: AppErrorBoundary(child: routedChild),
              ),
            );
          },
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

  /// 会话变化后切换游客或账号作用域，并为当前作用域启动本地后台工作。
  void _onAuthenticationSessionChanged() {
    final AppAuthenticationSession? session =
        widget.dependencies.authenticationGateway.session.value;
    final int? previousUserId =
        widget.dependencies.currentUserScope.userId.value;
    final int nextUserId =
        session?.account.id ?? CurrentUserScope.guestUserId;
    if (previousUserId != nextUserId) {
      widget.dependencies.bookshelfHistoryAutoRefreshService.cancel(
        reason: 'authentication_session_changed',
      );
      widget.dependencies.bookshelfHistoryStartupPreloader.invalidate();
      widget.dependencies.downloadCoordinator.invalidateUserSession();
      widget.dependencies.readerProcessedContentStartupPreloader
          .invalidateUserSession();
      widget.dependencies.readerProcessedContentCache.clear();
      _hasStartedMainBackgroundServices = false;
    }
    /// 会话变更必须先切换本地作用域，避免游客与账号页面相互读取记录。
    widget.dependencies.currentUserScope.applySession(session);
    if (_hasStartedMainBackgroundServices) {
      return;
    }
    _hasStartedMainBackgroundServices = true;
    final int userId =
        widget.dependencies.currentUserScope.requireUserId();
    final int userGeneration =
        widget.dependencies.currentUserScope.generation;
    /// 启动遮罩可见期间预读当前游客或账号的本地书架与历史。
    /// 失败由页面原有数据库流兜底，不能影响认证、准入或主界面进入。
    unawaited(_preloadBookshelfHistory());
    if (session != null) {
      if (_isAdministrator(session)) {
        widget.dependencies.logger.info(
          tag: appAccessCheckLogTag,
          message: 'stage=start_skipped reason=administrator_account',
        );
      } else {
        /// 账号态建立后立即检查，不能等待书源导入和下载恢复完成。
        widget.dependencies.appAccessCoordinator.start(
          trigger: 'authenticated_session',
        );
      }
      unawaited(
        widget.dependencies.remoteBookSourceSyncService
            .flushPendingAnalytics(),
      );
    }
    unawaited(
      _initializeMainBackgroundServices(
        userId: userId,
        userGeneration: userGeneration,
      ),
    );
  }

  /// 将认证边界发布的远端校验结果转换为固定枚举事件。
  void _onAuthenticationRestoreResultChanged() {
    final AuthenticationRestoreResult? result =
        widget.dependencies.authenticationGateway.restoreResult.value;
    if (result == null ||
        identical(result, _reportedAuthenticationRestoreResult)) {
      return;
    }
    _reportedAuthenticationRestoreResult = result;
    unawaited(
      _recordAnalyticsEvent(
        'app_session_restore_result',
        props: <String, Object?>{
          'result': switch (result.kind) {
            AuthenticationRestoreResultKind.success => 'success',
            AuthenticationRestoreResultKind.expired => 'expired',
            AuthenticationRestoreResultKind.unauthorized => 'unauthorized',
            AuthenticationRestoreResultKind.networkDegraded =>
              'network_degraded',
          },
          'refreshAttempted': result.refreshAttempted,
        },
      ),
    );
  }

  /// 预加载失败时不改变认证或主界面启动流程，页面仍会通过既有数据库流读取数据。
  Future<void> _preloadBookshelfHistory() async {
    try {
      await widget.dependencies.bookshelfHistoryStartupPreloader.preload();
      if (mounted && _startupPhase.value == _AppStartupPhase.ready) {
        _scheduleReaderProcessedContentPreload();
      }
    } catch (_) {
      // 预加载只优化首屏，不应把本地读取失败扩大为认证或启动失败。
    }
  }

  /// 在主界面完成一帧后安排最近阅读当前章预热，避免与启动遮罩退出动画竞争。
  void _scheduleReaderProcessedContentPreload() {
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted || _startupPhase.value != _AppStartupPhase.ready) {
        return;
      }
      unawaited(_preloadReaderProcessedContent());
    });
  }

  /// 缓存限定正文预热失败只影响下次进入的加速效果，不改变启动与阅读正确性。
  Future<void> _preloadReaderProcessedContent() async {
    try {
      await widget.dependencies.readerProcessedContentStartupPreloader
          .preload();
    } catch (_) {
      // 页面仍会按原管线从持久缓存或书源加载，启动优化失败无需阻断主界面。
    }
  }

  /// 串行导入内置书源并恢复下载队列，避免两项工作并发占用同一 SQLite 连接。
  Future<void> _initializeMainBackgroundServices({
    required int userId,
    required int userGeneration,
  }) async {
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
      if (widget.dependencies.currentUserScope.matches(
        expectedUserId: userId,
        expectedGeneration: userGeneration,
      )) {
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
        } finally {
          if (widget.dependencies.currentUserScope.matches(
            expectedUserId: userId,
            expectedGeneration: userGeneration,
          )) {
            unawaited(
              widget.dependencies.bookshelfHistoryAutoRefreshService.start(),
            );
          }
        }
        widget.dependencies.logger.info(
          tag: appStartupLogTag,
          message: 'stage=main_background_services_ready',
        );
      }
    }
  }

  /// 仅用户名精确为 `admin` 的硬编码管理员账号跳过准入和版本检查。
  bool _isAdministrator(AppAuthenticationSession session) {
    return session.account.username == _administratorUsername;
  }

  /// 恢复或刷新持久化安全会话；无会话时继续使用游客本地作用域。
  Future<void> _restoreAuthenticationSession() async {
    _startupPhase.value = _AppStartupPhase.restoringAuthentication;
    widget.dependencies.logger.info(
      tag: appStartupLogTag,
      message: 'stage=authentication_restore_started',
    );
    try {
      final AuthenticationRestoreStart restore =
          await widget.dependencies.authenticationGateway.restoreSession();
      await _recordAnalyticsEvent(
        'app_session_started',
        props: <String, Object?>{
          'restoreState': switch (restore.state) {
            AuthenticationRestoreState.none => 'none',
            AuthenticationRestoreState.restored => 'restored',
            AuthenticationRestoreState.refreshRequired => 'refresh_required',
          },
        },
      );
    } finally {
      /// 没有可恢复会话时 session 不会发生变化，需要在此显式启动游客作用域。
      if (mounted) {
        _onAuthenticationSessionChanged();
      }
      await _finishStartup();
    }
  }

  /// 埋点读写失败只降级丢弃当前事件，不改变认证门和启动流程。
  Future<void> _recordAnalyticsEvent(
    String eventName, {
    required Map<String, Object?> props,
  }) async {
    try {
      await widget.dependencies.remoteBookSourceSyncService
          .recordAnalyticsEvent(eventName, props: props);
    } on Object {
      // 匿名分析是可选旁路，不能延长或阻断认证门。
    }
  }

  /// 等待业务 Navigator 首帧并满足最短品牌页时间后开放游客或账号主界面。
  Future<void> _finishStartup() async {
    if (!mounted) {
      return;
    }
    _startupPhase.value = _AppStartupPhase.preparingApplication;
    widget.dependencies.logger.info(
      tag: appStartupLogTag,
      message: 'stage=application_ready_preparing',
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
      message: 'stage=authentication_restore_finished app_ready=true',
    );
    _scheduleReaderProcessedContentPreload();
  }

  /// 等待下一绘制帧结束，确保业务 Navigator 和 Overlay 已完成挂载。
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
  /// 已写入展示日志的更新状态，避免 Widget 重建产生重复诊断日志。
  String? _loggedUpdatePresentation;
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<AppAccessState>(
    valueListenable: widget.coordinator.state,
    builder: (BuildContext context, AppAccessState state, Widget? child) {
      /// 已规范化的服务端更新说明，避免在 UI 中使用强制空断言。
      final String changelog = state.changelog?.trim() ?? '';
      final bool showOptionalUpdate = state.hasUpdate && !state.forceUpdate && state.versionName != _dismissedVersion;
      final String presentation = 'has_update=${state.hasUpdate} force_update=${state.forceUpdate} blocking=${state.isBlocking} latest_version=${state.versionName ?? 'none'} dismissed_version=${_dismissedVersion ?? 'none'} optional_visible=$showOptionalUpdate';
      if (_loggedUpdatePresentation != presentation) {
        _loggedUpdatePresentation = presentation;
        widget.dependencies.logger.info(
          tag: appAccessCheckLogTag,
          message: 'stage=ui_presentation $presentation',
        );
      }
      return Stack(children: <Widget>[
        _AppStartupGate(
          startupPhase: widget.startupPhase,
          child: child ?? const SizedBox.shrink(),
        ),
        if (showOptionalUpdate) _buildOptionalUpdate(context, state, changelog),
        if (state.isRestoring) _buildAccessStateRestorePage(context),
        if (!state.isRestoring && state.isBlocking)
          _buildBlockingPage(context, state),
      ]);
    },
    child: widget.child,
  );

  /// 构建仅等待本地准入缓存读取的不可交互遮罩，不等待网络请求。
  Widget _buildAccessStateRestorePage(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surface,
    child: const SafeArea(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('正在检查本地准入状态…'),
          ],
        ),
      ),
    ),
  );

  /// 构建可暂缓的升级弹窗；服务端提供安全地址时展示可打开和复制的下载地址。
  Widget _buildOptionalUpdate(BuildContext context, AppAccessState state, String changelog) => Stack(children: <Widget>[
    const ModalBarrier(dismissible: false, color: Color(0x66000000)),
    Center(child: AlertDialog(
      title: const Text('发现新版本'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('已有新版本${state.versionName == null ? '' : ' ${state.versionName}'}可用。${changelog.isEmpty ? '' : '\n\n$changelog'}'),
            if (_hasDownloadAddress(state.downloadUrl)) ...<Widget>[
              const SizedBox(height: 16),
              _buildDownloadAddress(context, state.downloadUrl),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        if (_downloadUri(state.downloadUrl) != null) FilledButton(onPressed: () => _openDownload(state.downloadUrl), child: const Text('立即更新')),
        TextButton(onPressed: () {
          widget.dependencies.logger.info(
            tag: appAccessCheckLogTag,
            message: 'stage=optional_update_dismissed latest_version=${state.versionName ?? 'none'}',
          );
          setState(() { _dismissedVersion = state.versionName; });
        }, child: const Text('稍后再说')),
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
        if (_hasDownloadAddress(state.downloadUrl)) Padding(
          padding: const EdgeInsets.only(top: 16),
          child: _buildDownloadAddress(context, state.downloadUrl),
        ),
        const SizedBox(height: 24),
        if (_downloadUri(state.downloadUrl) != null) FilledButton(onPressed: () => _openDownload(state.downloadUrl), child: const Text('立即更新')),
        if (_downloadUri(state.downloadUrl) != null) const SizedBox(height: 8),
        FilledButton.tonal(onPressed: () => widget.coordinator.refresh(trigger: 'blocking_page_retry'), child: const Text('重新检查')),
        const SizedBox(height: 8),
        if (defaultTargetPlatform == TargetPlatform.android) TextButton(onPressed: SystemNavigator.pop, child: const Text('退出应用')),
      ]),
    ))),
  );

  /// 非空下载地址始终展示并允许复制，不能因跳转校验失败而隐藏服务端原值。
  bool _hasDownloadAddress(String? rawUrl) =>
      rawUrl?.trim().isNotEmpty == true;

  /// 只把浏览器可处理的 HTTP 或 HTTPS 下载地址交给系统外部应用。
  Uri? _downloadUri(String? rawUrl) {
    final Uri? uri = Uri.tryParse(rawUrl?.trim() ?? '');
    if (uri == null || !uri.hasAuthority) {
      return null;
    }
    final String scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      return null;
    }
    return uri;
  }

  /// 构建完整可见的下载地址；点击以外部浏览器打开，长按复制原始地址。
  Widget _buildDownloadAddress(BuildContext context, String? rawUrl) {
    final String address = rawUrl?.trim() ?? '';
    if (address.isEmpty) {
      return const SizedBox.shrink();
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _openDownload(address),
      onLongPress: () => _copyDownloadAddress(address),
      child: Semantics(
        button: true,
        label: '下载地址，点击打开外部浏览器，长按复制',
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('下载地址（点击打开，长按复制）', style: Theme.of(context).textTheme.labelMedium),
              const SizedBox(height: 6),
              Text(address, style: TextStyle(color: Theme.of(context).colorScheme.primary)),
            ],
          ),
        ),
      ),
    );
  }

  /// 委托系统浏览器处理升级地址；失败时保留当前阻断状态并反馈给用户。
  Future<void> _openDownload(String? rawUrl) async {
    final Uri? uri = _downloadUri(rawUrl);
    if (uri == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('下载地址无效，请长按复制后手动打开')),
        );
      }
      return;
    }
    final bool launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!mounted || launched) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('无法打开升级地址，请稍后重试')));
  }

  /// 将弹窗中完整展示的下载地址复制到系统剪贴板，并反馈操作结果。
  Future<void> _copyDownloadAddress(String rawUrl) async {
    final String address = rawUrl.trim();
    if (address.isEmpty) {
      return;
    }
    await Clipboard.setData(ClipboardData(text: address));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('下载地址已复制')),
    );
  }
}

/// 在应用根部协调启动页与游客/账号业务路由的可见性状态。
final class _AppStartupGate extends StatelessWidget {
  /// 创建不强制登录的应用启动门。
  const _AppStartupGate({
    required this.startupPhase,
    required this.child,
  });

  /// 启动页和业务界面就绪状态。
  final ValueListenable<_AppStartupPhase> startupPhase;

  /// 游客与已登录账号共用的业务路由树。
  final Widget child;

  /// 业务树始终挂载在启动页下方，会话恢复结束前由启动页阻止交互。
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<_AppStartupPhase>(
    valueListenable: startupPhase,
    builder: (BuildContext context, _AppStartupPhase phase, Widget? child) => Stack(
      fit: StackFit.expand,
      children: <Widget>[
        child ?? const SizedBox.shrink(),
        /// 启动遮罩淡出而不是直接移除，让最低展示时长结束后平滑过渡到游客或账号主界面。
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

/// 冷启动期间覆盖业务树的极简启动页，只展示品牌图标。
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
