import '../../domain/model/book.dart';
import '../../domain/model/book_chapter.dart';
import '../../domain/model/manga_chapter.dart';
import '../../domain/model/manga_reader_config.dart';
import '../../domain/model/manga_reading_position.dart';

/// 漫画阅读器章节加载状态。
enum MangaReaderLoadState {
  /// 正在确认书籍、目录和初始进度。
  initializing,

  /// 正在加载目标章节正文和图片列表。
  loadingChapter,

  /// 当前章节图片列表可以阅读。
  ready,

  /// 当前书籍、目录或章节加载失败。
  error,
}

/// 漫画阅读器不可变业务状态，不持有 Widget、Controller 或平台对象。
final class MangaReaderUiState {
  /// 创建漫画阅读器状态。
  MangaReaderUiState({
    this.book,
    List<BookChapter> chapters = const <BookChapter>[],
    this.currentChapter,
    this.previousChapter,
    this.nextChapter,
    MangaReadingPosition position = const MangaReadingPosition(
      chapterIndex: 0,
      imageIndex: 0,
    ),
    this.loadState = MangaReaderLoadState.initializing,
    this.errorMessage,
    this.menuVisible = true,
    this.isInBookshelf = false,
    this.addingToBookshelf = false,
    this.readerConfig = const MangaReaderConfig(),
    this.isZoomed = false,
  }) : chapters = List<BookChapter>.unmodifiable(chapters),
       position = position;

  /// 当前书籍快照。
  final Book? book;

  /// 当前书籍完整目录。
  final List<BookChapter> chapters;

  /// 当前完成图片解析的章节。
  final MangaChapter? currentChapter;

  /// 当前章最近的上一可阅读章节图片清单。
  final MangaChapter? previousChapter;

  /// 当前章最近的下一可阅读章节图片清单。
  final MangaChapter? nextChapter;

  /// 当前漫画章节与图片的明确语义位置。
  final MangaReadingPosition position;

  /// 当前目录章节索引的兼容读取入口。
  int get currentChapterIndex => position.chapterIndex;

  /// 当前屏幕中心图片索引的兼容读取入口。
  int get currentImageIndex => position.imageIndex;

  /// 书籍或章节加载状态。
  final MangaReaderLoadState loadState;

  /// 当前可恢复错误说明。
  final String? errorMessage;

  /// 顶部和底部工具栏是否显示。
  final bool menuVisible;

  /// 当前书籍是否属于用户书架。
  final bool isInBookshelf;

  /// 是否正在执行显式加入书架动作。
  final bool addingToBookshelf;

  /// 当前路由使用的阅读方向和条漫留白配置。
  final MangaReaderConfig readerConfig;

  /// 当前图片是否处于放大状态；放大期间分页手势必须锁定。
  final bool isZoomed;

  /// 当前章是否存在上一条可阅读目录项。
  bool get canGoPreviousChapter => _readableIndex(-1) != null;

  /// 当前章是否存在下一条可阅读目录项。
  bool get canGoNextChapter => _readableIndex(1) != null;

  /// 当前图片页总数。
  int get imageCount => currentChapter?.imageCount ?? 0;

  /// 从当前索引向指定方向查找下一条非卷标题目录项。
  int? _readableIndex(int direction) {
    int index = currentChapterIndex + direction;
    while (index >= 0 && index < chapters.length) {
      if (!chapters[index].isVolume) {
        return index;
      }
      index += direction;
    }
    return null;
  }

  /// 复制状态并保持集合不可变。
  MangaReaderUiState copyWith({
    Book? book,
    List<BookChapter>? chapters,
    MangaChapter? currentChapter,
    bool clearCurrentChapter = false,
    MangaChapter? previousChapter,
    MangaChapter? nextChapter,
    bool clearAdjacentChapters = false,
    int? currentChapterIndex,
    int? currentImageIndex,
    MangaReadingPosition? position,
    MangaReaderLoadState? loadState,
    String? errorMessage,
    bool clearError = false,
    bool? menuVisible,
    bool? isInBookshelf,
    bool? addingToBookshelf,
    MangaReaderConfig? readerConfig,
    bool? isZoomed,
  }) {
    return MangaReaderUiState(
      book: book ?? this.book,
      chapters: chapters ?? this.chapters,
      currentChapter: clearCurrentChapter
          ? null
          : currentChapter ?? this.currentChapter,
      previousChapter: clearAdjacentChapters
          ? null
          : previousChapter ?? this.previousChapter,
      nextChapter: clearAdjacentChapters
          ? null
          : nextChapter ?? this.nextChapter,
      position: position ??
          this.position.copyWith(
            chapterIndex: currentChapterIndex,
            imageIndex: currentImageIndex,
          ),
      loadState: loadState ?? this.loadState,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
      menuVisible: menuVisible ?? this.menuVisible,
      isInBookshelf: isInBookshelf ?? this.isInBookshelf,
      addingToBookshelf: addingToBookshelf ?? this.addingToBookshelf,
      readerConfig: readerConfig ?? this.readerConfig,
      isZoomed: isZoomed ?? this.isZoomed,
    );
  }
}

