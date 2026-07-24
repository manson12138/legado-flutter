# Legado Flutter AI 项目索引

> 用途：帮助 AI 编码代理在修改本仓库业务代码前，快速找到规则、实现入口、Android 对照、阶段文档和已知阻塞。
>
> 本文件是导航索引，不替代强制规则、源码事实、阶段验收记录或用户当前回合的明确要求。
>
> 最后静态核对：2026-07-24。未运行编译、测试、分析、格式化或应用启动。

## 1. AI 使用顺序

处理任何 Flutter 重写任务时，按以下顺序建立上下文：

1. 阅读仓库根目录 `AGENTS.md` 和用户当前要求。
2. 完整阅读 [`FLUTTER_REWRITE_EXECUTION_PLAN.md`](./FLUTTER_REWRITE_EXECUTION_PLAN.md)。
3. 阅读本索引，确定功能入口、分层和需要继续读取的文档。
4. 阅读 [`steps/MIGRATION_STEPS_INDEX.md`](./steps/MIGRATION_STEPS_INDEX.md) 和目标阶段文档。
5. 阅读目标功能对应的阶段实施记录、Android 原实现和 Flutter 当前实现。
6. 修改前重新搜索真实调用方；不要仅凭本索引推断代码仍与 2026-07-15 相同。

事实冲突时使用以下优先级：

1. 用户当前回合明确要求；
2. 根目录 `AGENTS.md` 的强制约束；
3. `FLUTTER_REWRITE_EXECUTION_PLAN.md`；
4. 当前源码与宿主配置所表达的实现事实；
5. 目标阶段的最新实施记录和迁移账本；
6. 本索引。

状态判断不能只看源码是否存在。阶段是否通过，必须以用户运行结果或用户明确确认为准。

## 2. 项目身份与边界

| 项目事实 | 当前值 |
|---|---|
| 仓库定位 | 独立 Flutter 仓库；`lib/`、`android/`、`ios/` 直接在仓库根目录，不再有 `flutter_app/` 这层子目录 |
| Dart 入口 | `lib/main.dart` |
| Flutter/Dart 固定版本 | Flutter `3.41.5 stable`、Dart `3.11.3` |
| Android applicationId | `io.legado.flutter` |
| Android minSdk | `26` |
| iOS Bundle Identifier | `io.legado.flutter` |
| iOS Deployment Target | `16.0` |
| 独立数据库 | `legado_flutter.db`，当前 Schema v8 |
| 覆盖安装与版本基线 | [`../../VERSION.md`](../../VERSION.md)：晚间打包时对照 applicationId、签名、`versionCode` / `versionName`、SQLite Schema 与其他持久化数据，判断能否覆盖安装并保留数据 |
| 原 Android 参考实现 | 位于**同级兄弟仓库** `legado-with-MD3`（不在本仓库内）的 `app/src/main/java/io/legado/app/`；本索引第 6 节“Android 对照”列的路径均相对该兄弟仓库 |
| 重写文档主目录 | `docs/flutter-rewrite/` |

必须保持的边界：

- Flutter 应用与原 Android 应用共存，不读取或迁移原应用私有数据库。
- 原 Android 项目是只读功能基准；Flutter 任务不能顺手修改 Android 业务代码。
- UI 发送 Intent、渲染 UiState；一次性导航和系统行为通过 Effect 交给 Route。
- UI 不直接访问 DAO、HTTP、规则引擎、文件系统或平台通道。
- 依赖由 `AppDependencies` 在组合根创建，通过构造参数向下传递；没有全局 Service Locator。
- 领域模型、Gateway 和 UseCase 不依赖 Flutter Widget、sqflite 或宿主平台对象。
- Kotlin 禁止 `!!`；Dart 禁止用 `!` 空值断言掩盖可空设计问题。
- AI 不运行构建、测试、Lint、静态分析、格式检查或应用启动命令。
- 新增文件后必须询问用户是否加入 Git 暂存区，不能主动执行 `git add`。

跨阶段 UI、阅读器和书架冲突重构方案见
[`FLUTTER_UI_AND_READER_REDESIGN_PLAN.md`](./FLUTTER_UI_AND_READER_REDESIGN_PLAN.md)。该文档当前为
`IN_PROGRESS`；R1～R5 已写入第一批实现但尚无用户运行证据，且仿真翻页、高级设置、有限多章
Widget 窗口和其余页面视觉重构仍未完成；离线下载管理已实现待真机验证。
书源、搜索、详情/目录、阅读和换源核心主流程与原生 Android 的差距及建议实施顺序见
[`CORE_READING_FLOW_GAP_PRIORITY.md`](./CORE_READING_FLOW_GAP_PRIORITY.md)。该文档以真实书源成功率、
阅读稳定性、进度安全和换源数据安全为 P0，状态为 `PROPOSED`，需用户确认后再作为后续领取顺序。
小说正文阅读界面完整 UI 对齐的实施优先级见
[`m08/01_reader_ui_rebuild_priority.md`](./m08/01_reader_ui_rebuild_priority.md)。该文档当前为
`IN_PROGRESS`；P0～P4 可落地阅读 UI 已写入 Flutter，单章换源和离线下载管理已实现待真机
验证；TTS、AI、同步等仍等待对应子系统迁移。
小说阅读详情页完整 UI 对齐的实施优先级见
[`m06/01_book_info_ui_rebuild_priority.md`](./m06/01_book_info_ui_rebuild_priority.md)。该文档当前为
`IN_PROGRESS`；P0～P3 基础入口已写入 Flutter 详情页但尚无用户运行证据，阅读记录、
换封面、相关书、书源登录/变量、Web 文件、清缓存、日志和同步仍需后续业务能力。
搜索页的键盘收起、书名/作者结果 PageView 分类及详情主操作卡反馈方案见
[`m06/02_search_result_and_book_info_interaction_plan.md`](./m06/02_search_result_and_book_info_interaction_plan.md)。
该方案当前为 `IN_PROGRESS`；Flutter UI 已实现，待用户运行验证。

## 3. 总体启动链

```text
lib/main.dart
  -> 初始化 Widgets、edge-to-edge、全局错误捕获和日志器
  -> AppDependencies.create(...)
  -> LegadoApp
  -> MaterialApp.onGenerateRoute
  -> AppRouter
  -> Feature Route
  -> Feature ViewModel
  -> Feature Screen
```

关键入口：

