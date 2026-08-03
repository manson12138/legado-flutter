# MMKV 非表结构偏好存储接入与 SQLite 迁移设计

状态：`SUPERSEDED / 用户已确认 MMKV 2.4.x 与 Android 仅 64 位`。当前实施入口已合并到
[`mmkv_and_reader_entry_loading_optimization_plan.md`](./mmkv_and_reader_entry_loading_optimization_plan.md)。

> 本文只完成静态设计。尚未修改依赖或业务代码，也未运行 Flutter、Dart、构建、测试、静态分析、
> 格式化或应用启动。

## 1. 目标

为体积小、读取频繁、不需要关系查询、事务或列表排序的持久化状态引入 MMKV，使这些状态在 MMKV
初始化完成后可以同步从内存映射文件读取，避免每次页面进入都等待 SQLite 连接和查询队列。

第一批目标：

- 阅读器全局显示配置；
- 书架布局偏好；
- 搜索匹配偏好；
- 首次阅读先导页等一次性提示状态；
- 后续经过单独核对后可迁移的其他纯偏好。

本方案不把 MMKV 当成 SQLite 的替代品，也不迁移需要关系完整性、条件查询、批量事务或大正文存储的
数据。

## 2. 官方依赖评估

拟采用腾讯/微信官方 Flutter 包 `mmkv`：

- 当前官方包版本：`2.4.0`；
- 发布者：`weixin.com`；
- 许可证：BSD 3-Clause；
- Android 和 iOS 均由官方 federated plugin 支持；
- MMKV 使用 mmap 和 protobuf 编解码，写入立即保存，不要求业务调用 `apply` 或 `sync`；
- Flutter 侧必须先 `await MMKV.initialize()`，之后才能创建或访问 MMKV 实例；
- 默认文件位于应用沙盒；
- 默认值是明文存储，只依赖应用沙盒保护，因此不得保存 Token、密码、Cookie 或构建密钥。

### 2.1 平台边界

- 当前项目 Android `minSdk=26`，高于 MMKV 2.x 的 `minSdk=23`；
- 当前项目 iOS Deployment Target 为 16.0，高于官方插件旧版本已经要求的 iOS 12；
- MMKV 2.0 起停止支持 Android 32 位架构；
- MMKV 1.3.x LTS 支持 ARMv7，但只接受关键修复，不再获得 2.x 新功能。

推荐使用官方当前版本 `mmkv: ^2.4.0`，前提是用户确认 Android 只要求 64 位设备。若仍需
`armeabi-v7a`，必须单独评估 1.3.x LTS，不能在没有说明的情况下静默降低架构覆盖。

## 3. 适合与不适合迁移的数据

| 数据 | 目标存储 | 原因 |
|---|---|---|
| 阅读器全局显示配置 | MMKV | 单条小 JSON、每次阅读高频读取、设备级 |
| 书架网格/列表布局偏好 | MMKV | 小型枚举与布尔值，不需要关系查询 |
| 搜索匹配偏好 | MMKV | 小型设备级配置 |
| 首次先导页/一次性提示版本 | MMKV | 典型版本化布尔或整数 |
| 用户作用域搜索关键字历史 | 后续评估 | 数据量小，但需要用户隔离、去重和最多 20 条顺序语义 |
| App 准入/升级缓存 | 后续评估 | 小型 KV，但含版本和过期语义，迁移前需保持阻断安全 |
| 成人内容开关 | 后续评估 | 布尔偏好适合；远端词库和域名集合不应顺带迁移 |
| 书籍、目录、书架分组 | SQLite | 关系、排序、批量事务和用户作用域 |
| 阅读历史与阅读进度 | SQLite | 需要与书籍、章节和用户保持一致 |
| 稳定正文锚点 | SQLite | 当前与进度、换源事务存在业务关联，不在首批拆散 |
| 书签、正文标注、替换规则 | SQLite | 列表查询、筛选、排序和事务 |
| 下载队列 | SQLite | 状态恢复、批量更新和任务一致性 |
| 原始章节正文缓存 | SQLite/后续文件缓存评估 | 内容大、带有效期和批量删除，不适合作为偏好 |
| 封面 URL 缓存 | SQLite | 键数量可能随书籍增长，带查找和清理语义 |
| JavaScript `cache` 兼容 API | SQLite | 属于脚本可见行为，不能因偏好优化改变语义 |
| 匿名埋点待发送队列 | SQLite | 要求顺序、幂等、容量和崩溃恢复 |
| Token、Refresh Token | Keychain/Keystore | 安全凭据禁止进入普通 MMKV |
| Cookie、Authorization、密码 | 现有安全边界 | 禁止进入普通 MMKV |

## 4. 分层设计

