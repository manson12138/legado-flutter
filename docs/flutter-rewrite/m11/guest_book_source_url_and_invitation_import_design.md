# 游客通过 URL 或邀请码导入书源方案

状态：`IMPLEMENTED_PENDING_USER_VERIFICATION`

日期：2026-07-27

实施说明：代码已按本方案写入，未运行构建、测试、分析、格式化或应用。

## 1. 用户目标与已确认边界

本次只为未登录游客补充远程书源导入能力：

1. 游客状态继续不显示现有“同步服务器书源”按钮。
2. 游客状态在书源管理页面的“更多导入方式”菜单中增加“输入 URL”。
3. 输入绝对 HTTP/HTTPS URL 时，下载其 JSON 内容，再进入现有 JSON 导入确认和冲突处理流程。
4. 输入内容不是 URL、且符合邀请码候选条件时，调用游客书源 API：先兑换临时游客凭证，再按游标分页同步书源。
5. 正常登录用户保持以前的逻辑不变，包括入口、权限判断、账号 Token、V2 游标断点和同步反馈。

明确不包含：

- 不向登录用户展示新的游客入口。
- 不使用游客凭证替代或降级正常账号权限。
- 不持久化邀请码或 `guestToken`。
- 不修改书源数据库表、用户作用域或登录会话。
- 不修改服务端和 Android 参考工程。

## 2. 当前实现事实

### 2.1 书源管理入口

`book_source_route.dart` 根据当前 `AppAuthenticationSession` 判断：

```text
session.permissions.canSyncBookSource == true
  -> 显示现有服务器同步按钮
否则
  -> 不显示
```

因此游客当前已经不会看到账号服务器同步按钮。

`book_source_screen.dart` 的“更多导入方式”当前包含：

- 粘贴 JSON 文本；
- 从剪贴板导入；
- 扫描二维码。

### 2.2 URL 与 JSON 导入

现有 `BookSourceImportTextResolver` 已支持：

- HTTP/HTTPS 地址下载；
- 禁用 Cookie；
- 15 秒连接、30 秒接收及总超时；
- 最多 10 次重定向；
- 5 MiB 响应限制；
- 压缩、UTF-8/GBK 和服务端字符集解码；
- `#requestWithoutUA` 约定。

下载后的文本最终进入：

```text
ImportTextDialog
  -> ImportBookSourceTextIntent
  -> ImportBookSourcesUseCase
  -> BookSourceRepository.importSourceJson
```

该链路已经支持 JSON 单对象、数组、转义字符串、同 URL 覆盖/跳过、无效项摘要和事务写入。新 URL 入口应复用这条链路，不能另写 JSON 解码或数据库导入逻辑。

Android 参考 `ImportBookSourceViewModel.importSource/importSourceUrl` 同样把绝对地址下载结果当作书源 JSON 数组处理；游客邀请码属于 Flutter 后端接入扩展，没有 Android 对照入口。

### 2.3 正常账号同步

现有 `RemoteBookSourceSyncService` 使用：

- 登录账号 Access Token；
- `canSyncBookSource` 权限；
- `GET /api/v1/booksource/page`；
- HMAC + Bearer；
- `caches` 中的 V2 游标断点；
- 每批成功导入后才推进断点；
- `ImportBookSourcesUseCase` 的覆盖策略。

本次不能修改这套账号状态机的入口、权限、断点键和失败恢复语义。

## 3. 游客与登录账号的最终入口矩阵

| 当前状态 | 现有云同步按钮 | “更多”中的“输入 URL” | 同步实现 |
| --- | --- | --- | --- |
| 游客，`session == null` | 隐藏 | 显示 | URL JSON 导入或邀请码游客同步 |
| 已登录且有同步权限 | 保持显示 | 隐藏 | 现有账号 V2 游标同步 |
| 已登录但无同步权限 | 保持隐藏 | 隐藏 | 不新增游客降级入口 |

这样可保证正常登录用户“走以前的逻辑不变”，也避免无权限账号通过游客入口静默绕过当前账号语义。

