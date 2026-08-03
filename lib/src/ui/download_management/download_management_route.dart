import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_dependencies.dart';
import '../../app/app_route.dart';
import '../../domain/model/book.dart';
import '../../domain/model/book_chapter.dart';
import '../../domain/model/book_search.dart';
import '../../domain/model/download_task.dart';
import '../../domain/model/search_book.dart';
import '../../model/reader/download_coordinator.dart';
import '../book_info/book_info_contract.dart';
import '../components/app_scaffold.dart';
import '../theme/app_tokens.dart';

/// 连接跨书下载任务流、书架事实和独立下载管理页面。
final class DownloadManagementRoute extends StatelessWidget {
  /// 创建下载管理路由。
  const DownloadManagementRoute({
    required this.dependencies,
    this.initialPage = 0,
    super.key,
  });

  /// 应用组合根依赖，提供书架流和 App 级下载协调器。
  final AppDependencies dependencies;

  /// 初始展示的 PageView 页面：0 为进行中、1 为已完成、2 为离线内容管理。
  final int initialPage;

  /// 合并实时书架与下载任务流后构建管理页面。
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Book>>(
      stream: dependencies.bookshelfGateway.watchBookshelf(),
      initialData: const <Book>[],
      builder: (BuildContext context, AsyncSnapshot<List<Book>> bookSnapshot) {
        return StreamBuilder<List<DownloadTask>>(
          stream: dependencies.downloadCoordinator.watchAllTasks(),
          initialData: const <DownloadTask>[],
          builder: (
            BuildContext context,
            AsyncSnapshot<List<DownloadTask>> taskSnapshot,
          ) {
            return _DownloadManagementScreen(
              coordinator: dependencies.downloadCoordinator,
              books: bookSnapshot.data ?? const <Book>[],
              tasks: taskSnapshot.data ?? const <DownloadTask>[],
              initialPage: initialPage,
              onBack: () => Navigator.of(context).pop(),
            );
          },
        );
      },
    );
  }
}

/// 顶部全局控制、跨书汇总和可展开章节任务列表。
final class _DownloadManagementScreen extends StatefulWidget {
  /// 创建下载管理纯页面。
  const _DownloadManagementScreen({
    required this.coordinator,
    required this.books,
    required this.tasks,
    required this.initialPage,
    required this.onBack,
  });

  /// App 级共享下载协调器，统一执行用户设置的全局并发上限。
  final DownloadCoordinator coordinator;

  /// 当前书架事实，用于显示书名和作者。
  final List<Book> books;

  /// 全部书籍实时下载任务。
  final List<DownloadTask> tasks;

  /// 路由指定的首次展示页面。
  final int initialPage;

  /// 返回上一页的导航回调。
  final VoidCallback onBack;

  /// 创建展开章节与目录缓存状态。
  @override
  State<_DownloadManagementScreen> createState() =>
      _DownloadManagementScreenState();
}

