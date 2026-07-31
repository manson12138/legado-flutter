# 搜索命中书源候选持久化与详情入口只读恢复设计

> 状态：`PROPOSED / 等待用户确认执行`  
> 创建日期：2026-07-30  
> 范围：搜索结果 Cell 携带的同名同作者书源候选覆盖持久化，以及书架、阅读器、下载管理等非搜索入口打开详情时的本地候选恢复。

## 1. 用户确认的业务语义

同一本搜索结果会聚合多个匹配书源，详情页当前已经可以使用
`BookSearchResultGroup.books` 显示来源数量并在这些来源之间切换。本次需要把这组内存数据变成稳定的
本地事实：

1. 只有用户从搜索页面点击结果 Cell 时，才使用该 Cell 当时携带的完整候选组覆盖本地持久化数据。
2. 覆盖是整组替换，不是追加：新快照中已经不存在的旧来源必须同时删除。
3. 从搜索进入详情时继续直接使用路由携带的候选组，不为了读取数据库延迟首屏或先显示错误来源数量。
4. 从书架、阅读器、下载管理、详情换源后的新详情或其他入口进入时，不允许用这些入口临时构造的
   单来源组覆盖本地数据。
5. 非搜索入口每次创建详情页时，先按书名和作者读取本地候选；存在多个来源时恢复来源数量和切换能力。
6. 本地没有候选记录时，才退化为入口当前书籍对应的单来源组。
7. 搜索点击之后后台继续返回的新来源不自动改写本地；只有用户之后再次点击该结果 Cell，才用新的
   点击时快照再次整组覆盖。

本次不改变：

- 不改变搜索结果严格“书名 + 作者”分组、排序和去重规则。
- 不自动执行整书换源，不改变当前书籍主来源、书架记录、目录或阅读进度。
- 不让书架、阅读器、下载管理或详情页自身写入候选快照。
- 不把候选列表存入 MMKV、通用偏好或安全存储。
- 不修改只读 Android 参考仓库。

## 2. 当前 Flutter 事实

### 2.1 内存候选已经完整

当前调用链为：

```text
SearchViewModel._merge()
  -> BookSearchResultGroup.books
  -> OpenBookInfoEffect(group, selectedBook)
  -> BookInfoRouteArguments(group, selectedBook)
  -> BookInfoUiState.group
  -> 详情页显示“X 个来源可选”并允许切换
```

搜索 Cell 点击时已经持有用户所说的“匹配到了多少个书源”的完整快照，不需要重新搜索，也不应在详情
页用书名作者再次联网获取。

### 2.2 非搜索入口目前只构造一个来源

以下入口都会把当前 `Book` 转成一个 `SearchBook`，再构造仅含一项的
`BookSearchResultGroup`：

| 入口 | 当前 Flutter 文件 | 当前结果 |
|---|---|---|
| 书架详情 | `lib/src/ui/bookshelf/bookshelf_route.dart` | 只有书架当前来源 |
| 阅读器顶部详情 | `lib/src/ui/reader/reader_route.dart` | 只有阅读中的当前来源 |
| 下载管理详情 | `lib/src/ui/download_management/download_management_route.dart` | 只有下载书籍当前来源 |
| 整书换源后的替换详情 | `lib/src/ui/book_info/book_info_route.dart` | 只有换源后的新来源 |

所以这些入口即使此前搜索到过多个来源，重新打开详情后也会退化为一个来源。

### 2.3 现有 `searchBooks` 不足以作为精确长期候选组

Flutter 数据库已有 Android 对应的 `searchBooks` 表和 `SearchBookDao`，但当前没有业务调用写入。该表：

- 以 `bookUrl` 为唯一主键；
- 面向 Android 临时搜索缓存语义；
- 无候选组内稳定顺序字段；
- 无法同时保存“两个不同书源返回相同 `bookUrl`”的候选。

本次核心验收是来源数量与切换列表必须准确。若直接复用 `searchBooks`，相同详情 URL 的不同来源会发生
覆盖，持久化后的来源数量可能少于搜索 Cell 当时显示的数量。因此不能把该表直接改作本次精确候选组。

## 3. Android 参考与本次差异

已核对只读 Android 参考：

- `data/entities/SearchBook.kt`
- `data/dao/SearchBookDao.kt`
- `data/repository/SearchRepository.kt`
- `ui/book/info/BookInfoViewModel.kt`
- `App.kt`

