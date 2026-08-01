import 'dart:io';

import '../../domain/gateway/bookshelf_gateway.dart';
import '../../domain/model/book.dart';
import '../../domain/model/book_chapter.dart';
import '../../domain/model/local_book.dart';
import '../../domain/usecase/add_book_to_bookshelf_use_case.dart';
import '../../help/error/app_result.dart';
import '../../help/logging/app_logger.dart';
import 'local_book_parser.dart';
import 'local_book_storage.dart';

/// 编排本地文件复制、格式解析、重复更新和书架事务写入。
final class LocalBookImportCoordinator {
  /// 创建应用级本地书导入协调器。
  const LocalBookImportCoordinator({
    required LocalBookStorage storage,
    required LocalBookParserRegistry parserRegistry,
    required BookshelfGateway bookshelfGateway,
    required AddBookToBookshelfUseCase addBook,
    required AppLogger logger,
    required int Function() currentUserId,
    required Future<void> Function(
      String eventName, {
      Map<String, Object?> props,
    }) analyticsRecorder,
  }) : _storage = storage,
       _parserRegistry = parserRegistry,
       _bookshelfGateway = bookshelfGateway,
       _addBook = addBook,
       _logger = logger,
       _currentUserId = currentUserId,
       _analyticsRecorder = analyticsRecorder;

  /// 应用私有文件存储边界。
  final LocalBookStorage _storage;

  /// 当前格式解析器注册表。
  final LocalBookParserRegistry _parserRegistry;

  /// 用于查询精确重复内容的书架边界。
  final BookshelfGateway _bookshelfGateway;

  /// 原子保存书籍和目录的业务动作。
  final AddBookToBookshelfUseCase _addBook;

  /// 本地书导入到书架可见性全链路使用的统一诊断日志边界。
  final AppLogger _logger;

  /// 当前游客或账号本地数据作用域，仅转换为不可逆摘要后写入诊断日志。
  final int Function() _currentUserId;

  /// 本地书导入完成事件写入边界。
  final Future<void> Function(
    String eventName, {
    Map<String, Object?> props,
  }) _analyticsRecorder;

  /// 导入单个系统选择文件；失败时补偿未持久化的新副本。
  Future<LocalBookImportResult> importFile(LocalBookPickedFile pickedFile) async {
    final Stopwatch stopwatch = Stopwatch()..start();
    /// 已复制到应用目录的稳定文件引用。
    LocalBookFileReference? reference;
    /// 导入前已经存在的同内容书籍。
    Book? existingBook;
    try {
      reference = await _storage.persist(pickedFile);
      /// 由内容指纹生成且不依赖临时路径的稳定书籍主键。
      final String bookUrl = 'local://${reference.contentHash}';
      existingBook = await _bookshelfGateway.getBook(bookUrl);
      /// 当前格式解析器。
      final LocalBookParser parser = _parserRegistry.requireParser(reference.format);
      /// 解析器生成的新文件事实。
      final ParsedLocalBook parsed = await parser.parse(
        filePath: await _storage.resolve(reference),
        bookUrl: bookUrl,
        reference: reference,
        referenceJson: _storage.encodeReference(reference),
      );
      /// 重复导入时保留用户分组、自定义字段和阅读位置。
      final Book mergedBook = existingBook == null
          ? parsed.book
          : _mergeExistingBook(existingBook, parsed.book);
      _logger.info(
        tag: localBookShelfDiagnosticLogTag,
        message: 'stage=import_parsed '
            'bookId=${appLogDiagnosticId(bookUrl)} '
            'scopeId=${_scopeDiagnosticId()} '
            'format=${reference.format.name} '
            'existing=${existingBook != null} '
            'originLocal=${mergedBook.origin == 'loc_book'} '
            'chapterCount=${parsed.chapters.length}',
      );
      /// 事务写入结果。
      final AppResult<void> saved = await _addBook.save(mergedBook, parsed.chapters);
      switch (saved) {
        case AppSuccess<void>():
          await _logCommittedBook(
            book: mergedBook,
            chapterCount: parsed.chapters.length,
          );
          await _recordImportAnalytics(
            format: reference.format,
            result: existingBook == null ? 'imported' : 'updated',
            elapsedMilliseconds: stopwatch.elapsedMilliseconds,
          );
          if (existingBook == null) {
            await _recordBookAddedAnalytics();
          }
          return LocalBookImportResult(book: mergedBook, updated: existingBook != null);
        case AppFailure<void>(error: final error):
          throw LocalBookException(error.message);
      }
    } on LocalBookException catch (error) {
      _logger.warning(
        tag: localBookShelfDiagnosticLogTag,
        message: 'stage=import_failed '
            'bookId=${_referenceDiagnosticId(reference)} '
            'scopeId=${_scopeDiagnosticId()} '
            'failureType=${error.runtimeType}',
      );
      await _recordImportAnalytics(
        format: reference?.format ?? _formatFromName(pickedFile.name),
        result: 'failed',
        elapsedMilliseconds: stopwatch.elapsedMilliseconds,
      );
      if (reference != null && existingBook == null) {
        await _tryDeleteCopy(reference);
      }
      rethrow;
    } catch (error) {
      _logger.error(
        tag: localBookShelfDiagnosticLogTag,
        message: 'stage=import_failed '
            'bookId=${_referenceDiagnosticId(reference)} '
            'scopeId=${_scopeDiagnosticId()} '
            'failureType=${error.runtimeType}',
      );
      await _recordImportAnalytics(
        format: reference?.format ?? _formatFromName(pickedFile.name),
        result: 'failed',
        elapsedMilliseconds: stopwatch.elapsedMilliseconds,
      );
      if (reference != null && existingBook == null) {
        await _tryDeleteCopy(reference);
      }
      throw const LocalBookException('本地书导入失败，请确认文件可读取且存储空间充足');
    }
  }