| 职责 | 文件 | 重点 |
|---|---|---|
| 进程入口与全局错误兜底 | `lib/main.dart` | 初始化顺序、日志后备实现、`runZonedGuarded`；完成依赖装配后立即挂载根 Widget，不阻塞首帧 |
| 应用组合根 | `lib/src/app/app_dependencies.dart` | DAO、Repository、HTTP、JS、协调器和 UseCase 的唯一集中装配处 |
| 内置书源启动导入 | `lib/src/app/default_book_source_bootstrapper.dart` | 新库首次启动时从 Flutter assets 导入默认书源，复用书源导入 UseCase |
| 路由常量 | `lib/src/app/app_route.dart` | 应用内稳定路由名 |
| 路由与参数校验 | `lib/src/app/app_router.dart` | Route 创建、构造注入、无效参数错误页 |
| 根 Widget | `lib/src/app/legado_app.dart` | 主题、初始路由、路由观察器、错误边界和认证门；启动阶段只恢复认证会话，登录成功后异步导入内置书源、恢复下载并启动准入轮询（硬编码 `admin` 账号跳过准入与版本检查） |
| 全局错误边界 | `lib/src/app/app_error_boundary.dart` | Flutter 框架与平台调度错误 |
| 导航观察 | `lib/src/app/app_navigation_observer.dart` | 页面切换诊断日志 |

新增共享依赖时，先判断它属于 Gateway、Repository、UseCase、运行时协调器还是平台服务，再从 `AppDependencies` 接线；不要在页面中临时创建第二套网络、数据库或日志实现。

## 4. 目录职责索引

| 目录 | 职责 | 不应放入 |
|---|---|---|
| `lib/src/app/` | 启动、组合根、路由、应用级错误边界 | 功能业务逻辑 |
| `lib/src/ui/` | Contract、ViewModel、Route、Screen、共享 UI | DAO、HTTP、文件解析 |
| `lib/src/domain/model/` | 平台无关、存储无关的领域模型 | sqflite Map、Widget 状态 |
| `lib/src/domain/gateway/` | 领域所需能力的抽象边界 | 插件或 DAO 具体类型 |
| `lib/src/domain/usecase/` | 跨 Gateway 的明确业务动作 | 页面导航、SnackBar |
| `lib/src/data/dao/` | 单表或紧密相关表的 SQL 读写 | UI 状态和网络请求 |
| `lib/src/data/repository/` | Gateway 实现、事务和数据错误转换 | Widget 或 `BuildContext` |
| `lib/src/data/local/` | 数据库、表名、行读取、变更通知 | 功能页面状态 |
| `lib/src/data/model/` | 外部数据进入领域前的解码边界 | 页面 DTO |
| `lib/src/api/http/` | 统一 HTTP 契约、Dio 实现、URL 解析、响应解码 | 书源页面状态 |
| `lib/src/api/cookie/` | HTTP Cookie 持久化、Android WebView/WKWebView 按域同步 | 独立第二套 Cookie 存储 |
| `lib/src/api/js/` | JS 引擎、实例池、桥接、执行上下文 | 具体页面流程 |
| `lib/src/model/analyze_rule/` | 普通规则和 JavaScript 规则服务 | 导航和数据库 SQL |
| `lib/src/model/web_book/` | 搜索、详情、目录、正文编排 | Widget |
| `lib/src/model/bookshelf/` | 书架刷新运行时协调 | 页面渲染 |
| `lib/src/model/reader/` | 正文获取、处理、缓存和预加载协调 | 平台窗口直接调用 |
| `lib/src/model/local_book/` | 文件副本、格式识别、解析和导入协调 | 文件选择器 UI |
| `lib/src/platform/` | 文件选择、WebView 登录、阅读系统能力等窄接口 | 跨平台业务状态机 |
| `lib/src/help/error/` | 稳定应用错误与结果类型 | 功能专属状态 |
| `lib/src/help/logging/` | 日志抽象、文件日志、日志管理能力 | 敏感正文、Cookie、Token |
| `lib/src/ui/components/` | 至少两个页面复用的无状态组件 | 单页面业务抽象 |
| `lib/src/ui/theme/` | Material 3 主题和 Design Token | 功能状态 |
| `packages/` | 将来确有必要的自研平台插件 | 没有调用方的预留空壳 |

`.dart_tool/`、`build/`、`.gradle/`、`ios/Flutter/ephemeral/` 和生成的插件注册文件不是业务实现索引来源。

## 5. 路由与页面索引

