import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app/app_dependencies.dart';
import '../book_source/book_source_route.dart';
import '../bookshelf/bookshelf_route.dart';
import '../search/search_route.dart';
import '../settings/settings_route.dart';
import 'welcome_contract.dart';
import 'welcome_screen.dart';
import 'welcome_view_model.dart';

/// 连接主框架 ViewModel 与四个保持状态的一级页面。
final class WelcomeRoute extends StatefulWidget {
  /// 创建接收组合根依赖的应用主框架路由。
  const WelcomeRoute({
    required this.dependencies,
    required this.themeModeListenable,
    required this.onChangeThemeMode,
    super.key,
  });

  /// 应用组合根传入的共享依赖。
  final AppDependencies dependencies;

  /// 当前应用主题模式监听器，传递给一级“我的”页面。
  final ValueListenable<ThemeMode> themeModeListenable;

  /// 修改应用主题模式的组合根回调。
  final ValueChanged<ThemeMode> onChangeThemeMode;

  /// 创建负责主框架生命周期接线的 State。
  @override
  State<WelcomeRoute> createState() => _WelcomeRouteState();
}

/// 持有主框架 ViewModel 和一级页面栈。
final class _WelcomeRouteState extends State<WelcomeRoute> {
  /// 页面生命周期内唯一的主框架 ViewModel。
  late final WelcomeViewModel _viewModel;

  /// 四个一级目的地页面，使用 IndexedStack 保留滚动和输入状态。
  late List<Widget> _primaryPages;

  /// 创建 ViewModel 和仅初始化一次的一级页面。
  @override
  void initState() {
    super.initState();
    _viewModel = WelcomeViewModel();
    _primaryPages = _buildPrimaryPages();
  }

  /// 根据组合根当前配置创建四个一级页面，并保留统一的依赖注入方式。
  List<Widget> _buildPrimaryPages() {
    return <Widget>[
      BookshelfRoute(dependencies: widget.dependencies, embedded: true),
      SearchRoute(dependencies: widget.dependencies, embedded: true),
      BookSourceManagementRoute(dependencies: widget.dependencies, embedded: true),
      SettingsRoute(
        dependencies: widget.dependencies,
        themeModeListenable: widget.themeModeListenable,
        onChangeThemeMode: widget.onChangeThemeMode,
        embedded: true,
      ),
    ];
  }

  /// 释放主框架 ViewModel 的状态流。
  @override
  void dispose() {
    _viewModel.dispose();
    super.dispose();
  }

  /// 订阅导航状态并保持四个一级页面的 Widget 状态。
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<WelcomeUiState>(
      stream: _viewModel.states,
      initialData: _viewModel.state,
      builder: (BuildContext context, AsyncSnapshot<WelcomeUiState> snapshot) {
        /// 当前可渲染的主框架状态。
        final WelcomeUiState state = snapshot.data ?? _viewModel.state;
        return WelcomeScreen(
          state: state,
          onIntent: _viewModel.onIntent,
          body: IndexedStack(index: state.selectedIndex, children: _primaryPages),
        );
      },
    );
  }
}
