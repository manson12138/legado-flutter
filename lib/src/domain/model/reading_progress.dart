/// 表示可保存或恢复的阅读位置，对应 Android `data.entities.BookProgress` 的核心字段。
final class ReadingProgress {
  /// 创建不可变阅读进度；[readTime] 和 [syncTime] 均为 Unix Epoch 毫秒。
  const ReadingProgress({
    required this.bookUrl,
    required this.chapterIndex,
    required this.chapterPos,
    required this.readTime,
    this.chapterTitle,
    this.syncTime = 0,
  });

  /// 所属书籍主键。
  final String bookUrl;
  /// 当前章节从零开始索引。
  final int chapterIndex;
  /// 当前章节首个可见字符位置。
  final int chapterPos;
  /// 最近阅读时间，Unix Epoch 毫秒。
  final int readTime;
  /// 当前章节标题；`null` 表示尚未获得标题。
  final String? chapterTitle;
  /// 最近进度同步时间，Unix Epoch 毫秒；0 表示未同步。
  final int syncTime;
}
