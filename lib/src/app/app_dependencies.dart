import 'package:dio/dio.dart';
import 'package:flutter/services.dart';

import '../api/cookie/cookie_manager.dart';
import '../api/cookie/flutter_webview_cookie_bridge.dart';
import '../api/http/dio_http_client.dart';
import '../api/http/app_dio_log_interceptor.dart';
import '../api/http/http_contract.dart';
import '../api/http/response_decoder.dart';
import '../api/http/source_url_resolver.dart';
import '../api/js/java_compatibility_bridge.dart';
import '../api/js/js_engine.dart';
import '../api/js/js_engine_pool.dart';
import '../api/js/jsf_engine.dart';
import '../api/js/legado_script_bridge.dart';
import '../api/js/script_context.dart';
import '../api/js/webview_script_bridge.dart';
import '../data/dao/book_chapter_dao.dart';
import '../data/dao/book_group_dao.dart';
import '../data/dao/book_dao.dart';
import '../data/dao/book_source_dao.dart';
import '../data/dao/cookie_dao.dart';
import '../data/dao/cache_dao.dart';
import '../data/dao/bookmark_dao.dart';
import '../data/dao/replace_rule_dao.dart';
import '../data/dao/download_task_dao.dart';
import '../data/local/legado_database.dart';
import '../data/model/book_source_import_decoder.dart';
import '../data/repository/book_repository.dart';
import '../data/repository/book_group_repository.dart';
import '../data/repository/book_source_repository.dart';
import '../data/repository/download_repository.dart';
import '../data/repository/search_history_repository.dart';
import '../data/repository/reader_repository.dart';
import '../domain/gateway/bookmark_gateway.dart';
import '../domain/gateway/bookshelf_gateway.dart';
import '../domain/gateway/book_group_gateway.dart';
import '../domain/gateway/book_source_gateway.dart';
import '../domain/gateway/chapter_gateway.dart';
import '../domain/gateway/reading_progress_gateway.dart';
import '../domain/gateway/reader_cache_gateway.dart';
import '../domain/gateway/replace_rule_gateway.dart';
import '../domain/gateway/search_history_gateway.dart';
import '../domain/usecase/add_book_to_bookshelf_use_case.dart';
import '../domain/usecase/delete_books_from_bookshelf_use_case.dart';
import '../domain/usecase/create_bookshelf_group_use_case.dart';
import '../domain/usecase/change_book_source_use_case.dart';
import '../domain/usecase/import_book_sources_use_case.dart';
import '../domain/usecase/load_book_chapters_use_case.dart';
import '../domain/usecase/restore_reading_progress_use_case.dart';
import '../domain/usecase/replace_books_group_use_case.dart';
import '../domain/usecase/resolve_book_shelf_state_use_case.dart';
import '../domain/usecase/save_book_chapters_use_case.dart';
import '../domain/usecase/save_reading_progress_use_case.dart';
import '../help/logging/app_logger.dart';
import '../help/logging/app_log_manager.dart';
import '../model/web_book/standard_source_parser.dart';
import '../model/web_book/standard_source_service.dart';
import '../model/web_book/book_detail_service.dart';
import '../model/web_book/book_search_coordinator.dart';
import '../model/web_book/change_chapter_source_coordinator.dart';
import '../model/reader/download_coordinator.dart';
import '../model/web_book/change_source_coordinator.dart';
import '../model/bookshelf/bookshelf_refresh_coordinator.dart';
import '../model/book_source/book_source_import_text_resolver.dart';
import '../model/analyze_rule/legado_javascript_service.dart';
import '../model/reader/read_book_coordinator.dart';
import '../model/reader/reader_text_processor.dart';
import '../model/local_book/epub_local_book_parser.dart';
import '../model/local_book/local_book_parser.dart';
import '../model/local_book/local_book_service.dart';
import '../model/local_book/local_book_storage.dart';
import '../model/local_book/txt_local_book_parser.dart';
import '../model/local_book/pdf_local_book_parser.dart';
import '../model/local_book/umd_local_book_parser.dart';
import 'default_book_source_bootstrapper.dart';

