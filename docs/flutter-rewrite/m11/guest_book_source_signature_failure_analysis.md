# 游客邀请码拉取书源签名失败分析

状态：`ANALYZED_PENDING_EXECUTION`

日期：2026-07-28

本文件仅基于 Flutter 仓库、当前构建脚本和本机只读可见的后端参考源码做静态分析。
本轮未修改业务代码，未运行构建、测试、分析、格式化或应用。

## 1. 用户反馈与本次目标

用户在未登录游客状态下，通过“书源管理 → 更多 → 输入 URL 或邀请码”输入管理员邀请码，
应用提示：

```text
应用签名或设备时间校验失败
```

本次分析的唯一目标是定位该提示出现的请求阶段、确认客户端签名实现与构建配置，并给出后续
修复范围。

本次不包含：

- 不修改邀请码、游客 Token、分页或书源导入业务；
- 不修改数据库 Schema、用户作用域或登录会话；
- 不修改后端仓库或 Android 参考仓库；
- 不记录或输出 HMAC 原值、邀请码、Token、nonce、签名及书源正文；
- 不运行代码和检查命令。

## 2. 已确认调用链

当前失败发生在游客邀请码兑换会话阶段：

```text
BookSourceRoute
  -> GuestBookSourceImportService.submit
  -> GuestBookSourceImportService._syncWithInvitation
  -> RemoteAppApi.createGuestBookSourceSession
  -> POST /api/v1/booksource/guest/session
  -> HTTP 401
  -> GuestBookSourceImportFailureKind.signatureRejected
  -> “应用签名或设备时间校验失败”
```

此时尚未取得 `guestToken`，因此也尚未进入：

- `GET /api/v1/booksource/guest/page`；
- 游标分页；
- 书源 JSON 解码；
- 本地书源事务导入。

邀请码无效、过期或不存在按当前映射应为 HTTP 400、404 或 410，不会显示本次 401 提示。

## 3. 客户端与后端签名算法核对

Flutter 对游客会话请求使用：

```text
HMAC-SHA256(
  secret,
  "POST" + "/api/v1/booksource/guest/session" + timestamp + nonce + rawBody
)
```

其中：

- `timestamp` 为设备当前 Unix 秒；
- `nonce` 每次使用安全随机数重新生成；
- `rawBody` 与实际发送的 JSON 字符串是同一个变量；
- 签名输出为小写十六进制；
- URL 查询参数不参与 path canonical。

本机只读可见的后端参考中间件使用相同 canonical：

```text
method + request.URL.Path + timestamp + nonce + body
```

并允许客户端与服务端时间最多相差五分钟。根据当前源码，未发现游客 session 请求的
method、path、body 或 HMAC 编码方式不一致，因此不建议改动签名算法。

## 4. 已确认的构建配置问题

### 4.1 当前统一配置仍为开发占位值

根目录 `app_build_secrets.json` 已配置 `REMOTE_APP_HMAC_SECRET`，但其值仍等于 Dart
后备开发占位值：

```text
dev-app-signature-change-me
```

如果已部署后端通过 `APP_SIGNATURE_SECRET` 覆盖了后端默认值，则当前安装包计算出的所有
App HMAC 都会与服务端不一致，游客会话请求必然返回 401。

### 4.2 各构建入口的实际行为

| 构建入口 | HMAC 来源 | 当前结果 |
| --- | --- | --- |
| `build_apk.bat` | `--dart-define-from-file=app_build_secrets.json` | 注入开发占位值 |
| `build_install_run.bat` | 同上 | 注入开发占位值 |
| `build_install_run.sh` | 同上 | 注入开发占位值 |
| iOS Xcode Build Phase | `encode_app_build_secrets.dart` 读取同一文件并写入 `DART_DEFINES` | 注入开发占位值 |
| 直接 `flutter run/build` 或 IDE 默认运行 | 没有额外参数时使用 Dart `defaultValue` | 使用同一开发占位值 |

因此当前所有常见构建入口最终都会使用该占位值；构建脚本是否传参不会改变本次结果。

### 4.3 配置文件当前被 Git 跟踪

`app_build_secrets.json` 当前是已跟踪文件，且 `.gitignore` 没有排除它。项目规则禁止把真实
密钥或认证配置提交到仓库，因此不能直接把部署环境的真实 HMAC 值写入该已跟踪文件后交付。

虽然现有设计已明确客户端 HMAC 只能作为防滥用门槛、不能视为可靠机密，构建配置仍应避免
出现在日志、提交记录和交付说明中。

## 5. 根因优先级

### P0：安装包与部署后端使用的 HMAC 配置不一致

