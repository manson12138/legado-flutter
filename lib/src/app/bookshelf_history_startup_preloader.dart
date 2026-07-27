import '../data/dao/book_dao.dart';
import '../data/dao/book_group_dao.dart';
import '../data/dao/reading_history_dao.dart';
import '../domain/model/book.dart';
import '../domain/model/book_group.dart';
import 'current_user_scope.dart';

/// 保存登录后进入主界面前读取的书架、分组和阅读历史首个本地快照。
///
/// 快照仅用于消除页面首次订阅 SQLite 流前的等待；后续变化仍由各页面既有的数据库流提供。
final class BookshelfHistoryStartupSnapshot {
  /// 创建不可变的本地首快照。
  BookshelfHistoryStartupSnapshot({
    required this.userId,
    required List<Book> bookshelfBooks,
    required List<BookGroup> bookGroups,
    required List<Book> readingHistoryBooks,
  })  : bookshelfBooks = List<Book>.unmodifiable(bookshelfBooks),
        bookGroups = List<BookGroup>.unmodifiable(bookGroups),
        readingHistoryBooks = List<Book>.unmodifiable(readingHistoryBooks);

  /// 生成本快照的登录用户 ID。
  final int userId;

  /// 书架成员快照。
  final List<Book> bookshelfBooks;

  /// 用户书架分组快照。
  final List<BookGroup> bookGroups;

  /// 阅读历史书籍快照。
  final List<Book> readingHistoryBooks;
}

/// 在游客或已登录用户进入主界面前单飞读取当前作用域的本地书架与阅读历史。
///
/// 不执行书源网络请求、目录刷新、书源导入或下载恢复。
final class BookshelfHistoryStartupPreloader {
  /// 创建只依赖本地 DAO 的启动期预加载器。
  BookshelfHistoryStartupPreloader({
    required BookDao bookDao,
    required BookGroupDao bookGroupDao,
    required ReadingHistoryDao readingHistoryDao,
    required CurrentUserScope currentUserScope,
  })  : _bookDao = bookDao,
        _bookGroupDao = bookGroupDao,
        _readingHistoryDao = readingHistoryDao,
        _currentUserScope = currentUserScope;

  /// 本地书架 DAO。
  final BookDao _bookDao;

  /// 本地书架分组 DAO。
  final BookGroupDao _bookGroupDao;

  /// 本地阅读历史 DAO。
  final ReadingHistoryDao _readingHistoryDao;

  /// 登录用户作用域，用于捕获用户 ID 并拒绝旧会话预加载结果。
  final CurrentUserScope _currentUserScope;

  /// 已完成的内存快照；任务未成功完成前保持为空。
  BookshelfHistoryStartupSnapshot? _snapshot;

  /// 当前唯一的预加载任务，避免重复查询和重复打开数据库。
  Future<BookshelfHistoryStartupSnapshot>? _preloadFuture;

  /// 当前单飞任务所属的用户 ID。
  int? _preloadUserId;

  /// 当前单飞任务创建时捕获的用户作用域代次。
  int? _preloadGeneration;

  /// 已完成的快照，供随后创建的页面同步消费。
  BookshelfHistoryStartupSnapshot? get snapshot {
    final BookshelfHistoryStartupSnapshot? snapshot = _snapshot;
    if (snapshot == null ||
        snapshot.userId != _currentUserScope.userId.value) {
      return null;
    }
    return snapshot;
  }

  /// 启动或复用登录后的本地预加载任务。
  Future<BookshelfHistoryStartupSnapshot> preload() {
    final int userId = _currentUserScope.requireUserId();
    final int generation = _currentUserScope.generation;
    final Future<BookshelfHistoryStartupSnapshot>? existingFuture =
        _preloadFuture;
    if (existingFuture != null &&
        _preloadUserId == userId &&
        _preloadGeneration == generation) {
      return existingFuture;
    }
    final Future<BookshelfHistoryStartupSnapshot> preloadFuture =
        _loadSnapshot(userId, generation);
    _preloadFuture = preloadFuture;
    _preloadUserId = userId;
    _preloadGeneration = generation;
    return preloadFuture;
  }

  /// 清除旧用户的完成快照与单飞句柄；已开始的查询完成后也不会发布结果。
  void invalidate() {
    _snapshot = null;
    _preloadFuture = null;
    _preloadUserId = null;
    _preloadGeneration = null;
  }

  /// 并行读取三类独立本地首快照，并在成功后原子发布给页面。
  Future<BookshelfHistoryStartupSnapshot> _loadSnapshot(
    int userId,
    int generation,
  ) async {
    final List<Object> results = await Future.wait<Object>(<Future<Object>>[
      _bookDao.getAll(userId),
      _bookGroupDao.getAll(userId),
      _readingHistoryDao.getAllBooks(userId),
    ]);
    if (!_currentUserScope.matches(
      expectedUserId: userId,
      expectedGeneration: generation,
    )) {
      throw StateError('登录用户已切换，旧书架预加载结果已丢弃');
    }
    final BookshelfHistoryStartupSnapshot snapshot =
        BookshelfHistoryStartupSnapshot(
      userId: userId,
      bookshelfBooks: results[0] as List<Book>,
      bookGroups: results[1] as List<BookGroup>,
      readingHistoryBooks: results[2] as List<Book>,
    );
    _snapshot = snapshot;
    return snapshot;
  }
}
