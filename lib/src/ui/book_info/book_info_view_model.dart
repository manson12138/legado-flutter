import 'dart:async';

import '../../api/http/http_contract.dart';
import '../../domain/gateway/bookshelf_gateway.dart';
import '../../domain/model/book.dart';
import '../../domain/model/book_chapter.dart';
import '../../domain/model/search_book.dart';
import '../../domain/usecase/add_book_to_bookshelf_use_case.dart';
import '../../domain/usecase/save_book_chapters_use_case.dart';
import '../../help/error/app_result.dart';
import '../../help/logging/app_logger.dart';
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
    required AppLogger logger,
  }) : _detailService = detailService,
       _bookshelfGateway = bookshelfGateway,
       _addBookToBookshelf = addBookToBookshelf,
       _saveBookChapters = saveBookChapters,
       _cancellationTokenFactory = cancellationTokenFactory,
       _logger = logger,
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
  /// 【搜书诊断日志】项目统一日志接口，用于记录详情页 MVI 和持久化阶段。
  final AppLogger _logger;
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
  /// 是否正在为目录进入阅读器执行持久化，防止重复点击产生并发写入。
  bool _openingReader = false;

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
        _logger.info(tag: bookDetailLogTag, message: '用户重试详情');
        _loadDetails();
      case RetryBookTocIntent():
        _logger.info(tag: bookTocLogTag, message: '用户重试目录');
        _loadToc();
      case AddBookToShelfIntent():
        _logger.info(tag: bookDetailLogTag, message: '用户点击加入书架');
        _addToShelf();
      case OpenBookInfoChapterIntent(chapterIndex: final int chapterIndex):
        _logger.info(tag: bookDetailLogTag, message: '用户从详情目录打开章节 chapterIndex=$chapterIndex');
        _openChapterInReader(chapterIndex);
      case ChangeBookInfoSourceIntent(book: final SearchBook book):
        _changeSource(book);
      case BackFromBookInfoIntent():
        _logger.info(tag: bookDetailLogTag, message: '用户从详情页返回');
        _effectController.add(const CloseBookInfoEffect());
    }
  }

  /// 加载当前来源详情，成功后继续加载完整目录。
  Future<void> _loadDetails() async {
    _cancelRequest();
    _generation += 1;
    /// 本次详情请求世代。
    final int generation = _generation;
    /// 【搜书诊断日志】当前详情候选不可逆标识。
    final String bookId = appLogDiagnosticId(_state.selectedBook.bookUrl);
    /// 【搜书诊断日志】详情 ViewModel 阶段耗时计时器。
    final Stopwatch stopwatch = Stopwatch()..start();
    _logger.info(
      tag: bookDetailLogTag,
      message: '详情页加载开始 generation=$generation bookId=$bookId '
          'sourceId=${appLogDiagnosticId(_state.selectedBook.origin)}',
    );
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
        _logger.debug(
          tag: bookDetailLogTag,
          message: '忽略旧详情结果 generation=$generation currentGeneration=$_generation bookId=$bookId',
        );
        return;
      }
      _snapshot = snapshot;
      /// 数据库中同 URL 书籍。
      final Book? storedBook = await _bookshelfGateway.getBook(snapshot.book.bookUrl);
      _emit(_state.copyWith(loadingInfo: false, book: snapshot.book, inBookshelf: storedBook != null));
      _logger.info(
        tag: bookDetailLogTag,
        message: '详情页字段加载完成 generation=$generation bookId=$bookId '
            'inBookshelf=${storedBook != null} elapsedMs=${stopwatch.elapsedMilliseconds}',
      );
      await _loadToc(expectedGeneration: generation);
    } catch (error, stackTrace) {
      if (generation == _generation) {
        _logger.error(
          tag: bookDetailLogTag,
          message: '详情页加载失败 generation=$generation bookId=$bookId '
              'elapsedMs=${stopwatch.elapsedMilliseconds}',
          error: error,
          stackTrace: stackTrace,
        );
        _emit(_state.copyWith(loadingInfo: false, infoError: _message(error, '详情加载失败')));
      }
    }
  }

  /// 加载分页完整目录，并在书已存在时原子替换持久化目录。
  Future<void> _loadToc({int? expectedGeneration}) async {
    /// 当前详情快照。
    final BookDetailSnapshot? snapshot = _snapshot;
    if (snapshot == null) {
      _logger.warning(tag: bookTocLogTag, message: '目录加载被拒绝 reason=missingDetailSnapshot');
      return;
    }
    /// 沿用详情世代或使用当前世代。
    final int generation = expectedGeneration ?? _generation;
    /// 【搜书诊断日志】目录对应书籍不可逆标识。
    final String bookId = appLogDiagnosticId(snapshot.book.bookUrl);
    /// 【搜书诊断日志】目录 ViewModel 阶段耗时计时器。
    final Stopwatch stopwatch = Stopwatch()..start();
    _logger.info(
      tag: bookTocLogTag,
      message: '详情页目录加载开始 generation=$generation bookId=$bookId',
    );
    /// 目录请求使用的新取消令牌。
    final HttpCancellationToken token = _cancellationTokenFactory();
    _token = token;
    _emit(_state.copyWith(loadingToc: true, clearTocError: true));
    try {
      /// 完整目录。
      final List<BookChapter> chapters = await _detailService.loadToc(snapshot: snapshot, cancellationToken: token);
      if (generation != _generation) {
        _logger.debug(
          tag: bookTocLogTag,
          message: '忽略旧目录结果 generation=$generation currentGeneration=$_generation bookId=$bookId',
        );
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
        /// 【搜书诊断日志】书架已有书籍时，详情页刷新目录已经持久化。
        _logger.info(
          tag: bookTocLogTag,
          message: '详情页目录持久化完成 bookId=$bookId chapterCount=${chapters.length}',
        );
      }
      _emit(_state.copyWith(loadingToc: false, book: updatedBook, chapters: chapters));
      _logger.info(
        tag: bookTocLogTag,
        message: '详情页目录加载完成 generation=$generation bookId=$bookId '
            'chapterCount=${chapters.length} elapsedMs=${stopwatch.elapsedMilliseconds}',
      );
    } catch (error, stackTrace) {
      if (generation == _generation) {
        _logger.error(
          tag: bookTocLogTag,
          message: '详情页目录加载失败 generation=$generation bookId=$bookId '
              'elapsedMs=${stopwatch.elapsedMilliseconds}',
          error: error,
          stackTrace: stackTrace,
        );
        _emit(_state.copyWith(loadingToc: false, tocError: _message(error, '目录加载失败')));
      }
    }
  }

  /// 确保当前书籍和目录已经持久化，然后请求路由进入阅读器指定章节。
  Future<void> _openChapterInReader(int chapterIndex) async {
    if (_openingReader) {
      _logger.debug(tag: bookDetailLogTag, message: '忽略重复目录阅读入口 chapterIndex=$chapterIndex');
      return;
    }
    /// 当前已解析书籍。
    final Book? book = _state.book;
    if (book == null || _state.loadingToc || _state.tocError != null || _state.chapters.isEmpty) {
      _logger.warning(
        tag: bookDetailLogTag,
        message: '目录阅读入口被拒绝 hasBook=${book != null} loadingToc=${_state.loadingToc} '
            'hasTocError=${_state.tocError != null} chapterCount=${_state.chapters.length}',
      );
      _effectController.add(const ShowBookInfoMessageEffect('请等待详情和目录加载完成'));
      return;
    }
    if (chapterIndex < 0 || chapterIndex >= _state.chapters.length) {
      _logger.warning(
        tag: bookDetailLogTag,
        message: '目录阅读入口被拒绝 reason=chapterIndexOutOfRange '
            'chapterIndex=$chapterIndex chapterCount=${_state.chapters.length}',
      );
      _effectController.add(const ShowBookInfoMessageEffect('章节位置无效'));
      return;
    }
    /// 用户点击的章节。
    final BookChapter chapter = _state.chapters[chapterIndex];
    if (chapter.isVolume) {
      _logger.debug(tag: bookDetailLogTag, message: '忽略卷标题阅读入口 chapterIndex=$chapterIndex');
      return;
    }
    _openingReader = true;
    /// 目录阅读入口对应书籍不可逆标识。
    final String bookId = appLogDiagnosticId(book.bookUrl);
    try {
      if (!_state.inBookshelf) {
        _emit(_state.copyWith(addingToShelf: true));
        _logger.info(
          tag: bookDetailLogTag,
          message: '目录阅读入口写入书架开始 bookId=$bookId chapterCount=${_state.chapters.length}',
        );
        /// 非书架书进入阅读器前必须写入书籍和章节，阅读器统一从本地读取。
        final AppResult<void> result = await _addBookToBookshelf.execute(book, _state.chapters);
        switch (result) {
          case AppSuccess<void>():
            _logger.info(
              tag: bookDetailLogTag,
              message: '目录阅读入口写入书架成功 bookId=$bookId chapterIndex=$chapterIndex',
            );
            _emit(_state.copyWith(addingToShelf: false, inBookshelf: true));
          case AppFailure<void>(error: final error):
            _logger.error(
              tag: bookDetailLogTag,
              message: '目录阅读入口写入书架失败 bookId=$bookId',
              error: error,
            );
            _emit(_state.copyWith(addingToShelf: false));
            _effectController.add(ShowBookInfoMessageEffect(error.message));
            return;
        }
      }
      _effectController.add(
        OpenBookInfoReaderEffect(bookUrl: book.bookUrl, chapterIndex: chapterIndex),
      );
    } finally {
      _openingReader = false;
    }
  }

  /// 通过事务 UseCase 同时写入书籍和当前完整目录。
  Future<void> _addToShelf() async {
    /// 当前已解析书籍。
    final Book? book = _state.book;
    if (book == null || _state.loadingToc || _state.tocError != null || _state.chapters.isEmpty) {
      _logger.warning(
        tag: bookDetailLogTag,
        message: '加入书架被拒绝 hasBook=${book != null} loadingToc=${_state.loadingToc} '
            'hasTocError=${_state.tocError != null} chapterCount=${_state.chapters.length}',
      );
      _effectController.add(const ShowBookInfoMessageEffect('请等待详情和目录加载完成'));
      return;
    }
    _emit(_state.copyWith(addingToShelf: true));
    /// 【搜书诊断日志】加入书架对应书籍不可逆标识。
    final String bookId = appLogDiagnosticId(book.bookUrl);
    _logger.info(
      tag: bookDetailLogTag,
      message: '加入书架事务开始 bookId=$bookId chapterCount=${_state.chapters.length}',
    );
    /// 加入书架结果。
    final AppResult<void> result = await _addBookToBookshelf.execute(book, _state.chapters);
    switch (result) {
      case AppSuccess<void>():
        _logger.info(
          tag: bookDetailLogTag,
          message: '加入书架事务成功 bookId=$bookId chapterCount=${_state.chapters.length}',
        );
        _emit(_state.copyWith(addingToShelf: false, inBookshelf: true));
        _effectController.add(const ShowBookInfoMessageEffect('已加入书架'));
      case AppFailure<void>(error: final error):
        _logger.error(
          tag: bookDetailLogTag,
          message: '加入书架事务失败 bookId=$bookId',
          error: error,
        );
        _emit(_state.copyWith(addingToShelf: false));
        _effectController.add(ShowBookInfoMessageEffect(error.message));
    }
  }

  /// 切换到搜索阶段已发现的候选来源并重新解析详情目录。
  void _changeSource(SearchBook book) {
    if (book.origin == _state.selectedBook.origin && book.bookUrl == _state.selectedBook.bookUrl) {
      _logger.debug(tag: bookDetailLogTag, message: '忽略重复详情换源');
      return;
    }
    /// 【搜书诊断日志】记录详情换源前后的不可逆标识。
    _logger.info(
      tag: bookDetailLogTag,
      message: '详情页切换书源 oldSourceId=${appLogDiagnosticId(_state.selectedBook.origin)} '
          'newSourceId=${appLogDiagnosticId(book.origin)} newBookId=${appLogDiagnosticId(book.bookUrl)}',
    );
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
    if (_token != null) {
      /// 【搜书诊断日志】请求被换源、重试或页面销毁替换。
      _logger.debug(tag: bookDetailLogTag, message: '取消当前详情或目录请求 generation=$_generation');
    }
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
    _logger.info(tag: bookDetailLogTag, message: '详情页面释放 generation=$_generation');
    _generation += 1;
    _cancelRequest();
    _stateController.close();
    _effectController.close();
  }
}
