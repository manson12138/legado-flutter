import 'package:flutter/material.dart';

import '../../domain/model/book.dart';
import '../../domain/model/book_chapter.dart';
import '../../domain/model/download_task.dart';
import '../../model/reader/download_coordinator.dart';
import '../theme/app_tokens.dart';

/// 离线下载面板：选择章节范围加入队列，并展示当前书队列的实时状态。
///
/// 下载队列由 App 级单例 [DownloadCoordinator] 驱动，关闭本面板不会取消已入队的
/// 下载；下载只在应用运行期间进行，没有 Android 前台服务或 iOS 后台任务等价物。
final class ReaderDownloadSheetBody extends StatefulWidget {
  /// 创建离线下载面板。
  const ReaderDownloadSheetBody({
    required this.coordinator,
    required this.book,
    required this.chapters,
    required this.currentChapterIndex,
    super.key,
  });

  /// App 级单例下载队列调度器。
  final DownloadCoordinator coordinator;

  /// 当前书籍事实。
  final Book book;

  /// 当前书籍完整目录。
  final List<BookChapter> chapters;

  /// 当前阅读章节索引，用于换算默认下载范围。
  final int currentChapterIndex;

  /// 创建起止章节号输入状态。
  @override
  State<ReaderDownloadSheetBody> createState() => _ReaderDownloadSheetBodyState();
}

/// 持有起止章节号输入框控制器。
final class _ReaderDownloadSheetBodyState extends State<ReaderDownloadSheetBody> {
  /// 起始章节号（1 起始）输入控制器。
  late final TextEditingController _startController;

  /// 结束章节号（1 起始）输入控制器。
  late final TextEditingController _endController;

  /// 初始化默认下载范围：从下一章到最后一章，对齐 Android `DownloadSheet` 默认值。
  @override
  void initState() {
    super.initState();
    /// 目录总章节数。
    final int total = widget.chapters.length;
    /// 默认起始章节号。
    final int defaultStart = (widget.currentChapterIndex + 2).clamp(1, total == 0 ? 1 : total).toInt();
    _startController = TextEditingController(text: defaultStart.toString());
    _endController = TextEditingController(text: total == 0 ? '1' : total.toString());
  }

  /// 释放起止章节号输入控制器。
  @override
  void dispose() {
    _startController.dispose();
    _endController.dispose();
    super.dispose();
  }

  /// 构建范围选择、开始下载按钮和实时任务列表。
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.78,
      child: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(SpacingToken.medium),
            child: Text('下载', style: Theme.of(context).textTheme.titleLarge),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: SpacingToken.medium),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _startController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '起始章节号', border: OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: SpacingToken.small),
                const Text('至'),
                const SizedBox(width: SpacingToken.small),
                Expanded(
                  child: TextField(
                    controller: _endController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '结束章节号', border: OutlineInputBorder()),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              SpacingToken.medium,
              SpacingToken.small,
              SpacingToken.medium,
              0,
            ),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: widget.chapters.isEmpty ? null : _enqueue,
                icon: const Icon(Icons.download_outlined),
                label: const Text('开始下载'),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(SpacingToken.medium),
            child: Text(
              '下载仅在应用运行期间进行，退出或被系统回收后需要重新开始。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: StreamBuilder<List<DownloadTask>>(
              stream: widget.coordinator.watchTasks(widget.book.bookUrl),
              builder: (BuildContext context, AsyncSnapshot<List<DownloadTask>> snapshot) {
                /// 当前书队列的实时任务列表。
                final List<DownloadTask> tasks = snapshot.data ?? const <DownloadTask>[];
                if (tasks.isEmpty) {
                  return const Center(child: Text('还没有下载任务'));
                }
                return ListView.builder(
                  itemCount: tasks.length,
                  itemBuilder: (BuildContext context, int index) {
                    return _DownloadTaskRow(
                      task: tasks[index],
                      chapterTitle: _chapterTitle(tasks[index].chapterIndex),
                      onRetry: () => widget.coordinator.retryTask(widget.book.bookUrl, tasks[index].chapterIndex),
                      onRemove: () => widget.coordinator.removeTask(widget.book.bookUrl, tasks[index].chapterIndex),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 解析当前输入的起止章节号并转换为下载队列所需的目录索引。
  void _enqueue() {
    /// 解析后的起始章节号；解析失败为空。
    final int? start = int.tryParse(_startController.text.trim());
    /// 解析后的结束章节号；解析失败为空。
    final int? end = int.tryParse(_endController.text.trim());
    if (start == null || end == null || start < 1 || end < start || end > widget.chapters.length) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('请输入 1 到目录总数之间的有效章节号')));
      return;
    }
    /// 待入队的目录索引；卷标题由下载队列在处理时直接跳过。
    final List<int> indices = List<int>.generate(end - start + 1, (int offset) => start - 1 + offset);
    widget.coordinator.enqueueIndices(widget.book.bookUrl, indices);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('已加入下载队列：$start ~ $end')));
  }

  /// 按目录索引查找章节标题；目录已变化时回退为索引本身。
  String _chapterTitle(int chapterIndex) {
    for (final BookChapter chapter in widget.chapters) {
      if (chapter.index == chapterIndex) {
        return chapter.title;
      }
    }
    return '第 ${chapterIndex + 1} 章';
  }
}

/// 单个下载任务行：章节标题、状态和重试/移除操作。
final class _DownloadTaskRow extends StatelessWidget {
  /// 创建下载任务行。
  const _DownloadTaskRow({
    required this.task,
    required this.chapterTitle,
    required this.onRetry,
    required this.onRemove,
  });

  /// 当前任务。
  final DownloadTask task;

  /// 目标章节标题。
  final String chapterTitle;

  /// 重试回调，只在失败状态下可用。
  final VoidCallback onRetry;

  /// 移除回调。
  final VoidCallback onRemove;

  /// 构建状态图标、标题和操作按钮。
  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: _statusIcon(context),
      title: Text(chapterTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(_statusLabel()),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (task.status == DownloadTaskStatus.failed)
            IconButton(onPressed: onRetry, icon: const Icon(Icons.replay), tooltip: '重试'),
          IconButton(onPressed: onRemove, icon: const Icon(Icons.close), tooltip: '移除'),
        ],
      ),
    );
  }

  /// 按状态选择图标。
  Widget _statusIcon(BuildContext context) {
    return switch (task.status) {
      DownloadTaskStatus.waiting => const Icon(Icons.schedule),
      DownloadTaskStatus.running => const SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(strokeWidth: 2.4),
      ),
      DownloadTaskStatus.success => Icon(Icons.check_circle, color: Theme.of(context).colorScheme.primary),
      DownloadTaskStatus.failed => Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error),
    };
  }

  /// 按状态生成简短说明；失败态附带已消耗的重试次数。
  String _statusLabel() {
    return switch (task.status) {
      DownloadTaskStatus.waiting => '等待中',
      DownloadTaskStatus.running => '下载中',
      DownloadTaskStatus.success => '已下载',
      DownloadTaskStatus.failed => '失败（已重试 ${task.retryCount} 次）',
    };
  }
}
