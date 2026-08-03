# 搜索结果进入详情的渐进加载与搜索暂停/继续设计

> 状态：`IMPLEMENTED / 代码已写入，等待用户运行验证`  
> 创建日期：2026-07-30  
> 范围：Flutter 搜索结果进入书籍详情时的首屏快照复用，以及详情/阅读期间的多书源搜索暂停与返回继续。

## 1. 用户目标

本次只解决两个直接相关的问题：

1. 用户点击搜索结果 cell 进入书籍详情时，立即使用该 cell 已有的书名、作者、来源、封面、简介、分类、
   字数、最新章节和目录 URL 等基础数据渲染详情页；搜索结果没有的字段暂时不显示，详情和目录继续异步
   请求，成功后在当前页面原位补齐，不能先展示全屏 loading。
2. 如果多书源搜索仍在进行，点击结果进入详情时暂停搜索；用户从详情或详情之上的阅读器等页面最终返回
   搜索页后，从原进度继续搜索，避免详情和阅读期间后台继续消耗 CPU。

本次不包含：

- 不改变搜索结果去重、分类、排序、失败重试和书源成功率规则。
- 不改变详情、目录解析规则，不新增网络客户端。
- 不把搜索结果写入书架或其他持久化表。
- 不改变数据库 Schema、MMKV key、`pubspec.yaml` 版本或平台通道。
- 不修改只读 Android 参考仓库。

## 2. 当前 Flutter 事实

### 2.1 搜索结果数据已经随路由传入详情

当前调用链：

```text
SearchScreen cell
  -> OpenSearchResultIntent(group, group.primary)
  -> SearchViewModel
  -> OpenBookInfoEffect(group, book)
  -> SearchRoute
  -> BookInfoRouteArguments(group, selectedBook)
  -> BookInfoViewModel
```

`SearchBook` 已经包含详情首屏可直接使用的基础字段：

- `bookUrl`
- `origin` / `originName`
- `name` / `author`
- `type` / `kind`
- `coverUrl`
- `intro`
- `wordCount`
- `latestChapterTitle`
- `tocUrl`
- `variable` / `originOrder`

而且 `SearchBook.toBook(createdAt:)` 已经提供明确的临时 `Book` 转换边界。因此本次无需新增路由 DTO，
也无需复制字段；缺口只是 `BookInfoViewModel` 初始状态没有消费 `selectedBook`，仍以 `book == null` 和
`loadingInfo == true` 开始。

### 2.2 全屏 loading 的直接原因

`BookInfoUiState` 当前初始 `book` 为空，`_BookInfoBody` 又在 `loadingInfo` 为 true 时优先返回
`CircularProgressIndicator`。虽然 `_loadDetails()` 已经支持：

- 命中本地书架数据时立即展示并后台静默刷新；
- 换源时保留旧详情内容，只局部显示进行中状态；
- 网络结果通过请求世代隔离，避免旧请求覆盖新来源；

但“从搜索结果首次进入详情”没有任何可见快照，所以仍走全屏 loading 分支。

### 2.3 搜索当前只有取消，没有暂停

`BookSearchCoordinator` 当前固定最多 4 个 worker。每个 worker 领取一个书源，创建独立 HTTP
取消令牌并完成搜索；`BookSearchRun.cancel()` 会：

- 标记整次运行取消；
- 取消全部当前网络令牌；
- 阻止后续书源继续领取；
- 让 ViewModel 通过运行编号拒绝晚到回调。

该取消是终止语义，不能继续。`SearchViewModel` 的手动停止也会递增运行编号，并把状态标记为
`cancelled`。因此详情返回后若直接复用现有取消逻辑，只能重新搜索全部来源，既重复请求，也无法保持
准确进度。

### 2.4 路由返回不能只依赖 `pushNamed()` Future

详情页完整换源会使用 `pushReplacementNamed()` 替换当前详情路由。若搜索页只在最初
`pushNamed(AppRoute.bookInfo)` 的 Future 完成时恢复搜索，旧详情被替换时该 Future 可能提前完成，
导致新的详情页仍可见时搜索已经恢复。

搜索页需要基于“搜索所在路由重新成为当前可见路由”恢复，而不是基于某一个详情路由对象是否完成。

## 3. Android 参考行为

已核对只读 Android 参考：

