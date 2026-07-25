import 'package:flutter/material.dart';

import '../../domain/model/app_account.dart';
import '../components/app_scaffold.dart';
import '../theme/app_tokens.dart';

/// 展示本地用户信息和应用管理入口的无状态“我的”页面。
final class SettingsScreen extends StatelessWidget {
  /// 创建“我的”页面纯 UI。
  const SettingsScreen({
    required this.appSession,
    required this.themeMode,
    required this.onBack,
    required this.onOpenThemeManagement,
    required this.onOpenLanguageManagement,
    required this.onOpenBookSources,
    required this.onOpenAuthentication,
    required this.onOpenDownloadManagement,
    required this.onOpenOfflineContentManagement,
    required this.allowSearchSourceInteraction,
    required this.onChangeSearchSourceInteraction,
    required this.analyticsEnabled,
    required this.onChangeAnalyticsEnabled,
    required this.onOpenLogManagement,
    required this.onOpenCrashReportManagement,
    required this.onOpenAbout,
    this.showBackButton = true,
    super.key,
  });

  /// 当前仅驻留内存的 App 账号会话；为空表示未登录。
  final AppAuthenticationSession? appSession;

  /// 当前应用主题模式。
  final ThemeMode themeMode;

  /// 返回上一页的导航回调。
  final VoidCallback onBack;

  /// 打开主题管理的回调。
  final VoidCallback onOpenThemeManagement;

  /// 打开多语言管理的回调。
  final VoidCallback onOpenLanguageManagement;

  /// 打开书源管理的回调。
  final VoidCallback onOpenBookSources;

  /// 打开 App 用户注册登录页面的回调。
  final VoidCallback onOpenAuthentication;

  /// 打开跨书离线下载管理页的回调。
  final VoidCallback onOpenDownloadManagement;

  /// 打开离线内容管理页并清除不再需要的已下载正文。
  final VoidCallback onOpenOfflineContentManagement;

  /// 搜索时是否允许书源脚本申请登录或验证交互；默认关闭。
  final bool allowSearchSourceInteraction;

  /// 用户切换搜索期书源登录与验证交互权限时的回调。
  final ValueChanged<bool> onChangeSearchSourceInteraction;

  /// 用户是否已同意上传非敏感分析事件。
  final bool analyticsEnabled;

  /// 保存用户分析同意状态的回调。
  final ValueChanged<bool> onChangeAnalyticsEnabled;

  /// 打开日志管理页的导航回调。
  final VoidCallback onOpenLogManagement;

  /// 打开独立崩溃报告管理页的导航回调。
  final VoidCallback onOpenCrashReportManagement;

  /// 打开关于信息的回调。
  final VoidCallback onOpenAbout;

  /// 顶部栏是否展示返回按钮。
  final bool showBackButton;

