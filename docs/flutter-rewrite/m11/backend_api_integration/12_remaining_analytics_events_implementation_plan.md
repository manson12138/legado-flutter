# 剩余 App 匿名埋点全量接入实施方案

> 状态：`IMPLEMENTED_PENDING_USER_VERIFICATION`  
> 2026-07-25 已按本文完成客户端接入；尚未运行代码、测试、静态分析、格式化或真机验收，由用户后续验证。

状态：`ANALYZED_PENDING_EXECUTION_CONFIRMATION`。

本方案依据 2026-07-25 导出的 `novel-admin-api-selected-2026-07-25.json`
（导出时间 `2026-07-25T11:35:18.564Z`）、当前 Flutter 源码和只读 Android 参考实现整理。
本轮只完成静态分析和实施设计，尚未修改业务代码，也未运行编译、测试、分析、格式化或应用。

## 1. 唯一目标与不包含内容

唯一目标：在保留现有授权、隐私、聚合、幂等和动态分批能力的前提下，把当前尚未产生事件的
13 个后端白名单事件接入各业务最终结果分支，并补齐登录后续传、事件枚举校验和跨异步流程
的一次性约束。

本次包含：

- `app_session_started`
- `app_session_restore_result`
- `search_submitted`
- `search_completed`
- `book_detail_opened`
- `book_added_to_shelf`
- `book_source_import_completed`
- `remote_book_source_sync_completed`
- `book_source_change_completed`
- `chapter_source_change_completed`
- `reader_download_completed`
- `local_book_import_completed`
- `crash_report_upload_result`

本次不包含：

- 不修改服务端和后台管理 Web。
- 不接入 Firebase Analytics、友盟或新的第三方 SDK。
- 不采集页面浏览、点击流、停留时长、逐章/翻页行为或设备唯一标识。
- 不新增数据库表或列；若实施中发现必须修改 Schema，停止并重新向用户说明。
- 不修改只读 Android 参考仓库。
- 不把书名、作者、搜索词、章节、正文、书源名称、书源 URL、账号、Token、Cookie、
  文件路径或异常原文写入埋点。

## 2. 当前事实

### 2.1 已有 Flutter 能力

- `AnalyticsRecorder` 已实现默认关闭的用户授权、关闭清队列、旧 v1 队列清理、
  UUID v4 幂等事件桶、版本/平台字段、UTC 小时聚合、七天过期、50 条/16 KiB 动态分批。
- `RemoteAppApi.reportAnalyticsEvents` 已接入 `POST /api/v1/analytics/batch`，
  并校验 `accepted` 与 `duplicate`。
- 设置页已接入授权开关；开启只记录 `settings_analytics_changed(enabled=true)`，
  关闭不产生事件。
- TXT/EPUB/UMD/PDF 阅读成功与失败已接入 `reader_opened`、`reader_open_failed`。
- 当前没有业务调用 `flushPendingAnalytics()`；旧队列在登录成功后不一定立即续传，
  只能依赖后续新事件的五秒延迟刷新。

### 2.2 Android 只读参考

Android 参考实现只有 `FirebaseManager` 对 Firebase 收集开关的启停，没有本方案 16 个
自定义后端事件的逐事件业务基线。因此本任务属于 Flutter App 后端契约接入，不迁移
Firebase SDK，也不在 Android/iOS 原生层分别复制埋点逻辑。

### 2.3 2026-07-25 接口契约仍缺少的内容

导出文件确认了：

- 16 个事件名；
- 每个事件使用严格 props 白名单；
- `durationBucket` 的五个值；
- `failureKind` 的七个值；
- 1～50 个桶、16 KiB、UUID、七天窗口、Android/iOS 平台和关闭授权语义。

导出文件没有列出每个事件的完整字段类型与所有字符串枚举。当前仓库建议目录补充了大部分
字段，但以下 `result` 值仍是客户端推定，不是导出文件中的明确服务端事实：

