# Legado Flutter AI 项目索引

> 用途：帮助 AI 编码代理在修改 `flutter_app/` 前，快速找到规则、实现入口、Android 对照、阶段文档和已知阻塞。
>
> 本文件是导航索引，不替代强制规则、源码事实、阶段验收记录或用户当前回合的明确要求。
>
> 最后静态核对：2026-07-16。未运行编译、测试、分析、格式化或应用启动。

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
| Flutter 子项目 | `flutter_app/` |
| Dart 入口 | `flutter_app/lib/main.dart` |
| Flutter/Dart 固定版本 | Flutter `3.41.5 stable`、Dart `3.11.3` |
| Android applicationId | `io.legado.flutter` |
| Android minSdk | `26` |
| iOS Bundle Identifier | `io.legado.flutter` |
| iOS Deployment Target | `16.0` |
| 独立数据库 | `legado_flutter.db`，当前 Schema v4 |
| 原 Android 参考实现 | `app/src/main/java/io/legado/app/` |
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
Widget 窗口、离线下载和其余页面视觉重构仍未完成。
小说正文阅读界面完整 UI 对齐的实施优先级见
[`m08/01_reader_ui_rebuild_priority.md`](./m08/01_reader_ui_rebuild_priority.md)。该文档当前为
`IN_PROGRESS`；P0～P4 可落地阅读 UI 已写入 Flutter，依赖型能力已用边界面板登记，TTS、
离线下载、AI、同步和单章换源等仍等待对应子系统迁移。
小说阅读详情页完整 UI 对齐的实施优先级见
[`m06/01_book_info_ui_rebuild_priority.md`](./m06/01_book_info_ui_rebuild_priority.md)。该文档当前为
`IN_PROGRESS`；P0～P3 基础入口已写入 Flutter 详情页但尚无用户运行证据，阅读记录、
换封面、相关书、书源登录/变量、Web 文件、清缓存、日志和同步仍需后续业务能力。

## 3. 总体启动链

