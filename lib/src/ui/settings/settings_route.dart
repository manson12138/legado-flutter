import 'package:flutter/material.dart';

import '../../app/app_route.dart';
import 'settings_screen.dart';

/// 连接设置页面与应用路由的轻量入口。
final class SettingsRoute extends StatelessWidget {
  /// 创建设置页路由。
  const SettingsRoute({super.key});

  /// 构建设置页并注入日志管理导航回调。
  @override
  Widget build(BuildContext context) {
    return SettingsScreen(
      onBack: () {
        Navigator.of(context).pop();
      },
      onOpenLogManagement: () {
        Navigator.of(context).pushNamed(AppRoute.logManagement);
      },
    );
  }
}
