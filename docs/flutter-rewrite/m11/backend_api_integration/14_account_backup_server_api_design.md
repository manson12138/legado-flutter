# 登录账号备份服务端接口与存储设计

状态：`IMPLEMENTED_PENDING_VERIFICATION / 服务端 API v2 契约已提供，Flutter 备份与恢复逻辑已写入，等待用户运行和后续 UI 接线`。

本轮客户端实现以用户提供的 `novel-admin-api-App-客户端-账号备份-2026-08-04.json`
（导出时间 `2026-08-04T05:46:18.508Z`）为当前服务端事实源；本文中与该 JSON 不同的早期建议均以实际
API 为准。

截至 2026-08-04，Flutter 已完成以下客户端前置工作：

- Schema v12 为书签、正文标注和替换规则补齐 `userId` 作用域，无法确认归属的旧数据保留在游客作用域；
- 只允许当前登录账号生成版本化 `.pnbak` ZIP 文件，游客不参与账号备份；
- 已导出书架、书架分组、阅读历史、书签、正文标注、替换规则和白名单小型设置；
- 已排除本地书、章节正文、缓存、下载队列、Cookie、Token、书源和书源运行变量；
- 已生成 `manifest.json`、逐文件 SHA-256、最终文件 SHA-256、字节数和客户端幂等 ID；
- 已接入初始化、应用服务器流式 PUT、完成确认、分页、latest、短期下载和幂等删除；
- 已实现下载文件大小/SHA-256、ZIP 文件白名单、逐文件 SHA-256、格式版本和账号归属校验；
- 已实现当前账号 SQLite 数据的替换式恢复事务，并在提交后失效书架首快照和处理后正文缓存；
- 上传能力已经切换为 `available`，本轮不新增 UI，仍等待用户运行验证和后续页面接线。

对应客户端入口为 `AccountBackupGateway`、`AccountBackupArtifact`、
`AccountBackupRepository` 和 `AppDependencies.accountBackupGateway`。服务端完成本设计的接口并提供
联调环境可用后，可直接由 ViewModel 调用上传、列表、下载恢复和删除能力；用户入口仍需后续页面专项接线。

本文定义 PageNest 使用登录账号保存和恢复备份文件时，服务端需要增加的接口、元数据表、对象存储流程、
认证授权、幂等、校验、配额、版本保留和清理规则。本文只定义“版本化备份快照”，不把它描述为实时、
逐条、双向数据同步。

## 1. 目标与非目标

### 1.1 目标

- Flutter 客户端把当前登录账号的可备份业务数据导出为一个逻辑备份文件。
- 服务端把文件作为不透明对象保存，并把备份元数据严格归属到当前 Bearer Token 对应的用户和产品。
- 用户可以列出、下载和删除自己的备份，并能取得最新一份可恢复备份。
- 上传必须支持断网重试、请求幂等、文件大小和 SHA-256 校验，不能把半成品暴露为可恢复备份。
- 服务端保留有限历史版本并执行用户级容量限制，避免备份无限增长。
- Android 和 iOS 使用同一份备份格式和同一组服务端接口。

### 1.2 非目标

- 不提供阅读进度秒级实时同步。
- 不在服务端解析、合并或修改书架、书签、标注等业务 JSON。
- 不上传整个 SQLite 数据库、MMKV 文件、Keychain/Keystore 数据或 App 沙盒目录。
- 不备份正文、漫画图片、目录刷新检查点、下载队列、日志、崩溃报告和埋点队列。
- 不把游客 `userId=-1` 的本地数据自动归属给登录账号。
- 不在首版备份本地书原文件；未来如增加，必须单独提高文件上限、配额和版权提示。

## 2. 总体方案

客户端先生成逻辑备份文件，服务端只负责可靠保存：

```text
Flutter 当前登录账号
  -> 导出当前用户可备份数据
  -> 生成 backup-v1.pnbak 临时文件
  -> 计算 byteSize + SHA-256
  -> 初始化上传
  -> 上传二进制对象
  -> 完成上传并校验
  -> 服务端将备份状态原子切换为 READY
```

