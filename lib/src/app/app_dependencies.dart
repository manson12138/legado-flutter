import 'package:dio/dio.dart';
import 'package:flutter/services.dart';

import '../api/cookie/cookie_manager.dart';
import '../api/cookie/flutter_webview_cookie_bridge.dart';
import '../api/http/dio_http_client.dart';
import '../api/http/app_dio_log_interceptor.dart';
import '../api/http/http_contract.dart';
import '../api/http/response_decoder.dart';
import '../api/http/source_url_resolver.dart';
import '../api/remote_app/remote_app_api.dart';
import '../api/remote_app/remote_app_service_config.dart';
import '../api/js/java_compatibility_bridge.dart';
import '../api/js/js_engine.dart';
import '../api/js/js_engine_pool.dart';
import '../api/js/jsf_engine.dart';
import '../api/js/legado_script_bridge.dart';
import '../api/js/script_context.dart';
import '../api/js/script_interaction_broker.dart';
import '../api/js/webview_script_bridge.dart';
import '../data/dao/book_chapter_dao.dart';
import '../data/dao/book_group_dao.dart';
import '../data/dao/book_dao.dart';
import '../data/dao/book_source_dao.dart';
import '../data/dao/cookie_dao.dart';
import '../data/dao/cache_dao.dart';
import '../data/dao/bookmark_dao.dart';
import '../data/dao/book_content_process_dao.dart';
import '../data/dao/replace_rule_dao.dart';
import '../data/dao/download_task_dao.dart';
import '../data/dao/reading_history_dao.dart';
import '../data/local/database_tables.dart';
import '../data/local/legado_database.dart';
import '../data/local/secure_auth_session_store.dart';
import '../data/model/book_source_import_decoder.dart';
import '../data/repository/adult_content_repository.dart';
import '../data/repository/book_repository.dart';
import '../data/repository/book_group_repository.dart';
import '../data/repository/book_source_repository.dart';
import '../data/repository/download_repository.dart';
import '../data/repository/search_history_repository.dart';
import '../data/repository/reader_repository.dart';
import '../data/repository/reading_history_repository.dart';
import '../data/repository/remote_app_configuration_repository.dart';
import '../data/repository/authentication_repository.dart';
import '../platform/password_encryption_platform_service.dart';
import '../domain/gateway/adult_content_gateway.dart';
import '../domain/gateway/bookmark_gateway.dart';
import '../domain/gateway/book_content_process_gateway.dart';
import '../domain/gateway/bookshelf_gateway.dart';
import '../domain/gateway/book_group_gateway.dart';
import '../domain/gateway/book_source_gateway.dart';
import '../domain/gateway/chapter_gateway.dart';
import '../domain/gateway/cover_cache_gateway.dart';
import '../domain/gateway/reading_progress_gateway.dart';
import '../domain/gateway/reading_history_gateway.dart';
import '../domain/gateway/reader_cache_gateway.dart';
import '../domain/gateway/replace_rule_gateway.dart';
import '../domain/gateway/search_history_gateway.dart';
import '../domain/gateway/authentication_gateway.dart';
import '../domain/usecase/add_book_to_bookshelf_use_case.dart';
import '../domain/usecase/save_book_content_process_use_case.dart';
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
import '../domain/usecase/record_reading_history_use_case.dart';
import '../help/logging/app_logger.dart';
import '../help/logging/app_log_manager.dart';
import '../help/crash_reporting/crash_report_manager.dart';
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
import '../platform/download_background_service.dart';
import '../model/local_book/epub_local_book_parser.dart';
import '../model/local_book/local_book_parser.dart';
import '../model/local_book/local_book_service.dart';
import '../model/local_book/local_book_storage.dart';
import '../model/local_book/txt_local_book_parser.dart';
import '../model/local_book/pdf_local_book_parser.dart';
import '../model/local_book/umd_local_book_parser.dart';
import '../ui/components/cover_url_cache.dart';
import 'default_book_source_bootstrapper.dart';
import 'remote_app_bootstrapper.dart';
import 'app_access_coordinator.dart';
import 'bookshelf_layout_preferences.dart';
import 'bookshelf_history_startup_preloader.dart';
import 'current_user_scope.dart';
import 'search_preferences.dart';
import 'remote_book_source_sync_service.dart';

