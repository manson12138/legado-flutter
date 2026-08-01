import 'dart:async';

import '../../app/bookshelf_layout_preferences.dart';
import '../../app/bookshelf_history_startup_preloader.dart';
import '../../app/reader_transition_spec.dart';
import '../../domain/gateway/book_group_gateway.dart';
import '../../domain/gateway/bookshelf_gateway.dart';
import '../../domain/model/book.dart';
import '../../domain/model/book_group.dart';
import '../../domain/usecase/delete_books_from_bookshelf_use_case.dart';
import '../../domain/usecase/create_bookshelf_group_use_case.dart';
import '../../domain/usecase/replace_books_group_use_case.dart';
import '../../help/error/app_result.dart';
import '../../help/logging/app_logger.dart';
import '../../model/bookshelf/bookshelf_refresh_coordinator.dart';
import 'bookshelf_contract.dart';

/// 管理实时书架、分组排序、选择、删除和目录刷新的 MVI ViewModel。
final class BookshelfViewModel {
  /// 创建书架 ViewModel 并订阅书籍与分组流。
  BookshelfViewModel({
    required BookshelfGateway bookshelfGateway,
    required BookGroupGateway bookGroupGateway,
    required DeleteBooksFromBookshelfUseCase deleteBooks,
    required CreateBookshelfGroupUseCase createGroup,
    required ReplaceBooksGroupUseCase replaceBooksGroup,
    required BookshelfRefreshCoordinator refreshCoordinator,
    required BookshelfLayoutPreferences layoutPreferences,
    required BookshelfHistoryStartupPreloader startupPreloader,
    required AppLogger logger,
    required int Function() currentUserId,
    int initialGroupId = BookGroup.idAll,
  }) : _bookshelfGateway = bookshelfGateway,
       _bookGroupGateway = bookGroupGateway,
       _deleteBooks = deleteBooks,
       _createGroup = createGroup,
       _replaceBooksGroup = replaceBooksGroup,
       _refreshCoordinator = refreshCoordinator,
       _layoutPreferences = layoutPreferences,
       _startupPreloader = startupPreloader,
       _logger = logger,
       _currentUserId = currentUserId,
       _state = BookshelfUiState(selectedGroupId: initialGroupId) {
    unawaited(_restoreLayout());
    _applyCompletedStartupSnapshot();
    unawaited(_applyPendingStartupSnapshot());
    _subscribe();
  }

  /// 书架数据边界。
  final BookshelfGateway _bookshelfGateway;
  /// 用户分组数据边界。
  final BookGroupGateway _bookGroupGateway;
  /// 批量删除 UseCase。
  final DeleteBooksFromBookshelfUseCase _deleteBooks;
  /// 创建用户分组 UseCase。
  final CreateBookshelfGroupUseCase _createGroup;
  /// 批量分组 UseCase。
  final ReplaceBooksGroupUseCase _replaceBooksGroup;
  /// 受控目录刷新协调器。
  final BookshelfRefreshCoordinator _refreshCoordinator;
  /// 书架列表/网格模式的持久化读取与写入边界。
  final BookshelfLayoutPreferences _layoutPreferences;
  /// 登录后在主界面启动遮罩期间创建的本地首快照服务。
  final BookshelfHistoryStartupPreloader _startupPreloader;
  /// 本地书导入到书架可见性全链路使用的统一诊断日志边界。
  final AppLogger _logger;
  /// 当前游客或账号本地数据作用域，仅转换为不可逆摘要后写入诊断日志。
  final int Function() _currentUserId;
  /// 上一次本地分组筛选日志签名，避免无状态变化的重复重建刷屏。
  String? _lastLocalFilterLogSignature;
  /// 用户是否已在异步恢复完成前切换布局，避免旧值覆盖新选择。
  bool _layoutChangedByUser = false;
  /// 当前状态。
  BookshelfUiState _state;
  /// 状态广播流。
  final StreamController<BookshelfUiState> _stateController = StreamController<BookshelfUiState>.broadcast();
  /// Effect 广播流。
  final StreamController<BookshelfEffect> _effectController = StreamController<BookshelfEffect>.broadcast();
  /// 数据库实时书籍快照。
  List<Book> _allBooks = const <Book>[];
  /// 数据库用户分组快照。
  List<BookGroup> _userGroups = const <BookGroup>[];
  /// 书籍流订阅。
  StreamSubscription<List<Book>>? _booksSubscription;
  /// 分组流订阅。
  StreamSubscription<List<BookGroup>>? _groupsSubscription;
  /// 当前刷新运行。
  BookshelfRefreshRun? _refreshRun;
  /// 刷新世代，用于隔离取消后的旧事件。
  int _refreshGeneration = 0;
  /// 是否已收到首个书籍快照。
  bool _booksReady = false;
  /// 是否已收到首个分组快照。
  bool _groupsReady = false;