  /// 事务成功后按稳定主键回查一次，区分“保存返回成功”和“当前作用域确实可读”。
  /// 诊断回查失败不能改变已经提交的导入业务结果。
  Future<void> _logCommittedBook({
    required Book book,
    required int chapterCount,
  }) async {
    try {
      final Book? persisted = await _bookshelfGateway.getBook(book.bookUrl);
      _logger.info(
        tag: localBookShelfDiagnosticLogTag,
        message: 'stage=import_commit_verified '
            'bookId=${appLogDiagnosticId(book.bookUrl)} '
            'scopeId=${_scopeDiagnosticId()} '
            'persisted=${persisted != null} '
            'originLocal=${persisted?.origin == 'loc_book'} '
            'chapterCount=$chapterCount',
      );
    } on Object catch (error) {
      _logger.warning(
        tag: localBookShelfDiagnosticLogTag,
        message: 'stage=import_commit_verify_failed '
            'bookId=${appLogDiagnosticId(book.bookUrl)} '
            'scopeId=${_scopeDiagnosticId()} '
            'failureType=${error.runtimeType}',
      );
    }
  }

  /// 将当前用户作用域转换为不可逆诊断标识，日志本身不保留账号 ID。
  String _scopeDiagnosticId() {
    try {
      return appLogDiagnosticId('${_currentUserId()}');
    } on Object {
      return 'unavailable';
    }
  }

  /// 从已持久化引用恢复稳定书籍诊断标识；复制前失败时返回固定占位值。
  String _referenceDiagnosticId(LocalBookFileReference? reference) {
    if (reference == null) {
      return 'unavailable';
    }
    return appLogDiagnosticId('local://${reference.contentHash}');
  }

  /// 本地书导入结果失败时也只上传格式、结果和耗时分桶。
  Future<void> _recordImportAnalytics({
    required LocalBookFormat? format,
    required String result,
    required int elapsedMilliseconds,
  }) async {
    final String? normalizedFormat = switch (format) {
      LocalBookFormat.txt => 'txt',
      LocalBookFormat.epub => 'epub',
      LocalBookFormat.pdf => 'pdf',
      LocalBookFormat.umd => 'umd',
      _ => null,
    };
    if (normalizedFormat == null) {
      return;
    }
    try {
      await _analyticsRecorder(
        'local_book_import_completed',
        props: <String, Object?>{
          'format': normalizedFormat,
          'result': result,
          'durationBucket': _durationBucket(elapsedMilliseconds),
        },
      );
    } on Object {
      // 匿名分析失败不能改变导入成功或失败结果。
    }
  }

  /// 新内容首次进入书架时报告统一加书入口。
  Future<void> _recordBookAddedAnalytics() async {
    try {
      await _analyticsRecorder(
        'book_added_to_shelf',
        props: const <String, Object?>{'entry': 'import'},
      );
    } on Object {
      // 加书事务已经成功，匿名分析保持旁路。
    }
  }