```text
flutter_app/lib/main.dart
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
| 进程入口与全局错误兜底 | `flutter_app/lib/main.dart` | 初始化顺序、日志后备实现、`runZonedGuarded` |
| 应用组合根 | `flutter_app/lib/src/app/app_dependencies.dart` | DAO、Repository、HTTP、JS、协调器和 UseCase 的唯一集中装配处 |
| 内置书源启动导入 | `flutter_app/lib/src/app/default_book_source_bootstrapper.dart` | 新库首次启动时从 Flutter assets 导入默认书源，复用书源导入 UseCase |
| 路由常量 | `flutter_app/lib/src/app/app_route.dart` | 应用内稳定路由名 |
| 路由与参数校验 | `flutter_app/lib/src/app/app_router.dart` | Route 创建、构造注入、无效参数错误页 |
| 根 Widget | `flutter_app/lib/src/app/legado_app.dart` | 主题、初始路由、路由观察器和错误边界 |
| 全局错误边界 | `flutter_app/lib/src/app/app_error_boundary.dart` | Flutter 框架与平台调度错误 |
| 导航观察 | `flutter_app/lib/src/app/app_navigation_observer.dart` | 页面切换诊断日志 |

新增共享依赖时，先判断它属于 Gateway、Repository、UseCase、运行时协调器还是平台服务，再从 `AppDependencies` 接线；不要在页面中临时创建第二套网络、数据库或日志实现。

## 4. 目录职责索引

| 目录 | 职责 | 不应放入 |
|---|---|---|
| `flutter_app/lib/src/app/` | 启动、组合根、路由、应用级错误边界 | 功能业务逻辑 |
| `flutter_app/lib/src/ui/` | Contract、ViewModel、Route、Screen、共享 UI | DAO、HTTP、文件解析 |
| `flutter_app/lib/src/domain/model/` | 平台无关、存储无关的领域模型 | sqflite Map、Widget 状态 |
| `flutter_app/lib/src/domain/gateway/` | 领域所需能力的抽象边界 | 插件或 DAO 具体类型 |
| `flutter_app/lib/src/domain/usecase/` | 跨 Gateway 的明确业务动作 | 页面导航、SnackBar |
| `flutter_app/lib/src/data/dao/` | 单表或紧密相关表的 SQL 读写 | UI 状态和网络请求 |
| `flutter_app/lib/src/data/repository/` | Gateway 实现、事务和数据错误转换 | Widget 或 `BuildContext` |
| `flutter_app/lib/src/data/local/` | 数据库、表名、行读取、变更通知 | 功能页面状态 |
| `flutter_app/lib/src/data/model/` | 外部数据进入领域前的解码边界 | 页面 DTO |
| `flutter_app/lib/src/api/http/` | 统一 HTTP 契约、Dio 实现、URL 解析、响应解码 | 书源页面状态 |
| `flutter_app/lib/src/api/cookie/` | HTTP Cookie 持久化、Android WebView/WKWebView 按域同步 | 独立第二套 Cookie 存储 |
| `flutter_app/lib/src/api/js/` | JS 引擎、实例池、桥接、执行上下文 | 具体页面流程 |
| `flutter_app/lib/src/model/analyze_rule/` | 普通规则和 JavaScript 规则服务 | 导航和数据库 SQL |
| `flutter_app/lib/src/model/web_book/` | 搜索、详情、目录、正文编排 | Widget |
| `flutter_app/lib/src/model/bookshelf/` | 书架刷新运行时协调 | 页面渲染 |
| `flutter_app/lib/src/model/reader/` | 正文获取、处理、缓存和预加载协调 | 平台窗口直接调用 |
| `flutter_app/lib/src/model/local_book/` | 文件副本、格式识别、解析和导入协调 | 文件选择器 UI |
| `flutter_app/lib/src/platform/` | 文件选择、WebView 登录、阅读系统能力等窄接口 | 跨平台业务状态机 |
| `flutter_app/lib/src/help/error/` | 稳定应用错误与结果类型 | 功能专属状态 |
| `flutter_app/lib/src/help/logging/` | 日志抽象、文件日志、日志管理能力 | 敏感正文、Cookie、Token |
| `flutter_app/lib/src/ui/components/` | 至少两个页面复用的无状态组件 | 单页面业务抽象 |
| `flutter_app/lib/src/ui/theme/` | Material 3 主题和 Design Token | 功能状态 |
| `flutter_app/packages/` | 将来确有必要的自研平台插件 | 没有调用方的预留空壳 |

`.dart_tool/`、`build/`、`.gradle/`、`ios/Flutter/ephemeral/` 和生成的插件注册文件不是业务实现索引来源。

## 5. 路由与页面索引

| 路由 | Route / Screen | 状态入口 | 参数或说明 |
|---|---|---|---|
| `/` | `ui/home/welcome_route.dart` / `welcome_screen.dart` | `WelcomeViewModel` | 正式应用 Shell；手机底部导航、宽屏 NavigationRail，IndexedStack 保留书架/搜索/书源/设置状态 |
| `/settings` | `ui/settings/settings_route.dart` / `settings_screen.dart` | 当前为轻量无状态接线 | 设置入口 |
| `/settings/logs` | `ui/log_management/log_management_route.dart` / `log_management_screen.dart` | `LogManagementViewModel` | 查看、分享、ADB 回显和删除沙盒日志 |
| `/book-sources` | `ui/book_source/book_source_route.dart` / `book_source_screen.dart` | `BookSourceManagementViewModel` | 书源管理、导入、扫码和编辑 |
| `/search` | `ui/search/search_route.dart` / `search_screen.dart` | `SearchViewModel` | 多书源搜索和搜索历史 |
| `/book-info` | `ui/book_info/book_info_route.dart` / `book_info_screen.dart` | `BookInfoViewModel` | 必须传 `BookInfoRouteArguments` |
| `/bookshelf` | `ui/bookshelf/bookshelf_route.dart` / `bookshelf_screen.dart` | `BookshelfViewModel` | 实时书架、分组、排序、批量操作 |
| `/local-books/import` | `ui/local_book_import/local_book_import_route.dart` / `local_book_import_screen.dart` | `LocalBookImportViewModel` | 系统文件选择和导入 |
| `/reader` | `ui/reader/book_reader_route.dart` | `ReaderViewModel` | 必须传非空 `bookUrl`；PDF 分流到 `PdfReaderRoute`，其余进入 `ReaderRoute`；P0/P2 文本阅读菜单浮层和刷新范围入口在 `reader_menu_overlay.dart`，P1/P3 设置面板在 `reader_settings_sheet.dart`，P2/P4 当前章/整书搜索、书签编辑、替换规则列表和后续能力面板在 `reader_action_sheets.dart` |
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
| 搜索 | `ui/search/` | `BookSearchCoordinator`、`SearchHistoryRepository`、`StandardBookSourceService` | `ui/book/search/` | [`m06/README.md`](./m06/README.md) |
| 详情和目录 | `ui/book_info/` | `BookDetailService`、`SaveBookChaptersUseCase`、`AddBookToBookshelfUseCase` | `ui/book/info/`、`model/webBook/` | [`m06/README.md`](./m06/README.md)、[`m06/01_book_info_ui_rebuild_priority.md`](./m06/01_book_info_ui_rebuild_priority.md) |
| 书架 | `ui/bookshelf/` | `BookRepository`、`BookGroupRepository`、`BookshelfRefreshCoordinator` | `ui/main/bookshelf/` | [`m07/README.md`](./m07/README.md) |
| 网络书正文阅读 | `ui/reader/` | `ReadBookCoordinator`、`ReaderTextProcessor`、`ReaderRepository`、`ReaderSearchState`、`ReaderDisplayConfig` | `ui/book/read/`、`model/ReadBook.kt` | [`m08/README.md`](./m08/README.md)、[`m08/01_reader_ui_rebuild_priority.md`](./m08/01_reader_ui_rebuild_priority.md) |
| 整书换源 | `ui/change_book_source/` | `ChangeSourceCoordinator`、`ChangeBookSourceUseCase`、`BookRepository.changeBookSource` | `ui/book/changesource/`、`ChangeSourceSearchUseCase.kt`、`ChangeBookSourceUseCase.kt` | [`m11/README.md`](./m11/README.md) |
| 单章换源 | `ui/change_chapter_source/`（阅读器内 `ReaderChangeChapterSourceSheet`） | `ChangeChapterSourceCoordinator`、`chapter_title_matcher.dart`、`ReadBookCoordinator.invalidateChapter` | `ui/book/read/sheet/ChangeChapterSourceSheet.kt`、`BookHelp.getDurChapter`、`BookHelp.saveText` | [`m11/chapter_change_source/README.md`](./m11/chapter_change_source/README.md) |
| 离线下载 | `ui/reader/reader_download_sheet.dart`（阅读器内 `ReaderDownloadSheet`） | `DownloadCoordinator`（App 级单例）、`DownloadTaskDao`/`DownloadRepository`、`download_tasks` 表 | `ui/book/read/sheet/DownloadSheet.kt`、`CacheBook`/`CacheBookModel`、`CacheBookService`（前台服务未迁移） | [`m11/offline_download/README.md`](./m11/offline_download/README.md) |
| 本地书导入 | `ui/local_book_import/` | `LocalBookImportCoordinator`、`LocalBookStorage`、各格式 Parser | `model/localBook/` 和原文件导入入口 | [`m08_1/README.md`](./m08_1/README.md) |
| PDF 阅读 | `ui/reader/pdf_reader_route.dart` | `PdfLocalBookParser`、`pdfx` | `model/localBook/PdfFile.kt` | [`m08_1/README.md`](./m08_1/README.md) |
| 阅读系统栏和常亮 | `platform/reader_platform_service.dart` | Android `MainActivity.kt`、iOS `AppDelegate.swift` | 原阅读 Activity/窗口逻辑 | [`m09/04_m10_handoff.md`](./m09/04_m10_handoff.md) |
| 日志与设置 | `ui/settings/`、`ui/log_management/` | `help/logging/`、`AppDependencies` | `ui/widget/components/log/` 等现有日志入口 | 当前源码；修改前搜索最新专项目标文档 |
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
`flutter_app/assets/default_data/book_sources.json`，并继续走 `ImportBookSourcesUseCase` 与
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

当前只覆盖单本网络书的整书换源。单章、自动、批量换源、候选书源管理和缓存下载仍是独立 M11 Feature，不能因本路由存在而宣称完成。

### 7.6 同书冲突、分页与阅读预下载

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
  -> 缓存未命中：先测首批页面/恢复锚点页，_ReaderIncrementalPageLayoutJob 后台分批续算完整页集
  -> 超长无换行段落按有限字符块测量，完整页集写入 ReaderPageLayoutCache 最近三套 LRU
  -> ReaderPagedContent 左右跟手覆盖翻页
  -> ReaderDisplayConfig 左/中/右点击动作、长按动作、点击区宽度和音量键翻页配置
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

当前 Schema v2 的核心表定义位于 `data/local/legado_database.dart`：

| 表 | DAO | 领域入口 / Repository |
|---|---|---|
| `books` | `BookDao` | `BookshelfGateway`、`ReadingProgressGateway` / `BookRepository` |
| `book_groups` | `BookGroupDao` | `BookGroupGateway` / `BookGroupRepository` |
| `book_sources` | `BookSourceDao` | `BookSourceGateway` / `BookSourceRepository` |
| `chapters` | `BookChapterDao` | `ChapterGateway` / `BookRepository` |
| `searchBooks` | `SearchBookDao` | 当前为数据层缓存能力，修改前确认真实调用方 |
| `bookmarks` | `BookmarkDao` | `BookmarkGateway` / `ReaderRepository` |
| `cookies` | `CookieDao` | `LegadoCookieManager` |
| `caches` | `CacheDao` | `ReaderCacheGateway`、`SearchHistoryGateway`、JS cache API |
| `replace_rules` | `ReplaceRuleDao` | `ReplaceRuleGateway` / `ReaderRepository` |

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
- JSF/QuickJS 实现：`api/js/jsf_engine.dart`；
- 按书源隔离：`api/js/js_engine_pool.dart`；
- Legado API：`api/js/legado_script_bridge.dart`；
- Java 白名单：`api/js/java_compatibility_bridge.dart`；
- 规则层门面：`model/analyze_rule/legado_javascript_service.dart`。
- 普通规则与脚本顺序串联：`model/analyze_rule/legado_rule_evaluator.dart`；纯普通规则保持 isolate 快路径，含脚本规则进入 QuickJS。

书源运行变量通过 `BookSourceGateway`/`BookSourceRepository` 读写 `sourceVariable_书源URL` 独立缓存键，书源编辑器提供输入入口；`LegadoScriptBridge.prepareContext` 在执行前预载，使 `source.getVariable()` 保持同步返回。JSF 宿主桥使用结构化信封传播失败，避免 Dart 异常对象被当作脚本业务值。`org.jsoup.Jsoup` 只有基于现有 `html` 依赖的固定只读白名单，不代表任意 JVM 类兼容。

搜索、详情、目录和正文已经通过 `StandardBookSourceService` 接入同一混合执行入口，不再把所有脚本书源预先标成 `javascriptPending`。M10 已新增 `FlutterWebViewScriptBridge` 和 `FlutterWebViewCookieBridge`，Android/iOS 使用官方系统 WebView 按域同步统一 Cookie；书源登录入口位于 `ui/book_source/book_source_login_route.dart`。当前仍不能宣称的能力：Rhino/JVM 全兼容、历史同步 `java.ajax/connect/get/post` 透明兼容、WebView/Cookie 真机样本通过、Android/iOS 真机 JSF 已通过。具体样本和阻塞见 [`m04/README.md`](./m04/README.md)、[`m04/05_collection_validation_samples.md`](./m04/05_collection_validation_samples.md) 与 [`m10/README.md`](./m10/README.md)。

## 10. 平台宿主索引

| 能力 | Dart 边界 | Android 宿主 | iOS 宿主 |
|---|---|---|---|
| 阅读沉浸模式、常亮、亮度、方向和电量 | `platform/reader_platform_service.dart` | `android/app/src/main/kotlin/io/legado/flutter/MainActivity.kt` | `ios/Runner/AppDelegate.swift` |
| 书源文件和登录 | `platform/book_source_platform_bridge.dart`、`ui/book_source/book_source_login_route.dart` | file_picker + 官方 Android WebView + 统一 Cookie | Document Picker + 官方 WKWebView + 统一 Cookie |
| 本地书文件选择 | `platform/local_book_platform_bridge.dart` | `file_picker` / SAF | `file_picker` / Document Picker |
| 二维码相机 | `ui/book_source/book_source_qr_scanner_route.dart` | Manifest 相机权限 + `mobile_scanner` | `Info.plist` 用途说明 + `mobile_scanner` |
| 页面 WebView/Cookie | `api/js/webview_script_bridge.dart`、`api/cookie/flutter_webview_cookie_bridge.dart` | 系统 WebView；超时/取消/释放代码待真机 | WKWebView/WKHTTPCookieStore；超时/取消/释放代码待真机 |

平台差异先查 [`m00/07_platform_capability_matrix.md`](./m00/07_platform_capability_matrix.md) 和 [`m09/04_m10_handoff.md`](./m09/04_m10_handoff.md)。原生宿主只能提供窄能力，不能复制 Dart 业务状态机。

## 11. 当前阶段快照

截至本次静态核对：

- M1～M8.1 已有实现代码，但仍缺用户完整运行证据，不能将“文件存在”写成阶段通过。
- M4 JavaScript 兼容仍为 `BLOCKED`，核心问题包含真实书源双平台结果和历史同步网络语义。
- 用户本回合要求执行 M10 后，iOS 平台代码和验收文档已接入；这不等同于 Android A2 或 iOS 真机通过。
- M10 仍受 M9 和 M4 门禁约束，状态保持 `IN_PROGRESS`；安装、签名、JSF、WebView/Cookie、文件安全作用域和核心路径都等待用户结果。
- M11 全功能迁移尚不能替代核心闭环验收。
- 用户在获知 M10 尚待真机验收后要求继续执行 M11；当前只领取整书换源，代码状态为 `IN_PROGRESS`，该决定不等同于 M9/M10 通过。
- UI 与阅读器重构已写入 R1～R5 第一批实现；未运行编译、分析、测试、格式化或应用启动，阶段保持 `IN_PROGRESS`，具体未完成项见重构方案的“实施快照”。
- 小说正文阅读界面完整 UI 对齐已有 P0～P4 优先级文档，状态为 `IN_PROGRESS`；默认左右覆盖翻页、章节标题分页、首行缩进、两端对齐、长章节首屏增量分页、后台分批续算、完整分页 LRU、点击区域、音量键翻页、页眉页脚时间/电量、亮度和方向配置已写入 Flutter，但尚无用户运行证据。
- 小说阅读详情页完整 UI 对齐已有 P0～P3 优先级文档，状态为 `IN_PROGRESS`；P0～P3 基础入口和可用子集已写入 Flutter 详情页但尚无用户运行证据，依赖型能力仍按文档继续拆分。

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
| M11 当前 Feature 与门禁记录 | [`m11/README.md`](./m11/README.md) |
| 整书换源行为、映射与验收 | [`m11/change_source/01_android_behavior_inventory.md`](./m11/change_source/01_android_behavior_inventory.md)、[`02_mapping_and_design.md`](./m11/change_source/02_mapping_and_design.md)、[`03_acceptance_matrix.md`](./m11/change_source/03_acceptance_matrix.md) |
| 功能是否纳入首批 | [`m00/04_feature_matrix.md`](./m00/04_feature_matrix.md) |
| Android 与 Flutter 文件对应 | [`m00/03_file_mapping.md`](./m00/03_file_mapping.md) |

## 12. AI 搜索配方

以下命令只用于只读定位，不代表允许运行检查：

```bash
# 列出 Flutter 业务源码，排除生成物
rg --files flutter_app/lib flutter_app/android/app/src/main flutter_app/ios/Runner