| 路由 | Route / Screen | 状态入口 | 参数或说明 |
|---|---|---|---|
| `/` | `ui/home/welcome_route.dart` / `welcome_screen.dart` | `WelcomeViewModel` | 正式应用 Shell；手机底部导航、宽屏 NavigationRail，IndexedStack 保留书架/搜索/书源/设置状态 |
| `/settings` | `ui/settings/settings_route.dart` / `settings_screen.dart` | 当前为轻量无状态接线 | 设置入口 |
| `/settings/logs` | `ui/log_management/log_management_route.dart` / `log_management_screen.dart` | `LogManagementViewModel` | 查看、分享、ADB 回显和删除沙盒日志 |
| `/settings/crash-reports` | `ui/crash_report_management/crash_report_management_route.dart` / `crash_report_management_screen.dart` | `CrashReportManagementViewModel` | 独立崩溃报告查看、手动上传、本地上传状态和删除；方案见 [`m11/crash_reporting/01_crash_reporting_and_telemetry_design.md`](./m11/crash_reporting/01_crash_reporting_and_telemetry_design.md) |
| `/settings/about` | `ui/about/about_route.dart` / `about_screen.dart` | `AboutViewModel` | 连点应用图标 2 秒内 5 次解锁“内容过滤管理”（成人内容屏蔽开关 + 远程更新词库） |
| `/downloads` | `ui/download_management/download_management_route.dart` | `DownloadCoordinator` + `DownloadGateway` 全局任务流 | 设置或阅读器进入；PageView 区分下载中、已完成与离线内容；跨书范围入队、暂停恢复、失败重试、仅删任务、离线正文删除与书籍详情入口 |
| `/book-sources` | `ui/book_source/book_source_route.dart` / `book_source_screen.dart` | `BookSourceManagementViewModel` | 书源管理、导入、扫码和编辑；服务器书源同步将按 API v2 游标协议重写，方案见 [`m11/backend_api_integration/09_booksource_cursor_sync_v2_rewrite_plan.md`](./m11/backend_api_integration/09_booksource_cursor_sync_v2_rewrite_plan.md)；旧页码方案仅供历史追溯 |
| `/search` | `ui/search/search_route.dart` / `search_screen.dart` | `SearchViewModel` | 多书源搜索和搜索历史 |
| `/book-info` | `ui/book_info/book_info_route.dart` / `book_info_screen.dart` | `BookInfoViewModel` | 必须传 `BookInfoRouteArguments` |
| `/bookshelf` | `ui/bookshelf/bookshelf_route.dart` / `bookshelf_screen.dart` / `reading_history_screen.dart` / `app/bookshelf_layout_preferences.dart` | `BookshelfViewModel`、`ReadingHistoryViewModel` | 内部书架/历史 `PageView`；实时书架、独立阅读历史、分组、排序、批量操作；列表/网格排版通过 `caches` 持久化并在重启后恢复；书架失去可见性时退出选择模式 |
| `/local-books/import` | `ui/local_book_import/local_book_import_route.dart` / `local_book_import_screen.dart` | `LocalBookImportViewModel` | 系统文件选择和导入 |
| `/reader` | `ui/reader/book_reader_route.dart` | `ReaderViewModel` | 必须传非空 `bookUrl`；未入架详情/历史入口可附带 `initialBook`、`initialChapters` 和 `entry` 快照；PDF 分流到 `PdfReaderRoute`，其余进入 `ReaderRoute`；菜单与刷新入口在 `reader_menu_overlay.dart`，设置在 `reader_settings_sheet.dart`，搜索/书签/替换/标注管理在 `reader_action_sheets.dart`，连续与分页选区共用 `reader_selection_region.dart`，正文短按由不参与手势竞技场的 `reader_tap_region.dart` 识别，避免与长按选词冲突 |
| `/books/change-source` | `ui/change_book_source/change_book_source_route.dart` / `change_book_source_screen.dart` | `ChangeBookSourceViewModel` | 必须传当前书架旧 `bookUrl`；成功返回 `ChangeBookSourceResult` 新主键 |

页面修改的默认阅读集合是同目录下的：

```text
*_contract.dart
*_view_model.dart
*_route.dart
*_screen.dart
```

Route 管理生命周期、插件、导航、对话框和 Effect；Screen 保持无状态；ViewModel 只从单一 `onIntent` 入口改变状态或发出 Effect。

## 6. 功能定位表

