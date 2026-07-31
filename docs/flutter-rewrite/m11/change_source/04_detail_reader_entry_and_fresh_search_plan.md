# 详情与阅读器整书换源入口及重新搜索修正方案

状态：`IN_PROGRESS / 代码已实现，等待用户运行验收`

## 1. 目标

修正两个整书换源入口：

- 已入架网络书的详情页点击“替换书源”后，必须进入整书换源页并重新搜索当前可见且已启用的书源，不能只展示进入详情前已有的候选；
- 阅读器“更多”菜单同时提供文字明确的“整书换源”和“单章换源”，整书换源成功后继续用新主键、新目录和迁移后的阅读进度阅读。

本任务不重写已经存在的多书源搜索、候选详情/目录预览、迁移选项和 SQLite 原子换源事务。

## 2. 当前 Flutter 原因

### 2.1 详情页被已有候选分支截走

`book_info_screen.dart` 的“书源 / 换源”主操作卡当前使用：

```text
group.books.length > 1
  -> _showSourceChoices(...)
否则
  -> OpenBookInfoFullSourceChangeIntent
```

因此，只要详情路由携带两个以上搜索候选，用户点击主操作卡就只会看到同次搜索的已有来源，不会进入 `/books/change-source`。

右上菜单“整书换源”已经会发送 `OpenBookInfoFullSourceChangeIntent`，属于正确链路。

### 2.2 整书换源页本身已经会重新搜索

`ChangeBookSourceViewModel._initialize()` 已经：

1. 通过 `BookshelfGateway.getBook(bookUrl)` 重新确认书架事实；
2. 读取当前可见且已启用的书源；
3. 自动调用 `_startSearch()`；
4. `_startSearch()` 会取消旧任务、清空旧候选、增加搜索代次，并从当前搜索范围重新执行有界多书源搜索。

因此本任务不需要新增第二套搜索器，也不需要把详情的 `group.books` 注入整书换源页。只需保证详情主入口进入这条现有链路。

### 2.3 阅读器业务链已存在但入口不清晰

Flutter 已有：

```text
OpenReaderBookSourceChangeIntent
  -> ReaderViewModel._requestBookSourceChange()
  -> 保存当前稳定阅读进度
  -> OpenReaderBookSourceChangeEffect
  -> ReaderRoute._openChangeSource()
  -> /books/change-source
  -> ChangeBookSourceUseCase
  -> 新 bookUrl 替换当前阅读路由
```

但是阅读器 UI 只有顶部无文字的 `swap_horiz` 图标；更多菜单仅列出“单章换源”。在手机窄屏和图标语义不明显的情况下，用户会认为阅读器没有整书换源功能。

### 2.4 阅读器外部路由恢复不完整

当前取消整书换源后只重新调用 `enterReader`，没有同步恢复：

- 阅读器低频系统信息定时器；
- 键盘/音量键焦点；
- 路由打开异常时的系统模式和单飞标志。

此外，阅读历史可以打开未加入书架的网络书。当前整书换源入口只检查本地书，未提前检查 `isInBookshelf`，会进入换源页后才提示书籍不存在。

## 3. Android 参考行为

主要参考文件：

- `ui/book/info/BookInfoViewModel.kt`
- `ui/book/info/BookInfoScreen.kt`
- `ui/book/info/BookInfoSheets.kt`
- `ui/widget/components/changeSource/ChangeSourceSheet.kt`
- `ui/book/changesource/ChangeBookSourceComposeViewModel.kt`
- `domain/usecase/ChangeSourceSearchUseCase.kt`
- `ui/book/read/ReadBookContract.kt`
- `ui/book/read/ReadBookMenuBar.kt`
- `ui/book/read/ReadBookViewModel.kt`
- `ui/book/read/ReadBookScreen.kt`

Android 行为：

1. 详情页来源操作打开共用 `ChangeSourceSheet`；
2. Android 会先读取 `searchBooks` 缓存，缓存为空时自动搜索，刷新按钮可以强制重新搜索；
3. 阅读器来源按钮短按执行默认换源方式，受 `defaultSourceChangeAll` 配置影响；
4. 来源按钮长按或来源下拉菜单会同时展示“换源”和“单章换源”；
5. 整书换源面板由详情页与阅读器共用；
6. 阅读器换源成功后调用 `ChangeBookSourceUseCase`，重置当前 `ReadBook` 数据并加载新来源正文。

