# M11 专项方案：搜索漫画、加入书架与漫画阅读

状态：`IMPLEMENTED_PENDING_VERIFICATION / 步骤 0 已通过，步骤 1～10 代码已写入并按用户要求统一留到最后验证`

最后静态核对：2026-08-02。类型、搜索/入架边界、三入口路由、章节图片解析、统一图片获取/缓存及
连续条漫、三种单页方向、当前页缩放、漫画语义进度/生命周期、相邻章预取/内存治理及错误恢复代码已写入；没有
运行 Flutter、Dart、Gradle、Xcode、构建、测试、分析、格式化或应用启动。

## 1. 唯一目标

在复用现有书源、搜索、详情、目录和书架能力的前提下，新增一条 Android/iOS 共用的网络漫画闭环：

```text
导入并启用图片书源
  -> 搜索漫画
  -> 打开详情并加载目录
  -> 加入书架
  -> 从详情、书架或阅读历史进入漫画阅读器
  -> 阅读图片章节并切换上下章
  -> 保存并恢复章节与图片页进度
```

首版必须同时覆盖 Android 和 iOS。核心规则解析、图片列表提取、进度状态机和缓存调度使用 Dart；
平台代码只承担系统图片保存、系统栏、常亮和应用生命周期等平台能力。

## 2. 首版包含与明确不包含

### 2.1 首版必须包含

1. 图片书源 `bookSourceType == 2` 正确转换为 Android 兼容的 `BookType.image == 64`。
2. 图片书源可以在书源管理中由用户启用，并参与现有多书源搜索和书源选择。
3. 搜索结果、详情候选、入架书籍、换源候选和阅读历史持续携带正确的图片类型位。
4. 详情、目录和加入书架复用现有实现，不为漫画复制第二套业务页面。
5. 从详情、书架和阅读历史打开图片书籍时进入独立漫画路由，而不是文本阅读器。
6. 从章节正文安全提取有序图片 URL，支持常见 `<img>` 与现有安全图片标记。
7. 支持条漫连续滚动、从左到右单页、从右到左单页和从上到下单页。
8. 支持双指缩放、双击缩放、加载失败重试、上下章和目录跳转。
9. 显示当前章节名、当前图片页、章节总页数和全书章节进度。
10. 保存并恢复当前章节索引与当前图片索引，返回书架时更新阅读历史。
11. 当前章和相邻章有界预取；大图解码、内存缓存和磁盘缓存有明确上限及失效策略。
12. 图片请求复用统一 Cookie、书源 Header、Referer、超时和取消边界。
13. 图片书籍换源只能搜索兼容的图片来源，不能静默切换为音频或普通文本来源。
14. 无图片、图片地址损坏、登录失效、付费章节、网络失败和缓存损坏均提供明确恢复入口。

### 2.2 后续增强，不阻塞首版闭环

- 自动滚动和自动翻页。
- 九宫格点击区域自定义。
- 音量键翻页及反向音量键。
- 长按保存或分享当前图片。
- 漫画颜色滤镜、灰度和墨水屏阈值。
- 页脚字段、排列和对齐的完整自定义。
- 漫画图片批量离线下载、下载管理和后台续传。
- 本地 ZIP、RAR、7Z 漫画包导入与阅读。
- 图片型 EPUB、UMD、MOBI/AZW 漫画阅读。
- 阅读进度云同步和跨设备恢复。

### 2.3 明确不包含

- 修改只读 Android 参考仓库。
- 借漫画功能重构文本阅读器、PDF 阅读器或现有搜索 UI。
- 把漫画整章图片内容或图片二进制写入 MMKV。
- 用文本排版页或字符偏移假装漫画图片页。
- 在首版承诺任意付费、加密、验证码或任意 Java/Rhino API 书源均兼容。

## 3. Android 功能基准

### 3.1 入口与分流

| Android 责任 | 文件或行为 |
|---|---|
| 图片书源类型 | `constant/BookSourceType.kt`：`image = 2` |
| 书籍位掩码 | `constant/BookType.kt`：`image = 64` |
| 类型转换 | `help/source/BookSourceExtensions.kt#getBookType` |
| 搜索结果赋值 | `model/webBook/BookList.kt` 使用 `bookSource.getBookType()` |
| 详情阅读分流 | `ui/book/info/BookInfoRouteScreen.kt` 判断 `book.isImage` 后打开 `ReadMangaActivity` |
| 漫画阅读入口 | `ui/book/manga/ReadMangaActivity.kt` |

图片书源类型和书籍类型不是同一组数值。图片书源的值是 `2`，持久化书籍图片位是 `64`，实现时不得直接赋值。

### 3.2 阅读业务

| Android 文件 | 主要责任 |
|---|---|
| `model/ReadManga.kt` | 当前书、章节窗口、图片页、预取、进度保存、目录更新和进度同步 |
| `ui/book/manga/ReadMangaViewModel.kt` | 初始化、详情/目录补载、换源、入架、移出书架和单书配置 |
| `ui/book/manga/entities/MangaPage.kt` | 章节索引、图片索引、图片 URL、章节名和图片总数 |
| `ui/book/manga/entities/MangaChapter.kt` | 章节事实、页面集合和图片数量 |
| `ui/book/manga/recyclerview/MangaAdapter.kt` | 图片页面渲染、预载和颜色处理 |
| `ui/book/manga/recyclerview/MangaLayoutManager.kt` | 阅读方向、页面定位和滚动行为 |
| `model/ImageProvider.kt` | 图片文件缓存、尺寸读取、位图解码和内存 LRU |
| `help/book/BookHelp.kt#flowImages` | 从章节正文按顺序提取绝对图片 URL |

