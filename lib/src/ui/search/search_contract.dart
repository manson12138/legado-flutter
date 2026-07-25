import '../../domain/model/book_search.dart';
import '../../domain/model/book_source.dart';
import '../../domain/model/search_book.dart';

/// 搜索结果与关键词的匹配范围；模糊模式保留既有全量结果行为。
enum SearchMatchMode { contains, exact, fuzzy }

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
    this.useAllSources = true,
    this.selectedSourceGroup,
    this.sourceQuery = '',
    this.onlySuccessfulSources = false,
    this.matchMode = SearchMatchMode.fuzzy,
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

  /// 是否选择当前全部可用书源；false 时仅使用 [selectedSourceUrls]。
  final bool useAllSources;

  /// 本次搜索限定的书源分组；null 表示全部书源。
  final String? selectedSourceGroup;

  /// 书源选择面板中的临时搜索词。
  final String sourceQuery;

  /// 是否仅保留已有成功率记录的书源。
  final bool onlySuccessfulSources;

  /// 当前搜索结果匹配模式。
  final SearchMatchMode matchMode;

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
    bool? useAllSources,
    String? selectedSourceGroup,
    bool clearSelectedSourceGroup = false,
    String? sourceQuery,
    bool? onlySuccessfulSources,
    SearchMatchMode? matchMode,
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
       useAllSources: useAllSources ?? this.useAllSources,
       selectedSourceGroup: clearSelectedSourceGroup
           ? null
           : selectedSourceGroup ?? this.selectedSourceGroup,
       sourceQuery: sourceQuery ?? this.sourceQuery,
       onlySuccessfulSources: onlySuccessfulSources ?? this.onlySuccessfulSources,
       matchMode: matchMode ?? this.matchMode,
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

/// 反选当前可用书源。
final class InvertSearchSourcesIntent extends SearchIntent {
  /// 创建反选意图。
  const InvertSearchSourcesIntent();
}

/// 一次性保存搜索书源浮层中编辑完成的全部筛选草稿。
final class ApplySearchSourceSelectionIntent extends SearchIntent {
  /// 创建搜索书源筛选草稿提交意图。
  const ApplySearchSourceSelectionIntent({
    required this.selectedSourceUrls,
    required this.useAllSources,
    required this.selectedSourceGroup,
    required this.sourceQuery,
    required this.onlySuccessfulSources,
  });

  /// 最终选中的书源稳定 URL 集合。
  final Set<String> selectedSourceUrls;
  /// 是否表示全部启用书源都被选中。
  final bool useAllSources;
  /// 最终限定的书源分组；空值表示不限定分组。
  final String? selectedSourceGroup;
  /// 最终用于筛选书源名称的临时关键字。
  final String sourceQuery;
  /// 是否只保留已有成功率的书源。
  final bool onlySuccessfulSources;
}

/// 按书源分组限定本次搜索。
final class ChangeSearchSourceGroupIntent extends SearchIntent {
  /// 创建书源分组筛选意图；null 表示全部。
  const ChangeSearchSourceGroupIntent(this.group);
  /// 目标分组。
  final String? group;
}

/// 修改书源选择面板中的临时搜索词。
final class ChangeSearchSourceQueryIntent extends SearchIntent {
  /// 创建书源搜索意图。
  const ChangeSearchSourceQueryIntent(this.query);
  /// 临时搜索词。
  final String query;
}

/// 切换仅选择有成功率书源。
final class ToggleSuccessfulSearchSourcesIntent extends SearchIntent {
  /// 创建成功率筛选意图。
  const ToggleSuccessfulSearchSourcesIntent();
}

/// 切换结果匹配模式。
final class ChangeSearchMatchModeIntent extends SearchIntent {
  /// 创建匹配模式意图。
  const ChangeSearchMatchModeIntent(this.mode);
  /// 目标模式。
  final SearchMatchMode mode;
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
