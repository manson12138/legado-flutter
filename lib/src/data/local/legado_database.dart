import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import '../../help/logging/app_logger.dart';
import 'database_change_notifier.dart';

/// 管理 Flutter 独立 SQLite 数据库 v2 的打开、迁移、事务和释放。
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
  static const int schemaVersion = 4;

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
      },
      onUpgrade: (Database upgradedDatabase, int oldVersion, int newVersion) async {
        if (oldVersion < 2) {
          logOperation(operation: 'ALTER_TABLE', table: 'book_sources');
          await upgradedDatabase.execute(
            'ALTER TABLE book_sources ADD COLUMN extraFieldsJson TEXT',
          );
        }
        if (oldVersion < 3) {
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
        PRIMARY KEY (bookUrl)
      )
    ''');
    schemaBatch.execute(
      'CREATE INDEX index_books_name_author ON books (name, author)',
    );
    schemaBatch.execute(
      'CREATE INDEX index_books_durChapterTime ON books (durChapterTime)',
    );

    schemaBatch.execute('''
      CREATE TABLE book_groups (
        groupId INTEGER NOT NULL,
        groupName TEXT NOT NULL,
        cover TEXT,
        `order` INTEGER NOT NULL DEFAULT 0,
        enableRefresh INTEGER NOT NULL DEFAULT 1,
        show INTEGER NOT NULL DEFAULT 1,
        bookSort INTEGER NOT NULL DEFAULT -1,
        isPrivate INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (groupId)
      )
    ''');

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
        PRIMARY KEY (url, bookUrl),
        FOREIGN KEY (bookUrl) REFERENCES books (bookUrl) ON DELETE CASCADE
      )
    ''');
    schemaBatch.execute(
      'CREATE INDEX index_chapters_bookUrl ON chapters (bookUrl)',
    );
    schemaBatch.execute(
      'CREATE UNIQUE INDEX index_chapters_bookUrl_index '
      'ON chapters (bookUrl, `index`)',
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
      'CREATE INDEX index_bookmarks_bookName_bookAuthor '
      'ON bookmarks (bookName, bookAuthor)',
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
      'CREATE INDEX index_replace_rules_id ON replace_rules (id)',
    );

    await schemaBatch.commit(noResult: true);
  }

  /// 新增离线下载队列表；只记录队列可见状态，实际正文仍写入 `caches` 表。
  Future<void> _createSchemaV3(Database database) async {
    logOperation(operation: 'CREATE_SCHEMA', table: 'download_tasks');
    await database.execute('''
      CREATE TABLE IF NOT EXISTS download_tasks (
        bookUrl TEXT NOT NULL,
        chapterIndex INTEGER NOT NULL,
        status TEXT NOT NULL,
        retryCount INTEGER NOT NULL DEFAULT 0,
        updatedAt INTEGER NOT NULL,
        PRIMARY KEY (bookUrl, chapterIndex),
        FOREIGN KEY (bookUrl) REFERENCES books (bookUrl) ON DELETE CASCADE
      )
    ''');
    await database.execute(
      'CREATE INDEX IF NOT EXISTS index_download_tasks_bookUrl ON download_tasks (bookUrl)',
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