Android 同时保留上一章、当前章和下一章的漫画页面集合；滚动跨过章节边界时更新章节索引，当前图片位置写入
`Book.durChapterPos`。Flutter 可以继续复用数据库字段，但领域层必须使用明确的 `MangaReadingPosition`
表达“图片索引”，不能把它当成文本字符偏移。

### 3.3 Android 阅读模式

| 数值 | 模式 | 首版 |
|---:|---|---|
| 1 | 单页，从左到右 | 必须 |
| 2 | 单页，从右到左 | 必须 |
| 3 | 单页，从上到下 | 必须 |
| 4 | 连续条漫 | 必须，默认 |
| 5 | 带页面间隙的条漫 | 首版可以由条漫模式加间距实现 |

## 4. Flutter 当前事实与必须先修的问题

### 4.1 可以复用

- `ui/search/`：多源搜索、取消、错误聚合、书源选择和结果分组。
- `ui/book_info/`：渐进详情、完整目录、加入书架、分组和更新目录。
- `ui/bookshelf/`：列表/网格、分组、排序、阅读历史和入口转场。
- `StandardBookSourceService`：详情、目录和正文请求。
- `ReaderContentMarkup`：把安全 HTTP(S) 图片编码为不可执行资源标记。
- `LegadoCookieManager`、`UnifiedHttpClient` 和 `SourceUrlResolver`：Cookie、Header 和请求规则。
- `ReaderPlatformService`：阅读系统栏、常亮和生命周期边界。
- `ReadConfig`：已经保留 `imageStyle`、`mangaScrollMode`、`webtoonSidePaddingDp`、
  `mangaColorFilter` 和 `mangaBackground` 等 Android 映射字段。

### 4.2 P0 类型映射错误

`standard_source_parser.dart` 当前把 `source.bookSourceType` 直接写入 `SearchBook.type`。这会让图片书源产生
`type == 2`，但 Android 兼容的图片书籍应为 `type == 64`。在任何漫画路由接线前必须先建立统一转换：

```text
bookSourceType 0 或未知 -> BookType.text 8
bookSourceType 1        -> BookType.audio 32
bookSourceType 2        -> BookType.image 64
bookSourceType 3        -> BookType.text 8 | BookType.webFile 128
```

转换必须由一个领域方法负责，搜索、探索、详情刷新和换源均复用，禁止各处散落数字判断。

### 4.3 P0 图片请求边界不足

现有文本阅读器图片组件直接使用 `Image.network`，只附带 Referer。漫画首版不能依赖该路径，因为真实图片书源可能需要：

- 书源自定义 Header；
- 持久 Cookie；
- 章节地址 Referer；
- 重定向和字符规则；
- 有界并发、取消和超时；
- 应用私有磁盘缓存；
- 缓存损坏后删除并重新请求。

漫画图片应通过项目内 `MangaImageGateway` 获取受控文件或字节流，UI 不直接访问 Dio、Cookie DAO 或文件系统。

### 4.4 P0 阅读入口未分流

当前详情、书架和历史最终都进入 `/reader`。实现漫画后，入口应通过共用类型判断器分流：

```text
本地 PDF -> PdfReaderRoute
网络图片书 -> MangaReaderRoute
其余当前支持书籍 -> BookReaderRoute
```

Route 只负责分流和系统副作用，不承载漫画业务状态。

## 5. 目标架构与建议文件

以下是实施时的目标职责，不要求为了形式一次创建全部文件；只有具备真实职责时才新增。

```text
lib/src/
├── constant/
│   ├── book_type.dart
│   └── book_source_type.dart
├── domain/
│   ├── gateway/
│   │   └── manga_image_gateway.dart
│   └── model/
│       ├── manga_page.dart
│       ├── manga_chapter.dart
│       ├── manga_reading_position.dart
│       └── manga_reader_config.dart
├── data/
│   └── repository/
│       └── manga_image_repository.dart
├── model/
│   └── manga/
│       ├── manga_content_parser.dart
│       ├── read_manga_coordinator.dart
│       └── manga_image_cache.dart
├── ui/
│   └── manga_reader/
│       ├── manga_reader_contract.dart
│       ├── manga_reader_view_model.dart
│       ├── manga_reader_route.dart
│       ├── manga_reader_screen.dart
│       ├── manga_page_view.dart
│       └── manga_reader_settings_sheet.dart
└── app/
    └── manga_reader_preferences.dart
```

### 5.1 分层职责

| 层 | 责任 |
|---|---|
| Domain Model | 图片页、章节、阅读位置、模式和受控错误，不依赖 Flutter |
| Gateway | 获取图片缓存文件、删除损坏缓存和观察加载进度 |
| Repository | 组合统一 HTTP、Cookie、书源 Header、Referer 与私有缓存目录 |
| Coordinator | 加载目录/正文、解析图片、维持前后章窗口、预取、取消和保存进度 |
| ViewModel | 单一 `onIntent` 更新状态并发出导航、提示和系统行为 Effect |
| Screen | 无状态渲染工具栏、页面列表、错误和设置面板 |
| Route | 生命周期、系统栏、常亮、图片保存选择器和导航 |

