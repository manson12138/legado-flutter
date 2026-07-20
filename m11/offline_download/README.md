# M11 专项记录：离线下载

状态：`IN_PROGRESS / 代码已实现前台运行范围，等待用户真机验收`

## 本轮范围

做：
- 阅读器内“下载”面板：选择章节范围（对齐 Android `DownloadSheet` 的起止章节号默认值），
  加入当前书的下载队列。
- 数据库持久化的下载队列（`download_tasks` 表），应用重启后残留任务会被恢复继续调度，
  不是纯内存队列。
- 有界并发调度（默认 3 个章节同时下载）、失败自动重试（封顶 3 次，短延迟后重新排队）、
  每章状态展示（等待/下载中/成功/失败）、失败手动重试、单章移除、整本书清空队列。
- 已下载正文与单章换源共用同一条“正文缓存”存储路径（`caches` 表 + `deadline: 0` 永久语义），
  不新增第二套正文存储。

明确不做（记录差距，不假装完成）：
- **没有 Android `CacheBookService` 那样的前台服务 + 通知**：下载只在 Flutter 引擎存活期间
  （应用前台，Android 上短时间退到后台可能也行，但没有保证）进行；应用被系统回收或用户完全
  退出后下载停止，下次打开应用只会把队列里的任务从头继续，不会补上停机期间的下载。
- 没有暂停/恢复，只有移除和重新入队。
- 没有 Android `BookCacheManageScreen` 那种跨书全局缓存管理仪表盘；本轮下载面板只能看当前书。
- 没有存储配额/用量限制（Android 本身也没有）。
- 没有漫画/图片章节下载（Flutter 暂无漫画阅读器）。

## Android 行为摘要（供对照）

- `DownloadSheet.kt`：起止章节号输入框，默认 `当前章节+1` 到 `总章节数`，确认后调用
  `CacheBook.start(context, book, start, end)`。
- `CacheBook`/`CacheBookModel`/`CacheDownloadQueue`/`CacheDownloadStateStore`：跨书调度器 +
  每本书独立队列 + 全局状态汇总；全局最多 8 个章节并发；单章失败自动重试 3 次，1 秒退避。
- `CacheBookService`：前台 `Service` + 常驻通知，展示汇总进度，应用被杀后由系统保活到下载完成
  或用户取消。
- `BookHelp.saveText`：下载成功的正文写入普通文件缓存（永久，无 TTL）。
- `BookCacheManageScreen`：跨书仪表盘，展示每本书的缓存状态、支持暂停/继续/删除。

## Flutter 映射

| Android | Flutter |
|---|---|
| `CacheDownloadRequest`/`ChapterSelection` | `domain/model/download_task.dart`：`DownloadTask`，只存 `bookUrl/chapterIndex/status/retryCount/updatedAt`，不冗余章节标题/URL |
| `CacheDownloadStateStore`（内存状态） | `download_tasks` 表（`data/local/legado_database.dart` schemaVersion 2→3）+ `DownloadTaskDao`——数据库持久化，天然支持崩溃恢复 |
| `CacheBook`/`CacheBookModel` 调度器 | `model/reader/download_coordinator.dart`：`DownloadCoordinator`，事件驱动（入队/重试后 `_kick()`）而不是轮询，固定并发数领取等待任务 |
| `CacheBookService` 前台服务 | **未实现**，见上方“明确不做” |
| `BookHelp.saveText` 永久文件缓存 | 复用 `ReaderCacheGateway.saveChapterContent(..., deadline: 0)`，与单章换源共用同一套“永久缓存”语义 |
| `DownloadSheet.kt` | `ui/reader/reader_download_sheet.dart`：`ReaderDownloadSheetBody`，新增 `ReaderSheet` 变体 `ReaderDownloadSheet` |
| `BookCacheManageScreen`（跨书仪表盘） | **未实现**，见上方“明确不做” |

## 调度设计要点

- `DownloadCoordinator` 是 App 级单例（`AppDependencies.create()` 构造一次），不是页面级
  `create*Coordinator()` 工厂——必须在用户关闭下载面板后继续跑。
- 领取任务前不产生额外 `await`（`_claimNextTask` 内部读取待办列表后立即同步标记为运行中再
  返回），同一调度器实例内部不会出现两个 worker 抢到同一任务的竞争。
- 已有有效正文缓存（无论是普通 7 天缓存还是已有永久缓存）时不重新发请求，只把 `deadline`
  升级为 0——用户点击“下载”这个动作本身保证“从现在起这章不再受 7 天有效期约束”。
- 卷标题、本地书章节直接标记成功，不发网络请求，对齐 Android 对卷标题“视为已缓存”的处理。

## 用户验收步骤

1. 打开一本已验证的网络书源书籍，从更多菜单点击“下载”，确认起止章节号默认值符合预期
   （下一章 ~ 最后一章）。
2. 修改范围并点击“开始下载”，观察任务列表状态从等待→下载中→成功变化。
3. 断网后新加入几个章节，观察至少一个任务在重试 3 次后进入失败态；恢复网络后点击重试，
   确认能转回成功。
4. 下载完成后断网直接打开这些章节，确认无需网络也能正常阅读。
5. 完全关闭应用（不仅是切后台）后重新打开，进入同一本书的下载面板，确认队列状态还在，
   未完成的任务能继续被调度（不需要重新点击“开始下载”）。
6. 对本地书确认更多菜单里“下载”入口禁用。
7. 确认“后续能力”面板里不再出现“离线下载”这一项假占位。

用户提供上述运行结果前，本 Feature 保持 `IN_PROGRESS`。
