import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_dependencies.dart';
import '../../app/app_route.dart';
import 'welcome_contract.dart';
import 'welcome_screen.dart';
import 'welcome_view_model.dart';

/// 连接欢迎页 ViewModel 生命周期、Effect 和纯 UI 的路由层。
final class WelcomeRoute extends StatefulWidget {
  /// 创建接收组合根依赖的欢迎页路由。
  const WelcomeRoute({required this.dependencies, super.key});

  /// 应用组合根传入的共享依赖。
  final AppDependencies dependencies;

  /// 创建负责页面生命周期接线的 State。
  @override
  State<WelcomeRoute> createState() => _WelcomeRouteState();
}

/// 持有欢迎页 ViewModel 与 Effect 订阅，并在页面销毁时释放资源。
final class _WelcomeRouteState extends State<WelcomeRoute> {
  /// 页面生命周期内唯一的欢迎页 ViewModel。
  late final WelcomeViewModel _viewModel;

  /// 路由层对一次性 Effect 流的订阅。
  late final StreamSubscription<WelcomeEffect> _effectSubscription;

  /// 创建 ViewModel 并开始监听一次性副作用。
  @override
  void initState() {
    super.initState();
    _viewModel = WelcomeViewModel(logger: widget.dependencies.logger);
    _effectSubscription = _viewModel.effects.listen(_handleEffect);
  }

  /// 在路由层执行需要 BuildContext 的一次性系统 UI 行为。
  void _handleEffect(WelcomeEffect effect) {
    if (!mounted) {
      return;
    }
    switch (effect) {
      case ShowWelcomeMessageEffect(message: final String message):
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(message)));
      case NavigateToBookSourceManagementEffect():
        Navigator.of(context).pushNamed(AppRoute.bookSourceManagement);
      case NavigateToSearchEffect():
        Navigator.of(context).pushNamed(AppRoute.search);
      case NavigateToBookshelfEffect():
        Navigator.of(context).pushNamed(AppRoute.bookshelf);
      case NavigateToLocalBookImportEffect():
        Navigator.of(context).pushNamed(AppRoute.localBookImport);
    }
  }

  /// 先释放 Effect 订阅和 ViewModel，再结束 Widget 生命周期。
  @override
  void dispose() {
    _effectSubscription.cancel();
    _viewModel.dispose();
    super.dispose();
  }

  /// 把 ViewModel 状态和 Intent 入口传给无状态页面。
  @override
  Widget build(BuildContext context) {
    return WelcomeScreen(
      state: _viewModel.state,
      onIntent: _viewModel.onIntent,
    );
  }
}
