import 'dart:io';

import '../../domain/gateway/bookshelf_gateway.dart';
import '../../domain/model/book.dart';
import '../../domain/model/book_chapter.dart';
import '../../domain/model/local_book.dart';
import '../../domain/usecase/add_book_to_bookshelf_use_case.dart';
import '../../help/error/app_result.dart';
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
  }) : _storage = storage,
       _parserRegistry = parserRegistry,
       _bookshelfGateway = bookshelfGateway,
       _addBook = addBook;

  /// 应用私有文件存储边界。
  final LocalBookStorage _storage;

  /// 当前格式解析器注册表。
  final LocalBookParserRegistry _parserRegistry;

  /// 用于查询精确重复内容的书架边界。
  final BookshelfGateway _bookshelfGateway;

  /// 原子保存书籍和目录的业务动作。
  final AddBookToBookshelfUseCase _addBook;

  /// 导入单个系统选择文件；失败时补偿未持久化的新副本。
  Future<LocalBookImportResult> importFile(LocalBookPickedFile pickedFile) async {
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
      /// 事务写入结果。
      final AppResult<void> saved = await _addBook.save(mergedBook, parsed.chapters);
      switch (saved) {
        case AppSuccess<void>():
          return LocalBookImportResult(book: mergedBook, updated: existingBook != null);
        case AppFailure<void>(error: final error):
          throw LocalBookException(error.message);
      }
    } on LocalBookException {
      if (reference != null && existingBook == null) {
        await _tryDeleteCopy(reference);
      }
      rethrow;
    } catch (error) {
      if (reference != null && existingBook == null) {
        await _tryDeleteCopy(reference);
      }
      throw const LocalBookException('本地书导入失败，请确认文件可读取且存储空间充足');
    }
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
