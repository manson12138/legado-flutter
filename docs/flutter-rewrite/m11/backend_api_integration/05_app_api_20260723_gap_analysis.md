# 2026-07-23 App 客户端 API 文档差异分析

状态：`IMPLEMENTED_PENDING_USER_VERIFICATION`。本文件按
`novel-admin-api-App-客户端-2026-07-23 (1).json` 与 Flutter 当前静态源码比对。2026-07-23
已完成本文件列出的 Flutter 侧 P0/P1，以及成功率聚合和匿名埋点契约改造；真实后端登录响应的
`user` 字段仍待服务端修正并由用户验收。AI 未运行构建、测试、分析、格式化或应用。

## 1. 结论与范围

当前 Flutter 已覆盖登录/注册、邀请码、权限、启动聚合、过滤规则、分页书源、书源事件、分析、崩溃报告、公告和功能开关的主要调用链。需要优先修复的不是新增接口，而是三类已有接口的契约与安全问题：登录响应缺失判定、启动接口版本及更新字段、认证数据日志脱敏。

本次不纳入：`GET /api/v1/app/access-check`、`GET /api/v1/app/update-check`、`GET /api/v1/booksource/list` 和 `POST /api/v1/filter/upload`。前两者已被 `bootstrap` 聚合，书源全量接口仅服务旧客户端，过滤上传需要独立的管理员配置 UI。`GET /api/v1/booksource/share/:token` 保持由既有远程 JSON 导入路径消费，不应另建重复 HTTP 链路。

## 2. P0：登录接口与日志安全

### 2.1 登录响应契约

接口文档要求 `POST /api/v1/auth/login` 的 `data` 同时包含 `token` 与 `user`。2026-07-23 的真实日志却只返回了 `token`，所以 Flutter 在 `RemoteAppApi.loginWithProfile` 解码时失败；这属于服务端响应违反当前文档，不能由客户端伪造用户资料补救。

Flutter 已把现有笼统的“App 登录响应缺少 token”拆为 `token` 缺失和 `user` 缺失两类错误。后端仍需要确保成功响应始终返回 `user.id`、`user.username`、`user.status`。

### 2.2 登录日志脱敏

接口文档明确禁止记录 `username`、`passwordEncrypted`、`token`、`publicKey` 和完整登录请求/响应体。当前 `AppDioLogInterceptor` 对字符串 JSON 只按少量固定字段名遮盖；实际日志已经暴露用户名、RSA 密文和公钥。

Flutter 已对 `/api/v1/auth/password-key`、`/api/v1/auth/login`、`/api/v1/auth/register` 实施路径级正文摘要策略：日志保留方法、路径、状态、耗时和响应类型，正文一律不输出；通用敏感字段识别也已覆盖 `username`、`passwordEncrypted`、`publicKey`。不得为此记录 token、密文、密钥或响应正文。

## 3. P0：启动、准入与升级契约

`GET /api/v1/app/bootstrap` 现在要求 `productId`、`versionName`、`versionCode` 和可选 `channel`。Flutter 已从集中构建配置发送语义版本名，不以 build number 替代。

`bootstrap.update` 文档字段为 `latestVersion`、`latestVersionCode`、`downloadUrl`、`changelog`。Flutter 已统一 DTO、`AppAccessState` 和升级 UI：展示 `latestVersion`、`changelog` 与非空 `downloadUrl`，地址可长按复制；合法 HTTP/HTTPS 地址可点击交给系统外部浏览器，无法自动打开的地址仍保留可见和可复制，iOS 不自动下载或安装。

同时需要与后端确认版本码规则：接口示例为 `20300`，当前 Flutter 默认值随本次 Schema 构建升为
`6`。在确认前不能擅自转换既有 build number。

## 4. P1：接口已接入且需继续保持的契约