  /// 是否已经由数据库流收到书架首快照，用于防止旧预加载结果回写覆盖新数据。
  bool _booksStreamReceived = false;

  /// 是否已经由数据库流收到分组首快照，用于防止旧预加载结果回写覆盖新数据。
  bool _groupsStreamReceived = false;

  /// 当前状态。
  BookshelfUiState get state => _state;
  /// 后续状态流。
  Stream<BookshelfUiState> get states => _stateController.stream;
  /// 一次性 Effect 流。
  Stream<BookshelfEffect> get effects => _effectController.stream;

  /// 书架所有用户操作的唯一入口。
  void onIntent(BookshelfIntent intent) {
    switch (intent) {
      case ChangeBookshelfQueryIntent(query: final String query):
        _emit(_state.copyWith(query: query));
        _rebuild();
      case ToggleBookshelfLayoutIntent():
        _layoutChangedByUser = true;
        final BookshelfLayoutMode layoutMode =
            _state.layoutMode == BookshelfLayoutMode.grid
                ? BookshelfLayoutMode.list
                : BookshelfLayoutMode.grid;
        _emit(_state.copyWith(layoutMode: layoutMode));
        unawaited(_saveLayout(layoutMode));
      case SelectBookshelfGroupIntent(groupId: final int groupId):
        _emit(_state.copyWith(selectedGroupId: groupId, selectionMode: false, selectedBookUrls: <String>{}));
        _rebuild();
      case ChangeBookshelfSortIntent(sortMode: final BookshelfSortMode sortMode):
        _emit(_state.copyWith(sortMode: sortMode));
        _rebuild();
      case ToggleBookshelfSortOrderIntent():
        _emit(_state.copyWith(descending: !_state.descending));
        _rebuild();
      case TapBookshelfBookIntent(
        bookUrl: final String bookUrl,
        transitionSpec: final transitionSpec,
      ):
        _tapBook(bookUrl, transitionSpec: transitionSpec);
      case LongPressBookshelfBookIntent(bookUrl: final String bookUrl):
        _emit(_state.copyWith(selectionMode: true, selectedBookUrls: <String>{bookUrl}));
      case SelectAllBookshelfBooksIntent():
        _emit(_state.copyWith(selectedBookUrls: _state.books.map((BookshelfBookItem item) => item.book.bookUrl).toSet()));
      case ExitBookshelfSelectionIntent():
        _exitSelection();
      case RefreshBookshelfIntent():
        _refresh();
      case CancelBookshelfRefreshIntent():
        _cancelRefresh(manual: true);
      case DismissBookshelfRefreshResultIntent():
        _dismissRefreshResult();
      case RequestDeleteBookshelfBooksIntent():
        _requestDelete();
      case ConfirmDeleteBookshelfBooksIntent():
        _confirmDelete();
      case RequestMoveBookshelfBooksIntent():
        _requestMove();
      case ConfirmMoveBookshelfBooksIntent(groupId: final int groupId):
        _confirmMove(groupId);
      case CreateAndMoveBookshelfGroupIntent(name: final String name):
        _createAndMove(name);
      case DismissBookshelfDialogIntent():
        _emit(_state.copyWith(clearDialog: true));
      case OpenBookshelfBookInfoIntent(bookUrl: final String bookUrl):
        _openInfo(bookUrl);
      case BackFromBookshelfIntent():
        _back();
      case OpenBookshelfLocalBookImportIntent():
        _effectController.add(const OpenBookshelfLocalBookImportEffect());
      case OpenSelectedBookSourceChangeIntent():
        _openSelectedBookSourceChange();
      case OpenSelectedBookCoverChangeIntent():
        _openSelectedBookCoverChange();
    }
  }

