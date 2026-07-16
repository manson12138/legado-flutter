import '../../domain/model/book.dart';
import '../../domain/model/book_group.dart';
import '../../model/bookshelf/bookshelf_refresh_coordinator.dart';

/// 书架布局模式，列表和网格共享同一 ViewModel 状态。
enum BookshelfLayoutMode {
  /// 单列详细列表。
  list,
  /// 多列封面网格。
  grid,
}

/// Android 兼容书架排序字段。
enum BookshelfSortMode {
  /// 最近阅读时间。
  recentRead,
  /// 最新章节更新时间。
  latestUpdate,
  /// 书名。
  name,
  /// 用户手动顺序。
  manual,
  /// 阅读或更新中的最近活动时间。
  recentActivity,
  /// 作者。
  author,
}

/// 书架使用的稳定显示模型，不修改核心 Book 实体含义。
final class BookshelfBookItem {
  /// 创建书架显示模型。
  const BookshelfBookItem({required this.book, required this.unreadChapterCount});

  /// 持久化书籍事实。
  final Book book;
  /// 按 Android 公式计算的剩余未读章节数。
  final int unreadChapterCount;

  /// 优先使用用户封面，否则使用书源封面。
  String? get displayCoverUrl {
    /// 用户自定义封面。
    final String? custom = book.customCoverUrl;
    return custom?.trim().isNotEmpty == true ? custom : book.coverUrl;
  }
}

/// 书架分组选择项。
final class BookshelfGroupItem {
  /// 创建带书籍数量的分组项。
  const BookshelfGroupItem({required this.group, required this.bookCount});
  /// 系统或用户分组。
  final BookGroup group;
  /// 当前分组包含书籍数。
  final int bookCount;
}

/// 书架当前业务对话框。
sealed class BookshelfDialog {
  /// 限制对话框类型。
  const BookshelfDialog();
}

/// 删除书籍确认对话框。
final class DeleteBookshelfBooksDialog extends BookshelfDialog {
  /// 创建删除确认。
  DeleteBookshelfBooksDialog(Set<String> bookUrls)
    : bookUrls = Set<String>.unmodifiable(bookUrls);
  /// 待删除稳定 URL。
  final Set<String> bookUrls;
}

/// 批量移动分组对话框。
final class MoveBookshelfBooksDialog extends BookshelfDialog {
  /// 创建移动分组对话框。
  MoveBookshelfBooksDialog(Set<String> bookUrls)
    : bookUrls = Set<String>.unmodifiable(bookUrls);
  /// 待移动稳定 URL。
  final Set<String> bookUrls;
}

/// 书架完整不可变 UiState。
final class BookshelfUiState {
  /// 创建书架状态。
  BookshelfUiState({
    this.loading = true,
    this.layoutMode = BookshelfLayoutMode.grid,
    this.sortMode = BookshelfSortMode.recentRead,
    this.descending = true,
    this.selectedGroupId = BookGroup.idAll,
    List<BookshelfGroupItem> groups = const <BookshelfGroupItem>[],
    List<BookshelfBookItem> books = const <BookshelfBookItem>[],
    this.query = '',
    this.selectionMode = false,
    Set<String> selectedBookUrls = const <String>{},
    this.refreshing = false,
    this.refreshCancelled = false,
    this.refreshProgress = const BookshelfRefreshProgress(total: 0, completed: 0, succeeded: 0, failed: 0),
    List<BookshelfRefreshFailure> refreshFailures = const <BookshelfRefreshFailure>[],
    Set<String> updatingBookUrls = const <String>{},
    this.dialog,
    this.errorMessage,
  }) : groups = List<BookshelfGroupItem>.unmodifiable(groups),
       books = List<BookshelfBookItem>.unmodifiable(books),
       selectedBookUrls = Set<String>.unmodifiable(selectedBookUrls),
       refreshFailures = List<BookshelfRefreshFailure>.unmodifiable(refreshFailures),
       updatingBookUrls = Set<String>.unmodifiable(updatingBookUrls);

