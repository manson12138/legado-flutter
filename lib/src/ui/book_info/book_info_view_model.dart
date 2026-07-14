import 'dart:async';

import '../../api/http/http_contract.dart';
import '../../domain/gateway/bookshelf_gateway.dart';
import '../../domain/model/book.dart';
import '../../domain/model/book_chapter.dart';
import '../../domain/model/search_book.dart';
import '../../domain/usecase/add_book_to_bookshelf_use_case.dart';
import '../../domain/usecase/save_book_chapters_use_case.dart';
import '../../help/error/app_result.dart';
import '../../model/web_book/book_detail_service.dart';
import 'book_info_contract.dart';

/// 创建详情请求取消令牌的函数类型。
typedef BookInfoCancellationTokenFactory = HttpCancellationToken Function();

/// 管理详情、目录、加入书架和基础换源的 MVI ViewModel。
final class BookInfoViewModel {
  /// 创建详情 ViewModel 并自动加载详情与完整目录。
  BookInfoViewModel({
    required BookInfoRouteArguments arguments,
    required BookDetailService detailService,
    required BookshelfGateway bookshelfGateway,
    required AddBookToBookshelfUseCase addBookToBookshelf,
    required SaveBookChaptersUseCase saveBookChapters,
    required BookInfoCancellationTokenFactory cancellationTokenFactory,
  }) : _detailService = detailService,
       _bookshelfGateway = bookshelfGateway,
       _addBookToBookshelf = addBookToBookshelf,
       _saveBookChapters = saveBookChapters,
       _cancellationTokenFactory = cancellationTokenFactory,
       _state = BookInfoUiState(group: arguments.group, selectedBook: arguments.selectedBook) {
    _loadDetails();
  }

  /// 详情和目录业务服务。
  final BookDetailService _detailService;
  /// 书架查询边界。
  final BookshelfGateway _bookshelfGateway;
  /// 加入书架事务 UseCase。
  final AddBookToBookshelfUseCase _addBookToBookshelf;
  /// 已在书架时替换目录的 UseCase。
  final SaveBookChaptersUseCase _saveBookChapters;
  /// 网络取消令牌工厂。
  final BookInfoCancellationTokenFactory _cancellationTokenFactory;
  /// 当前详情状态。
  BookInfoUiState _state;
  /// 状态广播流。
  final StreamController<BookInfoUiState> _stateController = StreamController<BookInfoUiState>.broadcast();
  /// Effect 广播流。
  final StreamController<BookInfoEffect> _effectController = StreamController<BookInfoEffect>.broadcast();
  /// 当前详情和目录共享快照。
  BookDetailSnapshot? _snapshot;
  /// 当前网络令牌。
  HttpCancellationToken? _token;
  /// 请求世代，换源和销毁后拒绝旧结果。
  int _generation = 0;

  /// 当前状态。
  BookInfoUiState get state => _state;
  /// 后续状态流。
  Stream<BookInfoUiState> get states => _stateController.stream;
  /// 一次性 Effect 流。
  Stream<BookInfoEffect> get effects => _effectController.stream;

  /// 详情页面所有操作的唯一入口。
  void onIntent(BookInfoIntent intent) {
    switch (intent) {
      case RetryBookInfoIntent():
        _loadDetails();
      case RetryBookTocIntent():
        _loadToc();
      case AddBookToShelfIntent():
        _addToShelf();
      case ChangeBookInfoSourceIntent(book: final SearchBook book):
        _changeSource(book);
      case BackFromBookInfoIntent():
        _effectController.add(const CloseBookInfoEffect());
    }
  }

  /// 加载当前来源详情，成功后继续加载完整目录。
  Future<void> _loadDetails() async {
    _cancelRequest();
    _generation += 1;
    /// 本次详情请求世代。
    final int generation = _generation;
    /// 本次详情取消令牌。
    final HttpCancellationToken token = _cancellationTokenFactory();
    _token = token;
    _emit(_state.copyWith(loadingInfo: true, loadingToc: false, clearBook: true, chapters: const <BookChapter>[], clearInfoError: true, clearTocError: true));
    try {
      /// 当前来源解析快照。
      final BookDetailSnapshot snapshot = await _detailService.loadDetails(
        searchBook: _state.selectedBook,
        cancellationToken: token,
      );
      if (generation != _generation) {
        return;
      }
      _snapshot = snapshot;
      /// 数据库中同 URL 书籍。
      final Book? storedBook = await _bookshelfGateway.getBook(snapshot.book.bookUrl);
      _emit(_state.copyWith(loadingInfo: false, book: snapshot.book, inBookshelf: storedBook != null));
      await _loadToc(expectedGeneration: generation);
    } catch (error) {
      if (generation == _generation) {
        _emit(_state.copyWith(loadingInfo: false, infoError: _message(error, '详情加载失败')));
      }
    }
  }

