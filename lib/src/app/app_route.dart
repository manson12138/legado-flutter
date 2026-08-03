import '../domain/model/book.dart';
import '../domain/model/book_chapter.dart';
import '../domain/model/local_book.dart';
import 'reader_transition_spec.dart';

/// 集中声明应用内稳定路由名称，避免页面散落硬编码字符串。
abstract final class AppRoute {
  /// M1 欢迎页，也是当前应用启动路由。
  static const String welcome = '/';

  /// 应用“我的”页面；保留旧路由名称以兼容已有导航调用。
  static const String settings = '/settings';

  /// 设置中的沙盒日志管理页面。
  static const String logManagement = '/settings/logs';

  /// 设置中的独立崩溃报告管理页面。
  static const String crashReportManagement = '/settings/crash-reports';

  /// 跨书离线下载任务和缓存管理页面。
  static const String downloadManagement = '/downloads';

  /// 设置中的离线正文清除入口，复用下载管理的离线内容 PageView 页面。
  static const String offlineContentManagement = '/offline-content';

  /// “我的”页面中的“关于”页面。
  static const String about = '/settings/about';

  /// 设置中的 App 用户注册、登录和邀请码页面。
  static const String authentication = '/settings/authentication';

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

  /// M11 网络漫画专用阅读入口。
  static const String mangaReader = '/manga-reader';

  /// M11 网络书整书换源页面。
  static const String changeBookSource = '/books/change-source';

  /// 根据书籍主要内容类型返回统一阅读入口。
  ///
  /// 图片书籍进入漫画阅读器；其余当前支持类型继续进入既有阅读入口，PDF 仍由
  /// `BookReaderRoute` 内部按本地格式分流。
  static String readingRouteFor(Book book) {
    return book.isImage ? mangaReader : reader;
  }
}

/// 整书换源路由参数，只传递仍需从数据库重新确认的旧书主键。
final class ChangeBookSourceRouteArguments {
  /// 创建整书换源路由参数。
  const ChangeBookSourceRouteArguments({required this.bookUrl});

  /// 当前书架中的旧书籍稳定 URL。
  final String bookUrl;
}

/// Android 外部 TXT“打开方式”进入本地书导入页时使用的一次性参数。
final class LocalBookImportRouteArguments {
  /// 创建包含可立即读取临时副本和清理 token 的路由参数。
  const LocalBookImportRouteArguments({
    required this.file,
    required this.cleanupToken,
  });

  /// 原生层已经复制到应用 cache 的 TXT 候选。
  final LocalBookPickedFile file;

  /// 导入完成、失败或取消后交回原生层的一次性清理 token。
  final String cleanupToken;
}

/// 从“我的”等入口打开书架时指定首个可见分组。
final class BookshelfRouteArguments {
  /// 创建书架初始分组参数。
  const BookshelfRouteArguments({required this.initialGroupId});

  /// 书架 ViewModel 首帧使用的系统或用户分组 ID。
  final int initialGroupId;
}

/// 阅读器路由参数，支持从书架恢复进度或从目录指定章节进入。
final class ReaderRouteArguments {
  /// 创建阅读器路由参数。
  const ReaderRouteArguments({
    required this.bookUrl,
    this.initialChapterIndex,
    this.initialMessage,
    this.initialBook,
    this.initialIsInBookshelf,
    this.initialChapters = const <BookChapter>[],
    this.transitionSpec,
    this.entry = 'bookshelf',
  });

  /// 阅读器需要读取的本地稳定书籍 URL。
  final String bookUrl;

  /// 从详情目录进入阅读器时指定的初始章节索引；为空时使用既有阅读进度。
  final int? initialChapterIndex;

  /// 路由替换后需要由新阅读页面展示的一次性提示。
  final String? initialMessage;

  /// 书架、历史或详情入口已经持有的书籍快照。
  final Book? initialBook;

  /// 路由入口已经确认的书架成员事实；为空时阅读器在后台补查。
  final bool? initialIsInBookshelf;

  /// 尚未加入书架时由详情页传入的完整目录快照。
  final List<BookChapter> initialChapters;

  /// 本次进入使用的短生命周期封面转场参数；返回不复用旧 cell 几何。
  final ReaderTransitionSpec? transitionSpec;

  /// 匿名埋点允许的阅读入口：bookshelf、detail 或 history。
  final String entry;
}

/// 漫画阅读器路由参数，支持详情指定章节和书架/历史恢复已有进度。
final class MangaReaderRouteArguments {
  /// 创建漫画阅读路由参数。
  MangaReaderRouteArguments({
    required this.bookUrl,
    this.initialChapterIndex,
    this.initialMessage,
    this.initialBook,
    this.initialIsInBookshelf,
    List<BookChapter> initialChapters = const <BookChapter>[],
    this.transitionSpec,
    this.entry = 'bookshelf',
  }) : initialChapters = List<BookChapter>.unmodifiable(initialChapters);

  /// 漫画书籍稳定 URL。
  final String bookUrl;

  /// 详情目录指定的初始章节；为空时使用书籍已有进度。
  final int? initialChapterIndex;

  /// 新漫画路由首帧展示的一次性提示，例如整书换源结果。
  final String? initialMessage;

  /// 详情、书架或历史入口持有的图片书籍快照。
  final Book? initialBook;

  /// 入口已经确认的书架成员事实；历史入口允许为空。
  final bool? initialIsInBookshelf;

  /// 尚未加入书架时由详情页传入的完整目录快照。
  final List<BookChapter> initialChapters;

  /// 本次进入使用的一次性封面转场参数，后续漫画转场可选择消费。
  final ReaderTransitionSpec? transitionSpec;

  /// 匿名入口枚举：`bookshelf`、`detail` 或 `history`。
  final String entry;
}