  /// 构建本地资料和紧凑分组列表。
  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      appBar: AppBar(
        title: const Text('我的'),
        automaticallyImplyLeading: false,
        leading: showBackButton
            ? IconButton(
                onPressed: onBack,
                icon: const Icon(Icons.arrow_back),
                tooltip: '返回',
              )
            : null,
      ),
      body: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          /// 宽屏下限制“我的”页面内容宽度，保持列表适合快速扫描。
          final double horizontalPadding = constraints.maxWidth > 720
              ? (constraints.maxWidth - 720) / 2
              : SpacingToken.medium;
          return ListView(
            padding: EdgeInsets.fromLTRB(
              horizontalPadding,
              SpacingToken.small,
              horizontalPadding,
              SpacingToken.large,
            ),
            children: <Widget>[
              _buildProfileHeader(context),
              const SizedBox(height: SpacingToken.large),
              const _SectionTitle(title: '外观与语言'),
              _SettingsGroup(
                children: <Widget>[
                  _SettingsItem(
                    icon: Icons.palette_outlined,
                    title: '主题管理',
                    subtitle: _themeModeLabel(themeMode),
                    onTap: onOpenThemeManagement,
                  ),
                  _SettingsItem(
                    icon: Icons.language_outlined,
                    title: '多语言管理',
                    subtitle: '简体中文',
                    onTap: onOpenLanguageManagement,
                  ),
                ],
              ),
              const SizedBox(height: SpacingToken.large),
              const _SectionTitle(title: '应用管理'),
              _SettingsGroup(
                children: <Widget>[
                  _SettingsItem(
                    icon: Icons.hub_outlined,
                    title: '书源管理',
                    subtitle: '导入、编辑和启停书源',
                    onTap: onOpenBookSources,
                  ),
                  _SettingsItem(
                    icon: Icons.download_for_offline_outlined,
                    title: '下载管理',
                    subtitle: '串行下载、暂停恢复和离线内容管理',
                    onTap: onOpenDownloadManagement,
                  ),
                  _SettingsItem(
                    icon: Icons.inventory_2_outlined,
                    title: '离线内容管理',
                    subtitle: '查看并清除已下载的离线正文',
                    onTap: onOpenOfflineContentManagement,
                  ),
                  _SearchSourceInteractionSwitch(
                    initialValue: allowSearchSourceInteraction,
                    onChanged: onChangeSearchSourceInteraction,
                  ),
                  _AnalyticsConsentSwitch(
                    initialValue: analyticsEnabled,
                    onChanged: onChangeAnalyticsEnabled,
                  ),
                  _SettingsItem(
                    icon: Icons.description_outlined,
                    title: '日志管理',
                    subtitle: '查看、分享或删除运行日志',
                    onTap: onOpenLogManagement,
                  ),
                  _SettingsItem(
                    icon: Icons.bug_report_outlined,
                    title: '崩溃日志',
                    subtitle: '查看、上传或删除已脱敏的崩溃报告',
                    onTap: onOpenCrashReportManagement,
                  ),
                  _SettingsItem(
                    icon: Icons.info_outline,
                    title: '关于',
                    subtitle: 'Legado Flutter 1.0.0+6',
                    onTap: onOpenAbout,
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  /// 构建低装饰的本地用户资料区，不暗示尚未实现的云端账户能力。
  Widget _buildProfileHeader(BuildContext context) {
    final AppAuthenticationSession? session = appSession;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: SpacingToken.small,
        vertical: SpacingToken.mediumSmall,
      ),
      child: Row(
        children: <Widget>[
          CircleAvatar(
            radius: 22,
            backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
            foregroundColor: Theme.of(context).colorScheme.onSecondaryContainer,
            child: const Icon(Icons.person_outline, size: 22),
          ),
          const SizedBox(width: SpacingToken.medium),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(session?.account.username ?? '本地读者', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: SpacingToken.xSmall),
                Text(
                  session == null ? '阅读数据保存在本机' : '阅读数据保存在本机',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onOpenAuthentication,
            icon: const Icon(Icons.manage_accounts_outlined),
            tooltip: session == null ? '登录或注册 App 账号' : '管理 App 账号',
          ),
        ],
      ),
    );
  }

  /// 返回主题模式对应的简短中文名称。
  String _themeModeLabel(ThemeMode mode) {
    return switch (mode) {
      ThemeMode.system => '跟随系统',
      ThemeMode.light => '浅色',
      ThemeMode.dark => '深色',
    };
  }
}

/// 展示默认关闭的分析同意开关，避免未经明确同意采集或持久化事件。
final class _AnalyticsConsentSwitch extends StatefulWidget {
  /// 创建分析同意开关。
  const _AnalyticsConsentSwitch({required this.initialValue, required this.onChanged});

  /// 路由读取到的持久化同意状态。
  final bool initialValue;

  /// 保存用户新选择的回调。
  final ValueChanged<bool> onChanged;

  /// 创建本地即时状态。
  @override
  State<_AnalyticsConsentSwitch> createState() => _AnalyticsConsentSwitchState();
}

/// 管理分析同意开关的即时视觉状态。
final class _AnalyticsConsentSwitchState extends State<_AnalyticsConsentSwitch> {
  /// 当前开关值。
  late bool _value;

  /// 使用路由读取的初始值。
  @override
  void initState() { super.initState(); _value = widget.initialValue; }

  /// 持久化值异步到达时同步显示状态。
  @override
  void didUpdateWidget(covariant _AnalyticsConsentSwitch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialValue != widget.initialValue) { _value = widget.initialValue; }
  }

  /// 构建分析同意开关。
  @override
  Widget build(BuildContext context) => SwitchListTile(
    secondary: const Icon(Icons.insights_outlined, size: 20),
    title: const Text('允许匿名使用分析'),
    subtitle: const Text('默认关闭；仅上传非敏感事件，用于改进书源质量和功能稳定性'),
    value: _value,
    onChanged: (bool value) { setState(() { _value = value; }); widget.onChanged(value); },
  );
}

/// 展示并立即反馈搜索期书源登录与验证交互开关。
final class _SearchSourceInteractionSwitch extends StatefulWidget {
  /// 创建默认关闭、可由持久设置恢复的交互权限开关。
  const _SearchSourceInteractionSwitch({
    required this.initialValue,
    required this.onChanged,
  });

  /// 路由从持久设置读取到的初始值。
  final bool initialValue;

  /// 保存新值的回调。
  final ValueChanged<bool> onChanged;

  /// 创建开关的本地即时反馈状态。
  @override
  State<_SearchSourceInteractionSwitch> createState() =>
      _SearchSourceInteractionSwitchState();
}

/// 管理搜索期书源交互开关的即时视觉状态。
final class _SearchSourceInteractionSwitchState
    extends State<_SearchSourceInteractionSwitch> {
  /// 当前开关值；写入持久层期间也立即更新界面。
  late bool _value;

  /// 在 State 绑定 Widget 后应用默认关闭或持久恢复值。
  @override
  void initState() {
    super.initState();
    _value = widget.initialValue;
  }

  /// 持久设置异步读取完成后，用真实值替换首帧使用的默认关闭状态。
  @override
  void didUpdateWidget(covariant _SearchSourceInteractionSwitch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialValue != widget.initialValue) {
      _value = widget.initialValue;
    }
  }

  /// 构建带安全说明的开关列表项。
  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      secondary: const Icon(Icons.login_outlined, size: 20),
      title: const Text('搜索时允许书源登录与验证提示'),
      subtitle: const Text('默认关闭；关闭时需要交互的书源会被跳过'),
      value: _value,
      onChanged: (bool value) {
        setState(() {
          _value = value;
        });
        widget.onChanged(value);
      },
    );
  }
}