/// 保存页面局部展开状态，下载业务状态始终由协调器和数据库流提供。
final class _DownloadManagementScreenState
    extends State<_DownloadManagementScreen> {
  /// 当前展开的书籍主键集合。
  final Set<String> _expandedBookUrls = <String>{};

  /// 已按需加载的书籍目录缓存。
  final Map<String, List<BookChapter>> _chaptersByBookUrl =
      <String, List<BookChapter>>{};

  /// 正在加载目录的书籍主键集合。
  final Set<String> _loadingChapterBookUrls = <String>{};

  /// 当前管理页展示的下载并发数；初始化期间采用与调度器一致的默认值。
  int _maximumConcurrency = DownloadCoordinator.defaultMaximumConcurrency;

  /// 下载管理三页的控制器，支持顶部切换和左右滑动。
  late final PageController _pageController;

  /// 当前展示页索引，用于同步顶部页面切换按钮。
  int _pageIndex = 0;

  /// 首帧后读取已持久化的下载并发设置，避免在构建期触发数据库访问。
  @override
  void initState() {
    super.initState();
    _pageIndex = widget.initialPage.clamp(0, 2).toInt();
    _pageController = PageController(initialPage: _pageIndex);
    unawaited(_loadMaximumConcurrency());
  }

  /// 释放 PageView 控制器，避免退出下载管理后持有页面滚动资源。
  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  /// 构建全局摘要、并发策略说明和按书分组任务列表。
  @override
  Widget build(BuildContext context) {
    /// 按书籍主键分组的任务。
    final Map<String, List<DownloadTask>> groupedTasks =
        _groupTasks(widget.tasks);
    /// 按最近任务变化时间排序的书籍主键。
    final Set<String> visibleBookUrls = <String>{
      ...groupedTasks.keys,
      ...widget.books
          .where((Book book) => book.origin != 'loc_book')
          .map((Book book) => book.bookUrl),
    };
    /// 按最近任务变化时间排序的可管理书籍主键。
    final List<String> orderedBookUrls = visibleBookUrls.toList()
      ..sort((String left, String right) {
        /// 左侧书籍最近一次状态变化时间。
        final int leftTime = groupedTasks[left]
                ?.map((DownloadTask task) => task.updatedAt)
                .fold<int>(0, (int value, int item) => item > value ? item : value) ??
            0;
        /// 右侧书籍最近一次状态变化时间。
        final int rightTime = groupedTasks[right]
                ?.map((DownloadTask task) => task.updatedAt)
                .fold<int>(0, (int value, int item) => item > value ? item : value) ??
            0;
        if (leftTime != rightTime) {
          return rightTime.compareTo(leftTime);
        }
        /// 左侧书籍用于无任务时稳定排序的名称。
        final String leftName = _findBook(left)?.name ?? left;
        /// 右侧书籍用于无任务时稳定排序的名称。
        final String rightName = _findBook(right)?.name ?? right;
        return leftName.compareTo(rightName);
      });
    /// 是否存在等待或运行任务。
    final bool hasActiveTasks = widget.tasks.any(
      (DownloadTask task) =>
          task.status == DownloadTaskStatus.waiting ||
          task.status == DownloadTaskStatus.running,
    );
    /// 是否存在暂停任务。
    final bool hasPausedTasks = widget.tasks.any(
      (DownloadTask task) => task.status == DownloadTaskStatus.paused,
    );
    /// 是否存在失败任务。
    final bool hasFailedTasks = widget.tasks.any(
      (DownloadTask task) => task.status == DownloadTaskStatus.failed,
    );
    /// 仍有等待、下载中、暂停或失败任务的书籍，作为默认下载管理页内容。
    final List<String> activeBookUrls = orderedBookUrls
        .where((String bookUrl) => (groupedTasks[bookUrl] ?? const <DownloadTask>[])
            .any((DownloadTask task) => task.status != DownloadTaskStatus.success))
        .toList(growable: false);
    /// 全部任务都成功的书籍；点击后直接进入书籍详情，不再显示下载操作按钮。
    final List<String> completedBookUrls = orderedBookUrls
        .where((String bookUrl) {
          final List<DownloadTask> tasks =
              groupedTasks[bookUrl] ?? const <DownloadTask>[];
          return tasks.isNotEmpty &&
              tasks.every((DownloadTask task) =>
                  task.status == DownloadTaskStatus.success);
        })
        .toList(growable: false);
    /// 存在已下载正文的书籍，供离线内容管理页清除缓存和对应任务记录。
    final List<String> offlineContentBookUrls = orderedBookUrls
        .where((String bookUrl) => (groupedTasks[bookUrl] ?? const <DownloadTask>[])
            .any((DownloadTask task) => task.status == DownloadTaskStatus.success))
        .toList(growable: false);
    return AppScaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: widget.onBack,
          icon: const Icon(Icons.arrow_back),
          tooltip: '返回',
        ),
        title: const Text('下载管理'),
        actions: <Widget>[
          if (hasFailedTasks)
            IconButton(
              onPressed: () => _runAction(
                widget.coordinator.retryAllFailed,
                '失败任务已重新排队',
              ),
              icon: const Icon(Icons.replay),
              tooltip: '重试全部失败任务',
            ),
          if (hasActiveTasks)
            IconButton(
              onPressed: () => _runAction(
                widget.coordinator.pauseAll,
                '全部下载已暂停',
              ),
              icon: const Icon(Icons.pause),
              tooltip: '暂停全部',
            )
          else if (hasPausedTasks)
            IconButton(
              onPressed: () => _runAction(
                widget.coordinator.resumeAll,
                '全部暂停任务已恢复',
              ),
              icon: const Icon(Icons.play_arrow),
              tooltip: '恢复全部',
            ),
        ],
      ),
      body: Column(
        children: <Widget>[
          _DownloadSummaryCard(tasks: widget.tasks),
          Padding(
            padding: EdgeInsets.fromLTRB(
              SpacingToken.medium,
              0,
              SpacingToken.medium,
              SpacingToken.small,
            ),
            child: Row(
              children: <Widget>[
                const Expanded(
                  child: Text('同时下载请求数'),
                ),
                DropdownButton<int>(
                  value: _maximumConcurrency,
                  items: List<DropdownMenuItem<int>>.generate(
                    DownloadCoordinator.maximumConcurrencyLimit,
                    (int index) => DropdownMenuItem<int>(
                      value: index + 1,
                      child: Text('${index + 1} 个'),
                    ),
                  ),
                  onChanged: (int? value) {
                    if (value != null) {
                      unawaited(_updateMaximumConcurrency(value));
                    }
                  },
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(
              SpacingToken.medium,
              0,
              SpacingToken.medium,
              SpacingToken.small,
            ),
            child: Text(
              '默认 5 个；单次请求 45 秒超时，失败 5 次后跳过并继续后续章节。并发数调整只影响后续领取的任务。',
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: SpacingToken.medium,
              vertical: SpacingToken.xSmall,
            ),
            child: Row(
              children: <Widget>[
                _buildPageButton(0, '下载中'),
                _buildPageButton(1, '已完成'),
                _buildPageButton(2, '离线内容'),
              ],
            ),
          ),
          Expanded(
            child: PageView(
              controller: _pageController,
              onPageChanged: (int index) {
                setState(() {
                  _pageIndex = index;
                });
              },
              children: <Widget>[
                _buildBookList(
                  bookUrls: activeBookUrls,
                  groupedTasks: groupedTasks,
                ),
                _buildBookList(
                  bookUrls: completedBookUrls,
                  groupedTasks: groupedTasks,
                  completed: true,
                ),
                _buildBookList(
                  bookUrls: offlineContentBookUrls,
                  groupedTasks: groupedTasks,
                  offlineContentManagement: true,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 按书籍主键将全部任务分组，并保持任务列表只读。
  Map<String, List<DownloadTask>> _groupTasks(List<DownloadTask> tasks) {
    /// 可变分组缓冲区。
    final Map<String, List<DownloadTask>> groups =
        <String, List<DownloadTask>>{};
    for (final DownloadTask task in tasks) {
      groups.putIfAbsent(task.bookUrl, () => <DownloadTask>[]).add(task);
    }
    for (final List<DownloadTask> group in groups.values) {
      group.sort(
        (DownloadTask left, DownloadTask right) =>
            left.chapterIndex.compareTo(right.chapterIndex),
      );
    }
    return groups;
  }

  /// 读取持久化并发数后更新页面；页面已销毁时不再写入局部状态。
  /// 构建 PageView 顶部切换按钮，并保持手势翻页与按钮状态一致。
  Widget _buildPageButton(int index, String label) {
    return Expanded(
      child: TextButton(
        onPressed: () {
          _pageController.animateToPage(
            index,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
          );
        },
        child: Text(
          label,
          style: TextStyle(
            fontWeight: _pageIndex == index ? FontWeight.w700 : FontWeight.w400,
          ),
        ),
      ),
    );
  }

  /// 按页面职责构建书籍列表：进行中可展开，已完成直接进入详情，离线内容页仅负责清除正文。
  Widget _buildBookList({
    required List<String> bookUrls,
    required Map<String, List<DownloadTask>> groupedTasks,
    bool completed = false,
    bool offlineContentManagement = false,
  }) {
    if (bookUrls.isEmpty) {
      final String message = offlineContentManagement
          ? '还没有可清除的离线内容'
          : completed
          ? '还没有已完成下载的书籍'
          : '还没有进行中的下载任务';
      return Center(child: Text(message));
    }
    return ListView.builder(
      padding: const EdgeInsets.only(
        top: SpacingToken.small,
        bottom: SpacingToken.large,
      ),
      itemCount: bookUrls.length,
      itemBuilder: (BuildContext context, int index) {
        final String bookUrl = bookUrls[index];
        final List<DownloadTask> tasks =
            groupedTasks[bookUrl] ?? const <DownloadTask>[];
        if (offlineContentManagement) {
          return _buildOfflineContentBookGroup(bookUrl, tasks);
        }
        return _buildBookGroup(bookUrl, tasks, completed: completed);
      },
    );
  }

  Future<void> _loadMaximumConcurrency() async {
    final int value = await widget.coordinator.loadMaximumConcurrency();
    if (!mounted) {
      return;
    }
    setState(() {
      _maximumConcurrency = value;
    });
  }

  /// 保存用户选择的并发数，并立即让调度器补领可用任务槽位。
  Future<void> _updateMaximumConcurrency(int value) async {
    await widget.coordinator.setMaximumConcurrency(value);
    if (!mounted) {
      return;
    }
    setState(() {
      _maximumConcurrency = widget.coordinator.maximumConcurrency;
    });
  }

  /// 构建一本书的汇总卡片和按需展开的活跃章节任务。
  Widget _buildBookGroup(
    String bookUrl,
    List<DownloadTask> tasks, {
    bool completed = false,
  }) {
    /// 当前主键对应的书架书籍。
    final Book? book = _findBook(bookUrl);
    /// 当前书籍是否展开章节任务。
    final bool expanded = _expandedBookUrls.contains(bookUrl);
    /// 当前书籍是否有活动任务。
    final bool hasActive = tasks.any(
      (DownloadTask task) =>
          task.status == DownloadTaskStatus.waiting ||
          task.status == DownloadTaskStatus.running,
    );
    /// 当前书籍是否有暂停任务。
    final bool hasPaused = tasks.any(
      (DownloadTask task) => task.status == DownloadTaskStatus.paused,
    );
    /// 当前书籍是否有失败任务。
    final bool hasFailed = tasks.any(
      (DownloadTask task) => task.status == DownloadTaskStatus.failed,
    );
    if (completed) {
      return Card(
        margin: const EdgeInsets.symmetric(
          horizontal: SpacingToken.medium,
          vertical: SpacingToken.xSmall,
        ),
        child: ListTile(
          leading: const Icon(Icons.check_circle_outline),
          title: Text(book?.name ?? '已移除书籍'),
          subtitle: Text(_bookSummary(book, tasks)),
          trailing: const Icon(Icons.chevron_right),
          onTap: book == null ? null : () => _openBookInfo(book),
        ),
      );
    }
    return Card(
      margin: const EdgeInsets.symmetric(
        horizontal: SpacingToken.medium,
        vertical: SpacingToken.xSmall,
      ),
      child: Column(
        children: <Widget>[
          ListTile(
            leading: Icon(
              expanded ? Icons.expand_more : Icons.chevron_right,
            ),
            title: Text(
              book?.name ?? '已移除书籍',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              _bookSummary(book, tasks),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => _toggleBook(bookUrl),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                IconButton(
                  onPressed: book == null ? null : () => _openBookInfo(book),
                  icon: const Icon(Icons.info_outline),
                  tooltip: '书籍详情',
                ),
                PopupMenuButton<_DownloadBookAction>(
                  tooltip: '本书下载操作',
                  onSelected: (_DownloadBookAction action) {
                    switch (action) {
                      case _DownloadBookAction.pause:
                        _runAction(
                          () => widget.coordinator.pauseBook(bookUrl),
                          '本书下载已暂停',
                        );
                      case _DownloadBookAction.resume:
                        _runAction(
                          () => widget.coordinator.resumeBook(bookUrl),
                          '本书下载已恢复',
                        );
                      case _DownloadBookAction.retryFailed:
                        _runAction(
                          () => widget.coordinator.retryBookFailed(bookUrl),
                          '本书失败任务已重新排队',
                        );
                      case _DownloadBookAction.addRange:
                        _showEnqueueRange(
                          bookUrl,
                          book?.name ?? '本书',
                        );
                      case _DownloadBookAction.delete:
                        _confirmDeleteBook(bookUrl, book?.name ?? '本书');
                      case _DownloadBookAction.removeTasksOnly:
                        _confirmRemoveBookTasks(bookUrl, book?.name ?? '本书');
                    }
                  },
                  itemBuilder: (BuildContext context) {
                    return <PopupMenuEntry<_DownloadBookAction>>[
                      PopupMenuItem<_DownloadBookAction>(
                        value: _DownloadBookAction.addRange,
                        enabled: book != null,
                        child: const Text('添加章节范围'),
                      ),
                      PopupMenuItem<_DownloadBookAction>(
                        value: _DownloadBookAction.pause,
                        enabled: hasActive,
                        child: const Text('暂停本书'),
                      ),
                      PopupMenuItem<_DownloadBookAction>(
                        value: _DownloadBookAction.resume,
                        enabled: hasPaused,
                        child: const Text('恢复本书'),
                      ),
                      PopupMenuItem<_DownloadBookAction>(
                        value: _DownloadBookAction.retryFailed,
                        enabled: hasFailed,
                        child: const Text('重试失败章节'),
                      ),
                      const PopupMenuDivider(),
                      const PopupMenuItem<_DownloadBookAction>(
                        value: _DownloadBookAction.removeTasksOnly,
                        child: Text('仅删除下载任务'),
                      ),
                      const PopupMenuItem<_DownloadBookAction>(
                        value: _DownloadBookAction.delete,
                        child: Text('删除本书离线内容'),
                      ),
                    ];
                  },
                ),
              ],
            ),
          ),
          if (expanded) const Divider(height: 1),
          if (expanded) _buildChapterTasks(bookUrl, tasks),
        ],
      ),
    );
  }

  /// 构建离线内容管理书籍项；清除操作会删除正文缓存及其成功下载任务，不影响书架书籍本身。
  Widget _buildOfflineContentBookGroup(
    String bookUrl,
    List<DownloadTask> tasks,
  ) {
    final Book? book = _findBook(bookUrl);
    return Card(
      margin: const EdgeInsets.symmetric(
        horizontal: SpacingToken.medium,
        vertical: SpacingToken.xSmall,
      ),
      child: ListTile(
        leading: const Icon(Icons.offline_pin_outlined),
        title: Text(book?.name ?? '已移除书籍'),
        subtitle: Text(_bookSummary(book, tasks)),
        onTap: book == null ? null : () => _openBookInfo(book),
        trailing: IconButton(
          onPressed: () => _confirmDeleteBook(bookUrl, book?.name ?? '本书'),
          icon: const Icon(Icons.delete_outline),
          tooltip: '清除离线内容',
        ),
      ),
    );
  }

  /// 构建一本书展开后的固定高度活跃任务列表；已完成任务不再渲染，避免大范围下载时创建大量 Widget。
  Widget _buildChapterTasks(String bookUrl, List<DownloadTask> tasks) {
    if (_loadingChapterBookUrls.contains(bookUrl)) {
      return const Padding(
        padding: EdgeInsets.all(SpacingToken.medium),
        child: LinearProgressIndicator(),
      );
    }
    /// 已加载的当前书目录。
    final List<BookChapter> chapters =
        _chaptersByBookUrl[bookUrl] ?? const <BookChapter>[];
    return _ActiveDownloadTaskList(
      tasks: tasks,
      chapters: chapters,
      onPause: (DownloadTask task) => _runAction(
        () => widget.coordinator.pauseTask(task.bookUrl, task.chapterIndex),
        '章节下载已暂停',
      ),
      onResume: (DownloadTask task) => _runAction(
        () => widget.coordinator.resumeTask(task.bookUrl, task.chapterIndex),
        '章节已重新排队',
      ),
      onDelete: (DownloadTask task) => _confirmDeleteTask(task, chapters),
    );
  }

  /// 从下载管理直接进入既有书籍详情页，并复用书架到详情页的候选转换语义。
  void _openBookInfo(Book book) {
    /// 详情路由所需的单来源候选书籍。
    final SearchBook searchBook = SearchBook(
      bookUrl: book.bookUrl,
      origin: book.origin,
      originName: book.originName,
      name: book.name,
      author: book.author,
      type: book.type,
      kind: book.kind,
      coverUrl: book.coverUrl,
      intro: book.intro,
      wordCount: book.wordCount,
      latestChapterTitle: book.latestChapterTitle,
      tocUrl: book.tocUrl,
      time: book.lastCheckTime,
      variable: book.variable,
      originOrder: book.originOrder,
    );
    Navigator.of(context).pushNamed(
      AppRoute.bookInfo,
      arguments: BookInfoRouteArguments(
        group: BookSearchResultGroup(
          key: bookSearchResultGroupKey(searchBook),
          books: <SearchBook>[searchBook],
        ),
        selectedBook: searchBook,
      ),
    );
  }

  /// 切换一本书的展开状态，并在首次展开时按需加载目录。
  void _toggleBook(String bookUrl) {
    if (_expandedBookUrls.remove(bookUrl)) {
      setState(() {});
      return;
    }
    setState(() {
      _expandedBookUrls.add(bookUrl);
    });
    if (!_chaptersByBookUrl.containsKey(bookUrl)) {
      unawaited(_loadChapters(bookUrl));
    }
  }

  /// 加载指定书籍目录并只在页面仍挂载时更新局部缓存。
  Future<void> _loadChapters(String bookUrl) async {
    setState(() {
      _loadingChapterBookUrls.add(bookUrl);
    });
    try {
      /// 下载协调器返回的完整目录。
      final List<BookChapter> chapters =
          await widget.coordinator.loadChapters(bookUrl);
      if (!mounted) {
        return;
      }
      setState(() {
        _chaptersByBookUrl[bookUrl] = chapters;
      });
    } on Object {
      if (mounted) {
        _showMessage('读取章节目录失败');
      }
    } finally {
      if (mounted) {
        setState(() {
          _loadingChapterBookUrls.remove(bookUrl);
        });
      }
    }
  }

  /// 按稳定书籍主键查找书架书。
  Book? _findBook(String bookUrl) {
    for (final Book book in widget.books) {
      if (book.bookUrl == bookUrl) {
        return book;
      }
    }
    return null;
  }

  /// 生成一本书作者、状态计数和正文字符数摘要。
  String _bookSummary(Book? book, List<DownloadTask> tasks) {
    /// 当前书成功章节数量。
    final int successCount = tasks
        .where((DownloadTask task) =>
            task.status == DownloadTaskStatus.success)
        .length;
    /// 当前书等待或运行章节数量。
    final int activeCount = tasks
        .where((DownloadTask task) =>
            task.status == DownloadTaskStatus.waiting ||
            task.status == DownloadTaskStatus.running)
        .length;
    /// 当前书暂停章节数量。
    final int pausedCount = tasks
        .where((DownloadTask task) =>
            task.status == DownloadTaskStatus.paused)
        .length;
    /// 当前书失败章节数量。
    final int failedCount = tasks
        .where((DownloadTask task) =>
            task.status == DownloadTaskStatus.failed)
        .length;
    /// 当前书已记录正文字符总数。
    final int contentLength = tasks.fold<int>(
      0,
      (int value, DownloadTask task) => value + task.contentLength,
    );
    /// 当前书作者摘要。
    final String author = book?.author.isNotEmpty == true ? '${book?.author} · ' : '';
    return '$author完成 $successCount/${tasks.length} · 进行 $activeCount · 暂停 $pausedCount · 失败 $failedCount · ${_formatCharacterCount(contentLength)}';
  }

  /// 将正文字符数转换为紧凑近似用量说明。
  String _formatCharacterCount(int count) {
    if (count >= 10000) {
      return '${(count / 10000).toStringAsFixed(1)} 万字符';
    }
    return '$count 字符';
  }

  /// 加载目录并弹出起止章节范围，确认后加入全局共享下载队列。
  Future<void> _showEnqueueRange(String bookUrl, String bookName) async {
    try {
      /// 当前书完整目录。
      final List<BookChapter> chapters =
          await widget.coordinator.loadChapters(bookUrl);
      if (!mounted || chapters.isEmpty) {
        if (mounted) {
          _showMessage('当前书没有可下载目录');
        }
        return;
      }
      /// 起始章节号输入控制器。
      final TextEditingController startController =
          TextEditingController(text: '1');
      /// 结束章节号输入控制器。
      final TextEditingController endController =
          TextEditingController(text: chapters.length.toString());
      /// 用户确认后返回的章节索引集合。
      final List<int>? selectedIndices = await showDialog<List<int>>(
        context: context,
        builder: (BuildContext dialogContext) {
          /// 范围输入错误提示，仅属于弹窗局部展示状态。
          String? rangeError;
          return StatefulBuilder(
            builder: (
              BuildContext dialogContext,
              StateSetter setDialogState,
            ) {
              return AlertDialog(
                title: Text('下载《$bookName》'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: TextField(
                            controller: startController,
                            keyboardType: TextInputType.number,
                            decoration:
                                const InputDecoration(labelText: '起始章节'),
                          ),
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: SpacingToken.small,
                          ),
                          child: Text('至'),
                        ),
                        Expanded(
                          child: TextField(
                            controller: endController,
                            keyboardType: TextInputType.number,
                            decoration:
                                const InputDecoration(labelText: '结束章节'),
                          ),
                        ),
                      ],
                    ),
                    if (rangeError != null)
                      Padding(
                        padding: const EdgeInsets.only(
                          top: SpacingToken.small,
                        ),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            rangeError ?? '',
                            style: TextStyle(
                              color: Theme.of(dialogContext).colorScheme.error,
                            ),
                          ),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(top: SpacingToken.small),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '可选范围：1–${chapters.length}，卷标题会自动跳过',
                          style: Theme.of(dialogContext).textTheme.bodySmall,
                        ),
                      ),
                    ),
                  ],
                ),
                actions: <Widget>[
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    onPressed: () {
                      /// 用户输入的起始章节号。
                      final int? start =
                          int.tryParse(startController.text.trim());
                      /// 用户输入的结束章节号。
                      final int? end =
                          int.tryParse(endController.text.trim());
                      if (start == null ||
                          end == null ||
                          start < 1 ||
                          end < start ||
                          end > chapters.length) {
                        setDialogState(() {
                          rangeError =
                              '请输入 1–${chapters.length} 内的有效起止章节';
                        });
                        return;
                      }
                      /// 排除卷标题后的实际下载章节索引。
                      final List<int> indices = chapters
                          .where((BookChapter chapter) =>
                              chapter.index >= start - 1 &&
                              chapter.index <= end - 1 &&
                              !chapter.isVolume)
                          .map((BookChapter chapter) => chapter.index)
                          .toList(growable: false);
                      Navigator.of(dialogContext).pop(indices);
                    },
                    child: const Text('加入队列'),
                  ),
                ],
              );
            },
          );
        },
      );
      startController.dispose();
      endController.dispose();
      if (selectedIndices == null || selectedIndices.isEmpty) {
        return;
      }
      await widget.coordinator.enqueueIndices(bookUrl, selectedIndices);
      if (mounted) {
        _showMessage('已加入 ${selectedIndices.length} 个章节');
      }
    } on Object {
      if (mounted) {
        _showMessage('读取目录或加入下载队列失败');
      }
    }
  }

  /// 二次确认后删除一本书全部离线正文和任务。
  Future<void> _confirmDeleteBook(String bookUrl, String bookName) async {
    /// 用户对删除整书离线内容的确认结果。
    final bool confirmed = await showDialog<bool>(
          context: context,
          builder: (BuildContext dialogContext) {
            return AlertDialog(
              title: const Text('删除离线内容'),
              content: Text('确定删除《$bookName》的全部离线正文和下载任务吗？'),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: const Text('删除'),
                ),
              ],
            );
          },
        ) ??
        false;
    if (!confirmed) {
      return;
    }
    await _runAction(
      () => widget.coordinator.deleteBookDownloads(bookUrl),
      '本书离线内容已删除',
    );
  }

  /// 二次确认后仅删除任务记录；已下载正文保持离线可读。
  Future<void> _confirmRemoveBookTasks(String bookUrl, String bookName) async {
    final bool confirmed = await showDialog<bool>(
          context: context,
          builder: (BuildContext dialogContext) {
            return AlertDialog(
              title: const Text('仅删除下载任务'),
              content: Text('确定删除《$bookName》的下载任务吗？已下载的离线正文会保留。'),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: const Text('删除任务'),
                ),
              ],
            );
          },
        ) ??
        false;
    if (!confirmed) {
      return;
    }
    await _runAction(
      () => widget.coordinator.removeBookTasks(bookUrl),
      '下载任务已删除，离线正文已保留',
    );
  }

  /// 二次确认后删除单章离线正文和任务。
  Future<void> _confirmDeleteTask(
    DownloadTask task,
    List<BookChapter> chapters,
  ) async {
    /// 当前任务用户可见章节标题。
    final String title = _chapterTitle(chapters, task.chapterIndex);
    /// 用户对删除单章离线内容的确认结果。
    final bool confirmed = await showDialog<bool>(
          context: context,
          builder: (BuildContext dialogContext) {
            return AlertDialog(
              title: const Text('删除章节离线内容'),
              content: Text('确定删除“$title”的离线正文和任务吗？'),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: const Text('删除'),
                ),
              ],
            );
          },
        ) ??
        false;
    if (!confirmed) {
      return;
    }
    await _runAction(
      () => widget.coordinator.deleteTaskDownload(
        task.bookUrl,
        task.chapterIndex,
      ),
      '章节离线内容已删除',
    );
  }

  /// 为删除确认对话框解析章节标题；目录尚未命中时使用稳定章节号回退。
  String _chapterTitle(List<BookChapter> chapters, int chapterIndex) {
    for (final BookChapter chapter in chapters) {
      if (chapter.index == chapterIndex) {
        return chapter.title;
      }
    }
    return '第 ${chapterIndex + 1} 章';
  }

  /// 执行下载管理动作并展示成功或失败消息。
  Future<void> _runAction(
    Future<void> Function() action,
    String successMessage,
  ) async {
    try {
      await action();
      if (mounted) {
        _showMessage(successMessage);
      }
    } on Object {
      if (mounted) {
        _showMessage('操作失败，请稍后重试');
      }
    }
  }

  /// 显示单条下载管理结果提示。
  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

