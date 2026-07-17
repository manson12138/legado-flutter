import 'dart:async';

import '../../api/http/http_contract.dart';
import '../../domain/gateway/book_group_gateway.dart';
import '../../domain/gateway/bookshelf_gateway.dart';
import '../../domain/model/add_book_to_bookshelf_result.dart';
import '../../domain/model/book.dart';
import '../../domain/model/book_chapter.dart';
import '../../domain/model/book_group.dart';
import '../../domain/model/search_book.dart';
import '../../domain/usecase/add_book_to_bookshelf_use_case.dart';
import '../../domain/usecase/change_book_source_use_case.dart';
import '../../domain/usecase/create_bookshelf_group_use_case.dart';
import '../../domain/usecase/replace_books_group_use_case.dart';
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
    required BookGroupGateway bookGroupGateway,
    required BookshelfGateway bookshelfGateway,
    required AddBookToBookshelfUseCase addBookToBookshelf,
    required ChangeBookSourceUseCase changeBookSource,
    required CreateBookshelfGroupUseCase createBookshelfGroup,
    required ReplaceBooksGroupUseCase replaceBooksGroup,
    required SaveBookChaptersUseCase saveBookChapters,
    required BookInfoCancellationTokenFactory cancellationTokenFactory,
    required AppLogger logger,
  }) : _detailService = detailService,
       _bookGroupGateway = bookGroupGateway,
       _bookshelfGateway = bookshelfGateway,
       _addBookToBookshelf = addBookToBookshelf,
       _changeBookSource = changeBookSource,
       _createBookshelfGroup = createBookshelfGroup,
       _replaceBooksGroup = replaceBooksGroup,
       _saveBookChapters = saveBookChapters,
       _cancellationTokenFactory = cancellationTokenFactory,
       _logger = logger,
       _state = BookInfoUiState(group: arguments.group, selectedBook: arguments.selectedBook) {
    _groupSubscription = _bookGroupGateway.watchGroups().listen(_handleGroupsChanged, onError: _handleGroupsError);
    _loadDetails();
  }

  /// 详情和目录业务服务。
  final BookDetailService _detailService;
  /// 书架分组查询边界。
  final BookGroupGateway _bookGroupGateway;
  /// 书架查询边界。
  final BookshelfGateway _bookshelfGateway;
  /// 加入书架事务 UseCase。
  final AddBookToBookshelfUseCase _addBookToBookshelf;
  /// 原子替换冲突书籍并迁移阅读事实的 UseCase。
  final ChangeBookSourceUseCase _changeBookSource;
  /// 创建书架分组 UseCase。
  final CreateBookshelfGroupUseCase _createBookshelfGroup;
  /// 替换当前书籍分组 UseCase。
  final ReplaceBooksGroupUseCase _replaceBooksGroup;
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
  /// 用户书架分组订阅。
  late final StreamSubscription<List<BookGroup>> _groupSubscription;
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
      case BookInfoMenuActionIntent(action: final BookInfoMenuAction action):
        _handleMenuAction(action);
      case DismissBookInfoDialogIntent():
        _emit(_state.copyWith(clearDialog: true));
      case ConfirmDeleteBookInfoIntent():
        _deleteCurrentBook();
      case UpdateBookInfoRemarkIntent(remark: final String remark):
        _updateRemark(remark);
      case PreviewBookInfoCoverIntent():
        _previewCover();
      case UpdateBookInfoGroupIntent(groupId: final int groupId):
        _updateGroup(groupId);
      case CreateBookInfoGroupIntent(name: final String name):
        _createGroupAndMove(name);
      case ToggleBookInfoCanUpdateIntent():
        _toggleCanUpdate();
      case ReplaceBookInfoShelfConflictIntent():
        _replaceShelfConflict();
      case AddBookInfoShelfConflictAsNewIntent():
        _addShelfConflictAsNew();
      case DismissBookInfoShelfConflictIntent():
        _emit(_state.copyWith(clearShelfConflict: true, addingToShelf: false));
      case OpenBookInfoChapterIntent(chapterIndex: final int chapterIndex):
        _logger.info(tag: bookDetailLogTag, message: '用户从详情目录打开章节 chapterIndex=$chapterIndex');
        _openChapterInReader(chapterIndex);
      case ChangeBookInfoSourceIntent(book: final SearchBook book):
        _changeSource(book);
      case OpenBookInfoFullSourceChangeIntent():
        _openFullSourceChange();
      case BackFromBookInfoIntent():
        _logger.info(tag: bookDetailLogTag, message: '用户从详情页返回');
        _effectController.add(const CloseBookInfoEffect());
    }
  }

  /// 处理详情页更多菜单动作，对应 Android `BookInfoMenuAction` 的 Flutter P1 子集。
  void _handleMenuAction(BookInfoMenuAction action) {
    switch (action) {
      case BookInfoMenuAction.refresh:
        _logger.info(tag: bookDetailLogTag, message: '用户从菜单刷新详情');
        _loadDetails();
      case BookInfoMenuAction.share:
        _shareCurrentBook();
      case BookInfoMenuAction.copyBookUrl:
        _copyCurrentBookUrl();
      case BookInfoMenuAction.copyTocUrl:
        _copyCurrentTocUrl();
      case BookInfoMenuAction.editRemark:
        _requestEditRemark();
      case BookInfoMenuAction.previewCover:
        _previewCover();
      case BookInfoMenuAction.changeCover:
        _effectController.add(const ShowBookInfoMessageEffect('换封面需要封面搜索和保存能力，已登记到 P2'));
      case BookInfoMenuAction.groupSelect:
        _effectController.add(const ShowBookInfoMessageEffect('请从详情页分组入口选择分组'));
      case BookInfoMenuAction.toggleCanUpdate:
        _toggleCanUpdate();
      case BookInfoMenuAction.deleteBook:
        _requestDeleteBook();
      case BookInfoMenuAction.fullSourceChange:
        _openFullSourceChange();
      case BookInfoMenuAction.readRecord:
        _effectController.add(const ShowBookInfoMessageEffect('阅读记录将在后续批次接入'));
      case BookInfoMenuAction.featureMatrix:
        _effectController.add(const ShowBookInfoMessageEffect('P2/P3 后续能力已在详情页能力面板中说明'));
    }
  }

  /// 同步书架分组列表到详情页状态。
  void _handleGroupsChanged(List<BookGroup> groups) {
    /// 只保留正数用户分组，系统分组不作为详情页写入目标。
    final List<BookGroup> userGroups = groups
        .where((BookGroup group) => group.groupId > 0)
        .toList(growable: false);
    _emit(_state.copyWith(groups: userGroups));
  }

  /// 处理分组流异常，避免页面因为分组辅助能力中断详情闭环。
  void _handleGroupsError(Object error, StackTrace stackTrace) {
    _logger.error(
      tag: bookDetailLogTag,
      message: '详情页分组列表加载失败',
      error: error,
      stackTrace: stackTrace,
    );
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
        /// 非书架书进入阅读器前必须完成冲突感知的加入动作。
        final AppResult<AddBookToBookshelfResult> result =
            await _addBookToBookshelf.execute(book, _state.chapters);
        /// 是否可以在本轮立即继续进入阅读器。
        final bool canOpenReader = _handleAddResult(
          result,
          pendingChapterIndex: chapterIndex,
        );
        if (!canOpenReader) {
          return;
        }
        _logger.info(
          tag: bookDetailLogTag,
          message: '目录阅读入口写入书架成功 bookId=$bookId chapterIndex=$chapterIndex',
        );
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
    final AppResult<AddBookToBookshelfResult> result =
        await _addBookToBookshelf.execute(book, _state.chapters);
    _handleAddResult(result);
  }

  /// 把结构化加入结果转换为页面状态、提示或待确认冲突。
  ///
  /// 返回 true 表示书籍已经可以从本地书架进入阅读器。
  bool _handleAddResult(
    AppResult<AddBookToBookshelfResult> result, {
    int? pendingChapterIndex,
  }) {
    switch (result) {
      case AppFailure<AddBookToBookshelfResult>(error: final error):
        _logger.error(
          tag: bookDetailLogTag,
          message: '加入书架事务失败',
          error: error,
        );
        _emit(_state.copyWith(addingToShelf: false));
        _effectController.add(ShowBookInfoMessageEffect(error.message));
        return false;
      case AppSuccess<AddBookToBookshelfResult>(value: final addResult):
        switch (addResult) {
          case BookAddedToBookshelf():
            _emit(_state.copyWith(addingToShelf: false, inBookshelf: true));
            if (pendingChapterIndex == null) {
              _effectController.add(const ShowBookInfoMessageEffect('已加入书架'));
            }
            return true;
          case BookAlreadyInBookshelf():
            _emit(_state.copyWith(addingToShelf: false, inBookshelf: true));
            if (pendingChapterIndex == null) {
              _effectController.add(const ShowBookInfoMessageEffect('该来源书籍已在书架中'));
            }
            return true;
          case BookShelfConflict(
            existingBook: final Book existingBook,
            incomingBook: final Book incomingBook,
            incomingChapters: final List<BookChapter> incomingChapters,
          ):
            _emit(
              _state.copyWith(
                addingToShelf: false,
                shelfConflict: BookInfoShelfConflictDialog(
                  existingBook: existingBook,
                  incomingBook: incomingBook,
                  incomingChapters: incomingChapters,
                  pendingChapterIndex: pendingChapterIndex,
                ),
              ),
            );
            return false;
        }
    }
  }

  /// 用候选来源替换现有同名书，并按默认策略保留阅读进度和用户配置。
  Future<void> _replaceShelfConflict() async {
    /// 当前待确认冲突；已被关闭时忽略迟到操作。
    final BookInfoShelfConflictDialog? conflict = _state.shelfConflict;
    if (conflict == null || _state.addingToShelf) {
      return;
    }
    _emit(_state.copyWith(addingToShelf: true, clearShelfConflict: true));
    /// 原子换源和用户事实迁移结果。
    final AppResult<ChangeBookSourceResult> result = await _changeBookSource.execute(
      oldBook: conflict.existingBook,
      newBook: conflict.incomingBook,
      chapters: conflict.incomingChapters,
      options: const ChangeSourceMigrationOptions(),
    );
    switch (result) {
      case AppFailure<ChangeBookSourceResult>(error: final error):
        _emit(_state.copyWith(addingToShelf: false));
        _effectController.add(ShowBookInfoMessageEffect(error.message));
      case AppSuccess<ChangeBookSourceResult>(value: final changeResult):
        _emit(
          _state.copyWith(
            addingToShelf: false,
            inBookshelf: true,
            book: changeResult.book,
          ),
        );
        _effectController.add(const ShowBookInfoMessageEffect('已替换书源并保留阅读数据'));
        _continueAfterShelfConflict(conflict, changeResult.book.bookUrl);
    }
  }

  /// 在用户明确确认后把候选来源作为第二本书加入书架。
  Future<void> _addShelfConflictAsNew() async {
    /// 当前待确认冲突；已被关闭时忽略迟到操作。
    final BookInfoShelfConflictDialog? conflict = _state.shelfConflict;
    if (conflict == null || _state.addingToShelf) {
      return;
    }
    _emit(_state.copyWith(addingToShelf: true, clearShelfConflict: true));
    /// 明确绕过同名同作者保护后的新增结果。
    final AppResult<void> result = await _addBookToBookshelf.addAsNew(
      conflict.incomingBook,
      conflict.incomingChapters,
    );
    switch (result) {
      case AppFailure<void>(error: final error):
        _emit(_state.copyWith(addingToShelf: false));
        _effectController.add(ShowBookInfoMessageEffect(error.message));
      case AppSuccess<void>():
        _emit(_state.copyWith(addingToShelf: false, inBookshelf: true));
        _effectController.add(const ShowBookInfoMessageEffect('已作为另一来源加入书架'));
        _continueAfterShelfConflict(conflict, conflict.incomingBook.bookUrl);
    }
  }

  /// 冲突解决后恢复用户原先从目录进入阅读器的动作。
  void _continueAfterShelfConflict(
    BookInfoShelfConflictDialog conflict,
    String bookUrl,
  ) {
    /// 冲突出现前用户选择的章节位置。
    final int? chapterIndex = conflict.pendingChapterIndex;
    if (chapterIndex == null) {
      return;
    }
    _effectController.add(
      OpenBookInfoReaderEffect(bookUrl: bookUrl, chapterIndex: chapterIndex),
    );
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

  /// 对已在书架中的网络书请求独立全书源换源页面。
  void _openFullSourceChange() {
    /// 当前已解析并确认在书架中的书籍。
    final Book? book = _state.book;
    if (!_state.inBookshelf || book == null) {
      _effectController.add(
        const ShowBookInfoMessageEffect('请先把书籍加入书架再执行整书换源'),
      );
      return;
    }
    if (book.origin == 'loc_book') {
      _effectController.add(const ShowBookInfoMessageEffect('本地书不支持整书换源'));
      return;
    }
    _effectController.add(OpenBookInfoFullSourceChangeEffect(book.bookUrl));
  }

  /// 请求路由层分享当前书籍基础信息。
  void _shareCurrentBook() {
    /// 当前已解析书籍。
    final Book? book = _state.book;
    if (book == null) {
      _effectController.add(const ShowBookInfoMessageEffect('详情尚未加载完成'));
      return;
    }
    /// 分享文本，避免包含 Cookie、Header 或正文隐私内容。
    final String text = _bookShareText(book);
    _effectController.add(
      ShareBookInfoEffect(
        title: book.name.isEmpty ? '分享书籍' : '分享《${book.name}》',
        text: text,
      ),
    );
  }

  /// 打开当前封面预览；没有封面时给出明确提示。
  void _previewCover() {
    /// 当前已解析书籍。
    final Book? book = _state.book;
    if (book == null) {
      _effectController.add(const ShowBookInfoMessageEffect('当前书籍没有可预览的封面'));
      return;
    }
    /// 用户自定义封面地址。
    final String customCoverUrl = book.customCoverUrl?.trim() ?? '';
    /// 当前封面地址，优先使用用户自定义封面。
    final String coverUrl = customCoverUrl.isNotEmpty ? customCoverUrl : book.coverUrl?.trim() ?? '';
    if (coverUrl.isEmpty) {
      _effectController.add(const ShowBookInfoMessageEffect('当前书籍没有可预览的封面'));
      return;
    }
    _emit(
      _state.copyWith(
        dialog: PreviewBookCoverDialog(
          coverUrl: coverUrl,
          title: book.name.isEmpty ? '封面预览' : book.name,
        ),
      ),
    );
  }

  /// 请求路由层复制当前书籍 URL。
  void _copyCurrentBookUrl() {
    /// 当前已解析书籍。
    final Book? book = _state.book;
    if (book == null || book.bookUrl.isEmpty) {
      _effectController.add(const ShowBookInfoMessageEffect('当前没有可复制的书籍地址'));
      return;
    }
    _effectController.add(
      CopyBookInfoTextEffect(text: book.bookUrl, message: '已复制书籍地址'),
    );
  }

  /// 请求路由层复制当前目录 URL。
  void _copyCurrentTocUrl() {
    /// 当前已解析书籍。
    final Book? book = _state.book;
    /// 当前可复制的目录地址。
    final String tocUrl = book?.tocUrl.trim() ?? '';
    if (tocUrl.isEmpty) {
      _effectController.add(const ShowBookInfoMessageEffect('当前没有可复制的目录地址'));
      return;
    }
    _effectController.add(
      CopyBookInfoTextEffect(text: tocUrl, message: '已复制目录地址'),
    );
  }

  /// 打开备注编辑对话框。
  void _requestEditRemark() {
    /// 当前已解析书籍。
    final Book? book = _state.book;
    if (book == null || !_state.inBookshelf) {
      _effectController.add(const ShowBookInfoMessageEffect('请先把书籍加入书架再编辑备注'));
      return;
    }
    _emit(_state.copyWith(dialog: EditBookInfoRemarkDialog(book.remark ?? '')));
  }

  /// 打开删除确认对话框。
  void _requestDeleteBook() {
    /// 当前已解析书籍。
    final Book? book = _state.book;
    if (book == null || !_state.inBookshelf) {
      _effectController.add(const ShowBookInfoMessageEffect('当前书籍尚未加入书架'));
      return;
    }
    _emit(_state.copyWith(dialog: DeleteBookInfoDialog(book)));
  }

  /// 从 Flutter 独立书架中删除当前书籍。
  Future<void> _deleteCurrentBook() async {
    /// 当前删除确认对话框。
    final BookInfoDialog? dialog = _state.dialog;
    if (dialog is! DeleteBookInfoDialog) {
      return;
    }
    _emit(_state.copyWith(clearDialog: true));
    try {
      await _bookshelfGateway.deleteBook(dialog.book.bookUrl);
      _emit(_state.copyWith(inBookshelf: false));
      _effectController.add(const ShowBookInfoMessageEffect('已从书架移除'));
      _effectController.add(const CloseBookInfoEffect());
    } catch (error, stackTrace) {
      _logger.error(
        tag: bookDetailLogTag,
        message: '删除详情页书籍失败 bookId=${appLogDiagnosticId(dialog.book.bookUrl)}',
        error: error,
        stackTrace: stackTrace,
      );
      _effectController.add(const ShowBookInfoMessageEffect('移除书籍失败'));
    }
  }

  /// 保存当前书籍备注。
  Future<void> _updateRemark(String remark) async {
    /// 当前已解析书籍。
    final Book? book = _state.book;
    if (book == null || !_state.inBookshelf) {
      _effectController.add(const ShowBookInfoMessageEffect('请先把书籍加入书架再编辑备注'));
      return;
    }
    /// 备注文本，空字符串以 null 保存，保持数据库含义清晰。
    final String normalizedRemark = remark.trim();
    /// 带新备注的书籍副本。
    final Book updatedBook = _copyBookWithRemark(
      book,
      normalizedRemark.isEmpty ? null : normalizedRemark,
    );
    _emit(_state.copyWith(clearDialog: true));
    try {
      await _bookshelfGateway.addBook(updatedBook, const <BookChapter>[]);
      /// 当前详情快照，用于同步后续目录刷新上下文。
      final BookDetailSnapshot? snapshot = _snapshot;
      _snapshot = snapshot == null
          ? null
          : BookDetailSnapshot(source: snapshot.source, book: updatedBook);
      _emit(_state.copyWith(book: updatedBook));
      _effectController.add(const ShowBookInfoMessageEffect('备注已保存'));
    } catch (error, stackTrace) {
      _logger.error(
        tag: bookDetailLogTag,
        message: '保存详情页备注失败 bookId=${appLogDiagnosticId(book.bookUrl)}',
        error: error,
        stackTrace: stackTrace,
      );
      _effectController.add(const ShowBookInfoMessageEffect('保存备注失败'));
    }
  }

  /// 把当前书籍移动到指定分组。
  Future<void> _updateGroup(int groupId) async {
    /// 当前已解析书籍。
    final Book? book = _state.book;
    if (book == null || !_state.inBookshelf) {
      _effectController.add(const ShowBookInfoMessageEffect('请先把书籍加入书架再设置分组'));
      return;
    }
    /// 分组写入事务结果。
    final AppResult<void> result = await _replaceBooksGroup.execute(<String>{book.bookUrl}, groupId);
    switch (result) {
      case AppFailure<void>(error: final error):
        _effectController.add(ShowBookInfoMessageEffect(error.message));
      case AppSuccess<void>():
        /// 更新后的书籍副本。
        final Book updatedBook = _copyBookWithGroup(book, groupId);
        _syncCurrentBook(updatedBook);
        _effectController.add(const ShowBookInfoMessageEffect('分组已更新'));
    }
  }

  /// 创建新分组并把当前书籍移动到新分组。
  Future<void> _createGroupAndMove(String name) async {
    /// 当前已解析书籍。
    final Book? book = _state.book;
    if (book == null || !_state.inBookshelf) {
      _effectController.add(const ShowBookInfoMessageEffect('请先把书籍加入书架再设置分组'));
      return;
    }
    /// 创建分组结果。
    final AppResult<BookGroup> createResult = await _createBookshelfGroup.execute(name);
    switch (createResult) {
      case AppFailure<BookGroup>(error: final error):
        _effectController.add(ShowBookInfoMessageEffect(error.message));
      case AppSuccess<BookGroup>(value: final BookGroup group):
        await _updateGroup(group.groupId);
    }
  }

  /// 切换当前书籍是否允许书架刷新更新。
  Future<void> _toggleCanUpdate() async {
    /// 当前已解析书籍。
    final Book? book = _state.book;
    if (book == null || !_state.inBookshelf) {
      _effectController.add(const ShowBookInfoMessageEffect('请先把书籍加入书架再修改更新开关'));
      return;
    }
    /// 切换允许更新后的书籍副本。
    final Book updatedBook = _copyBookWithCanUpdate(book, !book.canUpdate);
    try {
      await _bookshelfGateway.addBook(updatedBook, const <BookChapter>[]);
      _syncCurrentBook(updatedBook);
      _effectController.add(
        ShowBookInfoMessageEffect(updatedBook.canUpdate ? '已允许书架刷新更新' : '已禁止书架刷新更新'),
      );
    } catch (error, stackTrace) {
      _logger.error(
        tag: bookDetailLogTag,
        message: '切换详情页允许更新失败 bookId=${appLogDiagnosticId(book.bookUrl)}',
        error: error,
        stackTrace: stackTrace,
      );
      _effectController.add(const ShowBookInfoMessageEffect('更新开关保存失败'));
    }
  }

  /// 同步当前书籍状态和详情快照。
  void _syncCurrentBook(Book updatedBook) {
    /// 当前详情快照，用于同步后续目录刷新上下文。
    final BookDetailSnapshot? snapshot = _snapshot;
    _snapshot = snapshot == null
        ? null
        : BookDetailSnapshot(source: snapshot.source, book: updatedBook);
    _emit(_state.copyWith(book: updatedBook));
  }

  /// 生成分享书籍的安全文本。
  String _bookShareText(Book book) {
    /// 作者显示文本。
    final String author = book.author.isEmpty ? '未知作者' : book.author;
    /// 来源显示文本。
    final String originName = book.originName.isEmpty ? '未知来源' : book.originName;
    /// 最新章节显示文本。
    final String latest = book.latestChapterTitle?.trim() ?? '';
    return <String>[
      if (book.name.isNotEmpty) '《${book.name}》',
      '作者：$author',
      '来源：$originName',
      if (latest.isNotEmpty) '最新：$latest',
      if (book.bookUrl.isNotEmpty) '地址：${book.bookUrl}',
    ].join('\n');
  }

  /// 构造只改变备注字段的书籍副本，避免修改其他业务事实。
  Book _copyBookWithRemark(Book book, String? remark) {
    return Book(
      bookUrl: book.bookUrl,
      tocUrl: book.tocUrl,
      origin: book.origin,
      originName: book.originName,
      name: book.name,
      author: book.author,
      kind: book.kind,
      customTag: book.customTag,
      coverUrl: book.coverUrl,
      customCoverUrl: book.customCoverUrl,
      intro: book.intro,
      customIntro: book.customIntro,
      remark: remark,
      charset: book.charset,
      type: book.type,
      group: book.group,
      latestChapterTitle: book.latestChapterTitle,
      latestChapterTime: book.latestChapterTime,
      lastCheckTime: book.lastCheckTime,
      lastCheckCount: book.lastCheckCount,
      totalChapterNum: book.totalChapterNum,
      durChapterTitle: book.durChapterTitle,
      durChapterIndex: book.durChapterIndex,
      durChapterPos: book.durChapterPos,
      durChapterTime: book.durChapterTime,
      wordCount: book.wordCount,
      canUpdate: book.canUpdate,
      order: book.order,
      originOrder: book.originOrder,
      variable: book.variable,
      readConfig: book.readConfig,
      syncTime: book.syncTime,
    );
  }

  /// 构造只改变分组字段的书籍副本，避免修改其他业务事实。
  Book _copyBookWithGroup(Book book, int groupId) {
    return Book(
      bookUrl: book.bookUrl,
      tocUrl: book.tocUrl,
      origin: book.origin,
      originName: book.originName,
      name: book.name,
      author: book.author,
      kind: book.kind,
      customTag: book.customTag,
      coverUrl: book.coverUrl,
      customCoverUrl: book.customCoverUrl,
      intro: book.intro,
      customIntro: book.customIntro,
      remark: book.remark,
      charset: book.charset,
      type: book.type,
      group: groupId,
      latestChapterTitle: book.latestChapterTitle,
      latestChapterTime: book.latestChapterTime,
      lastCheckTime: book.lastCheckTime,
      lastCheckCount: book.lastCheckCount,
      totalChapterNum: book.totalChapterNum,
      durChapterTitle: book.durChapterTitle,
      durChapterIndex: book.durChapterIndex,
      durChapterPos: book.durChapterPos,
      durChapterTime: book.durChapterTime,
      wordCount: book.wordCount,
      canUpdate: book.canUpdate,
      order: book.order,
      originOrder: book.originOrder,
      variable: book.variable,
      readConfig: book.readConfig,
      syncTime: book.syncTime,
    );
  }

  /// 构造只改变允许更新字段的书籍副本，避免修改其他业务事实。
  Book _copyBookWithCanUpdate(Book book, bool canUpdate) {
    return Book(
      bookUrl: book.bookUrl,
      tocUrl: book.tocUrl,
      origin: book.origin,
      originName: book.originName,
      name: book.name,
      author: book.author,
      kind: book.kind,
      customTag: book.customTag,
      coverUrl: book.coverUrl,
      customCoverUrl: book.customCoverUrl,
      intro: book.intro,
      customIntro: book.customIntro,
      remark: book.remark,
      charset: book.charset,
      type: book.type,
      group: book.group,
      latestChapterTitle: book.latestChapterTitle,
      latestChapterTime: book.latestChapterTime,
      lastCheckTime: book.lastCheckTime,
      lastCheckCount: book.lastCheckCount,
      totalChapterNum: book.totalChapterNum,
      durChapterTitle: book.durChapterTitle,
      durChapterIndex: book.durChapterIndex,
      durChapterPos: book.durChapterPos,
      durChapterTime: book.durChapterTime,
      wordCount: book.wordCount,
      canUpdate: canUpdate,
      order: book.order,
      originOrder: book.originOrder,
      variable: book.variable,
      readConfig: book.readConfig,
      syncTime: book.syncTime,
    );
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
    _groupSubscription.cancel();
    _stateController.close();
    _effectController.close();
  }
}
