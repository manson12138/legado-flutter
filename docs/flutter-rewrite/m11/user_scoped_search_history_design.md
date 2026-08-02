# 按登录用户隔离搜索历史设计

状态：`IMPLEMENTED_PENDING_USER_VERIFICATION / 代码已写入，等待用户运行验收`。本文基于 2026-07-25 的静态梳理与实施，并于 2026-07-27 增加 `userId=-1` 的游客搜索历史；未运行编译、测试、分析、格式化或应用。

## 1. 目标与边界

目标：同一设备上的搜索关键字历史只属于执行搜索的登录用户。A、B 账号切换后分别看到自己的最近搜索；重新登录原账号后恢复该账号在当前设备保存的历史。

### 1.1 实施快照

- `SearchHistoryRepository` 已注入当前用户 ID 解析器，并使用
  `flutter_m06_search_history_user_v1_<userId>` 作为用户级缓存键。
- 旧设备级公共键 `flutter_m06_search_history` 会在首次访问搜索历史时单飞删除，
  不会迁移给任一登录用户；清理失败后允许后续访问重试。
- `load`、`record`、`clear` 已通过同一条串行任务尾执行，并在进入异步队列前固定
  本次操作的用户缓存键，避免快速切换账号时串号或丢失更新。
- `AppDependencies` 已把 `CurrentUserScope.requireUserId` 注入搜索历史仓储。
- 本次没有修改数据库结构，也没有调整 `LegadoDatabase.schemaVersion` 或
  `pubspec.yaml` 构建号。
- Android/iOS 真机或模拟器验收仍由用户执行。
- 保活 `SearchRoute` 的 `SearchViewModel` 已直接监听 `CurrentUserScope.userId`：认证恢复、
  登录、退出或换号时立即清空旧作用域瞬时搜索状态并重读新作用域历史，读取代次会拒绝游客或旧账号的
  较慢结果覆盖当前账号。

明确不包含：

- 不同步到服务端，也不提供跨设备恢复。
- 不把搜索结果、搜索运行状态、书源选择、成功率筛选或结果匹配方式一并改成用户级。
- `SearchPreferences` 中不含查询原文的包含/精确/模糊匹配方式继续保持设备级。
- 不修改 `caches` 表结构，不升级 `LegadoDatabase.schemaVersion`，不递增 `pubspec.yaml` build number。

## 2. 当前实现与问题

当前调用链：

```text
SearchViewModel
  -> SearchHistoryGateway
  -> SearchHistoryRepository
  -> CacheDao
  -> caches(key = flutter_m06_search_history)
```

`SearchHistoryRepository` 使用唯一固定缓存键 `flutter_m06_search_history` 保存最多 20 条 JSON 字符串。所有账号读写同一行，因此 B 登录后会看到 A 的搜索词；“清空”也会删除所有账号共用的记录。

搜索页位于主框架 `IndexedStack` 中并保持状态。2026-08-02 的 iOS 真机日志证明，启动时搜索页先在游客
作用域初始化；认证恢复到账号后，现有导航路由没有释放该 `SearchViewModel`。数据库中账号 13 的用户键
仍有 11 条历史，但两次启动都只记录了 `historyCount=0`，因此页面显示为空。持久化层独立捕获用户作用域
仍是必要边界，ViewModel 同时必须监听作用域变化，不能依赖根 Widget 或路由重建。

## 3. 存储与旧数据决策

继续复用 `caches` 表，以用户 ID 构造稳定且不可冲突的缓存键：

```text
flutter_m06_search_history_user_v1_<userId>
```

示例：

```text
flutter_m06_search_history_user_v1_12
flutter_m06_search_history_user_v1_27
```

每个键仍保存按最近使用倒序排列、最多 20 条的 JSON 字符串列表。`userId` 是服务端稳定整数账号标识；缓存键不包含用户名、Token、密码或搜索词。

旧固定键 `flutter_m06_search_history` 的数据无法证明属于哪个账号，因此不能自动认领给升级后第一个登录用户。实施时首次进入用户级搜索历史 Repository 后单飞删除旧固定键，不复制其内容。删除仅影响旧搜索历史，不影响书源、搜索偏好、书架或其他 `caches` 数据。

该变化只增加新的缓存键命名规则，`caches.key` 已经是字符串主键，所以不需要 Schema v10 或构建号 `+8`。

## 4. 运行时与并发规则