  /// 订阅书架和分组数据库流。
  void _subscribe() {
    _booksSubscription = _bookshelfGateway.watchBookshelf().listen(
      (List<Book> books) {
        _booksStreamReceived = true;
        _allBooks = List<Book>.unmodifiable(books);
        _booksReady = true;
        _logBookSnapshot(stage: 'bookshelf_database_stream', books: books);
        _rebuild();
      },
      onError: (Object error) {
        _booksReady = true;
        _logger.warning(
          tag: localBookShelfDiagnosticLogTag,
          message: 'stage=bookshelf_database_stream_failed '
              'scopeId=${_scopeDiagnosticId()} '
              'failureType=${error.runtimeType}',
        );
        _emit(_state.copyWith(loading: false, errorMessage: '读取书架失败'));
      },
    );
    _groupsSubscription = _bookGroupGateway.watchGroups().listen(
      (List<BookGroup> groups) {
        _groupsStreamReceived = true;
        _userGroups = List<BookGroup>.unmodifiable(groups);
        _groupsReady = true;
        _rebuild();
      },
      onError: (Object error) {
        _groupsReady = true;
        _emit(_state.copyWith(loading: false, errorMessage: '读取书架分组失败'));
      },
    );
  }

  /// 根据数据快照和共享筛选排序状态生成显示模型。
  void _rebuild() {
    /// 当前实际存在的书籍 URL。
    final Set<String> existingUrls = _allBooks.map((Book book) => book.bookUrl).toSet();
    /// 自动剔除数据库中已删除的选择。
    final Set<String> selected = _state.selectedBookUrls.intersection(existingUrls);
    /// 系统和用户分组项。
    final List<BookshelfGroupItem> groups = _buildGroups();
    /// 当前分组是否仍然存在。
    final bool selectedGroupExists = groups.any(
      (BookshelfGroupItem item) => item.group.groupId == _state.selectedGroupId,
    );
    /// 本次实际筛选分组，已删除分组回退全部。
    final int effectiveGroupId = selectedGroupExists
        ? _state.selectedGroupId
        : BookGroup.idAll;
    /// 当前分组书籍。
    final List<Book> filtered = _allBooks.where((Book book) {
      return _matchesGroup(book, effectiveGroupId) && _matchesQuery(book, _state.query);
    }).toList(growable: false);
    if (effectiveGroupId == BookGroup.idLocal) {
      _logLocalFilterResult(filtered);
    }
    filtered.sort(_compareBooks);
    /// 当前显示模型。
    final List<BookshelfBookItem> items = filtered.map(_toItem).toList(growable: false);
    _emit(
      _state.copyWith(
        loading: !(_booksReady && _groupsReady),
        selectedGroupId: effectiveGroupId,
        groups: groups,
        books: items,
        selectedBookUrls: selected,
        selectionMode: selected.isNotEmpty && _state.selectionMode,
        clearError: true,
      ),
    );
  }

  /// 构建固定系统分组与数据库用户分组。
  List<BookshelfGroupItem> _buildGroups() {
    /// 固定第一批系统分组。
    final List<BookGroup> systemGroups = <BookGroup>[
      const BookGroup(groupId: BookGroup.idAll, groupName: '全部'),
      const BookGroup(groupId: BookGroup.idLocal, groupName: '本地'),
      const BookGroup(groupId: BookGroup.idNetNone, groupName: '未分组'),
      const BookGroup(groupId: BookGroup.idUnread, groupName: '未读'),
      const BookGroup(groupId: BookGroup.idReading, groupName: '阅读中'),
    ];
    /// 可显示用户分组。
    final List<BookGroup> visibleUserGroups = _userGroups.where((BookGroup group) {
      return group.show && group.groupId > 0;
    }).toList(growable: false)
      ..sort((BookGroup left, BookGroup right) {
        /// 先比较手动分组顺序。
        final int order = left.order.compareTo(right.order);
        return order != 0 ? order : left.groupId.compareTo(right.groupId);
      });
    return <BookGroup>[...systemGroups, ...visibleUserGroups].map((BookGroup group) {
      /// 当前分组数量。
      final int count = _allBooks.where((Book book) => _matchesGroup(book, group.groupId)).length;
      return BookshelfGroupItem(group: group, bookCount: count);
    }).toList(growable: false);
  }

  /// 判断书籍是否属于系统或用户分组。
  bool _matchesGroup(Book book, int groupId) {
    return switch (groupId) {
      BookGroup.idAll => true,
      BookGroup.idNetNone => book.origin != 'loc_book' && book.group == 0,
      BookGroup.idUnread => _unreadCount(book) > 0,
      BookGroup.idReading => book.durChapterTime > 0 && _unreadCount(book) > 0,
      BookGroup.idLocal => book.origin == 'loc_book',
      _ => groupId > 0 && (book.group & groupId) != 0,
    };
  }