/// 保存应用级共享依赖的组合根容器。
///
/// M1 使用显式构造注入，避免在业务代码中访问全局 Service Locator；后续新增依赖时仍应
/// 由本容器创建，再通过构造参数传给路由、ViewModel、UseCase 或 Repository。
final class AppDependencies {
  /// 创建不可变的应用依赖容器。
  const AppDependencies({
    required this.logger,
    required this.logManager,
    required this.bookSourceGateway,
    required this.bookshelfGateway,
    required this.bookGroupGateway,
    required this.chapterGateway,
    required this.readingProgressGateway,
    required this.bookmarkGateway,
    required this.replaceRuleGateway,
    required this.readerCacheGateway,
    required this.searchHistoryGateway,
    required this.cookieManager,
    required this.defaultBookSourceBootstrapper,
    required this.importBookSources,
    required this.bookSourceImportTextResolver,
    required this.addBookToBookshelf,
    required this.deleteBooksFromBookshelf,
    required this.createBookshelfGroup,
    required this.changeBookSource,
    required this.replaceBooksGroup,
    required this.loadBookChapters,
    required this.saveBookChapters,
    required this.saveReadingProgress,
    required this.restoreReadingProgress,
    required this.standardBookSourceService,
    required this.bookDetailService,
    required this.javaScriptService,
    required this.localBookImportCoordinator,
    required this.localBookContentService,
    required this.localBookStorage,
    required this.downloadCoordinator,
  });

