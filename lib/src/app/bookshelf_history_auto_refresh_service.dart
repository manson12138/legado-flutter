import 'dart:async';

import '../api/http/http_contract.dart';
import '../data/dao/toc_refresh_checkpoint_dao.dart';
import '../domain/gateway/chapter_gateway.dart';
import '../domain/gateway/reading_history_gateway.dart';
import '../domain/model/book.dart';
import '../domain/model/book_chapter.dart';
import '../domain/model/toc_refresh_checkpoint.dart';
import '../domain/usecase/add_book_to_bookshelf_use_case.dart';
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
    required ChapterGateway chapterGateway,
    required ReadingHistoryGateway readingHistoryGateway,
    required TocRefreshCheckpointDao checkpointDao,
    required BookDetailService detailService,
    required AddBookToBookshelfUseCase saveBookshelfBook,
    required HttpCancellationToken Function() cancellationTokenFactory,
    required AppLogger logger,
    this.maximumConcurrency = 2,
  }) : _startupPreloader = startupPreloader,
       _currentUserScope = currentUserScope,
       _chapterGateway = chapterGateway,
       _readingHistoryGateway = readingHistoryGateway,
       _checkpointDao = checkpointDao,
       _detailService = detailService,
       _saveBookshelfBook = saveBookshelfBook,
       _cancellationTokenFactory = cancellationTokenFactory,
       _logger = logger;

  /// 提供书架与历史本地首快照的预加载器。
  final BookshelfHistoryStartupPreloader _startupPreloader;

  /// 当前认证用户作用域。
  final CurrentUserScope _currentUserScope;

  /// 读取书架完整目录，供增量页与旧快照安全合并。
  final ChapterGateway _chapterGateway;

  /// 读取未入架历史书的完整目录快照。
  final ReadingHistoryGateway _readingHistoryGateway;

  /// 保存用户级增量目录检查点。
  final TocRefreshCheckpointDao _checkpointDao;

  /// 联网刷新详情与完整目录的服务。
  final BookDetailService _detailService;

  /// 原子保存书架书籍和目录的业务动作。
  final AddBookToBookshelfUseCase _saveBookshelfBook;

  /// 为每本书创建独立 HTTP 取消令牌。
  final HttpCancellationToken Function() _cancellationTokenFactory;

  /// 应用统一日志接口；本流程固定使用启动日志 Tag。
  final AppLogger _logger;

  /// 启动后台刷新允许的最大并发数。
  final int maximumConcurrency;

  /// 同一账号最近成功更新后跳过重复启动刷新的时间窗口。
  static const Duration _freshnessWindow = Duration(minutes: 30);

  /// 即使增量更新持续成功，也要周期性完整校准目录。
  static const Duration _fullRefreshInterval = Duration(days: 7);

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

      await _checkpointDao.deleteBooksNotIn(
        userId,
        targetsByUrl.keys.toSet(),
      );

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
      int skippedFresh = 0;
      int incrementalRefreshes = 0;
      int fullRefreshes = 0;
      int fallbackRefreshes = 0;

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
          final int now = DateTime.now().millisecondsSinceEpoch;
          final TocRefreshCheckpoint? checkpoint =
              await _checkpointDao.get(userId, target.refreshSource.bookUrl);
          if (_isFreshCheckpoint(
            checkpoint: checkpoint,
            book: target.refreshSource,
            now: now,
          )) {
            skippedFresh += 1;
            continue;
          }
          final HttpCancellationToken token = _cancellationTokenFactory();
          _activeTokens.add(token);
          try {
            final _AutoRefreshOutcome outcome = await _refreshTarget(
              target: target,
              checkpoint: checkpoint,
              now: now,
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

            final RefreshedBookResult refreshed = outcome.refreshed;
            final List<BookChapter> chapters = outcome.chapters;
            final Book refreshedBook = _detailService.withChapterSummary(
              target.refreshSource.tocUrl.isEmpty
                  ? refreshed.book
                  : target.refreshSource,
              chapters,
            );

            if (target.bookshelfBook != null) {
              final AppResult<void> saveResult =
                  await _saveBookshelfBook.save(
                    refreshedBook,
                    chapters,
                  );
              if (saveResult case AppFailure<void>(error: final error)) {
                throw StateError(error.message);
              }
            }

            final Book? historySnapshot = target.readingHistoryBook;
            if (historySnapshot != null) {
              if (!_isCurrentRun(
                userId: userId,
                userGeneration: userGeneration,
                runGeneration: runGeneration,
              )) {
                return;
              }
              /// 事务内仍存在时才会提交，并合并最新进度和用户封面。
              final bool historyRefreshed =
                  await _readingHistoryGateway.refreshExistingHistory(
                    refreshedBook,
                    chapters,
                  );
              if (!historyRefreshed && target.bookshelfBook == null) {
                continue;
              }
            }
            if (chapters.isEmpty) {
              throw StateError('目录更新完成但无法保存空目录检查点');
            }
            await _checkpointDao.upsert(
              userId,
              TocRefreshCheckpoint(
                bookUrl: refreshedBook.bookUrl,
                sourceUrl: refreshedBook.origin,
                tocUrl: refreshedBook.tocUrl,
                anchorPageUrl: refreshed.anchorPageUrl,
                visitedPageUrls: refreshed.visitedPageUrls,
                anchorChapterUrl: chapters.last.url,
                reverse: refreshed.reverse,
                chapterCount: chapters.length,
                lastSuccessfulAt: now,
                lastFullRefreshAt: outcome.lastFullRefreshAt,
              ),
            );
            if (outcome.fullRefresh) {
              fullRefreshes += 1;
            } else {
              incrementalRefreshes += 1;
            }
            if (outcome.fallbackUsed) {
              fallbackRefreshes += 1;
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
              'failed=$failed skippedFresh=$skippedFresh '
              'incremental=$incrementalRefreshes full=$fullRefreshes '
              'fallback=$fallbackRefreshes',
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

  /// 判断检查点是否仍属于当前书籍且处于短时间免重复刷新窗口。
  bool _isFreshCheckpoint({
    required TocRefreshCheckpoint? checkpoint,
    required Book book,
    required int now,
  }) {
    if (checkpoint == null || !_checkpointMatchesBook(checkpoint, book)) {
      return false;
    }
    final int elapsed = now - checkpoint.lastSuccessfulAt;
    return elapsed >= 0 && elapsed < _freshnessWindow.inMilliseconds;
  }

  /// 核对书源、目录入口和书籍主键，避免换源后复用旧分页地址。
  bool _checkpointMatchesBook(
    TocRefreshCheckpoint checkpoint,
    Book book,
  ) {
    return checkpoint.bookUrl == book.bookUrl &&
        checkpoint.sourceUrl == book.origin &&
        checkpoint.tocUrl == book.tocUrl &&
        checkpoint.anchorPageUrl.isNotEmpty &&
        checkpoint.visitedPageUrls.contains(checkpoint.anchorPageUrl) &&
        checkpoint.anchorChapterUrl.isNotEmpty;
  }

  /// 优先从检查点页增量刷新；检查点异常、目录漂移或周期校准到期时完整刷新。
  Future<_AutoRefreshOutcome> _refreshTarget({
    required _AutoRefreshTarget target,
    required TocRefreshCheckpoint? checkpoint,
    required int now,
    required HttpCancellationToken cancellationToken,
  }) async {
    final Book book = target.refreshSource;
    if (checkpoint == null || !_checkpointMatchesBook(checkpoint, book)) {
      return _fullRefresh(
        book: book,
        now: now,
        cancellationToken: cancellationToken,
      );
    }
    final int sinceFullRefresh = now - checkpoint.lastFullRefreshAt;
    if (sinceFullRefresh < 0 ||
        sinceFullRefresh >= _fullRefreshInterval.inMilliseconds) {
      return _fullRefresh(
        book: book,
        now: now,
        cancellationToken: cancellationToken,
      );
    }

    final List<BookChapter> existingChapters = target.bookshelfBook != null
        ? await _chapterGateway.getChapterList(book.bookUrl)
        : await _readingHistoryGateway.getHistoryChapters(book.bookUrl);
    final bool localSnapshotMatches =
        existingChapters.length == checkpoint.chapterCount &&
        existingChapters.isNotEmpty &&
        existingChapters.last.url == checkpoint.anchorChapterUrl;
    if (!localSnapshotMatches) {
      return _fullRefresh(
        book: book,
        now: now,
        cancellationToken: cancellationToken,
      );
    }

    try {
      final RefreshedBookResult incremental = await _detailService.refreshBook(
        book: book,
        cancellationToken: cancellationToken,
        initialPageUrl: checkpoint.anchorPageUrl,
        maximumPages: checkpoint.reverse ? 1 : 100,
        previouslyVisitedPageUrls:
            checkpoint.visitedPageUrls.toSet(),
        enableTocLogging: false,
      );
      if (incremental.reverse != checkpoint.reverse) {
        throw const _IncrementalRefreshFallback('reverse_changed');
      }
      final List<BookChapter> merged = _mergeIncrementalChapters(
        existingChapters: existingChapters,
        incrementalChapters: incremental.chapters,
      );
      return _AutoRefreshOutcome(
        refreshed: incremental,
        chapters: merged,
        fullRefresh: false,
        fallbackUsed: false,
        lastFullRefreshAt: checkpoint.lastFullRefreshAt,
      );
    } on Object catch (error) {
      if (cancellationToken.isCancelled) {
        rethrow;
      }
      final String fallbackReason = error is _IncrementalRefreshFallback
          ? error.reason
          : error.runtimeType.toString();
      _logger.info(
        tag: appStartupLogTag,
        message: 'stage=bookshelf_history_auto_refresh_incremental_fallback '
            'bookId=${appLogDiagnosticId(book.bookUrl)} '
            'reason=$fallbackReason',
      );
      final _AutoRefreshOutcome full = await _fullRefresh(
        book: book,
        now: now,
        cancellationToken: cancellationToken,
      );
      return full.withFallbackUsed();
    }
  }

  /// 从目录入口执行完整刷新，并把本次时间记录为新的完整校准时间。
  Future<_AutoRefreshOutcome> _fullRefresh({
    required Book book,
    required int now,
    required HttpCancellationToken cancellationToken,
  }) async {
    final RefreshedBookResult refreshed = await _detailService.refreshBook(
      book: book,
      cancellationToken: cancellationToken,
      enableTocLogging: false,
    );
    return _AutoRefreshOutcome(
      refreshed: refreshed,
      chapters: refreshed.chapters,
      fullRefresh: true,
      fallbackUsed: false,
      lastFullRefreshAt: now,
    );
  }

  /// 用检查点页的首个重叠章节替换旧目录尾部，并重新生成连续索引。
  List<BookChapter> _mergeIncrementalChapters({
    required List<BookChapter> existingChapters,
    required List<BookChapter> incrementalChapters,
  }) {
    if (incrementalChapters.isEmpty) {
      throw const _IncrementalRefreshFallback('empty_incremental_page');
    }
    final Map<String, int> existingIndexByUrl = <String, int>{
      for (final BookChapter chapter in existingChapters)
        chapter.url: chapter.index,
    };
    final int? overlapIndex =
        existingIndexByUrl[incrementalChapters.first.url];
    if (overlapIndex == null) {
      throw const _IncrementalRefreshFallback('missing_overlap');
    }
    final List<BookChapter> merged = <BookChapter>[];
    final Set<String> addedUrls = <String>{};
    for (final BookChapter chapter
        in existingChapters.take(overlapIndex)) {
      if (addedUrls.add(chapter.url)) {
        merged.add(_copyChapterWithIndex(chapter, merged.length));
      }
    }
    for (final BookChapter chapter in incrementalChapters) {
      if (addedUrls.add(chapter.url)) {
        merged.add(_copyChapterWithIndex(chapter, merged.length));
      }
    }
    if (merged.length < existingChapters.length) {
      throw const _IncrementalRefreshFallback('chapter_count_decreased');
    }
    return List<BookChapter>.unmodifiable(merged);
  }

  /// 复制章节并只替换合并后的连续索引。
  BookChapter _copyChapterWithIndex(BookChapter chapter, int index) {
    return BookChapter(
      url: chapter.url,
      title: chapter.title,
      bookUrl: chapter.bookUrl,
      index: index,
      isVolume: chapter.isVolume,
      baseUrl: chapter.baseUrl,
      isVip: chapter.isVip,
      isPay: chapter.isPay,
      resourceUrl: chapter.resourceUrl,
      tag: chapter.tag,
      wordCount: chapter.wordCount,
      start: chapter.start,
      end: chapter.end,
      startFragmentId: chapter.startFragmentId,
      endFragmentId: chapter.endFragmentId,
      variable: chapter.variable,
      reviewImg: chapter.reviewImg,
    );
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

/// 保存一次启动目录刷新采用的模式、合并目录和完整校准时间。
final class _AutoRefreshOutcome {
  /// 创建后台目录刷新结果。
  const _AutoRefreshOutcome({
    required this.refreshed,
    required this.chapters,
    required this.fullRefresh,
    required this.fallbackUsed,
    required this.lastFullRefreshAt,
  });

  /// 网络层返回的书籍摘要和分页元数据。
  final RefreshedBookResult refreshed;

  /// 已与旧快照合并并重新编号的完整目录。
  final List<BookChapter> chapters;

  /// 本次是否从目录入口执行了完整校准。
  final bool fullRefresh;

  /// 本次完整刷新是否由增量检查异常回退触发。
  final bool fallbackUsed;

  /// 最近一次完整校准成功时间。
  final int lastFullRefreshAt;

  /// 返回只把回退标记设为真的不可变副本。
  _AutoRefreshOutcome withFallbackUsed() {
    return _AutoRefreshOutcome(
      refreshed: refreshed,
      chapters: chapters,
      fullRefresh: fullRefresh,
      fallbackUsed: true,
      lastFullRefreshAt: lastFullRefreshAt,
    );
  }
}

/// 表示增量目录无法安全合并，调用方应回退完整刷新。
final class _IncrementalRefreshFallback implements Exception {
  /// 创建不包含书名、URL 或规则正文的安全回退原因。
  const _IncrementalRefreshFallback(this.reason);

  /// 仅供诊断的稳定原因枚举文本。
  final String reason;
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
  Book get refreshSource {
    final Book? shelfBook = bookshelfBook;
    if (shelfBook != null) {
      return shelfBook;
    }
    final Book? historyBook = readingHistoryBook;
    if (historyBook != null) {
      return historyBook;
    }
    throw StateError('启动目录更新目标缺少书架或历史书籍快照');
  }

  /// 在不改变书架目标的情况下补充阅读历史目标。
  _AutoRefreshTarget withReadingHistoryBook(Book book) {
    return _AutoRefreshTarget(
      bookshelfBook: bookshelfBook,
      readingHistoryBook: book,
    );
  }
}
