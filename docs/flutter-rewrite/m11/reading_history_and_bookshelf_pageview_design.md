# 书架与阅读历史双页设计

状态：`IMPLEMENTED_PENDING_USER_VERIFICATION / 代码已写入，等待用户运行验收`

## 目标与边界

本专项实现以下行为：

1. 主导航的书架目的地改为内部 `PageView`，固定两页：书架与历史；历史不再放在“我的”。
2. 书架与历史独立：同一本书可同时存在；打开书籍不自动入架，成功进入阅读后一定写入历史。
3. 阅读菜单显示时，在底部工具栏右上方显示仅图标的“加入书架”悬浮按钮；已在书架时不显示。
4. 阅读器章节滑杆左右放上一章、下一章；滑杆下方仅目录、书签、设置。
5. 书架选择模式在系统返回时优先取消；切换书架/历史、切换主导航目的地或书架失去可见性时自动取消。

不包含读时统计、同步、删除历史、历史筛选/搜索、书架分组规则改造或 Android `ReadRecord` 统计迁移。

## 实施快照

- 数据库升级到 Schema v8，新增 `reading_history_books` 与
  `reading_history_chapters`；`books`/`chapters` 继续只表示书架，`pubspec.yaml`
  build number 同步升为 `+6`。升级安装会把 `durChapterTime > 0` 的既有书架书和目录复制为
  初始历史快照，未读书架书不会被误加入历史。
- 后续用户隔离专项已把数据库升级到 Schema v9、build number `+7`；上述 v8 初始复制仅是
  历史实现记录。v8 到 v9 会按用户确认的破坏式方案清空旧书架、目录、分组、历史和下载状态，
  新记录以 `(userId, bookUrl)` 等复合键隔离，详见
  [按登录用户隔离设计](./user_scoped_bookshelf_and_history_design.md)。
- 新增 `ReadingHistoryDao`、`ReadingHistoryRepository`、
  `ReadingHistoryGateway` 和 `RecordReadingHistoryUseCase`。网络书首次成功得到可读正文后写入
  独立书籍/目录快照；TXT/EPUB 复用同一文本链路，PDF 在文档真实打开后写入；后续保存阅读
  或 PDF 页码进度时同步更新历史位置。
- 书架路由内部改为书架/历史两页 `PageView`。书架选择模式在返回、滑到历史或主导航离开书架时退出，
  对应控制器、订阅和可见性通知均随 Route 释放；“我的”页面原有最近阅读区和历史弹层已移除。
- 详情目录进入阅读器不再隐式调用加入书架事务；路由可携带未入架书籍与目录快照，历史页也能独立恢复阅读。
- 阅读菜单已把上一章/下一章移动到章节滑杆两侧，末行只保留目录、书签、设置；未入架时在底栏右上显示
  仅图标的小型加入书架悬浮按钮。
- 新增 `SourceSuccessRateReporter`：按 URL、`search/toc/content`、UTC 日聚合，
  校验同步权限，执行未知书源两阶段补充并按 50 条/96 KiB 动态拆批；私网地址或疑似包含凭据的书源不上传。
- 新增 `AnalyticsRecorder`：只有用户主动授权才写入，使用独立 v2 队列、UUID v4、版本/平台字段、
  严格事件属性白名单、按小时聚合及 50 条/16 KiB 动态拆批；关闭授权清队列，旧格式队列安全删除。
  本专项已接入 `reader_opened` 与 `reader_open_failed`；`book_added_to_shelf(entry=reader)` 因导出文档
  未给出该枚举值的明确许可，暂不发送。
- AI 按仓库约定未运行构建、测试、分析、格式化或应用启动，以上状态不等同于已通过。

## 现状与数据决策

`books` 表只表示当前用户书架，`chapters`、下载状态等表通过复合外键依赖
`books(userId, bookUrl)`。因此不能只加一个 UI 历史列表，也不能把未入架书写进 `books` 表，
否则会违反“阅读不自动加入书架”。

新增独立历史快照：