| 事件 | 建议值 | 契约风险 |
| --- | --- | --- |
| `search_completed.result` | `success` / `partial` / `failed` | 导出示例只出现 `success` |
| `remote_book_source_sync_completed.result` | `success` / `failed` | 导出未列枚举 |
| `reader_download_completed.result` | `success` / `partial` / `failed` | 导出未列枚举 |
| `local_book_import_completed.result` | `imported` / `updated` / `failed` | 导出未列枚举 |
| `crash_report_upload_result.result` | `success` / `failed` | 导出未列枚举 |

正式编码前需要把上述值视为本次用户确认的客户端契约，或者由后端补充精确事件目录。
不得先发送任意字符串，再依赖服务端 400 响应反推白名单。

## 3. 统一实现边界

### 3.1 仍使用一套 Dart 记录器

保留 `AnalyticsRecorder` 作为唯一授权、校验、聚合、持久化和上传边界。页面与业务协调器
只接收最小的记录回调，不直接读取 `CacheDao`、Token 或调用 HTTP。Android 和 iOS 共用
同一套事件逻辑，不新增原生通道。

`AnalyticsRecorder` 需要把当前“只校验字段名、通用类型、耗时和失败分类”的校验扩展为：

- 按事件校验完整字段集合；
- 按事件和字段校验字符串枚举；
- 布尔字段必须是布尔值；
- 数量字段必须是非负整数并夹取到 9999；
- 未知事件、未知字段、缺失字段或未知枚举在入队前拒绝；
- 校验失败不得修改业务结果，也不得记录敏感原值。

### 3.2 旁路失败不得改变业务

每个业务落点都遵循同一规则：

1. 先形成并保存业务最终结果。
2. 再尽力写入匿名事件。
3. 埋点缓存或网络失败不得把成功业务改成失败，也不得覆盖原错误提示。
4. 不在 Widget `build()`、文本输入回调、按钮点击起点或路由观察器中记录。

### 3.3 登录后立即续传

`PageNestApp._onAuthenticationSessionChanged` 在认证会话首次建立后尽力调用
`flushPendingAnalytics()`。调用不阻塞主界面、书源初始化或下载恢复；失败继续保留队列。
登出不上传，重新登录且授权仍开启后再续传。

### 3.4 性能与内存

- 搜索、详情、换源和导入复用已有 `Stopwatch`，不新增周期 Timer。
- 下载批次耗时只在内存保存当前授权期间新建批次的开始时间，以
  `bookUrl + generation` 作为仅本地运行期键；批次结算或会话失效后立即删除。
- 下载在进程重启后没有可信开始时间时跳过该批耗时事件，不伪造 `durationBucket`。
- 下载测量表设置小型有界上限，并在用户切换账号、关闭授权和协调器失效时清空，
  防止长期运行累积。
- 事件仍按桶聚合，不为每章、每个搜索结果或每个下载任务单独创建事件。

## 4. 事件落点与字段映射

