import 'dart:async';

import '../../app/bookshelf_layout_preferences.dart';
import '../../app/bookshelf_history_startup_preloader.dart';
import '../../app/reader_transition_spec.dart';
import '../../domain/gateway/reading_history_gateway.dart';
import '../../domain/model/book.dart';
import 'reading_history_contract.dart';

/// 管理阅读历史实时快照、布局和刷新观察，以及阅读器导航。
final class ReadingHistoryViewModel {
  /// 创建并立即订阅历史数据。
  ReadingHistoryViewModel(
    this._gateway,
    this._layoutPreferences,
    this._startupPreloader,
  ) {
    unawaited(_restoreLayout());
    _applyCompletedStartupSnapshot();
    unawaited(_applyPendingStartupSnapshot());
    _subscribe();
  }

  /// 阅读历史领域边界。
  final ReadingHistoryGateway _gateway;
  /// 阅读历史列表/网格模式的持久化读取与写入边界。
  final BookshelfLayoutPreferences _layoutPreferences;
  /// 登录后在主界面启动遮罩期间创建的本地首快照服务。
  final BookshelfHistoryStartupPreloader _startupPreloader;
  /// 用户是否已在异步恢复完成前切换布局，避免旧值覆盖新选择。
  bool _layoutChangedByUser = false;
  /// 当前数据库快照。
  List<Book> _allBooks = const <Book>[];
  /// 当前页面状态。
  ReadingHistoryUiState _state = ReadingHistoryUiState();
  /// 状态广播流。
  final StreamController<ReadingHistoryUiState> _stateController =
      StreamController<ReadingHistoryUiState>.broadcast();
  /// Effect 广播流。
  final StreamController<ReadingHistoryEffect> _effectController =
      StreamController<ReadingHistoryEffect>.broadcast();
  /// 可被刷新流程替换的数据库历史流订阅。
  StreamSubscription<List<Book>>? _subscription;

  /// 是否已经由数据库流收到历史首快照，避免旧预加载结果覆盖新数据。
  bool _historyStreamReceived = false;

  /// 当前可同步读取的状态。
  ReadingHistoryUiState get state => _state;
  /// 后续状态流。
  Stream<ReadingHistoryUiState> get states => _stateController.stream;
  /// 一次性 Effect 流。
  Stream<ReadingHistoryEffect> get effects => _effectController.stream;

  /// 处理阅读历史页面操作。
  void onIntent(ReadingHistoryIntent intent) {
    switch (intent) {
      case OpenReadingHistoryBookIntent(
        bookUrl: final String bookUrl,
        transitionSpec: final transitionSpec,
      ):
        _openBook(bookUrl, transitionSpec: transitionSpec);
      case ToggleReadingHistoryLayoutIntent():
        _layoutChangedByUser = true;
        final ReadingHistoryLayoutMode layoutMode =
            _state.layoutMode == ReadingHistoryLayoutMode.list
                ? ReadingHistoryLayoutMode.grid
                : ReadingHistoryLayoutMode.list;
        _emit(_state.copyWith(layoutMode: layoutMode));
        unawaited(_saveLayout(layoutMode));
      case RefreshReadingHistoryIntent():
        unawaited(_refresh());
    }
  }

  /// 在首个历史快照到达前恢复上次选定的历史页面布局。
  Future<void> _restoreLayout() async {
    try {
      final ReadingHistoryLayoutMode layoutMode =
          await _layoutPreferences.readReadingHistoryLayout();
      if (!_layoutChangedByUser) {
        _emit(_state.copyWith(layoutMode: layoutMode));
      }
    } catch (error) {
      _emit(_state.copyWith(errorMessage: '读取历史排版设置失败'));
    }
  }

  /// 保存用户刚切换的历史页面布局；失败不回滚当前可见状态。
  Future<void> _saveLayout(ReadingHistoryLayoutMode layoutMode) async {
    try {
      await _layoutPreferences.saveReadingHistoryLayout(layoutMode);
    } catch (error) {
      _emit(_state.copyWith(errorMessage: '保存历史排版设置失败'));
    }
  }

  /// 连接数据库历史流；刷新时以新的订阅替换旧订阅，避免重复更新和内存保留。
  void _subscribe() {
    _subscription = _gateway.watchHistory().listen(
      (List<Book> books) {
        _historyStreamReceived = true;
        _allBooks = List<Book>.unmodifiable(books);
        _emit(
          _state.copyWith(
            loading: false,
            refreshing: false,
            books: _allBooks,
            clearError: true,
          ),
        );
      },
      onError: (Object error) {
        _emit(
          _state.copyWith(
            loading: false,
            refreshing: false,
            errorMessage: '读取阅读历史失败',
          ),
        );
      },
    );
  }

  /// 在路由创建前已完成预加载时同步应用历史首快照。
  void _applyCompletedStartupSnapshot() {
    final BookshelfHistoryStartupSnapshot? snapshot =
        _startupPreloader.snapshot;
    if (snapshot == null) {
      return;
    }
    _applyStartupSnapshot(snapshot);
  }

  /// 预加载尚未完成时等待其结果；数据库流先到达时不再使用该旧快照。
  Future<void> _applyPendingStartupSnapshot() async {
    if (_startupPreloader.snapshot != null) {
      return;
    }
    try {
      final BookshelfHistoryStartupSnapshot snapshot =
          await _startupPreloader.preload();
      if (!_historyStreamReceived) {
        _applyStartupSnapshot(snapshot);
      }
    } catch (_) {
      // 预加载失败时保留既有数据库流的错误处理路径。
    }
  }

  /// 将预加载历史首快照作为页面初值，后续仍由数据库流覆盖更新。
  void _applyStartupSnapshot(BookshelfHistoryStartupSnapshot snapshot) {
    _allBooks = snapshot.readingHistoryBooks;
    _emit(
      _state.copyWith(
        loading: false,
        refreshing: false,
        books: _allBooks,
        clearError: true,
      ),
    );
  }

  /// 重新建立本地历史快照观察，不执行网络刷新或修改历史数据。
  Future<void> _refresh() async {
    if (_state.refreshing) {
      return;
    }
    _emit(_state.copyWith(refreshing: true));
    await _subscription?.cancel();
    _subscribe();
  }

  /// 从内存快照找到目标书籍并发出阅读器导航。
  void _openBook(
    String bookUrl, {
    required ReaderTransitionSpec? transitionSpec,
  }) {
    for (final Book book in _allBooks) {
      if (book.bookUrl == bookUrl) {
        _effectController.add(
          OpenReadingHistoryReaderEffect(
            book,
            transitionSpec: transitionSpec,
          ),
        );
        return;
      }
    }
  }

  /// 发布新状态。
  void _emit(ReadingHistoryUiState state) {
    _state = state;
    if (!_stateController.isClosed) {
      _stateController.add(state);
    }
  }

  /// 释放数据库订阅和页面流。
  void dispose() {
    _subscription?.cancel();
    _stateController.close();
    _effectController.close();
  }
}
