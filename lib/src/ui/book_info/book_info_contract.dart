import '../../domain/model/book.dart';
import '../../domain/model/book_chapter.dart';
import '../../domain/model/book_group.dart';
import '../../domain/model/book_search.dart';
import '../../domain/model/search_book.dart';

/// 保存同名同作者书架冲突及冲突解决后需要继续的阅读入口。
final class BookInfoShelfConflictDialog {
  /// 创建不可变书架冲突对话框状态。
  BookInfoShelfConflictDialog({
    required this.existingBook,
    required this.incomingBook,
    required List<BookChapter> incomingChapters,
    this.pendingChapterIndex,
  }) : incomingChapters = List<BookChapter>.unmodifiable(incomingChapters);

  /// 当前书架中已经存在的同名同作者书籍。
  final Book existingBook;

  /// 用户正在尝试加入的新书源书籍。
  final Book incomingBook;

  /// 新书源已经加载完成的完整目录。
  final List<BookChapter> incomingChapters;

  /// 冲突解决后需要继续打开的章节；普通加入动作时为空。
  final int? pendingChapterIndex;
}

/// 书籍详情路由参数，保留搜索阶段发现的全部可换来源。
final class BookInfoRouteArguments {
  /// 创建详情路由参数。
  const BookInfoRouteArguments({
    required this.group,
    required this.selectedBook,
    this.initialMessage,
  });
  /// 同名作者候选来源组。
  final BookSearchResultGroup group;
  /// 初始选择来源。
  final SearchBook selectedBook;

  /// 路由替换后由新详情页展示的一次性提示。
  final String? initialMessage;
}

/// 详情、目录、书架和换源入口的不可变页面状态。
final class BookInfoUiState {
  /// 创建详情状态。
  BookInfoUiState({
    required this.group,
    required this.selectedBook,
    this.loadingInfo = true,
    this.loadingToc = false,
    this.switchingSource = false,
    this.addingToShelf = false,
    this.inBookshelf = false,
    this.book,
    List<BookChapter> chapters = const <BookChapter>[],
    List<BookGroup> groups = const <BookGroup>[],
    this.shelfConflict,
    this.dialog,
    this.infoError,
    this.tocError,
  }) : chapters = List<BookChapter>.unmodifiable(chapters),
       groups = List<BookGroup>.unmodifiable(groups);

  /// 可供基础换源的候选组。
  final BookSearchResultGroup group;
  /// 当前来源候选。
  final SearchBook selectedBook;
  /// 是否加载详情。
  final bool loadingInfo;
  /// 是否加载目录。
  final bool loadingToc;
  /// 是否正在切换到另一个候选来源；切换时保留旧数据可见，只在换源入口局部展示加载态。
  final bool switchingSource;
  /// 是否执行加入书架事务。
  final bool addingToShelf;
  /// 当前书籍是否已在书架。
  final bool inBookshelf;
  /// 已解析并合并的书籍。
  final Book? book;
  /// 完整目录。
  final List<BookChapter> chapters;
  /// 当前可用于详情页分组选择的用户分组。
  final List<BookGroup> groups;
  /// 当前待用户确认的同名同作者书架冲突。
  final BookInfoShelfConflictDialog? shelfConflict;
  /// 当前详情页内展示的确认或编辑对话框。
  final BookInfoDialog? dialog;
  /// 详情错误摘要。
  final String? infoError;
  /// 目录错误摘要。
  final String? tocError;

  /// 复制详情状态。
  BookInfoUiState copyWith({
    SearchBook? selectedBook,
    bool? loadingInfo,
    bool? loadingToc,
    bool? switchingSource,
    bool? addingToShelf,
    bool? inBookshelf,
    Book? book,
    List<BookChapter>? chapters,
    List<BookGroup>? groups,
    BookInfoShelfConflictDialog? shelfConflict,
    BookInfoDialog? dialog,
    String? infoError,
    String? tocError,
    bool clearInfoError = false,
    bool clearTocError = false,
    bool clearBook = false,
    bool clearShelfConflict = false,
    bool clearDialog = false,
  }) {
    return BookInfoUiState(
      group: group,
      selectedBook: selectedBook ?? this.selectedBook,
      loadingInfo: loadingInfo ?? this.loadingInfo,
      loadingToc: loadingToc ?? this.loadingToc,
      switchingSource: switchingSource ?? this.switchingSource,
      addingToShelf: addingToShelf ?? this.addingToShelf,
      inBookshelf: inBookshelf ?? this.inBookshelf,
      book: clearBook ? null : book ?? this.book,
      chapters: chapters ?? this.chapters,
      groups: groups ?? this.groups,
      shelfConflict: clearShelfConflict ? null : shelfConflict ?? this.shelfConflict,
      dialog: clearDialog ? null : dialog ?? this.dialog,
      infoError: clearInfoError ? null : infoError ?? this.infoError,
      tocError: clearTocError ? null : tocError ?? this.tocError,
    );
  }
}