建议备份文件扩展名使用 `.pnbak`，MIME 使用 `application/octet-stream`。首版内部可以是 ZIP，但服务端
不得依赖 ZIP 目录结构，不得解压用户文件；备份格式升级由客户端的 `formatVersion` 负责。

服务端必须在数据库之外使用对象存储或受控文件存储保存二进制内容。数据库只保存元数据、状态、归属和
对象键，禁止将完整备份二进制直接写入普通业务表的 BLOB 字段。

## 3. 首版容量与保留建议

以下数值是首版建议，部署时允许通过服务端配置调整，但接口响应必须返回实际限制：

| 项目 | 建议值 |
| --- | --- |
| 单个备份文件上限 | 20 MiB |
| 单用户总备份容量 | 100 MiB |
| 单用户保留版本数 | 最近 5 份 `READY` 备份 |
| 上传会话有效期 | 30 分钟 |
| 下载地址有效期 | 5 分钟 |
| 未完成对象清理时间 | 上传会话过期后 1 小时内 |
| 删除对象最终清理时间 | 24 小时内 |
| 初始化上传限流 | 每用户每小时 10 次 |
| 下载限流 | 每用户每小时 30 次 |

服务端应优先同时执行“版本数上限”和“总容量上限”。新备份完成后，从最旧的非锁定版本开始清理；清理
旧版本失败不能回滚刚刚校验成功的新备份，但必须记录后台重试任务。

## 4. 认证、签名与用户归属

全部备份控制接口必须同时要求：

- `Authorization: Bearer <accessToken>`；
- `X-App-Timestamp`；
- `X-App-Nonce`；
- `X-App-Signature`。

控制接口继续沿用当前 App API 的 HMAC-SHA256 规则：

```text
method + path + timestamp + nonce + body
```

HMAC 只作为客户端滥用门槛，真正的用户身份和数据授权必须来自 Bearer Token。服务端从 Token 会话取得
`userId`，从受控 App 配置取得 `productId`，不得相信请求正文、文件清单或备份内容中的用户 ID。

实际 API v2 使用应用服务器一次性上传地址。二进制 PUT 必须同时携带 Bearer Token 和初始化响应中的
`X-Upload-Token`，不携带 App HMAC。客户端只接受与 App API 配置同源的上传地址，避免 Bearer Token
被服务端异常响应导向第三方主机。下载短期地址不携带 Bearer；HTTPS 地址允许进入受控存储域，HTTP 地址
仍只允许当前 App API 主机。

所有列表、详情、下载和删除查询都必须同时带上：

```text
product_id = 当前产品
user_id = 当前登录用户
backup_id = 请求中的备份 ID
```

不能先按 `backup_id` 查出对象再在业务层补用户判断。访问其他用户的备份统一返回不存在，禁止泄漏资源
是否真实存在。

## 5. 统一响应信封

实际 API v2 的控制接口和应用服务器二进制 PUT 响应都使用现有响应格式；只有 PUT 请求正文是原始字节：

```json
{
  "code": 0,
  "message": "ok",
  "data": {}
}
```

HTTP 状态表达协议层结果，`code` 表达稳定业务结果。服务端不得把数据库异常、对象键、磁盘路径、SDK
错误堆栈或内部存储地址直接放进 `message`。

## 6. 必须增加的接口

### 6.1 初始化上传

```http
POST /api/v1/backups/uploads
Authorization: Bearer <accessToken>
Content-Type: application/json
X-App-Timestamp: ...
X-App-Nonce: ...
X-App-Signature: ...
```

请求：

```json
{
  "clientBackupId": "018f3f4a-b0b9-7b2a-a321-1f785ab2de32",
  "formatVersion": 1,
  "appVersionName": "1.0.1",
  "appVersionCode": 13,
  "databaseSchemaVersion": 12,
  "platform": "ios",
  "createdAt": "2026-08-04T12:30:00.000Z",
  "byteSize": 483920,
  "sha256": "a64f...64位小写十六进制摘要",
  "containsLocalBookFiles": false,
  "itemCounts": {
    "books": 18,
    "bookGroups": 4,
    "readingHistory": 32,
    "bookmarks": 7,
    "annotations": 11,
    "replaceRules": 5
  }
}
```

约束：

