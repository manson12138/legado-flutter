import 'package:flutter/material.dart';

import '../ui/theme/app_theme.dart';
import 'app_dependencies.dart';
import 'app_error_boundary.dart';
import 'app_route.dart';
import 'app_router.dart';

/// Flutter 应用组合根，统一连接依赖、主题、路由和全局错误边界。
final class LegadoApp extends StatelessWidget {
  /// 创建应用组合根。
  const LegadoApp({required this.dependencies, super.key});

  /// 启动阶段组装完成的应用级依赖。
  final AppDependencies dependencies;

  /// 构建只包含应用级装配职责的 MaterialApp。
  @override
  Widget build(BuildContext context) {
    /// 路由器通过构造参数获得依赖，并在页面入口继续向下传递。
    final AppRouter router = AppRouter(dependencies: dependencies);
    return MaterialApp(
      title: 'Legado Flutter',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      initialRoute: AppRoute.welcome,
      onGenerateRoute: router.onGenerateRoute,
      builder: (BuildContext context, Widget? child) {
        return AppErrorBoundary(child: child);
      },
    );
  }
}
