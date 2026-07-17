import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app/app_dependencies.dart';
import '../../app/app_route.dart';
import '../../domain/model/book.dart';
import 'settings_screen.dart';

/// 连接“我的”页面、书架历史流与应用路由的轻量入口。
final class SettingsRoute extends StatelessWidget {
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

  /// 构建“我的”页并注入阅读历史、主题、书源、日志和关于回调。
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeListenable,
      builder: (BuildContext context, ThemeMode themeMode, Widget? child) {
        return StreamBuilder<List<Book>>(
          stream: dependencies.bookshelfGateway.watchBookshelf(),
          initialData: const <Book>[],
          builder: (BuildContext context, AsyncSnapshot<List<Book>> snapshot) {
            /// 只保留真正打开过正文的书籍，并按最近阅读时间倒序展示。
            final List<Book> recentBooks = List<Book>.of(snapshot.data ?? const <Book>[])
              ..removeWhere((Book book) => book.durChapterTime <= 0)
              ..sort((Book left, Book right) => right.durChapterTime.compareTo(left.durChapterTime));
            return SettingsScreen(
              recentBooks: recentBooks,
              themeMode: themeMode,
              onBack: () {
                Navigator.of(context).pop();
              },
              showBackButton: !embedded,
              onOpenBook: (Book book) {
                Navigator.of(context).pushNamed(AppRoute.reader, arguments: book.bookUrl);
              },
              onOpenAllHistory: () {
                _showReadingHistory(context, recentBooks);
              },
              onOpenThemeManagement: () {
                _showThemeManagement(context, themeMode);
              },
              onOpenLanguageManagement: () {
                _showLanguageManagement(context);
              },
              onOpenBookSources: () {
                Navigator.of(context).pushNamed(AppRoute.bookSourceManagement);
              },
              onOpenLogManagement: () {
                Navigator.of(context).pushNamed(AppRoute.logManagement);
              },
              onOpenAbout: () {
                _showAbout(context);
              },
            );
          },
        );
      },
    );
  }

  /// 展示完整阅读历史，并允许直接继续阅读任意一本书。
  void _showReadingHistory(BuildContext context, List<Book> books) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext sheetContext) {
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(sheetContext).height * 0.72,
            child: Column(
              children: <Widget>[
                ListTile(
                  title: const Text('阅读历史'),
                  subtitle: Text('${books.length} 本读过的书'),
                ),
                const Divider(),
                Expanded(
                  child: books.isEmpty
                      ? const Center(child: Text('还没有阅读记录'))
                      : ListView.builder(
                          itemCount: books.length,
                          itemBuilder: (BuildContext context, int index) {
                            /// 当前按最近阅读排序的书籍。
                            final Book book = books[index];
                            return ListTile(
                              leading: const Icon(Icons.menu_book_outlined, size: 20),
                              title: Text(book.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text(
                                book.durChapterTitle ?? '上次阅读位置',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: const Icon(Icons.chevron_right, size: 18),
                              onTap: () {
                                Navigator.of(sheetContext).pop();
                                Navigator.of(context).pushNamed(
                                  AppRoute.reader,
                                  arguments: book.bookUrl,
                                );
                              },
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
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
                onChangeThemeMode(mode);
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

  /// 展示应用名称、当前 Flutter 版本和数据边界说明。
  void _showAbout(BuildContext context) {
    showAboutDialog(
      context: context,
      applicationName: 'Legado Flutter',
      applicationVersion: '1.0.0+1',
      applicationIcon: const Icon(Icons.auto_stories, size: 36),
      children: const <Widget>[
        Text('Android 与 iOS 共用的简约阅读客户端。书架、书源和阅读数据默认保存在本机。'),
      ],
    );
  }
}