/// 保存应用级共享依赖的组合根容器。
///
/// M1 使用显式构造注入，避免在业务代码中访问全局 Service Locator；后续新增依赖时仍应
/// 由本容器创建，再通过构造参数传给路由、ViewModel、UseCase 或 Repository。
final class AppDependencies {
  /// 创建不可变的应用依赖容器。
  const AppDependencies({
    required this.logger,
    required this.logManager,
    required this.crashReportManager,
    required this.adultContentGateway,
    required this.bookSourceGateway,
    required this.bookshelfGateway,
    required this.bookGroupGateway,
    required this.chapterGateway,
    required this.readingProgressGateway,
    required this.readingHistoryGateway,
    required this.bookmarkGateway,
    required this.bookContentProcessGateway,
    required this.replaceRuleGateway,
    required this.readerCacheGateway,
    required this.coverCacheGateway,
    required this.searchHistoryGateway,
    required this.searchPreferences,
    required this.cookieManager,
    required this.scriptInteractionBroker,
    required this.defaultBookSourceBootstrapper,
    required this.remoteAppBootstrapper,
    required this.appAccessCoordinator,
    required this.remoteAppConfigurationRepository,
    required this.authenticationGateway,
    required this.remoteBookSourceSyncService,
    required this.bookshelfLayoutPreferences,
    required this.bookshelfHistoryStartupPreloader,
    required this.currentUserScope,
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
    required this.recordReadingHistory,
    required this.saveBookContentProcess,
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
    required CrashReportManager crashReportManager,
    required RemoteAppServiceConfig remoteAppConfig,
  }) {
    /// M2 Flutter 独立数据库，首次数据操作时惰性打开。
    final LegadoDatabase database = LegadoDatabase(logger: logger);
    /// 书籍表 DAO，只在数据组合根内创建，不向 UI 暴露。
    final BookDao bookDao = BookDao(database);
    /// 章节表 DAO，只在数据组合根内创建，不向 UI 暴露。
    final BookChapterDao chapterDao = BookChapterDao(database);
    /// 阅读历史书籍与目录快照 DAO，不复用书架成员表。
    final ReadingHistoryDao readingHistoryDao = ReadingHistoryDao(database);
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
    /// 用户正文高亮与下划线 DAO，只由 ReaderRepository 访问。
    final BookContentProcessDao bookContentProcessDao =
        BookContentProcessDao(database);
    /// 正文替换规则 DAO，只由 ReaderRepository 访问。
    final ReplaceRuleDao replaceRuleDao = ReplaceRuleDao(database);
    /// 离线下载队列 DAO，只由 DownloadRepository 访问。
    final DownloadTaskDao downloadTaskDao = DownloadTaskDao(database);
    /// 登录用户的本地数据作用域；只保存用户 ID，不保存认证凭据。
    final CurrentUserScope currentUserScope = CurrentUserScope();
    /// 书籍、目录和进度共用的 Repository 实现。
    final BookRepository bookRepository = BookRepository(
      database,
      bookDao,
      chapterDao,
      currentUserScope.requireUserId,
    );
    /// 与书架成员资格独立的阅读历史 Repository。
    final ReadingHistoryRepository readingHistoryRepository =
        ReadingHistoryRepository(
      database,
      readingHistoryDao,
      currentUserScope.requireUserId,
    );
    /// M07 用户分组 Repository。
    final BookGroupRepository bookGroupRepository = BookGroupRepository(
      bookGroupDao,
      currentUserScope.requireUserId,
    );
    /// 登录后主界面书架与历史的本地首快照预加载器。
    final BookshelfHistoryStartupPreloader bookshelfHistoryStartupPreloader =
        BookshelfHistoryStartupPreloader(
      bookDao: bookDao,
      bookGroupDao: bookGroupDao,
      readingHistoryDao: readingHistoryDao,
      currentUserScope: currentUserScope,
    );
    /// 统一 Dio 实例；随后安装会遮盖认证信息的应用日志拦截器。
    final Dio dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 60),
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
    /// 服务端 App API 的集中配置和 HMAC 实现。
    final RemoteAppApi remoteAppApi = RemoteAppApi(
      httpClient: httpClient,
      config: remoteAppConfig,
    );
    /// 启动配置和过滤规则的远端仓储。
    final RemoteAppConfigurationRepository remoteAppConfigurationRepository =
        RemoteAppConfigurationRepository(remoteAppApi, cacheDao, remoteAppConfig);
    /// App 用户注册登录与内存会话仓储。
    final AuthenticationRepository authenticationRepository = AuthenticationRepository(
      remoteAppApi,
      const MethodChannelPasswordEncryptionService(),
      logger,
      SecureAuthenticationSessionStore(),
    );
    /// 崩溃上报使用可选内存会话，不会为此持久化认证信息。
    crashReportManager.configureUploader((Map<String, Object?> report) async {
      final RemoteCrashReportReceipt receipt = await remoteAppApi.uploadCrashReport(
        report: report,
        token: authenticationRepository.currentToken(),
      );
      return CrashReportUploadReceipt(
        receiptId: receipt.receiptId,
        retentionDays: receipt.retentionDays,
        duplicate: receipt.duplicate,
      );
    });
    /// App 登录会话和服务端书源下载服务；token 仅保存在内存。
    final RemoteBookSourceSyncService remoteBookSourceSyncService =
        RemoteBookSourceSyncService(
          remoteAppApi,
          cacheDao,
          authenticationRepository,
          remoteAppConfig,
          logger,
        );
    crashReportManager.configureAnalyticsRecorder(
      remoteBookSourceSyncService.recordAnalyticsEvent,
    );
    /// 成人内容屏蔽 Repository；供搜索、换源和书源导入共用同一套判定。
    final AdultContentRepository adultContentRepository = AdultContentRepository(
      cacheDao,
      rootBundle,
      httpClient,
      logger,
      notifySourceVisibilityChanged: () {
        /// 屏蔽策略改变了书源查询的可见结果，复用表级观察链触发重新查询，
        /// 但不删除或改写数据库中的任何书源。
        database.changeNotifier.notifyTables(<String>{DatabaseTables.bookSources});
      },
    );
    /// 首帧后异步刷新远端启动配置和内容过滤规则。
    final RemoteAppBootstrapper remoteAppBootstrapper = RemoteAppBootstrapper(
      repository: remoteAppConfigurationRepository,
      adultContentGateway: adultContentRepository,
      logger: logger,
    );
    /// 应用准入和升级状态的前台轮询协调器。
    final AppAccessCoordinator appAccessCoordinator = AppAccessCoordinator(
      remoteAppBootstrapper,
      remoteAppConfigurationRepository,
      logger,
    );
    /// 书源 Repository，组合 DAO、不可信 JSON 解码边界与成人内容屏蔽判定。
    final BookSourceRepository bookSourceRepository = BookSourceRepository(
      database,
      bookSourceDao,
      cacheDao,
      const BookSourceImportDecoder(),
      adultContentRepository,
      remoteBookSourceSyncService.recordOutcome,
    );
    remoteBookSourceSyncService.configureBookSourceProvider(
      bookSourceRepository.getByUrl,
    );
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
    /// 搜索页和脚本宿主桥共用的应用级单消费者交互队列。
    final LegadoScriptInteractionBroker scriptInteractionBroker =
        LegadoScriptInteractionBroker();
    /// M4 Legado、网络、Cookie、缓存与 Java 白名单统一桥。
    final LegadoScriptBridge scriptBridge = LegadoScriptBridge(
      httpClient,
      const HttpResponseDecoder(),
      const SourceUrlResolver(),
      cookieManager,
      cacheDao,
      const JavaCompatibilityBridge(),
      webViewScriptBridge,
      scriptInteractionBroker,
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
      cacheDao,
      webViewScriptBridge,
      logger,
    );
    /// M06 搜索历史 Repository，通过缓存表保持独立数据边界。
    final SearchHistoryRepository searchHistoryRepository =
        SearchHistoryRepository(
      cacheDao,
      currentUserScope.requireUserId,
    );
    /// M08 正文缓存、稳定锚点、显示配置、书签、替换规则和封面地址缓存 Repository。
    final ReaderRepository readerRepository = ReaderRepository(
      cacheDao,
      bookmarkDao,
      bookContentProcessDao,
      replaceRuleDao,
    );
    // BookCover 深埋在书架/搜索/详情等无状态 Screen 里，不经过路由层依赖注入；
    // 用组合根这一次性调用把持久化实现接进去，避免逐个页面 Screen/Route 都要新增
    // 参数传递这套跨页面展示缓存。
    CoverUrlCache.instance.configure(readerRepository);
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
      analyticsRecorder: remoteBookSourceSyncService.recordAnalyticsEvent,
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
    /// 服务器同步每页成功后立即复用该导入事务，并以相同 URL 覆盖策略续传。
    remoteBookSourceSyncService.configurePageImporter(importBookSources);
    /// 离线下载队列持久化 Repository。
    final DownloadRepository downloadRepository = DownloadRepository(
      downloadTaskDao,
      currentUserScope.requireUserId,
    );
    /// 自动下载换源专用单 worker 搜索器；搜索成功本身不评分，由整书批次统一结算。
    final BookSearchCoordinator automaticDownloadSearchCoordinator =
        BookSearchCoordinator(
          sourceGateway: bookSourceRepository,
          standardService: standardBookSourceService,
          adultContentGateway: adultContentRepository,
          cancellationTokenFactory: () => DioHttpCancellationToken(),
          logger: logger,
          maximumConcurrency: 1,
          recordSourceOutcomes: false,
        );
    /// 自动下载换源候选详情与目录协调器，不执行书架主源替换。
    final ChangeSourceCoordinator automaticDownloadSourceCoordinator =
        ChangeSourceCoordinator(
          searchCoordinator: automaticDownloadSearchCoordinator,
          detailService: bookDetailService,
          logger: logger,
        );
    /// App 级单例离线下载队列调度器；由本组合根长期持有，跨页面继续运行。
    final DownloadCoordinator downloadCoordinator = DownloadCoordinator(
      downloadGateway: downloadRepository,
      chapterGateway: bookRepository,
      bookshelfGateway: bookRepository,
      bookSourceGateway: bookSourceRepository,
      cacheGateway: readerRepository,
      standardService: standardBookSourceService,
      automaticSourceCoordinator: automaticDownloadSourceCoordinator,
      cancellationTokenFactory: () => DioHttpCancellationToken(),
      logger: logger,
      backgroundService: const MethodChannelDownloadBackgroundService(),
      cacheDao: cacheDao,
      analyticsEnabled: remoteBookSourceSyncService.isAnalyticsEnabled,
      analyticsRecorder: remoteBookSourceSyncService.recordAnalyticsEvent,
    );