## 4. 游客输入界面与分类规则

游客点击“更多 → 输入 URL”后打开路由局部对话框：

- 标题：“输入 URL 或邀请码”；
- 单行输入；
- 提示：“URL 返回书源 JSON；非 URL 内容将尝试作为管理员邀请码”；
- 关闭时释放 `TextEditingController`；
- 禁用输入建议和自动纠错，避免邀请码进入键盘学习；
- 提交中禁止重复点击。

输入只在提交时去除首尾空白，并按以下顺序分类：

1. 绝对 HTTP/HTTPS URI 且 host 非空：按 URL 处理。
2. 已有 URI scheme、疑似 `://` 地址、JSON 对象/数组或超长文本，但不是有效 HTTP/HTTPS URL：直接提示格式错误，不能把它上传为邀请码。
3. 其余不含空白的短文本：作为邀请码候选，由服务端做最终校验。

客户端不猜测邀请码固定长度或字符集，因为当前 API 只提供示例，没有给出稳定格式契约；仅设置合理输入上限，避免异常大文本进入签名请求。

## 5. URL 分支

```text
游客输入 URL
  -> GuestBookSourceImportService 判定为 HTTP/HTTPS
  -> BookSourceImportTextResolver.resolveRemoteUrl
  -> 返回不可信 JSON 文本
  -> 关闭 URL 输入对话框
  -> 打开现有 ImportTextDialog
  -> 用户选择覆盖或跳过
  -> ImportBookSourcesUseCase
  -> 展示现有 ImportSummaryDialog
```

实施时为 `BookSourceImportTextResolver` 增加明确的“手动 URL”入口：

- 复用现有 HTTP、大小、字符集和取消能力；
- 不保存原始输入到扫码诊断文件；
- 不把手动 URL 的响应写入扫码诊断文件；
- 原二维码入口继续保持当前诊断行为；
- 下载完成后不提前解释书源字段，仍交给既有导入解码器。

URL 分支使用 `BookSourceImportEntry.remoteUrl` 记录安全的入口枚举和导入数量，不记录输入 URL 或响应正文。

## 6. 邀请码分支与 API

### 6.1 兑换临时凭证

新增 API 方法：

```text
POST /api/v1/booksource/guest/session
App HMAC，无登录 Bearer

body:
  productId: RemoteAppServiceConfig.productId
  invitationCode: 用户本次输入
```

严格解码：

- `guestToken` 必须是非空 Base64URL 风格字符串；
- `expiresAt` 必须是可解析的未来 UTC 时间；
- 统一响应信封必须满足既有 `{code,message,data}` 契约。

邀请码只允许发送到这个固定服务端接口。它不进入日志、崩溃报告、埋点、缓存、数据库、Secure Storage、AuthenticationGateway 或扫码诊断文件。

### 6.2 游标分页

兑换成功后：

```text
GET /api/v1/booksource/guest/page
App HMAC + Authorization: Bearer <guestToken>
首次不传 beforeId
后续传上一批 nextCursor
```

每批严格校验：

- `items` 是数组；
- `total >= 0`；
- `pageSize == 50`；
- `hasMore` 是布尔值；
- `hasMore=true` 时 `nextCursor` 是正整数；
- `hasMore=false` 时 `nextCursor == null`；
- 下一游标必须严格小于当前 `beforeId`；
- 空 items 只能出现在完成批次。

每批 `items` 通过：

```text
jsonEncode(items)
  -> ImportBookSourcesUseCase
     conflictPolicy: overwrite
     filterBlockedSources: false
```

即继续使用现有 JSON 校验、未知字段保留和事务写入。成人内容可见性仍在现有 Repository/搜索读取阶段统一处理，不在游客同步时改写服务端数据。

### 6.3 凭证和断点生命周期