| 职责 | Android 文件 | 当前行为 |
|---|---|---|
| 搜索暂停/继续 Intent | `ui/book/search/SearchContract.kt` | 定义 `PauseEngine`、`ResumeEngine`。 |
| 搜索页面生命周期 | `ui/book/search/SearchScreen.kt` | Activity `ON_PAUSE`、组合离开时暂停；重新进入组合和 `ON_RESUME` 时继续。 |
| 搜索运行控制 | `domain/usecase/SearchBooksUseCase.kt` | `BookSearchControl.awaitResumed()` 在书源执行前等待，不丢失结果集合。 |
| 搜索 ViewModel | `ui/book/search/SearchViewModel.kt` | 记录离开前是否仍在搜索，返回后恢复控制；必要时继续搜索。 |
| 搜索到详情参数 | `ui/book/search/SearchActivity.kt`、`ui/main/MainIntent.kt` | 携带书名、作者、详情 URL、来源和封面。 |
| 详情初始快照 | `ui/book/info/BookInfoViewModel.kt` | 路由存在书名、作者时立即构造临时 `Book`，再异步查询数据库和网络详情。 |

Flutter 本次应保持相同业务目标，同时利用现有 `SearchBook` 中比 Android Intent 更完整的基础字段。

Android 的 `BookSearchControl` 只阻止新书源开始，已进入网络/解析的书源允许自然结束。为更严格满足本次
“进入详情后不在后台继续消耗 CPU”的要求，Flutter 推荐在暂停时同时取消最多 4 个正在执行的单源令牌，
但不把它们记为完成或失败；返回后只重试这些被暂停打断的来源，再继续尚未领取的队列。

## 4. 推荐状态机

### 4.1 搜索运行状态

```text
running
  -> 点击搜索结果
pausedForBookInfo
  -> 搜索路由重新可见
running

running / pausedForBookInfo
  -> 用户停止、新搜索、屏蔽规则变化、页面销毁
cancelled

running
  -> 所有来源完成
completed
```

约束：

- `pausedForBookInfo` 不是用户手动停止，不能设置现有 `cancelled = true`。
- 暂停期间不改变已合并结果、失败列表、书源总数和已完成计数。
- 暂停打断的来源不计成功、不计失败、不调整书源分数。
- 恢复时不重新执行已经成功或失败结束的来源。
- 同一来源在暂停前已产出完整结果并完成进度上报时，不得重复执行。
- 新搜索、手动停止、成人内容规则变化和 ViewModel 销毁仍使用永久取消语义。

### 4.2 详情渐进加载状态

```text
SearchBook 基础快照
  -> 立即渲染详情壳和已有字段
  -> 异步查本地书架/目录
  -> 异步加载远端详情
  -> 异步加载完整目录
  -> 原位补齐字段和目录
```

展示规则：

- 书名、作者、来源和搜索结果封面立即显示。
- 搜索结果已有的简介、分类、字数、最新章节直接显示。
- 搜索结果缺失且网络尚未返回的字段不显示“暂无”，避免把“尚未加载”误写成“确实没有”。
- 首次详情请求只显示轻量局部进度，不替换整个页面。
- 详情成功后在同一个 `ListView` 中更新数据，不使用全屏 `AnimatedSwitcher`、闪白或清空旧数据。
- 目录未开始加载时不提前显示“暂无目录”；开始后在目录卡局部显示进度。
- 详情失败时保留搜索快照，并显示可恢复的内联错误与重试入口。
- 目录失败时继续保留详情和基础数据，只在目录区域显示错误。

## 5. 搜索暂停/继续实现设计

### 5.1 `BookSearchRun` 增加可继续暂停

在现有运行句柄内维护：

- 是否永久取消；
- 是否因详情导航暂停；
- 一个只在暂停期存在的恢复 `Completer`；
- 当前活动 HTTP 令牌集合；
- worker 当前持有但尚未完成的来源。

worker 执行原则：

1. 领取新来源前等待恢复门。
2. 暂停时先关闭恢复门，再取消活动令牌。
3. 因暂停取消的当前来源保留在对应 worker 中，不增加 `completed/failed`。
4. 返回后打开恢复门，worker 重试该来源；完成后再领取后续来源。
5. 永久取消时同时打开等待门，使所有暂停中的 worker 可以退出，避免 Future 和 ViewModel 泄漏。

这样最多保留 4 个 worker Future、4 个当前来源引用和一个来源列表快照，不创建按书源数量增长的
Future，也不引入 Timer、Stream 或额外 isolate。

### 5.2 `SearchViewModel` 区分暂停与停止

建议在 `SearchUiState` 增加明确的 `pausedForBookInfo`：