  /// 是否等待首次数据。
  final bool loading;
  /// 当前列表或网格布局。
  final BookshelfLayoutMode layoutMode;
  /// 当前排序字段。
  final BookshelfSortMode sortMode;
  /// 是否倒序。
  final bool descending;
  /// 当前分组 ID。
  final int selectedGroupId;
  /// 可见系统和用户分组。
  final List<BookshelfGroupItem> groups;
  /// 已筛选并排序的书籍。
  final List<BookshelfBookItem> books;
  /// 当前搜索词。
  final String query;
  /// 是否处于长按选择模式。
  final bool selectionMode;
  /// 当前选择的稳定书籍 URL。
  final Set<String> selectedBookUrls;
  /// 是否正在刷新目录。
  final bool refreshing;
  /// 最近刷新是否被主动取消。
  final bool refreshCancelled;
  /// 当前刷新进度。
  final BookshelfRefreshProgress refreshProgress;
  /// 单书刷新失败摘要。
  final List<BookshelfRefreshFailure> refreshFailures;
  /// 当前待刷新或正在刷新的书籍 URL。
  final Set<String> updatingBookUrls;
  /// 当前业务对话框。
  final BookshelfDialog? dialog;
  /// 页面级错误摘要。
  final String? errorMessage;

  /// 复制书架状态。
  BookshelfUiState copyWith({
    bool? loading,
    BookshelfLayoutMode? layoutMode,
    BookshelfSortMode? sortMode,
    bool? descending,
    int? selectedGroupId,
    List<BookshelfGroupItem>? groups,
    List<BookshelfBookItem>? books,
    String? query,
    bool? selectionMode,
    Set<String>? selectedBookUrls,
    bool? refreshing,
    bool? refreshCancelled,
    BookshelfRefreshProgress? refreshProgress,
    List<BookshelfRefreshFailure>? refreshFailures,
    Set<String>? updatingBookUrls,
    BookshelfDialog? dialog,
    String? errorMessage,
    bool clearDialog = false,
    bool clearError = false,
  }) {
    return BookshelfUiState(
      loading: loading ?? this.loading,
      layoutMode: layoutMode ?? this.layoutMode,
      sortMode: sortMode ?? this.sortMode,
      descending: descending ?? this.descending,
      selectedGroupId: selectedGroupId ?? this.selectedGroupId,
      groups: groups ?? this.groups,
      books: books ?? this.books,
      query: query ?? this.query,
      selectionMode: selectionMode ?? this.selectionMode,
      selectedBookUrls: selectedBookUrls ?? this.selectedBookUrls,
      refreshing: refreshing ?? this.refreshing,
      refreshCancelled: refreshCancelled ?? this.refreshCancelled,
      refreshProgress: refreshProgress ?? this.refreshProgress,
      refreshFailures: refreshFailures ?? this.refreshFailures,
      updatingBookUrls: updatingBookUrls ?? this.updatingBookUrls,
      dialog: clearDialog ? null : dialog ?? this.dialog,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    );
  }
}

/// 书架页面所有用户操作的统一入口。
sealed class BookshelfIntent {
  /// 限制 Intent 类型。
  const BookshelfIntent();
}

/// 修改书架搜索词。
final class ChangeBookshelfQueryIntent extends BookshelfIntent {
  /// 创建搜索 Intent。
  const ChangeBookshelfQueryIntent(this.query);
  /// 新搜索词。
  final String query;
}

/// 切换列表和网格。
final class ToggleBookshelfLayoutIntent extends BookshelfIntent {
  /// 创建布局切换 Intent。
  const ToggleBookshelfLayoutIntent();
}

/// 选择书架分组。
final class SelectBookshelfGroupIntent extends BookshelfIntent {
  /// 创建分组 Intent。
  const SelectBookshelfGroupIntent(this.groupId);
  /// 目标分组 ID。
  final int groupId;
}

/// 修改排序字段。
final class ChangeBookshelfSortIntent extends BookshelfIntent {
  /// 创建排序 Intent。
  const ChangeBookshelfSortIntent(this.sortMode);
  /// 新排序字段。
  final BookshelfSortMode sortMode;
}

/// 切换排序方向。
final class ToggleBookshelfSortOrderIntent extends BookshelfIntent {
  /// 创建排序方向 Intent。
  const ToggleBookshelfSortOrderIntent();
}

/// 打开或选择一本书。
final class TapBookshelfBookIntent extends BookshelfIntent {
  /// 创建点击 Intent。
  const TapBookshelfBookIntent(this.bookUrl);
  /// 书籍稳定 URL。
  final String bookUrl;
}

/// 长按进入选择模式。
final class LongPressBookshelfBookIntent extends BookshelfIntent {
  /// 创建长按 Intent。
  const LongPressBookshelfBookIntent(this.bookUrl);
  /// 首个选择书籍 URL。
  final String bookUrl;
}

/// 全选当前可见书籍。
final class SelectAllBookshelfBooksIntent extends BookshelfIntent {
  /// 创建全选 Intent。
  const SelectAllBookshelfBooksIntent();
}