  /// 在文件复制前按扩展名推断受支持格式，用于失败事件。
  LocalBookFormat? _formatFromName(String name) {
    final String lower = name.toLowerCase();
    if (lower.endsWith('.txt')) {
      return LocalBookFormat.txt;
    }
    if (lower.endsWith('.epub')) {
      return LocalBookFormat.epub;
    }
    if (lower.endsWith('.pdf')) {
      return LocalBookFormat.pdf;
    }
    if (lower.endsWith('.umd')) {
      return LocalBookFormat.umd;
    }
    return null;
  }

  /// 将精确耗时转换为 API 固定分桶。
  String _durationBucket(int elapsedMilliseconds) {
    if (elapsedMilliseconds < 1000) {
      return 'lt_1s';
    }
    if (elapsedMilliseconds < 3000) {
      return '1_3s';
    }
    if (elapsedMilliseconds < 10000) {
      return '3_10s';
    }
    if (elapsedMilliseconds < 30000) {
      return '10_30s';
    }
    return 'gte_30s';
  }

  /// 合并重新解析的文件事实和已有用户状态。
  Book _mergeExistingBook(Book existing, Book parsed) {
    return Book(
      bookUrl: parsed.bookUrl,
      tocUrl: parsed.tocUrl,
      origin: parsed.origin,
      originName: parsed.originName,
      name: parsed.name,
      author: parsed.author,
      kind: parsed.kind,
      customTag: existing.customTag,
      coverUrl: parsed.coverUrl,
      customCoverUrl: existing.customCoverUrl,
      intro: parsed.intro,
      customIntro: existing.customIntro,
      remark: existing.remark,
      charset: parsed.charset,
      type: parsed.type,
      group: existing.group,
      latestChapterTitle: parsed.latestChapterTitle,
      latestChapterTime: parsed.latestChapterTime,
      lastCheckTime: parsed.lastCheckTime,
      lastCheckCount: 0,
      totalChapterNum: parsed.totalChapterNum,
      durChapterTitle: existing.durChapterTitle,
      durChapterIndex: existing.durChapterIndex < parsed.totalChapterNum
          ? existing.durChapterIndex
          : 0,
      durChapterPos: existing.durChapterIndex < parsed.totalChapterNum
          ? existing.durChapterPos
          : 0,
      durChapterTime: existing.durChapterTime,
      wordCount: parsed.wordCount,
      canUpdate: false,
      order: existing.order,
      originOrder: existing.originOrder,
      variable: parsed.variable,
      readConfig: existing.readConfig,
      syncTime: existing.syncTime,
    );
  }

  /// 尽力补偿失败导入产生的新副本，清理失败不覆盖原始错误。
  Future<void> _tryDeleteCopy(LocalBookFileReference reference) async {
    try {
      await _storage.deleteCopy(reference);
    } on FileSystemException {
      // 文件清理由后续孤儿文件维护任务处理，保留原始导入错误。
    }
  }
}

/// 为 M8 阅读协调器提供本地书目标章节正文。
final class LocalBookContentService {
  /// 创建本地正文读取服务。
  const LocalBookContentService({
    required LocalBookStorage storage,
    required LocalBookParserRegistry parserRegistry,
  }) : _storage = storage,
       _parserRegistry = parserRegistry;

  /// 应用私有文件存储边界。
  final LocalBookStorage _storage;

  /// 格式解析器注册表。
  final LocalBookParserRegistry _parserRegistry;

  /// 恢复文件引用并读取目标章节，不把整个应用私有路径暴露给 UI。
  Future<String> loadChapter(Book book, BookChapter chapter) async {
    /// 从 Book.variable 恢复的稳定文件引用。
    final LocalBookFileReference reference = _storage.decodeReference(book);
    /// 当前安装中应用内副本路径。
    final String filePath = await _storage.resolve(reference);
    if (!await File(filePath).exists()) {
      throw const LocalBookException('本地书应用内副本已丢失，请重新导入并绑定文件');
    }
    /// 对应格式解析器。
    final LocalBookParser parser = _parserRegistry.requireParser(reference.format);
    return parser.loadChapter(filePath: filePath, book: book, chapter: chapter);
  }
}
