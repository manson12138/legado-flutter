import 'package:flutter/material.dart';

import '../ui/theme/app_theme.dart';
import 'app_dependencies.dart';
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
final class _LegadoAppState extends State<LegadoApp> {
  /// 当前主题模式监听器，首次启动默认跟随系统，并向已保留的一级页面同步变化。
  final ValueNotifier<ThemeMode> _themeModeNotifier = ValueNotifier<ThemeMode>(
    ThemeMode.system,
  );

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
    _themeModeNotifier.dispose();
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
        return AppErrorBoundary(child: child);
      },
    );
  }
}