本任务采用 Android 的“两个明确入口共存”和共用整书换源状态机，但按用户本次明确要求做一处差异：

- Flutter 详情页点击“替换书源”后每次都直接开始一次新的搜索，不因已有候选而跳过搜索。

## 4. 详情页修正

### 4.1 明确区分两种来源操作

详情页保留两种语义：

- **已有书源**：只切换搜索进入详情时携带的 `group.books`，不修改书架主键；
- **替换书源**：对已入架网络书打开 `/books/change-source`，自动重新搜索全部当前启用书源，并在确认后原子替换书籍主键和目录。

### 4.2 主操作卡行为

详情主操作卡按照书籍状态决定：

- 已入架网络书：标题显示“替换书源”，说明显示“重新搜索全部启用书源”，点击始终发送 `OpenBookInfoFullSourceChangeIntent`；
- 未入架且有多个详情候选：标题显示“已有书源”，点击继续打开 `_showSourceChoices`；
- 未入架且只有一个来源：显示“加入书架后可替换书源”；
- 本地书：显示“本地书不支持整书换源”。

顶部已有来源下拉仍保留，避免丢失搜索结果间的临时详情切换能力。

### 4.3 不向整书换源页传旧候选

整书换源页继续只接收旧 `bookUrl`，由页面重新读取数据库事实和启用书源。这样可以保证：

- 详情页持有的旧 `Book` 不会覆盖最新进度和用户字段；
- 搜索范围使用进入换源页时的当前书源状态；
- 成人内容可见性和书源启停变化得到重新计算；
- 页面关闭时现有 `BookSearchRun` 可以完整取消。

## 5. 阅读器修正

### 5.1 显式入口

在阅读器“更多”菜单增加：

- `整书换源`
- `单章换源`

两个入口并列显示，不能再让用户通过无文字图标猜测区别。

顶部交换图标继续作为整书换源快捷入口；窄屏即使用户忽略顶部图标，也能从更多菜单找到文字入口。后续如顶部操作仍发生拥挤，可只在宽屏保留快捷图标，但本任务不调整其他阅读器工具栏布局。

### 5.2 书架成员校验

整书换源只修改书架持久化主键，因此：

- 本地书提示“本地书不支持整书换源”；
- 阅读历史中尚未加入书架的网络书提示“请先加入书架再替换书源”；
- 已入架网络书才保存进度并打开换源页。

单章换源仍允许网络书使用，它只覆盖章节正文缓存，不改变书架书籍主键；其现有逻辑不修改。

### 5.3 打开换源页

阅读器发送整书换源 Intent 后：

1. 保存当前章节索引、字符位置和稳定锚点；
2. 收起阅读菜单；
3. 停止系统信息定时器；
4. 退出沉浸模式和屏幕常亮；
5. 单飞打开 `/books/change-source`；
6. 换源页自动重新搜索当前可见且启用的全部书源。

### 5.4 取消和异常恢复

用户取消换源或导航失败时统一恢复：

- 阅读器系统栏、亮度、方向和常亮配置；
- 低频系统信息定时器；
- 键盘/音量键焦点；
- `_openingChangeSource` 单飞标志。

恢复逻辑放在 `ReaderRoute` 私有方法中，避免取消、异常和其他外部路由返回路径逐项遗漏。不得在已销毁路由上恢复平台状态。

### 5.5 换源成功

整书换源确认后继续复用现有事务：

1. 候选必须完成详情和完整目录加载；
2. `ChangeBookSourceUseCase` 按迁移选项映射阅读进度、分组、排序、自定义封面、标签备注和阅读配置；
3. `BookRepository.changeBookSource` 在一个 SQLite 事务中删除旧书/旧目录并写入新书/新目录；
4. 处理后正文缓存的旧、新主键均失效；
5. 阅读器使用 `pushReplacementNamed` 替换旧阅读路由，传入新 `Book`；
6. 新阅读器从 SQLite 读取新目录，并按迁移后的章节索引和稳定锚点加载新来源正文。

旧阅读路由不能继续持有已经删除的旧 `bookUrl`。

## 6. 搜索行为

详情和阅读器都复用同一个 `/books/change-source` 页面：

