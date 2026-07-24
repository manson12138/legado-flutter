# 崩溃日志与轻量埋点设计

状态：`PROPOSED`。本方案只定义 Flutter App、日志管理 UI 与后端之间的契约；未实现代码、未新增依赖、未修改数据库 Schema。

## 1. 目标与边界

目标：在应用私有目录中把每次可捕获的崩溃保存为一个独立、脱敏且有大小上限的报告文件；在“我的”中提供独立的崩溃日志管理页；用户可逐条手动上传，页面进入时准确显示本地上传状态；同时为后端统一规划低流量、非敏感的使用分析。

本期不做：后台自动上传、读取通讯录/设备硬件标识、采集书名/搜索词/书源 URL/正文/Cookie/Token/完整文件路径、采集原生 ANR，或把崩溃文件混入现有 `logs/` 运行日志目录。

## 2. 当前工程事实与影响

- `main.dart` 已通过 `runZonedGuarded`，`app_error_boundary.dart` 已通过 `FlutterError.onError` 和 `PlatformDispatcher.onError` 捕获多数 Dart/Flutter 未处理异常；它们目前只调用异步 `FileAppLogger`。
- `FileAppLogger` 写入应用支持目录下的 `logs/`，有查看、分享、ADB 回显和删除的通用日志页；它不适合承担“一个崩溃一个文件”和上传状态。
- 已有远端 API 的 HMAC 请求签名、内存 Bearer 会话、`/api/v1/analytics/batch` 预留调用及默认关闭的分析同意开关。当前分析队列是通用 `Map`，并且只在登录后上报，不能直接承担崩溃文件上传。
- 因崩溃报告只落在应用支持目录、不进入 SQLite，不需要提升 `LegadoDatabase.schemaVersion` 或 `pubspec.yaml` build number。

## 3. 客户端崩溃报告设计

### 3.1 存储、原子性和保留策略

目录固定为应用支持目录的 `crash-reports/`，与 `logs/` 完全隔离。一次可捕获崩溃对应一个 `crash-<UTC 时间>-<随机 UUID>.json`；报告本身同时保存内容和上传状态，避免额外清单或数据库迁移。

写入采用“同目录临时文件 -> flush/close -> 原子 rename”的最短路径；崩溃写盘不得复用普通日志的异步串行队列，也不得在写盘失败时递归写日志。失败仅尽力写入原生控制台。单份报告序列化后最多 64 KiB；超长异常文本和堆栈按尾部截断，并标注 `truncated: true`。

默认保留上限为 30 份且总量 2 MiB。创建新报告前优先淘汰最早的“已上传”文件；仍超限时淘汰最早的未上传文件。列表页显示“因本地上限丢弃”的累计数量，而不制造无限增长的诊断文件。用户可逐条删除或清空；删除无法恢复。

### 3.2 内容白名单

报告只允许以下字段，所有时间使用 UTC ISO-8601：

```json
{
  "schemaVersion": 1,
  "reportId": "uuid-v4",
  "occurredAt": "2026-07-23T12:34:56.789Z",
  "source": "flutter_framework | platform_dispatcher | zone | startup | android_native | ios_native",
  "exceptionType": "StateError",
  "exceptionSummary": "最多 500 字符、已脱敏",
  "stackTrace": "最多 48 KiB、已脱敏",
  "app": {"versionName": "1.0.0", "versionCode": 5, "buildChannel": "..."},
  "runtime": {"platform": "android | ios", "osVersion": "...", "dartVersion": "..."},
  "upload": {"state": "pending | uploading | uploaded | failed", "attemptCount": 0, "uploadedAt": null, "receiptId": null, "lastFailureCode": null},
  "truncated": false
}
```

禁止写入的内容包括异常字符串中可能出现的密码、Authorization、Cookie、token、书源 URL 的 query、书名、搜索词、正文、绝对路径和用户输入。实现时必须使用专用 `CrashReportSanitizer` 做字段名脱敏、凭据模式脱敏、URL query 移除、路径替换和长度限制；不能假设现有业务日志已完全脱敏。`reportId` 是每次报告随机生成的幂等键，不是设备标识。