这是当前最可能的原因。客户端已确认使用开发占位值；仍需在部署环境中只做“是否一致”的
比较，不能复制、打印或写日志输出真实值。

### P1：手机设备时间与服务端相差超过五分钟

后端参考实现直接使用 `time.Now()` 与客户端 Unix 秒比较，允许窗口为正负五分钟。若部署
后端仍使用相同开发默认 HMAC，手机未开启自动日期和时间就成为首要检查项。

时区设置本身不会改变 Unix 时间戳；真正影响校验的是设备绝对时间错误。

### P2：后端部署版本与本地参考源码不一致

当前本机 `novel-admin-platform` 参考源码包含 App HMAC 中间件，但静态搜索没有找到
`/api/v1/booksource/guest/session` 和 `/api/v1/booksource/guest/page` 的路由实现。Flutter
方案与实际部署显然依赖更新的后端接口版本。

这不直接解释当前 401，因为 401 已经表明请求进入了签名校验边界，但后续修复和验收必须以
实际部署版本或对应后端源码为准，不能只依据当前本机旧快照宣称端到端通过。

## 6. 当前错误反馈的诊断边界

后端参考中间件对以下场景都返回 HTTP 401 和同一个通用业务码：

- timestamp 非法或超过五分钟；
- nonce 或签名缺失；
- HMAC 不匹配。

Flutter 出于安全考虑不展示任意服务端 message，并把兑换阶段所有 401 统一映射为：

```text
应用签名或设备时间校验失败
```

因此仅凭页面提示不能进一步区分“密钥不一致”和“设备时间错误”。这不是邀请码校验错误，
也不是书源分页或本地导入错误。

## 7. 建议执行方案

### 7.1 先完成不泄露密钥的运行环境确认

1. 在部署端确认 `APP_SIGNATURE_SECRET` 是否被环境变量覆盖。
2. 在构建端确认将要注入的 `REMOTE_APP_HMAC_SECRET` 与部署值一致，只输出布尔比较结果。
3. 在手机开启“自动设置日期和时间”，确认与可信网络时间相差不超过五分钟。
4. 确认测试安装包来自统一构建入口，而不是未携带 Dart define 的旧 APK。

### 7.2 Flutter 仓库建议修改

1. 将真实构建配置迁移到未跟踪的本地文件，例如
   `app_build_secrets.local.json`。
2. 将当前已跟踪文件改为不含真实值的示例文件，并在 `.gitignore` 排除本地配置。
3. 统一调整 Android 批处理、Shell 和 iOS Xcode Build Phase，使它们都读取同一个本地配置。
4. 构建辅助脚本在配置缺失、空值或仍为开发占位值时提前失败，避免产出必然验签失败的安装包；
   错误只说明配置类别，不输出原值。
5. 对未经过项目构建入口的 IDE/命令行运行，在文档中明确要求
   `--dart-define-from-file`，避免静默回落到占位值。
6. 保持当前 HMAC canonical、游客内存凭证、分页和事务导入逻辑不变。

如果开发环境确实有意让前后端共同使用默认占位值，应明确提供仅限本地开发的开关；发布构建
仍应拒绝占位值。

### 7.3 后端建议，但不纳入本仓库修改

后端可为“时间戳错误、签名缺失、签名不匹配”提供不同且稳定的机器业务码。Flutter 只根据
业务码做受控分类，不解析任意展示文案，也不记录请求签名材料。

## 8. 性能、内存与数据影响

建议修复只调整构建配置入口和错误前置保护：

- 不增加常驻对象、Timer、Stream 或后台任务；
- 不增加网络重试，避免错误签名触发限流；
- 不持久化邀请码、`guestToken`、HMAC 或时间偏移；
- 不改变书源分页每批 50 条和逐批释放的内存边界；
- 不修改 SQLite 或 MMKV，因此不涉及 Schema/version build number 联动。

## 9. 用户后续验收

执行修复后由用户运行：

1. 使用正确本地配置重新构建并覆盖安装。
2. 手机开启自动日期和时间，输入有效管理员邀请码。
3. 确认 session 兑换成功并开始显示游客书源分页进度。
4. 使用无效或过期邀请码，确认提示“邀请码无效或已过期”，不再误报签名问题。
5. 故意使用错误 HMAC 的隔离构建，确认构建入口提前拒绝产包，且日志不出现配置原值。
6. 检查日志、SQLite、缓存、安全存储和崩溃报告中不存在邀请码、Token、nonce、签名或 HMAC。

在用户提供真实运行结果前，本问题保持 `ANALYZED_PENDING_EXECUTION`，不能宣称已修复。