| 事件 | 精确触发点 | props | 计划修改位置 |
| --- | --- | --- | --- |
| `app_session_started` | 正式 App 首帧后、本地安全会话读取完成一次 | `restoreState=none/restored/refresh_required` | `domain/gateway/authentication_gateway.dart`、`data/repository/authentication_repository.dart`、`app/pagenest_app.dart` |
| `app_session_restore_result` | 有持久会话时，后台刷新或权限校验形成最终结果一次 | `result=success/expired/unauthorized/network_degraded`、`refreshAttempted` | 同上 |
| `search_submitted` | 非空关键词通过校验、执行书源集合确定且新任务正式建立 | `enabledSourceCount`、`historyUsed`；不传关键词 | `ui/search/search_view_model.dart`、`ui/search/search_route.dart` |
| `search_completed` | 当前 generation 的任务自然结束且未被取消 | `result`、结果组数、成功/失败书源数、耗时桶 | `ui/search/search_view_model.dart` |
| `book_detail_opened` | 首次本地详情命中或远端详情字段成功解析；静默刷新和重试不重复 | `entry=search/bookshelf` | `ui/book_info/book_info_contract.dart`、`book_info_view_model.dart`、各详情入口 |
| `book_added_to_shelf` | 新书真实写入成功；“已经在书架”不记录 | `entry=detail/import` | `ui/book_info/book_info_view_model.dart`、`ui/local_book_import/local_book_import_view_model.dart` |
| `book_source_import_completed` | 一次书源导入事务返回结构化成功结果 | `entry=file/text/qr/remote_sync`、`importedCount`、`blockedCount`、`invalidCount` | `ui/book_source/`、`app/remote_book_source_sync_service.dart` |
| `remote_book_source_sync_completed` | 单次游标同步成功或失败结束；并发复用只由真实任务记录一次 | `result`、本次请求页数、处理条数、耗时桶 | `app/remote_book_source_sync_service.dart` |
| `book_source_change_completed` | `ChangeBookSourceUseCase` 数据事务及非阻断缓存迁移完成 | `migrationProgress`、`migrationReadConfig`、`warningCount` | `domain/usecase/change_book_source_use_case.dart`、`app/app_dependencies.dart` |
| `chapter_source_change_completed` | 候选正文已经写入永久缓存，而不是仅下载成功 | `candidateCount`、从面板开始到保存成功的耗时桶 | `ui/change_chapter_source/`、`ui/reader/reader_contract.dart`、`reader_view_model.dart`、`reader_route.dart` |
| `reader_download_completed` | 同一本书同一 generation 的任务全部进入 success/failed 终态一次 | `result`、批次章节数、耗时桶 | `model/reader/download_coordinator.dart`、`app/app_dependencies.dart` |
| `local_book_import_completed` | 每个选中文件完成解析和书架事务，成功或失败各一次 | `format=txt/epub/pdf/umd`、`result`、单文件耗时桶 | `model/local_book/local_book_service.dart`、`ui/local_book_import/local_book_import_view_model.dart` |
| `crash_report_upload_result` | 单份手动上传得到成功回执或最终失败 | `result`、`duplicate` | `api/remote_app/remote_app_api.dart`、`help/crash_reporting/crash_report_manager.dart`、`app/app_dependencies.dart` |

## 5. 各链路的关键设计

### 5.1 启动和会话恢复

当前 `restoreSession()` 只在本地快照恢复后返回，远端刷新/权限校验继续后台执行，不能为了
埋点重新阻塞启动页。计划为认证边界增加不含 Token 的结构化恢复状态：

- 本地阶段返回 `none`、`restored` 或 `refresh_required`；
- 只有发现持久会话或明确过期会话时才产生一次恢复结果；
- 后台结果通过受控监听状态返回 `success`、`expired`、`unauthorized` 或
  `network_degraded`；
- `PageNestApp` 订阅一次并在 `dispose()` 解除，避免监听泄漏；
- 手动登录不冒充“启动会话恢复”。

### 5.2 搜索

- `historyUsed` 在写入新历史前，用规范化关键词是否已存在于当前历史判断；只上传布尔值。
- `resultCount` 使用用户看到的去重结果组数，不上传书籍或候选标识。
- `successSourceCount`、`failedSourceCount` 使用最终 `BookSearchProgress`。
- 用户取消或被新 generation 替换的搜索不产生 `search_completed`。
- 建议映射：全部书源成功为 `success`，成功与失败并存为 `partial`，无成功书源为 `failed`。

### 5.3 详情和加入书架

- `BookInfoRouteArguments` 增加可空受控入口；搜索和书架明确传入，下载管理等未获白名单
  的入口不记录 `book_detail_opened`。
- 本地书架详情命中和远端详情成功共用一个“已记录”标记；同页面静默刷新、来源回退和重试
  不重复。
- `BookAddedToBookshelf` 与冲突确认后的 `addAsNew` 成功记录 `entry=detail`；
  `BookAlreadyInBookshelf` 不记录。
