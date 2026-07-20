import '../../domain/model/book.dart';
import '../../domain/model/book_chapter.dart';
import '../../domain/model/book_search.dart';
import '../../domain/model/book_source.dart';
import '../../domain/model/search_book.dart';

/// 单章换源面板的完整不可变状态；只替换传入章节的正文，不改变书籍主键。
final class ChangeChapterSourceUiState {
  /// 创建单章换源状态，并把集合转换为不可修改快照。
  ChangeChapterSourceUiState({
    required this.book,
    required this.chapterIndex,
    required this.chapterTitle,
    List<BookSource> sources = const <BookSource>[],
    Set<String> selectedSourceUrls = const <String>{},
    this.checkAuthor = false,
    this.searching = false,
    this.cancelled = false,
    this.progress = const BookSearchProgress(
      total: 0,
      completed: 0,
      succeeded: 0,
      failed: 0,
    ),
    List<SearchBook> candidates = const <SearchBook>[],
    List<BookSearchSourceFailure> failures = const <BookSearchSourceFailure>[],
    this.selectedCandidate,
    this.showToc = false,
    this.loadingToc = false,
    List<BookChapter> tocChapters = const <BookChapter>[],
    this.tocSource,
    this.preselectedTocIndex = -1,
    this.tocError,
    this.fetchingContent = false,
    this.errorMessage,
  }) : sources = List<BookSource>.unmodifiable(sources),
       selectedSourceUrls = Set<String>.unmodifiable(selectedSourceUrls),
       candidates = List<SearchBook>.unmodifiable(candidates),
       failures = List<BookSearchSourceFailure>.unmodifiable(failures),
       tocChapters = List<BookChapter>.unmodifiable(tocChapters);

  /// 正在被单章换源的书籍事实；书籍主键本身不会改变。
  final Book book;

  /// 待替换正文的目标章节索引。
  final int chapterIndex;

  /// 待替换正文的目标章节标题，用于候选目录模糊匹配。
  final String chapterTitle;

  /// 当前启用书源快照，供用户限制搜索范围。
  final List<BookSource> sources;

  /// 明确选中的书源 URL；空集合表示全部启用书源。
  final Set<String> selectedSourceUrls;

  /// 是否要求候选作者包含旧作者。
  final bool checkAuthor;

  /// 是否存在正在执行的多书源搜索。
  final bool searching;

  /// 最近一次搜索是否由用户主动取消。
  final bool cancelled;

  /// 当前候选搜索聚合进度。
  final BookSearchProgress progress;

  /// 按来源顺序和 URL 去重后的候选书籍。
  final List<SearchBook> candidates;

  /// 单书源失败摘要；部分失败不阻止其他来源候选展示。
  final List<BookSearchSourceFailure> failures;

  /// 用户正在查看目录的候选。
  final SearchBook? selectedCandidate;

  /// 是否切换到候选目录视图。
  final bool showToc;

  /// 是否正在加载候选完整目录。
  final bool loadingToc;

  /// 候选来源完整目录。
  final List<BookChapter> tocChapters;

  /// 候选目录对应书源，供拉取章节正文使用。
  final BookSource? tocSource;

  /// 模糊匹配预选的目录索引；-1 表示没有合适的预选位置。
  final int preselectedTocIndex;

  /// 候选目录加载失败摘要。
  final String? tocError;

  /// 是否正在拉取用户选定章节的正文。
  final bool fetchingContent;

  /// 页面级错误摘要。
  final String? errorMessage;

  /// 是否可以点击目录中的章节发起正文拉取。
  bool get canSelectChapter =>
      showToc && !loadingToc && tocError == null && tocChapters.isNotEmpty && !fetchingContent;

  /// 复制状态并支持显式清除候选目录、错误和消息。
  ChangeChapterSourceUiState copyWith({
    Book? book,
    int? chapterIndex,
    String? chapterTitle,
    List<BookSource>? sources,
    Set<String>? selectedSourceUrls,
    bool? checkAuthor,
    bool? searching,
    bool? cancelled,
    BookSearchProgress? progress,
    List<SearchBook>? candidates,
    List<BookSearchSourceFailure>? failures,
    SearchBook? selectedCandidate,
    bool? showToc,
    bool? loadingToc,
    List<BookChapter>? tocChapters,
    BookSource? tocSource,
    int? preselectedTocIndex,
    String? tocError,
    bool? fetchingContent,
    String? errorMessage,
    bool clearToc = false,
    bool clearTocError = false,
    bool clearError = false,
  }) {
    return ChangeChapterSourceUiState(
      book: book ?? this.book,
      chapterIndex: chapterIndex ?? this.chapterIndex,
      chapterTitle: chapterTitle ?? this.chapterTitle,
      sources: sources ?? this.sources,
      selectedSourceUrls: selectedSourceUrls ?? this.selectedSourceUrls,
      checkAuthor: checkAuthor ?? this.checkAuthor,
      searching: searching ?? this.searching,
      cancelled: cancelled ?? this.cancelled,
      progress: progress ?? this.progress,
      candidates: candidates ?? this.candidates,
      failures: failures ?? this.failures,
      selectedCandidate: clearToc ? null : selectedCandidate ?? this.selectedCandidate,
      showToc: clearToc ? false : showToc ?? this.showToc,
      loadingToc: clearToc ? false : loadingToc ?? this.loadingToc,
      tocChapters: clearToc ? const <BookChapter>[] : tocChapters ?? this.tocChapters,
      tocSource: clearToc ? null : tocSource ?? this.tocSource,
      preselectedTocIndex: clearToc ? -1 : preselectedTocIndex ?? this.preselectedTocIndex,
      tocError: clearToc || clearTocError ? null : tocError ?? this.tocError,
      fetchingContent: fetchingContent ?? this.fetchingContent,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    );
  }
}