### 5.2 Android 到 Flutter 映射

| Android | Flutter 目标 |
|---|---|
| `BookSource.getBookType()` | `bookTypeFromSourceType()` |
| `ReadManga` | `ReadMangaCoordinator` |
| `ReadMangaViewModel` | `MangaReaderViewModel` |
| `ReadMangaActivity` | `MangaReaderRoute` + `MangaReaderScreen` |
| `MangaPage` | `domain/model/manga_page.dart` |
| `MangaChapter` | `domain/model/manga_chapter.dart` |
| `BookHelp.flowImages` | `MangaContentParser.parse` |
| `ImageProvider` | `MangaImageRepository` + `MangaImageCache` |
| `MangaAdapter` | `MangaPageView` |
| `MangaLayoutManager` | Flutter `PageView` 与惰性纵向列表 |
| `ReadMangaConfig` | `MangaReaderPreferences` + 单书 `ReadConfig` |

## 6. State、Intent 与 Effect

### 6.1 最小 UiState

`MangaReaderUiState` 至少包含：

- 当前书籍快照和是否已入书架；
- 初始化、目录加载、当前章加载和刷新状态；
- 当前章、前一章和后一章的图片页事实；
- 当前章节索引、当前图片索引和稳定页面键；
- 阅读模式、背景、间距和缩放开关；
- 当前加载失败及可恢复动作；
- 工具栏是否可见；
- 目录或设置面板状态；
- 是否已经到达全书开头或结尾。

页面列表、章节列表和错误集合对外均不可变。Widget、Controller、Stream、Timer 和平台对象不得进入 UiState。

### 6.2 最小 Intent

- 初始化和重试初始化；
- 点击或手势显示/隐藏工具栏；
- 页面位置变化；
- 上一页、下一页、上一章和下一章；
- 打开目录并跳转章节；
- 强制刷新当前章；
- 重试单张图片；
- 改变阅读模式、间距、背景或缩放开关；
- 加入或移出书架；
- 打开书籍详情；
- 请求保存当前图片；
- 返回并保存进度。

### 6.3 最小 Effect

- 显示受控提示；
- 打开目录或书籍详情；
- 请求系统图片保存/分享；
- 进入或退出沉浸式系统栏；
- 请求保持屏幕常亮；
- 关闭漫画阅读路由；
- 图片书源失效时打开整书换源。

## 7. 存储选择

### 7.1 SQLite

首版继续使用现有 `books`、`chapters`、阅读历史和正文缓存事实：

- `durChapterIndex`：当前章节索引；
- `durChapterPos`：在漫画领域中解释为当前章节图片索引；
- `durChapterTitle`、`durChapterTime`：继续保持现有含义；
- 章节目录、书架成员和阅读历史继续按当前用户作用域隔离。

首版不要求新增表或列，因此原则上不提升 `LegadoDatabase.schemaVersion`，也不提升 `pubspec.yaml`
构建号。实际实施若新增图片缓存元数据表、下载任务字段或其他持久字段，必须重新评估 Schema、基础建表、
`onUpgrade` 和 build number 联动。

### 7.2 MMKV

适合保存设备级、体积小且高频读取的漫画偏好：

- 默认阅读模式；
- 条漫间距与侧边留白；
- 漫画背景；
- 双击缩放开关；
- 后续自动翻页速度、页脚和滤镜配置。

新增键必须使用稳定命名空间，例如 `reader.manga.scroll_mode.v1`，并记录默认值、损坏值回退、旧存储迁移、
删除生命周期和设备级作用域。ViewModel 只能依赖类型化 `MangaReaderPreferences`，不能直接依赖 MMKV 插件。

### 7.3 应用私有文件缓存

漫画图片属于大内容，保存在 `AppMediaDirectory.comic` 对应的应用私有目录，不进入 MMKV 或 SQLite BLOB。
缓存键至少组合用户作用域、书籍稳定身份、章节 URL 和图片 URL 的摘要，禁止记录 Cookie、Authorization 或密钥。

建议边界：

- 当前章图片优先保留；
- 内存只保留当前可见页附近的有限解码结果；
- 磁盘使用 LRU 或容量上限，清理不得删除用户明确下载的永久离线图片；
- 账号切换取消旧作用域请求并清理内存索引，磁盘键必须按作用域隔离；
- 图片解码失败时删除损坏项，单飞重新请求一次，仍失败后显示明确错误。

## 8. 分步实施顺序

每一步完成后先由用户运行对应验收，再进入下一步。不得因为后续代码存在而跳过前一步真实结果。

### 步骤 0：冻结样本和验收基线

1. 由用户确认至少一份公开、无需登录的图片书源样本。
2. 再准备一份需要 Cookie、Referer 或自定义 Header 的样本。
3. 固定搜索关键字、目标漫画、目录章节和每章预期图片数。
4. 在 Android 原版记录搜索结果、详情字段、章节顺序、图片顺序和首张图片请求要求。
5. 敏感 Cookie、账号和 Token 不写入仓库。

退出门禁：至少一份基础样本可在 Android 原版完成搜索、详情、目录和阅读。

