# 书源游标同步 V2 重写方案

状态：`IMPLEMENTED_PENDING_USER_VERIFICATION`。本方案依据 2026-07-24 提供的 `Novel Admin API v2`，已写入 API、游标断点和书源同步 UI；未运行构建、测试或静态检查，最终状态仍须由用户验收。

## 1. 目标与边界

唯一目标：将 Flutter 的“服务器书源同步”重写为 `GET /api/v1/booksource/page?beforeId=...` 的游标同步，并提供与断点语义一致的专用 UI。

本次包含：

- 从当前登录会话读取 Bearer Token，并校验 `canSyncBookSource`；
- 为游标 GET 请求添加 App HMAC 签名、Bearer Token 和严格响应解码；
- 固定按服务端每批 50 条处理，每批通过现有书源导入事务成功落库后才保存 `nextCursor`；
- 进程被杀或网络失败后，从已保存游标继续；`hasMore=false` 时完成本轮并清除断点；
- 重写书源管理页中的同步入口、同步中状态、完成与可恢复失败反馈；
- 移除旧 `page=N` 同步专用的 API、页码 checkpoint、进度模型、服务流程和 UI 文案。

本次不包含：书源本地编辑/导入管理、`/booksource/stats/batch` 成功率上报、`/booksource/event` 兼容接口、分享 Token 消费、服务端或 Android 参考工程修改，也不修改本地 `book_sources` 表结构。

## 2. 与旧实现的不可兼容差异

| 维度 | 旧实现 | API v2 要求 | 重写决定 |
| --- | --- | --- | --- |
| 请求 | `page=N`，仅 Bearer | 可选 `beforeId`，HMAC + Bearer + 权限 | 删除页码参数与旧请求方法；首次不传查询参数，续传传整数游标 |
| 顺序 | 页码与 total 一致性校验 | 不可变 ID 倒序；同步期间 total 可变 | 不将 `total` 用作断点、完成条件或完整性校验 |
| 断点 | `nextPage` | 上批成功落库后的 `nextCursor` | checkpoint 仅保存游标与本轮已落库数量；不保存书源内容或 token |
| 完成 | `importedCount >= total` | `hasMore == false` 且 `nextCursor == null` | 仅按 `hasMore` 完成；协议矛盾直接失败且保留旧断点 |
| 每批导入 | 覆盖同 URL | 未在新接口改变 | 继续经 `ImportBookSourcesUseCase` 使用 `overwrite`，保持现有书源管理冲突语义 |
| UI | “第 N 页”“从第 N 页继续” | 游标不向用户暴露 | 显示“第 N 批、已处理 X 条、服务器当前共 Y 条”；失败显示“已保存进度，再次点击继续” |

## 3. 数据与状态机

继续复用 `caches`，不增加数据库 Schema：

```text
key: remote_book_source_cursor_sync_checkpoint_v2
value:
  beforeId: null 或正整数；下一请求使用的游标
  processedCount: 当前轮已成功提交导入事务的远端条目数
  batchCount: 当前轮已成功导入的批次数
  displayedTotal: 最近成功响应的 total，仅用于 UI 展示
```

状态机：

```text
点击同步
  -> 校验内存会话和 canSyncBookSource
  -> 读取 checkpoint（缺失即 beforeId=null）
  -> GET page(beforeId)
  -> 校验 items/pageSize=50/hasMore/nextCursor
  -> ImportBookSourcesUseCase(items JSON, overwrite)
  -> 导入事务成功：保存 nextCursor、processedCount、batchCount、displayedTotal
  -> hasMore=true：请求下一批
  -> hasMore=false 且 nextCursor=null：删除 checkpoint，本轮完成
```

断点写入必须发生在导入事务之后。请求、签名、响应解码、内容过滤或导入任一环节失败都不能推进游标。成功后若应用被杀，下一次以已保存的 `beforeId` 继续，允许本地因 URL 覆盖而出现幂等重导入，但不得跳过未落库批次。

协议校验规则：

- `items` 必须是数组，`total >= 0`，`pageSize == 50`，`hasMore` 必须为布尔值；
- `hasMore=true` 时 `nextCursor` 必须为正整数；`hasMore=false` 时必须为 `null`；
- 同一轮中新的 `nextCursor` 必须严格小于本次请求的 `beforeId`（首次请求除外），防止服务端游标循环；
- 空 `items` 仅在 `hasMore=false` 时允许；
- 服务端返回的 `total` 只作展示，数量变化不报错、不重置断点。