- 本地书首次导入成功记录 `entry=import`；同内容更新不记录“新增到书架”。
- 阅读器入口的 `entry=reader` 仍未出现在导出枚举说明中，本次不发送，避免服务端拒绝。

### 5.4 书源导入和远端同步

- 文件、剪贴板/手输、二维码的来源必须作为受控枚举随 Intent/Dialog 传递，不能继续用
  `_awaitingScannedImportConfirmation` 推断所有入口。
- 成功导入统计使用 `BookSourceImportResult.imported`、`blockedAdult`、`invalid`。
- 远端同步聚合每批 `BookSourceImportResult`，成功后同时产生：
  `book_source_import_completed(entry=remote_sync)` 和
  `remote_book_source_sync_completed(result=success)`。
- 同步失败只记录 `remote_book_source_sync_completed(result=failed)`，不把未完成事务伪装成
  `book_source_import_completed`。
- 页数和条数统计当前点击触发的本次尝试，不重复使用历史 checkpoint 的累计值。

### 5.5 整书和单章换源

- 整书换源放在 `ChangeBookSourceUseCase` 成功结果之后，覆盖独立换源页和详情冲突替换两条
  调用链；分析失败不能改变 `AppSuccess`。
- `migrationProgress`、`migrationReadConfig` 直接来自用户提交的迁移选项，
  `warningCount` 来自结果且上限 9999。
- 单章换源候选正文下载成功还不是完成；必须把候选数和开始时刻随 Effect/Intent 传给
  `ReaderViewModel`，等 `_cacheGateway.saveChapterContent` 成功后再记录。

### 5.6 离线下载

- 复用 `DownloadTask.generation` 作为批次边界；同一批中每章成功或失败都不单独上报。
- `_evaluateBookScoreIfSettled` 确认全批终态后，同时形成一次分析结果。
- 建议映射：全部成功为 `success`，成功失败并存为 `partial`，全部失败为 `failed`。
- 开始时间只保存在有界内存表；重启恢复、授权中途开启或缺少开始时间时不发送该批事件。
- 批次完成、删除、账号切换、关闭授权后释放测量项，避免内存泄漏和跨账号串用。

### 5.7 本地书导入

- 每个文件使用独立 `Stopwatch`；单文件失败不影响其他文件的事件。
- 只对当前已实现并在白名单建议中出现的 `txt/epub/pdf/umd` 发送。
- 建议 `result`：首次写入为 `imported`，同内容重导为 `updated`，受控失败为 `failed`。
- 只从解析出的格式或文件扩展名得到枚举，不发送文件名、大小、内容哈希或路径。

### 5.8 崩溃报告上传

- `RemoteCrashReportReceipt` 补充并严格解码后端已经返回的 `duplicate` 布尔值。
- 成功使用真实 `duplicate`；失败时 `duplicate=false`。
- 埋点失败不能阻止崩溃报告写回 `uploaded`，也不能把上传成功提示改成失败。
- 崩溃报告内容、异常类型、回执 ID 和本地路径均不进入埋点。

## 6. 预计修改文件

主要修改：