实施记录：已在 [`01_sample_and_acceptance_baseline.md`](./01_sample_and_acceptance_baseline.md) 选定仓库既有
M4 `S10`“🎨武芊漫画”作为公开基础样本，冻结搜索词、目标选择规则、目标章节规则、三端字段表和敏感数据
脱敏边界。2026-08-02 用户明确确认 Android 原版验证没有问题并通过步骤 0 门禁，本步骤状态为 `DONE`。

### 步骤 1：建立类型常量并修正全链路映射

1. 新增 Android 对齐的 `BookSourceType` 和 `BookType` 常量或等价领域定义。
2. 新增唯一的 `bookTypeFromSourceType()` 转换方法。
3. 修正普通和异步搜索解析的 `SearchBook.type`。
4. 搜索探索、详情刷新、候选合并和整书换源复用同一转换。
5. 提供 `Book.isImage` 安全 getter，使用位运算判断 `type & 64`。
6. 核对数据库映射、历史快照和 `SearchBook.toBook()` 不会丢失图片位。
7. 不改变已有数据库中真实文本书籍的类型事实。

退出门禁：图片书源搜索结果、详情书籍和入架书籍均为 `BookType.image`，普通文本仍为 `BookType.text`。

实施记录：已新增 `constant/book_type.dart` 和 `constant/book_source_type.dart`，集中定义 Android 位掩码、
书源数值及 `bookTypeFromSourceType()`；普通与 JavaScript 混合搜索解析分支均改用统一转换，`Book` 和
`SearchBook` 默认类型改为文本位 `8` 并提供安全的 `isImage` 位判断。没有改变 SQLite 表、列或 Schema 版本。
代码等待用户运行步骤 1 验收，因此当前为 `IMPLEMENTED_PENDING_VERIFICATION`。

### 步骤 2：接通图片书源搜索、详情和入架

1. 保留非文字书源导入时默认关闭的安全策略，但允许用户在书源管理中明确启用。
2. 搜索页书源选择应显示已启用图片书源，并能单独勾选。
3. 搜索结果分组和详情候选不得把同名文本书与漫画错误合并为同类型来源。
4. 详情加载、目录保存和加入书架复用现有 UseCase。
5. 书架同名冲突只在主要内容类型相同时成立；同名文本书与漫画作为独立作品直接并存。
6. 书架条目和阅读历史可以显示“漫画”类型标识，但不改变现有布局结构。

退出门禁：用户可以搜索目标漫画、打开详情、看到正确目录并加入当前用户书架。

实施记录：现有书源管理启用、搜索、详情、目录和加入书架链路继续复用；搜索结果分组键增加主要内容类型，
同名漫画、文本、音频和文件不再进入同一候选组。书架同名冲突查询同样增加主要内容类型，类型不同的作品
直接独立加入书架；整书和单章换源仍拒绝跨内容类型候选。书架列表与网格为图片书籍展示“漫画”标识。
代码已写入，按用户要求不在本步骤单独验证，统一留到漫画闭环完成后验收。

### 步骤 3：建立漫画阅读路由和三入口分流

1. 注册稳定路由 `/manga-reader`，参数至少包含 `bookUrl`、可选书籍快照、可选目录快照和入口来源。
2. 详情、书架和历史统一调用阅读类型解析器。
3. 图片书籍进入漫画路由；PDF 和文本书保持原路由。
4. 路由初始化优先使用传入快照，旧 URL 入口才查询数据库。
5. 未入架详情阅读允许临时阅读，但阅读成功只写历史，不自动加入书架。
6. 返回统一保存进度、恢复系统栏并释放当前路由任务。

退出门禁：三个入口均能稳定进入漫画页面，返回后没有重复阅读器和错误路由栈。

实施记录：已注册稳定 `/manga-reader` 路由和 `MangaReaderRouteArguments`，新增
`ui/manga_reader/manga_reader_route.dart` 与 `manga_reader_screen.dart` 页面壳。`AppRoute.readingRouteFor()`
集中按 `Book.isImage` 选择漫画或现有阅读入口；详情携带完整目录和指定章节，书架与历史携带书籍快照和已有进度。
漫画路由在收到非图片书籍快照时显示受控错误，不会继续误入。图片解析与真实阅读内核仍属于步骤 4～7。
代码按用户要求统一留到最后验证。

### 步骤 4：实现章节图片解析

1. 从 `StandardBookSourceService.loadContent` 获取原始章节正文。
2. 支持现有 `ReaderContentMarkup` 图片标记和常见 `<img>` 属性。
3. 使用章节最终响应地址或章节 URL 解析相对图片地址。
4. 保持原始图片顺序；只对完全相同的相邻地址执行 Android 对齐去重。
5. 拒绝 `javascript:`、`file:`、任意本地绝对路径和超长不可信地址。
6. 区分卷标题、正文为空和正文没有图片三种状态。
7. 为每张图生成稳定页面键，不使用列表瞬时下标作为唯一身份。

退出门禁：固定样本每章图片数量、顺序和绝对 URL 与 Android 一致。

