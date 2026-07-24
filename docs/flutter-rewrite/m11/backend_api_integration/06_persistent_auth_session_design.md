# 持久化 App 登录会话与自动恢复设计

状态：`SUPERSEDED`。该单 Token 设计已被 [`07_dual_token_session_migration_design.md`](./07_dual_token_session_migration_design.md) 替代；双 Token 实现以最新接口文档为准。AI 未运行构建、测试、分析、格式化或应用。

## 1. 目标与边界

目标：用户登录一次后，应用被系统杀死或手动结束进程再启动时，可恢复同一 App 账号，无需重新输入密码；Token 到期、被撤销、用户禁用/删除、密码重置或服务端返回 401 时，安全退出并要求重新登录。

必须遵守：

- 绝不保存明文密码、RSA 密文、公钥、完整登录响应或日志中的 Token。
- 不使用 SQLite、普通 SharedPreferences、`caches` 表或文件日志保存 Token。
- 仅将 Token、`expiresAt`、`refreshAfter` 和恢复界面所需的受控账号/权限快照写入系统安全存储。
- 用户主动退出时删除安全存储记录并清空内存会话；任何 401 同样删除。
- 网络失败或 5xx 不循环刷新；保留未过期会话并在下一次启动/前台时再尝试，避免启动风暴。

## 2. 接口事实与恢复规则

接口文档新增并明确了以下认证事实：

- `POST /api/v1/auth/login` 返回 `token`、`expiresAt`、`refreshAfter`、`user`；Token 固定有效 7 天。
- `POST /api/v1/auth/refresh` 使用未过期 Bearer Token 换取新的 7 天 Token，不需要密码和 App HMAC。
- 到达 `refreshAfter`（第 6 天）后，在启动或进入前台刷新一次；刷新成功必须原子替换本地 Token、`expiresAt` 和 `refreshAfter`。
- 刷新返回 401 时，或本地 `expiresAt` 已过期时，删除记录并回到未登录。
- 旧 Token 刷新后仍可用至原 `expiresAt`，但客户端只保留新 Token。

恢复流程：

```text
应用启动 / 进入前台
  -> 安全存储读取会话记录
  -> 无记录或 expiresAt 已过期：删除记录，未登录
  -> 先恢复内存账号和权限快照，页面立刻显示原账号
  -> now >= refreshAfter：POST /auth/refresh
       -> 成功：原子更新安全存储和内存会话，再 GET /account/permissions
       -> 401：删除安全记录和内存会话
       -> 网络/5xx：保留未过期记录，不循环重试
  -> now < refreshAfter：GET /account/permissions 校验/更新权限
       -> 401：删除安全记录和内存会话
       -> 网络/5xx：保留未过期记录
```

恢复过程不得阻塞首帧：启动后异步执行，并由现有 `ValueListenable` 推动设置页和认证页更新。进入前台时只允许一个恢复/刷新任务，避免并发覆盖最新 Token。

## 3. 存储方案

新增 `flutter_secure_storage`：Android 使用加密的 Keystore 保护存储，iOS 使用 Keychain。此依赖的职责仅限系统安全存储，不访问网络、不生成设备指纹、不保存密码。

建议的单一 JSON 记录（字段均不写日志）：

```json
{
  "token": "…",
  "expiresAt": "2026-07-30T12:00:00Z",
  "refreshAfter": "2026-07-29T12:00:00Z",
  "user": { "id": 12, "username": "reader01", "status": "active" },
  "permissions": { "userRole": "user", "canGenerateInvite": true, "canSyncBookSource": false, "inviteAvailableAt": null }
}
```

先完整写入新记录后才替换内存 Token；删除失败时仍清空内存会话，后续启动再次尝试删除。安全存储异常不得造成崩溃：登录成功但保存失败应以明确错误结束，避免给用户“已自动登录”的错误预期。

## 4. 计划修改范围

| 文件 | 计划修改 |
| --- | --- |
| `pubspec.yaml` | 已增加 `flutter_secure_storage`，仅用于会话秘密。 |
| `lib/src/data/local/secure_auth_session_store.dart` | 已新增安全会话读写、结构校验和原子替换边界。 |
| `lib/src/api/remote_app/remote_app_api.dart` | 已解码登录/刷新中的 Token 生命周期字段；新增 Bearer `POST /auth/refresh`。 |
| `lib/src/domain/gateway/authentication_gateway.dart` | 已增加启动/前台恢复入口，UI 不暴露 Token。 |
| `lib/src/data/repository/authentication_repository.dart` | 已实现登录后持久化、启动恢复、刷新策略、401 清理与并发保护。 |
| `lib/src/app/app_dependencies.dart`、`lib/src/app/legado_app.dart` | 已创建安全存储并在首帧后、前台恢复时触发非阻塞会话恢复。 |
| `lib/src/ui/settings/settings_route.dart` | 已订阅认证会话，修复登录后仍显示“本地读者”。 |
| `docs/flutter-rewrite/AI_PROJECT_INDEX.md` 与 M11 认证文档 | 已登记安全存储、恢复调用链、验收和当前状态。 |

本设计不修改数据库 Schema，不需要修改 `LegadoDatabase.schemaVersion` 或 `pubspec.yaml` 的应用 build number。

## 5. 用户验收

1. 登录成功后强制结束应用，重新打开可显示原账号并可使用受保护功能。
2. 第 6 天及之后启动，确认仅调用一次 `/auth/refresh`，并更新安全存储中的期限。
3. Token 过期或刷新/权限接口返回 401，确认自动退出且不会保留旧账号显示。
4. 无网络启动时，未过期会话可显示；网络恢复并再次进入前台后可更新权限/刷新 Token。
5. 主动退出登录后结束并重开应用，确认不再自动登录。
6. `LEGADO_HTTP`、`REMOTE_APP_API` 和文件日志中没有 Token、用户名、密码、公钥或完整认证正文。
