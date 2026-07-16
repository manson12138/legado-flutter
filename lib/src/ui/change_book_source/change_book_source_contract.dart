import '../../domain/model/book.dart';
import '../../domain/model/book_chapter.dart';
import '../../domain/model/book_search.dart';
import '../../domain/model/book_source.dart';
import '../../domain/model/search_book.dart';
import '../../domain/usecase/change_book_source_use_case.dart';

/// 整书换源页面的完整不可变状态。
final class ChangeBookSourceUiState {
  /// 创建换源状态，并把集合转换为不可修改快照。
  ChangeBookSourceUiState({
    this.initializing = true,
    this.oldBook,
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
    this.previewBook,
    List<BookChapter> previewChapters = const <BookChapter>[],
    this.loadingPreview = false,
    this.applying = false,
    this.options = const ChangeSourceMigrationOptions(),
    this.previewError,
    this.errorMessage,
  }) : sources = List<BookSource>.unmodifiable(sources),
       selectedSourceUrls = Set<String>.unmodifiable(selectedSourceUrls),
       candidates = List<SearchBook>.unmodifiable(candidates),
       failures = List<BookSearchSourceFailure>.unmodifiable(failures),
       previewChapters = List<BookChapter>.unmodifiable(previewChapters);

  /// 是否正在读取旧书和启用书源。
  final bool initializing;

  /// 当前书架中的旧书籍事实；为空表示初始化尚未完成或书籍已删除。
  final Book? oldBook;

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

  /// 当前换源搜索聚合进度。
  final BookSearchProgress progress;

  /// 按来源顺序和 URL 去重后的候选书籍。
  final List<SearchBook> candidates;

  /// 单书源失败摘要；部分失败不阻止其他来源候选展示。
  final List<BookSearchSourceFailure> failures;

  /// 用户正在预览的搜索候选。
  final SearchBook? selectedCandidate;

  /// 候选详情和目录完成解析后的新书籍事实。
  final Book? previewBook;

  /// 候选来源的完整目录。
  final List<BookChapter> previewChapters;

  /// 是否正在加载候选详情和目录。
  final bool loadingPreview;

  /// 是否正在执行不可重复的原子换源事务。
  final bool applying;

  /// 当前用户选择的迁移范围。
  final ChangeSourceMigrationOptions options;

  /// 候选详情或目录加载失败摘要。
  final String? previewError;

  /// 初始化或页面级搜索失败摘要。
  final String? errorMessage;

  /// 是否已有完整且可提交的候选预览。
  bool get canApply {
    return !applying &&
        !loadingPreview &&
        previewBook != null &&
        previewChapters.isNotEmpty &&
        previewError == null;
  }

  /// 复制状态并支持显式清除候选预览和错误。
  ChangeBookSourceUiState copyWith({
    bool? initializing,
    Book? oldBook,
    List<BookSource>? sources,
    Set<String>? selectedSourceUrls,
    bool? checkAuthor,
    bool? searching,
    bool? cancelled,
    BookSearchProgress? progress,
    List<SearchBook>? candidates,
    List<BookSearchSourceFailure>? failures,
    SearchBook? selectedCandidate,
    Book? previewBook,
    List<BookChapter>? previewChapters,
    bool? loadingPreview,
    bool? applying,
    ChangeSourceMigrationOptions? options,
    String? previewError,
    String? errorMessage,
    bool clearSelection = false,
    bool clearPreviewError = false,
    bool clearError = false,
  }) {
    return ChangeBookSourceUiState(
      initializing: initializing ?? this.initializing,
      oldBook: oldBook ?? this.oldBook,
      sources: sources ?? this.sources,
      selectedSourceUrls: selectedSourceUrls ?? this.selectedSourceUrls,
      checkAuthor: checkAuthor ?? this.checkAuthor,
      searching: searching ?? this.searching,
      cancelled: cancelled ?? this.cancelled,
      progress: progress ?? this.progress,
      candidates: candidates ?? this.candidates,
      failures: failures ?? this.failures,
      selectedCandidate: clearSelection ? null : selectedCandidate ?? this.selectedCandidate,
      previewBook: clearSelection ? null : previewBook ?? this.previewBook,
      previewChapters: clearSelection
          ? const <BookChapter>[]
          : previewChapters ?? this.previewChapters,
      loadingPreview: loadingPreview ?? this.loadingPreview,
      applying: applying ?? this.applying,
      options: options ?? this.options,
      previewError: clearSelection || clearPreviewError
          ? null
          : previewError ?? this.previewError,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    );
  }
}