/// 展示分组标题及可选的右侧文字操作。
final class _SectionTitle extends StatelessWidget {
  /// 创建紧凑分组标题。
  const _SectionTitle({required this.title, this.actionLabel, this.onAction});

  /// 分组名称。
  final String title;

  /// 可选的操作文字。
  final String? actionLabel;

  /// 可选的操作回调。
  final VoidCallback? onAction;

  /// 构建标题行。
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: SpacingToken.small),
      child: Row(
        children: <Widget>[
          Expanded(child: Text(title, style: Theme.of(context).textTheme.titleSmall)),
          if (actionLabel != null)
            TextButton(onPressed: onAction, child: Text(actionLabel ?? '')),
        ],
      ),
    );
  }
}

/// 使用单层边界组合一组列表项，避免每个入口都成为独立大卡片。
final class _SettingsGroup extends StatelessWidget {
  /// 创建设置项分组。
  const _SettingsGroup({required this.children});

  /// 分组内部的列表项。
  final List<Widget> children;

  /// 构建带轻边框和内部细分隔线的列表组。
  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(RadiusToken.medium),
        side: BorderSide(
          color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.55),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: List<Widget>.generate(children.length * 2 - 1, (int index) {
          if (index.isOdd) {
            return const Divider(indent: 44);
          }
          return children[index ~/ 2];
        }),
      ),
    );
  }
}

/// 展示图标、标题、摘要和进入箭头的紧凑设置项。
final class _SettingsItem extends StatelessWidget {
  /// 创建单个设置入口。
  const _SettingsItem({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  /// 左侧语义图标。
  final IconData icon;

  /// 设置项标题。
  final String title;

  /// 当前状态或功能摘要。
  final String subtitle;

  /// 点击设置项时的回调。
  final VoidCallback onTap;

  /// 构建紧凑列表项。
  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, size: 20),
      title: Text(title),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: const Icon(Icons.chevron_right, size: 18),
      onTap: onTap,
    );
  }
}