实施记录：已新增 `domain/model/manga_page.dart`、`manga_chapter.dart` 和
`model/manga/manga_content_parser.dart`。解析器按原正文位置合并现有 `ReaderContentMarkup` 安全标记与
常见 `<img>` 标签，支持 `src`、`data-src`、`data-original`、`data-url`、`data-lazy-src`，以最终响应地址
或章节 URL 解析相对地址，只接受带远端主机的 HTTP(S)。页面保持原始顺序，仅移除完全相同的相邻地址；
稳定键组合章节地址、图片地址和章节内位置，以区分非相邻重复资源。卷标题、空正文和有正文无图片分别进入
不同领域状态。标准正文 HTML 安全格式化入口也改为从候选属性中选择首个安全地址，避免占位 `src` 遮蔽
真实懒加载地址。代码按用户要求不在本步骤单独验证，固定样本门禁统一留到最后。

### 步骤 5：实现统一图片获取和缓存

1. `MangaImageRepository` 使用统一 HTTP 和 Cookie 边界，不让 UI 直接发网络请求。
2. 合并书源 Header、图片地址 Header 规则、Cookie 和章节 Referer，敏感字段不写日志。
3. 每张图片支持取消、连接/响应超时、有限重试和加载进度。
4. 同 URL 请求单飞，避免滚动重建产生重复下载。
5. 下载写入临时文件，成功校验后原子替换正式缓存，防止半张图片被当作命中。
6. 检查 MIME、文件头和尺寸上限，损坏或不支持格式返回领域错误。
7. UI 只消费受控文件/图片提供器和加载状态。

退出门禁：基础样本和带防盗链样本均可加载；断网时已缓存图片可显示，未缓存图片给出可重试错误。

实施记录：已新增 `domain/gateway/manga_image_gateway.dart`、`data/cache/manga_image_cache.dart` 和
`data/repository/manga_image_repository.dart`，并由 `AppDependencies.mangaImageGateway` 注入后续漫画阅读器。
仓储使用现有 `UnifiedHttpClient` 与共享 Cookie 管理器，合并书源 Header、图片地址安全 Header 选项及章节
Referer；统一 HTTP 接口新增可选下载进度回调，继续复用三次有限网络尝试、取消、重定向和超时分类。
2026-08-02 真机日志复盘后补齐 Android `AnalyzeUrl` 图片分支：单张图片在请求前执行 URL 主体和
`UrlOption.js`、执行书源 Header JavaScript、按“书源 Header → Android 默认 User-Agent → 登录 Header →
图片 URL Header”优先级合并，并支持统一客户端已有的 GET/POST 与请求 Body。字符串 `User-Agent: null`
继续表示不发送 UA。图片请求和脚本共用 Cell/预取取消令牌，脚本失败收敛为漫画请求规则错误。

正文 `imageDecode` 不再在章节解析阶段被拒绝；图片响应在文件头校验和落盘前，以 `result=bytes`、
`src=最终图片地址`、当前 `book/chapter/source` 上下文交给书源隔离 QuickJS 执行，返回值仅接受
`Uint8List` 或 0～255 数值数组，解密后的字节仍受 40 MiB 上限约束。依赖 Android/Rhino 未进入白名单的
任意 Java 类的解密脚本仍可能不兼容，必须由真实样本验收，不能据此宣称任意 `imageDecode` 已兼容。
同一用户/书籍/章节/图片请求规则经 SHA-256 形成缓存身份，同地址并发请求单飞；单文件上限 40 MiB，支持
PNG、JPEG、GIF、WebP 文件头和像素尺寸检查，单边上限 32768、总像素上限一亿。下载完成后在漫画缓存
同目录写入临时文件并原子替换，缓存命中也会复检文件头，损坏文件删除后重新请求。领域错误区分取消、
请求规则、网络、HTTP 状态、空响应、过大、格式和缓存 I/O，UI 后续只消费受控本地文件描述。

隐私边界：Cookie 仍由统一 Cookie Store 管理；Authorization、Cookie 和任意凭据 Header 不复制到正文
图片标记。正文标记只允许保存 Accept、Accept-Language、Origin、Referer、User-Agent 这类非凭据防盗链
Header，以及 `method/charset/retry/js/bodyJs/webView/webJs/webViewDelayTime` 可重放规则；请求 Body、Cookie、
Authorization 和其他凭据不进入普通正文缓存。敏感书源与登录 Header 只在每次请求时从既有书源事实和
书源隔离运行缓存读取，缓存文件名和日志均不包含原始 URL 或 Header。
`proxy`、`dnsIp`、`serverID` 仍属于尚未实现的跨平台代理/自定义 DNS 边界，不伪装为已支持。
当前代码按用户要求统一留到最后验证；基础样本、防盗链样本和断网命中门禁尚不能标记通过。

### 步骤 6：实现条漫阅读 MVP

1. 使用惰性纵向列表显示当前章图片，不能一次解码整章全部大图。
2. 图片按原始比例占满可用宽度，受安全区和侧边留白约束。
3. 当前可见页变化时更新领域位置，但使用节流保存避免每个像素滚动写数据库。
4. 到达章节尾部时拼接或切换下一章；回到顶部时支持上一章。
5. 当前章加载失败保留章节标题和重试入口。
6. 工具栏提供返回、目录、刷新、加入书架和设置入口。
7. 显示章节名、图片页和全书章节进度。

退出门禁：连续阅读至少三个章节，跨章顺序正确，快速滚动没有明显重复页或跳章。