| 接口 | 现有实现 | 结论 |
| --- | --- | --- |
| `GET /auth/password-key` | 已校验 RSA-OAEP、SHA-256、keyId、PEM | 保持内存缓存；按 P0 禁止输出正文。 |
| `POST /auth/register` | 已接入 RSA 密文、邀请码及用户 DTO | 同步应用路径级日志脱敏。 |
| `POST /invitations`、`GET /account/permissions` | 已接入内存会话 | 无字段差异。 |
| `GET /booksource/page` | 已按页校验 total、page、pageSize | 无字段差异；服务端 403 继续作为最终权限判定。 |
| `GET /filter/keywords`、`GET /filter/domains` | 已接入启动刷新 | 无字段差异。 |
| `GET /announcements`、`GET /flags` | 已接入远端配置仓储 | 无字段差异。 |
| `POST /analytics/batch` | 已按用户授权、UUID、版本/平台、count、严格白名单和 50 条/16 KiB 动态分批重建 | 本专项已接阅读成功/失败；其余事件需逐项确认字符串 props 枚举后接入，不创建设备标识。 |
| `POST /crash-reports` | 已签名并支持可选 Bearer | 崩溃载荷的 `versionName` 当前写死 `1.0.0`，应改为集中构建配置。 |
| `POST /booksource/stats/batch` | 已按 `search/toc/content`、UTC 日聚合，并实现未知书源两阶段补充 | 校验 `canSyncBookSource`，按 50 条/96 KiB 动态拆批；私网或疑似凭据书源不上传。 |
| `POST /booksource/event` | 旧逐条 API 方法仍保留兼容，但不再作为主成功率链路 | 不新增 `deviceId`；待服务端明确下线窗口后再单独移除。 |

## 5. 计划修改文件

| 文件 | 计划改动 |
| --- | --- |
| `lib/src/api/http/app_dio_log_interceptor.dart` | 已完成登录/注册/公钥路径的正文摘要与字段脱敏。 |
| `lib/src/api/remote_app/remote_app_service_config.dart` | 已增加集中 `appVersionName`；继续由 `--dart-define` 覆盖。 |
| `lib/src/api/remote_app/remote_app_api.dart` | 已发送 bootstrap `versionName`，解码更新字段并区分登录 token/user 缺失。 |
| `lib/src/app/app_access_coordinator.dart`、`lib/src/app/legado_app.dart` | 已透传并展示更新说明与受控下载地址。 |
| `lib/src/app/remote_book_source_sync_service.dart` | 已拆分成功率与匿名埋点边界，并保留统一登录后刷新入口。 |
| `lib/src/app/source_success_rate_reporter.dart` | 已实现聚合桶、权限、时间窗口、两阶段补源、敏感书源拦截和动态分批。 |
| `lib/src/app/analytics_recorder.dart` | 已实现授权、严格白名单、UUID 幂等桶、旧队列清理、聚合及动态分批。 |
| `lib/src/help/crash_reporting/crash_report_manager.dart`、组合根 | 已让崩溃报告使用集中版本名/版本码/渠道。 |
| `docs/flutter-rewrite/m11/backend_api_integration/01_implementation_plan.md`、`02_authentication_and_api_gap_plan.md`、`03_app_access_and_update_plan.md` | 已更新实现快照，不改变阶段为 `DONE`。 |

成功率和埋点队列继续复用 `caches` 表，本身不新增 Schema。同期书架/历史专项新增两张历史表，
因此 `LegadoDatabase.schemaVersion` 已升至 8，`pubspec.yaml` build number 已升至 `+6`；
该升级不是 API 队列引起。

## 6. 用户验收

1. 后端成功登录返回 `token + user` 后，确认 Flutter 登录成功并继续请求权限。
2. 服务端分别缺失 token、user 时，确认页面得到准确错误；日志仅有阶段和错误类型。
3. 登录、公钥、注册日志中确认不存在用户名、RSA 密文、公钥、token 或完整正文。
4. `bootstrap` 请求含 `versionName`，并按后端确认的版本码规则比较。
5. 有更新、强制更新、无下载地址、Android 有合法下载地址和 iOS 更新提示分别验收。
6. 登录且有书源同步权限后分别制造 `search/toc/content` 成功和失败，确认按日聚合、两阶段补源且不影响业务主链。
7. 开关数据分析授权，确认未授权不落队列、关闭立即清空、已授权上传包含
   `schemaVersion/eventId/count/version/platform`，重复回执可正确消费本地桶。
