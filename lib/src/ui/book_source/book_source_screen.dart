import 'package:flutter/material.dart';

import '../../domain/model/book_source.dart';
import '../components/app_scaffold.dart';
import '../components/app_state_views.dart';
import '../theme/app_tokens.dart';
import 'book_source_contract.dart';

/// 只渲染书源管理状态并发送 Intent 的无业务逻辑页面。
final class BookSourceManagementScreen extends StatelessWidget {
  /// 创建书源管理页面。
  const BookSourceManagementScreen({
    required this.state,
    required this.onIntent,
    this.showBackButton = true,
    super.key,
  });

  /// ViewModel 提供的不可变页面状态。
  final BookSourceManagementUiState state;

  /// 页面所有操作的统一 Intent 入口。
  final ValueChanged<BookSourceManagementIntent> onIntent;

  /// 非选择模式下是否展示返回按钮。
  final bool showBackButton;

  /// 构建包含筛选、列表、选择模式和入口操作的页面。
  @override
  Widget build(BuildContext context) {
    /// 当前是否处于批量选择模式。
    final bool selecting = state.selectedUrls.isNotEmpty;
    return PopScope(
      canPop: !selecting,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop) {
          onIntent(const BackFromBookSourceManagementIntent());
        }
      },
      child: AppScaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          leading: selecting || showBackButton
              ? IconButton(
                  tooltip: selecting ? '退出选择' : '返回',
                  onPressed: () {
                    onIntent(const BackFromBookSourceManagementIntent());
                  },
                  icon: Icon(selecting ? Icons.close : Icons.arrow_back),
                )
              : null,
          title: Text(selecting ? '已选择 ${state.selectedUrls.length} 项' : '书源管理'),
          actions: selecting
              ? <Widget>[
                  IconButton(
                    tooltip: '全选当前结果',
                    onPressed: () {
                      for (final BookSource source in state.visibleSources) {
                        if (!state.selectedUrls.contains(source.bookSourceUrl)) {
                          onIntent(ToggleBookSourceSelectionIntent(source.bookSourceUrl));
                        }
                      }
                    },
                    icon: const Icon(Icons.select_all),
                  ),
                ]
              : <Widget>[
                  IconButton(
                    tooltip: '导入文件',
                    onPressed: state.busy
                        ? null
                        : () {
                            onIntent(const RequestBookSourceFileIntent());
                          },
                    icon: const Icon(Icons.file_open_outlined),
                  ),
                  PopupMenuButton<String>(
                    tooltip: '更多导入方式',
                    onSelected: (String value) {
                      switch (value) {
                        case 'text':
                          onIntent(const ShowBookSourceTextImportIntent());
                        case 'clipboard':
                          onIntent(const RequestBookSourceClipboardIntent());
                        case 'qr':
                          onIntent(const RequestBookSourceQrIntent());
                      }
                    },
                    itemBuilder: (BuildContext context) => const <PopupMenuEntry<String>>[
                      PopupMenuItem<String>(value: 'text', child: Text('粘贴 JSON 文本')),
                      PopupMenuItem<String>(value: 'clipboard', child: Text('从剪贴板导入')),
                      PopupMenuItem<String>(value: 'qr', child: Text('扫描二维码')),
                    ],
                  ),
                ],
        ),
        floatingActionButton: selecting
            ? null
            : FloatingActionButton.small(
                onPressed: () {
                  onIntent(const RequestAddBookSourceIntent());
                },
                tooltip: '新增书源',
                child: const Icon(Icons.add),
              ),
        bottomNavigationBar: selecting
            ? _SelectionActions(state: state, onIntent: onIntent)
            : null,
        body: Column(
          children: <Widget>[
            if (state.busy) const LinearProgressIndicator(),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                SpacingToken.medium,
                SpacingToken.medium,
                SpacingToken.medium,
                SpacingToken.small,
              ),
              child: TextFormField(
                key: ValueKey<String>('book-source-${state.query.isEmpty}'),
                initialValue: state.query,
                onChanged: (String value) {
                  onIntent(ChangeBookSourceQueryIntent(value));
                },
                decoration: InputDecoration(
                  hintText: '搜索书源',
                  prefixIcon: const Icon(Icons.search, size: 18),
                  prefixIconConstraints: const BoxConstraints(minWidth: 38, minHeight: 38),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: SpacingToken.mediumSmall,
                    vertical: SpacingToken.small,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(RadiusToken.pill),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(RadiusToken.pill),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(RadiusToken.pill),
                    borderSide: BorderSide(
                      color: Theme.of(context).colorScheme.primary,
                      width: 1,
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: SpacingToken.medium),
                children: BookSourceFilter.values.map((BookSourceFilter filter) {
                  return Padding(
                    padding: const EdgeInsets.only(right: SpacingToken.small),
                    child: FilterChip(
                      selected: state.filter == filter,
                      label: Text(_filterLabel(filter)),
                      onSelected: (bool selected) {
                        if (selected) {
                          onIntent(ChangeBookSourceFilterIntent(filter));
                        }
                      },
                    ),
                  );
                }).toList(growable: false),
              ),
            ),
            Expanded(child: _buildContent(context)),
          ],
        ),
      ),
    );
  }

  /// 根据加载、错误、空和正常状态构建主体。
  Widget _buildContent(BuildContext context) {
    if (state.loading) {
      return const AppLoadingView(message: '正在读取书源……');
    }
    if (state.errorMessage case final String message) {
      return AppErrorView(
        message: message,
        onRetry: () {
          onIntent(const RetryBookSourceLoadIntent());
        },
      );
    }
    /// 当前筛选后的书源。
    final List<BookSource> sources = state.visibleSources;
    if (sources.isEmpty) {
      return AppEmptyView(
        message: state.sources.isEmpty ? '还没有书源，可以从文件或文本导入。' : '没有符合条件的书源。',
        action: state.sources.isEmpty
            ? FilledButton.icon(
                onPressed: () {
                  onIntent(const RequestBookSourceFileIntent());
                },
                icon: const Icon(Icons.file_open_outlined),
                label: const Text('选择书源文件'),
              )
            : null,
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(
        SpacingToken.medium,
        SpacingToken.small,
        SpacingToken.medium,
        72,
      ),
      itemCount: sources.length,
      separatorBuilder: (BuildContext context, int index) => const Divider(indent: 12),
      itemBuilder: (BuildContext context, int index) {
        /// 当前稳定 URL 主键书源。
        final BookSource source = sources[index];
        return _BookSourceCard(
          key: ValueKey<String>(source.bookSourceUrl),
          source: source,
          selected: state.selectedUrls.contains(source.bookSourceUrl),
          selectionMode: state.selectedUrls.isNotEmpty,
          busy: state.busy,
          onIntent: onIntent,
        );
      },
    );
  }

  /// 返回筛选器用户可见名称。
  String _filterLabel(BookSourceFilter filter) {
    return switch (filter) {
      BookSourceFilter.all => '全部',
      BookSourceFilter.enabled => '启用',
      BookSourceFilter.disabled => '停用',
      BookSourceFilter.ungrouped => '未分组',
      BookSourceFilter.javaScript => 'JavaScript',
    };
  }
}