  /// 加载分页完整目录，并在书已存在时原子替换持久化目录。
  Future<void> _loadToc({int? expectedGeneration}) async {
    /// 当前详情快照。
    final BookDetailSnapshot? snapshot = _snapshot;
    if (snapshot == null) {
      return;
    }
    /// 沿用详情世代或使用当前世代。
    final int generation = expectedGeneration ?? _generation;
    /// 目录请求使用的新取消令牌。
    final HttpCancellationToken token = _cancellationTokenFactory();
    _token = token;
    _emit(_state.copyWith(loadingToc: true, clearTocError: true));
    try {
      /// 完整目录。
      final List<BookChapter> chapters = await _detailService.loadToc(snapshot: snapshot, cancellationToken: token);
      if (generation != _generation) {
        return;
      }
      /// 带目录统计的书籍。
      final Book updatedBook = _detailService.withChapterSummary(snapshot.book, chapters);
      _snapshot = BookDetailSnapshot(source: snapshot.source, book: updatedBook);
      if (_state.inBookshelf) {
        /// 已在书架时的目录持久化结果。
        final AppResult<void> saveResult = await _saveBookChapters.execute(
          updatedBook.bookUrl,
          chapters,
        );
        if (saveResult case AppFailure<void>(error: final error)) {
          throw BookDetailException(error.message);
        }
      }
      _emit(_state.copyWith(loadingToc: false, book: updatedBook, chapters: chapters));
    } catch (error) {
      if (generation == _generation) {
        _emit(_state.copyWith(loadingToc: false, tocError: _message(error, '目录加载失败')));
      }
    }
  }

  /// 通过事务 UseCase 同时写入书籍和当前完整目录。
  Future<void> _addToShelf() async {
    /// 当前已解析书籍。
    final Book? book = _state.book;
    if (book == null || _state.loadingToc || _state.tocError != null || _state.chapters.isEmpty) {
      _effectController.add(const ShowBookInfoMessageEffect('请等待详情和目录加载完成'));
      return;
    }
    _emit(_state.copyWith(addingToShelf: true));
    /// 加入书架结果。
    final AppResult<void> result = await _addBookToBookshelf.execute(book, _state.chapters);
    switch (result) {
      case AppSuccess<void>():
        _emit(_state.copyWith(addingToShelf: false, inBookshelf: true));
        _effectController.add(const ShowBookInfoMessageEffect('已加入书架'));
      case AppFailure<void>(error: final error):
        _emit(_state.copyWith(addingToShelf: false));
        _effectController.add(ShowBookInfoMessageEffect(error.message));
    }
  }

  /// 切换到搜索阶段已发现的候选来源并重新解析详情目录。
  void _changeSource(SearchBook book) {
    if (book.origin == _state.selectedBook.origin && book.bookUrl == _state.selectedBook.bookUrl) {
      return;
    }
    _snapshot = null;
    _emit(_state.copyWith(selectedBook: book, inBookshelf: false));
    _loadDetails();
  }

  /// 将异常转换为不泄漏响应内容的提示。
  String _message(Object error, String fallback) {
    return error is BookDetailException ? error.message : fallback;
  }

  /// 取消当前详情或目录请求。
  void _cancelRequest() {
    _token?.cancel('详情页面请求已替换');
    _token = null;
  }

  /// 发布新状态。
  void _emit(BookInfoUiState state) {
    _state = state;
    if (!_stateController.isClosed) {
      _stateController.add(state);
    }
  }

  /// 取消请求并释放流。
  void dispose() {
    _generation += 1;
    _cancelRequest();
    _stateController.close();
    _effectController.close();
  }
}
