# 认证 RSA-OAEP 密码传输改造设计

状态：`IN_PROGRESS`。后端已要求登录和邀请码注册在提交前以 RSA-OAEP-SHA256 加密密码。本方案替换现有明文 `password` 请求字段，不改变账号 UI、邀请码、权限、内存 Token 或“注册后不自动登录”的业务语义；代码已实现，等待用户完成 Android 与 iOS 互通验收。

## 逻辑复核（2026-07-23）

当前 Flutter 代码已经具备以下主链路：`RemoteAppApi.fetchPasswordKey` 校验算法、摘要、`keyId` 和 PEM；`AuthenticationRepository` 仅以内存缓存公钥；Android 使用显式 `OAEPParameterSpec(SHA-256, MGF1/SHA-256, empty label)`；iOS 使用 `SecKeyAlgorithm.rsaEncryptionOAEPSHA256`；登录和注册请求均只提交 `passwordEncrypted`。现有 HTTP 日志脱敏规则也会遮盖 `password` 和 `passwordEncrypted` 字段。

现有实现已补齐以下安全边界：

1. `AuthenticationRepository` 对后端明确配置的密钥失效业务码清除匹配 `keyId` 的内存公钥、重新取钥、重新加密并仅重试一次；第二次失败不重试。
2. `RemoteAppApi._executeEnvelope` 将非零业务 `code` 保留为不含响应正文的受控异常，认证仓储仅按配置的业务码决定重试。
3. 缓存只保留当前可用公钥，但失效时会按生成密文的 `keyId` 精确清除，旧密文不缓存也不复用。

实施前必须由后端明确“密钥失效类错误”的稳定机器可识别标识（推荐业务 `code`，或约定的 HTTP 状态和错误码字段）。客户端通过 `REMOTE_APP_PASSWORD_KEY_INVALID_CODES`（逗号分隔的整数 `dart-define`）配置允许重试的业务码；默认空集合，不能依据展示文案、HTTP 5xx、网络失败、用户名/密码错误、邀请码错误或任意非零业务码触发重试。

## 补充实施方案

1. 为远端 App 响应增加不包含请求体、密文或密码的受控业务错误类型，保留 HTTP 状态、业务 `code` 和安全展示文案；非零业务 `code` 不再伪装为解码失败。
2. 在认证仓储将“取钥→加密→登录/注册”封装为单次提交流程。首次请求仅在错误类型与后端约定的密钥失效标识匹配时，清除内存中匹配 `keyId` 的公钥，重新获取公钥、重新加密当前提交的明文，并重试一次；第二次失败直接向 UI 返回受控错误。
3. 网络失败、超时、用户名或密码错误、邀请码错误、加密失败、算法/PEM 校验失败及未知服务端错误均不自动重试。加密失败统一展示“密码安全处理失败，请重试”。
4. 明文密码只在本次 `login`/`register` 调用栈和原生 MethodChannel 参数中短暂存在；旧密文不得缓存或再次发送。公钥只保存在进程内，退出登录时无需影响其他未完成提交，但应用进程结束必须自然释放。
5. 用户验收增加：使用同一测试密码分别验证 Android、iOS 与后端互通；随后模拟一次约定的密钥失效码，确认每个登录/注册提交恰好重新取钥并重试一次，以及抓包中始终没有 `password` 字段或明文。

## 已确认契约

1. 登录或注册前调用公开接口 `GET /api/v1/auth/password-key`。
2. 响应必须是 `algorithm=RSA-OAEP`、`hash=SHA-256`、非空 `keyId` 与 PEM `publicKey`。
3. 登录和注册只发送 `passwordEncrypted=Base64(RSA-OAEP-SHA256(UTF8(password)))`，禁止发送 `password`。

## 实现边界

```text
AuthenticationViewModel
  -> AuthenticationRepository
  -> PasswordEncryptionService
  -> RemoteAppApi.fetchPasswordKey + login/register
```

经实现前复核，不采用 `pointycastle`：其当前 OAEP 文档明确标注与 RFC 3447/RFC 8017 的 OAEP v2.1+ 不兼容，而后端要求与 Web 完全一致，不能以未验证的密码学兼容性冒险。改用最小 MethodChannel 平台桥：Android 使用 `Cipher` 加明确的 `OAEPParameterSpec(SHA-256, MGF1/SHA-256, empty label)`；iOS 使用 `SecKeyCreateEncryptedData` 的 `rsaEncryptionOAEPSHA256`。Dart 的 `PasswordEncryptionService` 只定义受控请求/响应，Android 与 iOS 均复用系统实现，不新增第三方密码学依赖或包体。

公钥可仅按 `keyId` 在内存缓存 5 分钟；密码、UTF-8 字节、密文和 Token 均不得写入日志、数据库、缓存、路由参数或 UI 状态。OAEP 主摘要、MGF1 摘要都必须固定为 SHA-256，标签为空；不得降级为 OAEP-SHA1 或 PKCS#1 v1.5。Android/iOS 桥接必须把 PEM 解码、算法不匹配、密钥格式无效和加密失败映射为受控错误，不向 Dart 返回原生异常正文。

PEM、算法、hash、keyId 或密文长度不合法时，客户端中止请求并只显示“加密准备失败”。网络失败不自动重发包含密码的请求，用户需重新提交。

## 修改范围与验收

修改 `android/app/src/main/kotlin/.../MainActivity.kt`、`ios/Runner/AppDelegate.swift`、`platform/`、`api/remote_app/remote_app_api.dart`、认证 Repository/组合根和认证专项文档；新增受控公钥 DTO、平台加密服务与 MethodChannel 协议。不会改 `pubspec.yaml` 或数据库 Schema。

验收：有效登录、有效邀请码注册、错误密码、失效邀请码、无效 PEM、算法不匹配和网络失败；抓包确认请求中无 `password` 字段或密码明文，仅存在 `passwordEncrypted`。先验收 Android，再验收 iOS；AI 不运行构建、测试或分析。
