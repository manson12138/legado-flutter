# App 埋点事件目录建议

状态：`PARTIALLY_IMPLEMENTED_PENDING_USER_VERIFICATION`。Flutter 已按 2026-07-23 API
导出重建用户授权、严格白名单、UUID 幂等事件桶、版本/平台字段、七天窗口和
`/api/v1/analytics/batch` 的 50 条/16 KiB 动态分批；阅读器已接入
`reader_opened`/`reader_open_failed`。其余 P0/P1 仍按本目录逐批接入。AI 未运行构建、测试、
分析、格式化或应用。

## 1. 目标与原则

目标是判断产品漏斗、核心功能成功率和性能分布，而不是记录用户阅读内容或建立跨应用追踪。所有事件均须由用户在设置页主动开启“数据分析”后采集；关闭时不得新增事件，并清空未上传队列。

禁止上报：书名、作者、搜索关键词、正文、章节标题/正文、书源名称、书源 URL、账号名、邀请码、设备唯一标识、IP、Cookie、Access Token、Refresh Token、完整异常或完整路由参数。

允许的 `props` 仅使用枚举、布尔值、数量、耗时分桶、版本和经评审的不可逆聚合标识。禁止使用 Dart `hashCode` 作为跨启动或跨平台的稳定标识。

## 2. P0：建议优先接入

| 事件名 | 触发点 | 安全 props | 目的 |
| --- | --- | --- | --- |
| `app_session_started` | App 首帧后 | `restoreState`（`none`/`restored`/`refresh_required`） | 衡量启动和会话恢复。 |
| `app_session_restore_result` | 自动恢复结束 | `result`（`success`/`expired`/`unauthorized`/`network_degraded`）、`refreshAttempted` | 判断自动登录质量。 |
| `search_submitted` | `SearchViewModel` 提交搜索 | `enabledSourceCount`、`historyUsed` | 统计搜索入口使用，不传关键词。 |
| `search_completed` | 搜索任务完成 | `resultCount`、`successSourceCount`、`failedSourceCount`、`durationBucket` | 判断搜索质量和性能。 |
| `book_detail_opened` | 从搜索/书架进入详情成功 | `entry`（`search`/`bookshelf`） | 统计转化，不传书籍标识。 |
| `book_added_to_shelf` | 加书事务成功 | `entry`（`detail`/`import`） | 衡量书架转化。 |
| `reader_opened` | 阅读器完成首章加载 | `entry`（`bookshelf`/`detail`/`history`）、`contentKind`（`network`/`local`）、`durationBucket` | 衡量真实阅读开启而非仅点击。 |
| `reader_open_failed` | 阅读首章失败且已向用户反馈 | `failureKind`、`contentKind` | 排查阅读闭环失败。 |
| `book_source_import_completed` | 书源导入事务结束 | `entry`（`file`/`text`/`qr`/`remote_sync`）、`importedCount`、`blockedCount`、`invalidCount` | 判断导入质量，禁止传原始 JSON/URL。 |
| `remote_book_source_sync_completed` | 服务端书源分页拉取结束 | `result`、`pageCount`、`sourceCount`、`durationBucket` | 判断受控书源同步可用性。 |

## 3. P1：功能使用与问题定位

| 事件名 | 触发点 | 安全 props | 目的 |
| --- | --- | --- | --- |
| `book_source_change_completed` | 整书换源事务成功 | `migrationProgress`、`migrationReadConfig`、`warningCount` | 评估换源完成率。 |
| `chapter_source_change_completed` | 章节换源成功 | `candidateCount`、`durationBucket` | 评估章节换源质量。 |
| `reader_download_completed` | 离线下载任务结束 | `result`、`chapterCount`、`durationBucket` | 评估离线能力。 |
| `local_book_import_completed` | 本地书解析和入库结束 | `format`（`txt`/`epub`/`pdf`/`umd`）、`result`、`durationBucket` | 评估格式支持。 |
| `settings_analytics_changed` | 用户修改埋点授权 | `enabled` | 只记录授权变化，不记录其他设置。 |
| `crash_report_upload_result` | 用户主动上传崩溃报告结束 | `result`、`duplicate` | 衡量崩溃上报通路，不传报告内容。 |

## 4. 不建议采集的行为

- 阅读页翻页、停留时长、章节位置、书签文本和正文搜索：会构成敏感阅读画像，当前不采集。
- 每个 HTTP 请求、规则执行步骤和书源 URL：量大且可能包含隐私/服务端地址，已有受控的书源质量事件，不重复上报。
- 登录账号、注册邀请码、权限角色原文：敏感且对产品漏斗价值有限。
- UI 点击全量日志：应只保留与明确产品决策关联的完成事件，避免“为了有数据而采集”。

## 5. 属性规范与实现边界

- `durationBucket`：`lt_1s`、`1_3s`、`3_10s`、`10_30s`、`gte_30s`，不上传精确时长。
- `failureKind`：只允许既有受控错误分类，如 `network`、`http_status`、`decode`、`rule`、`permission`、`cancelled`、`unknown`。
- 数量字段上限 9999；超出记为 `9999`，避免异常输入放大载荷。
- 单个事件 props 限制为扁平 Map；不得把异常对象、模型对象、URL 或用户输入直接传入。
- 事件调用应位于 ViewModel、Coordinator 或 UseCase 的“成功/失败结果已确定”处，不放在 Widget `build`、文本输入回调或路由观察器中。

## 6. 建议实施顺序

1. 先为 `RemoteBookSourceSyncService` 抽出独立 `AnalyticsRecorder` 边界，集中验证事件名和 props 白名单。
2. 接入 P0 的搜索、书籍详情/加书、阅读打开、书源导入和远端同步事件。
3. 用户验收事件队列、关闭授权清队列、登录恢复、失败重试与日志无敏感字段。
4. 再接入 P1；每新增一组事件前，先在本文件补充目的、props 和隐私评审。

不新增数据库 Schema；当前队列继续存于既有 `caches` 表，仅在用户同意后写入。

## 7. 当前实施边界

- 已实现：授权关闭立即清除 v2 队列且不发送 `enabled=false`；旧 v1 队列因无法补齐稳定
  `eventId` 而安全删除；相同事件和 props 在 UTC 小时内聚合 `count`，上传回执以
  `accepted + duplicate == batch.length` 才消费本地桶。
- 已接入：阅读首个可读章节成功后的 `reader_opened`，以及首次打开最终失败后的
  `reader_open_failed`；不包含书名、章节、正文、URL 或账号字段。
- 暂缓：导出文档只声明事件和 props 严格白名单，没有确认
  `book_added_to_shelf.entry=reader` 枚举，因此阅读器显式加入书架当前不发送该事件。
- 待实施：搜索、详情/加书、书源导入/远端同步及 P1 事件。新增调用前必须确认后端对每个
  字符串 props 的枚举限制，不能仅凭客户端建议目录猜测。