- `clientBackupId` 必须是客户端在生成文件前创建的 UUID，作为上传重试幂等键。
- `formatVersion` 首版只接受 `1`，不支持的版本返回明确错误。
- `byteSize` 必须为正数且不超过服务端当前单文件上限。
- `sha256` 必须是 64 位小写十六进制字符串。
- `createdAt` 只用于展示，不能参与授权、保留顺序或配额判断；服务端时间才是最终事实。
- `platform` 只接受当前发布支持的稳定枚举，不上传设备型号、设备名称或系统唯一标识。
- `itemCounts` 只用于列表摘要和诊断，不作为服务端解析备份内容的依据。
- `containsLocalBookFiles=true` 在首版固定拒绝，避免客户端绕过容量和产品边界。

成功响应：

```json
{
  "code": 0,
  "message": "ok",
  "data": {
    "uploadId": "019b0ee8-4fd9-75a2-8fa2-669c6b11eb41",
    "backupId": "019b0ee8-5012-7923-8d98-8ef6f0f8a91a",
    "state": "UPLOADING",
    "uploadMethod": "PUT",
    "uploadUrl": "https://server/api/v1/backups/uploads/.../content",
    "uploadHeaders": {
      "Content-Type": "application/octet-stream",
      "X-Upload-Token": "一次性凭据"
    },
    "expiresAt": "2026-08-04T13:00:00.000Z",
    "maximumByteSize": 20971520,
    "userQuotaBytes": 104857600,
    "retainedVersionLimit": 5
  }
}
```

幂等要求：同一 `productId + userId + clientBackupId` 重试时：

- 已是 `READY`：返回已有 `backupId`、`state=READY`，不创建新对象；
- 仍是未过期 `UPLOADING`：返回同一会话或签发同一对象键的新短期 URL；
- 会话已过期且未完成：允许重置上传会话，但继续使用同一 `backupId`；
- 元数据中的 SHA-256 或大小与首次请求不同：返回幂等冲突，不覆盖原会话。

### 6.2 上传二进制

客户端按初始化响应执行：

```http
PUT <uploadUrl>
Authorization: Bearer <accessToken>
X-Upload-Token: <初始化响应中的一次性凭据>
Content-Type: application/octet-stream
Content-Length: 483920

<原始 .pnbak 文件字节>
```

对象键必须完全由服务端生成，建议形如：

```text
backups/{productId}/{userIdHash}/{backupId}.pnbak
```

不得把用户名、客户端文件名、设备名或请求中的路径拼进对象键。对象存储桶必须为私有，禁止公开读和目录
列举。上传 URL 只能写入一个确定对象，不能允许覆盖其他对象键。

如果使用服务器本地磁盘：

- 先写入专用临时目录；
- 限制实际读取字节数，不能只相信 `Content-Length`；
- 写入过程中同步计算 SHA-256；
- 完成确认前不得移动到正式目录；
- 正式文件名只使用服务端生成的 ID；
- 临时目录和正式目录都不能位于静态 Web 根目录。

### 6.3 完成上传

```http
POST /api/v1/backups/uploads/{uploadId}/complete
Authorization: Bearer <accessToken>
Content-Type: application/json
X-App-Timestamp: ...
X-App-Nonce: ...
X-App-Signature: ...
```

请求：

```json
{
  "clientBackupId": "018f3f4a-b0b9-7b2a-a321-1f785ab2de32",
  "byteSize": 483920,
  "sha256": "a64f...64位小写十六进制摘要"
}
```

服务端必须：

1. 按当前产品、当前用户和 `uploadId` 查询未过期会话；
2. 从对象存储 HEAD 或本地临时文件读取真实大小；
3. 校验真实大小与初始化元数据一致；
4. 校验对象 SHA-256；对象存储只提供 ETag 时不能把 ETag 当作 SHA-256；
5. 在数据库事务中把备份从 `UPLOADING` 切换为 `READY`；
6. 记录服务端 `completedAt`；
7. 提交后台版本保留和容量清理任务；
8. 返回最终备份元数据。

成功响应：

```json
{
  "code": 0,
  "message": "ok",
  "data": {
    "backupId": "019b0ee8-5012-7923-8d98-8ef6f0f8a91a",
    "state": "READY",
    "formatVersion": 1,
    "byteSize": 483920,
    "sha256": "a64f...",
    "createdAt": "2026-08-04T12:30:00.000Z",
    "completedAt": "2026-08-04T12:31:12.000Z"
  }
}
```

