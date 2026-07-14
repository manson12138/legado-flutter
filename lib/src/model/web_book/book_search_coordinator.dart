import 'dart:async';

import '../../api/http/http_contract.dart';
import '../../domain/gateway/book_source_gateway.dart';
import '../../domain/model/book_search.dart';
import '../../domain/model/book_source.dart';
import '../../domain/model/search_book.dart';
import 'standard_source_service.dart';

/// 创建独立 HTTP 取消令牌的函数类型。
typedef HttpCancellationTokenFactory = HttpCancellationToken Function();

/// 使用同一业务接口调度普通与 JavaScript 书源搜索。
///
/// M04 尚未完成真实 JavaScript 书源验收，因此当前对 JavaScript 书源返回明确单源失败，
/// 不会错误地交给普通规则解析器；后续只需替换该分支的执行器，ViewModel 与页面无需改动。
final class BookSearchCoordinator {
  /// 创建受控多书源搜索协调器。
  const BookSearchCoordinator({
    required BookSourceGateway sourceGateway,
    required StandardBookSourceService standardService,
    required HttpCancellationTokenFactory cancellationTokenFactory,
    this.maximumConcurrency = 4,
  }) : _sourceGateway = sourceGateway,
       _standardService = standardService,
       _cancellationTokenFactory = cancellationTokenFactory;

  /// 启用书源查询边界。
  final BookSourceGateway _sourceGateway;

  /// 普通规则搜索服务。
  final StandardBookSourceService _standardService;

  /// 每个书源独立取消令牌工厂。
  final HttpCancellationTokenFactory _cancellationTokenFactory;

  /// 同时运行的最大书源数，默认与 Android 常用线程数保持保守上限。
  final int maximumConcurrency;

  /// 读取当前启用书源快照。
  Future<List<BookSource>> loadEnabledSources() => _sourceGateway.getEnabled();

  /// 开始一次可取消的多书源搜索并返回运行句柄。
  Future<BookSearchRun> start({
    required String keyword,
    required Set<String> selectedSourceUrls,
    required void Function(BookSearchEvent event) onEvent,
  }) async {
    /// 本次开始时固定的启用书源快照，运行中管理页变更不影响当前任务。
    final List<BookSource> enabled = await _sourceGateway.getEnabled();
    /// 过滤后的执行书源；空选择表示全部启用书源。
    final List<BookSource> sources = enabled.where((BookSource source) {
      return selectedSourceUrls.isEmpty || selectedSourceUrls.contains(source.bookSourceUrl);
    }).toList(growable: false);
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
        /// 当前书源独立取消令牌。
        final HttpCancellationToken token = _cancellationTokenFactory();
        run._tokens.add(token);
        try {
          if (_requiresJavaScript(source)) {
            throw const _JavaScriptSourcePendingException();
          }
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
            onEvent(BookSearchResultsEvent(source: source, books: books));
          }
        } catch (error) {
          if (!run.isCancelled) {
            failed += 1;
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
      onEvent(const BookSearchProgressEvent(BookSearchProgress(total: 0, completed: 0, succeeded: 0, failed: 0)));
      return;
    }
    /// 实际 worker 数量，不超过书源数且至少为一。
    final int workerCount = maximumConcurrency.clamp(1, sources.length).toInt();
    await Future.wait<void>(List<Future<void>>.generate(workerCount, (int index) => worker()));
  }

  /// 判断普通规则链路当前不能安全执行的 JavaScript 书源。
  bool _requiresJavaScript(BookSource source) {
    if (source.jsLib?.trim().isNotEmpty == true) {
      return true;
    }
    /// 可能包含脚本的规则文本。
    final String rules = <String?>[
      source.searchUrl,
      source.ruleSearch,
      source.ruleBookInfo,
      source.ruleToc,
      source.ruleContent,
    ].whereType<String>().join('\n');
    return RegExp(r'@js:|<js>|js@|Packages\.|JavaImporter|java\.', caseSensitive: false)
        .hasMatch(rules);
  }

  /// 将异常转换为不泄漏请求数据的稳定分类。
  String _failureCategory(Object error) {
    if (error is _JavaScriptSourcePendingException) {
      return 'JavaScript';
    }
    if (error is TimeoutException) {
      return '网络';
    }
    return '规则或网络';
  }

  /// 将异常转换为面向用户的稳定摘要。
  String _failureMessage(Object error) {
    if (error is _JavaScriptSourcePendingException) {
      return '该书源依赖 JavaScript，需等待 M04 真机兼容验收后接入';
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

/// 标识 JavaScript 执行边界尚未通过 M04 真机验收。
final class _JavaScriptSourcePendingException implements Exception {
  /// 创建无敏感上下文的内部异常。
  const _JavaScriptSourcePendingException();
}
