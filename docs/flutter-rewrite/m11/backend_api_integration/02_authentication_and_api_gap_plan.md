# App 用户认证与 API 缺口盘点

状态：`IN_PROGRESS`。本文件基于 `C:/Users/s8534/Downloads/novel-admin-api-all-2026-07-23.json` 于 2026-07-23 的静态盘点结果编写。注册、登录、权限、邀请码和设置入口已写入 Flutter；Access Token 与 Refresh Token 仅存于 Android Keystore/iOS Keychain，启动或回到前台时按 `refreshAfter` 以 HMAC 请求刷新，服务端 401 或主动退出时删除整个会话。旧单 Token 本地记录不能迁移，升级后必须重新登录一次。认证接口正文已禁止写入网络日志。真实后端登录/刷新响应须返回 `accessToken + accessExpiresAt + refreshAfter + refreshToken + refreshExpiresAt + user`，等待 Android 后 iOS 用户验收；AI 未运行构建、测试或检查。

书源管理页的服务器同步入口只在当前 App 会话存在且 `canSyncBookSource=true` 时展示；点击后直接复用当前 Access Token 拉取分页书源，不再出现第二套账号密码输入框。未登录或无同步权限时入口不渲染，服务端仍以 403 作为最终权限判定。

## 1. 唯一目标与边界

目标：在既有远端 App 服务接入上补齐“邀请码注册、账号登录、登录态展示、邀请码获取及账号权限读取”这一独立 Feature，并记录当前导出 API 与 Flutter 客户端实现之间的契约缺口。

本 Feature 包含：

- 公开的登录与邀请码注册；注册成功后回到登录，不假定后端自动签发 token。
- 内存会话的当前用户和权限快照；应用重启后登录态失效，与现有 token 生命周期一致。
- 已登录用户按权限获取邀请码，并展示有效期和不可生成原因。
- 用账号权限决定书源同步入口是否可用；服务端 403 仍须作为最终判定。
- 设置页的认证入口、受控状态、错误和退出登录行为。

明确不包含：管理员 `/api/admin/*`、密码找回/修改、第三方登录、注册后自动登录、长期 token 持久化、账户资料编辑、服务端接口变更，以及把 App 管理员的过滤列表上传能力暴露给普通用户。

## 2. API 覆盖结论

| API | 当前 Flutter 状态 | 本 Feature 处理 |
| --- | --- | --- |
| `POST /api/v1/auth/login` | 已有 `RemoteAppApi.login`，但仅由书源同步服务调用，未形成认证 UI/领域会话 | 改为认证仓库统一拥有会话；同步服务只消费会话和权限 |
| `POST /api/v1/auth/register` | 未接入 | 新增受控 DTO、注册用例和注册页 |
| `POST /api/v1/invitations` | 未接入 | 登录后按 `canGenerateInvite` 调用并展示邀请码/过期时间 |
| `GET /api/v1/account/permissions` | 未接入 | 登录成功、进入账户页和书源同步前刷新；只缓存本次内存会话 |
| `GET /api/v1/app/access-check` | 未单独接入 | 暂不接入；`bootstrap` 已聚合准入结果，保留为将来诊断接口 |
| `GET /api/v1/booksource/page` | 已接入 | 在请求前用权限快照改善 UI，不能以本地快照绕过服务端 403 |
| `GET /api/v1/booksource/list` | 未接入 | 不接入；新客户端已使用分页接口，保留作旧客户端兼容接口 |
| `POST /api/v1/filter/upload` | 未接入 | 不纳入本 Feature；若后续需要，必须另做“App 管理员内容配置”权限 UI |

导出文件中的全部 `/api/admin/*` 均为管理端接口，不属于 Flutter 阅读 App 的接入范围，当前不应接入。

## 3. 已发现的后端契约差异

现有 `RemoteAppApi` 还会调用以下接口，但它们不在本次导出的 API 清单中：

- `GET /api/v1/filter/domains`
- `GET /api/v1/flags`
- `POST /api/v1/booksource/event`

其中前两项在导出文件的 `related` 字段中被引用，书源事件则完全没有出现。实施认证前不阻塞；但在继续维护启动过滤、功能开关和书源质量回流前，后端需要确认这三个路由仍存在、认证方式和请求/响应结构未变，并将其补入接口导出。否则客户端当前这些调用会在真实环境中失败。

另有两个配置不一致必须在编码前解决：

- `bootstrap` 和 `access-check` 要求 `versionName`，现有客户端仅发送 `versionCode`；应从 `pubspec.yaml` 的版本名前半段集中提供 `versionName`。
- 后端 `versionCode` 示例为 `20300`，现有配置默认值已随 Schema v8 构建升为 `6`；必须确认服务端的比较规则和 Flutter 的构建号映射，不能擅自转换。

## 4. 目标分层和状态

```text
设置页认证入口 / 书源同步入口
  -> AuthenticationViewModel
  -> Login、Register、LoadAccountPermissions、GenerateInvitation UseCase
  -> AuthenticationGateway
  -> AuthenticationRepository
  -> RemoteAppApi（统一信封解码、Bearer 请求）
```

领域状态应为不可变的 `AuthenticationState`：未登录、提交中、已登录（用户、权限、邀请码可选）、失败。密码和 token 只在请求/内存会话中短暂存在，绝不写入日志、路由参数、数据库或偏好缓存。页面销毁时取消可取消请求或忽略过期结果，避免已释放页面收到异步状态更新。

登录表单至少校验非空账号和密码；注册额外校验邀请码非空及两次密码一致。长度、字符集和密码强度以服务端错误为准，客户端不能伪造未在 API 契约中定义的限制。所有服务端错误统一映射为可展示的受控文案，401/403 要清除内存会话并回到未登录态。

## 5. 文件映射与实现顺序

1. 已扩展 `api/remote_app/remote_app_api.dart`：注册、权限和邀请码均使用受控 DTO 与统一响应信封处理。
2. 已新增认证 Gateway、Repository 和 ViewModel，集中管理内存会话与退出登录；`RemoteBookSourceSyncService` 现复用该会话，不再持有自己的 token。
3. 已新增认证 Route，并从设置页资料区接入；UI 只渲染状态和发送用户操作。
4. 书源同步仍由服务端实时判定权限；下一轮可根据权限快照进一步优化书源管理页入口文案。
5. 已更新 API 接入方案和 AI 索引；待用户分别验证 Android 与 iOS。

若新增文件，均须使用中文职责注释；不新增数据库表或字段，因此不需要变更 `LegadoDatabase.schemaVersion` 或 `pubspec.yaml` build number。

## 6. 用户验收清单

- 未注册用户使用有效/无效/过期邀请码注册，确认不会自动泄露密码或 token。
- 已注册用户登录成功、登录失败、网络失败与页面返回后的状态正确。
- 重启应用后必须重新登录；退出登录后书源同步入口回到未登录状态。
- 有/无邀请码生成权限、24 小时冷却期、重复请求同一邀请码、失效邀请码均有明确反馈。
- 有/无书源同步权限时的入口与服务端 403 行为一致。
- Android 验收后再进行 iOS 验收；AI 不运行构建、测试、分析或应用。