Android 会在搜索过程中写入 `searchBooks`，并可在详情或换源路径读取；默认还可能清理一天前的搜索
缓存。用户本次明确要求的是：

- 只在点击搜索结果 Cell 时覆盖；
- 其他详情入口只读；
- 后续再次进入详情仍能恢复该候选组。

因此 Flutter 不能照搬 Android 的“搜索过程持续写入 + 自动过期”策略。用户本次确认的入口边界优先于
Android 临时缓存行为。

## 4. 持久化选型

### 4.1 选择 SQLite

候选来源是一个需要按书籍身份查询、整组事务替换、随书源删除级联失效的关系列表，因此选择 SQLite：

- 需要按严格书名和作者查询；
- 一本书对应多条候选；
- 覆盖时必须在一个事务内“删除旧组 + 写入新组”；
- 书源删除后对应候选应通过外键清理；
- 数据量随用户点击过的书籍增长，不适合 MMKV 高频小偏好语义。

不选择：

- MMKV：不是独立小型偏好，存在一对多关系和事务替换。
- `caches` 通用表：JSON 整组写入会丢失关系约束、来源级级联和可查询性。
- Keychain/Keystore：候选不包含凭据，不属于安全存储。

### 4.2 作用域与生命周期

- 作用域：设备级。书源本身是设备级配置，同一安装内游客和登录账号共享候选来源事实。
- 覆盖键：严格 `(name, author)`，与当前搜索分组语义一致。
- 行唯一键：`(name, author, origin, bookUrl)`，确保相同详情 URL 的不同书源仍分别计数。
- 写入时机：只在 `OpenSearchResultIntent` 对应的搜索 Cell 点击链路。
- 删除时机：
  - 同一本书下一次搜索 Cell 点击时整组覆盖；
  - 书源被删除时通过 `origin` 外键级联删除对应候选；
  - 本次不添加自动过期，不使用 Android 一天清理策略。
- 账号切换：不清除、不复制、不迁移。
- 隐私：只保存书籍公开元数据和书源标识；禁止保存 Cookie、Authorization、账号、正文和脚本交互数据。

## 5. 新表设计

新增 `book_source_candidates` 表，保存重建 `SearchBook` 和保持候选顺序所需的字段：

```text
name
author
origin
bookUrl
originName
type
kind
coverUrl
intro
wordCount
latestChapterTitle
tocUrl
time
variable
originOrder
chapterWordCountText
chapterWordCount
respondTime
sourceScore
pinned
candidateOrder
capturedAt
```

约束与索引：

- 主键：`(name, author, origin, bookUrl)`。
- 外键：`origin -> book_sources.bookSourceUrl ON DELETE CASCADE`。
- 查询索引：`(name, author, candidateOrder)`。
- 来源索引：`origin`。
- `candidateOrder` 保存 Cell 点击时 `BookSearchResultGroup.books` 的准确顺序。
- `capturedAt` 只记录快照时间，当前不用于自动清理。

这是 Schema 变化：

- `LegadoDatabase.schemaVersion` 从 `9` 增加到 `10`。
- 新安装的基础 Schema 创建该表。
- `onUpgrade` 增加 `if (oldVersion < 10)` 创建表和索引。
- `pubspec.yaml` build number 从 `+10` 增加到 `+11`。
- 旧版本没有等价的点击候选快照，不从未接线的 `searchBooks` 猜测迁移；升级后从下一次搜索 Cell 点击开始建立事实。

## 6. 分层设计

### 6.1 Data

新增 `BookSourceCandidateDao`：

- `loadByNameAuthor(name, author)`：按 `candidateOrder` 读取完整候选组。
- `replaceByNameAuthor(name, author, books)`：在一个数据库事务中删除旧组并按列表顺序写入新组。
- 输入为空或候选中存在不同书名作者时拒绝写入，避免误删其他分组。

新增 `BookSourceCandidateRepository`，负责：

- 将 sqflite 异常转换为项目数据错误；
- 返回不可变 `SearchBook` 列表；
- 对写入组执行一致性校验；
- 不向 ViewModel 暴露 DAO、Database 或 Map。

### 6.2 Domain

新增 `BookSourceCandidateGateway`：

```text
load(name, author) -> List<SearchBook>
replaceFromSearch(books) -> void
```

