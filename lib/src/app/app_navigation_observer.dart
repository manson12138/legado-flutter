import 'package:flutter/material.dart';

import '../help/logging/app_logger.dart';

/// 在 Navigator 统一入口记录所有页面进入、返回、替换和移除事件。
final class AppNavigationObserver extends NavigatorObserver {
  /// 创建绑定应用日志器的路由观察器。
  AppNavigationObserver({required AppLogger logger}) : _logger = logger;

  /// 应用组合根注入的统一日志器。
  final AppLogger _logger;

  /// 记录新页面入栈及其来源页面。
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    _logger.info(
      tag: navigationLogTag,
      message: 'PUSH from=${_routeName(previousRoute)} to=${_routeName(route)}',
    );
  }

  /// 记录当前页面出栈及返回目标页面。
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    _logger.info(
      tag: navigationLogTag,
      message: 'POP from=${_routeName(route)} to=${_routeName(previousRoute)}',
    );
  }

  /// 记录路由替换前后的页面名称。
  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    _logger.info(
      tag: navigationLogTag,
      message: 'REPLACE from=${_routeName(oldRoute)} to=${_routeName(newRoute)}',
    );
  }

  /// 记录没有触发常规返回流程的路由移除事件。
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didRemove(route, previousRoute);
    _logger.info(
      tag: navigationLogTag,
      message: 'REMOVE route=${_routeName(route)} previous=${_routeName(previousRoute)}',
    );
  }

  /// 优先返回显式路由名称，匿名路由则使用页面运行时类型辅助定位。
  String _routeName(Route<dynamic>? route) {
    if (route == null) {
      return '<none>';
    }
    final String? explicitName = route.settings.name;
    if (explicitName != null && explicitName.isNotEmpty) {
      return explicitName;
    }
    return route.runtimeType.toString();
  }
}