- `guestToken`、`expiresAt` 和 `beforeId` 只保存在当前异步操作的局部内存中。
- 不写入账号的 V2 checkpoint，也不创建游客持久 checkpoint。
- 页面离开、游客登录账号或操作完成后，取消未开始的网络请求并释放局部引用。
- 已经开始的单批数据库事务不强行中断，避免部分写入。
- 某批失败前已经成功提交的批次保留在本地。
- 再次输入邀请码时重新兑换新凭证并从第一页开始；同 URL 覆盖使重复批次保持幂等。

不保存断点是有意的安全取舍：如果只保存 cursor，无法证明下次输入的邀请码仍对应同一管理员和同一可见数据集；如果保存邀请码哈希，又会留下可离线枚举的凭据派生值。

## 7. 分层设计

新增 `GuestBookSourceImportService`，职责为：

- 分类游客输入；
- 调用现有 URL 解析器；
- 兑换游客凭证；
- 执行单飞游客游标分页；
- 每批复用导入 UseCase；
- 只向 UI 返回 JSON 文本、进度计数或安全结果，不返回邀请码和 Token。

建议结果类型：

```text
GuestBookSourceUrlResolved
  sourceJson

GuestBookSourceInvitationImported
  importedCount
  invalidCount
  processedCount
  batchCount
  totalCount
```

建议进度阶段：

```text
resolvingInput
downloadingUrl
exchangingInvitation
fetchingBatch
importingBatch
```

Route 负责显示、关闭对话框和 Snackbar；Screen 只展示游客菜单入口和安全进度；网络、签名、分页、JSON 解码和数据库写入不进入 Widget。

## 8. HMAC、日志与敏感数据保护

HMAC canonical 严格按用户提供的 API：

```text
HTTP_METHOD + URL_PATH + TIMESTAMP + NONCE + RAW_BODY
```

- POST session 的 RAW_BODY 必须是实际发送的同一 JSON 字符串。
- GET page 的 RAW_BODY 为空。
- `beforeId` 查询参数不进入 URL_PATH canonical。
- nonce 每次重新随机生成，客户端不持久化。

新增流程的应用日志和网络日志统一使用 `GUEST_BOOK_SOURCE_IMPORT` Tag，只允许记录：

- 阶段；
- URL/邀请码分类结果；
- HTTP 状态和受控错误类别；
- 批次、数量和耗时。

禁止记录：

- 原始输入；
- URL；
- 邀请码及其哈希；
- `guestToken`；
- Authorization；
- nonce、签名；
- 书源 JSON 和响应正文。

现有网络拦截器必须同步增加：

- `invitationCode` 敏感键；
- `guestToken`、App nonce 和 App signature 的明确遮盖；
- `/api/v1/booksource/guest/session` 请求和响应正文整体隐藏；
- 游客书源请求使用正文摘要而不是完整响应日志。

不能把邀请码交给当前扫码解析器，因为扫码诊断逻辑会保存原始输入；URL 分支也应关闭扫码诊断文件写入。

## 9. 错误反馈

| 场景 | 游客提示与行为 |
| --- | --- |
| URL 为空、协议不支持或 host 无效 | 提示输入有效 HTTP/HTTPS URL 或管理员邀请码，不发网络请求 |
| URL 超时、状态异常、超过 5 MiB、响应为空 | 显示远程 JSON 读取失败，现有书源不变 |
| URL 返回无效 JSON/无效书源 | 由现有导入对话框和导入摘要展示，无单独解析分支 |
| 邀请码无效、过期或不存在 | 提示邀请码无效或已过期，不保留输入 |
| 邀请人不是启用 admin，或没有邀请/书源同步权限 | 提示该邀请码不能用于游客书源同步 |
| 产品不匹配 | 提示邀请码不适用于当前 App |
| 429 | 提示请求过于频繁，稍后重试 |
| 游客 Token 在分页中失效 | 停止后续请求，提示重新输入邀请码 |
| HMAC 时间或签名失败 | 提示应用签名或设备时间校验失败 |
| 游标/分页协议矛盾 | 停止且不推进内存游标，提示服务端同步协议异常 |
| 页面销毁或会话切换 | 取消网络请求，不再更新已销毁 UI |

UI 不直接展示任意服务端 `message`，而是根据 HTTP 状态、业务码和受控失败类型转换为固定中文提示。

