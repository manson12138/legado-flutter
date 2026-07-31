# 书源完成后引导搜索与跳转设计

状态：`IMPLEMENTED_PENDING_USER_VERIFICATION`

## 1. 目标

用户主动完成书源同步或添加后，展示一次明确提示，告知“现在可以前往搜索界面搜索书籍了”。弹窗提供“取消”和“确定”两个按钮：

- 取消：关闭弹窗并停留在书源界面；
- 确定：关闭弹窗并直接进入搜索界面。

本记录只完成代码链路分析和实施设计。按仓库协作规则，等待用户确认后再修改业务代码。

## 2. 当前链路

### 2.1 本地导入

文件、文本、剪贴板、二维码和游客远程 URL 最终都进入 `BookSourceManagementViewModel._importText`。导入成功后，ViewModel 发布 `ImportSummaryDialog`，现有弹窗只显示新增、覆盖、跳过、无效等统计，并只有“完成”按钮。

### 2.2 登录账号服务器同步

`BookSourceManagementRoute._requestRemoteSourceSync` 直接调用 `RemoteBookSourceSyncService.syncAndImportSources`。成功后当前仅显示 Snackbar，没有继续前往搜索页的操作入口。

### 2.3 游客邀请码同步

`BookSourceManagementRoute._requestGuestRemoteSourceImport` 在邀请码分页导入成功后直接显示 Snackbar。游客远程 URL 则回到本地导入确认与摘要链路。

### 2.4 手动新增书源

`BookSourceManagementViewModel._saveDraft` 同时处理新增和编辑。新增成功目前通过通用 `_runWrite` 发布“书源已新增”Snackbar，编辑已有书源发布“书源已保存”Snackbar。

### 2.5 搜索页导航

主页通过 `WelcomeRoute` 的 `IndexedStack` 常驻书架、搜索、书源和我的四个页面，搜索页索引为 `1`，书源页索引为 `2`。书源管理页也可通过 `/book-sources` 独立路由打开。因此跳转必须区分：

- 主页内嵌书源页：通知 `WelcomeViewModel` 切换到索引 `1`，复用已保活的搜索页；
- 独立书源路由：通过 `/search` 打开搜索路由。

搜索页已经订阅 `BookSourceGateway.watchAll()`，切换过去时会使用最新启用书源，不需要重建搜索 ViewModel，也不需要额外查询数据库。

## 3. 触发边界

弹窗只覆盖用户主动发起且成功完成的操作：

1. 登录账号服务器书源同步成功；
2. 游客邀请码书源同步成功；
3. 文件、文本、剪贴板、二维码或远程 URL 导入，且 `BookSourceImportResult.imported > 0`；
4. 手动新建书源成功。

以下情况不弹出该引导：

- 编辑已有书源、启停、分组、删除或登录书源；
- 批量导入结果只有跳过、无效或成人内容屏蔽，实际写入数量为 `0`；
- 同步或导入失败、用户取消、页面销毁；
- 应用启动时自动导入内置默认书源。

服务器同步与游客邀请码同步只要服务返回成功结果就显示完成引导；即使本轮新增数为 `0`，同步动作本身也已完成，弹窗摘要会显示实际数量，不伪造新增结果。

## 4. 弹窗交互

### 4.1 导入摘要

复用现有 `ImportSummaryDialog`，保留总数、新增、覆盖、跳过、无效、成人内容屏蔽和失败详情。在 `imported > 0` 时追加文案：

> 书源已添加完成，现在可以前往搜索界面搜索书籍了。

按钮改为：

- `取消`：关闭摘要，停留在书源页；
- `确定`：关闭摘要后进入搜索页。

当 `imported == 0` 时继续使用单一“完成”按钮，避免把无实际写入的导入描述为添加完成。

### 4.2 服务器与游客同步

使用统一的完成弹窗，标题为“书源同步完成”，正文先显示本次处理/导入摘要，再显示“现在可以前往搜索界面搜索书籍了”。按钮同样为“取消”和“确定”。成功 Snackbar 由该弹窗替代，避免同一结果重复反馈；失败提示仍保持现有 Snackbar。

### 4.3 手动新增

新建书源持久化成功后显示“书源已添加”弹窗，正文说明可以前往搜索。仅新增触发，编辑保存仍使用现有“书源已保存”Snackbar。

弹窗返回布尔结果，由路由在弹窗完全关闭后统一处理导航，避免在 Dialog Overlay 尚未退出时切换主页标签或压入新路由。

## 5. 实施方案

### 5.1 书源路由统一出口

为 `BookSourceManagementRoute` 增加可选的 `onOpenSearch` 回调，并增加内部统一方法：

- 存在回调时调用回调，供主页内嵌场景切换一级标签；
- 不存在回调时通过 `AppRoute.search` 打开独立搜索页；
- 所有异步弹窗返回后检查 `mounted`，页面销毁时不再导航。

### 5.2 主页接线

`WelcomeRoute` 创建内嵌书源页时传入回调，通过 `SelectPrimaryDestinationIntent(1)` 切换到搜索页。`IndexedStack` 不重建四个一级页面，保留搜索输入、历史和滚动状态。

### 5.3 ViewModel 与 Contract

新增一个只表达“手动新增书源成功、请求展示搜索引导”的一次性 Effect。`_saveDraft` 在确认 `original == null` 且写入成功后发布该 Effect；编辑路径继续发布普通消息。

批量导入仍使用现有 `ImportSummaryDialog`，不再额外发布第二个 Effect，避免摘要弹窗关闭后又出现重复引导。

### 5.4 路由直连同步

登录账号同步和游客邀请码同步当前属于 Route 层异步流程，成功后直接调用同一个完成弹窗方法。游客远程 URL 不在这里重复处理，因为它已经进入批量导入摘要链路。

## 6. 状态、性能与内存

- 不增加数据库字段、MMKV 键或迁移，不涉及 `schemaVersion` 和应用 build number；
- 不创建新的页面级 Stream、Controller 或常驻订阅；
- 主页使用现有 `IndexedStack` 切换，避免重复创建搜索协调器和数据库监听；
- 弹窗只持有短期统计文本，不保留原始书源 JSON、Cookie 或脚本内容；
- 同步忙碌状态先复位，再展示完成弹窗；重复点击仍由现有忙碌状态门控；
- 导航前关闭弹窗并检查 `mounted`，防止页面退出后的异步回调使用失效 `BuildContext`。

## 7. 预计修改文件

- `lib/src/ui/home/welcome_route.dart`
- `lib/src/ui/book_source/book_source_contract.dart`
- `lib/src/ui/book_source/book_source_view_model.dart`
- `lib/src/ui/book_source/book_source_route.dart`
- `docs/flutter-rewrite/AI_PROJECT_INDEX.md`
- 本设计记录

不新增持久化文件，不改 Android 参考仓库。

## 8. 验收场景

1. 登录账号服务器同步成功后出现“取消/确定”；取消留在书源页，确定切到主页搜索标签。
2. 游客邀请码同步成功后行为一致，摘要数量正确。
3. 文件、文本、剪贴板、二维码和远程 URL 导入实际写入书源后，导入统计与搜索引导只出现一次。
4. 导入全部跳过或无效时只显示结果和“完成”，不显示可搜索引导。
5. 手动新增书源成功后出现引导；编辑已有书源成功不出现引导。
6. 独立 `/book-sources` 页面确认后打开 `/search`，主页内嵌页面确认后只切换一级标签。
7. 失败、取消和页面销毁时不跳转，不出现延迟弹窗。
