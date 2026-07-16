import '../../help/error/app_error.dart';
import '../../help/error/app_result.dart';
import '../gateway/bookshelf_gateway.dart';
import '../gateway/reader_cache_gateway.dart';
import '../model/book.dart';
import '../model/book_chapter.dart';
import '../model/reader_content.dart';
import 'use_case_guard.dart';

/// 保存整书换源时允许用户选择的迁移范围。
///
/// 对应 Android `ChangeSourceMigrationOptions`；缓存下载的删除策略属于下一个 M11 Feature，
/// 本模型只处理当前书籍事实、目录、阅读位置和单书显示配置。
final class ChangeSourceMigrationOptions {
  /// 创建默认保留全部用户事实的换源选项。
  const ChangeSourceMigrationOptions({
    this.migrateReadingProgress = true,
    this.migrateGroup = true,
    this.migrateCover = true,
    this.migrateCategory = true,
    this.migrateRemark = true,
    this.migrateReadConfig = true,
  });

  /// 是否把旧章节位置映射到新目录。
  final bool migrateReadingProgress;

  /// 是否保留用户分组与手动排序。
  final bool migrateGroup;

  /// 是否保留用户自定义封面。
  final bool migrateCover;

  /// 是否保留用户自定义分类与标签。
  final bool migrateCategory;

  /// 是否保留备注和自定义简介。
  final bool migrateRemark;

  /// 是否保留单书阅读配置和 Flutter 显示配置。
  final bool migrateReadConfig;

  /// 复制选项并只替换明确传入的字段。
  ChangeSourceMigrationOptions copyWith({
    bool? migrateReadingProgress,
    bool? migrateGroup,
    bool? migrateCover,
    bool? migrateCategory,
    bool? migrateRemark,
    bool? migrateReadConfig,
  }) {
    return ChangeSourceMigrationOptions(
      migrateReadingProgress: migrateReadingProgress ?? this.migrateReadingProgress,
      migrateGroup: migrateGroup ?? this.migrateGroup,
      migrateCover: migrateCover ?? this.migrateCover,
      migrateCategory: migrateCategory ?? this.migrateCategory,
      migrateRemark: migrateRemark ?? this.migrateRemark,
      migrateReadConfig: migrateReadConfig ?? this.migrateReadConfig,
    );
  }
}

/// 保存整书换源成功后的新主键和非阻断迁移提示。
final class ChangeBookSourceResult {
  /// 创建不可变换源结果。
  ChangeBookSourceResult({
    required this.oldBookUrl,
    required this.book,
    List<String> warnings = const <String>[],
  }) : warnings = List<String>.unmodifiable(warnings);

  /// 被替换的旧书籍主键。
  final String oldBookUrl;

  /// 已持久化的新书源书籍。
  final Book book;

  /// 数据事务成功后，显示配置或稳定锚点复制失败的非阻断提示。
  final List<String> warnings;
}

/// 原子执行整书换源并迁移用户事实，对应 Android `ChangeBookSourceUseCase`。
final class ChangeBookSourceUseCase {
  /// 创建整书换源业务动作。
  const ChangeBookSourceUseCase(this._bookshelfGateway, this._readerCacheGateway);

  /// 提供书籍主键与目录原子替换能力的数据边界。
  final BookshelfGateway _bookshelfGateway;

  /// 提供稳定阅读锚点和单书显示配置复制能力的缓存边界。
  final ReaderCacheGateway _readerCacheGateway;

