import 'dart:async';

import 'package:flutter/material.dart';

import '../../domain/model/book.dart';
import '../../domain/model/search_book.dart';
import '../../domain/usecase/update_book_custom_cover_use_case.dart';
import '../../model/web_book/book_cover_search_coordinator.dart';
import '../../platform/local_book_cover_service.dart';
import '../components/book_cover.dart';
import '../theme/app_tokens.dart';
import 'change_book_cover_contract.dart';
import 'change_book_cover_view_model.dart';

/// 展示共用封面选择底部面板，并在保存成功时返回数据库最新书籍。
Future<Book?> showChangeBookCoverSheet({
  required BuildContext context,
  required Book book,
  required List<SearchBook> initialCandidates,
  required BookCoverSearchCoordinator searchCoordinator,
  required UpdateBookCustomCoverUseCase updateCustomCover,
  required LocalBookCoverService localBookCoverService,
}) {
  return showModalBottomSheet<Book>(
    context: context,
    isScrollControlled: true,
    isDismissible: false,
    enableDrag: false,
    useSafeArea: true,
    builder: (BuildContext context) {
      return ChangeBookCoverSheet(
        book: book,
        initialCandidates: initialCandidates,
        searchCoordinator: searchCoordinator,
        updateCustomCover: updateCustomCover,
        localBookCoverService: localBookCoverService,
      );
    },
  );
}

/// 连接封面 ViewModel 生命周期和自适应懒加载网格。
final class ChangeBookCoverSheet extends StatefulWidget {
  /// 创建封面选择底部面板。
  const ChangeBookCoverSheet({
    required this.book,
    required this.initialCandidates,
    required this.searchCoordinator,
    required this.updateCustomCover,
    required this.localBookCoverService,
    super.key,
  });

  /// 当前书架书。
  final Book book;

  /// 详情页可复用的首批搜索候选。
  final List<SearchBook> initialCandidates;

  /// 面板生命周期独占的三级搜索协调器。
  final BookCoverSearchCoordinator searchCoordinator;

  /// 字段级封面更新动作。
  final UpdateBookCustomCoverUseCase updateCustomCover;

  /// 系统图片选择与应用私有封面副本管理边界。
  final LocalBookCoverService localBookCoverService;

  /// 创建底部面板状态。
  @override
  State<ChangeBookCoverSheet> createState() => _ChangeBookCoverSheetState();
}

/// 持有封面 ViewModel 和 Effect 订阅。
final class _ChangeBookCoverSheetState extends State<ChangeBookCoverSheet> {
  /// 页面生命周期内唯一 ViewModel。
  late final ChangeBookCoverViewModel _viewModel;

  /// 一次性 Effect 订阅。
  late final StreamSubscription<ChangeBookCoverEffect> _effectSubscription;

  /// 创建 ViewModel 并订阅保存结果。
  @override
  void initState() {
    super.initState();
    _viewModel = ChangeBookCoverViewModel(
      book: widget.book,
      initialCandidates: widget.initialCandidates,
      searchCoordinator: widget.searchCoordinator,
      updateCustomCover: widget.updateCustomCover,
    );
    _effectSubscription = _viewModel.effects.listen(_handleEffect);
  }