| 需求关键词 | Flutter 主入口 | 核心下游 | Android 对照 | 阶段文档 |
|---|---|---|---|---|
| 书源导入、编辑、启停、分组、扫码 | `ui/book_source/` | `BookSourceImportTextResolver`、`BookSourceRepository`、`ImportBookSourcesUseCase`、`BookSourcePlatformBridge` | `ui/book/source/manage/`、`ui/book/source/edit/`、`ui/association/` | [`m05/README.md`](./m05/README.md) |
| HTTP、Header、Cookie、编码、解压 | `api/http/`、`api/cookie/` | `DioUnifiedHttpClient`、`HttpResponseDecoder`、`SourceUrlResolver` | `help/http/` | [`m03/README.md`](./m03/README.md) |
| 普通规则 | `model/analyze_rule/standard_rule_engine.dart` | `source_rules.dart`、`standard_source_parser.dart`、`standard_source_service.dart` | `model/analyzeRule/`、`model/webBook/` | [`m03/README.md`](./m03/README.md) |
| JavaScript 书源 | `api/js/` | `LegadoJavaScriptService`、`LegadoScriptBridge`、`JsEnginePool` | `modules/rhino/`、`model/analyzeRule/` | [`m04/README.md`](./m04/README.md) |
| 搜索 | `ui/search/` | `BookSearchCoordinator`、`SearchHistoryRepository`、`StandardBookSourceService` | `ui/book/search/` | [`m06/README.md`](./m06/README.md)、[`m06/02_search_source_ranking_and_detail_failover_plan.md`](./m06/02_search_source_ranking_and_detail_failover_plan.md) |
| 详情和目录 | `ui/book_info/` | `BookDetailService`、`SaveBookChaptersUseCase`、`AddBookToBookshelfUseCase` | `ui/book/info/`、`model/webBook/` | [`m06/README.md`](./m06/README.md)、[`m06/01_book_info_ui_rebuild_priority.md`](./m06/01_book_info_ui_rebuild_priority.md)、[`m06/02_search_source_ranking_and_detail_failover_plan.md`](./m06/02_search_source_ranking_and_detail_failover_plan.md) |
| 书架 | `ui/bookshelf/` | `BookRepository`、`BookGroupRepository`、`BookshelfRefreshCoordinator` | `ui/main/bookshelf/` | [`m07/README.md`](./m07/README.md) |
| 书架内历史阅读双页 | `ui/bookshelf/bookshelf_page_switcher.dart`、`reading_history_contract.dart`、`reading_history_view_model.dart`、`reading_history_screen.dart`；`ui/reader/` 写入历史并提供显式加入书架图标 | `ReadingHistoryDao` / `ReadingHistoryRepository` / `ReadingHistoryGateway` / `RecordReadingHistoryUseCase`；独立 `reading_history_books`/`reading_history_chapters` 快照，`books` 仍只表示书架 | Android `ReadRecord` 与书架/阅读入口 | [`m11/reading_history_and_bookshelf_pageview_design.md`](./m11/reading_history_and_bookshelf_pageview_design.md)、[`m11/bookshelf_history_fixed_header_interaction_plan.md`](./m11/bookshelf_history_fixed_header_interaction_plan.md)、[`m11/bookshelf_history_and_remote_source_sync_feedback_plan.md`](./m11/bookshelf_history_and_remote_source_sync_feedback_plan.md) |
| App 登录注册与全局认证门 | `app/legado_app.dart`、`ui/authentication/`、`domain/gateway/authentication_gateway.dart`、`data/repository/authentication_repository.dart` | 安全会话恢复、全局认证阻断、RSA-OAEP 密码传输、权限读取与退出登录；未登录不会展示业务路由 | Android App 登录/注册相关入口 | [`m11/backend_api_integration/10_authentication_entry_and_full_flow_plan.md`](./m11/backend_api_integration/10_authentication_entry_and_full_flow_plan.md) |
| 网络书正文阅读 | `ui/reader/` | `ReadBookCoordinator`、`ReaderTextProcessor`、`ReaderRepository`、`ReaderSearchState`、`ReaderDisplayConfig`；安全资源协议在 `domain/model/reader_content_markup.dart`，图片视图在 `ui/reader/reader_content_image.dart`；原生选区与标注 Span 在 `ui/reader/reader_selection_region.dart`，标注模型/持久化在 `domain/model/book_content_process.dart`、`data/dao/book_content_process_dao.dart` | `ui/book/read/`、`model/ReadBook.kt`、`help/book/ContentProcessor.kt`、`data/entities/BookContentProcess.kt` | [`m08/README.md`](./m08/README.md)、[`m08/01_reader_ui_rebuild_priority.md`](./m08/01_reader_ui_rebuild_priority.md)、[`CORE_READING_FLOW_GAP_PRIORITY.md`](./CORE_READING_FLOW_GAP_PRIORITY.md) |
| 整书换源 | `ui/change_book_source/` | `ChangeSourceCoordinator`、`ChangeBookSourceUseCase`、`BookRepository.changeBookSource` | `ui/book/changesource/`、`ChangeSourceSearchUseCase.kt`、`ChangeBookSourceUseCase.kt` | [`m11/README.md`](./m11/README.md) |
| 单章换源 | `ui/change_chapter_source/`（阅读器内 `ReaderChangeChapterSourceSheet`） | `ChangeChapterSourceCoordinator`、`chapter_title_matcher.dart`、`ReadBookCoordinator.invalidateChapter` | `ui/book/read/sheet/ChangeChapterSourceSheet.kt`、`BookHelp.getDurChapter`、`BookHelp.saveText` | [`m11/chapter_change_source/README.md`](./m11/chapter_change_source/README.md) |
| 离线下载 | `ui/reader/reader_download_sheet.dart`（当前书入口）、`ui/download_management/download_management_route.dart`（`/downloads` 跨书 PageView 管理）、`/offline-content`（设置中的离线正文管理入口） | `DownloadCoordinator`（App 级全局可配置并发，默认 5、上限 8；支持仅删除任务或清除正文与任务）、`DownloadTaskDao`/`DownloadRepository`、`download_tasks` 表、`platform/download_background_service.dart`；Android `DownloadForegroundService.kt`，iOS `AppDelegate.swift` 有限后台窗口 | `ui/book/read/sheet/DownloadSheet.kt`、`CacheBook`/`CacheBookModel`、`CacheBookService`、`BookCacheManageScreen` | [`m11/offline_download/README.md`](./m11/offline_download/README.md) |
| 本地书导入 | `ui/local_book_import/` | `LocalBookImportCoordinator`、`LocalBookStorage`、各格式 Parser | `model/localBook/` 和原文件导入入口 | [`m08_1/README.md`](./m08_1/README.md) |
| PDF 阅读 | `ui/reader/pdf_reader_route.dart` | `PdfLocalBookParser`、`pdfx` | `model/localBook/PdfFile.kt` | [`m08_1/README.md`](./m08_1/README.md) |
| 阅读系统栏、常亮与认证密码加密 | `platform/reader_platform_service.dart`、`platform/password_encryption_platform_service.dart` | Android `MainActivity.kt`、iOS `AppDelegate.swift`；RSA-OAEP-SHA256 使用系统密码学实现 | 原阅读 Activity/窗口逻辑 | [`m09/04_m10_handoff.md`](./m09/04_m10_handoff.md)、[`m11/backend_api_integration/04_authentication_rsa_oaep_upgrade_design.md`](./m11/backend_api_integration/04_authentication_rsa_oaep_upgrade_design.md) |
| App 账号会话恢复 | `data/local/secure_auth_session_store.dart`、`data/repository/authentication_repository.dart`、`api/remote_app/remote_app_api.dart` | Android Keystore / iOS Keychain 保存 Token 生命周期；启动与前台恢复、到期刷新、401 与退出清理 | `AuthenticationGateway` -> `AuthenticationRepository` -> `SecureAuthenticationSessionStore`、`POST /api/v1/auth/refresh` | [`m11/backend_api_integration/06_persistent_auth_session_design.md`](./m11/backend_api_integration/06_persistent_auth_session_design.md) |
| 日志与设置 | `ui/settings/`、`ui/log_management/` | `help/logging/`、`AppDependencies` | `ui/widget/components/log/` 等现有日志入口 | 当前源码；修改前搜索最新专项目标文档 |
| 崩溃报告、匿名埋点与书源成功率 | `ui/crash_report_management/`、`help/crash_reporting/crash_report_manager.dart`、`app/analytics_recorder.dart`、`app/source_success_rate_reporter.dart` | 崩溃独立文件存储；匿名埋点按用户授权、UUID 幂等和严格白名单分批；书源按 `search/toc/content` 聚合并执行未知书源两阶段补充 | `main.dart`、`app_error_boundary.dart`、`RemoteAppApi.uploadCrashReport/reportAnalyticsEvents/reportBookSourceStats` | [`m11/crash_reporting/01_crash_reporting_and_telemetry_design.md`](./m11/crash_reporting/01_crash_reporting_and_telemetry_design.md)、[`m11/reading_history_and_bookshelf_pageview_design.md`](./m11/reading_history_and_bookshelf_pageview_design.md) |
| 成人内容屏蔽 | `ui/about/`（连点解锁入口） | `AdultContentGateway`/`AdultContentRepository`（内置 Base64 `assets/default_data/adult_keywords.txt` + `adult_domains.txt`，复用 `caches` 表存开关和远程覆盖词库）；接入点为 `BookSourceRepository.importSourceJson`（拒绝导入并计入 `BookSourceImportResult.blockedAdult`）和 `BookSearchCoordinator`（过滤搜索结果，`ChangeSourceCoordinator`/`ChangeChapterSourceCoordinator` 复用同一协调器自动覆盖） | `help/AdultContentFilter.kt`、`help/source/SourceHelp.list18Plus`（当前仅存在于本仓库 Android 侧未提交改动，两端各自独立实现，互不共享数据库） | 当前源码；无独立阶段文档 |
| 全局 UI、响应式、连续阅读、分页、预取、同书不同源冲突 | `ui/theme/`、`ui/components/adaptive_app_scaffold.dart`、`ui/bookshelf/`、`ui/book_info/`、`ui/reader/reader_page_layout.dart` | `ResolveBookShelfStateUseCase`、`AddBookToBookshelfUseCase`、`ReadBookCoordinator`、`ReaderPageLayoutEngine` | `ui/book/read/`、`model/ReadBook.kt`、`ResolveBookShelfStateUseCase.kt` | [`FLUTTER_UI_AND_READER_REDESIGN_PLAN.md`](./FLUTTER_UI_AND_READER_REDESIGN_PLAN.md) |