/// 展示全部下载任务的状态计数。
final class _DownloadSummaryCard extends StatelessWidget {
  /// 创建全局下载摘要卡片。
  const _DownloadSummaryCard({required this.tasks});

  /// 全部书籍下载任务。
  final List<DownloadTask> tasks;

  /// 构建等待、运行、暂停、成功和失败计数。
  @override
  Widget build(BuildContext context) {
    /// 各状态对应的任务数量。
    final Map<DownloadTaskStatus, int> counts =
        <DownloadTaskStatus, int>{
      for (final DownloadTaskStatus status in DownloadTaskStatus.values)
        status: tasks.where((DownloadTask task) => task.status == status).length,
    };
    return Card(
      margin: const EdgeInsets.all(SpacingToken.medium),
      child: Padding(
        padding: const EdgeInsets.all(SpacingToken.medium),
        child: Wrap(
          spacing: SpacingToken.large,
          runSpacing: SpacingToken.small,
          children: <Widget>[
            _SummaryValue(label: '等待', value: counts[DownloadTaskStatus.waiting] ?? 0),
            _SummaryValue(label: '下载中', value: counts[DownloadTaskStatus.running] ?? 0),
            _SummaryValue(label: '暂停', value: counts[DownloadTaskStatus.paused] ?? 0),
            _SummaryValue(label: '完成', value: counts[DownloadTaskStatus.success] ?? 0),
            _SummaryValue(label: '失败', value: counts[DownloadTaskStatus.failed] ?? 0),
          ],
        ),
      ),
    );
  }
}