/// 详情页内可由 Screen 渲染的对话框状态。
sealed class BookInfoDialog {
  /// 限制详情页 Dialog 类型。
  const BookInfoDialog();
}

/// 删除书籍确认对话框，对应 Android `BookInfoDialog.DeleteBook` 的 Flutter P1 版本。
final class DeleteBookInfoDialog extends BookInfoDialog {
  /// 创建删除确认对话框。
  const DeleteBookInfoDialog(this.book);

  /// 待从 Flutter 独立书架删除的书籍。
  final Book book;
}

/// 编辑备注对话框，对应 Android `BookInfoDialog.EditRemark` 的 Flutter P1 版本。
final class EditBookInfoRemarkDialog extends BookInfoDialog {
  /// 创建备注编辑对话框。
  const EditBookInfoRemarkDialog(this.initialRemark);

  /// 当前备注初始值，允许为空字符串。
  final String initialRemark;
}

/// 封面预览对话框，对应 Android `PhotoPreview` 的 Flutter P2 轻量版本。
final class PreviewBookCoverDialog extends BookInfoDialog {
  /// 创建封面预览对话框。
  const PreviewBookCoverDialog({required this.coverUrl, required this.title});

  /// 需要预览的封面地址，允许网络 URL 或本地文件路径。
  final String coverUrl;

  /// 对话框标题，通常为书名。
  final String title;
}

/// 详情页更多菜单动作，对应 Android `BookInfoMenuAction` 的 Flutter 子集。
enum BookInfoMenuAction {
  /// 重新加载详情和目录。
  refresh,

  /// 分享当前书籍基础信息。
  share,

  /// 复制当前书籍 URL。
  copyBookUrl,

  /// 复制当前目录 URL。
  copyTocUrl,

  /// 编辑当前书籍备注。
  editRemark,

  /// 预览当前封面。
  previewCover,

  /// 打开换封面入口；真实换封面依赖后续封面协调器。
  changeCover,

  /// 打开书架分组选择。
  groupSelect,

  /// 切换书架刷新时是否允许更新。
  toggleCanUpdate,

  /// 删除或移除当前书籍。
  deleteBook,

  /// 打开已入架网络书的整书换源页。
  fullSourceChange,

  /// 阅读记录占位入口。
  readRecord,

  /// 打开 P2/P3 后续能力面板。
  featureMatrix,
}

/// 详情页用户操作统一入口。
sealed class BookInfoIntent {
  /// 限制 Intent 类型。
  const BookInfoIntent();
}

/// 重试详情。
final class RetryBookInfoIntent extends BookInfoIntent {
  /// 创建重试详情 Intent。
  const RetryBookInfoIntent();
}

/// 重试完整目录。
final class RetryBookTocIntent extends BookInfoIntent {
  /// 创建重试目录 Intent。
  const RetryBookTocIntent();
}

/// 将详情和当前完整目录加入书架。
final class AddBookToShelfIntent extends BookInfoIntent {
  /// 创建加入书架 Intent。
  const AddBookToShelfIntent();
}

/// 执行详情页更多菜单动作。
final class BookInfoMenuActionIntent extends BookInfoIntent {
  /// 创建菜单动作 Intent。
  const BookInfoMenuActionIntent(this.action);

  /// 用户选择的菜单动作。
  final BookInfoMenuAction action;
}

/// 关闭详情页当前普通对话框。
final class DismissBookInfoDialogIntent extends BookInfoIntent {
  /// 创建关闭普通对话框 Intent。
  const DismissBookInfoDialogIntent();
}

/// 确认删除或移除当前书籍。
final class ConfirmDeleteBookInfoIntent extends BookInfoIntent {
  /// 创建确认删除 Intent。
  const ConfirmDeleteBookInfoIntent();
}

/// 保存新的书籍备注。
final class UpdateBookInfoRemarkIntent extends BookInfoIntent {
  /// 创建保存备注 Intent。
  const UpdateBookInfoRemarkIntent(this.remark);

  /// 用户输入的新备注文本。
  final String remark;
}

/// 请求预览当前书籍封面。
final class PreviewBookInfoCoverIntent extends BookInfoIntent {
  /// 创建封面预览 Intent。
  const PreviewBookInfoCoverIntent();
}

