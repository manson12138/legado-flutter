import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_dependencies.dart';
import '../../app/app_access_coordinator.dart';
import 'about_contract.dart';
import 'about_screen.dart';
import 'about_view_model.dart';

/// 连接“关于”页 ViewModel 生命周期和一次性副作用的路由层。
final class AboutRoute extends StatefulWidget {
  /// 创建接收应用组合根依赖的“关于”页路由。
  const AboutRoute({required this.dependencies, super.key});

  /// 应用组合根传入的共享依赖。
  final AppDependencies dependencies;

  /// 创建负责页面生命周期接线的 State。
  @override
  State<AboutRoute> createState() => _AboutRouteState();
}

/// 持有“关于”页 ViewModel、状态和副作用订阅。
final class _AboutRouteState extends State<AboutRoute> {
  /// 页面生命周期内唯一的“关于”页 ViewModel。
  late final AboutViewModel _viewModel;

  /// ViewModel 状态流订阅。
  late final StreamSubscription<AboutUiState> _stateSubscription;

  /// ViewModel 一次性副作用流订阅。
  late final StreamSubscription<AboutEffect> _effectSubscription;

  /// 当前用于渲染页面的状态快照。
  late AboutUiState _state;

  /// 创建 ViewModel 并订阅页面状态与副作用。
  @override
  void initState() {
    super.initState();
    _viewModel = AboutViewModel(
      adultContentGateway: widget.dependencies.adultContentGateway,
    );
    _state = _viewModel.state;
    _stateSubscription = _viewModel.states.listen((AboutUiState state) {
      if (mounted) {
        setState(() {
          _state = state;
        });
      }
    });
    _effectSubscription = _viewModel.effects.listen(_handleEffect);
  }

  /// 把一次性副作用转换为 Snackbar 提示。
  void _handleEffect(AboutEffect effect) {
    if (!mounted) {
      return;
    }
    switch (effect) {
      case ShowAboutMessageEffect(message: final String message):
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(message)));
    }
  }

  /// 释放状态订阅、副作用订阅和 ViewModel 资源。
  @override
  void dispose() {
    _stateSubscription.cancel();
    _effectSubscription.cancel();
    _viewModel.dispose();
    super.dispose();
  }

  /// 把当前状态和 Intent 入口传给无状态页面。
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppAccessState>(
      valueListenable: widget.dependencies.appAccessCoordinator.state,
      builder: (BuildContext context, AppAccessState appAccessState, Widget? child) {
        return AboutScreen(
          state: _state,
          appAccessState: appAccessState,
          onIntent: _viewModel.onIntent,
          onCheckUpdate: () {
            widget.dependencies.appAccessCoordinator.refresh(
              trigger: 'about_page_manual',
            );
          },
          onBack: () {
            Navigator.of(context).pop();
          },
        );
      },
    );
  }
}
