import 'dart:async';

import '../../api/http/http_contract.dart';
import '../../domain/gateway/book_source_gateway.dart';
import '../../domain/gateway/bookshelf_gateway.dart';
import '../../domain/gateway/chapter_gateway.dart';
import '../../domain/gateway/download_gateway.dart';
import '../../domain/gateway/reader_cache_gateway.dart';
import '../../domain/model/book.dart';
import '../../domain/model/book_chapter.dart';
import '../../domain/model/book_source.dart';
import '../../domain/model/download_task.dart';
import '../../help/logging/app_logger.dart';
import '../web_book/standard_source_service.dart';

/// App 级单例离线下载队列调度器，对应 Android `CacheBook`/`CacheBookModel` 的第一批职责。
///
/// 与页面级 `create*Coordinator()` 工厂方法不同，本协调器由 [AppDependencies] 在
/// `create()` 时构造一次并长期持有——用户关闭下载面板或退出阅读器后，已入队的下载
/// 仍需要继续跑，直到应用进程退出为止。
///
/// 第一批范围只在应用前台运行期间下载：没有 Android 前台服务/通知或 iOS 后台任务
/// 等价物，应用被系统回收或用户完全退出后下载会停止，下次打开应用会把残留的
/// “运行中”任务重置为“等待”并继续调度，但不会补上已经丢失的下载时间。
final class DownloadCoordinator {
  /// 创建离线下载队列调度器并立即恢复上次残留任务。
  DownloadCoordinator({
    required DownloadGateway downloadGateway,
    required ChapterGateway chapterGateway,
    required BookshelfGateway bookshelfGateway,
    required BookSourceGateway bookSourceGateway,
    required ReaderCacheGateway cacheGateway,
    required StandardBookSourceService standardService,
    required HttpCancellationToken Function() cancellationTokenFactory,
    required AppLogger logger,
    this.maxConcurrency = 3,
    this.maxRetryCount = 3,
  }) : _downloadGateway = downloadGateway,
       _chapterGateway = chapterGateway,
       _bookshelfGateway = bookshelfGateway,
       _bookSourceGateway = bookSourceGateway,
       _cacheGateway = cacheGateway,
       _standardService = standardService,
       _cancellationTokenFactory = cancellationTokenFactory,
       _logger = logger {
    unawaited(_recoverAndStart());
  }

  /// 同时运行的最大章节下载数。
  final int maxConcurrency;

  /// 单章最大自动重试次数，超过后转为失败状态并等待用户手动重试。
  final int maxRetryCount;

  /// 下载队列持久化边界。
  final DownloadGateway _downloadGateway;

  /// 目录读取边界，用于取得目标章节的 URL 和标题。
  final ChapterGateway _chapterGateway;

  /// 书架读取边界，用于取得目标书籍的来源书源。
  final BookshelfGateway _bookshelfGateway;

  /// 书源读取边界。
  final BookSourceGateway _bookSourceGateway;

  /// 正文缓存边界，下载成功的正文以永久缓存写入，与单章换源共用同一存储语义。
  final ReaderCacheGateway _cacheGateway;

  /// 普通书源正文网络与规则服务。
  final StandardBookSourceService _standardService;

  /// HTTP 取消令牌工厂。
  final HttpCancellationToken Function() _cancellationTokenFactory;

  /// 【搜书诊断日志】项目统一日志接口，用于记录下载队列调度。
  final AppLogger _logger;

  /// 当前正在运行的章节任务数。
  int _runningCount = 0;

  /// 是否已有一次调度扫描正在进行。
  bool _pumping = false;

  /// 当前扫描期间是否又有新的调度请求到达，扫描结束后需要立即再来一轮。
  bool _pumpAgain = false;

  /// 观察一本书的下载任务，供面板展示实时状态。
  Stream<List<DownloadTask>> watchTasks(String bookUrl) {
    return _downloadGateway.watchTasks(bookUrl);
  }

