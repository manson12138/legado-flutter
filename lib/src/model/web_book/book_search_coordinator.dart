import 'dart:async';

import '../../api/http/http_contract.dart';
import '../../api/js/js_engine.dart';
import '../../domain/gateway/adult_content_gateway.dart';
import '../../domain/gateway/book_source_gateway.dart';
import '../../domain/model/book_search.dart';
import '../../domain/model/book_source.dart';
import '../../domain/model/search_book.dart';
import '../../help/logging/app_logger.dart';
import 'standard_source_service.dart';

/// 创建独立 HTTP 取消令牌的函数类型。
typedef HttpCancellationTokenFactory = HttpCancellationToken Function();

/// 使用同一业务接口调度普通与 JavaScript 书源搜索。
final class BookSearchCoordinator {
  /// 创建受控多书源搜索协调器。
  const BookSearchCoordinator({
    required BookSourceGateway sourceGateway,
    required StandardBookSourceService standardService,
    required AdultContentGateway adultContentGateway,
    required HttpCancellationTokenFactory cancellationTokenFactory,
    required AppLogger logger,
    this.maximumConcurrency = 4,
    this.recordSourceOutcomes = true,
  }) : _sourceGateway = sourceGateway,
       _standardService = standardService,
       _adultContentGateway = adultContentGateway,
       _cancellationTokenFactory = cancellationTokenFactory,
       _logger = logger;

  /// 启用书源查询边界。
  final BookSourceGateway _sourceGateway;

  /// 普通规则搜索服务。
  final StandardBookSourceService _standardService;

  /// 成人内容屏蔽边界；搜索、整书换源和单章换源共用同一份结果过滤。
  final AdultContentGateway _adultContentGateway;

  /// 每个书源独立取消令牌工厂。
  final HttpCancellationTokenFactory _cancellationTokenFactory;

  /// 【搜书诊断日志】项目统一日志接口，用于记录跨书源调度阶段。
  final AppLogger _logger;

  /// 同时运行的最大书源数，默认与 Android 常用线程数保持保守上限。
  final int maximumConcurrency;

  /// 搜索成功时是否立即调整书源分数；自动下载换源关闭此项，改为整书批次统一评分。
  final bool recordSourceOutcomes;

  /// 屏蔽开关或规则变化修订，供保活搜索页面刷新可用书源和清理旧结果。
  Stream<int> get adultContentRuleChanges => _adultContentGateway.ruleChanges;

  /// 读取当前启用书源快照。
  Future<List<BookSource>> loadEnabledSources() async {
    /// 当前启用书源快照。
    final List<BookSource> sources = await _filterVisibleSources(
      await _sourceGateway.getEnabled(),
    );
    _logger.debug(
      tag: bookSearchSourceLogTag,
      message: '读取启用书源完成 sourceCount=${sources.length}',
    );
    return sources;
  }

  /// 开始一次可取消的多书源搜索并返回运行句柄。
  Future<BookSearchRun> start({
    required String keyword,
    required Set<String> selectedSourceUrls,
    required void Function(BookSearchEvent event) onEvent,
  }) async {
    /// 本次开始时固定的启用书源快照，运行中管理页变更不影响当前任务。
    final List<BookSource> enabled = await _filterVisibleSources(
      await _sourceGateway.getEnabled(),
    );
    /// 过滤后的执行书源；空选择表示全部启用书源；置顶优先，其余按成功率从高到低。
    final List<BookSource> sources = enabled.where((BookSource source) {
      return selectedSourceUrls.isEmpty || selectedSourceUrls.contains(source.bookSourceUrl);
    }).toList(growable: false)
      ..sort((BookSource left, BookSource right) {
        if (left.pinned != right.pinned) {
          return left.pinned ? -1 : 1;
        }
        return right.sourceScore.compareTo(left.sourceScore);
      });
    /// 【搜书诊断日志】记录过滤后的执行规模和并发配置，不记录搜索词原文。
    _logger.info(
      tag: bookSearchSourceLogTag,
      message: '多书源调度创建 keywordLength=${keyword.trim().length} '
          'enabledCount=${enabled.length} executionCount=${sources.length} '
          'maximumConcurrency=$maximumConcurrency',
    );
    /// 当前运行句柄。
    final BookSearchRun run = BookSearchRun();
    run._adultContentSubscription = _adultContentGateway.ruleChanges.listen(
      (int _) => run.cancel(),
    );
    run._completion = _execute(
      run: run,
      keyword: keyword.trim(),
      sources: sources,
      onEvent: onEvent,
    ).whenComplete(run._detachAdultContentSubscription);
    return run;
  }

