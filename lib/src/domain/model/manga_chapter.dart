import 'book_chapter.dart';
import 'manga_page.dart';

/// 漫画章节正文经过安全图片解析后的结果状态。
enum MangaChapterContentState {
  /// 章节至少包含一张有效图片，可以进入阅读状态。
  ready,

  /// 当前目录项只是卷标题，不应当作加载失败处理。
  volume,

  /// 章节正文为空，允许界面提供刷新或换源入口。
  emptyContent,

  /// 章节正文存在，但没有解析出任何安全图片。
  noImages,
}

/// 漫画章节及其有序图片页集合，对应 Android `MangaChapter`。
final class MangaChapter {
  /// 创建不可变漫画章节解析结果。
  MangaChapter({
    required this.chapter,
    required List<MangaPage> pages,
    required this.state,
  }) : pages = List<MangaPage>.unmodifiable(pages);

  /// 原始目录章节事实。
  final BookChapter chapter;

  /// 按正文出现顺序排列且仅相邻去重的图片页。
  final List<MangaPage> pages;

  /// 区分可读、卷标题、空正文和无图片正文的受控状态。
  final MangaChapterContentState state;

  /// 当前章节的有效图片数量。
  int get imageCount => pages.length;

  /// 当前章节是否已经具备可阅读图片。
  bool get isReady => state == MangaChapterContentState.ready;
}
