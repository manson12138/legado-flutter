# App 后端 API 接入实施方案

状态：`IN_PROGRESS`。本方案定义 Flutter App 与 `novel-admin-platform` App 端 API 的接入边界；P0 基础设施已有代码，但尚未获得 Android/iOS 验收结果。

实施快照：P0 启动/过滤基础设施已开始实现。当前采用用户确认的“客户端 HMAC 仅作为防滥用门槛”方案；服务地址、产品 ID、语义版本名、构建号、channel 与 HMAC 密钥统一通过 `--dart-define` 配置，默认值仅对齐本地后端开发环境，线上构建必须覆盖 HMAC 密钥。2026-07-23 App API 导出对齐已补充 bootstrap 的 `versionName`、`latestVersion`/`downloadUrl`/`changelog` 解码及 Android HTTPS 外部升级入口；AI 未运行构建、测试或检查。

P1 实施快照：已接入 App 登录与服务端书源下载。会话 token 只驻留内存，应用重启后必须重新登录；下载结果不会直接写库，而是复用既有 JSON 预览、成人内容过滤、冲突策略和导入事务。

分页书源同步实施快照：服务器书源同步已切换为 `/api/v1/booksource/page?page=N`。客户端逐页校验总数、页码和分页大小；任意一页失败或发现同步期间总数变化时，停止并要求重新同步，且不会写入本地书源。为保留现有“一次预览、一次确认导入”的交互，全部页面仍会在确认前合并为 JSON 数组；后续如书源规模继续增大，再拆分为逐页预览和逐页导入。

书源成功率实施快照：搜索、目录和正文的最终成功/失败按
`bookSourceUrl + eventType + UTC 日` 聚合，通过 `/booksource/stats/batch` 以每批最多 50 桶、
完整请求最多 96 KiB 上传；未知书源只按服务端返回的 missing URL 在第二阶段补充完整 JSON。
无同步权限、未登录、上报失败、私网地址或疑似凭据书源都不会影响业务主链。旧
`/booksource/event` API 方法只保留兼容，不再作为主链路。

运营与分析实施快照：bootstrap 返回的公告与功能开关会被拆分缓存，后续具体 Feature 可按需单独刷新；因后端尚未定义 flag key 到业务行为的映射，本轮不擅自改变阅读功能。分析事件默认不采集且不保留，只有用户主动同意后才进入独立 v2 队列；载荷使用 UUID、版本/平台、count、严格白名单及 50 条/16 KiB 动态分批。本专项已接入阅读成功/失败事件，其余目录事件待逐项确认后端字符串枚举。

公告与同意 UI 实施快照：设置页提供默认关闭的分析同意开关，关闭时立即清除未上传分析队列；主界面首次可用后拉取并展示一条未读公告，用户关闭后本地记录公告 ID，避免重复打扰。公告或网络失败不影响本地启动。

## 1. 唯一目标与范围

目标是在 Flutter 中以一个独立的“远端 App 配置与运营能力” Feature 接入后端 `http://47.109.99.126/api/v1`，优先完成启动期 bootstrap、过滤规则和受控书源同步，并为登录、书源事件、公告、功能开关和分析埋点保留同一契约。

本轮不包含管理端 `/api/admin/*`、后端路由或数据库修改、崩溃上报、用户自定义书源提交、后台长期同步，亦不修改既有书源规则 HTTP 链路。

## 2. 接口清单与优先级