完成接口必须幂等。相同内容重复完成返回既有 `READY` 元数据；内容摘要不同则返回冲突。校验失败时把会话
标记为 `FAILED`，对象进入清理队列，不能留下可下载的备份记录。

### 6.4 获取备份列表

```http
GET /api/v1/backups?beforeId=<cursor>&limit=20
Authorization: Bearer <accessToken>
X-App-Timestamp: ...
X-App-Nonce: ...
X-App-Signature: ...
```

规则：

- 只返回 `READY` 状态；
- 默认 `limit=20`，最大 `50`；
- 按服务端 `completedAt DESC, id DESC` 排序；
- 游标使用不透明字符串或服务端整数 ID，不使用页码；
- 不返回对象键、磁盘路径或永久下载地址。

响应：

```json
{
  "code": 0,
  "message": "ok",
  "data": {
    "items": [
      {
        "backupId": "019b0ee8-5012-7923-8d98-8ef6f0f8a91a",
        "formatVersion": 1,
        "appVersionName": "1.0.1",
        "appVersionCode": 13,
        "databaseSchemaVersion": 12,
        "platform": "ios",
        "createdAt": "2026-08-04T12:30:00.000Z",
        "completedAt": "2026-08-04T12:31:12.000Z",
        "byteSize": 483920,
        "sha256": "a64f...",
        "itemCounts": {
          "books": 18,
          "bookmarks": 7
        }
      }
    ],
    "nextCursor": null,
    "hasMore": false,
    "totalReadyCount": 1,
    "usedQuotaBytes": 483920,
    "userQuotaBytes": 104857600
  }
}
```

### 6.5 获取最新备份

```http
GET /api/v1/backups/latest
Authorization: Bearer <accessToken>
X-App-Timestamp: ...
X-App-Nonce: ...
X-App-Signature: ...
```

用于登录后或新设备初始化时快速判断是否存在可恢复备份。成功时返回与列表项相同的元数据；没有备份时
返回 `data: null`，不要用 HTTP 404 表达“当前账号从未备份”。该接口不直接返回下载地址，避免登录后
探测请求无意创建可用下载凭据。

### 6.6 创建短期下载地址

```http
POST /api/v1/backups/{backupId}/download
Authorization: Bearer <accessToken>
Content-Type: application/json
X-App-Timestamp: ...
X-App-Nonce: ...
X-App-Signature: ...
```

请求正文为 `{}`。服务端再次检查产品、用户、状态和对象存在性后，返回短期私有下载地址：

```json
{
  "code": 0,
  "message": "ok",
  "data": {
    "backupId": "019b0ee8-5012-7923-8d98-8ef6f0f8a91a",
    "downloadUrl": "https://storage.example/...短期签名地址...",
    "expiresAt": "2026-08-04T12:40:00.000Z",
    "byteSize": 483920,
    "sha256": "a64f..."
  }
}
```

下载地址必须只读、短期有效，并设置为附件下载。客户端下载完成后仍必须自行校验大小与 SHA-256；服务端
成功签发 URL 不等于客户端下载和恢复成功。

### 6.7 删除备份

```http
DELETE /api/v1/backups/{backupId}
Authorization: Bearer <accessToken>
X-App-Timestamp: ...
X-App-Nonce: ...
X-App-Signature: ...
```

删除采用幂等语义：

- 数据库先把当前用户的记录标记为 `DELETING` 或软删除；
- 记录立即从列表和最新备份中消失；
- 对象删除进入后台重试队列；
- 对象删除成功后记录转为 `DELETED` 或按审计周期清除元数据；
- 重复删除返回成功；
- 其他用户的 `backupId` 按不存在处理。

响应：

```json
{
  "code": 0,
  "message": "ok",
  "data": {
    "backupId": "019b0ee8-5012-7923-8d98-8ef6f0f8a91a",
    "deleted": true
  }
}
```

## 7. API v2 实际二进制上传接口

当前 API v2 把第 6.2 节的 `uploadUrl` 返回为应用服务器的一次性接口：