  /// 处理保存成功关闭和非阻断提示。
  void _handleEffect(ChangeBookCoverEffect effect) {
    if (!mounted) {
      return;
    }
    switch (effect) {
      case CloseBookCoverWithResultEffect(book: final Book book):
        unawaited(_closeWithSavedBook(book));
      case ShowChangeBookCoverMessageEffect(message: final String message):
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(message)));
      case RequestLocalBookCoverPickerEffect():
        unawaited(_pickLocalBookCover());
      case DeleteUnusedLocalBookCoverEffect(coverPath: final String coverPath):
        unawaited(_deleteUnusedLocalBookCover(coverPath));
    }
  }

  /// 打开系统图片选择器；平台返回后只把应用私有路径交回 ViewModel。
  Future<void> _pickLocalBookCover() async {
    try {
      /// 已复制到应用支持目录的本地封面路径；空值表示用户取消。
      final String? coverPath = await widget.localBookCoverService
          .pickAndPersist(widget.book.bookUrl);
      if (!mounted) {
        if (coverPath != null) {
          await widget.localBookCoverService.deleteManagedCover(
            coverPath,
            exceptPath: widget.book.customCoverUrl,
          );
        }
        return;
      }
      if (coverPath == null) {
        _viewModel.onIntent(const CancelLocalBookCoverPickIntent());
        return;
      }
      _viewModel.onIntent(LocalBookCoverPickedIntent(coverPath));
    } on Object {
      if (!mounted) {
        return;
      }
      _viewModel.onIntent(const CancelLocalBookCoverPickIntent());
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('选择或保存本地图片失败')));
    }
  }

  /// 保存成功后清理这本书旧的受管图片，再携带数据库最新书籍关闭面板。
  Future<void> _closeWithSavedBook(Book book) async {
    try {
      await widget.localBookCoverService.deleteManagedCover(
        widget.book.customCoverUrl,
        exceptPath: book.customCoverUrl,
      );
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(content: Text('旧本地封面清理失败，不影响新封面')),
          );
      }
    }
    if (mounted) {
      Navigator.of(context).pop(book);
    }
  }

  /// 删除数据库保存失败后未被引用的应用私有图片。
  Future<void> _deleteUnusedLocalBookCover(String coverPath) async {
    try {
      await widget.localBookCoverService.deleteManagedCover(coverPath);
    } on Object {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('未使用的本地封面清理失败')),
        );
    }
  }

  /// 释放搜索任务、订阅和 ViewModel。
  @override
  void dispose() {
    _effectSubscription.cancel();
    _viewModel.dispose();
    super.dispose();
  }

  /// 构建不允许保存中误关闭的底部面板。
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<ChangeBookCoverUiState>(
      stream: _viewModel.states,
      initialData: _viewModel.state,
      builder: (
        BuildContext context,
        AsyncSnapshot<ChangeBookCoverUiState> snapshot,
      ) {
        /// 当前可渲染状态。
        final ChangeBookCoverUiState state =
            snapshot.data ?? _viewModel.state;
        /// 面板高度上限，横屏和大屏不强制占满。
        final double height = (MediaQuery.sizeOf(context).height * 0.86)
            .clamp(420.0, 760.0)
            .toDouble();
        return PopScope<Object?>(
          canPop: !state.saving,
          child: SizedBox(
            height: height,
            child: Column(
              children: <Widget>[
                _ChangeBookCoverHeader(
                  state: state,
                  onIntent: _viewModel.onIntent,
                  onClose: state.saving
                      ? null
                      : () => Navigator.of(context).pop(),
                ),
                if (state.searching)
                  LinearProgressIndicator(
                    value: state.progress.total <= 0
                        ? null
                        : state.progress.completed / state.progress.total,
                  ),
                Expanded(
                  child: _ChangeBookCoverBody(
                    book: widget.book,
                    state: state,
                    onIntent: _viewModel.onIntent,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 底部面板标题、层级摘要和搜索控制区。
final class _ChangeBookCoverHeader extends StatelessWidget {
  /// 创建封面面板头部。
  const _ChangeBookCoverHeader({
    required this.state,
    required this.onIntent,
    required this.onClose,
  });

  /// 当前封面状态。
  final ChangeBookCoverUiState state;

  /// 用户操作回调。
  final ValueChanged<ChangeBookCoverIntent> onIntent;

  /// 关闭回调；保存中为空。
  final VoidCallback? onClose;

  /// 构建轻量头部。
  @override
  Widget build(BuildContext context) {
    /// 当前候选层级说明。
    final String? levelText = switch (state.matchLevel) {
      BookCoverMatchLevel.exactTitleAndAuthor => '书名和作者精确匹配',
      BookCoverMatchLevel.exactTitle => '书名精确匹配',
      BookCoverMatchLevel.fuzzyTitle => '书名模糊匹配',
      null => null,
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SpacingToken.medium,
        SpacingToken.small,
        SpacingToken.small,
        SpacingToken.small,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '更换封面',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                if (levelText != null)
                  Text(
                    '$levelText · ${state.candidates.length} 张',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
          ),
          if (state.searching)
            IconButton(
              onPressed: state.saving
                  ? null
                  : () => onIntent(const StopBookCoverSearchIntent()),
              icon: const Icon(Icons.stop_circle_outlined),
              tooltip: '停止搜索',
            )
          else
            IconButton(
              onPressed: state.initializing || state.saving
                  ? null
                  : () =>
                        onIntent(const RefreshBookCoverCandidatesIntent()),
              icon: const Icon(Icons.refresh),
              tooltip: '重新搜索封面',
            ),
          IconButton(
            onPressed:
                state.initializing || state.saving || state.pickingLocalImage
                ? null
                : () => onIntent(const PickLocalBookCoverIntent()),
            icon: state.pickingLocalImage
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.folder_open_outlined),
            tooltip: '选择本地图片',
          ),
          IconButton(
            onPressed: onClose,
            icon: const Icon(Icons.close),
            tooltip: '关闭',
          ),
        ],
      ),
    );
  }
}

/// 封面面板状态提示和自适应候选网格。
final class _ChangeBookCoverBody extends StatelessWidget {
  /// 创建封面面板主体。
  const _ChangeBookCoverBody({
    required this.book,
    required this.state,
    required this.onIntent,
  });

  /// 当前书架书。
  final Book book;

  /// 当前封面状态。
  final ChangeBookCoverUiState state;

  /// 用户操作回调。
  final ValueChanged<ChangeBookCoverIntent> onIntent;

  /// 构建状态摘要和懒加载网格。
  @override
  Widget build(BuildContext context) {
    /// 当前已有的自定义封面。
    final String currentCustomCover = book.customCoverUrl?.trim() ?? '';
    /// 是否额外展示当前自定义封面项。
    final bool hasCurrentCustomCover = currentCustomCover.isNotEmpty;
    /// 默认项、可选当前项和网络候选总数。
    final int itemCount =
        1 + (hasCurrentCustomCover ? 1 : 0) + state.candidates.length;
    return Column(
      children: <Widget>[
        if (state.initializing)
          const Padding(
            padding: EdgeInsets.all(SpacingToken.medium),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: SpacingToken.small),
                Text('正在读取已有封面'),
              ],
            ),
          ),
        if (state.statusMessage != null || state.errorMessage != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              SpacingToken.medium,
              SpacingToken.small,
              SpacingToken.medium,
              SpacingToken.small,
            ),
            child: Text(
              state.errorMessage ?? state.statusMessage ?? '',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: state.errorMessage == null
                    ? Theme.of(context).colorScheme.onSurfaceVariant
                    : Theme.of(context).colorScheme.error,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        Expanded(
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              /// 根据可用宽度选择列数，限制同时创建的图片 Widget 数量。
              final int crossAxisCount = constraints.maxWidth >= 720
                  ? 4
                  : constraints.maxWidth < 360
                  ? 2
                  : 3;
              return GridView.builder(
                padding: const EdgeInsets.all(SpacingToken.medium),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: crossAxisCount,
                  crossAxisSpacing: SpacingToken.small,
                  mainAxisSpacing: SpacingToken.small,
                  childAspectRatio: 0.58,
                ),
                itemCount: itemCount,
                itemBuilder: (BuildContext context, int index) {
                  if (index == 0) {
                    return _BookCoverChoiceCard(
                      key: const ValueKey<String>('default-cover'),
                      coverUrl: book.coverUrl,
                      bookName: book.name,
                      bookAuthor: book.author,
                      title: '恢复默认封面',
                      subtitle: book.originName.isEmpty
                          ? '书源默认'
                          : book.originName,
                      selected: currentCustomCover.isEmpty,
                      enabled: !state.saving && !state.pickingLocalImage,
                      onTap: () =>
                          onIntent(const RestoreDefaultBookCoverIntent()),
                    );
                  }
                  if (hasCurrentCustomCover && index == 1) {
                    return _BookCoverChoiceCard(
                      key: ValueKey<String>(
                        'current-custom-$currentCustomCover',
                      ),
                      coverUrl: currentCustomCover,
                      bookName: book.name,
                      bookAuthor: book.author,
                      title: '当前封面',
                      subtitle: '用户自定义',
                      selected: true,
                      enabled: !state.saving && !state.pickingLocalImage,
                      onTap: () => onIntent(
                        SelectBookCoverCandidateIntent(currentCustomCover),
                      ),
                    );
                  }
                  /// 扣除默认项和可选当前项后的网络候选索引。
                  final int candidateIndex =
                      index - 1 - (hasCurrentCustomCover ? 1 : 0);
                  /// 当前网络封面候选。
                  final BookCoverCandidate candidate =
                      state.candidates[candidateIndex];
                  return _BookCoverChoiceCard(
                    key: ValueKey<String>(
                      '${candidate.book.origin}\u0000${candidate.coverUrl}',
                    ),
                    coverUrl: candidate.coverUrl,
                    bookName: candidate.book.name,
                    bookAuthor: candidate.book.author,
                    title: candidate.book.originName.isEmpty
                        ? '未知书源'
                        : candidate.book.originName,
                    subtitle: candidate.book.author.isEmpty
                        ? '未知作者'
                        : candidate.book.author,
                    selected: currentCustomCover == candidate.coverUrl,
                    enabled: !state.saving && !state.pickingLocalImage,
                    onTap: () => onIntent(
                      SelectBookCoverCandidateIntent(candidate.coverUrl),
                    ),
                  );
                },
              );
            },
          ),
        ),
        if (state.saving)
          const Padding(
            padding: EdgeInsets.all(SpacingToken.medium),
            child: LinearProgressIndicator(),
          ),
      ],
    );
  }
}

