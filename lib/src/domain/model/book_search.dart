import 'book_source.dart';
import 'search_book.dart';

/// 表示同一“书名 + 作者”下由多个书源返回的候选结果组。
final class BookSearchResultGroup {
  /// 创建不可变候选组，并保留最先返回结果作为默认展示项。
  BookSearchResultGroup({required this.key, required List<SearchBook> books})
    : books = List<SearchBook>.unmodifiable(books);

  /// Android 搜索结果兼容键，严格由原始书名和作者组成。
  final String key;

  /// 按书源完成先后保存的候选结果，第一项为默认详情来源。
  final List<SearchBook> books;

  /// 默认展示和打开的候选书。
  SearchBook get primary => books.first;
}

/// 表示单个书源搜索失败，不影响其他书源继续执行。
final class BookSearchSourceFailure {
  /// 创建不包含请求正文、Header 或 Cookie 的安全失败摘要。
  const BookSearchSourceFailure({
    required this.sourceUrl,
    required this.sourceName,
    required this.category,
    required this.message,
  });

  /// 失败书源主键。
  final String sourceUrl;

  /// 失败书源显示名称。
  final String sourceName;

  /// 网络、规则、JavaScript 或取消分类。
  final String category;

  /// 可安全展示的简短原因。
  final String message;
}

/// 表示多书源搜索当前处理进度。
final class BookSearchProgress {
  /// 创建不可变进度快照。
  const BookSearchProgress({
    required this.total,
    required this.completed,
    required this.succeeded,
    required this.failed,
  });

  /// 本次启用且被选中的书源总数。
  final int total;

  /// 已完成书源数。
  final int completed;

  /// 正常完成书源数，空结果也算正常完成。
  final int succeeded;

  /// 执行失败书源数。
  final int failed;
}

/// 表示搜索协调器向 ViewModel 增量发布的不可变事件。
sealed class BookSearchEvent {
  /// 限制事件类型只能由本文件声明。
  const BookSearchEvent();
}

/// 单书源返回新结果时发布的增量事件。
final class BookSearchResultsEvent extends BookSearchEvent {
  /// 创建结果事件。
  BookSearchResultsEvent({required this.source, required List<SearchBook> books})
    : books = List<SearchBook>.unmodifiable(books);

  /// 产生结果的书源。
  final BookSource source;

  /// 当前书源的新结果。
  final List<SearchBook> books;
}

/// 单书源失败时发布的错误事件。
final class BookSearchFailureEvent extends BookSearchEvent {
  /// 创建错误事件。
  const BookSearchFailureEvent(this.failure);

  /// 单源安全错误摘要。
  final BookSearchSourceFailure failure;
}

/// 任一书源结束时发布的进度事件。
final class BookSearchProgressEvent extends BookSearchEvent {
  /// 创建进度事件。
  const BookSearchProgressEvent(this.progress);

  /// 最新进度快照。
  final BookSearchProgress progress;
}