## 7. 核心调用链

### 7.1 书源导入

```text
BookSourceManagementScreen
  -> BookSourceManagementIntent
  -> BookSourceManagementViewModel
  -> BookSourceImportTextResolver（远程地址时）
  -> ImportBookSourcesUseCase
  -> BookSourceGateway
  -> BookSourceRepository
  -> BookSourceImportDecoder + BookSourceDao + SQLite 事务
```

外部 JSON、二维码、剪贴板和远程文本都属于不可信输入。不要绕过统一解码、大小限制、冲突策略和事务边界。
新安装默认书源由 `DefaultBookSourceBootstrapper` 在 `main.dart` 启动期触发；它仅在书源表为空时读取
`assets/default_data/book_sources.json`，并继续走 `ImportBookSourcesUseCase` 与
`BookSourceRepository.importSourceJson`，不得另建资产专用解码或写库路径。

### 7.2 网络书搜索到阅读

```text
SearchViewModel
  -> BookSearchCoordinator
  -> BookSourceGateway 读取启用书源
  -> StandardBookSourceService
  -> UnifiedHttpClient + HttpResponseDecoder
  -> StandardBookSourceParser / StandardRuleEngine
  -> BookInfoViewModel + BookDetailService
  -> AddBookToBookshelfUseCase
  -> BookshelfViewModel
  -> BookReaderRoute
  -> ReaderViewModel
  -> ReadBookCoordinator
  -> ReaderRepository + ReadingProgressGateway
```

JavaScript 书源不能假装走普通规则成功；当前阻塞必须返回可诊断错误。

### 7.3 本地书导入到阅读

```text
LocalBookImportRoute
  -> LocalBookPlatformBridge
  -> LocalBookImportViewModel
  -> LocalBookImportCoordinator
  -> LocalBookStorage 复制到应用私有目录并识别格式
  -> LocalBookParserRegistry
  -> TXT / EPUB / PDF / UMD Parser
  -> AddBookToBookshelfUseCase
  -> BookReaderRoute
  -> PDF: PdfReaderRoute
  -> 其他已支持文本格式: ReaderRoute + LocalBookContentService
```

文件选择器展示的扩展名多于当前真实解析器。组合根目前注册 TXT、EPUB、PDF、UMD；MOBI、AZW、AZW3 和压缩容器不能因为可选择就宣称已支持。

### 7.4 数据写入

```text
UI Intent
  -> ViewModel
  -> UseCase 或明确的运行时协调器
  -> Gateway
  -> Repository
  -> DAO
  -> LegadoDatabase
  -> DatabaseChangeNotifier
  -> watch 流重新查询
```

事务失败时不能发送成功变更通知；sqflite Map 和异常不能越过 Repository/Gateway 边界进入 UI。

### 7.5 整书换源

```text
BookInfo / Bookshelf / Reader Intent
  -> /books/change-source
  -> ChangeBookSourceViewModel
  -> ChangeSourceCoordinator
     -> BookSearchCoordinator
     -> BookDetailService
     -> StandardBookSourceService
  -> ChangeBookSourceUseCase
  -> BookshelfGateway.changeBookSource
  -> BookRepository SQLite transaction
  -> ReaderCacheGateway 复制稳定锚点和显示配置
  -> 调用页使用新 bookUrl 替换详情或阅读路由
```

当前只覆盖单本网络书的整书换源。自动、批量换源和候选书源管理仍是独立 Feature；单章换源与
离线下载已有独立实现和验收门禁，不能因整书换源路由存在而宣称它们已通过验收。

### 7.6 离线下载与后台续传

```text
ReaderDownloadSheet / /downloads
  -> DownloadCoordinator（App 级单例、全局持久化 1～8 worker、默认 5、45 秒硬超时、失败 5 次跳章）
  -> DownloadGateway / DownloadRepository / DownloadTaskDao
  -> download_tasks + download_book_states（任务、批次、来源归因、自动换源锁定和一次性评分）
  -> ChangeSourceCoordinator（自动换源专用单搜索 worker；3@98% → 5@95% → 8@90% → 12@85% → 20@80% → 30@70%，累计最多 78 个来源、全局最多 3 分钟；失败提示手动换源）
  -> StandardBookSourceService 获取目录和正文
  -> ReaderCacheGateway 永久正文缓存
  -> DownloadBackgroundService 平台通道
     -> Android DownloadForegroundService（dataSync 通知）
     -> iOS beginBackgroundTask（系统有限窗口，结束后持久化续传）
```

### 7.7 同书冲突、分页与阅读预下载

```text
BookInfoViewModel
  -> AddBookToBookshelfUseCase
  -> ResolveBookShelfStateUseCase
  -> BookshelfGateway.getShelfBookConflict
  -> BookDao 精确 name + author 查询
  -> 已入架 / 同名同作者冲突 / 未入架
  -> 冲突时由 BookInfoRoute 展示替换、明确新增或取消

ReaderScreen
  -> 连续模式：章节边界 Intent
  -> 分页模式：ReaderPageLayoutEngine 标题/段落/真实排版行装页 + 中文字符/英文词距两端对齐
  -> ReaderSelectionRegion 原生选择手柄/平台复制分享 + 选区书签/高亮/下划线
  -> BookContentProcessGateway -> ReaderRepository -> BookContentProcessDao
  -> 缓存未命中：先测首批页面/恢复锚点页，_ReaderIncrementalPageLayoutJob 后台分批续算完整页集
  -> 超长无换行段落按有限字符块测量，完整页集写入 ReaderPageLayoutCache 最近三套 LRU
  -> ReaderPagedContent 左右跟手覆盖翻页
  -> ReaderDisplayConfig 左/中/右点击动作、点击区宽度和音量键翻页配置；旧长按字段只兼容读取
  -> ReaderSystemInfoText 时间/电量页眉页脚 + ReaderPlatformService 亮度/方向/电量窄桥
  -> 章节边界：保留旧页加载相邻章 + _ReaderChapterCoverSwitch 跨章覆盖衔接
  -> ReaderViewModel 稳定字符锚点与切章防抖
  -> ReadBookCoordinator 有界预下载、并发 2、失败上限 3
  -> ReaderRepository 持久化阅读方式与预下载数量
```

