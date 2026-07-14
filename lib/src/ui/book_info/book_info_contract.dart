import '../../domain/model/book.dart';
import '../../domain/model/book_chapter.dart';
import '../../domain/model/book_search.dart';
import '../../domain/model/search_book.dart';

/// 书籍详情路由参数，保留搜索阶段发现的全部可换来源。
final class BookInfoRouteArguments {
  /// 创建详情路由参数。
  const BookInfoRouteArguments({required this.group, required this.selectedBook});
  /// 同名作者候选来源组。
  final BookSearchResultGroup group;
  /// 初始选择来源。
  final SearchBook selectedBook;
}

/// 详情、目录、书架和换源入口的不可变页面状态。
final class BookInfoUiState {
  /// 创建详情状态。
  BookInfoUiState({
    required this.group,
    required this.selectedBook,
    this.loadingInfo = true,
    this.loadingToc = false,
    this.addingToShelf = false,
    this.inBookshelf = false,
    this.book,
    List<BookChapter> chapters = const <BookChapter>[],
    this.infoError,
    this.tocError,
  }) : chapters = List<BookChapter>.unmodifiable(chapters);

  /// 可供基础换源的候选组。
  final BookSearchResultGroup group;
  /// 当前来源候选。
  final SearchBook selectedBook;
  /// 是否加载详情。
  final bool loadingInfo;
  /// 是否加载目录。
  final bool loadingToc;
  /// 是否执行加入书架事务。
  final bool addingToShelf;
  /// 当前书籍是否已在书架。
  final bool inBookshelf;
  /// 已解析并合并的书籍。
  final Book? book;
  /// 完整目录。
  final List<BookChapter> chapters;
  /// 详情错误摘要。
  final String? infoError;
  /// 目录错误摘要。
  final String? tocError;

  /// 复制详情状态。
  BookInfoUiState copyWith({
    SearchBook? selectedBook,
    bool? loadingInfo,
    bool? loadingToc,
    bool? addingToShelf,
    bool? inBookshelf,
    Book? book,
    List<BookChapter>? chapters,
    String? infoError,
    String? tocError,
    bool clearInfoError = false,
    bool clearTocError = false,
    bool clearBook = false,
  }) {
    return BookInfoUiState(
      group: group,
      selectedBook: selectedBook ?? this.selectedBook,
      loadingInfo: loadingInfo ?? this.loadingInfo,
      loadingToc: loadingToc ?? this.loadingToc,
      addingToShelf: addingToShelf ?? this.addingToShelf,
      inBookshelf: inBookshelf ?? this.inBookshelf,
      book: clearBook ? null : book ?? this.book,
      chapters: chapters ?? this.chapters,
      infoError: clearInfoError ? null : infoError ?? this.infoError,
      tocError: clearTocError ? null : tocError ?? this.tocError,
    );
  }
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

/// 切换到搜索阶段发现的另一个来源。
final class ChangeBookInfoSourceIntent extends BookInfoIntent {
  /// 创建换源 Intent。
  const ChangeBookInfoSourceIntent(this.book);
  /// 新来源搜索结果。
  final SearchBook book;
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
