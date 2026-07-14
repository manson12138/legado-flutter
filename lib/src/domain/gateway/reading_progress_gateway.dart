import '../model/reading_progress.dart';

/// 定义阅读进度保存和恢复边界。
abstract interface class ReadingProgressGateway {
  /// 保存阅读位置；书籍不存在时返回 false。
  Future<bool> saveProgress(ReadingProgress progress);

  /// 恢复阅读位置；书籍不存在时返回 null。
  Future<ReadingProgress?> restoreProgress(String bookUrl);
}