  /// 把指定章节索引加入下载队列；已存在的任务会重新排队。
  Future<void> enqueueIndices(String bookUrl, List<int> chapterIndices) async {
    if (chapterIndices.isEmpty) {
      return;
    }
    /// 当前时间戳，作为全部新任务的初始更新时间。
    final int now = DateTime.now().millisecondsSinceEpoch;
    /// 待写入的等待中任务。
    final List<DownloadTask> tasks = chapterIndices
        .map(
          (int index) => DownloadTask(
            bookUrl: bookUrl,
            chapterIndex: index,
            status: DownloadTaskStatus.waiting,
            updatedAt: now,
          ),
        )
        .toList(growable: false);
    await _downloadGateway.upsertTasks(tasks);
    _logger.info(
      tag: bookReaderContentLogTag,
      message: '离线下载入队 bookId=${appLogDiagnosticId(bookUrl)} chapterCount=${tasks.length}',
    );
    _kick();
  }

  /// 重新排队一个失败或已完成的任务。
  Future<void> retryTask(String bookUrl, int chapterIndex) async {
    await _downloadGateway.upsertTask(
      DownloadTask(
        bookUrl: bookUrl,
        chapterIndex: chapterIndex,
        status: DownloadTaskStatus.waiting,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    _kick();
  }

  /// 从队列中移除单个任务，不影响已经写入的正文缓存。
  Future<void> removeTask(String bookUrl, int chapterIndex) {
    return _downloadGateway.removeTask(bookUrl, chapterIndex);
  }

  /// 清空一本书的全部下载任务。
  Future<void> clearBook(String bookUrl) {
    return _downloadGateway.clearBook(bookUrl);
  }

  /// 应用启动后把残留“运行中”任务重置为“等待”，随后开始调度。
  Future<void> _recoverAndStart() async {
    try {
      await _downloadGateway.resetRunningToWaiting(DateTime.now().millisecondsSinceEpoch);
    } on Object catch (error, stackTrace) {
      _logger.warning(
        tag: bookReaderContentLogTag,
        message: '离线下载队列恢复失败',
        error: error,
      );
      _logger.debug(tag: bookReaderContentLogTag, message: stackTrace.toString());
    }
    _kick();
  }

  /// 请求调度器尝试领取更多等待中的任务。
  void _kick() {
    if (_pumping) {
      _pumpAgain = true;
      return;
    }
    unawaited(_pump());
  }

  /// 在并发上限内持续领取等待中的任务并异步处理。
  Future<void> _pump() async {
    _pumping = true;
    try {
      do {
        _pumpAgain = false;
        while (_runningCount < maxConcurrency) {
          /// 本轮领取到的下一个任务；队列为空时为空。
          final DownloadTask? task = await _claimNextTask();
          if (task == null) {
            break;
          }
          _runningCount += 1;
          unawaited(
            _processTask(task).whenComplete(() {
              _runningCount -= 1;
              _kick();
            }),
          );
        }
      } while (_pumpAgain);
    } finally {
      _pumping = false;
    }
  }

  /// 从全部等待或运行中的任务里领取第一个仍处于等待状态的任务并标记为运行中。
  ///
  /// 领取过程中不产生额外 await，同一调度器实例内不会出现两次领取同一任务的竞争。
  Future<DownloadTask?> _claimNextTask() async {
    /// 全部等待或运行中的任务快照。
    final List<DownloadTask> pending = await _downloadGateway.getPendingTasks();
    for (final DownloadTask task in pending) {
      if (task.status != DownloadTaskStatus.waiting) {
        continue;
      }
      /// 标记为运行中的任务。
      final DownloadTask running = task.copyWith(
        status: DownloadTaskStatus.running,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
      await _downloadGateway.upsertTask(running);
      return running;
    }
    return null;
  }

  /// 执行单个章节下载：跳过已缓存或卷标题，否则拉取正文并写入永久缓存。
  Future<void> _processTask(DownloadTask task) async {
    /// 【搜书诊断日志】当前下载任务不可逆标识。
    final String taskId =
        '${appLogDiagnosticId(task.bookUrl)}#${task.chapterIndex}';
    try {
      /// 目标书籍事实。
      final Book? book = await _bookshelfGateway.getBook(task.bookUrl);
      if (book == null) {
        _logger.warning(tag: bookReaderContentLogTag, message: '离线下载终止 taskId=$taskId reason=bookMissing');
        await _downloadGateway.removeTask(task.bookUrl, task.chapterIndex);
        return;
      }
      /// 目标书籍完整目录。
      final List<BookChapter> chapters = await _chapterGateway.getChapterList(task.bookUrl);
      /// 目标章节；目录已变化导致索引失效时视为任务过期。
      BookChapter? chapter;
      for (final BookChapter candidate in chapters) {
        if (candidate.index == task.chapterIndex) {
          chapter = candidate;
          break;
        }
      }
      if (chapter == null) {
        _logger.warning(tag: bookReaderContentLogTag, message: '离线下载终止 taskId=$taskId reason=chapterMissing');
        await _downloadGateway.removeTask(task.bookUrl, task.chapterIndex);
        return;
      }
      if (chapter.isVolume) {
        await _markSuccess(task);
        return;
      }
      /// 当前时间戳，用于缓存有效期判断。
      final int now = DateTime.now().millisecondsSinceEpoch;
      /// 已存在的正文缓存，无论普通 7 天缓存还是既有永久缓存都视为已下载。
      final String? existing = await _cacheGateway.getChapterContent(book.bookUrl, chapter.url, now);
      if (existing != null) {
        /// 用户显式下载动作把既有缓存升级为永久缓存，不再受 7 天有效期约束。
        await _cacheGateway.saveChapterContent(book.bookUrl, chapter.url, existing, 0);
        await _markSuccess(task);
        return;
      }
      if (book.origin == 'loc_book') {
        /// 本地书没有网络正文缓存概念，交给阅读器本地内容服务按需读取即可。
        await _markSuccess(task);
        return;
      }
      /// 目标书籍来源书源。
      final BookSource? source = await _bookSourceGateway.getByUrl(book.origin);
      if (source == null) {
        await _markFailed(task, reason: 'sourceMissing');
        return;
      }
      /// 本次下载取消令牌。
      final HttpCancellationToken token = _cancellationTokenFactory();
      /// 普通规则或 JavaScript 混合链路解析后的正文页。
      final ParsedContentPage parsed = await _standardService.loadContent(
        source: source,
        chapter: chapter,
        cancellationToken: token,
      );
      if (parsed.content.trim().isEmpty) {
        await _markFailed(task, reason: 'emptyContent');
        return;
      }
      await _cacheGateway.saveChapterContent(book.bookUrl, chapter.url, parsed.content, 0);
      _logger.info(
        tag: bookReaderContentLogTag,
        message: '离线下载章节成功 taskId=$taskId contentLength=${parsed.content.length}',
      );
      await _markSuccess(task);
    } on Object catch (error, stackTrace) {
      _logger.warning(
        tag: bookReaderContentLogTag,
        message: '离线下载章节失败 taskId=$taskId retryCount=${task.retryCount}',
        error: error,
      );
      _logger.debug(tag: bookReaderContentLogTag, message: stackTrace.toString());
      await _markFailed(task, reason: 'exception');
    }
  }

  /// 把任务标记为下载成功。
  Future<void> _markSuccess(DownloadTask task) {
    return _downloadGateway.upsertTask(
      task.copyWith(status: DownloadTaskStatus.success, updatedAt: DateTime.now().millisecondsSinceEpoch),
    );
  }

  /// 按重试次数决定短延迟后重新排队，或在达到上限后标记为失败终态。
  Future<void> _markFailed(DownloadTask task, {required String reason}) async {
    /// 本次失败后的累计重试次数。
    final int nextRetryCount = task.retryCount + 1;
    if (nextRetryCount >= maxRetryCount) {
      await _downloadGateway.upsertTask(
        task.copyWith(
          status: DownloadTaskStatus.failed,
          retryCount: nextRetryCount,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      return;
    }
    await Future<void>.delayed(const Duration(seconds: 1));
    await _downloadGateway.upsertTask(
      task.copyWith(
        status: DownloadTaskStatus.waiting,
        retryCount: nextRetryCount,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }
}