### 4.1 统一偏好抽象

业务代码不直接依赖 `package:mmkv`。建议增加项目内的窄接口，例如：

```text
AppPreferencesStore
  -> contains(key)
  -> readBool/readInt/readDouble/readString
  -> writeBool/writeInt/writeDouble/writeString
  -> remove(key)
```

MMKV 实现位于数据/本地基础设施层，由 `AppDependencies` 注入。阅读器、书架和搜索只依赖各自的
类型化偏好类：

- `ReaderDisplayConfigStore`
- `BookshelfLayoutPreferences`
- `SearchPreferences`
- `ReaderIntroPreferences`

类型化偏好类负责键名、默认值、JSON 版本和非法数据降级，避免 UI 或 ViewModel 拼接字符串键。

### 4.2 MMKV 实例

首批建议使用单独实例 `legado.preferences`，采用默认单进程模式：

- 设备级偏好使用固定键；
- 用户级偏好必须带 `userId` 前缀并在当前用户作用域确定后访问；
- 不为每本书创建独立 MMKV 文件，避免文件描述符和实例数量随书架增长；
- 不启用多进程模式，除非以后原生后台进程也需要访问同一偏好；
- 不在实例中保存正文、封面二进制或完整页面快照。

## 5. 初始化时机

官方要求访问实例前必须等待 `MMKV.initialize()` 完成。当前工程已经把完整 `AppDependencies` 放到
Flutter 第一帧后创建，因此推荐链路为：

```text
runApp(轻量 Bootstrap)
  -> Flutter 第一帧
  -> await MMKV.initialize()
  -> 创建 legado.preferences 单进程实例
  -> 创建 AppDependencies 并注入 AppPreferencesStore
  -> 进入正式 PageNestApp
```

这不会阻塞原生启动页或 Flutter 第一帧，但会成为“轻量 Bootstrap 到正式应用组合根”的本地初始化条件。
MMKV 初始化失败时不应让整个 App 永久不可用：

- 记录不含路径和用户数据的受控错误；
- 使用进程内默认偏好或现有 SQLite 兼容读取作为降级；
- 页面仍可进入，但本轮偏好修改需要明确报告无法持久化；
- 不因降级重复创建多个 MMKV 初始化任务。

不建议把 `await MMKV.initialize()` 放回 `runApp()` 之前，否则会违背现有首帧性能分层。

## 6. 阅读器显示配置迁移

### 6.1 新存储

建议继续使用一个版本化 JSON 值：

```text
reader.display_config.v1
```

理由：

- 配置字段多，整体读取一次比逐字段跨 FFI 调用更简单；
- 现有 `ReaderDisplayConfig` 已有完整 JSON 映射；
- 新字段可通过默认值向前兼容；
- 读取后在 `ReaderDisplayConfigStore` 内保存同步内存快照。

MMKV 提供同步读取后，阅读页面构造时直接取得当前配置；不再每次通过
`ReaderCacheGateway.getDisplayConfig(bookUrl)` 等待 SQLite。

### 6.2 首次迁移

第一版迁移使用明确版本标记：

```text
preferences.migration_version
```

迁移顺序：

1. 初始化 MMKV；
2. 若 MMKV 已存在新版显示配置，直接使用；
3. 若不存在，则读取 SQLite `reader:config:global`；
4. 全局键不存在时继续兼容旧按书籍摘要键；
5. 完成 JSON 校验后写入 MMKV；
6. MMKV 写入成功后再提交迁移版本；
7. 任一步失败不写完成标记，下次允许重试；
8. 迁移期不删除 SQLite 旧值，便于版本回退和异常诊断。

迁移完成后正常读取只走 MMKV。显示设置保存时先更新内存和 MMKV；是否在第一个过渡版本继续旁路写
SQLite，需要实施时固定为单一策略，不能长期让两个事实源互相覆盖。推荐迁移后停止 SQLite 正常写入，
旧记录只作为一次迁移来源。

## 7. 其他偏好迁移顺序

### P0：为阅读器进入优化服务

1. 接入 MMKV 依赖和第一帧后初始化。
2. 建立 `AppPreferencesStore` 与内存降级实现。
3. 迁移阅读器全局显示配置。
4. 增加首次阅读先导页的版本化状态。
5. 阅读器通过同步 Store 读取配置，不再把 SQLite 配置查询放入进入关键链。

### P1：迁移已有纯偏好

1. `BookshelfLayoutPreferences`
2. `SearchPreferences`
3. 其他经过表格确认的设备级布尔、枚举和小字符串

每个偏好都必须独立定义旧键、新键、默认值、迁移版本和失败降级，不能把整个 `caches` 表一次性搬入
MMKV。

### P2：评估带过期或用户作用域的 KV

