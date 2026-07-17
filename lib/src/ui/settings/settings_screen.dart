import 'package:flutter/material.dart';

import '../../domain/model/book.dart';
import '../components/app_scaffold.dart';
import '../components/book_cover.dart';
import '../theme/app_tokens.dart';

/// 展示本地用户信息、阅读历史和应用管理入口的无状态“我的”页面。
final class SettingsScreen extends StatelessWidget {
  /// 创建“我的”页面纯 UI。
  const SettingsScreen({
    required this.recentBooks,
    required this.themeMode,
    required this.onBack,
    required this.onOpenBook,
    required this.onOpenAllHistory,
    required this.onOpenThemeManagement,
    required this.onOpenLanguageManagement,
    required this.onOpenBookSources,
    required this.onOpenLogManagement,
    required this.onOpenAbout,
    this.showBackButton = true,
    super.key,
  });

  /// 按最近阅读时间倒序排列的本地书籍。
  final List<Book> recentBooks;

  /// 当前应用主题模式。
  final ThemeMode themeMode;

  /// 返回上一页的导航回调。
  final VoidCallback onBack;

  /// 打开指定历史书籍继续阅读的回调。
  final ValueChanged<Book> onOpenBook;

  /// 打开完整阅读历史的回调。
  final VoidCallback onOpenAllHistory;

  /// 打开主题管理的回调。
  final VoidCallback onOpenThemeManagement;

  /// 打开多语言管理的回调。
  final VoidCallback onOpenLanguageManagement;

  /// 打开书源管理的回调。
  final VoidCallback onOpenBookSources;

  /// 打开日志管理页的导航回调。
  final VoidCallback onOpenLogManagement;

  /// 打开关于信息的回调。
  final VoidCallback onOpenAbout;

  /// 顶部栏是否展示返回按钮。
  final bool showBackButton;

  /// 构建本地资料、阅读历史和紧凑分组列表。
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
              _SectionTitle(
                title: '最近阅读',
                actionLabel: recentBooks.isEmpty ? null : '全部',
                onAction: recentBooks.isEmpty ? null : onOpenAllHistory,
              ),
              _RecentReadingList(
                books: recentBooks.take(3).toList(growable: false),
                onOpenBook: onOpenBook,
              ),
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
                    icon: Icons.description_outlined,
                    title: '日志管理',
                    subtitle: '查看、分享或删除运行日志',
                    onTap: onOpenLogManagement,
                  ),
                  _SettingsItem(
                    icon: Icons.info_outline,
                    title: '关于',
                    subtitle: 'Legado Flutter 1.0.0+1',
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
                Text('本地读者', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: SpacingToken.xSmall),
                Text(
                  '阅读数据保存在本机',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
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

/// 展示最多三条最近阅读记录。
final class _RecentReadingList extends StatelessWidget {
  /// 创建最近阅读列表。
  const _RecentReadingList({required this.books, required this.onOpenBook});

  /// 当前需要展示的最近阅读书籍。
  final List<Book> books;

  /// 点击书籍继续阅读的回调。
  final ValueChanged<Book> onOpenBook;

  /// 构建空状态或紧凑阅读记录。
  @override
  Widget build(BuildContext context) {
    if (books.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(
          horizontal: SpacingToken.small,
          vertical: SpacingToken.medium,
        ),
        child: Text('还没有阅读记录'),
      );
    }
    return _SettingsGroup(
      children: books.map((Book book) {
        /// 当前历史项优先展示用户封面，其次展示书源封面。
        final String? coverUrl = book.customCoverUrl?.trim().isNotEmpty == true
            ? book.customCoverUrl
            : book.coverUrl;
        return ListTile(
          leading: SizedBox(
            width: 28,
            height: 40,
            child: BookCover(coverUrl: coverUrl, semanticLabel: '${book.name}封面'),
          ),
          title: Text(book.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            book.durChapterTitle ?? '上次阅读位置',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: () => onOpenBook(book),
        );
      }).toList(growable: false),
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
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(RadiusToken.medium),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.55),
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(RadiusToken.medium),
        child: Column(
          children: List<Widget>.generate(children.length * 2 - 1, (int index) {
            if (index.isOdd) {
              return const Divider(indent: 44);
            }
            return children[index ~/ 2];
          }),
        ),
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