  /// 校验候选、映射阅读位置、提交事务并复制 URL 关联的阅读配置。
  Future<AppResult<ChangeBookSourceResult>> execute({
    required Book oldBook,
    required Book newBook,
    required List<BookChapter> chapters,
    required ChangeSourceMigrationOptions options,
  }) async {
    if (oldBook.origin == 'loc_book') {
      return validationFailure<ChangeBookSourceResult>('本地书不支持整书换源');
    }
    if (newBook.bookUrl.isEmpty || newBook.origin.isEmpty) {
      return validationFailure<ChangeBookSourceResult>('目标书籍或书源 URL 为空');
    }
    if (newBook.bookUrl == oldBook.bookUrl && newBook.origin == oldBook.origin) {
      return validationFailure<ChangeBookSourceResult>('请选择与当前书籍不同的来源');
    }
    if (chapters.isEmpty) {
      return validationFailure<ChangeBookSourceResult>('目标来源目录为空，不能执行换源');
    }
    if (!chapters.any((BookChapter chapter) => !chapter.isVolume)) {
      return validationFailure<ChangeBookSourceResult>('目标目录没有可阅读章节');
    }
    /// 新目录中已经出现的章节索引。
    final Set<int> chapterIndices = <int>{};
    /// 新目录中已经出现的章节复合键。
    final Set<(String, String)> chapterKeys = <(String, String)>{};
    for (int position = 0; position < chapters.length; position += 1) {
      /// 当前列表位置对应的目标章节。
      final BookChapter chapter = chapters[position];
      if (chapter.bookUrl != newBook.bookUrl) {
        return validationFailure<ChangeBookSourceResult>('目标目录与目标书籍 URL 不一致');
      }
      if (chapter.index != position) {
        return validationFailure<ChangeBookSourceResult>('目标目录章节索引必须从零连续排列');
      }
      if (!chapterIndices.add(chapter.index)) {
        return validationFailure<ChangeBookSourceResult>('目标目录包含重复章节索引');
      }
      /// 与数据库 `(bookUrl, url)` 主键一致的内存复合键。
      final (String, String) chapterKey = (chapter.bookUrl, chapter.url);
      if (!chapterKeys.add(chapterKey)) {
        return validationFailure<ChangeBookSourceResult>('目标目录包含重复章节 URL');
      }
    }
    /// 预检查的新主键查询结果；Repository 会在事务内再次检查。
    final AppResult<Book?> conflictResult = await guardUseCase<Book?>(
      () => _bookshelfGateway.getBook(newBook.bookUrl),
    );
    if (conflictResult case AppFailure<Book?>(error: final AppError error)) {
      return AppFailure<ChangeBookSourceResult>(error);
    }
    /// 已确认查询成功的新主键现有记录。
    final Book? conflict = switch (conflictResult) {
      AppSuccess<Book?>(value: final Book? value) => value,
      AppFailure<Book?>() => null,
    };
    if (conflict != null && conflict.bookUrl != oldBook.bookUrl) {
      return validationFailure<ChangeBookSourceResult>('目标来源的书籍已经在书架中');
    }
    /// 阅读进度迁移后的新目录索引。
    final int migratedIndex = options.migrateReadingProgress
        ? _resolveChapterIndex(oldBook, chapters)
        : 0;
    /// 使用用户迁移选项合并后的最终书籍事实。
    final Book migratedBook = _applyMigration(
      oldBook: oldBook,
      newBook: newBook,
      chapters: chapters,
      migratedIndex: migratedIndex,
      options: options,
    );
    /// 旧 URL 下的稳定字符锚点；读取失败不阻止数据库换源。
    ReaderPositionAnchor? oldAnchor;
    /// 旧 URL 下的 Flutter 单书显示配置；读取失败时不制造覆盖写入。
    ReaderDisplayConfig? oldDisplayConfig;
    /// 数据事务成功后需要向用户解释的非阻断提示。
    final List<String> warnings = <String>[];
    if (options.migrateReadingProgress) {
      try {
        oldAnchor = await _readerCacheGateway.getPositionAnchor(oldBook.bookUrl);
      } on Object {
        warnings.add('旧阅读锚点读取失败，已保留章节索引进度');
      }
    }
    if (options.migrateReadConfig) {
      try {
        oldDisplayConfig = await _readerCacheGateway.getDisplayConfig(oldBook.bookUrl);
      } on Object {
        warnings.add('旧显示配置读取失败，目标书籍将使用默认显示配置');
      }
    }
    /// 书籍和目录原子替换的领域结果。
    final AppResult<void> transactionResult = await guardUseCase<void>(
      () => _bookshelfGateway.changeBookSource(
        oldBookUrl: oldBook.bookUrl,
        newBook: migratedBook,
        chapters: chapters,
      ),
    );
    if (transactionResult case AppFailure<void>(error: final AppError error)) {
      return AppFailure<ChangeBookSourceResult>(error);
    }
    /// 缓存读取结束后固定的旧稳定锚点，便于在异步写入中安全收窄。
    final ReaderPositionAnchor? anchor = oldAnchor;
    if (options.migrateReadingProgress && anchor != null) {
      try {
        /// 与迁移后章节索引对应的新章节。
        final BookChapter targetChapter = chapters[migratedIndex];
        await _readerCacheGateway.savePositionAnchor(
          migratedBook.bookUrl,
          ReaderPositionAnchor(
            chapterUrl: targetChapter.url,
            chapterIndex: migratedIndex,
            characterOffset: anchor.characterOffset,
            context: anchor.context,
          ),
        );
      } on Object {
        warnings.add('稳定阅读锚点复制失败，重新打开时将使用章节索引进度');
      }
    }
    /// 缓存读取结束后固定的旧显示配置，便于在异步写入中安全收窄。
    final ReaderDisplayConfig? displayConfig = oldDisplayConfig;
    if (options.migrateReadConfig && displayConfig != null) {
      try {
        await _readerCacheGateway.saveDisplayConfig(
          migratedBook.bookUrl,
          displayConfig,
        );
      } on Object {
        warnings.add('显示配置复制失败，目标书籍将使用默认显示配置');
      }
    }
    return AppSuccess<ChangeBookSourceResult>(
      ChangeBookSourceResult(
        oldBookUrl: oldBook.bookUrl,
        book: migratedBook,
        warnings: warnings,
      ),
    );
  }

