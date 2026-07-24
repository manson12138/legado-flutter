# 双 Token 会话迁移设计

状态：`IMPLEMENTED_PENDING_USER_VERIFICATION`。本设计以 `novel-admin-api-App-客户端-2026-07-23.json` 的双 Token 契约实现。Flutter 已完成 Access/Refresh Token 安全存储、HMAC 刷新/退出、旧会话清理及启动/前台恢复；AI 未运行构建、测试、分析、格式化或应用。

## 1. 当前差异

Flutter 当前实现只安全保存一个 7 天 Access Token，并错误地把它作为 `POST /api/v1/auth/refresh` 的 Bearer Token。新接口已切换为双 Token：

- Access Token 有效期 7 天，供权限、书源、邀请码、埋点等 Bearer 接口使用。
- Refresh Token 有效期 30 天，只能用于刷新与退出；原文只在登录/刷新响应中返回一次。
- 刷新接口需要 App HMAC 签名，不使用 Bearer；正文是 `{"refreshToken":"…"}`。
- 成功刷新会轮换整套 Token，旧 Refresh Token 立即不可再用；同一时刻不能并发刷新。
- 原 Refresh Token 再次使用会撤销同一 family，返回 401；客户端绝不能在刷新超时/网络失败后并发或重放第二个请求。

因此，已有的单 Token 安全记录无法升级为双 Token 会话；接口文档也明确说明旧会话没有 Refresh Token，升级后必须让用户重新登录一次。

## 2. 迁移与恢复规则

```text
安全存储读取会话
  -> 缺少 refreshToken / refreshExpiresAt（旧单 Token 记录）
       -> 删除记录，显示未登录，要求一次重新登录
  -> refreshExpiresAt 已过期
       -> 删除记录，显示未登录
  -> accessExpiresAt 已过期，或 now >= refreshAfter
       -> 串行 POST /auth/refresh（HMAC + refreshToken JSON）
            成功：原子替换 accessToken、refreshToken、全部期限与 user
            网络/5xx：保留原 Refresh Token，等待后续启动/前台退避重试
            401：删除记录，显示未登录
  -> Access Token 尚未到刷新时刻
       -> 恢复账号与权限快照；按既有权限校验策略更新
```

用户主动退出时，客户端先尽力调用 `POST /api/v1/auth/logout`（HMAC + 当前 Refresh Token），随后无论请求结果如何都删除本地两个 Token 和期限。退出接口幂等，不能因网络失败保留登录态。

## 3. 安全与并发要求

- `accessToken`、`refreshToken`、所有期限和账号/权限快照继续只保存在 Android Keystore / iOS Keychain；不写 SQLite、普通偏好、文件、崩溃报告或日志。
- 单个安全存储 JSON 记录一次性替换全套字段；刷新成功前绝不写入部分新值。
- `AuthenticationRepository` 维护单一 refresh Future。启动恢复、前台恢复和任何 Access Token 已过期的受保护动作均复用它，禁止并发刷新。
- 网络/5xx 不自动紧密循环；本次失败后记录内存中的下一次允许尝试时间，后续启动/前台再试。401 清除会话。
- 用户资料和权限只能使用刷新响应或权限接口更新，禁止从旧 Access Token 推导。

## 4. 计划改动

| 文件 | 计划改动 |
| --- | --- |
| `lib/src/data/local/secure_auth_session_store.dart` | 已升级为 `accessToken/accessExpiresAt/refreshToken/refreshExpiresAt/refreshAfter`；读到旧记录即安全删除。 |
| `lib/src/api/remote_app/remote_app_api.dart` | 已严格要求新字段；刷新改为 HMAC JSON POST；已新增幂等 HMAC 登出。 |
| `lib/src/data/repository/authentication_repository.dart` | 已实现 Access/Refresh 双 Token 生命周期、单飞恢复、30 天恢复、401 清理与远端退出。 |
| `lib/src/domain/gateway/authentication_gateway.dart` | UI 继续不接触 Token。 |
| `lib/src/app/remote_book_source_sync_service.dart`、崩溃上传配置 | 继续仅消费当前 Access Token；启动/前台在 Access 过期时由认证仓储刷新。 |
| `docs/flutter-rewrite/m11/backend_api_integration/02_authentication_and_api_gap_plan.md`、`06_persistent_auth_session_design.md` | 已替换单 Token 描述，登记旧会话必须重新登录的迁移规则。 |

不改数据库 Schema，不需要调整 `LegadoDatabase.schemaVersion` 或应用 build number。

## 5. 用户验收

1. 升级前的单 Token 会话启动后被安全清除，并提示重新登录一次。
2. 新登录后杀死 App，再启动可从 Keychain/Keystore 恢复；Access 过期但 Refresh 未过期时可刷新成功。
3. 网络失败后不重复消费同一 Refresh Token；恢复网络后下一次前台/启动能重试。
4. 刷新接口 401、Refresh Token 到期、账号被禁用/密码重置后，均自动退出并删除本地记录。
5. 主动退出会调用服务端撤销并始终清除本地记录。
6. 日志、文件、数据库与崩溃报告中均不存在 Access Token 或 Refresh Token。
