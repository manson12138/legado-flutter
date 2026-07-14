import 'package:flutter/material.dart';

/// 为所有页面提供统一 Scaffold 与安全区域处理入口。
///
/// Android 通过应用启动时的 edge-to-edge 模式绘制到系统栏下方；这里与 iOS 共用
/// [SafeArea] 收拢可交互内容，避免状态栏、圆角、灵动岛或底部手势区域遮挡页面。
final class AppScaffold extends StatelessWidget {
  /// 创建应用页面基础骨架。
  const AppScaffold({
    required this.body,
    this.appBar,
    this.floatingActionButton,
    this.bottomNavigationBar,
    super.key,
  });

  /// 页面主体内容。
  final Widget body;

  /// 可选的统一顶部栏。
  final PreferredSizeWidget? appBar;

  /// 可选的页面主要浮动操作按钮。
  final Widget? floatingActionButton;

  /// 可选的底部导航或操作区域。
  final Widget? bottomNavigationBar;

  /// 构建支持 edge-to-edge 且内容避开系统交互区的页面。
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: appBar,
      extendBody: true,
      body: SafeArea(child: body),
      floatingActionButton: floatingActionButton,
      bottomNavigationBar: bottomNavigationBar,
    );
  }
}