# 找路由声明和跳转调用
rg -n "AppRoute\\.|pushNamed|onGenerateRoute" flutter_app/lib

# 找一个功能的 UiState、Intent、Effect、ViewModel、Route 和 Screen
rg -n "BookSourceManagement|Search|BookInfo|Bookshelf|Reader" flutter_app/lib/src/ui

# 找 Gateway 到 Repository 的实现关系
rg -n "abstract interface class .*Gateway|implements .*Gateway" \
  flutter_app/lib/src/domain flutter_app/lib/src/data

# 找组合根中的真实依赖创建和注入位置
rg -n "required this\\.|final .* =|create.*Coordinator" \
  flutter_app/lib/src/app/app_dependencies.dart

# 从 Android 类名反查 Flutter 映射文档
rg -n "AndroidClassName|FlutterClassName" docs/flutter-rewrite/m00/03_file_mapping.md

# 查找禁止的强制空值断言时，排除注释和非业务生成物后人工判断
rg -n "!" flutter_app/lib -g "*.dart"
```

不要搜索或修改 `flutter_app/build/`、`.dart_tool/`、`android/.gradle/` 中的生成结果来修复源码问题。

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

AI 在 `flutter_app/` 或 `docs/flutter-rewrite/` 下新增任何手写文件时，必须在同一任务交付前更新本索引的相关章节，使新文件能够按职责、功能、路由、调用链、平台边界或迁移阶段被后续 AI 定位。即使新增文件不改变功能状态，也不能让它成为索引无法解释的孤立文件。

索引不要求机械维护“一文件一行”的完整清单。若现有功能入口已经能够准确覆盖新文件，应更新该功能入口、目录职责或调用链；若现有结构无法覆盖，则新增最小必要索引项。

生成文件和构建产物不进入索引，包括 `.dart_tool/`、`build/`、`.gradle/`、`ios/Flutter/ephemeral/` 和自动生成的插件注册文件。AI 不应为了满足本规则而修改生成物。

发生以下变化时，应在同一任务中评估是否更新本索引：

- 新增、删除或重命名稳定路由；
- 新增功能目录或改变 Route / ViewModel / Screen 分层；
- Gateway、Repository、UseCase 或组合根职责发生变化；
- 数据库 Schema 版本、表或主键语义变化——修改 `LegadoDatabase.schemaVersion` 时必须同时给
  新字段补 `onUpgrade` 的 `ALTER TABLE` 迁移分支，并同步把 `flutter_app/pubspec.yaml` 的
  `version` build number（`+` 后面的整数）加一，让带 Schema 变化的构建始终能从版本号区分；
- 新增原生通道、Flutter 插件或平台差异；
- JavaScript、WebView、Cookie 或本地书格式的支持边界变化；
- 阶段门禁正式由用户确认通过。

更新索引时记录“最后静态核对”日期，但不要仅因源码已写完就把 `IN_PROGRESS`、`BLOCKED` 改成 `DONE`。