```http
PUT /api/v1/backups/uploads/{uploadId}/content
Authorization: Bearer <accessToken>
Content-Type: application/octet-stream
Content-Length: ...
X-Upload-Token: <一次性上传凭据>
```

此接口必须流式落盘和计算 SHA-256，禁止先把整个文件读入内存。其余初始化、完成、列表、下载、删除、
状态机和元数据契约保持不变；未来如切换对象存储，只有在 PUT 不再携带 App Bearer Token 时才允许返回
不同源 HTTPS 地址，并且必须同步升级客户端地址与 Header 白名单策略。

不建议使用单个 `multipart/form-data POST /backups` 同时提交元数据和文件：大请求难以复用现有 HMAC
正文签名、失败重试会重复传输全部内容，也较难区分“文件已上传但数据库确认超时”的场景。

## 8. 服务端数据库设计

建议至少增加 `account_backups` 和 `backup_upload_sessions` 两张表。字段类型按实际数据库调整：

```sql
CREATE TABLE account_backups (
  id                    VARCHAR(36) PRIMARY KEY,
  product_id            BIGINT NOT NULL,
  user_id               BIGINT NOT NULL,
  client_backup_id      VARCHAR(36) NOT NULL,
  state                 VARCHAR(16) NOT NULL,
  object_key            VARCHAR(512) NOT NULL,
  format_version        INTEGER NOT NULL,
  app_version_name      VARCHAR(64) NOT NULL,
  app_version_code      BIGINT NOT NULL,
  database_schema_version INTEGER NOT NULL,
  platform              VARCHAR(16) NOT NULL,
  client_created_at     TIMESTAMP NULL,
  byte_size             BIGINT NOT NULL,
  sha256                CHAR(64) NOT NULL,
  item_counts_json      TEXT NULL,
  contains_local_books  BOOLEAN NOT NULL DEFAULT FALSE,
  completed_at          TIMESTAMP NULL,
  delete_requested_at   TIMESTAMP NULL,
  created_at            TIMESTAMP NOT NULL,
  updated_at            TIMESTAMP NOT NULL,
  UNIQUE (product_id, user_id, client_backup_id)
);

CREATE INDEX index_account_backups_user_ready
  ON account_backups (product_id, user_id, state, completed_at DESC);
```

```sql
CREATE TABLE backup_upload_sessions (
  id                    VARCHAR(36) PRIMARY KEY,
  backup_id             VARCHAR(36) NOT NULL,
  product_id            BIGINT NOT NULL,
  user_id               BIGINT NOT NULL,
  state                 VARCHAR(16) NOT NULL,
  upload_token_hash     CHAR(64) NULL,
  expires_at            TIMESTAMP NOT NULL,
  failure_code          VARCHAR(64) NULL,
  created_at            TIMESTAMP NOT NULL,
  updated_at            TIMESTAMP NOT NULL,
  FOREIGN KEY (backup_id) REFERENCES account_backups(id)
);

CREATE INDEX index_backup_upload_sessions_expiry
  ON backup_upload_sessions (state, expires_at);
```

稳定状态建议只允许以下值：

```text
UPLOADING -> VERIFYING -> READY
UPLOADING -> EXPIRED
UPLOADING/VERIFYING -> FAILED
READY -> DELETING -> DELETED
```

状态更新必须使用条件更新或行锁，防止两个完成请求、完成和删除请求同时把记录推进到互相冲突的状态。

## 9. 服务端处理流程

### 9.1 初始化上传

1. 校验 HMAC 时间窗与 nonce 防重放。
2. 校验 Bearer Token、账号状态和产品归属。
3. 校验元数据枚举、长度、大小和 SHA-256 格式。
4. 查询 `clientBackupId`，执行幂等返回或冲突判断。
5. 汇总当前用户 `READY + UPLOADING` 的预留容量，执行配额判断。
6. 创建服务端 `backupId`、对象键和上传会话。
7. 返回短期上传 URL 和当前服务端限制。

### 9.2 完成上传

1. 校验认证、归属、会话状态和有效期。
2. 原子把会话从 `UPLOADING` 更新为 `VERIFYING`。
3. 校验对象存在、真实大小和 SHA-256。
4. 在事务中把备份改为 `READY`，把会话改为 `COMPLETED`。
5. 投递保留版本、容量和孤儿对象清理任务。
6. 返回可稳定展示的备份元数据。