实施记录：已新增 `model/manga/read_manga_coordinator.dart`、`ui/manga_reader/manga_reader_contract.dart`、
`manga_reader_view_model.dart` 和 `manga_page_view.dart`，并把原静态 `MangaReaderRoute` / `Screen` 替换为
真实 MVI 条漫链路。Coordinator 复用书源、`StandardBookSourceService` 和七天原始正文缓存，切章取消旧请求
并用代次拒绝晚到结果；ViewModel 从详情、书架或历史恢复书籍和目录，跳过卷标题，加载当前章并保留书源只在
业务层供图片 Gateway 使用。Screen 使用惰性 `ListView.builder`，每个 Cell 只取得校验后的本地文件，按屏幕
像素宽度解码并在销毁时取消请求；图片经过屏幕中心才更新图片索引和记录首次成功阅读，加载/解码失败可删除
损坏缓存后重试。

当前提供点击显示/隐藏工具栏、刷新、目录跳转、显式加入书架、上下章、章节末尾按钮和边界继续拖动跨章；
顶部显示书名/章节名，底部显示章节与图片进度。可见图片变化使用 700ms 节流写入既有 `durChapterPos`，
退后台和退出路由立即保存，并在首张真实可见图片后记录历史；未入架阅读不会自动入架。系统阅读模式进入时
保持屏幕常亮，退出时恢复系统栏和方向。代码按用户要求统一留到最后验证，因此“三章连续阅读”退出门禁尚未
标记通过；精确恢复到长章节中间图片、相邻章预取和内存窗口后来已由步骤 8～9 接通，仍统一待最终验证。

### 步骤 7：增加三种单页方向和缩放

1. 左到右和右到左使用横向 `PageView`，反向模式同时处理数据方向和手势语义。
2. 上到下单页使用纵向分页，不与连续条漫共用错误的滚动锚点。
3. 模式切换以当前稳定图片页为锚点，不回到章节开头。
4. 双指缩放和双击缩放只影响当前图片；缩放期间暂时禁止翻页手势竞争。
5. 退出缩放或换页时释放上一页高分辨率解码资源。
6. 屏幕方向和窗口尺寸变化后恢复同一图片页。

退出门禁：四种模式切换后仍停留在同一章节和图片；右到左模式的上一页/下一页含义正确。

实施记录：已新增 `domain/model/manga_reader_config.dart`，把 Android `mangaScrollMode` 的 `1/2/3/4/5`
收敛为从左到右、从右到左、纵向单页和连续条漫四种领域模式，其中 `5` 暂按条漫处理；单书
`ReadConfig.webtoonSidePaddingDp` 被限制在 `0～48dp` 后用于条漫左右留白。`MangaReaderUiState` 新增阅读配置
与缩放状态，设置入口在当前图片索引不变的情况下切换布局；当前路由内的用户选择优先于初始化阶段晚到的书籍
快照，现阶段不新增持久化键，独立的全局/单书设置写回留给后续偏好接线。

横向 `PageView` 通过 `reverse` 对齐右到左手势语义，纵向单页使用独立纵向分页控制器；模式、章节、屏幕方向
或窗口尺寸变化都以领域层 `currentImageIndex` 创建或保持分页锚点。条漫切到单页时保存章节滚动偏移，切回优先
恢复该精确偏移；首次由单页进入条漫时使用当前图片与视口估算起点，再由屏幕中心检测校正。图片 Cell 使用独立
`TransformationController` 支持双指缩放和双击 `2.5x` 缩放，放大期间冻结外层列表或分页手势；换页、换章、
换模式时复位缩放，分页 Cell 销毁时按文件与解码宽度清理 Flutter 图片缓存。代码按用户要求留到最后验证，
本步骤退出门禁尚未标记通过。

### 步骤 8：进度、历史和生命周期

1. 使用 `MangaReadingPosition(chapterIndex, imageIndex)` 表达漫画位置。
2. 数据库适配层把 `imageIndex` 写入现有 `durChapterPos`，不暴露为字符偏移。
3. 页面稳定、章节变化、应用退后台和退出路由时保存进度。
4. 恢复时对目录和图片数量做范围收敛，旧索引越界时定位到最后有效图片。
5. 正文首张图片成功显示后才记录阅读成功和阅读历史，加载失败不能伪装成成功。
6. 账号切换、路由销毁和内存压力取消预取并清理内存图片。
7. 阅读历史快照继续按用户作用域隔离，并携带正确图片类型。

退出门禁：退出应用、重新打开、切换章节和前后台恢复后均定位到正确图片页。

实施记录：已新增 `domain/model/manga_reading_position.dart`，用
`MangaReadingPosition(chapterIndex, imageIndex)` 贯穿 `MangaReaderUiState`、恢复收敛和保存快照；仅在
`toReadingProgress` 数据适配边界把 `imageIndex` 映射到既有 `ReadingProgress.chapterPos`，没有修改 SQLite
字段或 Schema。入口书籍的负值/越界章节先按目录数量收敛，卷标题跳到最近可阅读章时图片归零；章节图片列表
解析完成后再次按图片数量收敛，旧索引越界会停在最后一张有效图片。