### 3.3 捕获范围

Flutter/Dart 侧统一将 `FlutterError.onError`、`PlatformDispatcher.instance.onError`、`runZonedGuarded`、启动期初始化失败写入报告，并继续保持现有错误展示/控制台行为。相同异常在极短时间窗口内可能被多个入口观察到，报告器以“异常类型 + 规范化栈摘要 + 发生时间窗口”的内存去重键避免一次异常生成多份文件。

Android 原生崩溃另由 `Thread.setDefaultUncaughtExceptionHandler` 在交还给系统默认 handler 前尽力写入最小 JSON；不得吞掉或改变系统崩溃流程。iOS 可通过 `NSSetUncaughtExceptionHandler` 保存 Objective-C 异常摘要；信号级崩溃和 Dart VM/原生 ANR 不保证可捕获，后续如需覆盖，应接入专门的 crash SDK 并重新评估依赖、隐私和体积。崩溃前的进程直接被杀死时，任何异步上传都不可靠，因此本设计只保证本地尽力落盘。

## 4. “我的”页和崩溃日志管理页

在“我的 -> 应用管理”增加“崩溃日志”入口，副标题显示“查看、上传或删除崩溃报告”。新增稳定路由 `/settings/crash-reports`，采用现有 `Contract -> ViewModel -> Route -> Screen` 结构，不改动普通日志页的行为。

列表按发生时间倒序，单项展示发生时间、来源、异常类型、文件大小和以下状态之一：未上传、上传中、已上传、上传失败（可重试）。支持查看脱敏内容、逐条上传、分享、逐条删除和清空；上传中禁止重复点击与删除，路由销毁后应取消 UI 订阅而非持有 `BuildContext`。

进入列表时只读取每个报告内部的 `upload.state`，因此无需额外网络请求，也能准确判断“本设备是否已成功上传”。成功响应后以原子重写同一文件标记 `uploaded`。重新安装、手工恢复文件或本地状态损坏时，客户端可再次发起上传；后端用 `reportId` 幂等去重。不要在每次进入页面调用“查询是否已上传”的 API——它会以高频列表访问换取极低价值，增加后端流量和存储压力。

## 5. 上传协议：建议 JSON，不上传文件

后端已于 2026-07-23 确认接口：每次上传一个 JSON 报告到 `POST /api/v1/crash-reports`，`Content-Type: application/json`。请求体使用第 3.2 节报告字段，并在顶层补充 `productId`；`upload` 只发送 `attemptCount`，不发送本地失败文案、上传状态或本地时间。响应遵循统一信封 `{"code": number, "message": string, "data": unknown}`，仅当 `code == 0` 且 `data.accepted == true` 时标记本地文件为已上传；`data` 的 `duplicate`、`receiptId` 和 `retentionDays` 分别写入展示状态、回执和服务端保留期。崩溃报告上限 64 KiB，JSON 比 multipart 文件更易做字段白名单、网关体积限制、去重、索引和故障排查；在这个体积下 gzip/multipart 的收益小于复杂度。若未来放宽报告体积，再在服务端支持 `Content-Encoding: gzip`，客户端仍维持单报告单请求。

请求沿用现有 `X-App-Timestamp`、`X-App-Nonce`、`X-App-Signature` HMAC 约定；Bearer token 可选，不能作为上传前提，因为崩溃发生时通常没有登录会话。有有效 Token 时由服务端关联上传账号，无 Token 时记匿名；客户端不得为上传而持久化 Token。客户端 HMAC 只用于抬高滥用成本，不是机密。服务端已确认以 `productId + reportId` 做唯一幂等键，重复提交返回成功语义而非 409，并按服务端指纹自动合并为同一个 Bug。

已确认的成功响应为：

```json
{"accepted": true, "duplicate": false, "receiptId": "cr_...", "retentionDays": 30}
```

失败时使用受控错误码：`CRASH_REPORT_TOO_LARGE`、`INVALID_REPORT`、`RATE_LIMITED`、`PRODUCT_DISABLED`。客户端仅保存错误码，不保存服务端原文。