- `lib/src/app/analytics_recorder.dart`
- `lib/src/app/pagenest_app.dart`
- `lib/src/app/app_dependencies.dart`
- `lib/src/app/remote_book_source_sync_service.dart`
- `lib/src/api/remote_app/remote_app_api.dart`
- `lib/src/domain/gateway/authentication_gateway.dart`
- `lib/src/data/repository/authentication_repository.dart`
- `lib/src/domain/usecase/change_book_source_use_case.dart`
- `lib/src/ui/search/search_view_model.dart`
- `lib/src/ui/search/search_route.dart`
- `lib/src/ui/book_info/book_info_contract.dart`
- `lib/src/ui/book_info/book_info_view_model.dart`
- `lib/src/ui/book_info/book_info_route.dart`
- `lib/src/ui/bookshelf/bookshelf_route.dart`
- `lib/src/ui/download_management/download_management_route.dart`
- `lib/src/ui/book_source/book_source_contract.dart`
- `lib/src/ui/book_source/book_source_view_model.dart`
- `lib/src/ui/book_source/book_source_route.dart`
- `lib/src/ui/change_chapter_source/change_chapter_source_contract.dart`
- `lib/src/ui/change_chapter_source/change_chapter_source_view_model.dart`
- `lib/src/ui/reader/reader_contract.dart`
- `lib/src/ui/reader/reader_view_model.dart`
- `lib/src/ui/reader/reader_route.dart`
- `lib/src/model/reader/download_coordinator.dart`
- `lib/src/model/local_book/local_book_service.dart`
- `lib/src/ui/local_book_import/local_book_import_view_model.dart`
- `lib/src/help/crash_reporting/crash_report_manager.dart`

文档同步：

- 本文件；
- `docs/flutter-rewrite/m11/backend_api_integration/08_analytics_event_catalog_proposal.md`；
- `docs/flutter-rewrite/m11/backend_api_integration/05_app_api_20260723_gap_analysis.md`；
- `docs/flutter-rewrite/m11/README.md`；
- `docs/flutter-rewrite/AI_PROJECT_INDEX.md`。

不计划新增依赖，不计划修改 `LegadoDatabase.schemaVersion` 或 `pubspec.yaml` 构建号。

## 7. 实施顺序

1. 补齐事件级 props 类型/枚举校验和登录后队列续传。
2. 接启动/会话事件，保持远端校验不阻塞首帧。
3. 接搜索、详情、加入书架。
4. 接书源导入和远端同步。
5. 接整书换源、单章换源。
6. 接下载批次和本地书单文件结果。
7. 补崩溃上传 `duplicate` 并接上传结果。
8. 更新事件目录、API 差异和 M11 状态为“代码已写入、等待用户验证”。

## 8. 用户验收清单

用户执行构建和检查后，人工覆盖：

1. 授权关闭时完成全部业务路径，确认没有埋点缓存和 `/analytics/batch` 请求。
2. 开启授权，确认只产生一次 `enabled=true`；再次关闭立即清队列，不产生 `enabled=false`。
3. 离线产生事件后登录/重连，确认旧队列自动续传且 UUID 重试不变。
4. 分别验证无会话、有效会话、需刷新、过期、401、网络降级的启动事件。
5. 搜索成功、部分书源失败、全部失败、取消和快速发起新搜索，确认只记录有效 generation，
   且载荷没有关键词。
6. 从搜索和书架打开详情，确认每次页面只记录一次；静默刷新、重试和下载管理入口不误报。
7. 验证详情新增、重复加入、冲突新增、本地书首次导入和同内容更新的加书事件差异。
8. 从文件、文本、二维码和远端同步导入书源，核对导入/屏蔽/无效数量。
9. 验证整书换源事务失败不记录、成功只记录一次；单章必须等永久缓存保存成功后记录。
10. 下载全成功、部分失败、全部失败、暂停恢复、进程重启和账号切换，确认每批最多一次，
    无可信开始时间的恢复批次不伪造耗时。
11. TXT/EPUB/PDF/UMD 单文件成功、更新和失败逐项核对，载荷不包含文件名或路径。
12. 崩溃报告首次上传、幂等重复和失败重试，核对 `duplicate` 与结果且不包含报告内容。
13. 检查每批不超过 50 桶和 16 KiB，服务端 `accepted + duplicate` 等于批次数后才消费本地队列。

## 9. 执行前确认

如果用户确认按本方案执行，则同时确认第 2.3 节建议的五组 `result` 枚举作为当前客户端与
后端契约。若不能确认，需要后端先提供每个事件的完整 props 类型和字符串枚举后再编码；
否则客户端无法在严格白名单条件下可靠完成“全量接入”。
