# 服务器书源逐页入库与断点续传方案

状态：`SUPERSEDED_BY_CURSOR_SYNC_V2`。该页码同步方案已被 [`09_booksource_cursor_sync_v2_rewrite_plan.md`](./09_booksource_cursor_sync_v2_rewrite_plan.md) 取代，仅保留用于历史追溯。

## 用户确认的行为变化

服务器书源同步不再要求“所有分页成功后一次预览、一次确认导入”。每一个成功返回且通过结构校验的分页，立即导入本地 `book_sources`；后续页面失败时，已导入页面保持有效。用户明确接受书源同步可能处于半套完成状态。

当前全量原子失败方案由本方案取代：第 27 页失败不再丢弃前 26 页；下次同步从已持久化的失败页继续，不重新请求已完成页面。

## 持久化状态

复用既有 `caches` 表，不新增数据库 Schema：

```text
key: remote_book_source_incremental_sync_checkpoint
value:
  nextPage: 下一次需要请求的页码，最小为 1
  expectedTotal: 本轮服务端声明的总数（可为空）
  collectedCount: 本轮已成功请求并提交导入的原始条目数
  importedCount: 本轮已成功提交导入事务的条数
```

每页成功响应后，先经现有书源解码、成人内容过滤和导入事务处理；只有该页导入成功，才把 `nextPage` 持久化为下一页。请求、解析、过滤或导入失败都保留当前 `nextPage`，因此重试不会跳过未落库页面。

当 `importedCount >= expectedTotal` 时，视为本轮完成并把 checkpoint 重置为第 1 页，下一次手动同步从第一页重新同步。

## 冲突策略

建议并默认使用现有 `BookSourceConflictPolicy.overwrite`：服务器同步的同 URL 书源覆盖本地同 URL 版本，确保续传和后续完整同步能更新旧页。用户自行导入书源的冲突策略不变。

这意味着服务器书源和同 URL 本地自定义书源不能并存；若该 URL 已被用户本地编辑，下次服务器同步会覆盖它。若不接受该语义，必须改为 `skip` 或为服务器书源增加独立身份标识后再执行。

## 流程

```text
点击同步
  -> 读取 checkpoint.nextPage（缺失则 1）
  -> 请求该页
  -> 校验页码、页大小和总数
  -> 调用现有 ImportBookSourcesUseCase 导入该页（overwrite）
  -> 成功：持久化 nextPage + 1，刷新进度 UI
  -> 继续下一页
  -> 请求/校验/导入失败：保留当前 nextPage，展示“可从第 N 页继续”
```

同步过程仍串行化，避免重复点击并发写入。手动离开页面不取消已开始的页导入事务；路由仅停止接收 UI 进度。不会记录 Token、书源 URL、书源 JSON、Cookie 或响应正文到日志或 checkpoint。

## 文件与验收

| 文件 | 调整 |
|---|---|
| `app/remote_book_source_sync_service.dart` | 从全量 JSON 返回改为逐页请求、校验、导入回调和 checkpoint 读写。 |
| `app/app_dependencies.dart` | 注入现有缓存与书源导入依赖。 |
| `ui/book_source/book_source_route.dart` / `book_source_screen.dart` | 显示当前页、已导入数量、失败页与“从第 N 页继续”。 |
| `help/logging/app_logger.dart` | 继续使用统一 `REMOTE_BOOK_SOURCE_SYNC` Tag，记录页号、计数、导入摘要与失败阶段。 |

验收：第 N 页超时后，本地仍可看到前 N-1 页书源；再次点击同步直接从第 N 页开始；本页导入失败时不会推进 checkpoint；全部完成后下一次同步从第 1 页开始。
