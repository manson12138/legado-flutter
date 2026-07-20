import 'package:flutter/material.dart';

import '../../domain/model/book.dart';
import '../../domain/model/book_chapter.dart';
import '../../domain/model/book_group.dart';
import '../../domain/model/search_book.dart';
import '../components/app_scaffold.dart';
import '../components/book_cover.dart';
import '../theme/app_tokens.dart';
import 'book_info_contract.dart';

/// 只渲染详情和目录状态并发送 Intent 的无状态页面。
final class BookInfoScreen extends StatelessWidget {
  /// 创建详情纯 UI。
  const BookInfoScreen({required this.state, required this.onIntent, super.key});
  /// ViewModel 提供的不可变状态。
  final BookInfoUiState state;
  /// 用户操作统一入口。
  final ValueChanged<BookInfoIntent> onIntent;

  /// 构建详情、换源、目录预览和加入书架操作。
  @override
  Widget build(BuildContext context) {
    /// 当前已经解析出的书籍，加载中时为空。
    final Book? book = state.book;
    return AppScaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: () => onIntent(const BackFromBookInfoIntent()),
          icon: const Icon(Icons.arrow_back),
          tooltip: '返回',
        ),
        title: Text(book?.name ?? state.selectedBook.name),
        actions: <Widget>[
          if (state.group.books.length > 1)
            PopupMenuButton<SearchBook>(
              tooltip: '更换书源',
              icon: const Icon(Icons.swap_horiz),
              onSelected: (SearchBook book) => onIntent(ChangeBookInfoSourceIntent(book)),
              itemBuilder: (BuildContext context) => state.group.books.map((SearchBook book) {
                return CheckedPopupMenuItem<SearchBook>(
                  value: book,
                  checked: book.origin == state.selectedBook.origin && book.bookUrl == state.selectedBook.bookUrl,
                  child: Text(book.originName),
                );
              }).toList(growable: false),
            ),
          _BookInfoMoreMenu(state: state, onIntent: onIntent),
        ],
      ),
      body: Stack(
        children: <Widget>[
          _BookInfoBody(state: state, onIntent: onIntent),
          _BookInfoDialogs(state: state, onIntent: onIntent),
        ],
      ),
      bottomNavigationBar: book == null ? null : _BookInfoReadBar(state: state, onIntent: onIntent),
    );
  }
}

/// 详情页底部阅读主按钮，对应 Android 详情页中的阅读主入口。
final class _BookInfoReadBar extends StatelessWidget {
  /// 创建底部阅读栏。
  const _BookInfoReadBar({required this.state, required this.onIntent});

  /// 当前详情页状态。
  final BookInfoUiState state;

  /// 用户操作统一入口。
  final ValueChanged<BookInfoIntent> onIntent;

  /// 构建避开系统手势区的阅读主按钮。
  @override
  Widget build(BuildContext context) {
    /// 当前是否允许进入阅读器。
    final bool canRead = _firstReadableChapterIndex(state.chapters) != null && !state.loadingToc && state.tocError == null;
    /// 当前主题颜色。
    final ColorScheme colors = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surface,
          boxShadow: ElevationToken.cardShadow,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            SpacingToken.medium,
            SpacingToken.mediumSmall,
            SpacingToken.medium,
            SpacingToken.mediumSmall,
          ),
          child: FilledButton.icon(
            onPressed: canRead ? () => _openPreferredChapter(state, onIntent) : null,
            icon: const Icon(Icons.menu_book_outlined),
            label: const Text('开始阅读'),
          ),
        ),
      ),
    );
  }
}

/// 详情页右上角更多菜单，对应 Android `BookInfoTopBarActions` 的首批轻量入口。
final class _BookInfoMoreMenu extends StatelessWidget {
  /// 创建更多菜单。
  const _BookInfoMoreMenu({required this.state, required this.onIntent});

  /// 当前详情页状态。
  final BookInfoUiState state;

  /// 用户操作统一入口。
  final ValueChanged<BookInfoIntent> onIntent;