- 点击结果时，若 `_run` 仍活动，则调用 `pauseForBookInfo()`；
- 保持同一次搜索运行语义并设置 `pausedForBookInfo`，保留全部结果和进度；
- 然后发出 `OpenBookInfoEffect`；
- 搜索路由真正重新可见时发送 `ResumeSearchAfterBookInfoIntent`；
- 若运行已在点击前完成，暂停和恢复均为空操作；
- `run.completion` 完成后及时清空 `_run`，避免对已完成句柄误执行暂停。

暂停不递增 `_generation`，因为恢复后的同一次运行仍应继续合并结果。永久取消仍递增或替换运行代次，
继续拒绝旧回调。

### 5.3 路由可见性

复用并扩展现有 `AppNavigationObserver`：

- 使其同时提供稳定 `RouteObserver` 能力；
- 在 `PageNestApp` State 生命周期内只创建一次，避免每次 build 替换观察器；
- 由 `AppRouter`、`WelcomeRoute` 把同一实例传给独立和内嵌两种 `SearchRoute`；
- `SearchRoute` 只在“本次确实因打开书籍详情而暂停”时等待 `didPopNext` 恢复；
- 普通对话框、验证码、书源登录和其他路由不会误触发详情暂停；
- 详情内部 `pushReplacement` 后仍保持暂停，直到搜索所在路由重新成为当前路由；
- 导航创建失败时立即恢复，避免搜索永久卡在暂停态。

该观察器只管理导航可见性，不进入 ViewModel、Domain 或 Model 层。

## 6. 详情首屏实现设计

### 6.1 初始状态

`BookInfoViewModel` 构造时用：

```text
arguments.selectedBook.toBook(createdAt: 当前毫秒)
```

建立仅用于当前页面内存展示的初始 `Book`。该对象：

- 不写 SQLite；
- 不表示已经加入书架；
- 不替代网络详情事实；
- 继续由本地书架命中或远端详情结果覆盖/合并。

### 6.2 避免误判“已有完整详情”

现有 `_loadDetails()` 通过 `state.book != null` 判断是否有旧内容。加入搜索快照后，这个条件不再足够：

- 搜索快照是“可见基础数据”，不是“已经成功解析的详情”；
- 初始请求必须保持 `loadingInfo` 语义，但不能清空 `book`；
- 真正换源时才使用 `switchingSource` 并保留上一个完整详情。

因此需要显式区分“搜索预览快照”和“已解析详情”，不能仅凭 `book` 是否为空推断。

### 6.3 无闪刷新

- `_BookInfoBody` 仅在路由确实没有任何可展示 `Book` 时使用全屏错误/加载兜底。
- 有搜索快照时始终保持同一个详情 `ListView`。
- 新字段到达后只更新对应文本、标签、操作状态和目录区。
- 不先把 `book` 置空，也不在详情请求开始时清空搜索快照。
- 如果详情解析返回了不同封面地址，详情页封面保留旧帧，待新封面首帧成功解码后替换；只在过渡期间
  短暂持有两张封面解码结果，失败时继续保留已有可用封面或走现有缓存回退。

## 7. 计划修改范围

| 文件 | 计划改动 |
|---|---|
| `lib/src/model/web_book/book_search_coordinator.dart` | 为 `BookSearchRun` 和固定 worker 增加暂停、恢复、暂停取消后的当前来源重试与资源释放。 |
| `lib/src/ui/search/search_contract.dart` | 增加详情导航暂停状态和返回继续 Intent。 |
| `lib/src/ui/search/search_view_model.dart` | 点击结果前暂停活动运行，返回后恢复；完成时清理运行句柄；保持运行代次和进度。 |
| `lib/src/ui/search/search_route.dart` | 订阅稳定路由观察器，在搜索路由真正重新可见时继续搜索，并处理导航失败。 |
| `lib/src/app/app_navigation_observer.dart` | 在保留现有导航日志的同时提供 RouteAware 订阅能力。 |
| `lib/src/app/pagenest_app.dart` | 在 State 生命周期内持有唯一导航观察器。 |
| `lib/src/app/app_router.dart` | 把导航观察器传到独立搜索页和主框架。 |
| `lib/src/ui/home/welcome_route.dart` | 把同一导航观察器传给内嵌搜索页。 |
| `lib/src/ui/book_info/book_info_contract.dart` | 让初始状态明确携带搜索快照及其未完成语义。 |
| `lib/src/ui/book_info/book_info_view_model.dart` | 使用 `SearchBook.toBook()` 初始化可见数据，异步结果原位合并且不清空预览。 |
| `lib/src/ui/book_info/book_info_screen.dart` | 移除有基础快照时的全屏 loading；缺失字段加载期间不显示；增加局部进度和内联错误。 |
| `lib/src/ui/components/book_cover.dart` | 为详情封面提供可选的旧帧保持，避免封面 URL 更新时闪空；默认不改变其他页面语义。 |
| `docs/flutter-rewrite/m06/README.md` | 已登记代码状态和待用户验收项。 |
| `docs/flutter-rewrite/AI_PROJECT_INDEX.md` | 已更新搜索、详情和导航生命周期索引。 |