不机械增加空转 UseCase：读取和整组覆盖本身已经是清晰、单一的领域边界，没有额外跨仓储事务。

### 6.3 组合根

`AppDependencies` 创建 DAO、Repository，并把同一 Gateway 注入：

- `SearchViewModel`：唯一写入方。
- `BookInfoViewModel`：只读恢复方。

Widget、Route 和 Screen 不直接访问数据库。

## 7. 搜索入口：唯一覆盖写入方

`OpenSearchResultIntent` 调整为：

```text
点击 Cell
  -> 暂停仍在运行的搜索
  -> 原子覆盖该书名作者的本地候选组
  -> 发出 OpenBookInfoEffect
  -> 路由继续携带原 group 和 selectedBook
```

行为约束：

- 搜索传入的候选组立即作为详情首屏来源事实，不再读旧本地组覆盖它。
- SQLite 覆盖在导航 Effect 前完成，使成功导航时本地快照已经提交。
- 写入失败不阻断查看详情：记录统一日志、展示一次受控提示，仍使用本次路由候选进入详情。
- 写入失败时旧本地组保持不变，因为删除与插入位于同一事务。
- 快速重复点击继续使用单飞保护，避免同组重复事务和重复路由。
- 搜索恢复规则保持上一专项设计：详情及阅读链路最终退出、搜索页真正可见后才恢复。

`BookInfoRouteArguments` 增加明确的 `sourceCandidatesFromSearch`，默认 `false`，只有
`SearchRoute` 创建参数时设为 `true`。不能使用 `analyticsEntry == 'search'` 推断业务写入语义，避免埋点
字段意外控制持久化。

## 8. 非搜索入口：只读恢复

`BookInfoViewModel` 初始化分为两条：

### 8.1 搜索入口

- `sourceCandidatesFromSearch == true`。
- 初始状态直接使用路由候选组，来源数量和切换入口首帧可见。
- 不再查询旧本地候选。
- 按上一专项继续异步加载详情与目录。

### 8.2 书架、阅读器及其他入口

- `sourceCandidatesFromSearch == false`。
- 先按当前书籍严格 `name + author` 读取本地候选，再启动详情网络请求。
- 读取成功后把 `BookInfoUiState.group` 更新为本地候选组。
- 如果本地组包含当前 `origin + bookUrl`，用入口携带的当前书籍快照替换该项的旧元数据，但不写数据库。
- 如果本地组不包含当前来源，把当前来源只加入本次内存组，确保详情当前书籍仍可用；不反向写入本地。
- 本地无记录或读取失败时退化为入口单来源组，详情和目录仍继续加载。
- 本地书 `origin == 'loc_book'` 不读取网络书源候选，保持本地单来源语义。

这样书架、阅读器、下载管理和换源替换详情都不需要分别增加写入代码；它们保持现有默认路由参数，就会
统一走只读恢复。

## 9. 避免来源数量闪烁

`BookInfoUiState` 增加 `loadingSourceCandidates`：

- 搜索入口为 `false`，直接展示搜索 Cell 的准确来源数量。
- 非搜索入口初始为 `true`，在本地查询完成前不显示“只有 1 个来源”的错误中间态。
- 详情主操作卡在读取期间显示轻量“正在读取本地书源”状态。
- 本地结果发布后一次性显示最终来源数量和切换入口。
- 书名、作者、封面等详情快照继续可见，不恢复全屏 loading。

候选列表通常只有少量行，本地查询只返回当前书名作者的数据，不加载整张候选表到内存。

## 10. 计划修改范围

| 文件 | 计划改动 |
|---|---|
| `lib/src/data/local/legado_database.dart` | Schema v10 新表、索引和升级分支。 |
| `lib/src/data/local/database_tables.dart` | 登记候选表稳定名称。 |
| `lib/src/data/local/entity_maps.dart` | `SearchBook` 候选行的安全映射。 |
| `lib/src/data/dao/book_source_candidate_dao.dart` | 新增精确查询和事务整组覆盖 DAO。 |
| `lib/src/domain/gateway/book_source_candidate_gateway.dart` | 新增候选读写领域边界。 |
| `lib/src/data/repository/book_source_candidate_repository.dart` | 新增数据错误转换和一致性校验。 |
| `lib/src/app/app_dependencies.dart` | 创建并注入候选 Gateway。 |
| `lib/src/ui/search/search_view_model.dart` | 搜索 Cell 点击时唯一执行整组覆盖，再导航。 |
| `lib/src/ui/book_info/book_info_contract.dart` | 路由来源标记、可变候选组和本地读取状态。 |
| `lib/src/ui/book_info/book_info_view_model.dart` | 搜索入口使用路由组；其他入口先读本地且永不覆盖。 |
| `lib/src/ui/book_info/book_info_screen.dart` | 候选读取期间隐藏错误单来源计数，完成后原位显示。 |
| `pubspec.yaml` | Schema 变化联动 build number `+10 -> +11`。 |
| `docs/flutter-rewrite/m06/README.md` | 实施后登记状态和用户验收。 |
| `docs/flutter-rewrite/AI_PROJECT_INDEX.md` | 实施后登记新持久化边界和 Schema 版本。 |