- 默认搜索全部当前启用且可见的书源；
- 固定最大并发继续由 `BookSearchCoordinator` 控制；
- 单书源超时、部分失败、停止和重新搜索沿用现有实现；
- 书名保持精确匹配；
- 作者校验开关保持可选；
- 当前来源与当前详情 URL 完全相同的结果继续排除；
- 新搜索开始时清空上一代候选，迟到结果由搜索代次拒绝；
- 候选完成详情和完整目录预览后才允许确认。

没有启用书源时继续在整书换源页显示明确错误，不制造空成功。

## 7. 预计修改文件

业务代码：

- `lib/src/ui/book_info/book_info_screen.dart`
  - 修正主操作卡分支和文案；
  - 已入架网络书始终进入重新搜索整书换源；
  - 保留顶部已有候选切换。
- `lib/src/ui/reader/reader_menu_overlay.dart`
  - 更多菜单增加明确的“整书换源”；
  - 与“单章换源”并列。
- `lib/src/ui/reader/reader_view_model.dart`
  - 整书换源前增加书架成员校验；
  - 保存进度后再发送导航 Effect。
- `lib/src/ui/reader/reader_route.dart`
  - 补齐打开、取消、异常时的阅读系统生命周期恢复；
  - 成功后继续替换为新主键阅读路由。

文档：

- 本方案；
- `docs/flutter-rewrite/m11/change_source/01_android_behavior_inventory.md`
- `docs/flutter-rewrite/m11/change_source/02_mapping_and_design.md`
- `docs/flutter-rewrite/m11/change_source/03_acceptance_matrix.md`
- `docs/flutter-rewrite/m11/README.md`
- `docs/flutter-rewrite/AI_PROJECT_INDEX.md`

## 8. 数据、性能与内存

- 不新增数据库表或字段，不修改 Schema 版本和应用构建号；
- 不新增 MMKV 键或第三方依赖；
- 重新搜索继续使用最多 4 个 worker，不为书源数量创建无界 Future；
- 阅读器打开换源页时不保留新的章节副本，候选预览仍由换源页独占；
- 路由关闭会取消搜索和候选预览令牌；
- 取消换源后只恢复一个系统信息定时器，不重复创建；
- 换源成功用路由替换释放旧 Reader ViewModel、正文状态和滚动控制器。

## 9. 验收步骤

1. 从搜索打开一个包含多个已有来源的详情页，未加入书架时点击“已有书源”，确认仍可在现有候选间切换。
2. 把书加入书架后重新进入详情，点击“替换书源”，确认进入独立整书换源页并立即出现新的搜索进度，而不是只弹出原有候选。
3. 在整书换源页停止后重新搜索，确认旧结果不继续写入。
4. 阅读器打开更多菜单，确认同时出现“整书换源”和“单章换源”。
5. 阅读历史中未入架网络书点击“整书换源”，确认提示先加入书架，不进入失败页面。
6. 本地书点击整书换源，确认明确提示不支持；单章换源入口保持禁用。
7. 已入架网络书阅读到章节中间后打开整书换源再取消，确认返回原正文、沉浸模式、常亮、亮度、方向和音量键操作均恢复。
8. 从阅读器完成整书换源，确认当前阅读路由使用新 `bookUrl`，加载新目录和新来源正文。
9. 确认迁移后的章节优先匹配旧章节标题，字符位置尽量保留，旧书主键和旧目录不再存在。
10. 候选详情失败、目录为空或目标主键冲突时，确认书架和当前阅读器保持原来源。
11. 普通规则和 JavaScript 书源分别验收；单书源失败不能清空其他成功候选。

## 10. 实施快照

已写入以下实现，未运行构建、测试、分析、格式化或应用：

- 详情主操作卡已按“已入架网络书 / 未入架已有候选 / 本地书”分流；已入架网络书点击“替换书源”始终进入独立整书换源页并重新搜索；
- 阅读器更多菜单已增加“整书换源”，与“单章换源”并列，顶部交换图标继续保留；
- 阅读器 ViewModel 已在保存进度和导航前校验书籍属于书架，本地书与未入架网络书就地提示；
- 阅读器打开整书换源前停止低频系统信息定时器并退出阅读模式，取消或导航异常时恢复阅读显示配置、定时器和键盘/音量键焦点；
- 整书换源成功仍复用原有事务及 `pushReplacementNamed` 新主键路由替换。
