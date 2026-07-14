import '../../domain/model/book.dart';
import '../../domain/model/book_chapter.dart';
import '../../domain/model/bookmark.dart';
import '../../domain/model/reader_content.dart';

/// 阅读器正文加载状态，空正文与失败不会伪装成已完成。
enum ReaderLoadState {
  /// 尚未完成书籍和目录初始化。
  initializing,

  /// 正在加载或处理目标章节。
  loading,

  /// 当前章节正文可以阅读。
  ready,

  /// 当前章节加载失败，可由用户重试。
  error,
}

/// 阅读器当前展示的业务面板。
sealed class ReaderSheet {
  /// 限制面板类型只能由本文件定义。
  const ReaderSheet();
}

/// 目录跳转面板。
final class ReaderTocSheet extends ReaderSheet {
  /// 创建目录面板标识。
  const ReaderTocSheet();
}

/// 基础显示设置面板。
final class ReaderSettingsSheet extends ReaderSheet {
  /// 创建显示设置面板标识。
  const ReaderSettingsSheet();
}

/// 书签查看与跳转面板。
final class ReaderBookmarksSheet extends ReaderSheet {
  /// 创建书签面板标识。
  const ReaderBookmarksSheet();
}

/// 阅读器完整不可变 UiState，业务状态不依赖 ScrollController 或平台窗口对象。
final class ReaderUiState {
  /// 创建阅读器状态。
  ReaderUiState({
    this.book,
    List<BookChapter> chapters = const <BookChapter>[],
    this.currentChapterIndex = 0,
    this.content,
    this.anchor,
    this.config = const ReaderDisplayConfig(),
    List<Bookmark> bookmarks = const <Bookmark>[],
    this.loadState = ReaderLoadState.initializing,
    this.errorMessage,
    this.menuVisible = true,
    this.activeSheet,
    this.restoreRequestId = 0,
  }) : chapters = List<BookChapter>.unmodifiable(chapters),
       bookmarks = List<Bookmark>.unmodifiable(bookmarks);

  /// 当前书架书籍。
  final Book? book;

  /// 按稳定索引排序的完整目录。
  final List<BookChapter> chapters;

  /// 当前目录章节索引。
  final int currentChapterIndex;

  /// 当前处理完成的正文和惰性分块。
  final ReaderChapterContent? content;

  /// 当前首个可见内容的稳定字符锚点。
  final ReaderPositionAnchor? anchor;

  /// 当前单书显示、替换和常亮配置。
  final ReaderDisplayConfig config;

  /// 当前书名与作者关联的书签。
  final List<Bookmark> bookmarks;

  /// 当前初始化或正文加载状态。
  final ReaderLoadState loadState;

  /// 可安全展示的页面错误摘要。
  final String? errorMessage;

  /// 顶部和底部阅读菜单是否可见。
  final bool menuVisible;

  /// 当前由路由层展示的目录、设置或书签面板。
  final ReaderSheet? activeSheet;

  /// 每次章节或字体宽度配置变化时递增，通知路由按字符锚点重新定位。
  final int restoreRequestId;

  /// 当前章节；目录为空或索引越界时为 null。
  BookChapter? get currentChapter {
    if (currentChapterIndex < 0 || currentChapterIndex >= chapters.length) {
      return null;
    }
    return chapters[currentChapterIndex];
  }

  /// 是否存在上一可阅读章节。
  bool get canGoPrevious => _findReadableIndex(-1) != null;

  /// 是否存在下一可阅读章节。
  bool get canGoNext => _findReadableIndex(1) != null;

  /// 从当前索引查找指定方向的下一可阅读章节。
  int? _findReadableIndex(int direction) {
    int index = currentChapterIndex + direction;
    while (index >= 0 && index < chapters.length) {
      if (!chapters[index].isVolume) {
        return index;
      }
      index += direction;
    }
    return null;
  }

  /// 复制状态并支持显式清除正文、错误和面板。
  ReaderUiState copyWith({
    Book? book,
    List<BookChapter>? chapters,
    int? currentChapterIndex,
    ReaderChapterContent? content,
    ReaderPositionAnchor? anchor,
    ReaderDisplayConfig? config,
    List<Bookmark>? bookmarks,
    ReaderLoadState? loadState,
    String? errorMessage,
    bool? menuVisible,
    ReaderSheet? activeSheet,
    int? restoreRequestId,
    bool clearContent = false,
    bool clearError = false,
    bool clearSheet = false,
  }) {
    return ReaderUiState(
      book: book ?? this.book,
      chapters: chapters ?? this.chapters,
      currentChapterIndex: currentChapterIndex ?? this.currentChapterIndex,
      content: clearContent ? null : content ?? this.content,
      anchor: anchor ?? this.anchor,
      config: config ?? this.config,
      bookmarks: bookmarks ?? this.bookmarks,
      loadState: loadState ?? this.loadState,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
      menuVisible: menuVisible ?? this.menuVisible,
      activeSheet: clearSheet ? null : activeSheet ?? this.activeSheet,
      restoreRequestId: restoreRequestId ?? this.restoreRequestId,
    );
  }
}

/// 阅读器所有用户和生命周期操作的统一入口。
sealed class ReaderIntent {
  /// 限制 Intent 类型。
  const ReaderIntent();
}