现有书架、阅读器、下载管理和详情换源后的路由构造不设置搜索来源标记，因此默认只读；除非实施时发现
现有参数注释需要澄清，否则无需逐入口修改业务逻辑。

## 11. 性能、内存与并发

- 每次详情只查询一个严格书名作者组，不扫描或反序列化全部候选。
- 搜索点击只执行一个短 SQLite 事务；删除和批量插入原子提交。
- 不新增 Stream、Timer、isolate、长期 Future 或全局内存缓存。
- UiState 继续持有当前组的不可变列表，详情销毁后由 ViewModel 一并释放。
- 搜索快速重复点击使用单飞状态，避免并发覆盖顺序反转。
- SQLite 写入失败保留旧组，不出现“旧组已删、新组未写”的中间状态。
- 表通过书名作者索引控制读取成本，通过书源外键避免悬空来源。

## 12. 边界与异常

1. 搜索结果只有一个来源：仍覆盖本地旧组，旧的多来源必须被删除。
2. 点击时搜索尚未结束：保存点击瞬间的组；之后新返回来源不静默改变本地。
3. 同一书源返回重复候选：沿用搜索 ViewModel 当前去重结果，DAO 再依靠复合主键兜底。
4. 不同来源返回相同 `bookUrl`：复合主键分别保存，来源数量不减少。
5. 后续删除某书源：外键级联移除该来源候选；其余候选保留。
6. 当前书架来源不在旧候选组：只在本次详情内存组中补入当前来源，不覆盖数据库。
7. 本地候选读取失败：保留当前入口单来源并继续详情请求，提示候选恢复失败。
8. 搜索候选写入失败：仍打开详情并使用本次内存组；下次非搜索进入仍读取上一次成功快照。
9. 书名或作者为空：不执行候选持久化查询或覆盖，保持入口单来源，避免空身份误合并。
10. 本地书：不读取或写入网络书源候选。

## 13. 用户验收建议

AI 不运行 build、test、analyze、lint、format、数据库检查或应用启动。实施后由用户验证：

1. 搜索一本命中多个来源的书，记住 Cell 和详情显示的来源数量。
2. 点击 Cell 进入详情，确认首帧立即显示同样数量，并可切换每个来源。
3. 返回搜索、等待更多来源完成后，不再次点击该 Cell；从书架或阅读器进入详情，确认仍是第一次点击时的快照。
4. 再次从搜索点击同一本书，确认本地组被本次完整来源集合覆盖。
5. 使用只命中一个来源的新搜索快照点击同一本书，确认旧的多来源被删除，之后其他入口只显示一个来源。
6. 从书架、阅读器、下载管理进入详情，确认只读取本地组，不把当前单来源反向覆盖掉多来源快照。
7. 从详情执行整书换源并进入替换后的详情，确认它读取本地组但不把换源后的单来源写回数据库。
8. 删除某个已保存候选对应的书源，再进入详情，确认该来源不再出现且其他来源保留。
9. 使用两个来源返回相同 `bookUrl` 的样本，确认来源数量仍为两个。
10. 快速连续点击 Cell，确认只打开一个详情且最终持久化组没有被旧事务覆盖。
11. 升级旧安装后首次进入非搜索详情应安全退化为当前单来源；从搜索点击一次后再进入即可恢复多来源。

## 14. 完成判断

当前仅完成静态分析和实施设计。用户确认执行后才能修改业务代码和数据库 Schema；代码写入后仍只能标记
`IMPLEMENTED / 待用户验证`，必须取得用户运行结果后才能描述为已验证。
