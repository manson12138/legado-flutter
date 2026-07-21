import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_dependencies.dart';
import '../../domain/model/book.dart';
import '../../domain/model/book_chapter.dart';
import '../../domain/model/download_task.dart';
import '../../model/reader/download_coordinator.dart';
import '../components/app_scaffold.dart';
import '../theme/app_tokens.dart';

/// 连接跨书下载任务流、书架事实和独立下载管理页面。
final class DownloadManagementRoute extends StatelessWidget {
  /// 创建下载管理路由。
  const DownloadManagementRoute({required this.dependencies, super.key});

  /// 应用组合根依赖，提供书架流和 App 级下载协调器。
  final AppDependencies dependencies;

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
    required this.onBack,
  });

  /// App 级严格串行下载协调器。
  final DownloadCoordinator coordinator;

  /// 当前书架事实，用于显示书名和作者。
  final List<Book> books;

  /// 全部书籍实时下载任务。
  final List<DownloadTask> tasks;

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

  /// 构建全局摘要、串行策略说明和按书分组任务列表。
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
          const Padding(
            padding: EdgeInsets.fromLTRB(
              SpacingToken.medium,
              0,
              SpacingToken.medium,
              SpacingToken.small,
            ),
            child: Text(
              '当前固定为全局串行下载：同一时间只请求一个章节，两次真实书源请求至少间隔 1.5 秒；单次请求 45 秒超时，失败 5 次后跳过并继续后续章节。',
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: orderedBookUrls.isEmpty
                ? const Center(child: Text('还没有离线下载任务'))
                : ListView.builder(
                    padding: const EdgeInsets.only(
                      top: SpacingToken.small,
                      bottom: SpacingToken.large,
                    ),
                    itemCount: orderedBookUrls.length,
                    itemBuilder: (BuildContext context, int index) {
                      /// 当前分组书籍主键。
                      final String bookUrl = orderedBookUrls[index];
                      /// 当前书籍全部下载任务。
                      final List<DownloadTask> tasks =
                          groupedTasks[bookUrl] ?? const <DownloadTask>[];
                      return _buildBookGroup(bookUrl, tasks);
                    },
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

  /// 构建一本书的汇总卡片和按需展开章节任务。
  Widget _buildBookGroup(String bookUrl, List<DownloadTask> tasks) {
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
            trailing: PopupMenuButton<_DownloadBookAction>(
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
                    value: _DownloadBookAction.delete,
                    child: Text('删除本书离线内容'),
                  ),
                ];
              },
            ),
          ),
          if (expanded) const Divider(height: 1),
          if (expanded) _buildChapterTasks(bookUrl, tasks),
        ],
      ),
    );
  }

  /// 构建一本书展开后的章节任务列表或目录加载状态。
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
    return Column(
      children: tasks.map((DownloadTask task) {
        return _DownloadChapterTaskTile(
          task: task,
          title: _chapterTitle(chapters, task.chapterIndex),
          onPause: () => _runAction(
            () => widget.coordinator.pauseTask(
              task.bookUrl,
              task.chapterIndex,
            ),
            '章节下载已暂停',
          ),
          onResume: () => _runAction(
            () => widget.coordinator.resumeTask(
              task.bookUrl,
              task.chapterIndex,
            ),
            '章节已重新排队',
          ),
          onDelete: () => _confirmDeleteTask(task, chapters),
        );
      }).toList(growable: false),
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

  /// 按章节索引查找标题，目录缺失时回退为章节号。
  String _chapterTitle(List<BookChapter> chapters, int chapterIndex) {
    for (final BookChapter chapter in chapters) {
      if (chapter.index == chapterIndex) {
        return chapter.title;
      }
    }
    return '第 ${chapterIndex + 1} 章';
  }

  /// 加载目录并弹出起止章节范围，确认后加入全局串行下载队列。
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
      DownloadTaskStatus.waiting => '等待串行下载',
      DownloadTaskStatus.running => '正在下载',
      DownloadTaskStatus.paused => '已暂停',
      DownloadTaskStatus.success => '已离线 · ${task.contentLength} 字符',
      DownloadTaskStatus.failed =>
        '${task.errorMessage ?? '下载失败'} · 已尝试 ${task.retryCount} 次',
    };
  }
}

/// 一本书可执行的下载管理动作。
enum _DownloadBookAction {
  /// 选择起止章节范围加入串行队列。
  addRange,

  /// 暂停本书活动任务。
  pause,

  /// 恢复本书暂停任务。
  resume,

  /// 重试本书失败任务。
  retryFailed,

  /// 删除本书全部离线正文和任务。
  delete,
}