/// 单个汇总状态和值。
final class _SummaryValue extends StatelessWidget {
  /// 创建状态计数。
  const _SummaryValue({required this.label, required this.value});

  /// 状态名称。
  final String label;

  /// 状态任务数量。
  final int value;

  /// 构建紧凑纵向计数。
  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text('$value', style: Theme.of(context).textTheme.titleLarge),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

/// 展示单章下载状态和暂停、恢复、删除操作。
final class _DownloadChapterTaskTile extends StatelessWidget {
  /// 创建章节下载任务行。
  const _DownloadChapterTaskTile({
    required this.task,
    required this.title,
    required this.onPause,
    required this.onResume,
    required this.onDelete,
  });

  /// 当前章节任务。
  final DownloadTask task;

  /// 当前章节标题。
  final String title;

  /// 暂停任务回调。
  final VoidCallback onPause;

  /// 恢复或重试任务回调。
  final VoidCallback onResume;

  /// 删除离线正文和任务回调。
  final VoidCallback onDelete;

  /// 构建状态图标、失败摘要和操作按钮。
  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.only(
        left: SpacingToken.large,
        right: SpacingToken.small,
      ),
      leading: _statusIcon(context),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(_statusLabel()),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (task.status == DownloadTaskStatus.waiting ||
              task.status == DownloadTaskStatus.running)
            IconButton(
              onPressed: onPause,
              icon: const Icon(Icons.pause),
              tooltip: '暂停',
            ),
          if (task.status == DownloadTaskStatus.paused ||
              task.status == DownloadTaskStatus.failed)
            IconButton(
              onPressed: onResume,
              icon: const Icon(Icons.play_arrow),
              tooltip: '恢复或重试',
            ),
          IconButton(
            onPressed: onDelete,
            icon: const Icon(Icons.delete_outline),
            tooltip: '删除离线内容',
          ),
        ],
      ),
    );
  }

  /// 返回当前任务状态图标。
  Widget _statusIcon(BuildContext context) {
    return switch (task.status) {
      DownloadTaskStatus.waiting => const Icon(Icons.schedule),
      DownloadTaskStatus.running => const SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2.2),
        ),
      DownloadTaskStatus.paused => const Icon(Icons.pause_circle_outline),
      DownloadTaskStatus.success => Icon(
          Icons.check_circle,
          color: Theme.of(context).colorScheme.primary,
        ),
      DownloadTaskStatus.failed => Icon(
          Icons.error_outline,
          color: Theme.of(context).colorScheme.error,
        ),
    };
  }

  /// 生成状态、重试和安全失败摘要。
  String _statusLabel() {
    return switch (task.status) {
      DownloadTaskStatus.waiting => '等待下载',
      DownloadTaskStatus.running => '正在下载',
      DownloadTaskStatus.paused => '已暂停',
      DownloadTaskStatus.success => '已离线 · ${task.contentLength} 字符',
      DownloadTaskStatus.failed =>
        '${task.errorMessage ?? '下载失败'} · 已尝试 ${task.retryCount} 次',
    };
  }
}

