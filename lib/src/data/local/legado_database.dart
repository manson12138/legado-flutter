import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import '../../help/logging/app_logger.dart';
import 'database_change_notifier.dart';

/// 管理 Flutter 独立 SQLite 数据库的打开、迁移、事务和释放。
///
/// 这是全新数据库，不读取或迁移原 Android App 的 Room 数据库。
final class LegadoDatabase {
  /// 创建惰性数据库实例；首次 DAO 操作时才真正打开文件。
  LegadoDatabase({
    required AppLogger logger,
    DatabaseChangeNotifier? changeNotifier,
  })  : _logger = logger,
        changeNotifier = changeNotifier ?? DatabaseChangeNotifier();

  /// Flutter 独立数据库文件名，不与原 App 的 `legado.db` 共用。
  static const String databaseName = 'legado_flutter.db';

  /// 当前全新数据库版本；M2 不包含旧 App Room 迁移。
  static const int schemaVersion = 12;

  /// 表级变更通知器，由事务提交成功后触发。
  final DatabaseChangeNotifier changeNotifier;

  /// 应用组合根注入的统一日志器，数据库操作固定使用数据库 Tag。
  final AppLogger _logger;

  /// 已打开或正在打开的数据库 Future，保证组合根只创建一个连接。
  Future<Database>? _databaseFuture;

  /// 获取共享数据库连接，并在第一次访问时创建当前 Schema。
  Future<Database> get database {
    /// 已存在的数据库打开任务。
    final Future<Database>? existingFuture = _databaseFuture;
    if (existingFuture != null) {
      return existingFuture;
    }

    /// 本次创建的数据库打开任务。
    final Future<Database> openingFuture = _openDatabase();
    _databaseFuture = openingFuture;
    return openingFuture;
  }