  /// 判断书籍是否匹配搜索词。
  bool _matchesQuery(Book book, String query) {
    /// 小写关键字。
    final String normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) {
      return true;
    }
    return book.name.toLowerCase().contains(normalized) ||
        book.author.toLowerCase().contains(normalized) ||
        book.originName.toLowerCase().contains(normalized) ||
        (book.kind?.toLowerCase().contains(normalized) ?? false);
  }

  /// 按 Android 字段排序，并始终使用 bookUrl 作为稳定次级排序。
  int _compareBooks(Book left, Book right) {
    /// 主排序结果。
    final int primary = switch (_state.sortMode) {
      BookshelfSortMode.recentRead => left.durChapterTime.compareTo(right.durChapterTime),
      BookshelfSortMode.latestUpdate => left.latestChapterTime.compareTo(right.latestChapterTime),
      BookshelfSortMode.name => left.name.toLowerCase().compareTo(right.name.toLowerCase()),
      BookshelfSortMode.manual => left.order.compareTo(right.order),
      BookshelfSortMode.recentActivity => _activityTime(left).compareTo(_activityTime(right)),
      BookshelfSortMode.author => left.author.toLowerCase().compareTo(right.author.toLowerCase()),
    };
    if (primary != 0) {
      return _state.descending ? -primary : primary;
    }
    return left.bookUrl.compareTo(right.bookUrl);
  }

  /// 取得阅读和更新中的较新时间。
  int _activityTime(Book book) {
    return book.latestChapterTime > book.durChapterTime
        ? book.latestChapterTime
        : book.durChapterTime;
  }

  /// 将领域书籍映射为显示模型。
  BookshelfBookItem _toItem(Book book) {
    return BookshelfBookItem(book: book, unreadChapterCount: _unreadCount(book));
  }

  /// 按 Android 公式计算剩余未读章节数。
  int _unreadCount(Book book) {
    /// 扣除当前已进入章节后的剩余数量。
    final int count = book.totalChapterNum - book.durChapterIndex - 1;
    return count > 0 ? count : 0;
  }

  /// 点击书籍时按选择模式切换选择或导航阅读器。
  void _tapBook(
    String bookUrl, {
    required ReaderTransitionSpec? transitionSpec,
  }) {
    if (_state.selectionMode) {
      /// 可修改选择集合。
      final Set<String> selected = Set<String>.from(_state.selectedBookUrls);
      if (!selected.add(bookUrl)) {
        selected.remove(bookUrl);
      }
      _emit(_state.copyWith(selectionMode: selected.isNotEmpty, selectedBookUrls: selected));
      return;
    }
    /// 目标书籍。
    final Book? book = _findBook(bookUrl);
    if (book != null) {
      _effectController.add(
        OpenBookshelfReaderEffect(
          book,
          transitionSpec: transitionSpec,
        ),
      );
    }
  }

  /// 打开书籍详情。
  void _openInfo(String bookUrl) {
    /// 目标书籍。
    final Book? book = _findBook(bookUrl);
    if (book != null) {
      _effectController.add(OpenBookshelfBookInfoEffect(book));
    }
  }

  /// 校验当前恰好选中一本网络书，再请求路由打开整书换源页面。
  void _openSelectedBookSourceChange() {
    if (_state.selectedBookUrls.length != 1) {
      _effectController.add(
        const ShowBookshelfMessageEffect('整书换源一次只能选择一本书'),
      );
      return;
    }
    /// 当前唯一选中的稳定书籍 URL。
    final String selectedBookUrl = _state.selectedBookUrls.first;
    /// 与选择 URL 对应的当前数据库快照。
    final Book? book = _findBook(selectedBookUrl);
    if (book == null) {
      _effectController.add(const ShowBookshelfMessageEffect('选中的书籍已不存在'));
      return;
    }
    if (book.origin == 'loc_book') {
      _effectController.add(const ShowBookshelfMessageEffect('本地书不支持整书换源'));
      return;
    }
    _effectController.add(OpenBookshelfChangeSourceEffect(book));
  }

  /// 校验当前恰好选中一本书，再请求路由打开共用封面选择面板。
  void _openSelectedBookCoverChange() {
    if (_state.selectedBookUrls.length != 1) {
      _effectController.add(
        const ShowBookshelfMessageEffect('更换封面一次只能选择一本书'),
      );
      return;
    }
    /// 当前唯一选中的稳定书籍 URL。
    final String selectedBookUrl = _state.selectedBookUrls.first;
    /// 与选择 URL 对应的当前数据库快照。
    final Book? book = _findBook(selectedBookUrl);
    if (book == null) {
      _effectController.add(const ShowBookshelfMessageEffect('选中的书籍已不存在'));
      return;
    }
    _effectController.add(OpenBookshelfChangeCoverEffect(book));
  }

  /// 开始刷新可见或选中书籍目录。
  Future<void> _refresh() async {
    if (_state.refreshing) {
      return;
    }
    /// 优先刷新选中项，否则刷新当前可见项。
    final Set<String> targetUrls = _state.selectedBookUrls.isNotEmpty
        ? _state.selectedBookUrls
        : _state.books.map((BookshelfBookItem item) => item.book.bookUrl).toSet();
    /// 刷新书籍快照。
    final List<Book> books = _allBooks
        .where((Book book) => targetUrls.contains(book.bookUrl) && book.origin != 'loc_book' && book.canUpdate)
        .toList(growable: false);
    if (books.isEmpty) {
      _effectController.add(const ShowBookshelfMessageEffect('当前没有可刷新的书籍'));
      return;
    }
    _cancelRefresh(manual: false);
    _refreshGeneration += 1;
    /// 本次刷新世代。
    final int generation = _refreshGeneration;
    _emit(
      _state.copyWith(
        refreshing: true,
        refreshCancelled: false,
        refreshFailures: const <BookshelfRefreshFailure>[],
        updatingBookUrls: targetUrls,
        refreshProgress: BookshelfRefreshProgress(total: books.length, completed: 0, succeeded: 0, failed: 0),
      ),
    );
    /// 当前刷新运行。
    final BookshelfRefreshRun run = _refreshCoordinator.start(
      books: books,
      onEvent: (BookshelfRefreshEvent event) => _handleRefreshEvent(generation, event),
    );
    _refreshRun = run;
    await run.completion;
    if (generation == _refreshGeneration && !run.isCancelled) {
      _emit(_state.copyWith(refreshing: false, updatingBookUrls: <String>{}));
    }
  }

  /// 处理当前世代刷新事件。
  void _handleRefreshEvent(int generation, BookshelfRefreshEvent event) {
    if (generation != _refreshGeneration) {
      return;
    }
    switch (event) {
      case BookshelfRefreshSuccessEvent(bookUrl: final String bookUrl):
        _removeUpdating(bookUrl);
      case BookshelfRefreshFailureEvent(failure: final BookshelfRefreshFailure failure):
        _removeUpdating(failure.bookUrl);
        _emit(_state.copyWith(refreshFailures: <BookshelfRefreshFailure>[..._state.refreshFailures, failure]));
      case BookshelfRefreshProgressEvent(progress: final BookshelfRefreshProgress progress):
        _emit(_state.copyWith(refreshProgress: progress));
    }
  }

  /// 从更新集合移除已经结束的书籍。
  void _removeUpdating(String bookUrl) {
    /// 可修改更新集合。
    final Set<String> updating = Set<String>.from(_state.updatingBookUrls)..remove(bookUrl);
    _emit(_state.copyWith(updatingBookUrls: updating));
  }

  /// 取消刷新并隔离旧事件。
  void _cancelRefresh({required bool manual}) {
    _refreshRun?.cancel();
    _refreshRun = null;
    if (manual) {
      _refreshGeneration += 1;
      _emit(_state.copyWith(refreshing: false, refreshCancelled: true, updatingBookUrls: <String>{}));
    }
  }

  /// 在路由创建前已完成预加载时，同步写入两个首快照以直接解除圆形加载。
  void _applyCompletedStartupSnapshot() {
    final BookshelfHistoryStartupSnapshot? snapshot =
        _startupPreloader.snapshot;
    if (snapshot == null) {
      return;
    }
    _applyStartupSnapshot(snapshot);
  }

  /// 预加载仍在执行时等待其完成；若数据库流先到达则不回写旧快照。
  Future<void> _applyPendingStartupSnapshot() async {
    if (_startupPreloader.snapshot != null) {
      return;
    }
    try {
      final BookshelfHistoryStartupSnapshot snapshot =
          await _startupPreloader.preload();
      if (!_booksStreamReceived || !_groupsStreamReceived) {
        _applyStartupSnapshot(snapshot);
      }
    } catch (_) {
      // 预加载失败时由既有数据库流继续负责错误显示和重试。
    }
  }

  /// 将未被数据库流覆盖的预加载首快照写入页面状态。
  void _applyStartupSnapshot(BookshelfHistoryStartupSnapshot snapshot) {
    if (!_booksStreamReceived) {
      _allBooks = snapshot.bookshelfBooks;
      _booksReady = true;
      _logBookSnapshot(
        stage: 'bookshelf_startup_snapshot',
        books: snapshot.bookshelfBooks,
      );
    }
    if (!_groupsStreamReceived) {
      _userGroups = snapshot.bookGroups;
      _groupsReady = true;
    }
    _rebuild();
  }

  /// 记录书架数据源交付的本地书摘要，不记录书名、文件名、路径或正文。
  void _logBookSnapshot({
    required String stage,
    required List<Book> books,
  }) {
    final List<Book> localBooks = books
        .where((Book book) => book.origin == 'loc_book')
        .toList(growable: false);
    final List<String> localIds = localBooks
        .take(12)
        .map((Book book) => appLogDiagnosticId(book.bookUrl))
        .toList(growable: false);
    _logger.info(
      tag: localBookShelfDiagnosticLogTag,
      message: 'stage=$stage '
          'scopeId=${_scopeDiagnosticId()} '
          'totalCount=${books.length} '
          'localCount=${localBooks.length} '
          'localIds=${localIds.join(',')} '
          'idsTruncated=${localBooks.length > localIds.length}',
    );
  }

  /// 记录本地分组的候选数与最终可见数，用于识别搜索词造成的二次隐藏。
  void _logLocalFilterResult(List<Book> visibleBooks) {
    final int localCandidateCount = _allBooks
        .where((Book book) => book.origin == 'loc_book')
        .length;
    final bool queryActive = _state.query.trim().isNotEmpty;
    final String signature = '${_scopeDiagnosticId()}|$localCandidateCount|'
        '${visibleBooks.length}|$queryActive';
    if (_lastLocalFilterLogSignature == signature) {
      return;
    }
    _lastLocalFilterLogSignature = signature;
    _logger.info(
      tag: localBookShelfDiagnosticLogTag,
      message: 'stage=bookshelf_local_filter '
          'scopeId=${_scopeDiagnosticId()} '
          'candidateCount=$localCandidateCount '
          'visibleCount=${visibleBooks.length} '
          'queryActive=$queryActive',
    );
  }

  /// 将当前用户作用域转换为不可逆诊断标识，日志本身不保留账号 ID。
  String _scopeDiagnosticId() {
    try {
      return appLogDiagnosticId('${_currentUserId()}');
    } on Object {
      return 'unavailable';
    }
  }

  /// 在首个数据快照到达前恢复上次选定的书架布局。
  Future<void> _restoreLayout() async {
    try {
      final BookshelfLayoutMode layoutMode =
          await _layoutPreferences.readBookshelfLayout();
      if (!_layoutChangedByUser) {
        _emit(_state.copyWith(layoutMode: layoutMode));
      }
    } catch (error) {
      _emit(_state.copyWith(errorMessage: '读取书架排版设置失败'));
    }
  }

  /// 保存用户刚切换的书架布局；失败不回滚当前可见状态。
  Future<void> _saveLayout(BookshelfLayoutMode layoutMode) async {
    try {
      await _layoutPreferences.saveBookshelfLayout(layoutMode);
    } catch (error) {
      _emit(_state.copyWith(errorMessage: '保存书架排版设置失败'));
    }
  }

  /// 清理已完成或已取消刷新在页面上的临时展示状态，不修改任何书籍数据。
  void _dismissRefreshResult() {
    if (_state.refreshing) {
      return;
    }
    _emit(
      _state.copyWith(
        refreshCancelled: false,
        refreshProgress: const BookshelfRefreshProgress(
          total: 0,
          completed: 0,
          succeeded: 0,
          failed: 0,
        ),
        refreshFailures: const <BookshelfRefreshFailure>[],
      ),
    );
  }

  /// 显示删除确认。
  void _requestDelete() {
    if (_state.selectedBookUrls.isEmpty) {
      return;
    }
    _emit(_state.copyWith(dialog: DeleteBookshelfBooksDialog(_state.selectedBookUrls)));
  }

  /// 执行确认后的事务删除。
  Future<void> _confirmDelete() async {
    /// 对话框中的删除目标。
    final Set<String> bookUrls = switch (_state.dialog) {
      DeleteBookshelfBooksDialog(bookUrls: final Set<String> urls) => urls,
      _ => <String>{},
    };
    _emit(_state.copyWith(clearDialog: true));
    /// 删除结果。
    final AppResult<void> result = await _deleteBooks.execute(bookUrls);
    switch (result) {
      case AppSuccess<void>():
        _exitSelection();
        _effectController.add(ShowBookshelfMessageEffect('已删除 ${bookUrls.length} 本书及其目录'));
      case AppFailure<void>(error: final error):
        _effectController.add(ShowBookshelfMessageEffect(error.message));
    }
  }

  /// 显示批量分组对话框。
  void _requestMove() {
    if (_state.selectedBookUrls.isEmpty) {
      return;
    }
    _emit(_state.copyWith(dialog: MoveBookshelfBooksDialog(_state.selectedBookUrls)));
  }

  /// 通过 UseCase 批量替换分组。
  Future<void> _confirmMove(int groupId) async {
    /// 对话框中的移动目标。
    final Set<String> bookUrls = switch (_state.dialog) {
      MoveBookshelfBooksDialog(bookUrls: final Set<String> urls) => urls,
      _ => <String>{},
    };
    _emit(_state.copyWith(clearDialog: true));
    /// 分组写入结果。
    final AppResult<void> result = await _replaceBooksGroup.execute(bookUrls, groupId);
    switch (result) {
      case AppSuccess<void>():
        _exitSelection();
        _effectController.add(const ShowBookshelfMessageEffect('书籍分组已更新'));
      case AppFailure<void>(error: final error):
        _effectController.add(ShowBookshelfMessageEffect(error.message));
    }
  }

  /// 创建新分组后把对话框中的书籍移动进去。
  Future<void> _createAndMove(String name) async {
    /// 对话框中的移动目标。
    final Set<String> bookUrls = switch (_state.dialog) {
      MoveBookshelfBooksDialog(bookUrls: final Set<String> urls) => urls,
      _ => <String>{},
    };
    /// 创建分组结果。
    final AppResult<BookGroup> createResult = await _createGroup.execute(name);
    switch (createResult) {
      case AppSuccess<BookGroup>(value: final BookGroup group):
        /// 将书籍移动到新分组的结果。
        final AppResult<void> moveResult = await _replaceBooksGroup.execute(
          bookUrls,
          group.groupId,
        );
        switch (moveResult) {
          case AppSuccess<void>():
            _emit(_state.copyWith(clearDialog: true));
            _exitSelection();
            _effectController.add(ShowBookshelfMessageEffect('已创建并移动到“${group.groupName}”'));
          case AppFailure<void>(error: final error):
            _effectController.add(ShowBookshelfMessageEffect(error.message));
        }
      case AppFailure<BookGroup>(error: final error):
        _effectController.add(ShowBookshelfMessageEffect(error.message));
    }
  }

  /// 返回优先关闭对话框、取消选择模式，再关闭页面。
  void _back() {
    if (_state.dialog != null) {
      _emit(_state.copyWith(clearDialog: true));
      return;
    }
    if (_state.selectionMode) {
      _exitSelection();
      return;
    }
    _effectController.add(const CloseBookshelfEffect());
  }

  /// 清空选择模式。
  void _exitSelection() {
    _emit(_state.copyWith(selectionMode: false, selectedBookUrls: <String>{}));
  }

  /// 按稳定 URL 查找书籍。
  Book? _findBook(String bookUrl) {
    for (final Book book in _allBooks) {
      if (book.bookUrl == bookUrl) {
        return book;
      }
    }
    return null;
  }

  /// 发布新状态。
  void _emit(BookshelfUiState state) {
    _state = state;
    if (!_stateController.isClosed) {
      _stateController.add(state);
    }
  }

  /// 取消全部任务和订阅并释放流。
  void dispose() {
    _refreshGeneration += 1;
    _cancelRefresh(manual: false);
    _booksSubscription?.cancel();
    _groupsSubscription?.cancel();
    _stateController.close();
    _effectController.close();
  }
}