领域结果文件为 `domain/model/book_shelf_state.dart` 和
`domain/model/add_book_to_bookshelf_result.dart`；冲突解析入口为
`domain/usecase/resolve_book_shelf_state_use_case.dart`。分页文件依赖 Flutter 排版测量，因此位于
`ui/reader/reader_page_layout.dart`，不得下沉到平台无关 Domain。

## 8. 数据层索引

当前 Schema v8 的核心表定义位于 `data/local/legado_database.dart`：

| 表 | DAO | 领域入口 / Repository |
|---|---|---|
| `books` | `BookDao` | `BookshelfGateway`、`ReadingProgressGateway` / `BookRepository` |
| `book_groups` | `BookGroupDao` | `BookGroupGateway` / `BookGroupRepository` |
| `book_sources` | `BookSourceDao` | `BookSourceGateway` / `BookSourceRepository` |
| `chapters` | `BookChapterDao` | `ChapterGateway` / `BookRepository` |
| `reading_history_books`、`reading_history_chapters` | `ReadingHistoryDao` | `ReadingHistoryGateway` / `ReadingHistoryRepository` / `RecordReadingHistoryUseCase`；与书架主键和目录外键独立 |
| `searchBooks` | `SearchBookDao` | 当前为数据层缓存能力，修改前确认真实调用方 |
| `bookmarks` | `BookmarkDao` | `BookmarkGateway` / `ReaderRepository` |
| `book_content_processes` | `BookContentProcessDao` | `BookContentProcessGateway` / `ReaderRepository` / `SaveBookContentProcessUseCase` |
| `cookies` | `CookieDao` | `LegadoCookieManager` |
| `caches` | `CacheDao` | `ReaderCacheGateway`、`SearchHistoryGateway`、JS cache API、`AnalyticsRecorder` 授权/事件桶、`SourceSuccessRateReporter` 聚合桶 |
| `replace_rules` | `ReplaceRuleDao` | `ReplaceRuleGateway` / `ReaderRepository` |
| `download_tasks`、`download_book_states` | `DownloadTaskDao` | `DownloadGateway` / `DownloadRepository` / App 级 `DownloadCoordinator`；任务归因、批次评分和自动换源锁定均持久化 |

数据库字段和 Android 映射先查 [`m02/01_field_mapping.md`](./m02/01_field_mapping.md)，全局文件映射查 [`m00/03_file_mapping.md`](./m00/03_file_mapping.md)。不要从 UI 文案反推字段可空性或主键语义。

## 9. 网络、规则与 JavaScript 边界

网络唯一入口契约是 `api/http/http_contract.dart` 中的 `UnifiedHttpClient`。实现默认是 `DioUnifiedHttpClient`。新增网络行为时需要同时核对：

- 请求方法、Body、Header 和 Cookie 模式；
- 重定向后的最终 URL；
- 取消令牌和超时分类；
- 原始字节、压缩、字符集和解码顺序；
- 敏感 Header、Cookie、正文和文件路径不能进入日志。

普通规则入口：

- 规则 DTO：`model/analyze_rule/source_rules.dart`；
- 选择和组合：`model/analyze_rule/standard_rule_engine.dart`；
- 搜索、详情、目录、正文结果转换：`model/web_book/standard_source_parser.dart`；
- 四段请求编排：`model/web_book/standard_source_service.dart`。

JavaScript 入口：

- 抽象与错误：`api/js/js_engine.dart`；
- JSF/QuickJS 实现：`api/js/jsf_engine.dart`，包含异步宿主调用等待、有限同步结果重放、响应代理、超时、取消和资源释放；
- 按书源隔离：`api/js/js_engine_pool.dart`；
- Legado API：`api/js/legado_script_bridge.dart`；`api/js/script_context.dart` 提供业务操作、默认拒绝交互策略，以及 URL、响应和解析阶段共享的 `LegadoScriptExecutionState` 与 Book/Chapter 可变快照；`api/js/script_interaction_broker.dart` 提供开启交互后的应用级 FIFO 单消费者队列、取消隔离和页面结果回传；
- Java 白名单：`api/js/java_compatibility_bridge.dart`；
- 规则层门面：`model/analyze_rule/legado_javascript_service.dart`。
- 普通规则与脚本顺序串联：`model/analyze_rule/legado_rule_evaluator.dart`；纯普通规则保持 isolate 快路径，含脚本、`@put` 或 `@get` 的规则进入共享状态执行链。

书源运行变量通过 `BookSourceGateway`/`BookSourceRepository` 读写 `sourceVariable_书源URL` 独立缓存键，书源编辑器提供输入入口；`LegadoScriptBridge.prepareContext` 在执行前预载，使 `source.getVariable()` 保持同步返回。JSF 宿主桥使用结构化信封传播失败，避免 Dart 异常对象被当作脚本业务值。`org.jsoup.Jsoup` 只有基于现有 `html` 依赖的固定只读白名单，不代表任意 JVM 类兼容。

搜索、详情、目录和正文已经通过 `StandardBookSourceService` 接入同一混合执行入口；响应按 `bodyJs`、`loginCheckJs` 顺序处理，正文入口提供 `book/chapter/nextChapterUrl`。目录 `preUpdateJs` 只在用户主动刷新或重试时于首请求前执行，对齐 Android `runPerJs`；`java.reGetBook/refreshTocUrl` 通过仅限该上下文的受控回调完成同书源精确搜索或详情刷新。URL `webView/webJs/webViewDelayTime` 和正文 `webJs/sourceRegex` 进入 `FlutterWebViewScriptBridge`，`sourceRegex` 通过页面开始时安装的 PerformanceObserver 和 Resource Timing 匹配资源 URL。设置页持久保存“搜索时允许书源登录与验证提示”，默认关闭；关闭时交互 API 以 `interactionRequired` 结束当前书源，不弹窗。开启后由 `script_interaction_broker.dart` 串行派发，`ui/search/search_route.dart` 承载确认与验证码输入，`ui/book_source/book_source_login_route.dart` 承载可见 WebView 并回传最终页面与 Cookie。当前仍不能宣称：请求前递归刷新和资源观察的真机等价性、可见交互的真实书源双端通过、Rhino/JVM 全兼容、真实书源和双端真机通过。具体样本和阻塞见 [`m04/README.md`](./m04/README.md)、[`m04/05_collection_validation_samples.md`](./m04/05_collection_validation_samples.md) 与 [`m10/README.md`](./m10/README.md)。

