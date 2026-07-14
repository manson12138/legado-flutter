/// 集中定义 M2 数据库表名，避免 DAO 使用不可搜索的散落字符串。
abstract final class DatabaseTables {
  /// 书架书表，对应 Android `books`。
  static const String books = 'books';
  /// 书源表，对应 Android `book_sources`。
  static const String bookSources = 'book_sources';
  /// 章节表，对应 Android `chapters`。
  static const String chapters = 'chapters';
  /// 书架分组表，对应 Android `book_groups`。
  static const String bookGroups = 'book_groups';
  /// 搜索结果缓存表，对应 Android `searchBooks`。
  static const String searchBooks = 'searchBooks';
  /// 书签表，对应 Android `bookmarks`。
  static const String bookmarks = 'bookmarks';
  /// Cookie 表，对应 Android `cookies`。
  static const String cookies = 'cookies';
  /// 通用缓存表，对应 Android `caches`。
  static const String caches = 'caches';
  /// 净化规则表，对应 Android `replace_rules`。
  static const String replaceRules = 'replace_rules';
}