| 数据 | 表/模型 | 职责 |
|---|---|---|
| 历史书籍 | `reading_history_books` / 复用领域 `Book` 快照 | `(userId, bookUrl)` 主键；保存当前用户可阅读的书籍快照、最后阅读时间与进度。 |
| 历史目录 | `reading_history_chapters` / 复用领域 `BookChapter` 快照 | `(userId, url, bookUrl)` 主键；复合外键到同一用户历史书籍，保存未入架书的目录。 |

两张表保存 `Book`/`BookChapter` 阅读所需字段。正文缓存、稳定进度锚点、显示设置、书签和标注继续使用相同 `bookUrl` 作为书籍级共享键，避免重复缓存；书架与历史的成员资格则完全独立。

数据库改动要求：schema 升至 `8`；新装在基础建表链路创建新表、索引和外键；`onUpgrade` 增加 `oldVersion < 8` 分支；同步增加 `pubspec.yaml` 的 build number；更新 `DatabaseTables`、实体映射、DAO、Gateway、Repository、组合根注入及数据库变更通知。

## 调用链和写入时机

```text
搜索/详情/书架/历史打开书籍
  -> ReaderRoute（明确携带阅读来源：书架或历史）
  -> ReaderViewModel 成功得到书籍、目录和首个可读章节正文
  -> RecordReadingHistoryUseCase
  -> ReadingHistoryGateway/Repository
  -> 历史书籍和历史目录原子 upsert

阅读器“加入书架”图标
  -> AddCurrentReaderBookToBookshelfIntent
  -> AddBookToBookshelfUseCase
  -> books + chapters 原子写入
  -> ReaderUiState 更新为已在架，图标消失
```

历史写入以首个章节正文成功进入可读状态为界；参数无效、目录不存在、加载失败或加载前取消都不写入。
写入必须幂等，以最后阅读时间倒序展示。搜索/详情的阅读动作将只导航阅读器，不隐式调用
`AddBookToBookshelfUseCase`；显式加入书架入口继续保留。

## UI 与生命周期

- `BookshelfRoute` 管理 `PageController` 和页索引，顶部页签为书架/历史，内容使用 `PageView`。
- 原 `BookshelfViewModel` 继续只管理书架分组、刷新和选择；历史使用独立 `ReadingHistoryViewModel`，实时观察历史数据并按最后阅读时间排序。
- 从书架页滑到历史、点击历史页签或一级书架目的地被 `IndexedStack` 隐藏时，发送 `ExitBookshelfSelectionIntent`；书架可见时的返回优先消费选择模式。
- 两页列表都以 `bookUrl` 为稳定 key，使用惰性 `ListView.builder`，不在 Widget 保留全量历史副本。
- `ReaderUiState` 新增“已在书架”状态；菜单显示且未在架时，在底栏右上以无文字 `FloatingActionButton.small`（`Icons.bookmark_add_outlined`）显示，提交期间禁用防重复，成功后自动移除。
- 阅读底栏保持章节信息行；下一行变为“上一章 + 滑杆 + 下一章”，末行仅目录、书签、设置。首末章按钮禁用。
- 新增订阅和 `PageController` 必须在 `dispose` 释放，不持有失效 `BuildContext`，不能让隐藏页继续保留批量选择。

## 成功率上报与匿名埋点执行方案

本节依据 `C:/Users/s8534/Downloads/novel-admin-api-App-客户端-2026-07-23 (1).json`（导出时间 `2026-07-23T14:26:41.094Z`）制定。两条链路必须分开：书源成功率属于带原始书源 URL 的运维质量数据；匿名埋点属于用户主动授权后的严格白名单产品分析数据，不能共用 DTO、队列或授权判断。

### 当前实现差距

| 链路 | API 文档要求 | Flutter 当前状态 | 必须调整 |
|---|---|---|---|
| 书源成功率 | `POST /api/v1/booksource/stats/batch`；HMAC + Bearer + `canSyncBookSource`；本地聚合，单批 1～50 桶、最大 96 KiB；未知书源按两阶段补充完整 JSON | 仅实现 `/api/v1/booksource/event` 的逐条事件队列，且没有业务调用 `recordOutcome` | 新建聚合桶、两阶段响应处理、权限判断和动态分批；旧逐条接口不再作为主成功率链路 |
| 匿名埋点 | `POST /api/v1/analytics/batch`；HMAC + Bearer；用户主动同意；单批 1～50 桶、最大 16 KiB；严格事件/属性白名单 | 有同意开关和 `caches` 队列，但业务没有调用；载荷缺 `schemaVersion`、`eventId`、版本名、平台和 `count`，批量上限仍复用 100 | 重建强类型事件桶和校验器，并在业务结果确定处接入 |