/// 漫画阅读器业务意图基类。
sealed class MangaReaderIntent {
  /// 限制意图由本文件定义。
  const MangaReaderIntent();
}

/// 初始化漫画阅读器。
final class InitializeMangaReaderIntent extends MangaReaderIntent {
  /// 创建初始化意图。
  const InitializeMangaReaderIntent();
}

/// 重试或强制刷新当前章节。
final class RetryMangaChapterIntent extends MangaReaderIntent {
  /// 创建章节重试意图。
  const RetryMangaChapterIntent({this.forceRefresh = false});

  /// 是否删除原始正文缓存后重新请求。
  final bool forceRefresh;
}

/// 切换到上一可阅读章节。
final class PreviousMangaChapterIntent extends MangaReaderIntent {
  /// 创建上一章意图。
  const PreviousMangaChapterIntent();
}

/// 切换到下一可阅读章节。
final class NextMangaChapterIntent extends MangaReaderIntent {
  /// 创建下一章意图。
  const NextMangaChapterIntent();
}

/// 从目录跳转到指定章节。
final class JumpToMangaChapterIntent extends MangaReaderIntent {
  /// 创建目录跳转意图。
  const JumpToMangaChapterIntent(this.chapterIndex);

  /// 目标目录索引。
  final int chapterIndex;
}

/// 当前屏幕中心图片发生变化。
final class MangaVisibleImageChangedIntent extends MangaReaderIntent {
  /// 创建可见图片变化意图。
  const MangaVisibleImageChangedIntent(this.imageIndex);

  /// 当前章节内的图片索引。
  final int imageIndex;
}

/// 切换漫画阅读方向。
final class ChangeMangaReadingModeIntent extends MangaReaderIntent {
  /// 创建阅读方向切换意图。
  const ChangeMangaReadingModeIntent(this.mode);

  /// 用户选中的目标阅读方向。
  final MangaReadingMode mode;
}

/// 当前图片缩放状态发生变化。
final class MangaZoomChangedIntent extends MangaReaderIntent {
  /// 创建缩放状态变化意图。
  const MangaZoomChangedIntent(this.isZoomed);

  /// 当前图片是否已经放大。
  final bool isZoomed;
}

/// 切换漫画工具栏显示状态。
final class ToggleMangaMenuIntent extends MangaReaderIntent {
  /// 创建工具栏切换意图。
  const ToggleMangaMenuIntent();
}

/// 显式加入当前漫画到书架。
final class AddMangaToBookshelfIntent extends MangaReaderIntent {
  /// 创建加入书架意图。
  const AddMangaToBookshelfIntent();
}

/// 当前图片完成首帧显示。
final class MangaImageDisplayedIntent extends MangaReaderIntent {
  /// 创建图片首显意图。
  const MangaImageDisplayedIntent(this.imageIndex);

  /// 已成功显示的图片索引。
  final int imageIndex;
}

/// 立即保存当前漫画进度。
final class SaveMangaProgressIntent extends MangaReaderIntent {
  /// 创建保存进度意图。
  const SaveMangaProgressIntent();
}

/// 系统内存压力下释放漫画可重建资源。
final class MangaMemoryPressureIntent extends MangaReaderIntent {
  /// 创建漫画内存压力意图。
  const MangaMemoryPressureIntent();
}

/// 请求打开当前漫画书源的登录或网页验证页面。
final class OpenMangaSourceLoginIntent extends MangaReaderIntent {
  /// 创建书源登录意图。
  const OpenMangaSourceLoginIntent();
}

/// 请求为当前书架漫画执行整书换源。
final class OpenMangaChangeSourceIntent extends MangaReaderIntent {
  /// 创建整书换源意图。
  const OpenMangaChangeSourceIntent();
}

/// 漫画阅读器一次性 Effect。
sealed class MangaReaderEffect {
  /// 限制 Effect 由本文件定义。
  const MangaReaderEffect();
}

/// 显示不含敏感信息的短提示。
final class ShowMangaReaderMessageEffect extends MangaReaderEffect {
  /// 创建提示 Effect。
  const ShowMangaReaderMessageEffect(this.message);

  /// 用户可见提示。
  final String message;
}

/// 打开书源登录页并在用户完成后刷新当前章节。
final class OpenMangaSourceLoginEffect extends MangaReaderEffect {
  /// 创建书源登录 Effect。
  const OpenMangaSourceLoginEffect({required this.sourceUrl, required this.title});

  /// 已收敛为 HTTP(S) 候选的登录起始地址。
  final String sourceUrl;

  /// 登录页面展示的书源名称。
  final String title;
}

/// 打开整书换源页并在成功后替换当前漫画路由。
final class OpenMangaChangeSourceEffect extends MangaReaderEffect {
  /// 创建整书换源 Effect。
  const OpenMangaChangeSourceEffect(this.bookUrl);

  /// 换源事务使用的旧书稳定主键。
  final String bookUrl;
}
