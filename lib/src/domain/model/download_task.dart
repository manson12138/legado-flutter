/// 离线下载队列中单个章节任务的状态，对应 `download_tasks` 表 `status` 列。
enum DownloadTaskStatus {
  /// 已加入队列，等待调度器领取。
  waiting,

  /// 正在下载。
  running,

  /// 已成功下载并写入永久正文缓存。
  success,

  /// 已达到重试上限，需要用户手动重试。
  failed,
}

/// 表示离线下载队列中的一个章节任务，只负责队列可见状态；实际正文仍落在
/// 通用正文缓存表，任务表不冗余存储章节标题或 URL。
final class DownloadTask {
  /// 创建不可变下载任务。
  const DownloadTask({
    required this.bookUrl,
    required this.chapterIndex,
    required this.status,
    this.retryCount = 0,
    required this.updatedAt,
  });

  /// 所属书籍主键，外键指向 `books.bookUrl`。
  final String bookUrl;

  /// 目标章节在目录中的稳定索引。
  final int chapterIndex;

  /// 当前任务状态。
  final DownloadTaskStatus status;

  /// 已消耗的自动重试次数；达到 3 次后转为 [DownloadTaskStatus.failed]。
  final int retryCount;

  /// 最近一次状态变化时间，Unix Epoch 毫秒。
  final int updatedAt;

  /// 复制任务并覆盖指定字段。
  DownloadTask copyWith({
    DownloadTaskStatus? status,
    int? retryCount,
    int? updatedAt,
  }) {
    return DownloadTask(
      bookUrl: bookUrl,
      chapterIndex: chapterIndex,
      status: status ?? this.status,
      retryCount: retryCount ?? this.retryCount,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
