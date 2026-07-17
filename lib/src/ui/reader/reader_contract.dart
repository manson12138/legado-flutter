import '../../domain/model/book.dart';
import '../../domain/model/book_chapter.dart';
import '../../domain/model/bookmark.dart';
import '../../domain/model/reader_content.dart';
import '../../domain/model/replace_rule.dart';

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

/// 阅读搜索范围，当前章用于快速定位，整本书会按目录顺序加载章节正文后搜索。
enum ReaderSearchScope {
  /// 只搜索当前已打开章节。
  currentChapter,

  /// 搜索当前书的全部可阅读章节。
  wholeBook,
}

/// 阅读器章节刷新范围，对应顶部刷新和扩展菜单里的后续/全部刷新动作。
enum ReaderRefreshScope {
  /// 只强制刷新当前可见章节。
  currentChapter,

  /// 从下一章开始刷新后续可阅读章节。
  followingChapters,

  /// 从目录第一章开始刷新全部可阅读章节。
  allChapters,
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

/// 阅读中搜索面板。
final class ReaderSearchSheet extends ReaderSheet {
  /// 创建正文搜索面板标识。
  const ReaderSearchSheet();
}

/// 书签备注编辑面板。
final class ReaderBookmarkEditSheet extends ReaderSheet {
  /// 创建书签编辑面板标识。
  const ReaderBookmarkEditSheet(this.bookmark);

  /// 当前需要编辑备注的书签。
  final Bookmark bookmark;
}

/// 替换规则当前章节统计面板。
final class ReaderReplaceInfoSheet extends ReaderSheet {
  /// 创建替换规则信息面板标识。
  const ReaderReplaceInfoSheet();
}

/// 阅读器依赖型后续能力边界面板。
final class ReaderFutureFeaturesSheet extends ReaderSheet {
  /// 创建后续能力边界面板标识。
  const ReaderFutureFeaturesSheet();
}

/// 当前章节内搜索结果项。
final class ReaderSearchMatch {
  /// 创建稳定的章节内搜索结果。
  const ReaderSearchMatch({
    required this.start,
    required this.end,
    required this.preview,
    this.chapterIndex,
    this.chapterTitle = '',
  });

  /// 匹配开始字符位置。
  final int start;

  /// 匹配结束字符位置。
  final int end;

  /// 不含敏感上下文之外的短预览文本。
  final String preview;

  /// 整书搜索时命中的章节索引；为空表示当前章节内结果。
  final int? chapterIndex;

  /// 整书搜索时命中的章节标题；当前章搜索可为空。
  final String chapterTitle;
}

/// 当前章节内搜索状态。
final class ReaderSearchState {
  /// 创建搜索状态。
  const ReaderSearchState({
    this.query = '',
    List<ReaderSearchMatch> matches = const <ReaderSearchMatch>[],
    this.currentIndex = 0,
    this.submitted = false,
    this.scope = ReaderSearchScope.currentChapter,
    this.searching = false,
  }) : matches = matches;

  /// 当前输入的搜索词。
  final String query;

  /// 当前章节内的匹配结果。
  final List<ReaderSearchMatch> matches;

  /// 当前正在查看的匹配结果索引。
  final int currentIndex;

  /// 是否已经执行过一次搜索。
  final bool submitted;

  /// 当前搜索范围。
  final ReaderSearchScope scope;

  /// 是否正在执行可能跨章节加载的搜索。
  final bool searching;

  /// 复制搜索状态。
  ReaderSearchState copyWith({
    String? query,
    List<ReaderSearchMatch>? matches,
    int? currentIndex,
    bool? submitted,
    ReaderSearchScope? scope,
    bool? searching,
  }) {
    return ReaderSearchState(
      query: query ?? this.query,
      matches: matches ?? this.matches,
      currentIndex: currentIndex ?? this.currentIndex,
      submitted: submitted ?? this.submitted,
      scope: scope ?? this.scope,
      searching: searching ?? this.searching,
    );
  }
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
    this.searchState = const ReaderSearchState(),
    this.restoreRequestId = 0,
    this.chapterTransitionDirection = 0,
    this.batteryLevel,
    List<ReplaceRule> replaceRules = const <ReplaceRule>[],
    this.refreshingChapters = false,
  }) : chapters = List<BookChapter>.unmodifiable(chapters),
       bookmarks = List<Bookmark>.unmodifiable(bookmarks),
       replaceRules = List<ReplaceRule>.unmodifiable(replaceRules);

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

  /// 当前章节内正文搜索状态。
  final ReaderSearchState searchState;

  /// 每次章节或字体宽度配置变化时递增，通知路由按字符锚点重新定位。
  final int restoreRequestId;

  /// 最近一次章节切换方向；正数表示下一章从右侧覆盖，负数表示上一章从左侧覆盖。
  final int chapterTransitionDirection;

  /// 平台最近一次返回的电量百分比；为空时页眉页脚隐藏电量。
  final int? batteryLevel;

  /// 当前书名或书源可用的完整正文替换规则列表。
  final List<ReplaceRule> replaceRules;

  /// 是否正在后台刷新后续或全部章节缓存。
  final bool refreshingChapters;

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
    ReaderSearchState? searchState,
    int? restoreRequestId,
    int? chapterTransitionDirection,
    int? batteryLevel,
    List<ReplaceRule>? replaceRules,
    bool? refreshingChapters,
    bool clearContent = false,
    bool clearError = false,
    bool clearSheet = false,
    bool clearBattery = false,
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
      searchState: searchState ?? this.searchState,
      restoreRequestId: restoreRequestId ?? this.restoreRequestId,
      chapterTransitionDirection:
          chapterTransitionDirection ?? this.chapterTransitionDirection,
      batteryLevel: clearBattery ? null : batteryLevel ?? this.batteryLevel,
      replaceRules: replaceRules ?? this.replaceRules,
      refreshingChapters: refreshingChapters ?? this.refreshingChapters,
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