/// 单个封面候选卡片。
final class _BookCoverChoiceCard extends StatelessWidget {
  /// 创建封面候选卡片。
  const _BookCoverChoiceCard({
    required this.coverUrl,
    required this.bookName,
    required this.bookAuthor,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.enabled,
    required this.onTap,
    super.key,
  });

  /// 封面 URL。
  final String? coverUrl;

  /// 封面缓存回退使用的书名。
  final String bookName;

  /// 封面缓存回退使用的作者。
  final String bookAuthor;

  /// 来源或操作标题。
  final String title;

  /// 作者或来源摘要。
  final String subtitle;

  /// 是否为当前已选择封面。
  final bool selected;

  /// 保存期间禁止重复选择。
  final bool enabled;

  /// 点击保存回调。
  final VoidCallback onTap;

  /// 构建带选中标识的封面卡片。
  @override
  Widget build(BuildContext context) {
    /// 当前主题配色。
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Material(
      color: selected
          ? colors.primaryContainer
          : colors.surfaceContainerLow,
      borderRadius: BorderRadius.circular(RadiusToken.medium),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.all(SpacingToken.small),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    BookCover(
                      coverUrl: coverUrl,
                      semanticLabel: '$title封面',
                      bookName: bookName,
                      bookAuthor: bookAuthor,
                      keepPreviousFrame: true,
                      borderRadius: BorderRadius.circular(RadiusToken.small),
                    ),
                    if (selected)
                      Align(
                        alignment: Alignment.topRight,
                        child: Padding(
                          padding: const EdgeInsets.all(SpacingToken.xSmall),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: colors.primary,
                              shape: BoxShape.circle,
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(
                                SpacingToken.xSmall,
                              ),
                              child: Icon(
                                Icons.check,
                                size: 16,
                                color: colors.onPrimary,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: SpacingToken.small),
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelLarge,
              ),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