如果服务进程在第 3 步之后崩溃，后续相同完成请求必须能够重新检查对象并继续推进，不能要求客户端重新上传。

### 9.3 下载

1. 按产品、用户、备份 ID 和 `READY` 状态查询。
2. 检查对象仍存在；不存在时记录存储一致性错误并返回受控失败。
3. 签发只读短期 URL，不返回对象键。
4. 只记录下载回执元数据，不记录文件内容或内部 URL。

### 9.4 后台清理

服务端至少需要两个周期任务：

- 上传会话清理：扫描过期 `UPLOADING/VERIFYING` 会话，标记过期并删除对应临时对象；
- 版本和配额清理：按用户保留最新版本，删除超限对象并重试失败任务。

还应周期性核对数据库记录与对象存储：只处理 `backups/` 专用前缀下、超过安全等待期的孤儿对象，禁止用
宽泛路径递归删除整个存储桶。

## 10. 业务错误码建议

| HTTP | code | 含义 |
| --- | --- | --- |
| 400 | `40000` | 请求字段、枚举、时间或摘要格式无效 |
| 401 | `40100` | Access Token 缺失、失效或账号不可用 |
| 403 | `40340` | 当前产品或账号没有备份能力 |
| 404 | `40440` | 当前用户下不存在该备份或上传会话 |
| 409 | `40940` | 幂等键对应的大小或摘要冲突 |
| 409 | `40941` | 上传会话状态不允许当前操作 |
| 413 | `41340` | 文件超过单备份大小限制 |
| 422 | `42240` | 实际对象大小或 SHA-256 校验失败 |
| 429 | `42900` | 请求过于频繁 |
| 507 | `50740` | 用户备份配额不足 |
| 503 | `50340` | 对象存储暂时不可用 |

客户端只能根据 HTTP 状态和稳定业务码映射 UI，不应依赖服务端任意 `message` 文本。

## 11. 隐私和安全要求

- 全链路只允许 HTTPS；生产环境不得继续使用明文 HTTP 服务根地址。
- 对象存储必须启用服务端静态加密，数据库备份元数据也应位于加密磁盘或托管加密存储中。
- 服务端不得解压或解析备份文件；这同时降低阅读隐私泄漏和 ZIP 炸弹风险。
- 不接收客户端自定义对象键、磁盘路径或原始文件名。
- 不把用户名、Token、对象键、下载签名 URL、SHA-256 全值或备份内容写入普通业务日志。
- 运维日志最多记录请求 ID、用户内部数值 ID、备份 ID、状态、大小、耗时和受控错误码。
- Access Token 失效后，既有上传和下载 URL 仍可能在短期内有效，因此 URL 必须一次性或足够短期。
- 删除账号时必须把该账号所有 `READY/UPLOADING` 备份和对象加入删除流程。
- 管理后台默认只能查看元数据，不提供直接下载用户备份内容的按钮；如业务确需客服恢复，必须另建审计授权。

备份文件可能包含书名、阅读历史、书签摘录和正文标注，属于隐私数据。首版若不做客户端端到端加密，
产品必须明确服务端可以接触备份字节，并保证传输加密、静态加密、最小权限和删除生命周期。未来增加端到端
加密时，服务端接口保持把文件作为不透明对象处理，无需改变核心存储模型。

## 12. 服务端不应承担的恢复逻辑

服务端只返回完整、经过摘要校验的备份文件，不执行下列操作：

- 不判断本地和云端哪份书架更新；
- 不合并同一本书的阅读进度；
- 不解析替换规则或书源 JSON；
- 不把备份文件展开写入服务端业务表；
- 不处理客户端 SQLite Schema 迁移；
- 不决定游客数据是否迁入登录账号。

这些行为由 Flutter 恢复 UseCase 在本地事务中完成。这样备份格式可以独立演进，也不会把客户端数据库结构
耦合到服务端。

## 13. 推荐备份文件内容边界

虽然服务端不解析文件，但双方必须约定首版允许的内容，避免容量和隐私边界漂移：

