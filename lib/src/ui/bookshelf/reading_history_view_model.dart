import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../app/bookshelf_layout_preferences.dart';
import '../../app/bookshelf_history_startup_preloader.dart';
import '../../app/reader_transition_spec.dart';
import '../../domain/gateway/reading_history_gateway.dart';
import '../../domain/model/book.dart';
import '../../help/logging/app_logger.dart';
import 'reading_history_contract.dart';

/// 管理阅读历史实时快照、布局和刷新观察，以及阅读器导航。
final class ReadingHistoryViewModel {
  /// 创建并立即订阅历史数据。
  ReadingHistoryViewModel({
    required ReadingHistoryGateway gateway,
    required BookshelfLayoutPreferences layoutPreferences,
    required BookshelfHistoryStartupPreloader startupPreloader,
    required AppLogger logger,
    required int Function() currentUserId,
    required ValueListenable<int?> userScopeListenable,
  }) : _gateway = gateway,
       _layoutPreferences = layoutPreferences,
       _startupPreloader = startupPreloader,
       _logger = logger,
       _currentUserId = currentUserId,
       _userScopeListenable = userScopeListenable {
    _userScopeListenable.addListener(_handleUserScopeChanged);
    unawaited(_restoreLayout());
    _applyCompletedStartupSnapshot();
    unawaited(_applyPendingStartupSnapshot());
    _subscribe(_scopeSubscriptionGeneration);
  }