  /// 构建刷新、整书换源和暂缓能力入口。
  @override
  Widget build(BuildContext context) {
    /// 当前书籍是否允许打开整书换源。
    final bool canOpenFullSourceChange = state.inBookshelf && state.book != null && state.book?.origin != 'loc_book';
    return PopupMenuButton<BookInfoMenuAction>(
      tooltip: '更多操作',
      icon: const Icon(Icons.more_vert),
      onSelected: (BookInfoMenuAction action) {
        if (action == BookInfoMenuAction.groupSelect) {
          _showGroupChoices(context, state, onIntent);
          return;
        }
        if (action == BookInfoMenuAction.featureMatrix) {
          _showFeatureMatrix(context, state, onIntent);
          return;
        }
        onIntent(BookInfoMenuActionIntent(action));
      },
      itemBuilder: (BuildContext context) {
        /// 当前书籍是否已在 Flutter 独立书架中。
        final bool inBookshelf = state.inBookshelf && state.book != null;
        /// 当前书籍是否有可复制目录地址。
        final bool hasTocUrl = state.book?.tocUrl.trim().isNotEmpty == true;
        return <PopupMenuEntry<BookInfoMenuAction>>[
          const PopupMenuItem<BookInfoMenuAction>(
            value: BookInfoMenuAction.refresh,
            child: ListTile(
              leading: Icon(Icons.refresh),
              title: Text('刷新详情'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
          const PopupMenuItem<BookInfoMenuAction>(
            value: BookInfoMenuAction.share,
            child: ListTile(
              leading: Icon(Icons.share_outlined),
              title: Text('分享'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
          const PopupMenuItem<BookInfoMenuAction>(
            value: BookInfoMenuAction.previewCover,
            child: ListTile(
              leading: Icon(Icons.image_outlined),
              title: Text('预览封面'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
          const PopupMenuItem<BookInfoMenuAction>(
            value: BookInfoMenuAction.changeCover,
            child: ListTile(
              leading: Icon(Icons.wallpaper_outlined),
              title: Text('更换封面'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
          const PopupMenuItem<BookInfoMenuAction>(
            value: BookInfoMenuAction.copyBookUrl,
            child: ListTile(
              leading: Icon(Icons.link),
              title: Text('复制书籍地址'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
          PopupMenuItem<BookInfoMenuAction>(
            value: BookInfoMenuAction.copyTocUrl,
            enabled: hasTocUrl,
            child: const ListTile(
              leading: Icon(Icons.format_list_bulleted),
              title: Text('复制目录地址'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
          PopupMenuItem<BookInfoMenuAction>(
            value: BookInfoMenuAction.editRemark,
            enabled: inBookshelf,
            child: const ListTile(
              leading: Icon(Icons.edit_note),
              title: Text('编辑备注'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
          PopupMenuItem<BookInfoMenuAction>(
            value: BookInfoMenuAction.groupSelect,
            enabled: inBookshelf,
            child: const ListTile(
              leading: Icon(Icons.folder_copy_outlined),
              title: Text('设置分组'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
          PopupMenuItem<BookInfoMenuAction>(
            value: BookInfoMenuAction.toggleCanUpdate,
            enabled: inBookshelf,
            child: ListTile(
              leading: Icon(state.book?.canUpdate == true ? Icons.sync_disabled_outlined : Icons.sync_outlined),
              title: Text(state.book?.canUpdate == true ? '禁止更新' : '允许更新'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
          PopupMenuItem<BookInfoMenuAction>(
            value: BookInfoMenuAction.fullSourceChange,
            enabled: canOpenFullSourceChange,
            child: const ListTile(
              leading: Icon(Icons.manage_search),
              title: Text('整书换源'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
          const PopupMenuItem<BookInfoMenuAction>(
            value: BookInfoMenuAction.readRecord,
            child: ListTile(
              leading: Icon(Icons.timeline),
              title: Text('阅读记录'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
          const PopupMenuItem<BookInfoMenuAction>(
            value: BookInfoMenuAction.featureMatrix,
            child: ListTile(
              leading: Icon(Icons.extension_outlined),
              title: Text('后续能力'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
          PopupMenuItem<BookInfoMenuAction>(
            value: BookInfoMenuAction.deleteBook,
            enabled: inBookshelf,
            child: const ListTile(
              leading: Icon(Icons.delete_outline),
              title: Text('移出书架'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ];
      },
    );
  }
}

/// 详情页普通对话框渲染层，对应 Android `BookInfoDialogs` 的 Flutter P1 子集。
final class _BookInfoDialogs extends StatelessWidget {
  /// 创建详情页对话框渲染层。
  const _BookInfoDialogs({required this.state, required this.onIntent});

  /// 当前详情页状态。
  final BookInfoUiState state;

  /// 用户操作统一入口。
  final ValueChanged<BookInfoIntent> onIntent;

  /// 根据状态展示删除或备注编辑对话框。
  @override
  Widget build(BuildContext context) {
    /// 当前需要展示的普通对话框。
    final BookInfoDialog? dialog = state.dialog;
    if (dialog == null) {
      return const SizedBox.shrink();
    }
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black54,
        child: Center(
          child: switch (dialog) {
            DeleteBookInfoDialog(book: final Book book) => _DeleteBookInfoDialog(
                book: book,
                onCancel: () => onIntent(const DismissBookInfoDialogIntent()),
                onConfirm: () => onIntent(const ConfirmDeleteBookInfoIntent()),
              ),
            EditBookInfoRemarkDialog(initialRemark: final String initialRemark) => _EditBookInfoRemarkDialog(
                initialRemark: initialRemark,
                onCancel: () => onIntent(const DismissBookInfoDialogIntent()),
                onConfirm: (String remark) => onIntent(UpdateBookInfoRemarkIntent(remark)),
              ),
            PreviewBookCoverDialog(coverUrl: final String coverUrl, title: final String title) => _PreviewBookCoverDialog(
                coverUrl: coverUrl,
                title: title,
                onClose: () => onIntent(const DismissBookInfoDialogIntent()),
              ),
          },
        ),
      ),
    );
  }
}

/// 删除书籍确认框，对应 Android `BookInfoDialog.DeleteBook`。
final class _DeleteBookInfoDialog extends StatelessWidget {
  /// 创建删除确认框。
  const _DeleteBookInfoDialog({
    required this.book,
    required this.onCancel,
    required this.onConfirm,
  });

  /// 待删除书籍。
  final Book book;

  /// 取消删除。
  final VoidCallback onCancel;

  /// 确认删除。
  final VoidCallback onConfirm;

  /// 构建删除确认框。
  @override
  Widget build(BuildContext context) {
    /// 安全书名。
    final String bookName = book.name.isEmpty ? '当前书籍' : '《${book.name}》';
    return AlertDialog(
      icon: const Icon(Icons.delete_outline),
      title: const Text('移出书架'),
      content: Text('$bookName 将从 Flutter 书架移除，目录会随书籍一起删除。'),
      actions: <Widget>[
        TextButton(onPressed: onCancel, child: const Text('取消')),
        FilledButton(onPressed: onConfirm, child: const Text('移除')),
      ],
    );
  }
}

/// 备注编辑框，对应 Android `BookInfoDialog.EditRemark`。
final class _EditBookInfoRemarkDialog extends StatefulWidget {
  /// 创建备注编辑框。
  const _EditBookInfoRemarkDialog({
    required this.initialRemark,
    required this.onCancel,
    required this.onConfirm,
  });

  /// 初始备注。
  final String initialRemark;

  /// 取消编辑。
  final VoidCallback onCancel;

  /// 保存备注。
  final ValueChanged<String> onConfirm;

  /// 创建可维护输入控制器的状态。
  @override
  State<_EditBookInfoRemarkDialog> createState() => _EditBookInfoRemarkDialogState();
}

/// 持有备注编辑输入控制器。
final class _EditBookInfoRemarkDialogState extends State<_EditBookInfoRemarkDialog> {
  /// 备注输入控制器。
  late final TextEditingController _controller;

  /// 初始化备注文本。
  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialRemark);
  }

  /// 释放备注输入控制器。
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 构建备注编辑框。
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: const Icon(Icons.edit_note),
      title: const Text('编辑备注'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: TextField(
          controller: _controller,
          minLines: 1,
          maxLines: 4,
          decoration: const InputDecoration(
            labelText: '备注',
            hintText: '可留空清除备注',
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: widget.onCancel, child: const Text('取消')),
        FilledButton(
          onPressed: () => widget.onConfirm(_controller.text),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

/// 封面预览框，对应 Android `PhotoPreview` 的 Flutter P2 轻量实现。
final class _PreviewBookCoverDialog extends StatelessWidget {
  /// 创建封面预览框。
  const _PreviewBookCoverDialog({
    required this.coverUrl,
    required this.title,
    required this.onClose,
  });

  /// 当前要预览的封面地址。
  final String coverUrl;

  /// 对话框标题。
  final String title;

  /// 关闭预览。
  final VoidCallback onClose;

  /// 构建大图封面预览。
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360, maxHeight: 520),
        child: AspectRatio(
          aspectRatio: LayoutToken.bookCoverAspectRatio,
          child: BookCover(
            coverUrl: coverUrl,
            semanticLabel: '$title封面预览',
            fit: BoxFit.contain,
            borderRadius: BorderRadius.circular(RadiusToken.medium),
          ),
        ),
      ),
      actions: <Widget>[
        FilledButton(onPressed: onClose, child: const Text('关闭')),
      ],
    );
  }
}

/// 根据详情加载状态构建页面主体。
final class _BookInfoBody extends StatelessWidget {
  /// 创建详情主体。
  const _BookInfoBody({required this.state, required this.onIntent});
  /// 当前状态。
  final BookInfoUiState state;
  /// Intent 入口。
  final ValueChanged<BookInfoIntent> onIntent;

  /// 构建加载、错误或详情内容。
  @override
  Widget build(BuildContext context) {
    if (state.loadingInfo) {
      return const Center(child: CircularProgressIndicator());
    }
    /// 已解析书籍。
    final Book? book = state.book;
    if (book == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(state.infoError ?? '详情加载失败'),
            const SizedBox(height: SpacingToken.medium),
            FilledButton(onPressed: () => onIntent(const RetryBookInfoIntent()), child: const Text('重试详情')),
          ],
        ),
      );
    }
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        /// 宽屏下把详情和目录约束在统一内容宽度内的水平留白。
        final double horizontalPadding = constraints.maxWidth > LayoutToken.contentMaxWidth
            ? (constraints.maxWidth - LayoutToken.contentMaxWidth) / 2
            : SpacingToken.medium;
        /// 当前屏幕是否需要压缩头部封面尺寸。
        final bool compact = constraints.maxWidth < LayoutToken.compactBreakpoint;
        return ListView(
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            SpacingToken.small,
            horizontalPadding,
            92,
          ),
          children: <Widget>[
            _BookInfoHero(book: book, compact: compact, onIntent: onIntent),
            const SizedBox(height: SpacingToken.medium),
            _BookInfoPrimaryActions(state: state, onIntent: onIntent),
            const SizedBox(height: SpacingToken.medium),
            _BookInfoSummaryCard(book: book, state: state),
            const SizedBox(height: SpacingToken.medium),
            _BookInfoChapterPreview(state: state, onIntent: onIntent),
          ],
        );
      },
    );
  }
}

/// 详情页头部主视觉，对应 Android `BookInfoHeader` 的 P0 Flutter 版本。
final class _BookInfoHero extends StatelessWidget {
  /// 创建头部主视觉。
  const _BookInfoHero({required this.book, required this.compact, required this.onIntent});

  /// 当前已解析书籍。
  final Book book;

  /// 是否使用手机紧凑布局。
  final bool compact;

  /// 用户操作统一入口。
  final ValueChanged<BookInfoIntent> onIntent;

  /// 构建封面、书名、作者、来源和标签。
  @override
  Widget build(BuildContext context) {
    /// 当前主题颜色。
    final ColorScheme colors = Theme.of(context).colorScheme;
    /// 当前封面地址，优先使用用户自定义封面。
    final String? coverUrl = book.customCoverUrl?.trim().isNotEmpty == true ? book.customCoverUrl : book.coverUrl;
    /// 头部封面宽度。
    final double coverWidth = compact ? 86 : 112;
    /// 需要展示的标签文本。
    final List<String> tags = _bookInfoTags(book);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(RadiusToken.large),
      ),
      child: Padding(
        padding: const EdgeInsets.all(SpacingToken.large),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            GestureDetector(
              onTap: () => onIntent(const PreviewBookInfoCoverIntent()),
              onLongPress: () => onIntent(const BookInfoMenuActionIntent(BookInfoMenuAction.changeCover)),
              child: SizedBox(
                width: coverWidth,
                child: AspectRatio(
                  aspectRatio: LayoutToken.bookCoverAspectRatio,
                  child: BookCover(
                    coverUrl: coverUrl,
                    semanticLabel: '${book.name}封面',
                    borderRadius: BorderRadius.circular(RadiusToken.medium),
                    bookName: book.name,
                    bookAuthor: book.author,
                  ),
                ),
              ),
            ),
            const SizedBox(width: SpacingToken.large),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    book.name.isEmpty ? '未命名书籍' : book.name,
                    style: Theme.of(context).textTheme.headlineSmall,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: SpacingToken.small),
                  Text(
                    book.author.isEmpty ? '未知作者' : book.author,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: colors.onSurfaceVariant),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: SpacingToken.small),
                  Text(
                    '来源 · ${book.originName.isEmpty ? '未知来源' : book.originName}',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(color: colors.primary),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (tags.isNotEmpty) ...<Widget>[
                    const SizedBox(height: SpacingToken.mediumSmall),
                    Wrap(
                      spacing: SpacingToken.small,
                      runSpacing: SpacingToken.small,
                      children: tags.map((String tag) => _BookInfoTag(text: tag)).toList(growable: false),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 生成详情头部和摘要区共用的标签，对应 Android `kindLabels` 和分组标签的首批近似。
List<String> _bookInfoTags(Book book) {
  /// 从书籍分类字段拆出的标签。
  final List<String> kindTags = _splitTagText(book.kind);
  /// 从用户自定义标签字段拆出的标签。
  final List<String> customTags = _splitTagText(book.customTag);
  /// 书籍分组位掩码的简短说明。
  final String? groupTag = book.group == 0 ? null : '分组 ${book.group}';
  return <String>[
    ...kindTags,
    ...customTags,
    if (groupTag != null) groupTag,
  ].take(6).toList(growable: false);
}

/// 拆分 Android 详情页常见的分类/标签字符串。
List<String> _splitTagText(String? text) {
  /// 清理后的原始标签文本。
  final String value = text?.trim() ?? '';
  if (value.isEmpty) {
    return const <String>[];
  }
  return value
      .split(RegExp(r'[,，;；|/、\s]+'))
      .map((String item) => item.trim())
      .where((String item) => item.isNotEmpty)
      .take(4)
      .toList(growable: false);
}

/// 详情头部内的小标签。
final class _BookInfoTag extends StatelessWidget {
  /// 创建标签。
  const _BookInfoTag({required this.text});

  /// 标签展示文本。
  final String text;

  /// 构建轻量标签。
  @override
  Widget build(BuildContext context) {
    /// 当前主题颜色。
    final ColorScheme colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.secondaryContainer,
        borderRadius: BorderRadius.circular(RadiusToken.pill),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: SpacingToken.mediumSmall, vertical: SpacingToken.xSmall),
        child: Text(
          text,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: colors.onSecondaryContainer),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}

/// 详情页四个主操作卡，对应 Android `BookInfoActions` 的 P0 版本。
final class _BookInfoPrimaryActions extends StatelessWidget {
  /// 创建主操作区。
  const _BookInfoPrimaryActions({required this.state, required this.onIntent});

  /// 当前详情页状态。
  final BookInfoUiState state;

  /// 用户操作统一入口。
  final ValueChanged<BookInfoIntent> onIntent;

  /// 构建书架、目录、书源和阅读记录入口。
  @override
  Widget build(BuildContext context) {
    /// 当前是否允许普通加入书架按钮触发。
    final bool canAddToShelf = !state.addingToShelf &&
        !state.inBookshelf &&
        !state.loadingToc &&
        state.tocError == null &&
        state.chapters.isNotEmpty;
    /// 当前是否允许打开目录第一个可读章节。
    final bool canRead = _firstReadableChapterIndex(state.chapters) != null && !state.loadingToc && state.tocError == null;
    return Column(
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: _BookInfoActionCard(
                icon: state.inBookshelf ? Icons.check_circle_outline : Icons.library_add_outlined,
                label: state.inBookshelf ? '已在书架' : state.addingToShelf ? '正在加入' : '加入书架',
                enabled: state.inBookshelf || canAddToShelf,
                onTap: state.inBookshelf ? null : () => onIntent(const AddBookToShelfIntent()),
              ),
            ),
            const SizedBox(width: SpacingToken.small),
            Expanded(
              child: _BookInfoActionCard(
                icon: Icons.format_list_bulleted,
                label: '查看目录',
                enabled: canRead,
                onTap: () => _showFullChapterList(context, state, onIntent),
              ),
            ),
          ],
        ),
        const SizedBox(height: SpacingToken.small),
        Row(
          children: <Widget>[
            Expanded(
              child: _BookInfoActionCard(
                icon: Icons.manage_search,
                label: state.group.books.length > 1 || state.inBookshelf ? '书源 / 换源' : '书源',
                enabled: state.group.books.length > 1 || (state.inBookshelf && state.book != null && state.book?.origin != 'loc_book'),
                onTap: state.group.books.length > 1
                    ? () => _showSourceChoices(context, state, onIntent)
                    : () => onIntent(const OpenBookInfoFullSourceChangeIntent()),
              ),
            ),
            const SizedBox(width: SpacingToken.small),
            Expanded(
              child: _BookInfoActionCard(
                icon: Icons.timeline,
                label: '阅读记录',
                enabled: true,
                onTap: () => onIntent(const BookInfoMenuActionIntent(BookInfoMenuAction.readRecord)),
              ),
            ),
          ],
        ),
        const SizedBox(height: SpacingToken.small),
        Row(
          children: <Widget>[
            Expanded(
              child: _BookInfoActionCard(
                icon: Icons.folder_copy_outlined,
                label: _groupActionLabel(state),
                enabled: state.inBookshelf && state.book != null,
                onTap: () => _showGroupChoices(context, state, onIntent),
              ),
            ),
            const SizedBox(width: SpacingToken.small),
            Expanded(
              child: _BookInfoActionCard(
                icon: Icons.extension_outlined,
                label: '后续能力',
                enabled: true,
                onTap: () => _showFeatureMatrix(context, state, onIntent),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 生成分组操作卡文案。
String _groupActionLabel(BookInfoUiState state) {
  /// 当前书籍分组位值。
  final int groupId = state.book?.group ?? 0;
  if (groupId == 0) {
    return '设置分组';
  }
  /// 当前命中的用户分组。
  final BookGroup? group = _findGroupById(state.groups, groupId);
  return group == null ? '分组 $groupId' : group.groupName;
}

/// 从用户分组列表查找指定分组。
BookGroup? _findGroupById(List<BookGroup> groups, int groupId) {
  for (final BookGroup group in groups) {
    if (group.groupId == groupId) {
      return group;
    }
  }
  return null;
}

/// 打开优先阅读章节：已读章节优先，否则使用第一个非卷标题章节。
void _openPreferredChapter(BookInfoUiState state, ValueChanged<BookInfoIntent> onIntent) {
  /// 当前已解析书籍。
  final Book? book = state.book;
  /// 从阅读进度推断出的章节索引。
  final int? progressIndex = book == null ? null : _readableChapterIndexAt(state.chapters, book.durChapterIndex);
  /// 第一个可阅读章节索引。
  final int? fallbackIndex = _firstReadableChapterIndex(state.chapters);
  /// 最终要打开的章节索引。
  final int? targetIndex = progressIndex ?? fallbackIndex;
  if (targetIndex == null) {
    return;
  }
  onIntent(OpenBookInfoChapterIntent(targetIndex));
}

/// 查找指定位置是否对应可阅读章节。
int? _readableChapterIndexAt(List<BookChapter> chapters, int index) {
  if (index < 0 || index >= chapters.length) {
    return null;
  }
  /// 指定位置上的章节。
  final BookChapter chapter = chapters[index];
  return chapter.isVolume ? null : index;
}

/// 查找目录中第一个非卷标题章节。
int? _firstReadableChapterIndex(List<BookChapter> chapters) {
  for (int index = 0; index < chapters.length; index += 1) {
    /// 当前扫描到的章节。
    final BookChapter chapter = chapters[index];
    if (!chapter.isVolume) {
      return index;
    }
  }
  return null;
}

/// 显示完整目录底部面板，对应 Android `TocClick` 的 P0 Flutter 近似。
Future<void> _showFullChapterList(
  BuildContext context,
  BookInfoUiState state,
  ValueChanged<BookInfoIntent> onIntent,
) async {
  /// 用户在完整目录中选择的章节索引。
  final int? selectedChapterIndex = await showModalBottomSheet<int>(
    context: context,
    showDragHandle: true,
    builder: (BuildContext context) {
      return SafeArea(
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                SpacingToken.large,
                SpacingToken.small,
                SpacingToken.large,
                SpacingToken.medium,
              ),
              child: Row(
                children: <Widget>[
                  Text('目录（${state.chapters.length}）', style: Theme.of(context).textTheme.titleMedium),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('关闭'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: state.chapters.length,
                itemBuilder: (BuildContext context, int index) {
                  /// 当前目录项对应的章节对象。
                  final BookChapter chapter = state.chapters[index];
                  return ListTile(
                    key: ValueKey<String>('toc-sheet-${chapter.index}:${chapter.url}'),
                    dense: true,
                    leading: Text('${chapter.index + 1}'),
                    title: Text(chapter.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: chapter.tag == null ? null : Text(chapter.tag ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
                    enabled: !chapter.isVolume && !state.addingToShelf,
                    onTap: chapter.isVolume || state.addingToShelf ? null : () => Navigator.of(context).pop(index),
                  );
                },
              ),
            ),
          ],
        ),
      );
    },
  );
  if (selectedChapterIndex != null) {
    onIntent(OpenBookInfoChapterIntent(selectedChapterIndex));
  }
}

/// 显示当前搜索结果组内的基础换源选择。
Future<void> _showSourceChoices(
  BuildContext context,
  BookInfoUiState state,
  ValueChanged<BookInfoIntent> onIntent,
) async {
  /// 用户选择的新来源。
  final SearchBook? selected = await showModalBottomSheet<SearchBook>(
    context: context,
    showDragHandle: true,
    builder: (BuildContext context) {
      return SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: state.group.books.map((SearchBook book) {
            /// 当前来源是否为已选来源。
            final bool checked = book.origin == state.selectedBook.origin && book.bookUrl == state.selectedBook.bookUrl;
            return ListTile(
              leading: Icon(checked ? Icons.radio_button_checked : Icons.radio_button_unchecked),
              title: Text(book.originName.isEmpty ? '未知来源' : book.originName),
              subtitle: Text(book.latestChapterTitle?.trim().isNotEmpty == true ? book.latestChapterTitle ?? '' : book.bookUrl),
              onTap: () => Navigator.of(context).pop(book),
            );
          }).toList(growable: false),
        ),
      );
    },
  );
  if (selected != null) {
    onIntent(ChangeBookInfoSourceIntent(selected));
  }
}

/// 显示书架分组选择面板，对应 Android `GroupSelectSheet` 的 Flutter P2 版本。
Future<void> _showGroupChoices(
  BuildContext context,
  BookInfoUiState state,
  ValueChanged<BookInfoIntent> onIntent,
) async {
  if (!state.inBookshelf || state.book == null) {
    onIntent(const BookInfoMenuActionIntent(BookInfoMenuAction.groupSelect));
    return;
  }
  /// 用户当前选择的分组动作。
  final _BookInfoGroupChoice? selected = await showModalBottomSheet<_BookInfoGroupChoice>(
    context: context,
    showDragHandle: true,
    builder: (BuildContext context) {
      /// 当前书籍分组位值。
      final int currentGroupId = state.book?.group ?? 0;
      return SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            ListTile(
              leading: Icon(currentGroupId == 0 ? Icons.radio_button_checked : Icons.radio_button_unchecked),
              title: const Text('不使用用户分组'),
              onTap: () => Navigator.of(context).pop(const _BookInfoExistingGroupChoice(0)),
            ),
            ...state.groups.map((BookGroup group) {
              /// 当前分组是否已经选中。
              final bool checked = group.groupId == currentGroupId;
              return ListTile(
                leading: Icon(checked ? Icons.radio_button_checked : Icons.radio_button_unchecked),
                title: Text(group.groupName),
                onTap: () => Navigator.of(context).pop(_BookInfoExistingGroupChoice(group.groupId)),
              );
            }),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: const Text('新建分组'),
              onTap: () => Navigator.of(context).pop(const _BookInfoCreateGroupChoice()),
            ),
          ],
        ),
      );
    },
  );
  switch (selected) {
    case null:
      return;
    case _BookInfoExistingGroupChoice(groupId: final int groupId):
      onIntent(UpdateBookInfoGroupIntent(groupId));
    case _BookInfoCreateGroupChoice():
      /// 用户输入的新分组名称。
      final String? name = await _showCreateGroupDialog(context);
      if (name != null) {
        onIntent(CreateBookInfoGroupIntent(name));
      }
  }
}

/// 请求用户输入新书架分组名称。
Future<String?> _showCreateGroupDialog(BuildContext context) async {
  /// 新分组名称输入控制器。
  final TextEditingController controller = TextEditingController();
  try {
    /// 用户最终提交的新分组名称。
    final String? name = await showDialog<String>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          icon: const Icon(Icons.create_new_folder_outlined),
          title: const Text('新建分组'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(labelText: '分组名称'),
            textInputAction: TextInputAction.done,
            onSubmitted: (String value) => Navigator.of(context).pop(value),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: const Text('创建'),
            ),
          ],
        );
      },
    );
    return name;
  } finally {
    controller.dispose();
  }
}

/// 显示 P2/P3 后续能力面板，保留 Android 功能映射和当前处理策略。
Future<void> _showFeatureMatrix(
  BuildContext context,
  BookInfoUiState state,
  ValueChanged<BookInfoIntent> onIntent,
) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (BuildContext sheetContext) {
      return SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                SpacingToken.large,
                SpacingToken.small,
                SpacingToken.large,
                SpacingToken.medium,
              ),
              child: Text('Android 详情页后续能力', style: Theme.of(sheetContext).textTheme.titleMedium),
            ),
            _BookInfoFeatureTile(
              icon: Icons.image_outlined,
              title: '封面预览',
              subtitle: '已接入：点击封面或菜单可预览当前封面。',
              onTap: () {
                Navigator.of(sheetContext).pop();
                onIntent(const PreviewBookInfoCoverIntent());
              },
            ),
            const _BookInfoFeatureTile(
              icon: Icons.wallpaper_outlined,
              title: '换封面 / 保存封面',
              subtitle: '待接入封面搜索协调器和封面缓存策略。',
            ),
            _BookInfoFeatureTile(
              icon: Icons.folder_copy_outlined,
              title: '书架分组',
              subtitle: state.inBookshelf ? '已接入：可选择已有分组或新建分组。' : '需先加入书架后设置分组。',
              onTap: state.inBookshelf
                  ? () {
                      Navigator.of(sheetContext).pop();
                      _showGroupChoices(context, state, onIntent);
                    }
                  : null,
            ),
            const _BookInfoFeatureTile(
              icon: Icons.timeline,
              title: '阅读记录',
              subtitle: '待 readRecord 表和阅读器写入记录稳定后展示时间线。',
            ),
            const _BookInfoFeatureTile(
              icon: Icons.manage_search,
              title: '完整换源 Sheet',
              subtitle: '当前使用独立整书换源页；详情内候选预览和迁移选项留到 M11 后续。',
            ),
            const _BookInfoFeatureTile(
              icon: Icons.auto_stories_outlined,
              title: '相关书',
              subtitle: '待规则字段解析和发现/搜索跳转能力接入。',
            ),
            const _BookInfoFeatureTile(
              icon: Icons.login_outlined,
              title: '书源登录和变量',
              subtitle: '待 WebView/Cookie 真机验证和变量 Gateway 接入。',
            ),
            const _BookInfoFeatureTile(
              icon: Icons.file_download_outlined,
              title: 'Web 文件 / 压缩包',
              subtitle: '待文件下载、压缩包和本地书导入能力稳定后接入。',
            ),
            _BookInfoFeatureTile(
              icon: state.book?.canUpdate == true ? Icons.sync_disabled_outlined : Icons.sync_outlined,
              title: state.book?.canUpdate == true ? '禁止更新' : '允许更新',
              subtitle: state.inBookshelf ? '已接入：切换书架刷新时是否更新本书。' : '需先加入书架后修改。',
              onTap: state.inBookshelf
                  ? () {
                      Navigator.of(sheetContext).pop();
                      onIntent(const ToggleBookInfoCanUpdateIntent());
                    }
                  : null,
            ),
            const _BookInfoFeatureTile(
              icon: Icons.cleaning_services_outlined,
              title: '清缓存 / 日志 / 同步',
              subtitle: '待明确缓存范围、全局日志入口和 WebDAV 同步能力后逐项接入。',
            ),
          ],
        ),
      );
    },
  );
}

/// 分组面板选择结果基类。
sealed class _BookInfoGroupChoice {
  /// 限制分组选择结果类型。
  const _BookInfoGroupChoice();
}

/// 已有分组或清除分组选择结果。
final class _BookInfoExistingGroupChoice extends _BookInfoGroupChoice {
  /// 创建已有分组选择结果。
  const _BookInfoExistingGroupChoice(this.groupId);

  /// 目标分组位值；0 表示清除分组。
  final int groupId;
}

/// 新建分组选择结果。
final class _BookInfoCreateGroupChoice extends _BookInfoGroupChoice {
  /// 创建新建分组选择结果。
  const _BookInfoCreateGroupChoice();
}

/// 后续能力面板中的单行能力说明。
final class _BookInfoFeatureTile extends StatelessWidget {
  /// 创建能力说明行。
  const _BookInfoFeatureTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
  });

  /// 能力图标。
  final IconData icon;

  /// 能力名称。
  final String title;

  /// 当前状态和处理策略。
  final String subtitle;

  /// 可立即执行的能力入口。
  final VoidCallback? onTap;

  /// 构建能力说明行。
  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      onTap: onTap,
    );
  }
}

/// 详情页主操作按钮卡片。
final class _BookInfoActionCard extends StatelessWidget {
  /// 创建操作卡。
  const _BookInfoActionCard({
    required this.icon,
    required this.label,
    required this.enabled,
    required this.onTap,
  });

  /// 操作图标。
  final IconData icon;

  /// 操作文案。
  final String label;

  /// 是否允许点击。
  final bool enabled;

  /// 点击回调；为空时只展示状态。
  final VoidCallback? onTap;

  /// 构建稳定高度的操作卡，避免状态文案切换时布局跳动。
  @override
  Widget build(BuildContext context) {
    /// 当前主题颜色。
    final ColorScheme colors = Theme.of(context).colorScheme;
    /// 实际点击回调。
    final VoidCallback? action = enabled ? onTap : null;
    return Semantics(
      button: action != null,
      enabled: enabled,
      label: label,
      child: Material(
        color: enabled ? colors.surfaceContainerLow : colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(RadiusToken.medium),
        child: InkWell(
          onTap: action,
          borderRadius: BorderRadius.circular(RadiusToken.medium),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: LayoutToken.minimumTouchTarget),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: SpacingToken.small, vertical: SpacingToken.mediumSmall),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(icon, color: enabled ? colors.primary : colors.onSurfaceVariant),
                  const SizedBox(height: SpacingToken.xSmall),
                  Text(
                    label,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          color: enabled ? colors.onSurface : colors.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 详情摘要卡，对应 Android `BookInfoSummary` 的 P0 信息层级。
final class _BookInfoSummaryCard extends StatelessWidget {
  /// 创建摘要卡。
  const _BookInfoSummaryCard({required this.book, required this.state});

  /// 当前已解析书籍。
  final Book book;

  /// 当前详情页状态。
  final BookInfoUiState state;

  /// 构建最新章节、阅读进度、备注和简介。
  @override
  Widget build(BuildContext context) {
    /// 当前主题颜色。
    final ColorScheme colors = Theme.of(context).colorScheme;
    /// 简介展示文本，优先使用用户自定义简介。
    final String intro = _displayText(book.customIntro, book.intro, fallback: '暂无简介');
    /// 备注展示文本。
    final String remark = book.remark?.trim() ?? '';
    return Card(
      elevation: ElevationToken.none,
      color: colors.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(SpacingToken.large),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('书籍概览', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: SpacingToken.medium),
            _BookInfoMetaRow(label: '最新', value: book.latestChapterTitle?.trim().isNotEmpty == true ? book.latestChapterTitle ?? '' : '暂无最新章节'),
            _BookInfoMetaRow(label: '目录', value: _tocStatusText(state)),
            _BookInfoMetaRow(label: '进度', value: _progressText(book, state.chapters.length)),
            if (book.wordCount?.trim().isNotEmpty == true) _BookInfoMetaRow(label: '字数', value: book.wordCount ?? ''),
            if (remark.isNotEmpty) ...<Widget>[
              const SizedBox(height: SpacingToken.small),
              Text('备注', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: SpacingToken.xSmall),
              Text(remark),
            ],
            const SizedBox(height: SpacingToken.medium),
            Text('简介', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: SpacingToken.xSmall),
            Text(intro),
          ],
        ),
      ),
    );
  }
}

/// 选择第一个非空文本，否则使用兜底文本。
String _displayText(String? primary, String? secondary, {required String fallback}) {
  /// 第一优先级文本。
  final String first = primary?.trim() ?? '';
  if (first.isNotEmpty) {
    return first;
  }
  /// 第二优先级文本。
  final String second = secondary?.trim() ?? '';
  if (second.isNotEmpty) {
    return second;
  }
  return fallback;
}

/// 生成目录状态文案。
String _tocStatusText(BookInfoUiState state) {
  if (state.loadingToc) {
    return '目录加载中';
  }
  if (state.tocError != null) {
    return '目录加载失败';
  }
  if (state.chapters.isEmpty) {
    return '暂无目录';
  }
  return '${state.chapters.length} 章';
}

/// 生成阅读进度文案。
String _progressText(Book book, int chapterCount) {
  if (chapterCount <= 0) {
    return '尚未开始阅读';
  }
  /// 归一后的从零开始章节索引。
  final int boundedIndex = book.durChapterIndex < 0
      ? 0
      : book.durChapterIndex >= chapterCount
          ? chapterCount - 1
          : book.durChapterIndex;
  /// 对用户展示的从一开始章节序号。
  final int displayIndex = boundedIndex + 1;
  /// 当前阅读章节标题。
  final String title = book.durChapterTitle?.trim() ?? '';
  if (title.isEmpty) {
    return '第 $displayIndex / $chapterCount 章';
  }
  return '第 $displayIndex / $chapterCount 章 · $title';
}

/// 摘要卡内的两列元信息行。
final class _BookInfoMetaRow extends StatelessWidget {
  /// 创建元信息行。
  const _BookInfoMetaRow({required this.label, required this.value});

  /// 左侧标签。
  final String label;

  /// 右侧内容。
  final String value;

  /// 构建元信息行。
  @override
  Widget build(BuildContext context) {
    /// 当前主题颜色。
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: SpacingToken.small),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 44,
            child: Text(label, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: colors.onSurfaceVariant)),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}

/// 目录预览卡，避免详情页直接铺满超长目录。
final class _BookInfoChapterPreview extends StatelessWidget {
  /// 创建目录预览。
  const _BookInfoChapterPreview({required this.state, required this.onIntent});

  /// 当前详情页状态。
  final BookInfoUiState state;

  /// 用户操作统一入口。
  final ValueChanged<BookInfoIntent> onIntent;

  /// 构建目录状态、重试按钮和最近章节预览。
  @override
  Widget build(BuildContext context) {
    /// 当前主题颜色。
    final ColorScheme colors = Theme.of(context).colorScheme;
    /// 预览章节数量。
    const int previewCount = 8;
    /// 需要展示的章节片段。
    final List<MapEntry<int, BookChapter>> previewChapters =
        state.chapters.asMap().entries.take(previewCount).toList(growable: false);
    return Card(
      elevation: ElevationToken.none,
      color: colors.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(SpacingToken.medium),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Text('目录（${state.chapters.length}）', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                if (state.loadingToc)
                  const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                if (!state.loadingToc && state.tocError != null)
                  TextButton(
                    onPressed: () => onIntent(const RetryBookTocIntent()),
                    child: const Text('重试'),
                  ),
              ],
            ),
            if (state.tocError != null)
              Padding(
                padding: const EdgeInsets.only(top: SpacingToken.small),
                child: Text(state.tocError ?? '目录加载失败', style: TextStyle(color: colors.error)),
              ),
            if (!state.loadingToc && state.chapters.isEmpty && state.tocError == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: SpacingToken.large),
                child: Center(child: Text('暂无目录')),
              ),
            if (previewChapters.isNotEmpty) ...<Widget>[
              const SizedBox(height: SpacingToken.small),
              ...previewChapters.map((MapEntry<int, BookChapter> entry) {
                /// 当前目录项在完整目录中的稳定位置。
                final int chapterIndex = entry.key;
                /// 当前目录项对应的章节对象。
                final BookChapter chapter = entry.value;
                return ListTile(
                  key: ValueKey<String>('${chapter.index}:${chapter.url}'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Text('${chapter.index + 1}'),
                  title: Text(chapter.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: chapter.tag == null ? null : Text(chapter.tag ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
                  enabled: !chapter.isVolume && !state.addingToShelf,
                  onTap: chapter.isVolume || state.addingToShelf
                      ? null
                      : () => onIntent(OpenBookInfoChapterIntent(chapterIndex)),
                );
              }),
              if (state.chapters.length > previewCount)
                Padding(
                  padding: const EdgeInsets.only(top: SpacingToken.small),
                  child: Text(
                    '已收起其余 ${state.chapters.length - previewCount} 章，可通过“查看目录”打开完整目录。',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
