/// 集中定义 M2 数据库表名，避免 DAO 使用不可搜索的散落字符串。
abstract final class DatabaseTables {
  /// 按 `(userId, bookUrl)` 隔离的书架书表，对应 Android `books`。
  static const String books = 'books';
  /// 书源表，对应 Android `book_sources`。
  static const String bookSources = 'book_sources';
  /// 按用户与书籍复合外键隔离的章节表，对应 Android `chapters`。
  static const String chapters = 'chapters';
  /// 按用户隔离的阅读历史书籍快照表；成员资格与书架 `books` 完全独立。
  static const String readingHistoryBooks = 'reading_history_books';
  /// 按用户隔离的阅读历史目录快照表；供未加入书架的书继续恢复阅读。
  static const String readingHistoryChapters = 'reading_history_chapters';
  /// 按 `(userId, groupId)` 隔离的书架分组表，对应 Android `book_groups`。
  static const String bookGroups = 'book_groups';
  /// 搜索结果缓存表，对应 Android `searchBooks`。
  static const String searchBooks = 'searchBooks';
  /// 搜索 Cell 点击时整组覆盖、供详情页只读恢复的精确书源候选表。
  static const String bookSourceCandidates = 'book_source_candidates';
  /// 书签表，对应 Android `bookmarks`。
  static const String bookmarks = 'bookmarks';
  /// Cookie 表，对应 Android `cookies`。
  static const String cookies = 'cookies';
  /// 通用缓存表，对应 Android `caches`。
  static const String caches = 'caches';
  /// 净化规则表，对应 Android `replace_rules`。
  static const String replaceRules = 'replace_rules';
  /// 按用户隔离的离线下载队列表，Flutter 新增，Android 无对应持久表。
  static const String downloadTasks = 'download_tasks';
  /// 按用户隔离的每本书下载批次与自动换源状态，Flutter 新增。
  static const String downloadBookStates = 'download_book_states';
  /// 用户正文处理与标注表，对应 Android `book_content_processes`。
  static const String bookContentProcesses = 'book_content_processes';
}