实现前应再次检查这些文件的工作区差异；当前 `search_view_model.dart`、`welcome_route.dart`、
`app_dependencies.dart` 和 `AI_PROJECT_INDEX.md` 已存在用户其他任务的未提交修改，必须在其基础上做
最小补丁，不得覆盖。

## 8. 性能与内存边界

- 搜索并发仍保持现有最大 4，不增加 worker。
- 暂停期间没有轮询和 Timer；worker 只等待一个共享恢复 Future。
- 当前活动 HTTP/JS 执行通过既有取消令牌释放，暂停取消不计书源失败。
- 详情首屏复用现有不可变 `SearchBook`/`Book`，不新增数据库读写或图片字节复制。
- 路由参数只持有领域模型，不持有 Widget、`BuildContext`、RenderObject、Controller 或 Stream。
- `RouteObserver` 订阅必须在 `dispose` 中解除。
- 暂停中的运行在新搜索、规则变化、账号切换或页面销毁时必须永久取消并唤醒退出。
- 封面无闪替换最多临时保留旧、新两张当前详情封面，完成或失败后释放旧引用，不建立新的全局图片缓存。

## 9. 边界与异常路径

1. 点击结果时搜索已经完成：直接进入详情，不创建暂停状态。
2. 快速重复点击 cell：只允许一个详情导航单飞。
3. 详情路由参数校验失败或导航抛错：恢复原搜索并给出受控提示。
4. 详情内换源替换路由：搜索保持暂停，直到最终回到搜索页。
5. 从详情进入阅读器：搜索继续暂停；只有阅读器和详情都退出、搜索页重新可见时才恢复。
6. 暂停期间成人内容规则变化：永久取消旧快照并按现有规则清空/刷新，不恢复旧任务。
7. 暂停期间账号切换或搜索页销毁：永久取消并释放所有 worker、令牌和观察器订阅。
8. 被暂停的单源原本需要登录/验证码：取消当前交互；返回后重试该来源时按现有交互策略重新请求，
   不保留已失效的 UI 上下文。
9. 详情请求失败：保留 cell 基础数据；只有远端字段和目录显示错误，不退回全屏 loading。
10. 搜索快照没有封面/简介/分类等字段：加载期间不显示对应区块；请求完成后仍为空才按现有产品文案
    决定显示“暂无”。

## 10. 用户验收建议

AI 不运行 build、test、analyze、lint、format、网络请求或应用启动。实现后由用户验证：

1. 使用多个响应较慢的书源开始搜索，出现首个结果后立即点击 cell。
2. 详情首帧应立即显示该 cell 的书名、作者、来源和已有封面，不出现全屏 loading。
3. 搜索结果没有的简介、分类、字数或目录在加载期间不应显示伪造的“暂无”。
4. 详情和目录返回后只原位补齐内容，页面不闪白、不切回全屏 loading，已有封面不闪空。
5. 在详情停留 30 秒并进入阅读器，观察搜索进度不再增长，CPU 不应继续被多书源搜索持续占用。
6. 从阅读器返回详情时搜索仍暂停；从详情最终返回搜索页后，搜索从旧进度继续。
7. 已完成的来源不重复执行；被暂停打断的最多 4 个来源可以在恢复后重试，且不产生取消失败记录。
8. 返回后结果继续增量合并，旧结果、失败摘要、分类页和滚动位置保持。
9. 搜索完成后再打开详情并返回，不应错误显示暂停或重新搜索。
10. 在详情内执行整书换源导致路由替换，再返回搜索页，确认搜索只在真正返回时恢复。
11. 搜索暂停期间切换账号、修改成人内容规则或关闭页面，确认旧任务不会恢复或污染新状态。

## 11. 完成判断

当前代码已按本设计写入，但未运行 build、test、analyze、lint、format、网络请求或应用。只有用户完成
上述真机验收后，才能把本专项从 `IMPLEMENTED / 实现待验证` 更新为已验证状态。
