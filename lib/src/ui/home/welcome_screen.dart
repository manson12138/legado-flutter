import 'package:flutter/material.dart';

import '../components/adaptive_app_scaffold.dart';
import 'welcome_contract.dart';

/// 渲染应用一级导航和当前目的地页面的无状态主框架。
final class WelcomeScreen extends StatelessWidget {
  /// 创建正式应用主框架。
  const WelcomeScreen({
    required this.state,
    required this.onIntent,
    required this.body,
    super.key,
  });

  /// ViewModel 提供的不可变导航状态。
  final WelcomeUiState state;

  /// 把主导航操作发送给 ViewModel 的统一入口。
  final ValueChanged<WelcomeIntent> onIntent;

  /// 路由层按当前状态组合的一级页面栈。
  final Widget body;

  /// 构建手机底部导航或宽屏侧栏，不直接执行页面导航。
  @override
  Widget build(BuildContext context) {
    return AdaptiveAppScaffold(
      selectedIndex: state.selectedIndex,
      onDestinationSelected: (int index) {
        onIntent(SelectPrimaryDestinationIntent(index));
      },
      destinations: const <AppNavigationDestination>[
        AppNavigationDestination(
          icon: Icons.auto_stories_outlined,
          selectedIcon: Icons.auto_stories,
          label: '书架',
        ),
        AppNavigationDestination(
          icon: Icons.search_outlined,
          selectedIcon: Icons.search,
          label: '搜索',
        ),
        AppNavigationDestination(
          icon: Icons.hub_outlined,
          selectedIcon: Icons.hub,
          label: '书源',
        ),
        AppNavigationDestination(
          icon: Icons.person_outline,
          selectedIcon: Icons.person,
          label: '我的',
        ),
      ],
      body: body,
    );
  }
}
