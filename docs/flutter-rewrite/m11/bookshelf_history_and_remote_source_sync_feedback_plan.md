# 书架历史页签与服务器书源同步反馈调整方案

状态：`IMPLEMENTED_PENDING_USER_VERIFICATION / 代码已写入，等待用户运行验收`

## 目标

本轮同时修正书架/历史固定页签的渐变选中效果与手势跳变，并为服务器书源同步提供可见的流程界面和受控诊断日志。

## 已定位问题

### 页签动画

`BookshelfRoute` 同时通过 `PageController` 监听器和 `onPageChanged` 修改 `_pageProgress`。`PageView.onPageChanged` 在手势越过半屏时即报告目标整数页，因此拖动仍在中间时进度被强制设为 `1`，随后监听器又以真实的 `0.x` 页位置覆盖，造成选中背景先跳到底、再回到中间的视觉跳变。

### 服务器书源同步

书源管理页点击同步后直接 `await fetchSources()`；页面没有独立同步态，按钮禁用条件也只依赖普通书源管理 `busy`，用户无法得知请求是否已开始、同步到第几页或是否失败。当前失败日志只在路由层记录 `stage=book_source_sync_failed`，不能定位失败发生在会话检查、哪一分页请求、分页一致性校验还是 JSON 交给导入预览之前。

## 调整范围

### 1. 书架 / 历史页签

- 页签的选中背景也改为“底部为当前选中色、顶部透明”的线性渐变；底层未选中背景保持同方向渐变。
- 删除 `onPageChanged` 对连续页签进度的写入，仅用 `PageController.page` 驱动背景位置；`onPageChanged` 只保留选择模式退出等离散业务动作。
- 历史页右上角三项操作全部实现：
  - 导入：复用现有本地书导入入口；
  - 布局：为历史页增加独立列表/网格显示状态；
  - 刷新：重新建立历史数据库观察并显示刷新中的轻量状态，完成后更新为最新快照。它不发起书架目录网络刷新，也不改写历史数据。

### 2. 服务器书源同步反馈界面

- 在书源管理路由中持有独立同步状态，点击后立刻显示不可误关闭的进度对话框，至少展示“正在校验会话 / 正在获取第 N 页 / 正在准备导入预览 / 同步失败”。
- 同步期间禁用再次点击同步，但不影响既有本地书源列表渲染；成功后关闭进度对话框并进入已有 JSON 导入预览与冲突策略确认流程。
- 远端同步服务暴露不含 Token、书源 URL、书源 JSON 或响应正文的进度回调，只包含阶段、页码、已收集数量和服务端声明总数。
- 为本轮新增的日志统一使用 `REMOTE_BOOK_SOURCE_SYNC` Tag：记录开始、会话缺失、页请求开始/成功、分页校验失败、汇总成功、用户取消/路由卸载和异常失败。日志只记录阶段、页码、计数、耗时桶和错误类别，绝不记录 Token、书源内容、URL、Cookie 或完整服务端响应。

## 已修改文件

| 文件 | 调整 |
|---|---|
| `ui/bookshelf/bookshelf_route.dart` | 去除页码整数回写，按当前页分发三项操作。 |
| `ui/bookshelf/bookshelf_page_switcher.dart` | 选中背景改为同方向的底到上渐变。 |
| `ui/bookshelf/reading_history_contract.dart`、`reading_history_view_model.dart`、`reading_history_screen.dart` | 独立历史布局与刷新状态，增加网格展示。 |
| `ui/book_source/book_source_route.dart`、`book_source_screen.dart` | 同步进度对话框、重复点击防护和完成/失败反馈。 |
| `app/remote_book_source_sync_service.dart`、`app/app_dependencies.dart` | 受控进度回调和统一同步日志。 |
| `help/logging/app_logger.dart` | 声明本轮统一日志 Tag。 |

## 验收

1. 手动横滑时，选中背景连续移动，不再跳到底后回拉；书架与历史选中态均为底实顶透渐变。
2. 历史页的导入、布局和刷新三个图标均有实际结果；历史刷新不触发书架网络目录刷新。
3. 点击服务器书源同步立即出现阶段进度，重复点击不会并发请求；成功进入导入预览，失败保留清晰错误提示。
4. 日志可定位失败阶段和页码，但不泄露账号、Token、书源 URL/JSON、Cookie 或响应正文。
5. 不运行构建、测试、分析或格式化，由用户进行 Android/iOS 验收。