/// 展示单个书源及其管理操作。
final class _BookSourceCard extends StatelessWidget {
  /// 创建书源卡片。
  const _BookSourceCard({
    required this.source,
    required this.selected,
    required this.selectionMode,
    required this.busy,
    required this.onIntent,
    super.key,
  });

  /// 当前书源。
  final BookSource source;

  /// 当前是否选中。
  final bool selected;

  /// 页面是否处于选择模式。
  final bool selectionMode;

  /// 是否禁止重复操作。
  final bool busy;

  /// Intent 入口。
  final ValueChanged<BookSourceManagementIntent> onIntent;

  /// 构建单个书源卡片。
  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? Theme.of(context).colorScheme.secondaryContainer : Colors.transparent,
      child: InkWell(
        onLongPress: () {
          onIntent(ToggleBookSourceSelectionIntent(source.bookSourceUrl));
        },
        onTap: selectionMode
            ? () {
                onIntent(ToggleBookSourceSelectionIntent(source.bookSourceUrl));
              }
            : () {
                onIntent(RequestEditBookSourceIntent(source.bookSourceUrl));
              },
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: SpacingToken.medium,
            vertical: SpacingToken.small,
          ),
          child: Row(
            children: <Widget>[
              if (selectionMode)
                Checkbox(
                  value: selected,
                  onChanged: (bool? value) {
                    onIntent(ToggleBookSourceSelectionIntent(source.bookSourceUrl));
                  },
                ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(source.bookSourceName, style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: SpacingToken.xSmall),
                    Text(
                      source.bookSourceUrl,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (source.bookSourceGroup?.trim().isNotEmpty == true)
                      Padding(
                        padding: const EdgeInsets.only(top: SpacingToken.xSmall),
                        child: Text(
                          '分组：${source.bookSourceGroup}',
                          style: Theme.of(context).textTheme.labelMedium,
                        ),
                      ),
                  ],
                ),
              ),
              Transform.scale(
                scale: 0.8,
                child: Switch(
                  value: source.enabled,
                  onChanged: busy
                      ? null
                      : (bool enabled) {
                          onIntent(
                            SetSingleBookSourceEnabledIntent(
                              sourceUrl: source.bookSourceUrl,
                              enabled: enabled,
                            ),
                          );
                        },
                ),
              ),
              PopupMenuButton<String>(
                iconSize: 18,
                enabled: !busy,
                onSelected: (String value) {
                  switch (value) {
                    case 'edit':
                      onIntent(RequestEditBookSourceIntent(source.bookSourceUrl));
                    case 'debug':
                      onIntent(DebugBookSourceIntent(source.bookSourceUrl));
                    case 'login':
                      onIntent(LoginBookSourceIntent(source.bookSourceUrl));
                    case 'delete':
                      onIntent(
                        RequestDeleteBookSourcesIntent(
                          sourceUrls: <String>{source.bookSourceUrl},
                        ),
                      );
                  }
                },
                itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                  const PopupMenuItem<String>(value: 'edit', child: Text('编辑')),
                  const PopupMenuItem<String>(value: 'debug', child: Text('基础调试')),
                  if (source.loginUrl != null || source.loginUi != null)
                    const PopupMenuItem<String>(value: 'login', child: Text('登录/Cookie')),
                  const PopupMenuDivider(),
                  const PopupMenuItem<String>(value: 'delete', child: Text('删除')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 选择模式底部批量操作栏。
final class _SelectionActions extends StatelessWidget {
  /// 创建批量操作栏。
  const _SelectionActions({required this.state, required this.onIntent});

  /// 当前页面状态。
  final BookSourceManagementUiState state;

  /// Intent 入口。
  final ValueChanged<BookSourceManagementIntent> onIntent;

  /// 构建批量启停、分组和删除操作栏。
  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Material(
        elevation: ElevationToken.overlay,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: SpacingToken.small,
            vertical: SpacingToken.xSmall,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: <Widget>[
              _action(Icons.check_circle_outline, '启用', () {
                onIntent(const SetSelectedBookSourcesEnabledIntent(true));
              }),
              _action(Icons.block_outlined, '停用', () {
                onIntent(const SetSelectedBookSourcesEnabledIntent(false));
              }),
              _action(Icons.folder_outlined, '分组', () {
                onIntent(const RequestSetBookSourceGroupIntent());
              }),
              _action(Icons.delete_outline, '删除', () {
                onIntent(RequestDeleteBookSourcesIntent());
              }),
            ],
          ),
        ),
      ),
    );
  }

  /// 创建带最小触摸区域的批量操作按钮。
  Widget _action(IconData icon, String label, VoidCallback onPressed) {
    return TextButton.icon(onPressed: onPressed, icon: Icon(icon), label: Text(label));
  }
}
