import 'dart:async';

import '../../api/http/http_contract.dart';
import '../../domain/model/book.dart';
import '../../domain/usecase/add_book_to_bookshelf_use_case.dart';
import '../../help/error/app_result.dart';
import '../web_book/book_detail_service.dart';

/// 创建书架刷新 HTTP 取消令牌的函数类型。
typedef BookshelfCancellationTokenFactory = HttpCancellationToken Function();

/// 表示单本书目录刷新失败。
final class BookshelfRefreshFailure {
  /// 创建不包含响应正文和请求信息的安全失败摘要。
  const BookshelfRefreshFailure({
    required this.bookUrl,
    required this.bookName,
    required this.message,
  });

  /// 失败书籍稳定 URL。
  final String bookUrl;
  /// 失败书名。
  final String bookName;
  /// 可安全展示的失败原因。
  final String message;
}

/// 表示书架刷新当前进度。
final class BookshelfRefreshProgress {
  /// 创建不可变进度。
  const BookshelfRefreshProgress({
    required this.total,
    required this.completed,
    required this.succeeded,
    required this.failed,
  });

  /// 可刷新书籍总数。
  final int total;
  /// 已完成数量。
  final int completed;
  /// 成功数量。
  final int succeeded;
  /// 失败数量。
  final int failed;
}

/// 书架刷新协调器增量事件。
sealed class BookshelfRefreshEvent {
  /// 限制事件类型。
  const BookshelfRefreshEvent();
}

/// 单书刷新成功事件。
final class BookshelfRefreshSuccessEvent extends BookshelfRefreshEvent {
  /// 创建成功事件。
  const BookshelfRefreshSuccessEvent(this.bookUrl);
  /// 成功书籍 URL。
  final String bookUrl;
}

/// 单书刷新失败事件。
final class BookshelfRefreshFailureEvent extends BookshelfRefreshEvent {
  /// 创建失败事件。
  const BookshelfRefreshFailureEvent(this.failure);
  /// 失败摘要。
  final BookshelfRefreshFailure failure;
}

/// 刷新进度事件。
final class BookshelfRefreshProgressEvent extends BookshelfRefreshEvent {
  /// 创建进度事件。
  const BookshelfRefreshProgressEvent(this.progress);
  /// 最新进度。
  final BookshelfRefreshProgress progress;
}

/// 使用固定 worker 刷新书架目录，单书失败不影响其他书籍。
final class BookshelfRefreshCoordinator {
  /// 创建目录刷新协调器。
  const BookshelfRefreshCoordinator({
    required BookDetailService detailService,
    required AddBookToBookshelfUseCase saveBook,
    required BookshelfCancellationTokenFactory cancellationTokenFactory,
    this.maximumConcurrency = 3,
  }) : _detailService = detailService,
       _saveBook = saveBook,
       _cancellationTokenFactory = cancellationTokenFactory;

  /// 详情和目录刷新服务。
  final BookDetailService _detailService;
  /// 原子保存书籍与目录的 UseCase。
  final AddBookToBookshelfUseCase _saveBook;
  /// 每本书独立取消令牌工厂。
  final BookshelfCancellationTokenFactory _cancellationTokenFactory;
  /// 同时刷新的最大书籍数。
  final int maximumConcurrency;

  /// 启动一次刷新并返回可取消句柄。
  BookshelfRefreshRun start({
    required List<Book> books,
    required void Function(BookshelfRefreshEvent event) onEvent,
  }) {
    /// 过滤本地书和禁止更新书籍后的稳定快照。
    final List<Book> refreshable = books.where((Book book) {
      return book.origin != 'loc_book' && book.canUpdate;
    }).toList(growable: false);
    /// 当前刷新运行。
    final BookshelfRefreshRun run = BookshelfRefreshRun();
    run._completion = _execute(run: run, books: refreshable, onEvent: onEvent);
    return run;
  }

  /// 通过固定 worker 执行全部刷新任务。
  Future<void> _execute({
    required BookshelfRefreshRun run,
    required List<Book> books,
    required void Function(BookshelfRefreshEvent event) onEvent,
  }) async {
    /// 下一个待领取索引。
    int nextIndex = 0;
    /// 已完成数量。
    int completed = 0;
    /// 成功数量。
    int succeeded = 0;
    /// 失败数量。
    int failed = 0;

    /// 单个有限 worker。
    Future<void> worker() async {
      while (!run.isCancelled && nextIndex < books.length) {
        /// 当前领取索引。
        final int index = nextIndex;
        nextIndex += 1;
        /// 当前刷新书籍。
        final Book book = books[index];
        /// 当前书籍取消令牌。
        final HttpCancellationToken token = _cancellationTokenFactory();
        run._tokens.add(token);
        try {
          /// 刷新得到的新书籍和完整目录。
          final RefreshedBookResult refreshed = await _detailService
              .refreshBook(book: book, cancellationToken: token)
              .timeout(
                const Duration(seconds: 60),
                onTimeout: () {
                  token.cancel('书架目录刷新超时');
                  throw TimeoutException('书架目录刷新超时');
                },
              );
          /// 原子保存结果。
          final AppResult<void> saveResult = await _saveBook.save(
            refreshed.book,
            refreshed.chapters,
          );
          if (saveResult case AppFailure<void>(error: final error)) {
            throw BookDetailException(error.message);
          }
          if (!run.isCancelled) {
            succeeded += 1;
            onEvent(BookshelfRefreshSuccessEvent(book.bookUrl));
          }
        } catch (error) {
          if (!run.isCancelled) {
            failed += 1;
            onEvent(
              BookshelfRefreshFailureEvent(
                BookshelfRefreshFailure(
                  bookUrl: book.bookUrl,
                  bookName: book.name,
                  message: _safeMessage(error),
                ),
              ),
            );
          }
        } finally {
          run._tokens.remove(token);
          if (!run.isCancelled) {
            completed += 1;
            onEvent(
              BookshelfRefreshProgressEvent(
                BookshelfRefreshProgress(
                  total: books.length,
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

    if (books.isEmpty) {
      onEvent(const BookshelfRefreshProgressEvent(BookshelfRefreshProgress(total: 0, completed: 0, succeeded: 0, failed: 0)));
      return;
    }
    /// 实际 worker 数。
    final int workerCount = maximumConcurrency.clamp(1, books.length).toInt();
    await Future.wait<void>(
      List<Future<void>>.generate(workerCount, (int index) => worker()),
    );
  }

  /// 将异常转换为不泄漏网络数据的摘要。
  String _safeMessage(Object error) {
    if (error is BookDetailException) {
      return error.message;
    }
    if (error is TimeoutException) {
      return '目录刷新超时';
    }
    return '目录刷新失败';
  }
}

/// 表示一次目录刷新运行的取消和完成生命周期。
final class BookshelfRefreshRun {
  /// 只允许协调器创建运行。
  BookshelfRefreshRun();

  /// 当前活动请求令牌。
  final Set<HttpCancellationToken> _tokens = <HttpCancellationToken>{};
  /// 整体完成 Future。
  Future<void> _completion = Future<void>.value();
  /// 是否已取消。
  bool isCancelled = false;

  /// 等待全部 worker 退出。
  Future<void> get completion => _completion;

  /// 取消当前请求并停止继续领取任务。
  void cancel() {
    if (isCancelled) {
      return;
    }
    isCancelled = true;
    for (final HttpCancellationToken token in List<HttpCancellationToken>.from(_tokens)) {
      token.cancel('用户取消书架刷新');
    }
    _tokens.clear();
  }
}