服务端建议：网关限制 96 KiB、按 IP/product 限流、校验字段白名单和时间窗口；关系库只保存检索元数据、指纹和对象存储 key，原始 JSON 压缩后存对象存储；原始报告保留 30 天，聚合后的指纹/版本/平台统计保留 180 天。未经人工扩展白名单的字段直接拒绝，不应“原样兜底”存储。

## 6. 埋点设计：低流量、先聚合、显式同意

崩溃的“本地收集”与“手动上传”不依赖匿名使用分析开关；用户点上传即为对该单份报告的明确操作。常规分析继续保持默认关闭，关闭时不得采集、落盘或上报。开启后只上报下列事件的枚举值、计数、耗时分桶和错误类别：

| 类别 | 事件/字段 | 禁止字段 | 采样与频率 |
| --- | --- | --- | --- |
| 启动稳定性 | `app_start`、`startup_stage_failed`、耗时分桶、错误类别 | 堆栈、设备 ID | 每会话一次 |
| 核心功能结果 | `book_source_import_result`、`search_result`、`reader_open/result`、`offline_download_result`、`change_source_result` | 书名、搜索词、书源 URL、正文 | 本地计数，前台/阈值触发批量 |
| 网络质量 | `remote_api_result`、HTTP 类别、耗时分桶、重试次数 | URL、请求/响应正文、Header | 按 endpoint 枚举聚合 |
| 性能 | 冷启动、首屏、首章/分页耗时分桶 | 精确阅读内容与逐帧数据 | 1% 稳定采样 |

不建议默认记录页面浏览、点击流、停留时长和每次翻页；它们流量大、分析价值有限，也更容易形成用户行为画像。现有书源事件上报中包含原始 `bookSourceUrl`，与本方案的最小化原则冲突：后端若确需书源质量归因，应另行确定不可逆的服务端可识别 ID/哈希规则、保留期限和同意策略，不能静默沿用原 URL。

`/api/v1/analytics/batch` 应改为严格 DTO，而非任意 `Map`：一个批次最多 50 条、16 KiB；同一 `eventName + props bucket + UTC day` 在客户端先合并为计数，最多缓存 500 个聚合桶；应用进入前台、积累到 20 桶且距上次成功上传至少 6 小时时尝试一次。失败使用指数退避并保留队列，上限外淘汰最早聚合桶。服务端按 `eventId` 幂等、按产品/版本/平台/日聚合，原始事件最长保留 7 天，聚合指标 180 天。

## 7. 后端交付清单

1. 定义并发布 `POST /api/v1/crash-reports` 的 OpenAPI、签名校验、64 KiB body 限制、幂等与受控错误码。
2. 建立 crash metadata 表和压缩对象存储生命周期；提供仅后台使用的按版本/指纹聚合查询，不向 App 暴露上传查询接口。
3. 确认 `/api/v1/analytics/batch` 的 DTO、同意策略、采样、去重键、限流和保留期，并废弃任意属性 Map 的契约。
4. 明确书源质量事件是否需要服务端归因；若需要，先给出不可逆标识规则和隐私说明，再改客户端。
5. 提供 API 文档后，客户端再实现专用 CrashReportStore、CrashReportGateway/Repository、管理页和严格埋点 DTO；届时复核 Android/iOS 原生桥接限制。

## 8. 客户端实施顺序与验收

先实现本地报告与 Dart 入口，再接独立列表/查看/删除/分享 UI，随后在拿到 API 后接手动上传和本地状态回写，最后替换现有通用分析队列为严格聚合 DTO。实现时保持文件 I/O 串行、页面订阅可释放、网络请求可取消，且不在 UI 直接访问文件或 HTTP。

用户验收应覆盖：三类 Dart 未处理异常各产生一份独立报告；敏感字符串不进入文件；重启后未上传/已上传状态正确；上传成功后再次进入页面不发查询请求且显示已上传；重复点击不重复上传；离线、限流和 5xx 后可重试；达到本地上限时保留策略正确；Android/iOS 原生崩溃能力按各自保证范围验证。AI 不运行构建、测试、分析或应用。