/// 按指定范围强制刷新章节正文缓存。
final class RefreshReaderChaptersIntent extends ReaderIntent {
  /// 创建章节刷新 Intent。
  const RefreshReaderChaptersIntent(this.scope);

  /// 本次需要刷新的章节范围。
  final ReaderRefreshScope scope;
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

/// 更新阅读器平台系统信息，例如电量。
final class UpdateReaderSystemInfoIntent extends ReaderIntent {
  /// 创建系统信息更新 Intent。
  const UpdateReaderSystemInfoIntent({this.batteryLevel});

  /// 平台返回的电量百分比；为空表示当前不可用。
  final int? batteryLevel;
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

/// 保存用户编辑后的书签备注。
final class SaveReaderBookmarkNoteIntent extends ReaderIntent {
  /// 创建书签备注保存 Intent。
  const SaveReaderBookmarkNoteIntent(this.bookmark, this.content);

  /// 需要更新备注的书签。
  final Bookmark bookmark;

  /// 用户编辑后的备注内容。
  final String content;
}

/// 从书签跳转到对应章节和字符位置。
final class OpenReaderBookmarkIntent extends ReaderIntent {
  /// 创建书签跳转 Intent。
  const OpenReaderBookmarkIntent(this.bookmark);

  /// 目标书签。
  final Bookmark bookmark;
}

/// 更新当前章节搜索词。
final class UpdateReaderSearchQueryIntent extends ReaderIntent {
  /// 创建搜索词更新 Intent。
  const UpdateReaderSearchQueryIntent(this.query);

  /// 用户输入的搜索词。
  final String query;
}

/// 更新正文搜索范围。
final class UpdateReaderSearchScopeIntent extends ReaderIntent {
  /// 创建搜索范围更新 Intent。
  const UpdateReaderSearchScopeIntent(this.scope);

  /// 新的搜索范围。
  final ReaderSearchScope scope;
}

/// 在当前章节执行正文搜索。
final class SubmitReaderSearchIntent extends ReaderIntent {
  /// 创建提交搜索 Intent。
  const SubmitReaderSearchIntent();
}

/// 打开指定搜索结果并跳转到匹配位置。
final class OpenReaderSearchResultIntent extends ReaderIntent {
  /// 创建搜索结果跳转 Intent。
  const OpenReaderSearchResultIntent(this.index);

  /// 匹配结果索引。
  final int index;
}

/// 按方向切换当前搜索结果。
final class NavigateReaderSearchResultIntent extends ReaderIntent {
  /// 创建搜索结果方向跳转 Intent。
  const NavigateReaderSearchResultIntent(this.direction);

  /// 前后方向，正数为下一个，负数为上一个。
  final int direction;
}

/// 将当前书签列表导出到剪贴板。
final class ExportReaderBookmarksIntent extends ReaderIntent {
  /// 创建书签导出 Intent。
  const ExportReaderBookmarksIntent();
}

/// 页面进入后台或路由暂时不可见时立即保存进度。
final class PauseReaderIntent extends ReaderIntent {
  /// 创建暂停 Intent。
  const PauseReaderIntent();
}

/// 系统报告内存压力时释放可重建的预加载和章节内存缓存。
final class ReaderMemoryPressureIntent extends ReaderIntent {
  /// 创建内存压力 Intent。
  const ReaderMemoryPressureIntent();
}

/// 保存当前进度后请求打开整书换源页面。
final class OpenReaderBookSourceChangeIntent extends ReaderIntent {
  /// 创建阅读器整书换源 Intent。
  const OpenReaderBookSourceChangeIntent();
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
  const EnterReaderSystemEffect(this.config);

  /// 进入阅读器时需要同步到平台的完整阅读配置。
  final ReaderDisplayConfig config;
}

/// 阅读中更新屏幕常亮状态。
final class UpdateReaderSystemEffect extends ReaderEffect {
  /// 创建更新系统 Effect。
  const UpdateReaderSystemEffect(this.config);

  /// 阅读中需要同步到平台的完整阅读配置。
  final ReaderDisplayConfig config;
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

/// 请求路由层把文本写入系统剪贴板。
final class CopyReaderTextEffect extends ReaderEffect {
  /// 创建复制文本 Effect。
  const CopyReaderTextEffect({
    required this.text,
    required this.message,
  });

  /// 需要写入剪贴板的文本。
  final String text;

  /// 复制完成后显示给用户的提示。
  final String message;
}

/// 请求路由退出阅读系统模式并打开 M11 整书换源页面。
final class OpenReaderBookSourceChangeEffect extends ReaderEffect {
  /// 创建阅读器换源导航 Effect。
  const OpenReaderBookSourceChangeEffect(this.bookUrl);

  /// 当前已保存进度的旧书籍稳定 URL。
  final String bookUrl;
}
