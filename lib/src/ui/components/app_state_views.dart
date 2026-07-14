import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

/// 展示页面正在等待数据的统一加载状态。
final class AppLoadingView extends StatelessWidget {
  /// 创建加载状态，可提供用户可理解的加载说明。
  const AppLoadingView({this.message = '正在加载……', super.key});

  /// 显示在进度指示器下方的加载说明。
  final String message;

  /// 构建居中的加载提示。
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const CircularProgressIndicator(),
          const SizedBox(height: SpacingToken.medium),
          Text(message),
        ],
      ),
    );
  }
}

/// 展示数据请求成功但没有内容的统一空状态。
final class AppEmptyView extends StatelessWidget {
  /// 创建空状态提示。
  const AppEmptyView({required this.message, this.action, super.key});

  /// 解释当前为什么没有可展示内容的文本。
  final String message;

  /// 可选的恢复或创建内容操作。
  final Widget? action;

  /// 构建包含说明和可选操作的空状态。
  @override
  Widget build(BuildContext context) {
    return _AppMessageView(
      icon: Icons.inbox_outlined,
      message: message,
      action: action,
    );
  }
}

/// 展示可恢复错误并为页面提供重试入口。
final class AppErrorView extends StatelessWidget {
  /// 创建可恢复错误状态。
  const AppErrorView({required this.message, this.onRetry, super.key});

  /// 可安全展示给用户的错误摘要。
  final String message;

  /// 可选的重试回调；为空时只展示错误，不提供无效按钮。
  final VoidCallback? onRetry;

  /// 构建错误说明和可选重试按钮。
  @override
  Widget build(BuildContext context) {
    /// 仅在存在重试行为时创建按钮，避免出现无响应操作。
    final Widget? action = onRetry == null
        ? null
        : FilledButton.tonal(
            onPressed: onRetry,
            child: const Text('重试'),
          );
    return _AppMessageView(
      icon: Icons.error_outline,
      message: message,
      action: action,
    );
  }
}

/// 展示越过全局错误边界的致命错误，不泄露堆栈或内部实现细节。
final class AppFatalErrorView extends StatelessWidget {
  /// 创建全局致命错误提示。
  const AppFatalErrorView({required this.message, super.key});

  /// 提供给用户的稳定恢复建议。
  final String message;

  /// 在可能缺少 Material 页面结构时仍构建完整兜底界面。
  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: _AppMessageView(
        icon: Icons.warning_amber_rounded,
        message: message,
      ),
    );
  }
}

/// 复用加载、空状态和错误状态的居中信息布局。
final class _AppMessageView extends StatelessWidget {
  /// 创建统一消息状态布局。
  const _AppMessageView({
    required this.icon,
    required this.message,
    this.action,
  });

  /// 表达状态类型的辅助图标；文本仍是主要信息来源。
  final IconData icon;

  /// 状态说明文本。
  final String message;

  /// 可选的恢复操作。
  final Widget? action;

  /// 构建满足最小触摸区域和文字缩放要求的消息布局。
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(SpacingToken.large),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 48, semanticLabel: '状态提示'),
            const SizedBox(height: SpacingToken.medium),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            if (action case final Widget resolvedAction) ...<Widget>[
              const SizedBox(height: SpacingToken.large),
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 44),
                child: resolvedAction,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