两种队列继续使用现有 `caches` 表，不新增数据库 Schema；书架/历史专项新增表所需的 Schema 升级不受本节影响。

### 书源成功率聚合

#### 采集口径

- 仅记录 `search`、`toc`、`content` 三种最终结果。一次业务调用在所有重试、备用 URL、脚本交互和缓存判断完成后只计一次，避免把内部重试放大成多次失败。
- `search`：单个书源的一次搜索任务最终得到可解析结果即成功；网络、HTTP、解码、规则或脚本最终失败计失败；用户主动取消不进入成功率。
- `toc`：书籍目录最终取得至少一个可阅读章节并通过结构校验计成功；卷标题列表、空目录或最终异常计失败。
- `content`：指定章节最终取得可用正文或受支持的正文资源块计成功；命中有效本地正文缓存不重复报告远端书源成功，只有实际请求书源的结果才计数。
- 聚合键固定为 `bookSourceUrl + eventType + UTC自然日`，保存 `successCount`、`failCount` 和该桶的 UTC `occurredAt`。每项限制为 `0～9999` 且合计至少为 1；超过 9999 时拆成新桶，不溢出也不丢弃近期数据。
- 只保留 31 天内数据；未来超过服务器 5 分钟的数据不上报，发现设备时间异常时暂停刷新该队列并给出不含 URL 的本地诊断。

#### 上传状态机

```text
业务最终结果
  -> SourceSuccessRateRecorder 聚合到 caches
  -> 已登录且 canSyncBookSource=true
  -> 第一阶段：只发送 reports（最多 50 桶且 JSON <= 96 KiB）
  -> 服务端返回 acceptedReports + missingBookSourceUrls
     -> 已存在书源对应桶：确认扣除本次快照计数
     -> 未知书源对应桶：进入第二阶段
  -> 从本地 BookSourceRepository 精确读取缺失 URL 的完整书源
  -> 第二阶段：只发送缺失 reports + 一一匹配的 bookSources
  -> importedSources/acceptedReports 成功后扣除相应快照
```

上传时先冻结本次计数快照；网络进行期间新产生的计数继续累加。成功后只从当前桶减去快照值，不能整桶删除，避免并发结果丢失。第二阶段只能重发 `missingBookSourceUrls` 对应 reports，不能把第一阶段已接受的书源再次发送，否则会重复计数。

当前接口没有报告桶 ID 或幂等键：若服务端已计数但响应丢失，客户端重试可能重复统计。实施时应把这项标为后端契约风险，优先建议后端为每个 report 增加稳定 UUID 并按产品幂等；在后端未补齐前只能采用“至少一次”语义，不能在客户端宣称精确一次。

#### 未知书源与隐私边界

- 成功率请求包含原始 `bookSourceUrl`，第二阶段还可能包含完整书源 JSON；请求体、响应中的缺失 URL、Header、变量和书源内容一律不得写入日志。
- 只有当前账号具备 `canSyncBookSource` 才允许刷新；403 视为权限终态，停止本轮，不循环重试。
- 自动补充未知书源前必须通过可分享性检查。包含账号 Cookie、Authorization、私有 Header、登录变量、内网/本机地址或其他凭据的书源不得上传完整 JSON；该桶保留为“不可补充”本地状态或在过期后清理，不得为了统计成功率泄露私人书源。
- `bookSources` 必须与本批 `reports.bookSourceUrl` 一一匹配，最多 50 条；按实际 UTF-8 JSON 字节动态装包，不能只按条数估计 96 KiB。
- 服务端只新增仍不存在的地址且不覆盖 Web 已管理书源；客户端不得把“导入成功”理解为该书源一定会下发，仍以 JSON 的 `enabled` 和服务端状态为准。

#### 失败策略