## 10. 性能与内存

- 游客分页固定每批 50 条，获取一批、导入一批、释放一批，不把全部服务器书源长期累积在内存。
- 整个游客操作单飞，避免双击产生两套凭证、分页和重复事务。
- URL 下载沿用 5 MiB 上限和取消令牌。
- 页面只保存计数型进度，不把书源 JSON 放入长期 UiState。
- `guestToken` 只被当前 Future 调用链短暂引用，操作结束后服务不保留字段。
- 控制器、订阅和取消令牌在 Route `dispose` 时释放，避免页面退出后回调和内存泄漏。
- 不增加常驻 worker、定时器或数据库观察流。

## 11. 预计文件范围

| 文件 | 预计调整 |
| --- | --- |
| `lib/src/ui/book_source/book_source_screen.dart` | 仅游客的“输入 URL”菜单项和游客进度展示 |
| `lib/src/ui/book_source/book_source_route.dart` | 监听会话、显示游客输入对话框、连接游客服务并处理安全结果 |
| `lib/src/ui/book_source/book_source_contract.dart` | 增加 `remoteUrl` 导入入口枚举；不把邀请码放入长期 UiState |
| `lib/src/model/book_source/book_source_import_text_resolver.dart` | 增加不写扫码诊断文件的手动 URL 下载入口 |
| `lib/src/api/remote_app/remote_app_api.dart` | 新增游客凭证和游客分页 API、严格 DTO 解码及取消支持 |
| `lib/src/app/guest_book_source_import_service.dart` | 新增游客输入分类、临时凭证、分页和批次导入服务 |
| `lib/src/app/app_dependencies.dart` | 组合并注入游客服务 |
| `lib/src/help/logging/app_logger.dart` | 增加本流程统一 Tag |
| `lib/src/api/http/app_dio_log_interceptor.dart` | 补充邀请码、游客 Token 和 HMAC 字段脱敏及游客正文摘要 |
| `docs/flutter-rewrite/AI_PROJECT_INDEX.md` | 索引游客 URL/邀请码导入职责与调用链 |

不涉及 `LegadoDatabase.schemaVersion` 和 `pubspec.yaml` build number。

## 12. 用户验收要点

### 12.1 入口隔离

1. 游客打开书源管理：没有现有云同步按钮，“更多”中出现“输入 URL”。
2. 登录有权限账号：仍显示原云同步按钮，“更多”中不出现游客入口。
3. 登录无权限账号：保持既有行为，既无云同步按钮，也无游客入口。
4. 账号 V2 checkpoint 的续传、完成和错误反馈与修改前一致。

### 12.2 URL

1. 输入返回单对象、数组和转义 JSON 的 HTTP/HTTPS 地址，均进入现有导入预览。
2. 分别验证覆盖和跳过，结果摘要正确。
3. 非 HTTP 协议、空响应、超时、超过 5 MiB 和无效 JSON 不损坏现有书源。
4. URL 输入和返回正文不出现在日志或扫码诊断文件。

### 12.3 邀请码

1. 有效 admin 邀请码成功兑换凭证，并跨越至少 3 批完成同步。
2. 普通用户邀请码、过期邀请码、产品不匹配、管理员禁用和权限撤销分别得到固定错误提示。
3. 分页期间撤销权限或令 Token 过期，后续请求立即停止。
4. 中途失败后已提交批次保留；重新输入邀请码从第一页幂等覆盖，不出现重复主键或数据损坏。
5. 连续快速提交只运行一个游客任务；页面退出或登录账号后不再更新旧页面。

### 12.4 安全

1. SQLite、`caches`、安全存储、日志、崩溃报告和埋点中都不存在邀请码、邀请码哈希或 `guestToken`。
2. 网络日志不包含 Authorization、App nonce、App signature、URL、书源 JSON 或游客会话响应正文。
3. 邀请码只发送到 `/api/v1/booksource/guest/session`，`guestToken` 只发送到 `/api/v1/booksource/guest/page`。