P0 集中验收入口：[`P0_PENDING_VERIFICATION_CHECKLIST.md`](./P0_PENDING_VERIFICATION_CHECKLIST.md)。该文档统一记录 S1～S8 书源四段链路、登录与单提示队列、阅读稳定性与进度恢复、整书/单章换源数据安全的 Android/iOS 最终结果；仅用于验收记录，不替代实现事实和阶段门禁。

## 10. 平台宿主索引

| 能力 | Dart 边界 | Android 宿主 | iOS 宿主 |
|---|---|---|---|
| 阅读沉浸模式、常亮、亮度、方向和电量 | `platform/reader_platform_service.dart` | `android/app/src/main/kotlin/io/legado/flutter/MainActivity.kt` | `ios/Runner/AppDelegate.swift` |
| 登录/注册密码 RSA-OAEP-SHA256 加密 | `platform/password_encryption_platform_service.dart` | `MainActivity.kt` 的 `io.legado.flutter/password_encryption` 通道 | `AppDelegate.swift` 的同名通道和 `SecKey` | [`m11/backend_api_integration/04_authentication_rsa_oaep_upgrade_design.md`](./m11/backend_api_integration/04_authentication_rsa_oaep_upgrade_design.md) |
| 书源文件和登录 | `platform/book_source_platform_bridge.dart`、`ui/book_source/book_source_login_route.dart` | file_picker + 官方 Android WebView + 统一 Cookie | Document Picker + 官方 WKWebView + 统一 Cookie |
| 本地书文件选择 | `platform/local_book_platform_bridge.dart` | `file_picker` / SAF | `file_picker` / Document Picker |
| 二维码相机 | `ui/book_source/book_source_qr_scanner_route.dart` | Manifest 相机权限 + `mobile_scanner` | `Info.plist` 用途说明 + `mobile_scanner` |
| 页面 WebView/Cookie | `api/js/webview_script_bridge.dart`、`api/cookie/flutter_webview_cookie_bridge.dart` | 系统 WebView；超时/取消/释放代码待真机 | WKWebView/WKHTTPCookieStore；超时/取消/释放代码待真机 |

平台差异先查 [`m00/07_platform_capability_matrix.md`](./m00/07_platform_capability_matrix.md) 和 [`m09/04_m10_handoff.md`](./m09/04_m10_handoff.md)。原生宿主只能提供窄能力，不能复制 Dart 业务状态机。

## 11. 当前阶段快照

截至本次静态核对：

- M1～M8.1 已有实现代码，但仍缺用户完整运行证据，不能将“文件存在”写成阶段通过。
- M4 JavaScript 兼容仍为 `BLOCKED`；同步网络重放、共享模型/规则状态、登录检测、可见交互队列、请求前脚本（含 `reGetBook/refreshTocUrl`）和后台 WebView 基础链路已进入验证，核心剩余问题包含 S1～S8 双平台结果、实时资源嗅探差异和 Java Helper 长尾。
- 用户本回合要求执行 M10 后，iOS 平台代码和验收文档已接入；这不等同于 Android A2 或 iOS 真机通过。
- M10 仍受 M9 和 M4 门禁约束，状态保持 `IN_PROGRESS`；安装、签名、JSF、WebView/Cookie、文件安全作用域和核心路径都等待用户结果。
- M11 全功能迁移尚不能替代核心闭环验收。
- 用户在获知 M10 尚待真机验收后要求继续执行 M11；整书换源、单章换源、离线下载及书架历史双页/API 质量上报均为代码已写入、等待用户验证，该决定不等同于 M9/M10 通过。
- UI 与阅读器重构已写入 R1～R5 第一批实现；未运行编译、分析、测试、格式化或应用启动，阶段保持 `IN_PROGRESS`，具体未完成项见重构方案的“实施快照”。
- 小说正文阅读界面完整 UI 对齐已有 P0～P4 优先级文档，状态为 `IN_PROGRESS`；默认左右覆盖翻页、章节标题分页、首行缩进、两端对齐、长章节首屏增量分页、后台分批续算、完整分页 LRU、点击区域、音量键翻页、页眉页脚时间/电量、亮度、方向、原生文字选择和用户高亮/下划线已写入 Flutter，但尚无用户运行证据。
- 小说阅读详情页完整 UI 对齐已有 P0～P3 优先级文档，状态为 `IN_PROGRESS`；P0～P3 基础入口和可用子集已写入 Flutter 详情页但尚无用户运行证据，依赖型能力仍按文档继续拆分。
- 书架/历史双页、阅读不自动入架、阅读器显式加入书架按钮、底栏重排、选择模式可见性退出，以及书源成功率和阅读匿名埋点已写入；Schema 为 v8、构建号为 `+6`，尚无用户运行证据。

状态入口：