/// 退出选择模式。
final class ExitBookshelfSelectionIntent extends BookshelfIntent {
  /// 创建退出选择 Intent。
  const ExitBookshelfSelectionIntent();
}

/// 刷新当前可见或选中书籍目录。
final class RefreshBookshelfIntent extends BookshelfIntent {
  /// 创建刷新 Intent。
  const RefreshBookshelfIntent();
}

/// 取消目录刷新。
final class CancelBookshelfRefreshIntent extends BookshelfIntent {
  /// 创建取消刷新 Intent。
  const CancelBookshelfRefreshIntent();
}

/// 请求删除选中书籍。
final class RequestDeleteBookshelfBooksIntent extends BookshelfIntent {
  /// 创建删除请求 Intent。
  const RequestDeleteBookshelfBooksIntent();
}

/// 确认删除对话框中的书籍。
final class ConfirmDeleteBookshelfBooksIntent extends BookshelfIntent {
  /// 创建确认删除 Intent。
  const ConfirmDeleteBookshelfBooksIntent();
}

/// 请求移动选中书籍到分组。
final class RequestMoveBookshelfBooksIntent extends BookshelfIntent {
  /// 创建移动请求 Intent。
  const RequestMoveBookshelfBooksIntent();
}

/// 确认移动到指定分组。
final class ConfirmMoveBookshelfBooksIntent extends BookshelfIntent {
  /// 创建移动确认 Intent。
  const ConfirmMoveBookshelfBooksIntent(this.groupId);
  /// 目标分组 ID；0 表示清除用户分组。
  final int groupId;
}

/// 创建新分组并把当前选中书籍移动进去。
final class CreateAndMoveBookshelfGroupIntent extends BookshelfIntent {
  /// 创建新分组 Intent。
  const CreateAndMoveBookshelfGroupIntent(this.name);
  /// 新分组名称。
  final String name;
}

/// 关闭当前对话框。
final class DismissBookshelfDialogIntent extends BookshelfIntent {
  /// 创建关闭对话框 Intent。
  const DismissBookshelfDialogIntent();
}

/// 从书籍菜单打开详情。
final class OpenBookshelfBookInfoIntent extends BookshelfIntent {
  /// 创建详情 Intent。
  const OpenBookshelfBookInfoIntent(this.bookUrl);
  /// 书籍 URL。
  final String bookUrl;
}

/// 请求返回。
final class BackFromBookshelfIntent extends BookshelfIntent {
  /// 创建返回 Intent。
  const BackFromBookshelfIntent();
}

/// 请求从书架打开本地书导入页面。
final class OpenBookshelfLocalBookImportIntent extends BookshelfIntent {
  /// 创建本地书导入 Intent。
  const OpenBookshelfLocalBookImportIntent();
}

/// 请求对当前唯一选中的网络书执行整书换源。
final class OpenSelectedBookSourceChangeIntent extends BookshelfIntent {
  /// 创建打开整书换源 Intent。
  const OpenSelectedBookSourceChangeIntent();
}

/// 书架一次性副作用。
sealed class BookshelfEffect {
  /// 限制 Effect 类型。
  const BookshelfEffect();
}

/// 打开 M8 阅读器边界。
final class OpenBookshelfReaderEffect extends BookshelfEffect {
  /// 创建阅读导航 Effect。
  const OpenBookshelfReaderEffect(this.book);
  /// 阅读器所需完整书籍上下文。
  final Book book;
}

/// 打开书籍详情。
final class OpenBookshelfBookInfoEffect extends BookshelfEffect {
  /// 创建详情导航 Effect。
  const OpenBookshelfBookInfoEffect(this.book);
  /// 详情所需书籍。
  final Book book;
}

/// 展示一次性书架提示。
final class ShowBookshelfMessageEffect extends BookshelfEffect {
  /// 创建提示 Effect。
  const ShowBookshelfMessageEffect(this.message);
  /// 提示文本。
  final String message;
}

/// 关闭书架页面。
final class CloseBookshelfEffect extends BookshelfEffect {
  /// 创建关闭 Effect。
  const CloseBookshelfEffect();
}

/// 请求路由层打开本地书导入页面。
final class OpenBookshelfLocalBookImportEffect extends BookshelfEffect {
  /// 创建本地书导入导航 Effect。
  const OpenBookshelfLocalBookImportEffect();
}

/// 请求路由层打开指定书籍的 M11 整书换源页面。
final class OpenBookshelfChangeSourceEffect extends BookshelfEffect {
  /// 创建整书换源导航 Effect。
  const OpenBookshelfChangeSourceEffect(this.book);

  /// 需要重新确认数据库事实的当前书籍。
  final Book book;
}