```text
backup-v1.pnbak
  manifest.json
  books.json
  book_groups.json
  reading_history.json
  bookmarks.json
  annotations.json
  replace_rules.json
  preferences.json
  custom_book_sources.json
  assets/covers/*
```

明确排除：

- Access Token、Refresh Token、密码、Cookie、Authorization；
- 书源登录会话和可能包含凭据的 Header/变量；
- 网络书目录与正文缓存；
- 漫画图片缓存；
- 下载任务、自动换源临时状态；
- 搜索结果和书源候选；
- 目录刷新检查点；
- 日志、崩溃报告、埋点和书源成功率队列；
- MMKV 迁移标记和设备安装周期提示状态。

当前 Flutter 的书签、正文标注、替换规则和书源仍缺少完整账号作用域。客户端在补齐 `userId` 归属前，
不得把这些设备公共表直接导出到任一登录账号的备份。

## 14. 管理与运维要求

建议后端配置增加：

```text
BACKUP_ENABLED
BACKUP_MAX_FILE_BYTES
BACKUP_USER_QUOTA_BYTES
BACKUP_RETAINED_VERSIONS
BACKUP_UPLOAD_SESSION_MINUTES
BACKUP_DOWNLOAD_URL_MINUTES
BACKUP_STORAGE_BUCKET
BACKUP_STORAGE_PREFIX
BACKUP_STORAGE_ENCRYPTION_KEY_ID（如使用托管 KMS）
```

运行指标至少包括：

- 初始化上传成功/拒绝/限流数量；
- 完成校验成功、大小不符和摘要不符数量；
- `UPLOADING/VERIFYING` 超时数量；
- 对象存储读写失败率和延迟；
- 每用户备份数量和容量分布，仅做聚合；
- 清理任务积压和删除失败重试数量；
- 数据库 `READY` 记录但对象不存在的一致性错误数量。

告警不能携带备份内容、下载 URL、Token、用户名或用户阅读数据。

## 15. 服务端验收清单

1. 用户 A 初始化、上传、完成后，只能在 A 的列表中看到备份。
2. 用户 B 使用 A 的 `backupId/uploadId` 下载、完成或删除时统一得到不存在。
3. 相同 `clientBackupId + sha256 + byteSize` 重试不会创建第二份备份。
4. 相同 `clientBackupId` 但摘要或大小不同返回幂等冲突。
5. 只上传部分字节后调用完成，备份不会进入 `READY`。
6. 修改一个字节后调用完成，SHA-256 校验失败且对象进入清理队列。
7. 完成接口响应超时后重试，能够返回已有 `READY` 结果而不要求重新上传。
8. 上传会话过期后，临时对象会被清理且不会出现在备份列表。
9. 第六份备份完成后只保留配置允许的最近五份，旧对象最终删除。
10. 超出单文件上限、用户总配额或限流阈值时返回稳定业务码。
11. 下载 URL 过期后无法继续下载，且存储桶不能匿名列举或公开读取。
12. 删除接口重复调用保持成功，删除记录立即不再出现在列表和 latest 中。
13. 数据库有记录但对象缺失时返回受控错误并产生脱敏一致性告警。
14. 账号删除后，其上传会话、备份元数据和存储对象全部进入清理生命周期。
15. 服务端日志不包含备份正文、对象签名 URL、Token、用户名、书名、书签或标注内容。

## 16. 推荐实施顺序

1. 建立 `account_backups`、`backup_upload_sessions` 和状态机。
2. 接入私有对象存储或受控本地文件存储，并完成过期会话清理。
3. 实现初始化、上传和完成接口，先通过大小、摘要、幂等和越权验收。
4. 实现列表、latest、下载和删除接口。
5. 实现版本保留、用户配额和后台删除重试。
6. 接入运维指标、脱敏日志和账号删除联动。
7. 保持 API v2 导出文档和不含用户数据的接口样例与部署实现同步，供 Flutter 联调和回归。

Flutter 已按 API v2 写入上传、列表、latest、下载、恢复与删除逻辑；当前不自行宣称接口或恢复流程通过，
仍需用户运行检查并在真实登录账号、真实服务端数据和双平台环境完成验收。用户入口留到页面专项实现。
