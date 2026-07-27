import 'dart:async';

import '../api/http/http_contract.dart';
import '../domain/model/book.dart';
import '../domain/usecase/add_book_to_bookshelf_use_case.dart';
import '../domain/usecase/record_reading_history_use_case.dart';
import '../help/error/app_result.dart';
import '../help/logging/app_logger.dart';
import '../model/web_book/book_detail_service.dart';
import 'bookshelf_history_startup_preloader.dart';
import 'current_user_scope.dart';

/// 启动后为当前游客或账号作用域自动更新书架与阅读历史中的网络书目录。
///
/// 本服务不参与启动首屏阻塞链路，不持有页面对象；书架和历史中相同 URL 只请求一次，
/// 再分别写回两套独立快照。
final class BookshelfHistoryAutoRefreshService {
  /// 创建应用生命周期内唯一的启动目录更新服务。
  BookshelfHistoryAutoRefreshService({
    required BookshelfHistoryStartupPreloader startupPreloader,
    required CurrentUserScope currentUserScope,
    required BookDetailService detailService,
    required AddBookToBookshelfUseCase saveBookshelfBook,
    required RecordReadingHistoryUseCase saveReadingHistory,
    required HttpCancellationToken Function() cancellationTokenFactory,
    required AppLogger logger,
    this.maximumConcurrency = 2,
  }) : _startupPreloader = startupPreloader,
       _currentUserScope = currentUserScope,
       _detailService = detailService,
       _saveBookshelfBook = saveBookshelfBook,
       _saveReadingHistory = saveReadingHistory,
       _cancellationTokenFactory = cancellationTokenFactory,
       _logger = logger;

  /// 提供书架与历史本地首快照的预加载器。
  final BookshelfHistoryStartupPreloader _startupPreloader;

  /// 当前认证用户作用域。
  final CurrentUserScope _currentUserScope;

  /// 联网刷新详情与完整目录的服务。
  final BookDetailService _detailService;

  /// 原子保存书架书籍和目录的业务动作。
  final AddBookToBookshelfUseCase _saveBookshelfBook;

  /// 原子保存阅读历史书籍和目录快照的业务动作。
  final RecordReadingHistoryUseCase _saveReadingHistory;

  /// 为每本书创建独立 HTTP 取消令牌。
  final HttpCancellationToken Function() _cancellationTokenFactory;

  /// 应用统一日志接口；本流程固定使用启动日志 Tag。
  final AppLogger _logger;

  /// 启动后台刷新允许的最大并发数。
  final int maximumConcurrency;

  /// 当前活动任务持有的全部 HTTP 取消令牌。
  final Set<HttpCancellationToken> _activeTokens = <HttpCancellationToken>{};

  /// 当前单飞任务。
  Future<void>? _activeFuture;

  /// 当前单飞任务所属用户。
  int? _activeUserId;

  /// 当前单飞任务所属用户作用域代次。
  int? _activeUserGeneration;

  /// 服务运行代次，用于隔离取消后晚到的异步结果。
  int _runGeneration = 0;

  /// 为当前游客或账号作用域启动或复用一次后台目录更新。
  Future<void> start() {
    final int userId = _currentUserScope.requireUserId();
    final int userGeneration = _currentUserScope.generation;
    final Future<void>? activeFuture = _activeFuture;
    if (activeFuture != null &&
        _activeUserId == userId &&
        _activeUserGeneration == userGeneration) {
      return activeFuture;
    }

    cancel(reason: 'new_user_refresh_started');
    final int runGeneration = _runGeneration;
    final Future<void> future = _execute(
      userId: userId,
      userGeneration: userGeneration,
      runGeneration: runGeneration,
    );
    _activeFuture = future;
    _activeUserId = userId;
    _activeUserGeneration = userGeneration;
    unawaited(
      future.whenComplete(() {
        if (identical(_activeFuture, future)) {
          _activeFuture = null;
          _activeUserId = null;
          _activeUserGeneration = null;
        }
      }),
    );
    return future;
  }

  /// 取消当前用户的全部目录请求，并让已经返回的旧结果失效。
  void cancel({required String reason}) {
    _runGeneration += 1;
    if (_activeTokens.isNotEmpty) {
      _logger.info(
        tag: appStartupLogTag,
        message:
            'stage=bookshelf_history_auto_refresh_cancelled '
            'activeRequests=${_activeTokens.length} reason=$reason',
      );
    }
    for (final HttpCancellationToken token
        in List<HttpCancellationToken>.of(_activeTokens)) {
      token.cancel('启动自动目录更新已取消');
    }
    _activeTokens.clear();
    _activeFuture = null;
    _activeUserId = null;
    _activeUserGeneration = null;
  }

