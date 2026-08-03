import '../../app/reader_transition_spec.dart';
import '../../domain/model/book.dart';

/// 阅读历史的显示布局；只影响 UI，不影响历史快照数据。
enum ReadingHistoryLayoutMode {
  /// 单列详情列表。
  list,
  /// 多列封面网格。
  grid,
}

/// 阅读历史按内容形态切换的分类。
enum ReadingHistoryContentCategory {
  /// 普通书籍。
  books,

  /// 图片或漫画书籍。
  manga,
}

/// 阅读历史页面当前需要展示的业务对话框。
sealed class ReadingHistoryDialog {
  /// 限制历史对话框类型。
  const ReadingHistoryDialog();
}

/// 删除选中历史书籍前的影响范围确认。
final class DeleteReadingHistoryDialog extends ReadingHistoryDialog {
  /// 创建历史删除确认，并冻结本次稳定 URL 集合。
  DeleteReadingHistoryDialog(Set<String> bookUrls)
    : bookUrls = Set<String>.unmodifiable(bookUrls);

  /// 等待从历史中移除的书籍稳定 URL。
  final Set<String> bookUrls;
}

/// 阅读历史页面不可变状态。
final class ReadingHistoryUiState {
  /// 创建阅读历史状态。
  ReadingHistoryUiState({
    this.loading = true,
    this.refreshing = false,
    this.layoutMode = ReadingHistoryLayoutMode.grid,
    this.selectedCategory = ReadingHistoryContentCategory.books,
    this.hasManga = false,
    List<Book> books = const <Book>[],
    this.selectionMode = false,
    Set<String> selectedBookUrls = const <String>{},
    this.dialog,
    this.errorMessage,
  }) : books = List<Book>.unmodifiable(books),
       selectedBookUrls = Set<String>.unmodifiable(selectedBookUrls);

  /// 是否尚未取得首个数据库快照。
  final bool loading;
  /// 是否正在重新建立历史数据观察。
  final bool refreshing;
  /// 当前列表或网格显示模式。
  final ReadingHistoryLayoutMode layoutMode;
  /// 当前书籍或漫画分类。
  final ReadingHistoryContentCategory selectedCategory;
  /// 历史中是否存在漫画；不存在时隐藏分类栏。
  final bool hasManga;
  /// 按最近阅读时间倒序排列的书籍快照。
  final List<Book> books;
  /// 是否处于历史长按多选模式。
  final bool selectionMode;
  /// 当前选中的历史书籍稳定 URL。
  final Set<String> selectedBookUrls;
  /// 当前等待路由展示的历史业务对话框。
  final ReadingHistoryDialog? dialog;
  /// 可安全展示的读取错误。
  final String? errorMessage;

  /// 复制历史页面状态。
  ReadingHistoryUiState copyWith({
    bool? loading,
    bool? refreshing,
    ReadingHistoryLayoutMode? layoutMode,
    ReadingHistoryContentCategory? selectedCategory,
    bool? hasManga,
    List<Book>? books,
    bool? selectionMode,
    Set<String>? selectedBookUrls,
    ReadingHistoryDialog? dialog,
    String? errorMessage,
    bool clearDialog = false,
    bool clearError = false,
  }) {
    return ReadingHistoryUiState(
      loading: loading ?? this.loading,
      refreshing: refreshing ?? this.refreshing,
      layoutMode: layoutMode ?? this.layoutMode,
      selectedCategory: selectedCategory ?? this.selectedCategory,
      hasManga: hasManga ?? this.hasManga,
      books: books ?? this.books,
      selectionMode: selectionMode ?? this.selectionMode,
      selectedBookUrls: selectedBookUrls ?? this.selectedBookUrls,
      dialog: clearDialog ? null : dialog ?? this.dialog,
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
  const OpenReadingHistoryBookIntent(
    this.bookUrl, {
    this.transitionSpec,
  });

  /// 目标书籍稳定 URL。
  final String bookUrl;

  /// 点击瞬间形成的一次性封面转场参数。
  final ReaderTransitionSpec? transitionSpec;
}

/// 长按一本历史书籍进入多选模式。
final class LongPressReadingHistoryBookIntent extends ReadingHistoryIntent {
  /// 创建历史长按选择 Intent。
  const LongPressReadingHistoryBookIntent(this.bookUrl);

  /// 首个选中的历史书籍稳定 URL。
  final String bookUrl;
}

/// 全选当前历史页面里的全部书籍。
final class SelectAllReadingHistoryBooksIntent extends ReadingHistoryIntent {
  /// 创建历史全选 Intent。
  const SelectAllReadingHistoryBooksIntent();
}

/// 退出历史多选模式并清空选择。
final class ExitReadingHistorySelectionIntent extends ReadingHistoryIntent {
  /// 创建退出历史选择 Intent。
  const ExitReadingHistorySelectionIntent();
}

/// 请求展示删除历史确认对话框。
final class RequestDeleteReadingHistoryIntent extends ReadingHistoryIntent {
  /// 创建历史删除请求 Intent。
  const RequestDeleteReadingHistoryIntent();
}

/// 确认删除对话框中冻结的历史记录。
final class ConfirmDeleteReadingHistoryIntent extends ReadingHistoryIntent {
  /// 创建确认删除历史 Intent。
  const ConfirmDeleteReadingHistoryIntent();
}

/// 关闭当前历史业务对话框。
final class DismissReadingHistoryDialogIntent extends ReadingHistoryIntent {
  /// 创建关闭历史对话框 Intent。
  const DismissReadingHistoryDialogIntent();
}

/// 切换历史书籍列表和封面网格显示。
final class ToggleReadingHistoryLayoutIntent extends ReadingHistoryIntent {
  /// 创建历史布局切换 Intent。
  const ToggleReadingHistoryLayoutIntent();
}

/// 切换历史书籍或漫画分类。
final class SelectReadingHistoryContentCategoryIntent
    extends ReadingHistoryIntent {
  /// 创建历史分类 Intent。
  const SelectReadingHistoryContentCategoryIntent(this.category);

  /// 目标分类。
  final ReadingHistoryContentCategory category;
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
  const OpenReadingHistoryReaderEffect(
    this.book, {
    this.transitionSpec,
  });

  /// 当前历史书籍快照。
  final Book book;

  /// 原样交给阅读路由的一次性封面转场参数。
  final ReaderTransitionSpec? transitionSpec;
}

/// 展示阅读历史操作的一次性结果提示。
final class ShowReadingHistoryMessageEffect extends ReadingHistoryEffect {
  /// 创建历史提示 Effect。
  const ShowReadingHistoryMessageEffect(this.message);

  /// 可安全展示给用户的短消息。
  final String message;
}