  /// 根据启动阶段已经创建的基础设施实例组装应用依赖。
  factory AppDependencies.create({
    required AppLogger logger,
    required AppLogManager logManager,
  }) {
    /// M2 Flutter 独立数据库，首次数据操作时惰性打开。
    final LegadoDatabase database = LegadoDatabase(logger: logger);
    /// 书籍表 DAO，只在数据组合根内创建，不向 UI 暴露。
    final BookDao bookDao = BookDao(database);
    /// 章节表 DAO，只在数据组合根内创建，不向 UI 暴露。
    final BookChapterDao chapterDao = BookChapterDao(database);
    /// 书架分组 DAO，只在数据组合根内创建。
    final BookGroupDao bookGroupDao = BookGroupDao(database);
    /// 书源表 DAO，只在数据组合根内创建，不向 UI 暴露。
    final BookSourceDao bookSourceDao = BookSourceDao(database);
    /// Cookie 表 DAO，只允许统一 Cookie 管理器访问。
    final CookieDao cookieDao = CookieDao(database);
    /// 通用缓存 DAO，供 M4 脚本 cache API 复用。
    final CacheDao cacheDao = CacheDao(database);
    /// 阅读书签 DAO，只由 ReaderRepository 访问。
    final BookmarkDao bookmarkDao = BookmarkDao(database);
    /// 正文替换规则 DAO，只由 ReaderRepository 访问。
    final ReplaceRuleDao replaceRuleDao = ReplaceRuleDao(database);
    /// 离线下载队列 DAO，只由 DownloadRepository 访问。
    final DownloadTaskDao downloadTaskDao = DownloadTaskDao(database);
    /// 书籍、目录和进度共用的 Repository 实现。
    final BookRepository bookRepository = BookRepository(
      database,
      bookDao,
      chapterDao,
    );
    /// M07 用户分组 Repository。
    final BookGroupRepository bookGroupRepository = BookGroupRepository(bookGroupDao);
    /// 书源 Repository，组合 DAO 与不可信 JSON 解码边界。
    final BookSourceRepository bookSourceRepository = BookSourceRepository(
      database,
      bookSourceDao,
      cacheDao,
      const BookSourceImportDecoder(),
    );
    /// 统一 Dio 实例；随后安装会遮盖认证信息的应用日志拦截器。
    final Dio dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        sendTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 60),
      ),
    );
    /// 全部 Dio 请求、响应和异常统一写入网络专用 Tag。
    dio.interceptors.add(AppDioLogInterceptor(logger: logger));
    /// Android/iOS 共用的 WebView Cookie Store 适配器。
    final FlutterWebViewCookieBridge webViewCookieBridge = FlutterWebViewCookieBridge();
    /// 共享 Cookie 管理器；普通 HTTP、登录 WebView 和页面脚本共用同一持久事实。
    final LegadoCookieManager cookieManager = LegadoCookieManager(
      cookieDao,
      webViewCookieBridge,
    );
    /// 统一 HTTP 实现。
    final UnifiedHttpClient httpClient = DioUnifiedHttpClient(dio, cookieManager);
    /// 扫码书源中的 HTTP/HTTPS 地址下载与字符集解码服务。
    final BookSourceImportTextResolver bookSourceImportTextResolver =
        BookSourceImportTextResolver(
          httpClient: httpClient,
          responseDecoder: const HttpResponseDecoder(),
          logger: logger,
        );
    /// M10 Android/iOS 共用的受控页面 WebView 脚本桥。
    final FlutterWebViewScriptBridge webViewScriptBridge = FlutterWebViewScriptBridge(
      cookieManager,
      webViewCookieBridge,
    );
    /// M4 Legado、网络、Cookie、缓存与 Java 白名单统一桥。
    final LegadoScriptBridge scriptBridge = LegadoScriptBridge(
      httpClient,
      const HttpResponseDecoder(),
      const SourceUrlResolver(),
      cookieManager,
      cacheDao,
      const JavaCompatibilityBridge(),
      webViewScriptBridge,
    );
    /// 按书源隔离的 QuickJS 引擎池。
    final JsEnginePool jsEnginePool = JsEnginePool(JsfJsEngineFactory(scriptBridge));
    /// M4 规则层 JavaScript 统一服务。
    final LegadoJavaScriptService javaScriptService = LegadoJavaScriptService(jsEnginePool);
    /// 普通规则保持 isolate 快路径，脚本规则按 Android 顺序接入 M4 QuickJS 的四段链路服务。
    final StandardBookSourceService standardBookSourceService = StandardBookSourceService(
      httpClient,
      const HttpResponseDecoder(),
      const SourceUrlResolver(),
      StandardBookSourceParser(javaScriptService: javaScriptService),
      javaScriptService,
      logger,
    );
    /// M06 搜索历史 Repository，通过缓存表保持独立数据边界。
    final SearchHistoryRepository searchHistoryRepository = SearchHistoryRepository(cacheDao);
    /// M08 正文缓存、稳定锚点、显示配置、书签和替换规则 Repository。
    final ReaderRepository readerRepository = ReaderRepository(
      cacheDao,
      bookmarkDao,
      replaceRuleDao,
    );
    /// M08.1 应用私有本地书副本管理器。
    const LocalBookStorage localBookStorage = LocalBookStorage();
    /// M08.1 当前已经真实实现的 TXT 与 EPUB 解析器注册表。
    final LocalBookParserRegistry localBookParserRegistry = LocalBookParserRegistry(
      const <LocalBookParser>[
        TxtLocalBookParser(),
        EpubLocalBookParser(),
        PdfLocalBookParser(),
        UmdLocalBookParser(),
      ],
    );
    /// M08.1 为阅读器提供目标章节正文的本地内容服务。
    final LocalBookContentService localBookContentService = LocalBookContentService(
      storage: localBookStorage,
      parserRegistry: localBookParserRegistry,
    );
    /// 按 Android 语义解析书籍是否已经入架或存在同名同作者冲突。
    final ResolveBookShelfStateUseCase resolveBookShelfState =
        ResolveBookShelfStateUseCase(bookRepository);
    /// 供详情新增、本地书更新和书架刷新复用的书籍保存业务动作。
    final AddBookToBookshelfUseCase addBookToBookshelf =
        AddBookToBookshelfUseCase(bookRepository, resolveBookShelfState);
    /// M08.1 编排文件复制、解析和书架事务的导入协调器。
    final LocalBookImportCoordinator localBookImportCoordinator = LocalBookImportCoordinator(
      storage: localBookStorage,
      parserRegistry: localBookParserRegistry,
      bookshelfGateway: bookRepository,
      addBook: addBookToBookshelf,
    );
    /// M06 普通书源详情与目录编排服务。
    final BookDetailService bookDetailService = BookDetailService(
      sourceGateway: bookSourceRepository,
      standardService: standardBookSourceService,
      logger: logger,
    );
    /// 书源 JSON 导入 UseCase，供管理页面和启动内置书源导入共同复用。
    final ImportBookSourcesUseCase importBookSources =
        ImportBookSourcesUseCase(bookSourceRepository);
    /// 离线下载队列持久化 Repository。
    final DownloadRepository downloadRepository = DownloadRepository(downloadTaskDao);
    /// App 级单例离线下载队列调度器；由本组合根长期持有，跨页面继续运行。
    final DownloadCoordinator downloadCoordinator = DownloadCoordinator(
      downloadGateway: downloadRepository,
      chapterGateway: bookRepository,
      bookshelfGateway: bookRepository,
      bookSourceGateway: bookSourceRepository,
      cacheGateway: readerRepository,
      standardService: standardBookSourceService,
      cancellationTokenFactory: () => DioHttpCancellationToken(),
      logger: logger,
    );

    return AppDependencies(
      logger: logger,
      logManager: logManager,
      bookSourceGateway: bookSourceRepository,
      bookshelfGateway: bookRepository,
      bookGroupGateway: bookGroupRepository,
      chapterGateway: bookRepository,
      readingProgressGateway: bookRepository,
      bookmarkGateway: readerRepository,
      replaceRuleGateway: readerRepository,
      readerCacheGateway: readerRepository,
      searchHistoryGateway: searchHistoryRepository,
      cookieManager: cookieManager,
      defaultBookSourceBootstrapper: DefaultBookSourceBootstrapper(
        sourceGateway: bookSourceRepository,
        importBookSources: importBookSources,
        assetBundle: rootBundle,
        logger: logger,
      ),
      importBookSources: importBookSources,
      bookSourceImportTextResolver: bookSourceImportTextResolver,
      addBookToBookshelf: addBookToBookshelf,
      deleteBooksFromBookshelf: DeleteBooksFromBookshelfUseCase(bookRepository),
      createBookshelfGroup: CreateBookshelfGroupUseCase(bookGroupRepository),
      changeBookSource: ChangeBookSourceUseCase(bookRepository, readerRepository),
      replaceBooksGroup: ReplaceBooksGroupUseCase(bookRepository),
      loadBookChapters: LoadBookChaptersUseCase(bookRepository),
      saveBookChapters: SaveBookChaptersUseCase(bookRepository),
      saveReadingProgress: SaveReadingProgressUseCase(bookRepository),
      restoreReadingProgress: RestoreReadingProgressUseCase(bookRepository),
      standardBookSourceService: standardBookSourceService,
      bookDetailService: bookDetailService,
      javaScriptService: javaScriptService,
      localBookImportCoordinator: localBookImportCoordinator,
      localBookContentService: localBookContentService,
      localBookStorage: localBookStorage,
      downloadCoordinator: downloadCoordinator,
    );
  }

  /// 应用统一日志接口，页面和领域代码只依赖抽象而不依赖输出实现。
  final AppLogger logger;

  /// 设置页使用的日志文件查看、删除和 ADB 回显能力。
  final AppLogManager logManager;

  /// 书源领域边界，供后续网络和规则 UseCase 通过构造参数使用。
  final BookSourceGateway bookSourceGateway;

  /// 书架领域边界，供后续组合根创建书架相关 UseCase。
  final BookshelfGateway bookshelfGateway;

  /// 书架用户分组领域边界。
  final BookGroupGateway bookGroupGateway;

  /// 目录领域边界，供后续规则和阅读 UseCase 读取或保存目录。
  final ChapterGateway chapterGateway;

  /// 阅读进度领域边界，供后续同步能力组合使用。
  final ReadingProgressGateway readingProgressGateway;

  /// 阅读器书签持久化边界。
  final BookmarkGateway bookmarkGateway;

  /// 阅读器正文替换规则读取边界。
  final ReplaceRuleGateway replaceRuleGateway;

  /// 阅读器正文缓存、稳定锚点和显示配置边界。
  final ReaderCacheGateway readerCacheGateway;

  /// 搜索历史持久化边界。
  final SearchHistoryGateway searchHistoryGateway;

  /// 普通 HTTP、登录 WebView 与 JavaScript 页面请求共用的统一 Cookie 管理器。
  final LegadoCookieManager cookieManager;

  /// 启动期按需导入 Flutter assets 内置书源的业务协调器。
  final DefaultBookSourceBootstrapper defaultBookSourceBootstrapper;

  /// 书源 JSON 导入业务动作。
  final ImportBookSourcesUseCase importBookSources;

  /// 扫码书源 JSON 或远程书源地址的只读解析服务。
  final BookSourceImportTextResolver bookSourceImportTextResolver;

  /// 将书籍和目录原子加入书架的业务动作。
  final AddBookToBookshelfUseCase addBookToBookshelf;

  /// 批量删除书架书籍 UseCase。
  final DeleteBooksFromBookshelfUseCase deleteBooksFromBookshelf;

  /// 创建用户书架分组 UseCase。
  final CreateBookshelfGroupUseCase createBookshelfGroup;

  /// M11 原子替换书籍主键、目录并迁移用户阅读事实的 UseCase。
  final ChangeBookSourceUseCase changeBookSource;

  /// 批量替换书籍分组 UseCase。
  final ReplaceBooksGroupUseCase replaceBooksGroup;

  /// 读取持久化目录的业务动作。
  final LoadBookChaptersUseCase loadBookChapters;

  /// 原子替换完整目录的业务动作。
  final SaveBookChaptersUseCase saveBookChapters;

  /// 保存阅读章节和字符位置的业务动作。
  final SaveReadingProgressUseCase saveReadingProgress;

  /// 恢复最后阅读位置的业务动作。
  final RestoreReadingProgressUseCase restoreReadingProgress;

  /// M3 统一网络与普通规则的搜索、详情、目录和正文入口。
  final StandardBookSourceService standardBookSourceService;

  /// M06 详情与目录业务编排服务。
  final BookDetailService bookDetailService;

  /// M08.1 本地书文件导入、解析和书架事务协调器。
  final LocalBookImportCoordinator localBookImportCoordinator;

  /// M08.1 本地书目标章节正文读取服务。
  final LocalBookContentService localBookContentService;

  /// M08.1 本地书应用私有副本路径解析服务。
  final LocalBookStorage localBookStorage;

  /// App 级单例离线下载队列调度器；关闭下载面板或退出阅读器后仍继续运行，
  /// 与其余按页面生命周期创建的 `create*Coordinator()` 工厂方法不同。
  final DownloadCoordinator downloadCoordinator;

  /// 创建页面生命周期独占的受控多书源搜索协调器。
  BookSearchCoordinator createBookSearchCoordinator() {
    return BookSearchCoordinator(
      sourceGateway: bookSourceGateway,
      standardService: standardBookSourceService,
      cancellationTokenFactory: createHttpCancellationToken,
      logger: logger,
    );
  }

  /// 创建页面生命周期独占的整书换源候选协调器。
  ChangeSourceCoordinator createChangeSourceCoordinator() {
    return ChangeSourceCoordinator(
      searchCoordinator: createBookSearchCoordinator(),
      detailService: bookDetailService,
      logger: logger,
    );
  }

  /// 创建面板生命周期独占的单章换源候选协调器；书籍级搜索基础设施与整书换源共用。
  ChangeChapterSourceCoordinator createChangeChapterSourceCoordinator() {
    return ChangeChapterSourceCoordinator(
      searchCoordinator: createBookSearchCoordinator(),
      detailService: bookDetailService,
      standardService: standardBookSourceService,
      logger: logger,
    );
  }

  /// 创建页面生命周期独占的书架目录刷新协调器。
  BookshelfRefreshCoordinator createBookshelfRefreshCoordinator() {
    return BookshelfRefreshCoordinator(
      detailService: bookDetailService,
      saveBook: addBookToBookshelf,
      cancellationTokenFactory: createHttpCancellationToken,
    );
  }

  /// 创建页面生命周期独占的正文缓存、处理、取消和预加载协调器。
  ReadBookCoordinator createReadBookCoordinator() {
    return ReadBookCoordinator(
      sourceGateway: bookSourceGateway,
      replaceRuleGateway: replaceRuleGateway,
      cacheGateway: readerCacheGateway,
      standardService: standardBookSourceService,
      localBookContentService: localBookContentService,
      textProcessor: const ReaderTextProcessor(),
      cancellationTokenFactory: createHttpCancellationToken,
      logger: logger,
    );
  }

  /// M4 JavaScript 规则执行入口；具体 JSF 类型不向业务层暴露。
  final LegadoJavaScriptService javaScriptService;

  /// 创建可由 ViewModel 生命周期持有并取消的网络令牌。
  HttpCancellationToken createHttpCancellationToken() {
    return DioHttpCancellationToken();
  }

  /// 创建由 ViewModel 生命周期持有的 JavaScript 取消控制器。
  JsCancellationController createJsCancellationController() {
    return JsCancellationController();
  }

  /// 创建同时覆盖 QuickJS 与宿主 HTTP 的组合取消控制器。
  LegadoScriptCancellationController createScriptCancellationController() {
    return LegadoScriptCancellationController(
      js: JsCancellationController(),
      http: DioHttpCancellationToken(),
    );
  }
}