/// 整书换源页面允许的用户操作统一入口。
sealed class ChangeBookSourceIntent {
  /// 限制 Intent 只能由本文件定义。
  const ChangeBookSourceIntent();
}

/// 开始或停止当前多书源搜索。
final class StartOrStopChangeSourceSearchIntent extends ChangeBookSourceIntent {
  /// 创建搜索切换 Intent。
  const StartOrStopChangeSourceSearchIntent();
}

/// 切换候选作者校验并重新开始搜索。
final class ToggleChangeSourceAuthorCheckIntent extends ChangeBookSourceIntent {
  /// 创建作者校验 Intent。
  const ToggleChangeSourceAuthorCheckIntent(this.enabled);

  /// 新的作者校验状态。
  final bool enabled;
}

/// 切换一个启用书源是否属于本次明确搜索范围。
final class ToggleChangeSourceScopeIntent extends ChangeBookSourceIntent {
  /// 创建书源范围 Intent。
  const ToggleChangeSourceScopeIntent(this.sourceUrl);

  /// 被切换的书源稳定 URL。
  final String sourceUrl;
}

/// 清空明确选择并恢复搜索全部启用书源。
final class SelectAllChangeSourceScopesIntent extends ChangeBookSourceIntent {
  /// 创建全部书源 Intent。
  const SelectAllChangeSourceScopesIntent();
}

/// 选择一个候选并加载其详情和完整目录。
final class SelectChangeSourceCandidateIntent extends ChangeBookSourceIntent {
  /// 创建候选选择 Intent。
  const SelectChangeSourceCandidateIntent(this.candidate);

  /// 待加载预览的搜索候选。
  final SearchBook candidate;
}

/// 关闭当前候选预览并返回结果列表。
final class DismissChangeSourcePreviewIntent extends ChangeBookSourceIntent {
  /// 创建关闭预览 Intent。
  const DismissChangeSourcePreviewIntent();
}

/// 替换整组换源迁移选项。
final class UpdateChangeSourceOptionsIntent extends ChangeBookSourceIntent {
  /// 创建选项更新 Intent。
  const UpdateChangeSourceOptionsIntent(this.options);

  /// 用户选择后的完整迁移范围。
  final ChangeSourceMigrationOptions options;
}

/// 确认把当前完整候选应用到书架。
final class ConfirmChangeBookSourceIntent extends ChangeBookSourceIntent {
  /// 创建确认换源 Intent。
  const ConfirmChangeBookSourceIntent();
}

/// 返回上一个页面。
final class BackFromChangeBookSourceIntent extends ChangeBookSourceIntent {
  /// 创建返回 Intent。
  const BackFromChangeBookSourceIntent();
}

/// 整书换源页面的一次性副作用。
sealed class ChangeBookSourceEffect {
  /// 限制 Effect 只能由本文件定义。
  const ChangeBookSourceEffect();
}

/// 请求路由显示一次性安全提示。
final class ShowChangeBookSourceMessageEffect extends ChangeBookSourceEffect {
  /// 创建提示 Effect。
  const ShowChangeBookSourceMessageEffect(this.message);

  /// 不包含 URL、正文或书源敏感信息的提示。
  final String message;
}

/// 请求路由关闭换源页面且不返回新主键。
final class CloseChangeBookSourceEffect extends ChangeBookSourceEffect {
  /// 创建关闭页面 Effect。
  const CloseChangeBookSourceEffect();
}

/// 请求路由携带换源结果返回调用页面。
final class CompleteChangeBookSourceEffect extends ChangeBookSourceEffect {
  /// 创建换源完成 Effect。
  const CompleteChangeBookSourceEffect(this.result);

  /// 已提交的新书籍主键和非阻断提示。
  final ChangeBookSourceResult result;
}