  /// 优先按旧章节标题匹配新目录，找不到时夹取旧索引。
  int _resolveChapterIndex(Book oldBook, List<BookChapter> chapters) {
    /// 去除首尾空白后的旧章节标题。
    final String oldTitle = oldBook.durChapterTitle?.trim() ?? '';
    if (oldTitle.isNotEmpty) {
      /// 与旧标题完全一致且可阅读的新章节索引。
      final int titleIndex = chapters.indexWhere(
        (BookChapter chapter) => !chapter.isVolume && chapter.title.trim() == oldTitle,
      );
      if (titleIndex >= 0) {
        return titleIndex;
      }
    }
    /// 旧索引夹取到新目录范围内。
    final int clampedIndex = oldBook.durChapterIndex.clamp(0, chapters.length - 1).toInt();
    if (!chapters[clampedIndex].isVolume) {
      return clampedIndex;
    }
    /// 卷标题之后的首个可阅读章节。
    final int nextReadableIndex = chapters.indexWhere(
      (BookChapter chapter) => chapter.index >= clampedIndex && !chapter.isVolume,
    );
    if (nextReadableIndex >= 0) {
      return nextReadableIndex;
    }
    /// 新目录中最后一个可阅读章节。
    final int previousReadableIndex = chapters.lastIndexWhere(
      (BookChapter chapter) => !chapter.isVolume,
    );
    return previousReadableIndex >= 0 ? previousReadableIndex : 0;
  }

  /// 按 Android 换源语义把用户事实合并到新书源返回的书籍事实。
  Book _applyMigration({
    required Book oldBook,
    required Book newBook,
    required List<BookChapter> chapters,
    required int migratedIndex,
    required ChangeSourceMigrationOptions options,
  }) {
    /// 迁移后用于 books 表兼容字段的章节标题。
    final String migratedTitle = chapters[migratedIndex].title;
    return Book(
      bookUrl: newBook.bookUrl,
      tocUrl: newBook.tocUrl,
      origin: newBook.origin,
      originName: newBook.originName,
      name: newBook.name,
      author: newBook.author,
      kind: newBook.kind,
      customTag: options.migrateCategory ? oldBook.customTag : newBook.customTag,
      coverUrl: newBook.coverUrl,
      customCoverUrl: options.migrateCover ? oldBook.customCoverUrl : newBook.customCoverUrl,
      intro: newBook.intro,
      customIntro: options.migrateRemark ? oldBook.customIntro : newBook.customIntro,
      remark: options.migrateRemark ? oldBook.remark : newBook.remark,
      charset: newBook.charset,
      type: oldBook.readConfig?.fixedType == true ? oldBook.type : newBook.type,
      group: options.migrateGroup ? oldBook.group : newBook.group,
      latestChapterTitle: chapters.last.title,
      latestChapterTime: newBook.latestChapterTime,
      lastCheckTime: DateTime.now().millisecondsSinceEpoch,
      lastCheckCount: 0,
      totalChapterNum: chapters.length,
      durChapterTitle: migratedTitle,
      durChapterIndex: options.migrateReadingProgress ? migratedIndex : 0,
      durChapterPos: options.migrateReadingProgress ? oldBook.durChapterPos : 0,
      durChapterTime: options.migrateReadingProgress
          ? oldBook.durChapterTime
          : DateTime.now().millisecondsSinceEpoch,
      wordCount: newBook.wordCount ?? oldBook.wordCount,
      canUpdate: oldBook.canUpdate,
      order: options.migrateGroup ? oldBook.order : newBook.order,
      originOrder: newBook.originOrder,
      variable: newBook.variable,
      readConfig: options.migrateReadConfig ? oldBook.readConfig : newBook.readConfig,
      syncTime: options.migrateReadingProgress ? oldBook.syncTime : newBook.syncTime,
    );
  }
}