    return AppDependencies(
      logger: logger,
      logManager: logManager,
      crashReportManager: crashReportManager,
      adultContentGateway: adultContentRepository,
      bookSourceGateway: bookSourceRepository,
      bookshelfGateway: bookRepository,
      bookGroupGateway: bookGroupRepository,
      chapterGateway: bookRepository,
      readingProgressGateway: bookRepository,
      readingHistoryGateway: readingHistoryRepository,
      bookmarkGateway: readerRepository,
      bookContentProcessGateway: readerRepository,
      replaceRuleGateway: readerRepository,
      readerCacheGateway: readerRepository,
      coverCacheGateway: readerRepository,
      searchHistoryGateway: searchHistoryRepository,
      searchPreferences: SearchPreferences(cacheDao),
      cookieManager: cookieManager,
      scriptInteractionBroker: scriptInteractionBroker,
      defaultBookSourceBootstrapper: DefaultBookSourceBootstrapper(
        sourceGateway: bookSourceRepository,
        importBookSources: importBookSources,
        assetBundle: rootBundle,
        logger: logger,
      ),
      remoteAppBootstrapper: remoteAppBootstrapper,
      appAccessCoordinator: appAccessCoordinator,
      remoteAppConfigurationRepository: remoteAppConfigurationRepository,
      authenticationGateway: authenticationRepository,
      remoteBookSourceSyncService: remoteBookSourceSyncService,
      bookshelfLayoutPreferences: BookshelfLayoutPreferences(cacheDao),
      bookshelfHistoryStartupPreloader: bookshelfHistoryStartupPreloader,
      currentUserScope: currentUserScope,
      importBookSources: importBookSources,
      bookSourceImportTextResolver: bookSourceImportTextResolver,
      addBookToBookshelf: addBookToBookshelf,
      deleteBooksFromBookshelf: DeleteBooksFromBookshelfUseCase(bookRepository),
      createBookshelfGroup: CreateBookshelfGroupUseCase(bookGroupRepository),
      changeBookSource: ChangeBookSourceUseCase(
        bookRepository,
        readerRepository,
        analyticsRecorder: remoteBookSourceSyncService.recordAnalyticsEvent,
      ),
      replaceBooksGroup: ReplaceBooksGroupUseCase(bookRepository),
      loadBookChapters: LoadBookChaptersUseCase(bookRepository),
      saveBookChapters: SaveBookChaptersUseCase(bookRepository),
      saveReadingProgress: SaveReadingProgressUseCase(bookRepository),
      restoreReadingProgress: RestoreReadingProgressUseCase(bookRepository),
      recordReadingHistory:
          RecordReadingHistoryUseCase(readingHistoryRepository),
      saveBookContentProcess: SaveBookContentProcessUseCase(readerRepository),
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

  /// “我的”页崩溃报告管理与全局错误入口共用的文件边界。
  final CrashReportManager crashReportManager;

  /// 成人内容屏蔽领域边界，供搜索、换源和书源导入共用同一套判定。
  final AdultContentGateway adultContentGateway;

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

  /// 与书架独立的阅读历史书籍和目录快照边界。
  final ReadingHistoryGateway readingHistoryGateway;

  /// 阅读器书签持久化边界。
  final BookmarkGateway bookmarkGateway;

  /// 用户正文高亮、下划线和管理操作的持久化边界。
  final BookContentProcessGateway bookContentProcessGateway;

  /// 阅读器正文替换规则读取边界。
  final ReplaceRuleGateway replaceRuleGateway;

  /// 阅读器正文缓存、稳定锚点和显示配置边界。
  final ReaderCacheGateway readerCacheGateway;

  /// 跨页面“已知可显示封面地址”缓存边界，供 [CoverUrlCache] 持久化。
  final CoverCacheGateway coverCacheGateway;

  /// 搜索历史持久化边界。
  final SearchHistoryGateway searchHistoryGateway;

  /// 搜索结果匹配方式的持久化偏好服务。
  final SearchPreferences searchPreferences;

  /// 普通 HTTP、登录 WebView 与 JavaScript 页面请求共用的统一 Cookie 管理器。
  final LegadoCookieManager cookieManager;

  /// 书源脚本申请登录或验证码交互时使用的应用级单消费者串行队列。
  final LegadoScriptInteractionBroker scriptInteractionBroker;

  /// 启动期按需导入 Flutter assets 内置书源的业务协调器。
  final DefaultBookSourceBootstrapper defaultBookSourceBootstrapper;

  /// 启动后异步同步服务端配置的协调器。
  final RemoteAppBootstrapper remoteAppBootstrapper;

  /// 应用级准入、升级与前台轮询协调器。
  final AppAccessCoordinator appAccessCoordinator;

  /// 公告和功能开关的缓存及按需刷新仓储。
  final RemoteAppConfigurationRepository remoteAppConfigurationRepository;
  /// 当前 App 用户认证边界；token 始终由数据层保留在内存。
  final AuthenticationGateway authenticationGateway;

  /// App 登录及服务端书源同步服务。
  final RemoteBookSourceSyncService remoteBookSourceSyncService;

  /// 书架与阅读历史列表/网格模式的持久化偏好服务。
  final BookshelfLayoutPreferences bookshelfLayoutPreferences;

  /// 登录后为书架和阅读历史页面准备本地首快照的单飞服务。
  final BookshelfHistoryStartupPreloader bookshelfHistoryStartupPreloader;

  /// 当前登录用户的本地书架与历史数据作用域。
  final CurrentUserScope currentUserScope;

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

  /// 首次成功阅读后记录历史快照的业务动作。
  final RecordReadingHistoryUseCase recordReadingHistory;

  /// 从稳定正文选区创建用户高亮或下划线的业务动作。
  final SaveBookContentProcessUseCase saveBookContentProcess;

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
      adultContentGateway: adultContentGateway,
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