- 无网络、5xx、超时：保留聚合桶并指数退避；不阻塞搜索、目录或正文主链路。
- 401：交给统一会话恢复，恢复失败后等待下一次登录。
- 403：刷新账号权限并停止；无权限期间不主动上传。
- 4xx 参数错误或载荷过大：不盲目重试；缩小批次或隔离无效桶，日志只记录错误类别、桶数和字节数。
- 响应结构不合法，或 `acceptedReports`、`missingBookSourceUrls` 与请求无法核对：保留快照并停止本轮，避免误删本地计数。

### 匿名埋点

#### 同意与隐私

- 默认关闭；仅在用户主动开启数据分析后才允许生成和持久化事件。关闭时立即清空本地埋点队列，并且不得上报 `settings_analytics_changed(enabled=false)`。
- 用户开启后可以记录一次 `settings_analytics_changed` 且 `enabled=true`；关闭动作本身不产生任何待上传记录。
- 后端从 Token 确定产品。客户端不得发送 `productId`、`userId`、`deviceId`、账号、书名、作者、搜索词、章节、正文、书源名称、URL、完整异常或任意自定义 props。
- 埋点请求正文禁止进入网络日志；本地诊断只允许事件名、桶数、序列化字节数和受控错误分类。

#### 强类型事件桶

持久化结构必须对齐 API：

```text
schemaVersion: 1
events[]:
  eventId: UUID（创建桶时生成，重试保持不变）
  eventName: 后端白名单事件名
  occurredAt: UTC ISO-8601
  appVersionName: 集中版本名
  appVersionCode: 集中构建号
  platform: android | ios
  count: 1..9999
  props: 该事件专属白名单的扁平字段
```

相同 `eventName + 规范化 props + 版本 + 平台 + 时间窗口` 可以在本地合并并增加 `count`；不能跨版本合并。`eventId` 是后端按 `productId + eventId` 去重的依据，网络重试必须发送相同 ID。单批最多 50 桶，并以 UTF-8 编码后的完整请求体不超过 16 KiB 为最终装包条件。

统一验证器在入队前同时校验事件名、该事件允许的 props、枚举、布尔和数字范围；未知字段直接拒绝入队。数量字段截断至 9999。耗时只能转换成 `lt_1s`、`1_3s`、`3_10s`、`10_30s`、`gte_30s`；失败只能映射为 `network`、`http_status`、`decode`、`rule`、`permission`、`cancelled`、`unknown`。

#### 本专项接入点

| 事件 | 精确触发时机 | props |
|---|---|---|
| `reader_opened` | 阅读器成功加载首个可读章节后；历史 upsert 成功与否不改变“已打开”事实 | `entry=bookshelf/detail/history`、`contentKind=network/local`、`durationBucket` |
| `reader_open_failed` | 首章最终失败且用户已收到错误反馈 | `failureKind`、`contentKind` |
| `book_added_to_shelf` | `AddBookToBookshelfUseCase` 事务成功；包含阅读器悬浮按钮加入 | `entry=detail/import/reader`，但 `reader` 必须先由后端 props 白名单确认；未确认前不发送该字段 |

其他 P0/P1 事件继续以 `backend_api_integration/08_analytics_event_catalog_proposal.md` 为目录，但必须以本次 API 导出的严格事件与 props 白名单为最终约束。事件只能放在 ViewModel、Coordinator 或 UseCase 的最终成功/失败分支，不能放在 Widget `build`、点击回调的起点、文本输入或路由观察器。

#### 上传与错误处理

- `accepted + duplicate` 必须与本批事件数一致后才删除本地批次；重复事件视为已成功交付。
- 只保留过去 7 天内事件；超过窗口直接本地过期。设备时间超过服务器未来 5 分钟时暂停上传，不修改原事件时间伪造成功。
- 网络、超时、5xx：保留并退避；401：统一恢复会话；用户退出登录后队列可保留，但必须等再次登录且仍获同意后再传。
- `INVALID_ANALYTICS_BATCH`、`UNKNOWN_ANALYTICS_EVENT`、`INVALID_ANALYTICS_PROPS`：隔离对应批次并停止重复重放；`ANALYTICS_BATCH_TOO_LARGE`：按字节重新拆包。不得为了让请求通过而删除未知 props 后静默改变事件含义。
- 队列继续设置有界上限，超限优先丢弃最旧且已过期的桶；写入和 flush 串行化，避免两个并发上传任务重复消费同一批。