  /// 合并本地快照并通过固定 worker 完成全部可更新书籍。
  Future<void> _execute({
    required int userId,
    required int userGeneration,
    required int runGeneration,
  }) async {
    try {
      final BookshelfHistoryStartupSnapshot snapshot =
          await _startupPreloader.preload();
      if (!_isCurrentRun(
        userId: userId,
        userGeneration: userGeneration,
        runGeneration: runGeneration,
      )) {
        return;
      }

      final Map<String, _AutoRefreshTarget> targetsByUrl =
          <String, _AutoRefreshTarget>{};
      for (final Book book in snapshot.bookshelfBooks) {
        targetsByUrl[book.bookUrl] = _AutoRefreshTarget(bookshelfBook: book);
      }
      for (final Book book in snapshot.readingHistoryBooks) {
        final _AutoRefreshTarget? existing = targetsByUrl[book.bookUrl];
        targetsByUrl[book.bookUrl] = existing == null
            ? _AutoRefreshTarget(readingHistoryBook: book)
            : existing.withReadingHistoryBook(book);
      }

      final List<_AutoRefreshTarget> targets = targetsByUrl.values
          .where((_AutoRefreshTarget target) {
            final Book book = target.refreshSource;
            return book.origin != 'loc_book' && book.canUpdate;
          })
          .toList(growable: false);
      if (targets.isEmpty) {
        _logger.info(
          tag: appStartupLogTag,
          message:
              'stage=bookshelf_history_auto_refresh_skipped '
              'reason=no_refreshable_books',
        );
        return;
      }

      _logger.info(
        tag: appStartupLogTag,
        message:
            'stage=bookshelf_history_auto_refresh_started '
            'targetCount=${targets.length}',
      );
      int nextIndex = 0;
      int succeeded = 0;
      int failed = 0;

      Future<void> worker() async {
        while (_isCurrentRun(
              userId: userId,
              userGeneration: userGeneration,
              runGeneration: runGeneration,
            ) &&
            nextIndex < targets.length) {
          final int index = nextIndex;
          nextIndex += 1;
          final _AutoRefreshTarget target = targets[index];
          final HttpCancellationToken token = _cancellationTokenFactory();
          _activeTokens.add(token);
          try {
            final RefreshedBookResult refreshed = await _detailService
                .refreshBook(
                  book: target.refreshSource,
                  cancellationToken: token,
                )
                .timeout(
                  const Duration(seconds: 60),
                  onTimeout: () {
                    token.cancel('启动自动目录更新超时');
                    throw TimeoutException('启动自动目录更新超时');
                  },
                );
            if (!_isCurrentRun(
              userId: userId,
              userGeneration: userGeneration,
              runGeneration: runGeneration,
            )) {
              return;
            }

            if (target.bookshelfBook != null) {
              final AppResult<void> saveResult =
                  await _saveBookshelfBook.save(
                    refreshed.book,
                    refreshed.chapters,
                  );
              if (saveResult case AppFailure<void>(error: final error)) {
                throw StateError(error.message);
              }
            }

            if (target.readingHistoryBook != null) {
              if (!_isCurrentRun(
                userId: userId,
                userGeneration: userGeneration,
                runGeneration: runGeneration,
              )) {
                return;
              }
              final Book historyBook = target.bookshelfBook == null
                  ? refreshed.book
                  : refreshed.book.copyWithProgress(
                      chapterIndex:
                          target.readingHistoryBook!.durChapterIndex,
                      chapterPos: target.readingHistoryBook!.durChapterPos,
                      readTime: target.readingHistoryBook!.durChapterTime,
                      chapterTitle:
                          target.readingHistoryBook!.durChapterTitle,
                    );
              final AppResult<void> historyResult =
                  await _saveReadingHistory.execute(
                    historyBook,
                    refreshed.chapters,
                  );
              if (historyResult case AppFailure<void>(error: final error)) {
                throw StateError(error.message);
              }
            }
            succeeded += 1;
          } on Object catch (error) {
            if (_isCurrentRun(
              userId: userId,
              userGeneration: userGeneration,
              runGeneration: runGeneration,
            )) {
              failed += 1;
              _logger.warning(
                tag: appStartupLogTag,
                message:
                    'stage=bookshelf_history_auto_refresh_book_failed '
                    'bookId=${appLogDiagnosticId(target.refreshSource.bookUrl)} '
                    'errorType=${error.runtimeType}',
              );
            }
          } finally {
            _activeTokens.remove(token);
          }
        }
      }

      final int workerCount =
          maximumConcurrency.clamp(1, targets.length).toInt();
      await Future.wait<void>(
        List<Future<void>>.generate(workerCount, (int _) => worker()),
      );
      if (_isCurrentRun(
        userId: userId,
        userGeneration: userGeneration,
        runGeneration: runGeneration,
      )) {
        // 自动更新已经改变数据库事实，清除启动旧快照，避免随后创建的页面短暂消费旧数据。
        _startupPreloader.invalidate();
        _logger.info(
          tag: appStartupLogTag,
          message:
              'stage=bookshelf_history_auto_refresh_completed '
              'targetCount=${targets.length} succeeded=$succeeded '
              'failed=$failed',
        );
      }
    } on Object catch (error) {
      if (_isCurrentRun(
        userId: userId,
        userGeneration: userGeneration,
        runGeneration: runGeneration,
      )) {
        _logger.warning(
          tag: appStartupLogTag,
          message:
              'stage=bookshelf_history_auto_refresh_failed '
              'errorType=${error.runtimeType}',
        );
      }
    }
  }

  /// 判断异步结果是否仍属于当前登录用户和当前运行。
  bool _isCurrentRun({
    required int userId,
    required int userGeneration,
    required int runGeneration,
  }) {
    return runGeneration == _runGeneration &&
        _currentUserScope.matches(
          expectedUserId: userId,
          expectedGeneration: userGeneration,
        );
  }
}

/// 同一 URL 在书架和阅读历史中的独立持久化目标。
final class _AutoRefreshTarget {
  /// 创建至少包含一个持久化目标的刷新项。
  const _AutoRefreshTarget({
    this.bookshelfBook,
    this.readingHistoryBook,
  }) : assert(bookshelfBook != null || readingHistoryBook != null);

  /// 书架中的书籍快照。
  final Book? bookshelfBook;

  /// 阅读历史中的书籍快照。
  final Book? readingHistoryBook;

  /// 联网请求优先使用书架事实，使“禁止更新”等书架设置保持权威。
  Book get refreshSource => bookshelfBook ?? readingHistoryBook!;

  /// 在不改变书架目标的情况下补充阅读历史目标。
  _AutoRefreshTarget withReadingHistoryBook(Book book) {
    return _AutoRefreshTarget(
      bookshelfBook: bookshelfBook,
      readingHistoryBook: book,
    );
  }
}
