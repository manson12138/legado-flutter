# M11 专项记录：单章换源

状态：`IN_PROGRESS / 代码已实现，等待用户真机验收`

## Android 行为摘要

- 入口：`ReadBookMenuBar.kt` 顶栏换源图标长按或更多菜单的“单章换源”，调用
  `ReadBookViewModel.handleChapterChangeSource()`，取当前 `ReadBook.durChapterIndex`
  对应的 `BookChapter` 后打开 `ReadBookSheet.ChangeChapterSource(chapterIndex, chapterTitle)`。
- UI：`ChangeChapterSourceSheet.kt`，两段式 `AppModalBottomSheet`——先按书名/作者搜索候选
  **书籍**（与整书换源共用 `ChangeSourceSearchUseCase`），选中候选后加载其**完整目录**
  （`GetChapterContentUseCase.getToc`），用 `BookHelp.getDurChapter` 模糊匹配预选一个目录行，
  用户手动点击确认要替换的目标章节。
- 正文拉取：`GetChapterContentUseCase.getContent`（即 `WebBook.getContentAwait`），不经过
  `ContentProcessor`——保存的是原始正文，替换规则和净化在阅读时统一处理。
- 持久化：`BookHelp.saveText(book, chapter, content, saveToSource=false)`，直接覆盖该章节在
  磁盘正文缓存里的文件；不改变 `Book.bookSourceUrl`、不写入任何“来源已被替换”的标记字段。
- 生效：`ReadBook.loadContent` 本来就是“先查本地缓存文件，查不到才请求书源”，缓存文件被覆盖后
  下一次读取自然命中新内容，无需任何专门的“生效”逻辑。
- 撤销：没有专门的撤销功能，复用已有的“刷新本章”（`BookHelp.delContent` + 重新下载）。

## Flutter 映射

| Android | Flutter |
|---|---|
| `ChangeSourceSearchUseCase`（书籍级搜索） | 复用 `BookSearchCoordinator`（`model/web_book/book_search_coordinator.dart`），新协调器内部转发，过滤规则照抄 `ChangeSourceCoordinator.startSearch` |
| `GetChapterContentUseCase.getToc` | 复用 `BookDetailService.loadToc`（`model/web_book/book_detail_service.dart`） |
| `BookHelp.getDurChapter` 模糊匹配 | 新增 `model/reader/chapter_title_matcher.dart`：`resolveMatchingChapterIndex` |
| `GetChapterContentUseCase.getContent` | 复用 `StandardBookSourceService.loadContent` |
| 编排以上四步 | 新增 `model/web_book/change_chapter_source_coordinator.dart`：`ChangeChapterSourceCoordinator` |
| `ChangeChapterSourceContract/ViewModel` | 新增 `ui/change_chapter_source/change_chapter_source_contract.dart` + `_view_model.dart`（同样的搜索/目录两段式状态机） |
| `ChangeChapterSourceSheet.kt` | 新增 `ui/change_chapter_source/change_chapter_source_screen.dart`：`ChangeChapterSourceSheetBody`，作为阅读器 `ReaderSheet` 的一个新变体（`ReaderChangeChapterSourceSheet`），走既有 `showModalBottomSheet` 机制，不是整页导航 |
| `BookHelp.saveText` 覆盖缓存文件 | `ReaderCacheGateway.saveChapterContent(bookUrl, chapterUrl, content, deadline: 0)`——`caches` 表本就支持 `deadline = 0` 表示永久，不需要改表结构 |
| `ReadBook.loadContent` 缓存优先 | `ReadBookCoordinator._load()` 本来就是缓存优先；新增 `invalidateChapter(chapterUrl)` 清掉内存 LRU，避免用户正在看的章节被旧内存内容挡住新缓存 |
| “刷新本章”撤销 | 复用已有 `RetryReaderChapterIntent(forceRefresh: true)`；强制刷新会绕过缓存、重新从原书源拉取并用 7 天 TTL 覆盖掉刚才的永久缓存 |

## 与 Android 的已知差异

- 章节号模糊匹配的兜底只解析阿拉伯数字，不解析中文数字（一二三…）。Jaccard 标题相似度是
  主要判据，多数网络小说同一章标题跨源高度一致，这个简化只影响相似度不足时的兜底命中率。
- 候选目录预选章节找不到时不报错，只是不预选（`preselectedIndex = -1`），用户仍需手动点选，
  与 Android 行为一致。
- 拉取到的候选正文不经过替换规则/净化处理，直接作为原始正文写入缓存，与 Android 一致。

## 用户验收步骤

1. 打开一本已验证的网络书源书籍，进入任意一章，从更多菜单点击“单章换源”。
2. 观察候选来源列表填充，点击一个候选进入其完整目录；确认列表大致定位到与当前章节标题接近的位置。
3. 手动点击目标章节，确认面板关闭并且阅读器正文立即变为新内容。
4. 退出该章再重新进入，确认仍显示替换后的内容（不会因为 7 天缓存失效而回退）。
5. 点击顶栏“刷新当前章”，确认正文恢复为原书源内容。
6. 对本地书打开更多菜单，确认“单章换源”入口禁用。

用户提供上述运行结果前，本 Feature 保持 `IN_PROGRESS`。
