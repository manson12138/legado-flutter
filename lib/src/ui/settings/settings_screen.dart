import 'package:flutter/material.dart';

import '../components/app_scaffold.dart';
import '../theme/app_tokens.dart';

/// 展示应用设置入口的无状态页面。
final class SettingsScreen extends StatelessWidget {
  /// 创建设置页面纯 UI。
  const SettingsScreen({
    required this.onBack,
    required this.onOpenLogManagement,
    super.key,
  });

  /// 返回上一页的导航回调。
  final VoidCallback onBack;

  /// 打开日志管理页的导航回调。
  final VoidCallback onOpenLogManagement;

  /// 构建设置列表。
  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      appBar: AppBar(
        title: const Text('设置'),
        leading: IconButton(
          onPressed: onBack,
          icon: const Icon(Icons.arrow_back),
          tooltip: '返回',
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(SpacingToken.medium),
        children: <Widget>[
          Card(
            clipBehavior: Clip.antiAlias,
            child: ListTile(
              onTap: onOpenLogManagement,
              leading: const Icon(Icons.description_outlined),
              title: const Text('管理日志'),
              subtitle: const Text('查看、分享、回显或删除沙盒日志'),
              trailing: const Icon(Icons.chevron_right),
            ),
          ),
        ],
      ),
    );
  }
}
