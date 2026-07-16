/// 集中声明应用内稳定路由名称，避免页面散落硬编码字符串。
abstract final class AppRoute {
  /// M1 欢迎页，也是当前应用启动路由。
  static const String welcome = '/';

  /// 应用设置页面。
  static const String settings = '/settings';

  /// 设置中的沙盒日志管理页面。
  static const String logManagement = '/settings/logs';

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

  /// M11 网络书整书换源页面。
  static const String changeBookSource = '/books/change-source';
}

/// 整书换源路由参数，只传递仍需从数据库重新确认的旧书主键。
final class ChangeBookSourceRouteArguments {
  /// 创建整书换源路由参数。
  const ChangeBookSourceRouteArguments({required this.bookUrl});

  /// 当前书架中的旧书籍稳定 URL。
  final String bookUrl;
}

/// 阅读器路由参数，支持从书架恢复进度或从目录指定章节进入。
final class ReaderRouteArguments {
  /// 创建阅读器路由参数。
  const ReaderRouteArguments({
    required this.bookUrl,
    this.initialChapterIndex,
    this.initialMessage,
  });

  /// 阅读器需要读取的本地稳定书籍 URL。
  final String bookUrl;

  /// 从详情目录进入阅读器时指定的初始章节索引；为空时使用既有阅读进度。
  final int? initialChapterIndex;

  /// 路由替换后需要由新阅读页面展示的一次性提示。
  final String? initialMessage;
}