  /// 通过固定数量 worker 执行任务，禁止为每个书源无界创建 Future。
  Future<void> _execute({
    required BookSearchRun run,
    required String keyword,
    required List<BookSource> sources,
    required void Function(BookSearchEvent event) onEvent,
  }) async {
    /// 【搜书诊断日志】多书源协调器整体耗时计时器。
    final Stopwatch runStopwatch = Stopwatch()..start();
    /// 下一个待领取的书源索引；Dart 单 isolate 事件循环保证同步领取不会竞争。
    int nextIndex = 0;
    /// 已结束书源数。
    int completed = 0;
    /// 正常结束书源数。
    int succeeded = 0;
    /// 失败书源数。
    int failed = 0;

    /// 单个 worker 循环领取任务的方法。
    Future<void> worker() async {
      while (!run.isCancelled && nextIndex < sources.length) {
        /// 当前 worker 领取的稳定索引。
        final int index = nextIndex;
        nextIndex += 1;
        /// 当前执行书源。
        final BookSource source = sources[index];
        /// 【搜书诊断日志】当前书源不可逆标识。
        final String sourceId = appLogDiagnosticId(source.bookSourceUrl);
        /// 【搜书诊断日志】当前单书源执行耗时计时器。
        final Stopwatch sourceStopwatch = Stopwatch()..start();
        /// 当前书源独立取消令牌。
        final HttpCancellationToken token = _cancellationTokenFactory();
        run._tokens.add(token);
        try {
          _logger.info(
            tag: bookSearchSourceLogTag,
            message: '单书源搜索开始 sourceId=$sourceId '
                'sourceName=${appLogSafeLabel(source.bookSourceName)} queueIndex=$index '
                'timeoutMs=${source.respondTime.clamp(10000, 60000).toInt()}',
          );
          /// 单源超时，限制在 10～60 秒；底层请求同样持有可取消令牌。
          final Duration timeout = Duration(
            milliseconds: source.respondTime.clamp(10000, 60000).toInt(),
          );
          /// 当前书源结果，已按成人内容屏蔽设置过滤。
          final List<SearchBook> books = await _filterAdultBooks(
            await _standardService
                .search(
                  source: source,
                  keyword: keyword,
                  page: 1,
                  receivedAt: DateTime.now().millisecondsSinceEpoch,
                  cancellationToken: token,
                )
                .timeout(
                  timeout,
                  onTimeout: () {
                    token.cancel('单书源搜索超时');
                    throw TimeoutException('单书源搜索超时');
                  },
                ),
          );
          if (!run.isCancelled) {
            succeeded += 1;
            _logger.info(
              tag: bookSearchSourceLogTag,
              message: '单书源搜索成功 sourceId=$sourceId '
                  'sourceName=${appLogSafeLabel(source.bookSourceName)} resultCount=${books.length} '
                  'elapsedMs=${sourceStopwatch.elapsedMilliseconds}',
            );
            onEvent(BookSearchResultsEvent(source: source, books: books));
            /// 搜索成功累加书源成功率；只在成功时加分，失败不扣分。
            if (recordSourceOutcomes) {
              unawaited(
                _sourceGateway
                    .recordSourceOutcome(source.bookSourceUrl, delta: 1, eventType: 'search')
                    .catchError((Object _) {}),
              );
            }
          }
        } catch (error, stackTrace) {
          if (!run.isCancelled) {
            failed += 1;
            if (error is JsEngineException) {
              /// 【FLUTTER_JS_COMPAT_LOG】脚本逻辑名仅由书源名和固定阶段名组成，不包含脚本正文。
              final String scriptName = appLogSafeLabel(
                error.scriptName ?? '<unknown>',
                maximumLength: 120,
              );
              /// 【FLUTTER_JS_COMPAT_LOG】QuickJS 原始摘要经过认证值、长文本和查询参数脱敏。
              final String engineDetail = appLogSafeJavaScriptDiagnostic(
                error.stack ?? error.message,
              );
              /// 【FLUTTER_JS_COMPAT_LOG】只包含宿主桥方法名和参数类型的调用轨迹。
              final String bridgeCalls = error.bridgeCalls.isEmpty
                  ? '<none>'
                  : error.bridgeCalls.join(' > ');
              _logger.error(
                tag: bookSearchSourceLogTag,
                message: '$javaScriptCompatibilityDebugLogMarker JavaScript 搜索失败 '
                    'sourceId=$sourceId kind=${error.kind.name} scriptName=$scriptName '
                    'line=${error.line?.toString() ?? "<null>"} '
                    'column=${error.column?.toString() ?? "<null>"} '
                    'bridgeCalls=$bridgeCalls engineDetail=$engineDetail',
              );
            }
            _logger.error(
              tag: bookSearchSourceLogTag,
              message: '单书源搜索失败 sourceId=$sourceId '
                  'sourceName=${appLogSafeLabel(source.bookSourceName)} '
                  'category=${_failureCategory(error)} '
                  'elapsedMs=${sourceStopwatch.elapsedMilliseconds}',
              error: error,
              stackTrace: stackTrace,
            );
            onEvent(
              BookSearchFailureEvent(
                BookSearchSourceFailure(
                  sourceUrl: source.bookSourceUrl,
                  sourceName: source.bookSourceName,
                  category: _failureCategory(error),
                  message: _failureMessage(error),
                ),
              ),
            );
            /// 搜索失败累加服务端成功率聚合；取消不算失败。
            if (recordSourceOutcomes) {
              unawaited(
                _sourceGateway
                    .recordSourceOutcome(
                      source.bookSourceUrl,
                      delta: -1,
                      eventType: 'search',
                    )
                    .catchError((Object _) {}),
              );
            }
          } else {
            /// 【搜书诊断日志】取消导致的异常不计入失败，只记录任务退出。
            _logger.info(
              tag: bookSearchSourceLogTag,
              message: '单书源搜索取消 sourceId=$sourceId '
                  'sourceName=${appLogSafeLabel(source.bookSourceName)} '
                  'elapsedMs=${sourceStopwatch.elapsedMilliseconds}',
            );
          }
        } finally {
          run._tokens.remove(token);
          if (!run.isCancelled) {
            completed += 1;
            onEvent(
              BookSearchProgressEvent(
                BookSearchProgress(
                  total: sources.length,
                  completed: completed,
                  succeeded: succeeded,
                  failed: failed,
                ),
              ),
            );
          }
        }
      }
    }

    if (sources.isEmpty) {
      _logger.warning(
        tag: bookSearchSourceLogTag,
        message: '多书源调度无可执行书源 elapsedMs=${runStopwatch.elapsedMilliseconds}',
      );
      onEvent(const BookSearchProgressEvent(BookSearchProgress(total: 0, completed: 0, succeeded: 0, failed: 0)));
      return;
    }
    /// 实际 worker 数量，不超过书源数且至少为一。
    final int workerCount = maximumConcurrency.clamp(1, sources.length).toInt();
    _logger.debug(
      tag: bookSearchSourceLogTag,
      message: '多书源 worker 启动 workerCount=$workerCount sourceCount=${sources.length}',
    );
    await Future.wait<void>(List<Future<void>>.generate(workerCount, (int index) => worker()));
    _logger.info(
      tag: bookSearchSourceLogTag,
      message: '多书源调度结束 cancelled=${run.isCancelled} completed=$completed/${sources.length} '
          'succeeded=$succeeded failed=$failed elapsedMs=${runStopwatch.elapsedMilliseconds}',
    );
  }

