import '../../domain/model/book_search.dart';
import '../../domain/model/book_source.dart';
import '../../domain/model/search_book.dart';

/// 搜索页不可变状态，包含输入、结果、进度、错误、历史和书源筛选。
final class SearchUiState {
  /// 创建搜索页状态。
  SearchUiState({
    this.keyword = '',
    this.committedKeyword = '',
    this.loadingSources = true,
    this.searching = false,
    this.cancelled = false,
    List<BookSource> sources = const <BookSource>[],
    Set<String> selectedSourceUrls = const <String>{},
    List<BookSearchResultGroup> results = const <BookSearchResultGroup>[],
    List<BookSearchSourceFailure> failures = const <BookSearchSourceFailure>[],
    List<String> history = const <String>[],
    this.progress = const BookSearchProgress(total: 0, completed: 0, succeeded: 0, failed: 0),
    this.errorMessage,
  }) : sources = List<BookSource>.unmodifiable(sources),
       selectedSourceUrls = Set<String>.unmodifiable(selectedSourceUrls),
       results = List<BookSearchResultGroup>.unmodifiable(results),
       failures = List<BookSearchSourceFailure>.unmodifiable(failures),
       history = List<String>.unmodifiable(history);

  /// 当前输入关键字。
  final String keyword;

  /// 当前结果对应的已提交关键字。
  final String committedKeyword;

  /// 是否正在读取启用书源和历史。
  final bool loadingSources;

  /// 是否有搜索 worker 仍在运行。
  final bool searching;

  /// 当前结果是否由用户主动停止。
  final bool cancelled;

  /// 本次可选的启用书源快照。
  final List<BookSource> sources;

  /// 选中书源 URL；空集合表示全部启用书源。
  final Set<String> selectedSourceUrls;

  /// 已由 ViewModel 按书名作者去重的增量结果。
  final List<BookSearchResultGroup> results;

  /// 不终止整体搜索的单源失败列表。
  final List<BookSearchSourceFailure> failures;

  /// 最近搜索关键字。
  final List<String> history;

  /// 当前书源处理进度。
  final BookSearchProgress progress;

  /// 页面级可恢复错误。
  final String? errorMessage;

  /// 复制搜索状态。
  SearchUiState copyWith({
    String? keyword,
    String? committedKeyword,
    bool? loadingSources,
    bool? searching,
    bool? cancelled,
    List<BookSource>? sources,
    Set<String>? selectedSourceUrls,
    List<BookSearchResultGroup>? results,
    List<BookSearchSourceFailure>? failures,
    List<String>? history,
    BookSearchProgress? progress,
    String? errorMessage,
    bool clearError = false,
  }) {
    return SearchUiState(
      keyword: keyword ?? this.keyword,
      committedKeyword: committedKeyword ?? this.committedKeyword,
      loadingSources: loadingSources ?? this.loadingSources,
      searching: searching ?? this.searching,
      cancelled: cancelled ?? this.cancelled,
      sources: sources ?? this.sources,
      selectedSourceUrls: selectedSourceUrls ?? this.selectedSourceUrls,
      results: results ?? this.results,
      failures: failures ?? this.failures,
      history: history ?? this.history,
      progress: progress ?? this.progress,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    );
  }
}

/// 搜索页所有用户操作的统一入口类型。
sealed class SearchIntent {
  /// 限制 Intent 类型只能由本文件声明。
  const SearchIntent();
}

/// 修改搜索输入。
final class ChangeSearchKeywordIntent extends SearchIntent {
  /// 创建输入 Intent。
  const ChangeSearchKeywordIntent(this.keyword);
  /// 新输入值。
  final String keyword;
}

/// 提交当前或指定关键字搜索。
final class SubmitSearchIntent extends SearchIntent {
  /// 创建提交 Intent。
  const SubmitSearchIntent({this.keyword});
  /// 历史点击时提供的可选关键字。
  final String? keyword;
}

/// 停止当前搜索。
final class CancelSearchIntent extends SearchIntent {
  /// 创建停止 Intent。
  const CancelSearchIntent();
}

/// 只重试上次失败书源。
final class RetryFailedSourcesIntent extends SearchIntent {
  /// 创建重试 Intent。
  const RetryFailedSourcesIntent();
}

/// 切换单个搜索书源。
final class ToggleSearchSourceIntent extends SearchIntent {
  /// 创建书源选择 Intent。
  const ToggleSearchSourceIntent(this.sourceUrl);
  /// 书源 URL。
  final String sourceUrl;
}

/// 选择或清空全部书源筛选。
final class SelectAllSearchSourcesIntent extends SearchIntent {
  /// 创建全选 Intent。
  const SelectAllSearchSourcesIntent();
}

/// 清空搜索历史。
final class ClearSearchHistoryIntent extends SearchIntent {
  /// 创建清空历史 Intent。
  const ClearSearchHistoryIntent();
}

/// 打开搜索结果详情。
final class OpenSearchResultIntent extends SearchIntent {
  /// 创建详情导航 Intent。
  const OpenSearchResultIntent(this.group, this.book);
  /// 同名作者候选组。
  final BookSearchResultGroup group;
  /// 当前选择的来源候选。
  final SearchBook book;
}

/// 返回上一页。
final class BackFromSearchIntent extends SearchIntent {
  /// 创建返回 Intent。
  const BackFromSearchIntent();
}

/// 搜索页一次性副作用。
sealed class SearchEffect {
  /// 限制 Effect 类型只能由本文件声明。
  const SearchEffect();
}

/// 导航到书籍详情。
final class OpenBookInfoEffect extends SearchEffect {
  /// 创建详情导航 Effect。
  const OpenBookInfoEffect(this.group, this.book);
  /// 候选来源组。
  final BookSearchResultGroup group;
  /// 默认打开候选。
  final SearchBook book;
}

/// 展示一次性提示。
final class ShowSearchMessageEffect extends SearchEffect {
  /// 创建提示 Effect。
  const ShowSearchMessageEffect(this.message);
  /// 提示文本。
  final String message;
}

/// 请求返回上一页。
final class CloseSearchEffect extends SearchEffect {
  /// 创建返回 Effect。
  const CloseSearchEffect();
}