/// 初始化书籍、目录、配置和恢复进度。
final class InitializeReaderIntent extends ReaderIntent {
  /// 创建初始化 Intent。
  const InitializeReaderIntent();
}

/// 更新首个可见字符位置；ViewModel 会节流持久化。
final class UpdateReaderScrollIntent extends ReaderIntent {
  /// 创建滚动位置 Intent。
  const UpdateReaderScrollIntent(this.characterOffset);

  /// 根据当前布局比例换算的章节内字符位置。
  final int characterOffset;
}

/// 打开上一可阅读章节。
final class OpenPreviousChapterIntent extends ReaderIntent {
  /// 创建上一章 Intent。
  const OpenPreviousChapterIntent();
}

/// 打开下一可阅读章节。
final class OpenNextChapterIntent extends ReaderIntent {
  /// 创建下一章 Intent。
  const OpenNextChapterIntent();
}

/// 从目录或书签打开指定章节和字符位置。
final class OpenReaderChapterIntent extends ReaderIntent {
  /// 创建章节跳转 Intent。
  const OpenReaderChapterIntent(this.chapterIndex, {this.characterOffset = 0});

  /// 目标章节索引。
  final int chapterIndex;

  /// 目标章节内字符位置。
  final int characterOffset;
}

/// 重试当前章节，并允许绕过损坏的持久正文缓存。
final class RetryReaderChapterIntent extends ReaderIntent {
  /// 创建重试 Intent。
  const RetryReaderChapterIntent({this.forceRefresh = true});

  /// 是否强制重新请求书源正文。
  final bool forceRefresh;
}

/// 点击正文中央区域切换阅读菜单。
final class ToggleReaderMenuIntent extends ReaderIntent {
  /// 创建菜单切换 Intent。
  const ToggleReaderMenuIntent();
}

/// 展示目录、设置或书签面板。
final class ShowReaderSheetIntent extends ReaderIntent {
  /// 创建面板 Intent。
  const ShowReaderSheetIntent(this.sheet);

  /// 目标业务面板。
  final ReaderSheet sheet;
}

/// 关闭当前阅读面板。
final class DismissReaderSheetIntent extends ReaderIntent {
  /// 创建关闭面板 Intent。
  const DismissReaderSheetIntent();
}

/// 保存新的显示、替换或常亮配置。
final class UpdateReaderConfigIntent extends ReaderIntent {
  /// 创建配置更新 Intent。
  const UpdateReaderConfigIntent(this.config);

  /// 完整新配置。
  final ReaderDisplayConfig config;
}

/// 在当前字符位置添加书签。
final class AddReaderBookmarkIntent extends ReaderIntent {
  /// 创建添加书签 Intent。
  const AddReaderBookmarkIntent();
}

/// 删除指定书签。
final class DeleteReaderBookmarkIntent extends ReaderIntent {
  /// 创建删除书签 Intent。
  const DeleteReaderBookmarkIntent(this.bookmark);

  /// 待删除书签。
  final Bookmark bookmark;
}

/// 从书签跳转到对应章节和字符位置。
final class OpenReaderBookmarkIntent extends ReaderIntent {
  /// 创建书签跳转 Intent。
  const OpenReaderBookmarkIntent(this.bookmark);

  /// 目标书签。
  final Bookmark bookmark;
}

/// 页面进入后台或路由暂时不可见时立即保存进度。
final class PauseReaderIntent extends ReaderIntent {
  /// 创建暂停 Intent。
  const PauseReaderIntent();
}

/// 用户返回书架，先保存进度再发出关闭 Effect。
final class CloseReaderIntent extends ReaderIntent {
  /// 创建关闭阅读器 Intent。
  const CloseReaderIntent();
}

/// 阅读器一次性导航、平台能力和消息副作用。
sealed class ReaderEffect {
  /// 限制 Effect 类型。
  const ReaderEffect();
}

/// 进入沉浸阅读并按配置设置屏幕常亮。
final class EnterReaderSystemEffect extends ReaderEffect {
  /// 创建进入阅读系统 Effect。
  const EnterReaderSystemEffect(this.keepScreenOn);

  /// 是否请求平台保持屏幕常亮。
  final bool keepScreenOn;
}

/// 阅读中更新屏幕常亮状态。
final class UpdateReaderSystemEffect extends ReaderEffect {
  /// 创建更新系统 Effect。
  const UpdateReaderSystemEffect(this.keepScreenOn);

  /// 是否请求平台保持屏幕常亮。
  final bool keepScreenOn;
}

/// 离开阅读器并恢复系统栏和平台窗口原状态。
final class ExitReaderSystemEffect extends ReaderEffect {
  /// 创建退出系统 Effect。
  const ExitReaderSystemEffect();
}

/// 关闭当前阅读路由。
final class CloseReaderRouteEffect extends ReaderEffect {
  /// 创建关闭路由 Effect。
  const CloseReaderRouteEffect();
}

/// 展示不包含敏感正文的轻量消息。
final class ShowReaderMessageEffect extends ReaderEffect {
  /// 创建消息 Effect。
  const ShowReaderMessageEffect(this.message);

  /// 用户可见消息。
  final String message;
}