  /// 阅读历史领域边界。
  final ReadingHistoryGateway _gateway;
  /// 阅读历史列表/网格模式的持久化读取与写入边界。
  final BookshelfLayoutPreferences _layoutPreferences;
  /// 登录后在主界面启动遮罩期间创建的本地首快照服务。
  final BookshelfHistoryStartupPreloader _startupPreloader;
  /// 记录作用域订阅重建和历史首快照数量的统一日志边界。
  final AppLogger _logger;
  /// 返回当前游客或账号 ID，建立 Gateway Stream 时会由 Repository 同步捕获。
  final int Function() _currentUserId;
  /// 当前游客或账号作用域通知器；变化后必须替换捕获旧 userId 的历史流。
  final ValueListenable<int?> _userScopeListenable;
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
  /// 当前历史 Stream 捕获的用户 ID。
  int? _subscribedUserId;
  /// 历史订阅世代；作用域变化后旧 Stream 的迟到事件会被丢弃。
  int _scopeSubscriptionGeneration = 0;
  /// 页面是否已经释放，防止异步取消完成后恢复旧订阅。
  bool _disposed = false;

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
  void _subscribe(int generation) {
    /// 本轮历史 Gateway Stream 捕获的用户 ID。
    final int subscribedUserId = _currentUserId();
    _subscribedUserId = subscribedUserId;
    _logger.info(
      tag: bookshelfHistoryScopeLogTag,
      message: 'stage=history_subscribe '
          'scopeId=${_scopeDiagnosticId(subscribedUserId)} '
          'generation=$generation',
    );
    _subscription = _gateway.watchHistory().listen(
      (List<Book> books) {
        if (!_isActiveScopeSubscription(generation, subscribedUserId)) {
          return;
        }
        _historyStreamReceived = true;
        _allBooks = List<Book>.unmodifiable(books);
        _logger.info(
          tag: bookshelfHistoryScopeLogTag,
          message: 'stage=history_database_stream '
              'scopeId=${_scopeDiagnosticId(subscribedUserId)} '
              'generation=$generation totalCount=${books.length}',
        );
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
        if (!_isActiveScopeSubscription(generation, subscribedUserId)) {
          return;
        }
        _logger.warning(
          tag: bookshelfHistoryScopeLogTag,
          message: 'stage=history_database_stream_failed '
              'scopeId=${_scopeDiagnosticId(subscribedUserId)} '
              'generation=$generation failureType=${error.runtimeType}',
        );
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

  /// 认证恢复、登录或退出登录改变本地作用域后，清空旧历史并重建数据库订阅。
  void _handleUserScopeChanged() {
    if (_disposed) {
      return;
    }
    final int? nextUserId = _userScopeListenable.value;
    if (nextUserId == null || nextUserId == _subscribedUserId) {
      return;
    }
    final int? previousUserId = _subscribedUserId;
    _scopeSubscriptionGeneration += 1;
    final int generation = _scopeSubscriptionGeneration;
    _logger.info(
      tag: bookshelfHistoryScopeLogTag,
      message: 'stage=history_scope_changed '
          'previousScopeId=${_scopeDiagnosticId(previousUserId)} '
          'nextScopeId=${_scopeDiagnosticId(nextUserId)} '
          'generation=$generation',
    );
    _allBooks = const <Book>[];
    _historyStreamReceived = false;
    _emit(
      _state.copyWith(
        loading: true,
        refreshing: false,
        books: const <Book>[],
        clearError: true,
      ),
    );
    unawaited(_restartScopeSubscription(generation));
  }

  /// 等待旧历史订阅结束后，为仍然生效的作用域建立新订阅和启动快照。
  Future<void> _restartScopeSubscription(int generation) async {
    await _subscription?.cancel();
    if (_disposed || generation != _scopeSubscriptionGeneration) {
      return;
    }
    _subscription = null;
    _applyCompletedStartupSnapshot(generation: generation);
    unawaited(_applyPendingStartupSnapshot(generation: generation));
    _subscribe(generation);
  }

  /// 判断历史数据库回调是否仍属于当前作用域和当前订阅世代。
  bool _isActiveScopeSubscription(int generation, int subscribedUserId) {
    return !_disposed &&
        generation == _scopeSubscriptionGeneration &&
        subscribedUserId == _subscribedUserId &&
        subscribedUserId == _userScopeListenable.value;
  }

  /// 在路由创建前已完成预加载时同步应用历史首快照。
  void _applyCompletedStartupSnapshot({int? generation}) {
    final BookshelfHistoryStartupSnapshot? snapshot =
        _startupPreloader.snapshot;
    if (snapshot == null) {
      return;
    }
    _applyStartupSnapshot(
      snapshot,
      generation: generation ?? _scopeSubscriptionGeneration,
    );
  }

  /// 预加载尚未完成时等待其结果；数据库流先到达时不再使用该旧快照。
  Future<void> _applyPendingStartupSnapshot({int? generation}) async {
    final int expectedGeneration =
        generation ?? _scopeSubscriptionGeneration;
    if (_startupPreloader.snapshot != null) {
      return;
    }
    try {
      final BookshelfHistoryStartupSnapshot snapshot =
          await _startupPreloader.preload();
      if (_disposed || expectedGeneration != _scopeSubscriptionGeneration) {
        return;
      }
      if (!_historyStreamReceived) {
        _applyStartupSnapshot(snapshot, generation: expectedGeneration);
      }
    } catch (_) {
      // 预加载失败时保留既有数据库流的错误处理路径。
    }
  }

  /// 将预加载历史首快照作为页面初值，后续仍由数据库流覆盖更新。
  void _applyStartupSnapshot(
    BookshelfHistoryStartupSnapshot snapshot, {
    required int generation,
  }) {
    if (generation != _scopeSubscriptionGeneration ||
        snapshot.userId != _userScopeListenable.value) {
      return;
    }
    _allBooks = snapshot.readingHistoryBooks;
    _logger.info(
      tag: bookshelfHistoryScopeLogTag,
      message: 'stage=history_startup_snapshot '
          'scopeId=${_scopeDiagnosticId(snapshot.userId)} '
          'generation=$generation totalCount=${_allBooks.length}',
    );
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
    /// 刷新开始时的订阅世代，用于识别等待取消期间发生的账号切换。
    final int expectedGeneration = _scopeSubscriptionGeneration;
    /// 刷新开始时的用户 ID，账号切换后不能复用旧刷新建立新流。
    final int? expectedUserId = _subscribedUserId;
    _emit(_state.copyWith(refreshing: true));
    await _subscription?.cancel();
    if (_disposed ||
        expectedGeneration != _scopeSubscriptionGeneration ||
        expectedUserId != _userScopeListenable.value) {
      return;
    }
    _scopeSubscriptionGeneration += 1;
    _subscribe(_scopeSubscriptionGeneration);
  }

  /// 将指定作用域转换为不可逆诊断标识，空值表示尚未建立数据库订阅。
  String _scopeDiagnosticId(int? userId) {
    return userId == null
        ? 'unavailable'
        : appLogDiagnosticId('$userId');
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
    _disposed = true;
    _scopeSubscriptionGeneration += 1;
    _userScopeListenable.removeListener(_handleUserScopeChanged);
    _subscription?.cancel();
    _stateController.close();
    _effectController.close();
  }
}