| 优先级 | 接口 | Flutter 行为 | 认证要求 |
| --- | --- | --- | --- |
| P0 | `GET /app/bootstrap` | 应用启动时取得准入、更新、公告和开关；失败时使用本地缓存并明确降级状态 | HMAC 签名 |
| P0 | `GET /filter/keywords`、`GET /filter/domains` | 版本化缓存，供搜索结果、书源和正文的内容过滤使用 | HMAC 签名 |
| P1 | `POST /auth/login` | App 用户登录并安全保存短期会话 token | 无 |
| P1 | `GET /booksource/list` | 登录后拉取服务端启用书源，走既有解码、预览和导入用例，不直接写数据库 | Bearer token |
| P1 | `POST /booksource/stats/batch` | 本地按日聚合书源成功/失败；动态分批、两阶段补充未知书源、权限和敏感信息保护 | HMAC + Bearer token + 书源同步权限 |
| 兼容 | `POST /booksource/event` | 旧客户端逐条事件协议；Flutter 新主链不再调用 | Bearer token |
| P2 | `GET /announcements`、`GET /flags` | bootstrap 不可用或需要单独刷新时的补偿获取 | HMAC 签名 |
| P2 | `POST /analytics/batch` | 仅在用户同意分析后批量上传非敏感事件 | HMAC 签名 + Bearer token |
| 兼容 | `GET /booksource/share/:token` | 继续通过当前二维码远程 JSON 下载流程导入；不另建专用网络链路 | 公开 token |

`/app/update-check` 和 `/app/access-check` 不作为首选启动调用：它们已被 `/app/bootstrap` 聚合，仅保留为未来故障诊断或细粒度刷新能力。

## 3. 分层与文件映射

```text
App 启动 / 设置 / 书源管理 Intent
  -> 远端配置与同步 ViewModel/Coordinator
  -> Bootstrap、Filter、BookSourceSync UseCase
  -> RemoteAppServiceGateway
  -> RemoteAppServiceRepository
  -> RemoteAppApi（UnifiedHttpClient + 签名器 + DTO 解码）
  -> 本地 DAO/既有 BookSourceGateway/安全偏好存储
```

- 网络实现必须复用 `lib/src/api/http/http_contract.dart` 的 `UnifiedHttpClient`，不能向 Widget 注入 Dio 或直接 HTTP。
- 书源 JSON 必须复用 `BookSourceImportTextResolver`、`ImportBookSourcesUseCase` 和 `BookSourceGateway` 的既有校验、去重与事务语义；服务端书源不得绕过导入用例直接写 `book_sources`。
- 远端 DTO 不可穿透 UI；将响应 `{code,message,data}` 先转换为受控错误与领域结果。
- 启动配置、过滤版本、公告已读状态、开关缓存、登录 token 和待回流事件需各自有明确生命周期。token 不可记录到日志，事件队列需有上限和淘汰策略以避免无限增长。
- App 版本号使用 `pubspec.yaml` 的 build number；产品 `productId`、channel 和服务地址必须来自单一不可编辑的运行时配置，而非散落在页面常量中。

## 4. 安全与未决决策

后端对 bootstrap、过滤、公告、开关和埋点使用 `X-App-Timestamp`、`X-App-Nonce`、`X-App-Signature`，签名原文为 `method + path + timestamp + nonce + body` 的 HMAC-SHA256。将固定 HMAC 密钥放入客户端无法构成可靠秘密，反编译即可取得；因此在编码前必须确定以下一项：

1. 改为服务端可验证的设备注册/短期凭据方案；或
2. 用户明确接受当前 HMAC 仅作为滥用门槛，并规定密钥轮换和泄露处置。

还必须确认：`productId`、发布 channel、是否启用 App 用户登录、分析与书源质量上报的用户同意策略、以及访问拒绝/强制更新/离线启动的产品文案和阻断规则。

## 5. 实施顺序与验收

1. 先确定上述安全和产品配置，再建立 API 契约、签名器、统一错误模型与可取消请求。
2. 接入 bootstrap 的本地缓存与启动协调器；只显示受控的“需要更新/禁止访问/服务不可用”状态，不把业务判断放入 Widget。
3. 接入关键字、域名规则及版本化缓存，定义它们在搜索、导入和正文中的过滤位置。
4. 接入登录与服务端书源同步；要求用户确认导入，且保留本地书源。
5. 最后实现批量书源事件、公告/开关补偿刷新和经同意的分析队列。

用户验收时分别验证 Android 与 iOS：首次在线启动、离线启动、签名失败、准入拒绝、可选/强制更新、过滤缓存回退、登录失效、书源导入取消与去重、事件队列重试及隐私开关。AI 不运行构建、测试或应用。