/// 把当前书籍移动到指定用户分组位值。
final class UpdateBookInfoGroupIntent extends BookInfoIntent {
  /// 创建分组更新 Intent。
  const UpdateBookInfoGroupIntent(this.groupId);

  /// 目标分组位值；0 表示清除用户分组。
  final int groupId;
}

/// 创建新分组并把当前书籍移动到该分组。
final class CreateBookInfoGroupIntent extends BookInfoIntent {
  /// 创建新分组并移动书籍 Intent。
  const CreateBookInfoGroupIntent(this.name);

  /// 用户输入的新分组名称。
  final String name;
}

/// 切换当前书籍是否允许书架刷新更新。
final class ToggleBookInfoCanUpdateIntent extends BookInfoIntent {
  /// 创建允许更新切换 Intent。
  const ToggleBookInfoCanUpdateIntent();
}

/// 确认用新书源替换现有同名书并保留用户阅读事实。
final class ReplaceBookInfoShelfConflictIntent extends BookInfoIntent {
  /// 创建替换现有书源 Intent。
  const ReplaceBookInfoShelfConflictIntent();
}

/// 确认保留现有书籍并把新来源明确新增为第二本书。
final class AddBookInfoShelfConflictAsNewIntent extends BookInfoIntent {
  /// 创建明确新增副本 Intent。
  const AddBookInfoShelfConflictAsNewIntent();
}

/// 关闭同名同作者冲突提示且不执行任何写入。
final class DismissBookInfoShelfConflictIntent extends BookInfoIntent {
  /// 创建关闭冲突提示 Intent。
  const DismissBookInfoShelfConflictIntent();
}

/// 从详情目录打开指定章节阅读。
final class OpenBookInfoChapterIntent extends BookInfoIntent {
  /// 创建打开目录章节 Intent。
  const OpenBookInfoChapterIntent(this.chapterIndex);

  /// 用户点击的目录章节索引。
  final int chapterIndex;
}

/// 切换到搜索阶段发现的另一个来源。
final class ChangeBookInfoSourceIntent extends BookInfoIntent {
  /// 创建换源 Intent。
  const ChangeBookInfoSourceIntent(this.book);
  /// 新来源搜索结果。
  final SearchBook book;
}

/// 对已在书架中的网络书打开独立整书换源页面。
final class OpenBookInfoFullSourceChangeIntent extends BookInfoIntent {
  /// 创建打开整书换源 Intent。
  const OpenBookInfoFullSourceChangeIntent();
}

/// 返回上一页。
final class BackFromBookInfoIntent extends BookInfoIntent {
  /// 创建返回 Intent。
  const BackFromBookInfoIntent();
}

/// 详情页一次性副作用。
sealed class BookInfoEffect {
  /// 限制 Effect 类型。
  const BookInfoEffect();
}

/// 展示详情提示。
final class ShowBookInfoMessageEffect extends BookInfoEffect {
  /// 创建提示 Effect。
  const ShowBookInfoMessageEffect(this.message);
  /// 提示文本。
  final String message;
}

/// 请求返回搜索页。
final class CloseBookInfoEffect extends BookInfoEffect {
  /// 创建返回 Effect。
  const CloseBookInfoEffect();
}

/// 请求进入阅读器并定位到指定章节。
final class OpenBookInfoReaderEffect extends BookInfoEffect {
  /// 创建打开阅读器 Effect。
  const OpenBookInfoReaderEffect({required this.bookUrl, required this.chapterIndex});

  /// 已持久化书籍的稳定 URL。
  final String bookUrl;

  /// 阅读器初始化时应优先打开的章节索引。
  final int chapterIndex;
}

/// 请求路由层打开当前书架书籍的 M11 整书换源页面。
final class OpenBookInfoFullSourceChangeEffect extends BookInfoEffect {
  /// 创建整书换源导航 Effect。
  const OpenBookInfoFullSourceChangeEffect(this.bookUrl);

  /// 当前书架书籍的稳定 URL。
  final String bookUrl;
}

/// 请求路由层复制文本到系统剪贴板。
final class CopyBookInfoTextEffect extends BookInfoEffect {
  /// 创建复制文本 Effect。
  const CopyBookInfoTextEffect({required this.text, required this.message});

  /// 将写入系统剪贴板的文本。
  final String text;

  /// 复制成功后展示的提示。
  final String message;
}

/// 请求路由层打开系统分享面板。
final class ShareBookInfoEffect extends BookInfoEffect {
  /// 创建分享书籍信息 Effect。
  const ShareBookInfoEffect({required this.title, required this.text});

  /// 分享面板标题或主题。
  final String title;

  /// 分享出去的书籍基础信息。
  final String text;
}