  /// 在一个 SQLite 事务中执行关联写入，并将结果返回给 Repository。
  Future<T> transaction<T>(Future<T> Function(Transaction transaction) action) async {
    /// 已打开的共享数据库连接。
    final Database openedDatabase = await database;
    logOperation(operation: 'TRANSACTION_BEGIN', table: '<multiple>');
    try {
      final T result = await openedDatabase.transaction<T>(action);
      logOperation(operation: 'TRANSACTION_COMMIT', table: '<multiple>');
      return result;
    } catch (error, stackTrace) {
      _logger.error(
        tag: databaseLogTag,
        message: 'operation=TRANSACTION_ROLLBACK table=<multiple>',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  /// 由所有 DAO 调用，统一输出操作类型、表名、条件和参数数量。
  void logOperation({
    required String operation,
    required String table,
    String? where,
    int argumentCount = 0,
    int? itemCount,
  }) {
    _logger.debug(
      tag: databaseLogTag,
      message: 'operation=$operation '
          'table=$table '
          'where=${where ?? '<none>'} '
          'argumentCount=$argumentCount '
          'itemCount=${itemCount ?? -1}',
    );
  }

  /// 打开数据库并配置外键约束与首次建表回调。
  Future<Database> _openDatabase() async {
    /// Android 或 iOS 为当前应用分配的数据库目录。
    final String databasesDirectory = await getDatabasesPath();
    /// Flutter 独立数据库的完整路径。
    final String databasePath = path.join(databasesDirectory, databaseName);
    _logger.info(
      tag: databaseLogTag,
      message: 'operation=OPEN database=$databaseName version=$schemaVersion',
    );
    return openDatabase(
      databasePath,
      version: schemaVersion,
      onConfigure: (Database configuredDatabase) async {
        logOperation(operation: 'PRAGMA', table: '<database>');
        await configuredDatabase.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (Database createdDatabase, int version) async {
        await _createSchemaV2(createdDatabase);
        await _createSchemaV3(createdDatabase);
        await _createSchemaV5(createdDatabase);
        await _createSchemaV7(createdDatabase);
        await _createSchemaV8(createdDatabase);
        await _createSchemaV10(createdDatabase);
        await _createSchemaV11(createdDatabase);
      },
      onUpgrade: (Database upgradedDatabase, int oldVersion, int newVersion) async {
        if (oldVersion < 2) {
          logOperation(operation: 'ALTER_TABLE', table: 'book_sources');
          await upgradedDatabase.execute(
            'ALTER TABLE book_sources ADD COLUMN extraFieldsJson TEXT',
          );
        }
        if (oldVersion < 3 && newVersion < 9) {
          await _createSchemaV3(upgradedDatabase);
        }
        if (oldVersion < 4) {
          logOperation(operation: 'ALTER_TABLE', table: 'book_sources');
          await upgradedDatabase.execute(
            'ALTER TABLE book_sources ADD COLUMN sourceScore INTEGER NOT NULL DEFAULT 0',
          );
          await upgradedDatabase.execute(
            'ALTER TABLE book_sources ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0',
          );
        }
        if (oldVersion < 5) {
          await _createSchemaV5(upgradedDatabase);
        }
        // v1/v2 升级会在上方直接创建已包含 v6 字段的下载表，不能再次追加同名列。
        if (oldVersion >= 3 && oldVersion < 6 && newVersion < 9) {
          logOperation(operation: 'ALTER_TABLE', table: 'download_tasks');
          await upgradedDatabase.execute(
            'ALTER TABLE download_tasks ADD COLUMN errorMessage TEXT',
          );
          await upgradedDatabase.execute(
            'ALTER TABLE download_tasks ADD COLUMN contentLength INTEGER NOT NULL DEFAULT 0',
          );
        }
        // v1/v2 会直接创建当前下载任务字段；仅已有 v3～v6 表需要追加批次和书源归因列。
        if (oldVersion >= 3 && oldVersion < 7 && newVersion < 9) {
          logOperation(operation: 'ALTER_TABLE', table: 'download_tasks');
          await upgradedDatabase.execute(
            'ALTER TABLE download_tasks ADD COLUMN generation INTEGER NOT NULL DEFAULT 0',
          );
          await upgradedDatabase.execute(
            "ALTER TABLE download_tasks ADD COLUMN attemptedSourceUrlsJson TEXT NOT NULL DEFAULT '[]'",
          );
          await upgradedDatabase.execute(
            'ALTER TABLE download_tasks ADD COLUMN successfulSourceUrl TEXT',
          );
        }
        if (oldVersion < 7 && newVersion < 9) {
          await _createSchemaV7(upgradedDatabase);
        }
        if (oldVersion < 8 && newVersion < 9) {
          await _createSchemaV8(upgradedDatabase);
        }
        if (oldVersion < 9) {
          await _rebuildUserScopedSchemaV9(upgradedDatabase);
        }
        if (oldVersion < 10) {
          await _createSchemaV10(upgradedDatabase);
        }
        if (oldVersion < 11) {
          await _createSchemaV11(upgradedDatabase);
        }
        if (oldVersion < 12) {
          await _addUserScopeToReaderAssetsV12(upgradedDatabase);
        }
      },
    );
  }

  /// 按外键依赖顺序建立当前表、唯一约束和索引。
  Future<void> _createSchemaV2(Database database) async {
    logOperation(operation: 'CREATE_SCHEMA', table: '<all>');
    /// 将全部 DDL 作为单批次提交，避免只创建部分表。
    final Batch schemaBatch = database.batch();

    schemaBatch.execute('''
      CREATE TABLE books (
        userId INTEGER NOT NULL,
        bookUrl TEXT NOT NULL DEFAULT '',
        tocUrl TEXT NOT NULL DEFAULT '',
        origin TEXT NOT NULL DEFAULT 'loc_book',
        originName TEXT NOT NULL DEFAULT '',
        name TEXT NOT NULL DEFAULT '',
        author TEXT NOT NULL DEFAULT '',
        kind TEXT,
        customTag TEXT,
        coverUrl TEXT,
        customCoverUrl TEXT,
        intro TEXT,
        customIntro TEXT,
        remark TEXT,
        charset TEXT,
        type INTEGER NOT NULL DEFAULT 0,
        `group` INTEGER NOT NULL DEFAULT 0,
        latestChapterTitle TEXT,
        latestChapterTime INTEGER NOT NULL DEFAULT 0,
        lastCheckTime INTEGER NOT NULL DEFAULT 0,
        lastCheckCount INTEGER NOT NULL DEFAULT 0,
        totalChapterNum INTEGER NOT NULL DEFAULT 0,
        durChapterTitle TEXT,
        durChapterIndex INTEGER NOT NULL DEFAULT 0,
        durChapterPos INTEGER NOT NULL DEFAULT 0,
        durChapterTime INTEGER NOT NULL DEFAULT 0,
        wordCount TEXT,
        canUpdate INTEGER NOT NULL DEFAULT 1,
        `order` INTEGER NOT NULL,
        originOrder INTEGER NOT NULL DEFAULT 0,
        variable TEXT,
        readConfig TEXT,
        syncTime INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (userId, bookUrl)
      )
    ''');
    schemaBatch.execute(
      'CREATE INDEX index_books_user_name_author '
      'ON books (userId, name, author)',
    );
    schemaBatch.execute(
      'CREATE INDEX index_books_user_read_time '
      'ON books (userId, durChapterTime DESC)',
    );

    schemaBatch.execute('''
      CREATE TABLE book_groups (
        userId INTEGER NOT NULL,
        groupId INTEGER NOT NULL,
        groupName TEXT NOT NULL,
        cover TEXT,
        `order` INTEGER NOT NULL DEFAULT 0,
        enableRefresh INTEGER NOT NULL DEFAULT 1,
        show INTEGER NOT NULL DEFAULT 1,
        bookSort INTEGER NOT NULL DEFAULT -1,
        isPrivate INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (userId, groupId)
      )
    ''');
    schemaBatch.execute(
      'CREATE INDEX index_book_groups_user_order '
      'ON book_groups (userId, `order`)',
    );

    schemaBatch.execute('''
      CREATE TABLE book_sources (
        bookSourceUrl TEXT NOT NULL,
        bookSourceName TEXT NOT NULL,
        bookSourceGroup TEXT,
        bookSourceType INTEGER NOT NULL,
        bookUrlPattern TEXT,
        customOrder INTEGER NOT NULL DEFAULT 0,
        enabled INTEGER NOT NULL DEFAULT 1,
        enabledExplore INTEGER NOT NULL DEFAULT 1,
        jsLib TEXT,
        enabledCookieJar INTEGER DEFAULT 0,
        concurrentRate TEXT,
        header TEXT,
        loginUrl TEXT,
        loginUi TEXT,
        loginCheckJs TEXT,
        coverDecodeJs TEXT,
        bookSourceComment TEXT,
        variableComment TEXT,
        lastUpdateTime INTEGER NOT NULL,
        respondTime INTEGER NOT NULL,
        weight INTEGER NOT NULL,
        exploreUrl TEXT,
        exploreScreen TEXT,
        ruleExplore TEXT,
        searchUrl TEXT,
        ruleSearch TEXT,
        ruleBookInfo TEXT,
        ruleToc TEXT,
        ruleContent TEXT,
        ruleReview TEXT,
        eventListener INTEGER NOT NULL DEFAULT 0,
        customButton INTEGER NOT NULL DEFAULT 0,
        homepageModules TEXT,
        extraFieldsJson TEXT,
        sourceScore INTEGER NOT NULL DEFAULT 0,
        pinned INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (bookSourceUrl)
      )
    ''');
    schemaBatch.execute(
      'CREATE INDEX index_book_sources_bookSourceUrl '
      'ON book_sources (bookSourceUrl)',
    );

    schemaBatch.execute('''
      CREATE TABLE chapters (
        userId INTEGER NOT NULL,
        url TEXT NOT NULL,
        title TEXT NOT NULL,
        isVolume INTEGER NOT NULL,
        baseUrl TEXT NOT NULL,
        bookUrl TEXT NOT NULL,
        `index` INTEGER NOT NULL,
        isVip INTEGER NOT NULL,
        isPay INTEGER NOT NULL,
        resourceUrl TEXT,
        tag TEXT,
        wordCount TEXT,
        start INTEGER,
        end INTEGER,
        startFragmentId TEXT,
        endFragmentId TEXT,
        variable TEXT,
        reviewImg TEXT,
        PRIMARY KEY (userId, url, bookUrl),
        FOREIGN KEY (userId, bookUrl)
          REFERENCES books (userId, bookUrl) ON DELETE CASCADE
      )
    ''');
    schemaBatch.execute(
      'CREATE INDEX index_chapters_user_book '
      'ON chapters (userId, bookUrl)',
    );
    schemaBatch.execute(
      'CREATE UNIQUE INDEX index_chapters_user_book_index '
      'ON chapters (userId, bookUrl, `index`)',
    );

    schemaBatch.execute('''
      CREATE TABLE searchBooks (
        bookUrl TEXT NOT NULL,
        origin TEXT NOT NULL,
        originName TEXT NOT NULL,
        type INTEGER NOT NULL,
        name TEXT NOT NULL,
        author TEXT NOT NULL,
        kind TEXT,
        coverUrl TEXT,
        intro TEXT,
        wordCount TEXT,
        latestChapterTitle TEXT,
        tocUrl TEXT NOT NULL,
        time INTEGER NOT NULL,
        variable TEXT,
        originOrder INTEGER NOT NULL,
        chapterWordCountText TEXT,
        chapterWordCount INTEGER NOT NULL DEFAULT -1,
        respondTime INTEGER NOT NULL DEFAULT -1,
        PRIMARY KEY (bookUrl),
        FOREIGN KEY (origin) REFERENCES book_sources (bookSourceUrl) ON DELETE CASCADE
      )
    ''');
    schemaBatch.execute(
      'CREATE UNIQUE INDEX index_searchBooks_bookUrl ON searchBooks (bookUrl)',
    );
    schemaBatch.execute(
      'CREATE INDEX index_searchBooks_origin ON searchBooks (origin)',
    );

    schemaBatch.execute('''
      CREATE TABLE bookmarks (
        userId INTEGER NOT NULL DEFAULT -1,
        time INTEGER NOT NULL,
        bookName TEXT NOT NULL,
        bookAuthor TEXT NOT NULL DEFAULT '',
        chapterIndex INTEGER NOT NULL,
        chapterPos INTEGER NOT NULL,
        chapterName TEXT NOT NULL,
        bookText TEXT NOT NULL,
        content TEXT NOT NULL,
        PRIMARY KEY (time)
      )
    ''');
    schemaBatch.execute(
      'CREATE INDEX index_bookmarks_user_bookName_bookAuthor '
      'ON bookmarks (userId, bookName, bookAuthor)',
    );

    schemaBatch.execute('''
      CREATE TABLE cookies (
        url TEXT NOT NULL,
        cookie TEXT NOT NULL,
        PRIMARY KEY (url)
      )
    ''');
    schemaBatch.execute(
      'CREATE UNIQUE INDEX index_cookies_url ON cookies (url)',
    );

    schemaBatch.execute('''
      CREATE TABLE caches (
        `key` TEXT NOT NULL,
        value TEXT,
        deadline INTEGER NOT NULL,
        PRIMARY KEY (`key`)
      )
    ''');
    schemaBatch.execute(
      'CREATE UNIQUE INDEX index_caches_key ON caches (`key`)',
    );

    schemaBatch.execute('''
      CREATE TABLE replace_rules (
        id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
        userId INTEGER NOT NULL DEFAULT -1,
        name TEXT NOT NULL DEFAULT '',
        `group` TEXT,
        pattern TEXT NOT NULL DEFAULT '',
        replacement TEXT NOT NULL DEFAULT '',
        scope TEXT,
        scopeTitle INTEGER NOT NULL DEFAULT 0,
        scopeContent INTEGER NOT NULL DEFAULT 1,
        excludeScope TEXT,
        isEnabled INTEGER NOT NULL DEFAULT 1,
        isRegex INTEGER NOT NULL DEFAULT 1,
        timeoutMillisecond INTEGER NOT NULL DEFAULT 3000,
        sortOrder INTEGER NOT NULL DEFAULT 0
      )
    ''');
    schemaBatch.execute(
      'CREATE INDEX index_replace_rules_user_order '
      'ON replace_rules (userId, sortOrder)',
    );

    await schemaBatch.commit(noResult: true);
  }

  /// 新增离线下载队列表；只记录队列可见状态，实际正文仍写入 `caches` 表。
  Future<void> _createSchemaV3(Database database) async {
    logOperation(operation: 'CREATE_SCHEMA', table: 'download_tasks');
    await database.execute('''
      CREATE TABLE IF NOT EXISTS download_tasks (
        userId INTEGER NOT NULL,
        bookUrl TEXT NOT NULL,
        chapterIndex INTEGER NOT NULL,
        status TEXT NOT NULL,
        retryCount INTEGER NOT NULL DEFAULT 0,
        errorMessage TEXT,
        contentLength INTEGER NOT NULL DEFAULT 0,
        generation INTEGER NOT NULL DEFAULT 0,
        attemptedSourceUrlsJson TEXT NOT NULL DEFAULT '[]',
        successfulSourceUrl TEXT,
        updatedAt INTEGER NOT NULL,
        PRIMARY KEY (userId, bookUrl, chapterIndex),
        FOREIGN KEY (userId, bookUrl)
          REFERENCES books (userId, bookUrl) ON DELETE CASCADE
      )
    ''');
    await database.execute(
      'CREATE INDEX IF NOT EXISTS index_download_tasks_user_book '
      'ON download_tasks (userId, bookUrl)',
    );
  }

  /// 新增每本书下载批次、自动换源锁定和一次性书源评分状态表。
  Future<void> _createSchemaV7(Database database) async {
    logOperation(operation: 'CREATE_SCHEMA', table: 'download_book_states');
    await database.execute('''
      CREATE TABLE IF NOT EXISTS download_book_states (
        userId INTEGER NOT NULL,
        bookUrl TEXT NOT NULL,
        autoChangeSource INTEGER NOT NULL DEFAULT 0,
        generation INTEGER NOT NULL DEFAULT 0,
        lockedSourceUrl TEXT,
        lockedSourceName TEXT,
        lockedBookUrl TEXT,
        lockedBookName TEXT,
        lockedBookAuthor TEXT,
        lockedBookTocUrl TEXT NOT NULL DEFAULT '',
        lockedBookVariable TEXT,
        lockedBookType INTEGER NOT NULL DEFAULT 0,
        triedSourceUrlsJson TEXT NOT NULL DEFAULT '[]',
        scoredSourceUrlsJson TEXT NOT NULL DEFAULT '[]',
        updatedAt INTEGER NOT NULL,
        PRIMARY KEY (userId, bookUrl),
        FOREIGN KEY (userId, bookUrl)
          REFERENCES books (userId, bookUrl) ON DELETE CASCADE
      )
    ''');
  }

  /// 新增与书架成员资格独立的阅读历史书籍和目录快照。
  Future<void> _createSchemaV8(Database database) async {
    logOperation(operation: 'CREATE_SCHEMA', table: 'reading_history');
    final Batch historyBatch = database.batch();
    historyBatch.execute('''
      CREATE TABLE IF NOT EXISTS reading_history_books (
        userId INTEGER NOT NULL,
        bookUrl TEXT NOT NULL DEFAULT '',
        tocUrl TEXT NOT NULL DEFAULT '',
        origin TEXT NOT NULL DEFAULT 'loc_book',
        originName TEXT NOT NULL DEFAULT '',
        name TEXT NOT NULL DEFAULT '',
        author TEXT NOT NULL DEFAULT '',
        kind TEXT,
        customTag TEXT,
        coverUrl TEXT,
        customCoverUrl TEXT,
        intro TEXT,
        customIntro TEXT,
        remark TEXT,
        charset TEXT,
        type INTEGER NOT NULL DEFAULT 0,
        `group` INTEGER NOT NULL DEFAULT 0,
        latestChapterTitle TEXT,
        latestChapterTime INTEGER NOT NULL DEFAULT 0,
        lastCheckTime INTEGER NOT NULL DEFAULT 0,
        lastCheckCount INTEGER NOT NULL DEFAULT 0,
        totalChapterNum INTEGER NOT NULL DEFAULT 0,
        durChapterTitle TEXT,
        durChapterIndex INTEGER NOT NULL DEFAULT 0,
        durChapterPos INTEGER NOT NULL DEFAULT 0,
        durChapterTime INTEGER NOT NULL DEFAULT 0,
        wordCount TEXT,
        canUpdate INTEGER NOT NULL DEFAULT 1,
        `order` INTEGER NOT NULL DEFAULT 0,
        originOrder INTEGER NOT NULL DEFAULT 0,
        variable TEXT,
        readConfig TEXT,
        syncTime INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (userId, bookUrl)
      )
    ''');
    historyBatch.execute(
      'CREATE INDEX IF NOT EXISTS index_reading_history_books_user_read_time '
      'ON reading_history_books (userId, durChapterTime DESC)',
    );
    historyBatch.execute('''
      CREATE TABLE IF NOT EXISTS reading_history_chapters (
        userId INTEGER NOT NULL,
        url TEXT NOT NULL,
        title TEXT NOT NULL,
        isVolume INTEGER NOT NULL,
        baseUrl TEXT NOT NULL,
        bookUrl TEXT NOT NULL,
        `index` INTEGER NOT NULL,
        isVip INTEGER NOT NULL,
        isPay INTEGER NOT NULL,
        resourceUrl TEXT,
        tag TEXT,
        wordCount TEXT,
        start INTEGER,
        end INTEGER,
        startFragmentId TEXT,
        endFragmentId TEXT,
        variable TEXT,
        reviewImg TEXT,
        PRIMARY KEY (userId, url, bookUrl),
        FOREIGN KEY (userId, bookUrl)
          REFERENCES reading_history_books (userId, bookUrl) ON DELETE CASCADE
      )
    ''');
    historyBatch.execute(
      'CREATE INDEX IF NOT EXISTS index_reading_history_chapters_user_book '
      'ON reading_history_chapters (userId, bookUrl)',
    );
    historyBatch.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS '
      'index_reading_history_chapters_user_book_index '
      'ON reading_history_chapters (userId, bookUrl, `index`)',
    );
    await historyBatch.commit(noResult: true);
  }

  /// 新增搜索 Cell 点击快照专用的详情书源候选表，保证候选数量和组内顺序可长期恢复。
  Future<void> _createSchemaV10(Database database) async {
    logOperation(
      operation: 'CREATE_SCHEMA',
      table: 'book_source_candidates',
    );
    await database.execute('''
      CREATE TABLE IF NOT EXISTS book_source_candidates (
        name TEXT NOT NULL,
        author TEXT NOT NULL,
        origin TEXT NOT NULL,
        bookUrl TEXT NOT NULL,
        originName TEXT NOT NULL,
        type INTEGER NOT NULL,
        kind TEXT,
        coverUrl TEXT,
        intro TEXT,
        wordCount TEXT,
        latestChapterTitle TEXT,
        tocUrl TEXT NOT NULL,
        time INTEGER NOT NULL,
        variable TEXT,
        originOrder INTEGER NOT NULL,
        chapterWordCountText TEXT,
        chapterWordCount INTEGER NOT NULL DEFAULT -1,
        respondTime INTEGER NOT NULL DEFAULT -1,
        sourceScore INTEGER NOT NULL DEFAULT 0,
        pinned INTEGER NOT NULL DEFAULT 0,
        candidateOrder INTEGER NOT NULL DEFAULT 0,
        capturedAt INTEGER NOT NULL,
        PRIMARY KEY (name, author, origin, bookUrl),
        FOREIGN KEY (origin)
          REFERENCES book_sources (bookSourceUrl) ON DELETE CASCADE
      )
    ''');
    await database.execute(
      'CREATE INDEX IF NOT EXISTS index_book_source_candidates_identity_order '
      'ON book_source_candidates (name, author, candidateOrder)',
    );
    await database.execute(
      'CREATE INDEX IF NOT EXISTS index_book_source_candidates_origin '
      'ON book_source_candidates (origin)',
    );
  }

  /// 新增用户级目录增量更新检查点，避免每次启动都从目录第一页完整遍历。
  Future<void> _createSchemaV11(Database database) async {
    logOperation(
      operation: 'CREATE_SCHEMA',
      table: 'toc_refresh_checkpoints',
    );
    await database.execute('''
      CREATE TABLE IF NOT EXISTS toc_refresh_checkpoints (
        userId INTEGER NOT NULL,
        bookUrl TEXT NOT NULL,
        sourceUrl TEXT NOT NULL,
        tocUrl TEXT NOT NULL,
        anchorPageUrl TEXT NOT NULL,
        visitedPageUrlsJson TEXT NOT NULL DEFAULT '[]',
        anchorChapterUrl TEXT NOT NULL,
        reverse INTEGER NOT NULL DEFAULT 0,
        chapterCount INTEGER NOT NULL,
        lastSuccessfulAt INTEGER NOT NULL,
        lastFullRefreshAt INTEGER NOT NULL,
        PRIMARY KEY (userId, bookUrl)
      )
    ''');
    await database.execute(
      'CREATE INDEX IF NOT EXISTS index_toc_refresh_checkpoints_user_success '
      'ON toc_refresh_checkpoints (userId, lastSuccessfulAt)',
    );
  }

  /// 将 v8 及更早的设备级书架数据破坏式升级为按用户复合主键的 v9 结构。
  ///
  /// 用户已确认旧书架、目录、分组、阅读历史和下载状态不认领给任何账号，因此本迁移
  /// 只按外键依赖顺序删除并重建表，不复制旧记录。
  Future<void> _rebuildUserScopedSchemaV9(Database database) async {
    logOperation(operation: 'REBUILD_SCHEMA', table: 'user_bookshelf');
    /// 删除旧外键图并创建用户作用域基础表的原子 DDL 批次。
    final Batch schemaBatch = database.batch();
    schemaBatch.execute('DROP TABLE IF EXISTS download_tasks');
    schemaBatch.execute('DROP TABLE IF EXISTS download_book_states');
    schemaBatch.execute('DROP TABLE IF EXISTS chapters');
    schemaBatch.execute('DROP TABLE IF EXISTS reading_history_chapters');
    schemaBatch.execute('DROP TABLE IF EXISTS reading_history_books');
    schemaBatch.execute('DROP TABLE IF EXISTS books');
    schemaBatch.execute('DROP TABLE IF EXISTS book_groups');
    schemaBatch.execute('''
      CREATE TABLE books (
        userId INTEGER NOT NULL,
        bookUrl TEXT NOT NULL DEFAULT '',
        tocUrl TEXT NOT NULL DEFAULT '',
        origin TEXT NOT NULL DEFAULT 'loc_book',
        originName TEXT NOT NULL DEFAULT '',
        name TEXT NOT NULL DEFAULT '',
        author TEXT NOT NULL DEFAULT '',
        kind TEXT,
        customTag TEXT,
        coverUrl TEXT,
        customCoverUrl TEXT,
        intro TEXT,
        customIntro TEXT,
        remark TEXT,
        charset TEXT,
        type INTEGER NOT NULL DEFAULT 0,
        `group` INTEGER NOT NULL DEFAULT 0,
        latestChapterTitle TEXT,
        latestChapterTime INTEGER NOT NULL DEFAULT 0,
        lastCheckTime INTEGER NOT NULL DEFAULT 0,
        lastCheckCount INTEGER NOT NULL DEFAULT 0,
        totalChapterNum INTEGER NOT NULL DEFAULT 0,
        durChapterTitle TEXT,
        durChapterIndex INTEGER NOT NULL DEFAULT 0,
        durChapterPos INTEGER NOT NULL DEFAULT 0,
        durChapterTime INTEGER NOT NULL DEFAULT 0,
        wordCount TEXT,
        canUpdate INTEGER NOT NULL DEFAULT 1,
        `order` INTEGER NOT NULL,
        originOrder INTEGER NOT NULL DEFAULT 0,
        variable TEXT,
        readConfig TEXT,
        syncTime INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (userId, bookUrl)
      )
    ''');
    schemaBatch.execute(
      'CREATE INDEX index_books_user_name_author '
      'ON books (userId, name, author)',
    );
    schemaBatch.execute(
      'CREATE INDEX index_books_user_read_time '
      'ON books (userId, durChapterTime DESC)',
    );
    schemaBatch.execute('''
      CREATE TABLE book_groups (
        userId INTEGER NOT NULL,
        groupId INTEGER NOT NULL,
        groupName TEXT NOT NULL,
        cover TEXT,
        `order` INTEGER NOT NULL DEFAULT 0,
        enableRefresh INTEGER NOT NULL DEFAULT 1,
        show INTEGER NOT NULL DEFAULT 1,
        bookSort INTEGER NOT NULL DEFAULT -1,
        isPrivate INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (userId, groupId)
      )
    ''');
    schemaBatch.execute(
      'CREATE INDEX index_book_groups_user_order '
      'ON book_groups (userId, `order`)',
    );
    schemaBatch.execute('''
      CREATE TABLE chapters (
        userId INTEGER NOT NULL,
        url TEXT NOT NULL,
        title TEXT NOT NULL,
        isVolume INTEGER NOT NULL,
        baseUrl TEXT NOT NULL,
        bookUrl TEXT NOT NULL,
        `index` INTEGER NOT NULL,
        isVip INTEGER NOT NULL,
        isPay INTEGER NOT NULL,
        resourceUrl TEXT,
        tag TEXT,
        wordCount TEXT,
        start INTEGER,
        end INTEGER,
        startFragmentId TEXT,
        endFragmentId TEXT,
        variable TEXT,
        reviewImg TEXT,
        PRIMARY KEY (userId, url, bookUrl),
        FOREIGN KEY (userId, bookUrl)
          REFERENCES books (userId, bookUrl) ON DELETE CASCADE
      )
    ''');
    schemaBatch.execute(
      'CREATE INDEX index_chapters_user_book '
      'ON chapters (userId, bookUrl)',
    );
    schemaBatch.execute(
      'CREATE UNIQUE INDEX index_chapters_user_book_index '
      'ON chapters (userId, bookUrl, `index`)',
    );
    await schemaBatch.commit(noResult: true);
    await _createSchemaV3(database);
    await _createSchemaV7(database);
    await _createSchemaV8(database);
  }

  /// 新增 Android 对齐的用户正文处理与标注表。
  Future<void> _createSchemaV5(Database database) async {
    logOperation(operation: 'CREATE_SCHEMA', table: 'book_content_processes');
    await database.execute('''
      CREATE TABLE IF NOT EXISTS book_content_processes (
        id TEXT NOT NULL,
        userId INTEGER NOT NULL DEFAULT -1,
        bookUrl TEXT NOT NULL,
        chapterIndex INTEGER,
        kind TEXT NOT NULL,
        stage TEXT NOT NULL DEFAULT 'content',
        target TEXT NOT NULL DEFAULT 'selection',
        anchorJson TEXT NOT NULL,
        actionJson TEXT NOT NULL,
        styleJson TEXT,
        source TEXT NOT NULL DEFAULT 'user',
        aiArtifactId TEXT,
        sourceContentHash TEXT,
        enabled INTEGER NOT NULL DEFAULT 1,
        sortOrder INTEGER NOT NULL DEFAULT 0,
        status INTEGER NOT NULL DEFAULT 1,
        schemaVersion INTEGER NOT NULL DEFAULT 1,
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL,
        PRIMARY KEY (id)
      )
    ''');
    await database.execute(
      'CREATE INDEX IF NOT EXISTS index_content_process_book_chapter_enabled_order '
      'ON book_content_processes (userId, bookUrl, chapterIndex, enabled, sortOrder)',
    );
    await database.execute(
      'CREATE INDEX IF NOT EXISTS index_content_process_book_kind '
      'ON book_content_processes (userId, bookUrl, kind)',
    );
    await database.execute(
      'CREATE INDEX IF NOT EXISTS index_content_process_ai_artifact '
      'ON book_content_processes (aiArtifactId)',
    );
  }

  /// 为书签、正文标注和替换规则补齐账号作用域；无法确认归属的旧记录保留在游客作用域。
  Future<void> _addUserScopeToReaderAssetsV12(Database database) async {
    logOperation(operation: 'ALTER_TABLE', table: 'reader_user_assets');
    await _addColumnIfMissing(
      database,
      table: 'bookmarks',
      column: 'userId',
      definition: 'INTEGER NOT NULL DEFAULT -1',
    );
    await _addColumnIfMissing(
      database,
      table: 'book_content_processes',
      column: 'userId',
      definition: 'INTEGER NOT NULL DEFAULT -1',
    );
    await _addColumnIfMissing(
      database,
      table: 'replace_rules',
      column: 'userId',
      definition: 'INTEGER NOT NULL DEFAULT -1',
    );
    final Batch migrationBatch = database.batch();
    migrationBatch.execute('DROP INDEX IF EXISTS index_bookmarks_bookName_bookAuthor');
    migrationBatch.execute(
      'CREATE INDEX IF NOT EXISTS index_bookmarks_user_bookName_bookAuthor '
      'ON bookmarks (userId, bookName, bookAuthor)',
    );
    migrationBatch.execute(
      'CREATE INDEX IF NOT EXISTS index_replace_rules_user_order '
      'ON replace_rules (userId, sortOrder)',
    );
    migrationBatch.execute(
      'CREATE INDEX IF NOT EXISTS index_content_process_user_book_chapter '
      'ON book_content_processes (userId, bookUrl, chapterIndex, status, sortOrder)',
    );
    await migrationBatch.commit(noResult: true);
  }

  /// 仅在旧表缺少目标列时执行追加，兼容从早期 Schema 一次升级到当前版本。
  Future<void> _addColumnIfMissing(
    Database database, {
    required String table,
    required String column,
    required String definition,
  }) async {
    final List<Map<String, Object?>> columns = await database.rawQuery(
      'PRAGMA table_info($table)',
    );
    final bool alreadyExists = columns.any(
      (Map<String, Object?> row) => row['name'] == column,
    );
    if (alreadyExists) {
      return;
    }
    await database.execute(
      'ALTER TABLE $table ADD COLUMN $column $definition',
    );
  }

  /// 关闭数据库连接和变更通知器；不会删除数据库文件。
  Future<void> close() async {
    /// 可能尚未创建的数据库打开任务。
    final Future<Database>? existingFuture = _databaseFuture;
    if (existingFuture != null) {
      /// 已打开的数据库连接。
      final Database openedDatabase = await existingFuture;
      _logger.info(
        tag: databaseLogTag,
        message: 'operation=CLOSE database=$databaseName',
      );
      await openedDatabase.close();
    }
    await changeNotifier.close();
  }
}
