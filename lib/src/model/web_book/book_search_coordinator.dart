import 'dart:async';

import '../../api/http/http_contract.dart';
import '../../api/js/js_engine.dart';
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
    required HttpCancellationTokenFactory cancellationTokenFactory,
    required AppLogger logger,
    this.maximumConcurrency = 4,
  }) : _sourceGateway = sourceGateway,
       _standardService = standardService,
       _cancellationTokenFactory = cancellationTokenFactory,
       _logger = logger;

  /// 启用书源查询边界。
  final BookSourceGateway _sourceGateway;

  /// 普通规则搜索服务。
  final StandardBookSourceService _standardService;

  /// 每个书源独立取消令牌工厂。
  final HttpCancellationTokenFactory _cancellationTokenFactory;

  /// 【搜书诊断日志】项目统一日志接口，用于记录跨书源调度阶段。
  final AppLogger _logger;

  /// 同时运行的最大书源数，默认与 Android 常用线程数保持保守上限。
  final int maximumConcurrency;

  /// 读取当前启用书源快照。
  Future<List<BookSource>> loadEnabledSources() async {
    /// 当前启用书源快照。
    final List<BookSource> sources = await _sourceGateway.getEnabled();
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
    final List<BookSource> enabled = await _sourceGateway.getEnabled();
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
    run._completion = _execute(
      run: run,
      keyword: keyword.trim(),
      sources: sources,
      onEvent: onEvent,
    );
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
          /// 当前书源结果。
          final List<SearchBook> books = await _standardService
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
            unawaited(
              _sourceGateway
                  .recordSourceOutcome(source.bookSourceUrl, delta: 1)
                  .catchError((Object _) {}),
            );
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

  /// 将异常转换为不泄漏请求数据的稳定分类。
  String _failureCategory(Object error) {
    if (error is JsEngineException) {
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
    for (final HttpCancellationToken token in List<HttpCancellationToken>.from(_tokens)) {
      token.cancel('用户取消搜索');
    }
    _tokens.clear();
  }
}