可见图片在 700ms 稳定窗口后保存，切章、退后台、内存压力和退出路由立即请求保存；保存任务冻结调用时的
书籍、章节和图片位置并串行落库，避免旧异步写入在新位置之后覆盖。首张图片仍须真实解码并成为当前页后才写
阅读历史，加载失败保持错误状态。条漫首次恢复深页时先按惰性列表估算范围定位，再通过目标图片 `GlobalKey`
按真实 Cell 居中；恢复完成前屏蔽其他首屏图片的位置回调，防止第一页覆盖持久进度。旋转或分屏尺寸变化会用
同一领域图片索引重新建立条漫锚点，分页模式继续由 `PageController` 保持逻辑页。

路由监听当前用户作用域：切换游客/账号时立即使旧 ViewModel 失效、取消章节请求、禁止旧数据写入新作用域、
清理解码缓存并关闭旧阅读路由；正常退出仍保存原作用域位置。内存压力先保存稳定位置，再清理 Flutter 普通及
live 图片解码缓存，应用私有磁盘图片不删除；路由销毁由 Coordinator 和图片 Cell 分别取消章节和图片请求。
阅读历史继续复用已有用户作用域 Repository，书籍快照通过 `Book.copyWithProgress` 保留图片类型位。
代码按用户要求留到最后验证，本步骤退出门禁尚未标记通过。

### 步骤 9：相邻章预取与内存治理

1. 目录与当前章加载完成后，只预取前一章、后一章的正文图片清单。
2. 图片文件预取使用低优先级、有界并发，并优先当前页前后少量图片。
3. 快速跳章时取消旧代次请求，旧结果不得写回当前状态。
4. 内存缓存按估算解码字节而不是图片数量限制；超大单图允许显示但不长期保留。
5. 系统内存压力到来时清理解码缓存，保留磁盘文件和稳定进度。
6. 预取失败不覆盖当前章正常阅读状态。

退出门禁：连续阅读大图章节时内存保持有界，跳章后不会继续大量请求旧章节。

实施记录：`ReadMangaCoordinator` 新增 Android 对齐的上一章/当前章/下一章解析窗口，遇到卷标题会保留
最近的前后可阅读章且始终裁剪为最多三章。当前章成功后用最多两个固定 worker 并发读取相邻两章的正文缓存
或书源内容并解析图片清单；相邻章失败只作为预取失败，不改变当前章 `ready` 状态。快速切章会同时递增可见章、
相邻章清单和图片文件三类代次，并取消旧令牌，旧结果不能写回新窗口。

图片磁盘预取队列依次加入当前页 `+1/-1/+2/-2`，再加入下一章首图和上一章末图，稳定键去重后最多六张；
先等待 200ms 让当前可见 Cell 优先进入统一仓储，再由两个固定 worker 下载。位置变化只替换图片队列，不中断
相邻章正文清单预取；单图失败继续下一候选且不覆盖 UI 错误。`MangaImageRepository` 对低优先级调用者首先
创建单飞任务后被取消的竞争增加活动调用者重试，预取取消不会让可见 Cell 永久复用已取消 Future。

漫画路由进入时把 Flutter `ImageCache.maximumSizeBytes` 临时收紧到原值与 64 MiB 的较小者，退出时仅在该值
未被其他生命周期修改时恢复旧预算。图片继续按屏幕像素宽度采样解码；大于缓存预算的单图允许当前 Widget
显示，但不会长期进入缓存。系统内存压力会取消相邻章/图片预取、清除相邻章解析窗口和 Flutter 解码缓存，
同时保留当前章 UiState、磁盘图片和稳定进度。代码按用户要求留到最后验证，本步骤退出门禁尚未标记通过。

### 步骤 10：错误恢复、换源和首版收口

1. 当前章正文失败：提供重试、刷新当前章和整书换源。
2. 单张图片失败：只重试该图，不重复请求整章正文。
3. Cookie 或登录失效：提供书源登录入口，成功返回后重试。
4. 付费或验证码动作：显示书源返回的受控错误，不形成无限重试。
5. 整书换源只接受图片类型候选，迁移后使当前漫画路由替换为新书主键。
6. 更新功能矩阵、Android/Flutter 文件映射、AI 项目索引和 M11 状态。
7. 由用户先验证 Android，再验证 iOS；两端均确认前不得标记 `DONE`。

实施结果：章节级错误和无图片状态统一提供普通重试、删除正文缓存后的刷新、书源登录与整书换源；单张图片
继续由图片 Cell 独立刷新，不重复请求章节正文。登录页复用统一 Cookie WebView，只有用户点击完成返回时才
强制刷新当前章，取消返回不发请求。普通规则和 JavaScript 的安全错误消息可直接展示，付费或验证码失败不做
自动循环重试。整书换源继续由 `ChangeBookSourceUseCase` 限制主要内容类型兼容，漫画路由再校验图片位；事务
成功后禁止旧主键继续保存，并以新书主键、书架事实和一次性结果提示替换当前 `/manga-reader` 路由。

代码和文档已经收口，但本步骤以及第 11 节 Android/iOS 验收项均未由 AI 执行；状态保持
`IMPLEMENTED_PENDING_VERIFICATION`，两端用户确认前不标记 `DONE`。

退出门禁：第 11 节所有首版验收项有用户提供的结果，已知差异均被登记或接受。

## 9. 并发、取消和内存边界