/// 单章换源面板允许的用户操作统一入口。
sealed class ChangeChapterSourceIntent {
  /// 限制 Intent 只能由本文件定义。
  const ChangeChapterSourceIntent();
}

/// 开始或停止当前多书源搜索。
final class StartOrStopChangeChapterSourceSearchIntent extends ChangeChapterSourceIntent {
  /// 创建搜索切换 Intent。
  const StartOrStopChangeChapterSourceSearchIntent();
}

/// 切换候选作者校验并重新开始搜索。
final class ToggleChangeChapterSourceAuthorCheckIntent extends ChangeChapterSourceIntent {
  /// 创建作者校验 Intent。
  const ToggleChangeChapterSourceAuthorCheckIntent(this.enabled);

  /// 新的作者校验状态。
  final bool enabled;
}

/// 切换一个启用书源是否属于本次明确搜索范围。
final class ToggleChangeChapterSourceScopeIntent extends ChangeChapterSourceIntent {
  /// 创建书源范围 Intent。
  const ToggleChangeChapterSourceScopeIntent(this.sourceUrl);

  /// 被切换的书源稳定 URL。
  final String sourceUrl;
}

/// 清空明确选择并恢复搜索全部启用书源。
final class SelectAllChangeChapterSourceScopesIntent extends ChangeChapterSourceIntent {
  /// 创建全部书源 Intent。
  const SelectAllChangeChapterSourceScopesIntent();
}

/// 选择一个候选并加载其完整目录。
final class SelectChangeChapterSourceCandidateIntent extends ChangeChapterSourceIntent {
  /// 创建候选选择 Intent。
  const SelectChangeChapterSourceCandidateIntent(this.candidate);

  /// 待加载目录的搜索候选。
  final SearchBook candidate;
}

/// 从候选目录中选定要替换正文的章节。
final class SelectChangeChapterSourceTocChapterIntent extends ChangeChapterSourceIntent {
  /// 创建目录章节选择 Intent。
  const SelectChangeChapterSourceTocChapterIntent(this.chapter);

  /// 用户选定的候选目录章节。
  final BookChapter chapter;
}

/// 从候选目录视图返回候选列表视图。
final class BackFromChangeChapterSourceTocIntent extends ChangeChapterSourceIntent {
  /// 创建返回候选列表 Intent。
  const BackFromChangeChapterSourceTocIntent();
}

/// 关闭单章换源面板。
final class DismissChangeChapterSourceIntent extends ChangeChapterSourceIntent {
  /// 创建关闭面板 Intent。
  const DismissChangeChapterSourceIntent();
}

/// 单章换源面板的一次性副作用。
sealed class ChangeChapterSourceEffect {
  /// 限制 Effect 只能由本文件定义。
  const ChangeChapterSourceEffect();
}

/// 请求路由显示一次性安全提示。
final class ShowChangeChapterSourceMessageEffect extends ChangeChapterSourceEffect {
  /// 创建提示 Effect。
  const ShowChangeChapterSourceMessageEffect(this.message);

  /// 不包含 URL、正文或书源敏感信息的提示。
  final String message;
}

/// 请求外层阅读器把目标章节正文替换为用户选定的候选正文并关闭面板。
final class ReplaceChangeChapterSourceContentEffect extends ChangeChapterSourceEffect {
  /// 创建正文替换 Effect。
  const ReplaceChangeChapterSourceContentEffect(this.chapterIndex, this.content);

  /// 待替换正文的目标章节索引，与打开面板时的入参一致。
  final int chapterIndex;

  /// 候选来源已拉取到的章节正文。
  final String content;
}

/// 请求路由关闭面板且不替换任何正文。
final class DismissChangeChapterSourceEffect extends ChangeChapterSourceEffect {
  /// 创建关闭面板 Effect。
  const DismissChangeChapterSourceEffect();
}
