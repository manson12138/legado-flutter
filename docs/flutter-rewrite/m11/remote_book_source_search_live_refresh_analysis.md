# 云端书源同步后搜索页实时感知分析

状态：`IMPLEMENTED_PENDING_USER_VERIFICATION / 代码已写入，等待用户运行验收`

日期：2026-07-25

## 1. 目标与边界

唯一目标：云端书源同步批次成功落库后，已在主页 `IndexedStack` 中保活的搜索页无需杀死 App，即可感知最新启用书源，并让下一次搜索使用最新书源集合。

本次包含：

- 复用现有 `book_sources` 表级变更通知；
- 为搜索协调器提供启用且可见书源的观察流；
- 搜索 ViewModel 在生命周期内订阅书源变化并更新筛选快照；
- 书源删除、启停、编辑、手动导入和云端同步统一触发同一刷新链路；
- 页面销毁时释放订阅，避免流订阅和 ViewModel 泄漏。

本次不包含：

- 修改云端游标同步协议、断点或导入事务；
- 修改 `book_sources` 表结构或数据库 Schema；
- 在同步完成后通过全局事件总线强制重建搜索页；
- 中断已经开始的搜索任务并临时加入新同步的书源；
- 修改 Android 参考工程。

## 2. 已定位根因

当前写入链路本身完整：

```text
RemoteBookSourceSyncService
  -> ImportBookSourcesUseCase
  -> BookSourceRepository.importSourceJson
  -> BookSourceDao.upsert（事务）
  -> DatabaseChangeNotifier.notifyTables(book_sources)
```

`BookSourceRepository.importSourceJson` 会在新增或覆盖书源后发布 `book_sources` 变更，`BookSourceDao.watchAll()` 也会在收到表级通知后重新查询，因此数据层已经具备实时观察能力。

缺口位于搜索页：

```text
SearchViewModel 构造
  -> _initialize()
  -> BookSearchCoordinator.loadEnabledSources()
  -> BookSourceGateway.getEnabled()
  -> 只读取一次快照
```

搜索页当前只额外订阅成人内容规则修订，没有订阅 `BookSourceGateway.watchAll()`。主页通过 `WelcomeScreen` 的 `IndexedStack` 保留搜索页状态，切到书源页同步再返回时，原 `SearchViewModel` 不会销毁和重建，因此仍持有同步前的 `sources`。杀死 App 后 ViewModel 重新创建，才会再次读取数据库，所以表现为“必须杀 App 才知道有书源”。

这不是云端同步未落库，也不需要增加同步完成回调或修改数据库 Schema。

## 3. Android 对照

原 Android 搜索页：

- `ui/book/search/SearchViewModel.kt` 在初始化时调用 `observeEnabledSources()`；
- `observeEnabledSources()` 持续收集 `repository.enabledSources`，每次 Room Flow 更新都会写入搜索 UiState；
- `data/dao/BookSourceDao.kt` 提供 `flowEnabled()`，书源表变化后由 Room 自动重新发射；
- `SearchScope.getBookSourceParts()` 在实际搜索开始时再次从 DAO 读取当前启用书源。

Flutter 应保持相同的可观察语义：页面展示持续跟随启用书源变化，而每次已开始的搜索仍使用启动时固定快照，避免运行中任务规模突变。

## 4. 实施方案

### 4.1 搜索协调器

在 `BookSearchCoordinator` 增加启用书源观察入口：

```text
BookSourceGateway.watchAll()
  -> 仅保留 enabled=true
  -> 执行成人内容可见性过滤
  -> 输出不可变 List<BookSource>
```

该入口只组合既有 Gateway 和屏蔽策略，不访问 DAO，也不把数据库类型暴露给 UI。

### 4.2 搜索 ViewModel

`SearchViewModel` 在构造期订阅协调器的启用书源流：

- 首次发射结束 `loadingSources`；
- 后续发射立即替换 `state.sources`；
- 显式选择集合与最新可见 URL 求交集，删除已停用、已删除或被屏蔽的选择；
- 当前分组已不存在时清除分组条件；
- `useAllSources=true` 时自动包含新同步且启用的书源；
- 不清空关键词、历史和已有搜索结果；
- 不取消正在运行的搜索，当前运行继续使用启动时固定书源快照，下一次搜索使用新列表。

历史和匹配方式初始化继续独立执行，避免书源观察失败阻断搜索历史恢复。

### 4.3 生命周期、性能与内存

- ViewModel 只维持一个书源流订阅，在 `dispose()` 中取消；
- 不创建轮询、定时器或第二套事件总线；
- 复用 `DatabaseChangeNotifier` 的表级通知，数据库无变化时没有额外查询；
- 书源成功率更新也可能触发 `book_sources` 通知，后续实现应避免并发刷新覆盖，并保持流串行处理；
- 当前搜索任务不因评分或同步批次变化重启，避免重复网络请求和结果抖动；
- 同步每批提交后允许搜索页逐批刷新，最终批次无需额外手动通知。

## 5. 预计修改文件

| 文件 | 修改 |
|---|---|
| `lib/src/model/web_book/book_search_coordinator.dart` | 暴露启用且可见书源观察流，复用既有成人内容过滤。 |
| `lib/src/ui/search/search_view_model.dart` | 订阅书源变化、维护选择有效性并在销毁时取消订阅。 |
| `docs/flutter-rewrite/AI_PROJECT_INDEX.md` | 登记本分析与搜索页实时书源刷新链路。 |
| 本文 | 记录根因、边界、Android 对照和用户验收。 |

不需要修改 `RemoteBookSourceSyncService`、`BookSourceRepository`、数据库 Schema、`pubspec.yaml` 或平台宿主。

## 6. 用户验收

1. 启动 App 并进入一次搜索页，确认当前无可用书源或记录当前数量。
2. 不杀 App，切到书源页执行云端同步。
3. 同步完成后返回搜索页，打开书源选择面板，应立即看到新同步且启用、未被屏蔽的文字书源。
4. 输入关键词搜索，进度总数和实际调度书源应包含新书源。
5. 在书源页停用或删除一个书源，返回搜索页后该书源应立即从候选和显式选择中移除。
6. 搜索进行中再同步书源：当前搜索不重启、不插入新 worker；下一次搜索使用最新书源。
7. 多次切换搜索页和书源页后，不应出现重复刷新、重复搜索、页面销毁后更新或异常提示。

## 7. 状态判断

搜索协调器的启用书源观察流和搜索 ViewModel 生命周期订阅已经写入。同步、手动导入、编辑、启停或删除书源后，搜索页会基于现有 `book_sources` 表级通知更新候选；正在运行的搜索仍使用启动时快照。

未运行构建、测试、分析、格式化或 App，最终结果等待用户按第 6 节验收。