## 4. 分层和文件改动

| 层 | 文件 | 改动 |
| --- | --- | --- |
| API | `api/remote_app/remote_app_api.dart` | 以 `fetchBookSourceCursorPage(token, {int? beforeId})` 取代页码方法，复用现有 HMAC GET 基础能力并附加 Authorization；强类型 DTO 改为 `items/total/pageSize/nextCursor/hasMore` |
| 应用服务 | `app/remote_book_source_sync_service.dart` | 删除页码 checkpoint 和页码状态机，改为游标 checkpoint、单飞同步锁、批次循环和无敏感信息进度 |
| 依赖注入 | `app/app_dependencies.dart` | 仅在构造器依赖因新 API/服务边界变化时调整；继续注入已有导入用例和缓存 DAO |
| 路由 UI | `ui/book_source/book_source_route.dart` | 去除“第几页继续”错误分支，映射新进度、权限不足、可继续失败和完成摘要；路由销毁后不再更新 UI |
| 展示 UI | `ui/book_source/book_source_screen.dart` | 将同步状态条改为批次/处理数量/展示总数，不显示 cursor、URL、Token 或响应内容 |
| 文档 | 本文、`AI_PROJECT_INDEX.md`、现有旧专项方案 | 更新导航与实现快照；旧方案标记被 V2 取代或删除，避免以后误用 |

不会把网络或导入逻辑放入 Widget；UI 只发起一次同步意图并渲染不可变进度快照。同步使用单飞锁防止重复点击；路由离开后只取消 UI 订阅，不取消已开始的导入事务。所有临时控制器、监听器与状态对象均在 `dispose` 释放，避免路由泄漏。

## 5. 安全、日志与错误策略

- 书源分页 GET 采用 `HTTP_METHOD + URL_PATH + TIMESTAMP + NONCE + RAW_BODY`，GET 的 RAW_BODY 为空；查询参数不进入 canonical URL_PATH，实施前将与现有签名帮助方法的 URL 生成方式逐项对齐。
- 不写入日志：Authorization、token、nonce、签名、`beforeId`、书源 URL、书源 JSON、响应体；日志统一使用既有 `REMOTE_BOOK_SOURCE_SYNC` Tag，最多记录阶段、批次数、条目数量、HTTP/错误类别和耗时。
- 401 交给统一会话恢复流程；恢复失败时保留断点并要求登录。403 视为权限终态，刷新权限快照并保留断点，不自动重试。400 或响应结构错误不移动断点，并显示“服务端同步协议异常”。
- HMAC 时间窗口为 5 分钟，nonce 必须随机且五分钟内不复用；客户端只生成随机值，不尝试本地 nonce 去重表或持久化敏感签名材料。

## 6. 用户验收

1. 已登录且有权限，首次同步不携带 `beforeId`；UI 按批次显示进度，完成后提示导入数量。
2. 在任意批导入后断网或杀进程，再次同步从最近一次成功批的游标继续；失败批不会被跳过。
3. 同步中新增、禁用或删除服务器书源时，本轮以 `hasMore=false` 正常结束；UI 的 total 只会更新展示，不会触发重置或错误。
4. 服务端返回 `hasMore/nextCursor` 矛盾、非正游标、`pageSize != 50` 或游标倒退时，操作失败且下次仍可从原断点重试。
5. 无权限账号不显示或不可用同步入口；运行中返回 403 后不持续重试。
6. 检查日志不含 URL、游标、token、签名、nonce、书源 JSON 或响应体。

## 7. 实施后仍需确认的契约点

新 API 说明将 canonical 指定为 URL_PATH；此处按路径不含查询参数实现。若服务端实际将查询字符串纳入签名，必须由后端修正文档或明确提供 canonical 示例后再调整，不能同时猜测两种规则。

接口响应书源示例只给出最小字段。客户端仍会通过既有导入解码器校验完整 Legado 书源 JSON；若服务器实际下发的字段不足以构成可用书源，导入会按既有规则拒绝该条。这是服务端数据契约风险，不应在客户端伪造缺失规则。