| 问题 | 文档 |
|---|---|
| 现在做到哪一步 | 各 `mXX/README.md`，尤其 [`m09/README.md`](./m09/README.md) |
| Android 核心验收项 | [`m09/02_core_and_exception_matrix.md`](./m09/02_core_and_exception_matrix.md) |
| 已知缺陷和回归 | [`m09/03_issue_and_regression_log.md`](./m09/03_issue_and_regression_log.md) |
| 下一阶段交接 | [`m09/04_m10_handoff.md`](./m09/04_m10_handoff.md) |
| M10 当前实现与阻断 | [`m10/README.md`](./m10/README.md) |
| iOS 能力与平台差异 | [`m10/01_ios_capability_inventory.md`](./m10/01_ios_capability_inventory.md) |
| iOS 签名与真机步骤 | [`m10/02_ios_signing_and_device_run.md`](./m10/02_ios_signing_and_device_run.md) |
| iOS 样本与验收矩阵 | [`m10/03_ios_compatibility_report.md`](./m10/03_ios_compatibility_report.md)、[`m10/04_ios_acceptance_matrix.md`](./m10/04_ios_acceptance_matrix.md) |
| iOS 启动白屏、数据库锁等待与认证输入焦点分析 | [`m10/05_ios_startup_white_screen_database_lock_analysis.md`](./m10/05_ios_startup_white_screen_database_lock_analysis.md)：启动期内置书源导入与离线下载恢复的 SQLite 竞争，以及认证页被重复会话恢复层覆盖的 iOS 输入焦点问题、修复范围与用户验收重点 |
| M11 当前 Feature 与门禁记录 | [`m11/README.md`](./m11/README.md) |
| App 后端 API 接入范围、HMAC 决策、P0 启动/过滤基础设施与后续实施顺序；2026-07-23 App API 文档的登录、日志、版本和更新契约差异 | [`m11/backend_api_integration/01_implementation_plan.md`](./m11/backend_api_integration/01_implementation_plan.md)、[`05_app_api_20260723_gap_analysis.md`](./m11/backend_api_integration/05_app_api_20260723_gap_analysis.md) |
| App 用户注册登录、RSA-OAEP 密码传输、邀请码、权限读取、内存会话与导出 API 契约缺口；安全持久化 Token、启动/前台自动恢复与双 Token 迁移设计 | [`m11/backend_api_integration/02_authentication_and_api_gap_plan.md`](./m11/backend_api_integration/02_authentication_and_api_gap_plan.md)、[`04_authentication_rsa_oaep_upgrade_design.md`](./m11/backend_api_integration/04_authentication_rsa_oaep_upgrade_design.md)、[`06_persistent_auth_session_design.md`](./m11/backend_api_integration/06_persistent_auth_session_design.md)、[`07_dual_token_session_migration_design.md`](./m11/backend_api_integration/07_dual_token_session_migration_design.md) |
| App 准入轮询、拒绝阻断、Android 退出与升级弹窗的平台差异 | [`m11/backend_api_integration/03_app_access_and_update_plan.md`](./m11/backend_api_integration/03_app_access_and_update_plan.md) |
| App 埋点候选事件、隐私边界、props 白名单与实施顺序 | [`m11/backend_api_integration/08_analytics_event_catalog_proposal.md`](./m11/backend_api_integration/08_analytics_event_catalog_proposal.md) |
| 整书换源行为、映射与验收 | [`m11/change_source/01_android_behavior_inventory.md`](./m11/change_source/01_android_behavior_inventory.md)、[`02_mapping_and_design.md`](./m11/change_source/02_mapping_and_design.md)、[`03_acceptance_matrix.md`](./m11/change_source/03_acceptance_matrix.md) |
| 功能是否纳入首批 | [`m00/04_feature_matrix.md`](./m00/04_feature_matrix.md) |
| Android 与 Flutter 文件对应 | [`m00/03_file_mapping.md`](./m00/03_file_mapping.md) |

## 12. AI 搜索配方

以下命令只用于只读定位，不代表允许运行检查：

```bash
# 列出 Flutter 业务源码，排除生成物
rg --files lib android/app/src/main ios/Runner

# 找路由声明和跳转调用
rg -n "AppRoute\\.|pushNamed|onGenerateRoute" lib

# 找一个功能的 UiState、Intent、Effect、ViewModel、Route 和 Screen
rg -n "BookSourceManagement|Search|BookInfo|Bookshelf|Reader" lib/src/ui

# 找 Gateway 到 Repository 的实现关系
rg -n "abstract interface class .*Gateway|implements .*Gateway" \
  lib/src/domain lib/src/data

# 找组合根中的真实依赖创建和注入位置
rg -n "required this\\.|final .* =|create.*Coordinator" \
  lib/src/app/app_dependencies.dart

# 从 Android 类名反查 Flutter 映射文档
rg -n "AndroidClassName|FlutterClassName" docs/flutter-rewrite/m00/03_file_mapping.md

# 查找禁止的强制空值断言时，排除注释和非业务生成物后人工判断
rg -n "!" lib -g "*.dart"
```

不要搜索或修改 `build/`、`.dart_tool/`、`android/.gradle/` 中的生成结果来修复源码问题。

## 13. 修改前最小上下文清单

开始编码前至少回答：

- 本次唯一目标是什么，明确不包含什么？
- Android 的入口、状态、数据、副作用、权限和返回行为在哪里？
- Flutter 已有 Contract、ViewModel、协调器、Gateway 或平台抽象能否复用？
- 改动是否跨越 UI、Domain、Data、API、Model 或 Platform 边界？
- 是否影响数据库 Schema、路由参数、书源兼容或平台通道？
- 当前阶段文档中的阻塞是否会让“成功实现”成为错误宣称？
- 用户可以执行哪些验收步骤？
- 是否产生新文件，需要在交付时询问 `git add`？

只修改本目标需要的文件。不要顺手更新无关格式、清理旧代码或重构 Android 参考实现。

## 14. 索引维护规则

AI 在 `lib/`、`android/`、`ios/` 等仓库业务代码或 `docs/flutter-rewrite/` 下新增任何手写文件时，必须在同一任务交付前更新本索引的相关章节，使新文件能够按职责、功能、路由、调用链、平台边界或迁移阶段被后续 AI 定位。即使新增文件不改变功能状态，也不能让它成为索引无法解释的孤立文件。

索引不要求机械维护“一文件一行”的完整清单。若现有功能入口已经能够准确覆盖新文件，应更新该功能入口、目录职责或调用链；若现有结构无法覆盖，则新增最小必要索引项。

生成文件和构建产物不进入索引，包括 `.dart_tool/`、`build/`、`.gradle/`、`ios/Flutter/ephemeral/` 和自动生成的插件注册文件。AI 不应为了满足本规则而修改生成物。

发生以下变化时，应在同一任务中评估是否更新本索引：

- 新增、删除或重命名稳定路由；
- 新增功能目录或改变 Route / ViewModel / Screen 分层；
- Gateway、Repository、UseCase 或组合根职责发生变化；
- 数据库 Schema 版本、表或主键语义变化——修改 `LegadoDatabase.schemaVersion` 时必须同时给
  新字段补 `onUpgrade` 的 `ALTER TABLE` 迁移分支，并同步把 `pubspec.yaml` 的
  `version` build number（`+` 后面的整数）加一，让带 Schema 变化的构建始终能从版本号区分；
- 新增原生通道、Flutter 插件或平台差异；
- JavaScript、WebView、Cookie 或本地书格式的支持边界变化；
- 阶段门禁正式由用户确认通过。

更新索引时记录“最后静态核对”日期，但不要仅因源码已写完就把 `IN_PROGRESS`、`BLOCKED` 改成 `DONE`。