  /// 按成人内容屏蔽设置过滤单书源结果；屏蔽关闭时原样返回，不逐条判定。
  Future<List<SearchBook>> _filterAdultBooks(List<SearchBook> books) async {
    if (books.isEmpty || !await _adultContentGateway.isBlockingEnabled()) {
      return books;
    }
    /// 通过成人内容判定的可展示结果。
    final List<SearchBook> filtered = <SearchBook>[];
    for (final SearchBook book in books) {
      /// 当前结果是否命中成人内容判定。
      final bool adult = await _adultContentGateway.isAdultBook(
        name: book.name,
        author: book.author,
        kind: book.kind,
        intro: book.intro,
      );
      if (!adult) {
        filtered.add(book);
      }
    }
    return filtered;
  }

  /// 搜索调度前过滤命中屏蔽词或域名黑名单的书源；同步数据仍完整保留在本地。
  Future<List<BookSource>> _filterVisibleSources(List<BookSource> sources) async {
    if (!await _adultContentGateway.isBlockingEnabled()) {
      return sources;
    }
    final List<BookSource> visible = <BookSource>[];
    for (final BookSource source in sources) {
      final bool blocked = await _adultContentGateway.isAdultSource(
        name: source.bookSourceName,
        group: source.bookSourceGroup,
        comment: source.bookSourceComment,
        url: source.bookSourceUrl,
      );
      if (!blocked) {
        visible.add(source);
      }
    }
    return List<BookSource>.unmodifiable(visible);
  }