- 章节正文沿用现有有界请求策略，不为每张图片启动无界 Future。
- 当前可见图片优先级最高，相邻图片其次，相邻章节最低。
- 默认同时下载图片数建议从 3 开始，真机验证后再决定是否调整；上限必须固定。
- 同一本书切换章节、切换来源、退出路由或切换账号时递增任务代次并取消旧请求。
- 图片解码不得在 UI isolate 执行大尺寸变换、滤镜或全量尺寸扫描。
- 超大图片优先按显示尺寸采样解码；不允许因为单张长图把内存 LRU 自动扩展到无上限。
- 日志只记录书籍/章节/图片的不可逆诊断摘要、状态和耗时，不记录 URL、Cookie、Authorization 或正文。

## 10. Android 与 iOS 差异

| 能力 | Android | iOS |
|---|---|---|
| 核心漫画阅读 | Flutter 共用 | Flutter 共用 |
| 图片 HTTP 与缓存 | Dart 共用 | Dart 共用 |
| 系统栏和常亮 | 复用 Android 平台实现 | 复用 iOS 平台实现 |
| 保存到相册 | Android MediaStore/插件能力 | iOS Photos/插件能力及权限说明 |
| 音量键翻页 | 可后续通过平台事件实现 | 首版不承诺硬件音量键拦截 |
| 长时间后台预取 | 不作为首版保证 | 不作为首版保证 |
| 内存压力 | Flutter 与 Android 回调清理解码缓存 | Flutter 与 iOS memory warning 清理解码缓存 |

核心领域层不得判断运行平台。没有等价能力时由平台实现返回明确 unsupported 结果，由 Route 展示说明。

## 11. 用户验收矩阵

### 11.1 搜索、详情和书架

1. 导入图片书源，确认默认关闭；用户手动启用后可在搜索书源选择中看到。
2. 搜索固定漫画，确认结果封面、书名、作者、最新章节和来源正确。
3. 打开详情，确认详情与完整目录顺序正确。
4. 加入书架，退出并重启后漫画仍存在于当前游客或账号书架。
5. 从详情、书架和历史分别打开，均进入漫画阅读器，文本书仍进入文本阅读器。

### 11.2 阅读和进度

1. 条漫模式连续阅读三章，确认图片无乱序、重复或漏页。
2. 分别验证左到右、右到左和上到下单页模式。
3. 在中间图片退出，重新进入后恢复同一章节和图片页。
4. 从目录跳转到首章、中间章和末章，确认边界与进度正确。
5. 切换阅读模式、横竖屏或窗口尺寸后仍保持当前图片。
6. 双指和双击缩放时不会误触翻页；换页后上一页缩放状态不污染新页。

### 11.3 网络、缓存和错误

1. 用公开图片书源验证无登录加载。
2. 用需要 Cookie、Header 或 Referer 的样本验证防盗链加载。
3. 当前章加载完成后断网，重新进入确认已缓存图片可读。
4. 清除一张缓存或模拟损坏，确认只重试该图片并能恢复。
5. 快速连续跳章，确认旧章节请求被取消且不覆盖新章节状态。
6. 正文为空、没有图片、图片 403、超时和登录失效时均显示正确恢复入口。
7. 长图和大图连续阅读期间观察内存；发生内存压力后页面可以重新加载而不崩溃。

### 11.4 双平台

1. Android 真机完成以上全部首版路径。
2. Android 返回、系统栏、常亮、前后台和低内存恢复正常。
3. iPhone 真机完成以上全部首版路径。
4. iOS Safe Area、返回手势、前后台和 memory warning 恢复正常。
5. 两端同一书源的章节图片数量和顺序一致。

## 12. 完成定义

漫画首版只有同时满足以下条件才能从 `PROPOSED` 更新为 `DONE`：

- [ ] 类型转换只有一个真实实现，搜索、详情、书架、换源和历史均保持图片位。
- [ ] 详情、书架和历史入口均正确分流到漫画阅读器。
- [ ] 图片解析结果与固定 Android 样本一致。
- [ ] 条漫和三种单页方向可以使用。
- [ ] Cookie、Header、Referer、缓存、取消和失败重试进入真实调用链。
- [ ] 漫画进度使用明确领域模型并能跨重启恢复。
- [ ] 大图内存、预取和账号/路由生命周期有界。
- [ ] Android 用户验收通过。
- [ ] iOS 用户验收通过，或平台差异已由用户明确接受。
- [ ] 功能矩阵、文件映射、AI 索引和 M11 实施记录同步更新。
- [ ] 所有新增手写文件均有中文职责注释，Dart 没有使用强制空值断言解决可空问题。

## 13. 实施时的文档同步要求

每个步骤落地后至少更新：

- 本文对应步骤的实施结果和待验收状态；
- `docs/flutter-rewrite/m00/03_file_mapping.md` 的 Android/Flutter 映射；
- `docs/flutter-rewrite/m00/04_feature_matrix.md` 的漫画状态；
- `docs/flutter-rewrite/AI_PROJECT_INDEX.md` 的路由、职责和核心调用链；
- `docs/flutter-rewrite/m11/README.md` 的当前 Feature；
- 若出现平台差异，再更新 M10 平台能力和验收记录。

代码存在但未接入组合根、路由或真实调用方时只能记为 `PARTIAL`；用户未提供运行结果时最多记为
`IMPLEMENTED_PENDING_VERIFICATION`，不得标记 `DONE`。