- 用户搜索历史；
- App 准入与升级缓存；
- 成人内容开关。

这些数据迁移前需要分别保留过期、阻断、用户隔离和远端覆盖语义。

## 8. 性能与内存约束

- 页面读取必须只访问已经初始化的类型化 Store，不在 `build()` 中初始化 MMKV；
- MMKV 的同步 API只能用于小值，不能在 UI 线程读写大正文或大 JSON；
- 显示配置解码一次后保留不可变内存对象，页面不重复 JSON 解码；
- 设置拖动期间只更新内存草稿，沿用现有提交时机持久化，不能让 Slider 每一帧都写 MMKV；
- MMKV 自动保存不代表可以无界高频写入；
- App 生命周期内复用同一个实例，不在每次路由进入时创建和关闭；
- 系统内存压力可以调用官方 `clearMemoryCache()`，但随后同步读取仍需保持正确；
- 不记录 MMKV 根目录、文件绝对路径、偏好值或用户输入内容。

## 9. 数据安全与恢复

- 普通偏好实例不启用业务自造固定加密密钥；固定写死密钥不能提供有效安全边界；
- Token 继续使用 `flutter_secure_storage`，不得迁移；
- MMKV 值损坏、类型错误或版本未知时使用受控默认值，并允许重写；
- 迁移标记只能在全部目标值成功写入后提交；
- 应保留键名前缀和 JSON schema 版本，避免以后字段含义冲突；
- 用户作用域值必须在切换账号时重新计算 key，旧异步任务不能写入新用户 key；
- MMKV 初始化和迁移单飞，避免启动与页面同时迁移。

## 10. 依赖风险与可替换性

### 风险

- MMKV 是包含 Android/iOS 原生二进制的第三方依赖，会增加平台构建和升级兼容面；
- 2.x 不支持 Android 32 位；
- 初始化必须异步完成，若时机设计错误会重新拉长启动白屏；
- 默认明文，误存安全凭据会扩大风险；
- 同步读取很快，但同步写入大值或过度高频写仍可能影响 UI；
- Flutter 侧不能直接完成全部原生日志重定向能力。

### 可替换性

业务只依赖 `AppPreferencesStore`，因此以后可以替换为其他 KV 实现或回退 SQLite，而不修改阅读器、
书架和搜索业务。MMKV 的类型和实例不得穿透到 ViewModel、UseCase 或 Widget。

## 11. 预计文件范围

执行 P0 时预计涉及：

- `pubspec.yaml`
- `pubspec.lock`（由用户安装依赖时生成或更新）
- `lib/src/app/pagenest_app.dart`
- `lib/src/app/app_dependencies.dart`
- 新的偏好接口、MMKV 实现、内存降级实现和阅读配置 Store
- `lib/src/data/repository/reader_repository.dart`
- `lib/src/domain/gateway/reader_cache_gateway.dart`
- `lib/src/ui/reader/reader_view_model.dart`
- 阅读器进入预热专项涉及的 Route/Contract
- `docs/flutter-rewrite/AI_PROJECT_INDEX.md`
- M8/M11 实施记录

不修改数据库表结构，因此不需要提高 `LegadoDatabase.schemaVersion`，也不因本专项单独提高
`pubspec.yaml` build number。

## 12. 用户验收

1. Android 64 位真机冷启动，确认 Flutter 首帧仍先出现，MMKV 初始化不造成原生白/黑屏延长。
2. iOS 真机冷启动和热启动，确认配置迁移与读取正常。
3. 从已有 SQLite 版本升级，确认原阅读字号、颜色、翻页模式、亮度、全屏和边缘返回设置完整迁移。
4. 杀进程重启，确认读取 MMKV 后设置保持不变。
5. 连续进入多本书，确认不再为显示配置查询 SQLite，也不出现通用圆形 loading。
6. 设置页连续拖动字号/亮度，确认动画流畅，持久化不会每帧执行。
7. 模拟 MMKV 初始化或值解码失败，确认使用默认值或兼容读取，不无限启动。
8. 切换游客与账号，确认设备级阅读配置保持一致，用户级偏好不串号。
9. 检查 Token、Cookie、密码和正文没有进入 MMKV。
10. 若选择 2.x，确认交付的 Android ABI 仅覆盖用户接受的 64 位范围。

## 13. 待用户确认

执行前只剩一个会改变交付平台范围的选择：

- 推荐：`mmkv ^2.4.0`，使用当前官方版本，接受 Android 只支持 64 位；
- 兼容：评估 `1.3.x LTS`，保留 ARMv7，但接受旧 LTS 功能和维护边界。

版本确认后，再执行 P0；不得在未确认 ABI 取舍时直接修改依赖。
