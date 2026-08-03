import 'book.dart';
import 'reading_progress.dart';

/// 漫画专用阅读位置，明确第二个维度是图片索引而不是文本字符偏移。
final class MangaReadingPosition {
  /// 创建不可变漫画位置；外部恢复值可通过 [clamp] 收敛到真实范围。
  const MangaReadingPosition({
    required this.chapterIndex,
    required this.imageIndex,
  });

  /// 当前目录章节的从零开始索引。
  final int chapterIndex;

  /// 当前章节图片的从零开始索引。
  final int imageIndex;

  /// 从 Android 兼容书籍进度字段恢复漫画语义位置。
  factory MangaReadingPosition.fromBook(Book book) {
    return MangaReadingPosition(
      chapterIndex: book.durChapterIndex,
      imageIndex: book.durChapterPos,
    );
  }

  /// 将章节和图片索引分别收敛到当前真实数量内。
  MangaReadingPosition clamp({
    required int chapterCount,
    int? imageCount,
  }) {
    /// 空目录只能保留安全零位置，调用方仍应展示目录为空错误。
    final int safeChapterIndex = chapterCount <= 0
        ? 0
        : chapterIndex.clamp(0, chapterCount - 1).toInt();
    /// 尚未加载图片清单时只收敛非负值，加载完成后再收敛上界。
    final int safeImageIndex = imageCount == null
        ? imageIndex < 0
            ? 0
            : imageIndex
        : imageCount <= 0
            ? 0
            : imageIndex.clamp(0, imageCount - 1).toInt();
    return MangaReadingPosition(
      chapterIndex: safeChapterIndex,
      imageIndex: safeImageIndex,
    );
  }

  /// 转换为既有数据库适配模型；仅在此边界把图片索引写入 `chapterPos`。
  ReadingProgress toReadingProgress({
    required String bookUrl,
    required int readTime,
    required String? chapterTitle,
    required int syncTime,
  }) {
    return ReadingProgress(
      bookUrl: bookUrl,
      chapterIndex: chapterIndex,
      chapterPos: imageIndex,
      readTime: readTime,
      chapterTitle: chapterTitle,
      syncTime: syncTime,
    );
  }

  /// 复制漫画位置并替换指定维度。
  MangaReadingPosition copyWith({int? chapterIndex, int? imageIndex}) {
    return MangaReadingPosition(
      chapterIndex: chapterIndex ?? this.chapterIndex,
      imageIndex: imageIndex ?? this.imageIndex,
    );
  }
}