### 实施顺序

1. 从 `RemoteBookSourceSyncService` 拆出 `SourceSuccessRateReporter` 与 `AnalyticsRecorder` 两个边界，分别使用独立缓存键、DTO、校验器和串行 flush 锁。
2. 扩展 `RemoteAppApi`：新增 `/booksource/stats/batch` 的强类型请求/响应；埋点请求补齐 `schemaVersion` 并解码 `accepted/duplicate`，两者均使用现有 HMAC canonical 规则。
3. 先接书源 `search/toc/content` 的最终结果聚合，完成两阶段缺失书源处理、权限和敏感书源拦截；保留旧 `/booksource/event` 仅作兼容，确认服务端不再需要后再单独移除。
4. 重建匿名埋点持久化格式和严格白名单；旧格式队列无法补出稳定 `eventId` 和完整版本字段，应在升级时安全清空，不能伪造迁移。
5. 接入本专项的 `reader_opened`、`reader_open_failed` 和确认过 props 白名单后的 `book_added_to_shelf`；再按事件目录逐批接入其他 P0/P1。
6. 更新 `backend_api_integration/05_app_api_20260723_gap_analysis.md`、`08_analytics_event_catalog_proposal.md` 和 M11 实施记录，状态保持待用户验证。

### API 上报验收

1. 未同意数据分析时操作搜索、阅读和加书，确认不产生埋点缓存或请求；关闭开关立即清空队列且不发送 `enabled=false`。
2. 同意后离线产生多个相同事件，确认合并 count；重连上传包含 UUID、版本名/构建号、平台和 schemaVersion，重试 UUID 不变。
3. 制造重复响应，确认 `duplicate` 后移除事件；构造超过 16 KiB 的待传数据，确认自动拆包且每批不超过 50。
4. 分别完成书源搜索、目录、正文的成功和失败，确认只记录最终结果，并按 URL、类型、UTC 日聚合，缓存命中和内部重试不重复计数。
5. 首次上报同时包含服务端已存在和不存在的书源，确认第二阶段只发送 missing URL，对已接受书源不重复计数。
6. 未知书源包含 Cookie、Authorization、登录变量或内网地址时，确认不上传完整 JSON，日志中也不存在 URL 和书源正文。
7. 无同步权限、401、403、超时、5xx、响应丢失和无效响应分别验收；上报失败不得影响搜索、目录、阅读或加入书架。

## 预计改动范围

- `data/local`：Schema、表常量、实体映射和历史 DAO/Repository。
- `domain/model`、`domain/gateway`、`domain/usecase`：历史快照、记录历史和按阅读来源取得上下文。
- `app/app_dependencies.dart`：依赖注入。
- `ui/home/welcome_route.dart`：向内嵌书架传递可见性变化。
- `ui/bookshelf/`：书架/历史 PageView 容器、历史 Contract/ViewModel/Screen、选择模式可见性退出。
- `ui/search/`、`ui/book_info/`、`ui/reader/`：移除隐式入架、支持历史阅读上下文、加入书架图标和底栏重排。
- `api/remote_app/remote_app_api.dart`、`app/remote_book_source_sync_service.dart`（或拆分后的独立上报器）：接入成功率聚合、两阶段未知书源补充和严格匿名埋点契约。
- `AI_PROJECT_INDEX.md`、M7/M8/M11 实施记录：登记新表、调用链和未验证状态。

## 用户验收

1. 从搜索或详情直接阅读未入架书：书架不出现，该书立即出现在“书架 → 历史”。
2. 在阅读器点加入书架图标：书架与历史同时出现；重进阅读器不重复写入。
3. 已在架书进入阅读器：不显示加入图标。
4. 书架长按选择后按返回、滑向历史、切到搜索再回来：都不保留选择；返回仅退出选择不离开页面。
5. 菜单显示时确认“上一章/滑杆/下一章”同一行，下一行仅目录、书签、设置，边界章节禁用正确。
6. 重启后历史按最后阅读时间排序，未入架书仍可恢复目录、章节和接近原位置。
7. 打开“我的”，确认不再出现最近阅读区或阅读历史弹层入口。

AI 不会运行构建、测试、静态分析、格式化或应用启动；由用户执行验证。