  /// 将异常转换为不泄漏请求数据的稳定分类。
  String _failureCategory(Object error) {
    if (error is JsEngineException) {
      if (error.kind == JsFailureKind.interactionRequired) {
        return '需要登录或验证';
      }
      return 'JavaScript';
    }
    if (error is TimeoutException) {
      return '网络';
    }
    return '规则或网络';
  }

  /// 将异常转换为面向用户的稳定摘要。
  String _failureMessage(Object error) {
    if (error is JsEngineException) {
      return error.message;
    }
    if (error is TimeoutException) {
      return '书源搜索超时';
    }
    return '书源搜索失败，请单独重试';
  }
}

/// 表示一次多书源搜索的取消和完成生命周期。
final class BookSearchRun {
  /// 只允许协调器创建运行句柄。
  BookSearchRun();

  /// 当前仍在运行的书源取消令牌。
  final Set<HttpCancellationToken> _tokens = <HttpCancellationToken>{};

  /// 成人内容规则变化监听；规则变化时当前固定书源快照立即失效。
  StreamSubscription<int>? _adultContentSubscription;

  /// 整体运行完成 Future。
  Future<void> _completion = Future<void>.value();

  /// 是否已经主动取消。
  bool isCancelled = false;

  /// 等待全部 worker 退出。
  Future<void> get completion => _completion;

  /// 取消当前和后续任务，旧结果由 ViewModel 运行编号二次隔离。
  void cancel() {
    if (isCancelled) {
      return;
    }
    isCancelled = true;
    unawaited(_detachAdultContentSubscription());
    for (final HttpCancellationToken token in List<HttpCancellationToken>.from(_tokens)) {
      token.cancel('用户取消搜索');
    }
    _tokens.clear();
  }

  /// 释放成人内容规则监听，避免已结束搜索继续持有应用级广播订阅。
  Future<void> _detachAdultContentSubscription() async {
    /// 当前需要释放的订阅；先置空以避免取消和完成路径重复等待同一对象。
    final StreamSubscription<int>? subscription = _adultContentSubscription;
    _adultContentSubscription = null;
    await subscription?.cancel();
  }
}
