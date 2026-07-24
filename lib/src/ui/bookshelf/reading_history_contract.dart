import '../../domain/model/book.dart';

/// 阅读历史的显示布局；只影响 UI，不影响历史快照数据。
enum ReadingHistoryLayoutMode {
  /// 单列详情列表。
  list,
  /// 多列封面网格。
  grid,
}

/// 阅读历史页面不可变状态。
final class ReadingHistoryUiState {
  /// 创建阅读历史状态。
  ReadingHistoryUiState({
    this.loading = true,
    this.refreshing = false,
    this.layoutMode = ReadingHistoryLayoutMode.list,
    List<Book> books = const <Book>[],
    this.errorMessage,
  }) : books = List<Book>.unmodifiable(books);

  /// 是否尚未取得首个数据库快照。
  final bool loading;
  /// 是否正在重新建立历史数据观察。
  final bool refreshing;
  /// 当前列表或网格显示模式。
  final ReadingHistoryLayoutMode layoutMode;
  /// 按最近阅读时间倒序排列的书籍快照。
  final List<Book> books;
  /// 可安全展示的读取错误。
  final String? errorMessage;

  /// 复制历史页面状态。
  ReadingHistoryUiState copyWith({
    bool? loading,
    bool? refreshing,
    ReadingHistoryLayoutMode? layoutMode,
    List<Book>? books,
    String? errorMessage,
    bool clearError = false,
  }) {
    return ReadingHistoryUiState(
      loading: loading ?? this.loading,
      refreshing: refreshing ?? this.refreshing,
      layoutMode: layoutMode ?? this.layoutMode,
      books: books ?? this.books,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    );
  }
}

/// 阅读历史页面用户操作。
sealed class ReadingHistoryIntent {
  /// 限制 Intent 类型。
  const ReadingHistoryIntent();
}

/// 打开一条历史书籍。
final class OpenReadingHistoryBookIntent extends ReadingHistoryIntent {
  /// 创建历史阅读 Intent。
  const OpenReadingHistoryBookIntent(this.bookUrl);

  /// 目标书籍稳定 URL。
  final String bookUrl;
}

/// 切换历史书籍列表和封面网格显示。
final class ToggleReadingHistoryLayoutIntent extends ReadingHistoryIntent {
  /// 创建历史布局切换 Intent。
  const ToggleReadingHistoryLayoutIntent();
}

/// 重新建立历史快照观察，以获取当前数据库的最新结果。
final class RefreshReadingHistoryIntent extends ReadingHistoryIntent {
  /// 创建历史刷新 Intent。
  const RefreshReadingHistoryIntent();
}

/// 阅读历史页面一次性副作用。
sealed class ReadingHistoryEffect {
  /// 限制 Effect 类型。
  const ReadingHistoryEffect();
}

/// 请求从历史入口打开阅读器。
final class OpenReadingHistoryReaderEffect extends ReadingHistoryEffect {
  /// 创建历史阅读器导航 Effect。
  const OpenReadingHistoryReaderEffect(this.book);

  /// 当前历史书籍快照。
  final Book book;
}
