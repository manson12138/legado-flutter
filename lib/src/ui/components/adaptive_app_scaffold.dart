import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

/// 保存主导航单个目标的图标、选中图标和本地化标签。
final class AppNavigationDestination {
  /// 创建不可变主导航目标。
  const AppNavigationDestination({
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });

  /// 未选中状态使用的图标。
  final IconData icon;

  /// 选中状态使用的图标。
  final IconData selectedIcon;

  /// 手机底部导航与宽屏侧栏共享的标签。
  final String label;
}

/// 为应用一级页面提供手机底栏和宽屏侧栏之间的自适应切换。
///
/// 该组件只负责布局和导航点击回调，不持有业务状态，也不直接访问 Navigator。
final class AdaptiveAppScaffold extends StatelessWidget {
  /// 创建响应式应用骨架。
  const AdaptiveAppScaffold({
    required this.body,
    required this.destinations,
    required this.selectedIndex,
    required this.onDestinationSelected,
    super.key,
  });

  /// 当前一级目标渲染的页面主体。
  final Widget body;

  /// 一级导航目标，手机与宽屏使用同一份顺序。
  final List<AppNavigationDestination> destinations;

  /// 当前选中的一级导航索引。
  final int selectedIndex;

  /// 用户选择一级导航目标时的回调。
  final ValueChanged<int> onDestinationSelected;

  /// 按当前可用宽度选择底部导航或 NavigationRail。
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        /// 当前是否达到平板和桌面侧栏布局断点。
        final bool useNavigationRail =
            constraints.maxWidth >= LayoutToken.compactBreakpoint;
        if (useNavigationRail) {
          return Scaffold(
            body: SafeArea(
              child: Row(
                children: <Widget>[
                  NavigationRail(
                    selectedIndex: selectedIndex,
                    extended: constraints.maxWidth >= LayoutToken.expandedBreakpoint,
                    groupAlignment: -0.82,
                    onDestinationSelected: onDestinationSelected,
                    destinations: destinations.map((AppNavigationDestination destination) {
                      return NavigationRailDestination(
                        icon: Icon(destination.icon),
                        selectedIcon: Icon(destination.selectedIcon),
                        label: Text(destination.label),
                      );
                    }).toList(growable: false),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(child: body),
                ],
              ),
            ),
          );
        }
        return Scaffold(
          body: body,
          bottomNavigationBar: NavigationBar(
            selectedIndex: selectedIndex,
            onDestinationSelected: onDestinationSelected,
            destinations: destinations.map((AppNavigationDestination destination) {
              return NavigationDestination(
                icon: Icon(destination.icon),
                selectedIcon: Icon(destination.selectedIcon),
                label: destination.label,
              );
            }).toList(growable: false),
          ),
        );
      },
    );
  }
}