/// 仅虚拟化展示未完成下载任务的固定高度列表；新章节开始下载时自动回到顶部展示。
final class _ActiveDownloadTaskList extends StatefulWidget {
  /// 创建当前书籍的活跃下载任务窗口。
  const _ActiveDownloadTaskList({
    required this.tasks,
    required this.chapters,
    required this.onPause,
    required this.onResume,
    required this.onDelete,
  });

  /// 当前书籍全部持久化任务；成功任务仅用于统计，不在此列表中渲染。
  final List<DownloadTask> tasks;

  /// 已按需加载的目录，用于把任务章节索引显示为章节标题。
  final List<BookChapter> chapters;

  /// 暂停单章任务的页面回调。
  final ValueChanged<DownloadTask> onPause;

  /// 恢复或重试单章任务的页面回调。
  final ValueChanged<DownloadTask> onResume;

  /// 删除单章离线正文和任务的页面回调。
  final ValueChanged<DownloadTask> onDelete;

  /// 创建内部懒加载列表的滚动状态。
  @override
  State<_ActiveDownloadTaskList> createState() =>
      _ActiveDownloadTaskListState();
}

/// 保存内部滚动位置，并在下载状态转换为运行中时把新活跃任务带回可见区域。
final class _ActiveDownloadTaskListState
    extends State<_ActiveDownloadTaskList> {
  /// 每行固定高度，5.5 行窗口既限制首次构建量，也保留下一行的滚动提示。
  static const double _taskRowExtent = 72;

  /// 内部任务窗口的滚动控制器，不影响下载管理页面的外层滚动位置。
  final ScrollController _scrollController = ScrollController();

  /// 销毁内部滚动控制器，避免展开/收起书籍后保留无效监听资源。
  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// 当任一任务刚变为下载中时自动显示列表顶部；列表排序会把所有下载中任务排在最前。
  @override
  void didUpdateWidget(covariant _ActiveDownloadTaskList oldWidget) {
    super.didUpdateWidget(oldWidget);
    final Set<String> previousRunningKeys = oldWidget.tasks
        .where((DownloadTask task) => task.status == DownloadTaskStatus.running)
        .map(_taskKey)
        .toSet();
    final bool hasNewRunningTask = widget.tasks.any(
      (DownloadTask task) =>
          task.status == DownloadTaskStatus.running &&
          !previousRunningKeys.contains(_taskKey(task)),
    );
    if (hasNewRunningTask) {
      WidgetsBinding.instance.addPostFrameCallback((Duration _) {
        if (mounted && _scrollController.hasClients) {
          _scrollController.animateTo(
            0,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  /// 构建固定 5.5 行的活跃任务窗口；成功任务保留持久化事实但不参与 Widget 构建。
  @override
  Widget build(BuildContext context) {
    final List<DownloadTask> visibleTasks = widget.tasks
        .where((DownloadTask task) => task.status != DownloadTaskStatus.success)
        .toList(growable: false)
      ..sort(_compareVisibleTasks);
    if (visibleTasks.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(SpacingToken.medium),
        child: Text('当前书籍的任务均已下载完成'),
      );
    }
    return SizedBox(
      height: _taskRowExtent * 5.5,
      child: ListView.builder(
        controller: _scrollController,
        itemExtent: _taskRowExtent,
        cacheExtent: _taskRowExtent * 2,
        itemCount: visibleTasks.length,
        itemBuilder: (BuildContext context, int index) {
          final DownloadTask task = visibleTasks[index];
          return _DownloadChapterTaskTile(
            task: task,
            title: _chapterTitle(task.chapterIndex),
            onPause: () => widget.onPause(task),
            onResume: () => widget.onResume(task),
            onDelete: () => widget.onDelete(task),
          );
        },
      ),
    );
  }

  /// 将下载中任务置顶，其余未完成任务按等待、暂停、失败和章节顺序稳定排列。
  int _compareVisibleTasks(DownloadTask left, DownloadTask right) {
    final int statusComparison =
        _statusPriority(left.status).compareTo(_statusPriority(right.status));
    if (statusComparison != 0) {
      return statusComparison;
    }
    return left.chapterIndex.compareTo(right.chapterIndex);
  }

  /// 生成活跃状态的显示优先级；数值越小越靠近列表顶部。
  int _statusPriority(DownloadTaskStatus status) {
    return switch (status) {
      DownloadTaskStatus.running => 0,
      DownloadTaskStatus.waiting => 1,
      DownloadTaskStatus.paused => 2,
      DownloadTaskStatus.failed => 3,
      DownloadTaskStatus.success => 4,
    };
  }

  /// 从已加载目录读取章节标题；目录暂未命中时使用稳定章节号回退。
  String _chapterTitle(int chapterIndex) {
    for (final BookChapter chapter in widget.chapters) {
      if (chapter.index == chapterIndex) {
        return chapter.title;
      }
    }
    return '第 ${chapterIndex + 1} 章';
  }

  /// 为跨流更新中的任务生成书籍内稳定键，供运行状态转换比对。
  String _taskKey(DownloadTask task) {
    return '${task.bookUrl}\n${task.chapterIndex}';
  }
}

/// 一本书可执行的下载管理动作。
enum _DownloadBookAction {
  /// 选择起止章节范围加入全局共享队列。
  addRange,

  /// 暂停本书活动任务。
  pause,

  /// 恢复本书暂停任务。
  resume,

  /// 重试本书失败任务。
  retryFailed,

  /// 删除本书全部离线正文和任务。
  delete,

  /// 仅删除本书任务记录并保留已经写入缓存的正文。
  removeTasksOnly,
}
