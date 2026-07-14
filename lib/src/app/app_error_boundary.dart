import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../help/logging/app_logger.dart';
import '../ui/components/app_state_views.dart';

/// 配置 Flutter 框架错误、平台调度错误和构建失败页面的全局兜底行为。
///
/// 业务可恢复错误仍需转换为 UiState 或 Effect；这里仅处理越过业务边界的未捕获错误。
void configureGlobalErrorHandling(AppLogger logger) {
  FlutterError.onError = (FlutterErrorDetails details) {
    logger.error(
      message: '未捕获的 Flutter 框架错误',
      error: details.exception,
      stackTrace: details.stack,
    );
    FlutterError.presentError(details);
  };

  PlatformDispatcher.instance.onError = (Object error, StackTrace stackTrace) {
    logger.error(
      message: '未捕获的平台调度错误',
      error: error,
      stackTrace: stackTrace,
    );
    return true;
  };

  ErrorWidget.builder = (FlutterErrorDetails details) {
    return const AppFatalErrorView(
      message: '页面暂时无法显示，请重启应用后重试。',
    );
  };
}

/// 位于 `MaterialApp.builder` 的应用根错误边界容器。
///
/// Flutter 构建异常由 [ErrorWidget.builder] 替换为统一错误页；本容器负责保证路由内容
/// 始终处于一个明确的根节点下，便于后续接入错误上报或全局遮罩。
final class AppErrorBoundary extends StatelessWidget {
  /// 创建应用根错误边界。
  const AppErrorBoundary({required this.child, super.key});

  /// 当前路由生成的页面；为空时显示统一致命错误提示。
  final Widget? child;

  /// 构建错误边界下的路由内容。
  @override
  Widget build(BuildContext context) {
    /// MaterialApp 在极端初始化失败时可能没有提供页面节点。
    final Widget resolvedChild = child ??
        const AppFatalErrorView(
          message: '应用界面初始化失败，请重启应用。',
        );
    return resolvedChild;
  }
}
