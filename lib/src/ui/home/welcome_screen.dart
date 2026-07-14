import 'package:flutter/material.dart';

import '../components/app_scaffold.dart';
import '../theme/app_tokens.dart';
import 'welcome_contract.dart';

/// 只负责渲染欢迎页状态并发送 Intent 的无状态页面。
final class WelcomeScreen extends StatelessWidget {
  /// 创建欢迎页纯 UI。
  const WelcomeScreen({
    required this.state,
    required this.onIntent,
    super.key,
  });

  /// ViewModel 提供的不可变页面状态。
  final WelcomeUiState state;

  /// 把用户操作发送给 ViewModel 的统一入口。
  final ValueChanged<WelcomeIntent> onIntent;

  /// 根据状态构建欢迎页，不读取数据库、网络或平台实现。
  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      appBar: AppBar(title: Text(state.title)),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(SpacingToken.large),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(SpacingToken.xLarge),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      Icons.auto_stories_outlined,
                      size: 72,
                      color: Theme.of(context).colorScheme.primary,
                      semanticLabel: 'Legado Flutter 应用图标',
                    ),
                    const SizedBox(height: SpacingToken.large),
                    Text(
                      state.title,
                      style: Theme.of(context).textTheme.headlineMedium,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: SpacingToken.medium),
                    Text(
                      state.description,
                      style: Theme.of(context).textTheme.bodyLarge,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: SpacingToken.xLarge),
                    ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 44),
                      child: FilledButton.icon(
                        onPressed: () {
                          onIntent(const ConfirmScaffoldIntent());
                        },
                        icon: const Icon(Icons.check_circle_outline),
                        label: const Text('验证骨架交互'),
                      ),
                    ),
                    const SizedBox(height: SpacingToken.medium),
                    ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 44),
                      child: FilledButton.tonalIcon(
                        onPressed: () {
                          onIntent(const OpenBookSourceManagementIntent());
                        },
                        icon: const Icon(Icons.source_outlined),
                        label: const Text('打开书源管理'),
                      ),
                    ),
                    const SizedBox(height: SpacingToken.medium),
                    ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 44),
                      child: FilledButton.tonalIcon(
                        onPressed: () {
                          onIntent(const OpenSearchIntent());
                        },
                        icon: const Icon(Icons.search),
                        label: const Text('搜索书籍'),
                      ),
                    ),
                    const SizedBox(height: SpacingToken.medium),
                    ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 44),
                      child: FilledButton.tonalIcon(
                        onPressed: () {
                          onIntent(const OpenBookshelfIntent());
                        },
                        icon: const Icon(Icons.library_books_outlined),
                        label: const Text('打开书架'),
                      ),
                    ),
                    const SizedBox(height: SpacingToken.medium),
                    ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 44),
                      child: FilledButton.tonalIcon(
                        onPressed: () {
                          onIntent(const OpenLocalBookImportIntent());
                        },
                        icon: const Icon(Icons.upload_file_outlined),
                        label: const Text('导入本地书'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
