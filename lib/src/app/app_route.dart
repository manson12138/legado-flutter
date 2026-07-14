/// 集中声明应用内稳定路由名称，避免页面散落硬编码字符串。
abstract final class AppRoute {
  /// M1 欢迎页，也是当前应用启动路由。
  static const String welcome = '/';

  /// M5 书源管理页面。
  static const String bookSourceManagement = '/book-sources';

  /// M06 多书源搜索页面。
  static const String search = '/search';

  /// M06 书籍详情与目录页面。
  static const String bookInfo = '/book-info';

  /// M07 实时书架页面。
  static const String bookshelf = '/bookshelf';

  /// M08.1 本地书文件选择、解析和加入书架页面。
  static const String localBookImport = '/local-books/import';

  /// M08 阅读器预留入口；M07 只定义稳定导航参数。
  static const String reader = '/reader';
}