- `SearchHistoryRepository` 通过组合根注入的 `CurrentUserScope.requireUserId` 获取当前用户；`load`、`record`、`clear` 每次入口先捕获一次用户 ID 和最终缓存键。
- `record` 内部读取旧列表、去重、置顶、截断和写回必须始终使用入口捕获的同一个键，不能在异步等待后重新读取当前用户，否则账号切换可能把 A 的关键字写入 B。
- 搜索历史读改写使用 Repository 内的有界串行尾任务，避免用户快速连续提交两个关键字时发生“后完成的旧快照覆盖新快照”。搜索历史频率低，单队列串行不会形成可感知性能瓶颈，也不需要维护按用户增长的锁 Map。
- 账号切换时保活 `SearchViewModel` 直接监听 `CurrentUserScope.userId`，取消旧搜索、清空关键字、结果和旧
  历史，并重新读取新用户键；历史读取代次会拒绝较慢的游客或旧账号结果。即使旧持久化操作已经开始，
  也只能写入入口捕获的旧用户键，且不会再发布到新账号页面。
- 未登录调用 `SearchHistoryGateway` 使用固定游客键 `flutter_m06_search_history_user_v1_-1`；不得回退到旧固定键、空用户键或无归属公共历史。
- 日志继续只记录历史数量，不记录搜索词原文、用户 ID 或缓存键。

## 5. 实施范围

- `lib/src/data/repository/search_history_repository.dart`
  - 已注入当前用户 ID 读取函数。
  - 已将固定旧键改为按用户派生的新键。
  - 已增加旧固定键单飞清理。
  - 已保证一次读改写固定同一用户键，并串行化写操作。
- `lib/src/app/app_dependencies.dart`
  - 创建 `SearchHistoryRepository` 时已注入 `currentUserScope.requireUserId`。
- `lib/src/app/current_user_scope.dart`
  - 已将职责注释从“书架与历史”扩展为“所有明确要求用户隔离的本地数据”，不改变其 Token 边界。
- `lib/src/ui/search/search_route.dart`、`lib/src/ui/search/search_view_model.dart`
  - 已注入并监听用户作用域；保活页面在认证恢复和账号切换时重读历史，并隔离旧异步结果。
- `docs/flutter-rewrite/m06/README.md`、`docs/flutter-rewrite/m11/README.md`、`docs/flutter-rewrite/AI_PROJECT_INDEX.md`
  - 已更新搜索历史归属、旧数据处理、验收和未同步限制。

无需修改 `SearchHistoryGateway`、Search Contract、ViewModel、Screen、路由或平台宿主；用户作用域仍由数据层组合根注入，Widget 不接触用户 ID 或缓存 DAO。

## 6. 用户可见行为

| 场景 | 目标行为 |
| --- | --- |
| A 搜索“甲”“乙” | A 的历史显示“乙、甲”。 |
| 退出 A、登录首次使用的 B | B 的搜索历史为空，不显示 A 的关键字。 |
| B 搜索“丙” | B 只显示“丙”。 |
| 退出 B、重新登录 A | A 恢复“乙、甲”，不出现“丙”。 |
| A 清空历史 | 只删除 A 的用户缓存键，B 的“丙”保留。 |
| 升级前存在设备级旧历史 | 首次用户级访问时删除旧固定键，不分配给任何账号。 |
| 游客搜索后登录 A | A 不显示游客搜索词；退出 A 后游客搜索历史重新出现。 |
| 新设备登录 A | 历史为空；服务端未提供同步 API。 |

## 7. 性能、内存与隐私

- 使用 SQLite 字符串主键直接查询单行，不扫描 `caches` 后在 Dart 过滤。
- 每个账号最多保存 20 条，沿用现有不可变返回列表，不新增常驻全量用户缓存。
- Repository 只保留一个串行 Future 尾任务和一个旧键清理 Future，不持有页面、`BuildContext`、账号对象或搜索结果。
- 搜索词属于隐私数据，不进入日志、埋点、崩溃报告或账号切换诊断。
- 用户缓存键只包含本地所需整数 ID；不包含用户名或认证凭据。

## 8. 用户验收

1. A 连续搜索两个不同关键字，退出后登录 B，确认 B 不显示 A 的历史。
2. B 搜索第三个关键字，切回 A，确认 A 只恢复自己的两条记录。
3. A 清空历史后切到 B，确认 B 的历史仍存在。
4. A/B 快速切换并在搜索提交后立即退出，确认关键字不会写入另一个账号。
5. 从带旧固定搜索历史的版本升级，确认旧历史不会出现在任一账号下。
6. 每个账号分别连续搜索超过 20 个不同关键字，确认各自独立保留最近 20 条。
7. 检查日志与崩溃报告，确认不存在搜索词原文、用户 ID 或用户级缓存键。

代码已经实施，仍需由用户运行 Android 和 iOS 验收；AI 未运行构建、测试、分析、格式化或应用。
