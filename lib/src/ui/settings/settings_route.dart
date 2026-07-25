import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app/app_dependencies.dart';
import '../../app/app_route.dart';
import 'settings_screen.dart';

/// 连接“我的”页面设置与应用路由的轻量入口。
final class SettingsRoute extends StatefulWidget {
  /// 创建“我的”页路由。
  const SettingsRoute({
    required this.dependencies,
    required this.themeModeListenable,
    required this.onChangeThemeMode,
    this.embedded = false,
    super.key,
  });

  /// 应用组合根提供的书架和日志依赖。
  final AppDependencies dependencies;

  /// 当前应用主题模式监听器。
  final ValueListenable<ThemeMode> themeModeListenable;

  /// 修改当前应用主题模式的回调。
  final ValueChanged<ThemeMode> onChangeThemeMode;

  /// 是否嵌入应用一级导航；嵌入时不显示返回按钮。
  final bool embedded;

  /// 创建持有一次性设置读取 Future 的路由状态。
  @override
  State<SettingsRoute> createState() => _SettingsRouteState();
}

/// 连接“我的”页面数据，并避免构建期间重复读取交互设置。
final class _SettingsRouteState extends State<SettingsRoute> {
  /// 首次进入页面时读取一次的搜索期交互设置。
  late final Future<bool> _searchInteractionSetting;

  /// 首次进入设置时读取一次的分析同意状态；默认关闭。
  late final Future<bool> _analyticsSetting;

  /// 在 State 已绑定 Widget 后创建一次持久设置读取任务。
  @override
  void initState() {
    super.initState();
    _searchInteractionSetting =
        widget.dependencies.standardBookSourceService.loadSearchInteractionSetting();
    _analyticsSetting = widget.dependencies.remoteBookSourceSyncService.isAnalyticsEnabled();
  }

  /// 构建“我的”页并注入主题、书源、日志和关于回调。
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: widget.themeModeListenable,
      builder: (BuildContext context, ThemeMode themeMode, Widget? child) {
        return FutureBuilder<bool>(
          future: _searchInteractionSetting,
          initialData: false,
          builder: (
            BuildContext context,
            AsyncSnapshot<bool> interactionSnapshot,
          ) {
            return FutureBuilder<bool>(
              future: _analyticsSetting,
              initialData: false,
              builder: (
                BuildContext context,
                AsyncSnapshot<bool> analyticsSnapshot,
              ) {
                return ValueListenableBuilder(
                  valueListenable:
                      widget.dependencies.authenticationGateway.session,
                  builder: (BuildContext context, session, Widget? child) {
                    return SettingsScreen(
                      appSession: session,
                      themeMode: themeMode,
                      allowSearchSourceInteraction:
                          interactionSnapshot.data ?? false,
                      onChangeSearchSourceInteraction: (bool allowed) {
                        widget.dependencies.standardBookSourceService
                            .setSearchInteractionAllowed(allowed);
                      },
                      analyticsEnabled: analyticsSnapshot.data ?? false,
                      onChangeAnalyticsEnabled: (bool enabled) {
                        if (!enabled) {
                          widget.dependencies.downloadCoordinator
                              .clearAnalyticsMeasurements();
                        }
                        widget.dependencies.remoteBookSourceSyncService
                            .setAnalyticsEnabled(enabled);
                      },
                      onBack: () => Navigator.of(context).pop(),
                      showBackButton: !widget.embedded,
                      onOpenThemeManagement: () {
                        _showThemeManagement(context, themeMode);
                      },
                      onOpenLanguageManagement: () {
                        _showLanguageManagement(context);
                      },
                      onOpenBookSources: () {
                        Navigator.of(context).pushNamed(
                          AppRoute.bookSourceManagement,
                        );
                      },
                      onOpenAuthentication: () {
                        Navigator.of(context).pushNamed(
                          AppRoute.authentication,
                        );
                      },
                      onOpenDownloadManagement: () {
                        Navigator.of(context).pushNamed(
                          AppRoute.downloadManagement,
                        );
                      },
                      onOpenOfflineContentManagement: () {
                        Navigator.of(context).pushNamed(
                          AppRoute.offlineContentManagement,
                        );
                      },
                      onOpenLogManagement: () {
                        Navigator.of(context).pushNamed(
                          AppRoute.logManagement,
                        );
                      },
                      onOpenCrashReportManagement: () {
                        Navigator.of(context).pushNamed(
                          AppRoute.crashReportManagement,
                        );
                      },
                      onOpenAbout: () {
                        Navigator.of(context).pushNamed(AppRoute.about);
                      },
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  /// 展示系统、浅色和深色三种主题模式，并立即应用到当前会话。
  void _showThemeManagement(BuildContext context, ThemeMode themeMode) {
    showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('主题管理'),
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
          content: RadioGroup<ThemeMode>(
            groupValue: themeMode,
            onChanged: (ThemeMode? mode) {
              if (mode != null) {
                widget.onChangeThemeMode(mode);
                Navigator.of(dialogContext).pop();
              }
            },
            child: const Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                RadioListTile<ThemeMode>(value: ThemeMode.system, title: Text('跟随系统')),
                RadioListTile<ThemeMode>(value: ThemeMode.light, title: Text('浅色')),
                RadioListTile<ThemeMode>(value: ThemeMode.dark, title: Text('深色')),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 展示当前多语言迁移状态，避免把尚未翻译的界面伪装成可切换语言。
  void _showLanguageManagement(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('多语言管理'),
          content: const Text('当前 Flutter 界面已启用简体中文。其他语言需要完成全量文案本地化后再开放切换。'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('知道了'),
            ),
          ],
        );
      },
    );
  }
}
