# 搜索、书源与阅读界面完善方案

> 状态：`IN_PROGRESS`。实现代码已写入；尚未执行构建、测试、分析、格式化或应用启动，等待用户验收。
>
> 日期：2026-07-25

## 目标与边界

本次目标是完善搜索页的临时书源筛选、书源列表筛选、服务器书源同步、阅读器首显菜单、阅读设置持久化和阅读器面板配色，并让非文字书源在导入/新建时默认关闭。

不包含：修改 Android 参考工程、改变书源 JSON 格式、修改既有书源类型值、把搜索页的临时筛选写入数据库、重做阅读器正文排版或运行验证。

## 当前实现与差距

| 范围 | Flutter 当前入口 | 当前事实 | 本次补足 |
| --- | --- | --- | --- |
| 搜索书源选择 | `ui/search/search_contract.dart`、`search_view_model.dart`、`search_screen.dart` | 已有 URL 集合选择；空集合表示全部启用书源 | 分组选择、书源关键字过滤、反选、仅成功率书源；全部只保留于当前 `SearchViewModel` 生命周期 |
| 搜索匹配方式 | `SearchViewModel._merge` | 当前以不区分大小写的相等比较提升结果排序，可视为既有模糊行为 | 增加“包含”“精准”“模糊”模式，并把模式传入合并/排序层；需确认“包含”和“模糊”的最终语义 |
| 搜索执行 | `model/web_book/book_search_coordinator.dart` | 读取启用书源并过滤搜索结果中的成人内容 | 继续在搜索入口执行内容屏蔽和域名黑名单判断 |
| 书源列表 | `ui/book_source/`、`BookSourceRepository.watchAll` | 可输入搜索词，但没有“总书源/分组”筛选入口 | 显式加入总书源和从现存分组派生的筛选项；列表仍执行屏蔽规则 |
| 服务器书源同步 | `app/remote_book_source_sync_service.dart` → `ImportBookSourcesUseCase` → `BookSourceRepository.importSourceJson` | 同步复用本地导入链路，会调用 `AdultContentGateway.isAdultSource` 并丢弃命中书源 | 新增仅供服务器同步的受控导入入口：保留所有服务器返回书源，仍遵循 JSON 校验、冲突覆盖和事务；显示/搜索时再过滤 |
| 书源默认启用 | `BookSource`、导入解码器、书源编辑草稿 | 类型值已存在，默认 `enabled=true` | 文字书源（`bookSourceType == 0`）保持默认开启；视频、音乐、漫画等非文字类型默认关闭；显式携带 `enabled=false` 时不覆盖用户值 |
| 阅读器菜单 | `ReaderUiState.menuVisible` | 默认值为 `true`，每个新 `ReaderViewModel` 都会显示工具栏 | 使用设备安装周期标记：App 安装后只自动显示一次，覆盖安装、重启和账号切换都保持隐藏；用户点按仍可显示 |
| 阅读设置 | `ReaderRepository.getDisplayConfig/saveDisplayConfig` | 配置按 `reader:config:<bookUrl digest>` 保存，因此杀进程后仅同书恢复 | 改为全局阅读显示配置键；首次读全局值，不存在时兼容迁移当前书籍旧键；任意书籍修改后写全局值，打开任意书都会读取 |
| 阅读器配色 | `reader_menu_overlay.dart`、`reader_settings_sheet.dart`、目录/书签 BottomSheet | 正文背景色与文字色未作为所有面板的统一主题 | 以 `ReaderDisplayConfig.backgroundColorValue/textColorValue` 计算面板 Surface、标题/正文、分割线、图标和交互色；目录、书签、设置及其余阅读器 Sheet 一致应用，不创建独立色彩持久化字段 |

## Android 对照

- 搜索书源范围及分组：`../legado-with-MD3/app/src/main/java/io/legado/app/data/repository/SearchRepository.kt`、`data/dao/BookSourceDao.kt`、`res/layout/dialog_search_scope.xml`。
- 书源分组查询：`../legado-with-MD3/app/src/main/java/io/legado/app/data/dao/BookSourceDao.kt`。
- 书源类型：`../legado-with-MD3/app/src/main/java/io/legado/app/constant/BookSourceType.kt`。
- 阅读器/阅读配置参考入口：`../legado-with-MD3/app/src/main/java/io/legado/app/data/entities/Book.kt` 及其 `ui/book/read/` 相关页面。

## 拟定实现

1. 扩展搜索 Contract 的临时筛选状态和 Intent；搜索页使用底部面板展示分组、书源关键字、选择操作和成功率条件。书源快照只取当前启用且可显示的文字书源，选择值不写入 `caches`、数据库或全局设置。
2. 在协调器/仓储边界提供书源分组与可显示书源查询，避免 UI 直接筛选数据层。成功率使用已有 `sourceScore` 的正值作为“有成功率”判定；UI 只过滤本次候选集合。
3. 为结果聚合引入显式的匹配模式：精准模式仅保留书名或作者与关键词规范化后相等的候选；包含模式保留书名或作者包含关键词的候选；模糊模式沿用当前全部结果并保留现有相等优先排序。若用户对“模糊”有其他既有定义，以确认结果为准。
4. 将成人内容屏蔽拆为“导入准入”与“显示/搜索可见性”两个调用点。普通手动导入保持原有准入过滤；服务器同步走新入口，不过滤关键词/域名。书源管理列表和搜索候选统一调用可见性判断，避免只在 UI 文本过滤而遗漏域名。
5. 在导入解码和编辑保存的默认值层处理非文字类型默认关闭，不改动已存在书源的启用状态。服务器同步按同一默认策略落库。
6. 将阅读配置从单书缓存迁移为全局缓存键，保留旧键只读迁移兼容。配置写入使用单个 JSON，避免每个设置项分别 I/O；不涉及 SQLite 表结构，因此不提升 schemaVersion 或 app build number。
7. ReaderRoute 创建 ViewModel 时通过类型化 `ReaderMenuPreferences` 领取“本安装是否已经自动展示过工具栏”的设备级状态。未展示时首个路由使用 `menuVisible=true`，正文和工具栏实际进入可见帧后写入 `reader.menu_auto_shown.v1.device`；覆盖安装、重启和账号切换不重置，卸载或清除应用数据后重新首显。
8. 提取阅读器面板颜色解析的纯 UI helper，并传给所有 ReaderSheet。避免在滚动列表逐项创建主题对象；面板主题在构建时按当前配置计算一次，动画继续使用现有 BottomSheet/Overlay 动画。

## 涉及文件

- 搜索：`lib/src/ui/search/search_contract.dart`、`search_view_model.dart`、`search_screen.dart`、`search_route.dart`、`lib/src/model/web_book/book_search_coordinator.dart`。
- 书源：`lib/src/domain/gateway/book_source_gateway.dart`、`lib/src/data/dao/book_source_dao.dart`、`lib/src/data/repository/book_source_repository.dart`、`lib/src/domain/usecase/import_book_sources_use_case.dart`、`lib/src/app/remote_book_source_sync_service.dart`、`lib/src/ui/book_source/`。
- 阅读：`lib/src/data/repository/reader_repository.dart`、`lib/src/app/reader_menu_preferences.dart`、`lib/src/ui/reader/reader_contract.dart`、`reader_view_model.dart`、`reader_route.dart`、`reader_menu_overlay.dart`、`reader_settings_sheet.dart`、`reader_action_sheets.dart`。
- 文档索引：`docs/flutter-rewrite/AI_PROJECT_INDEX.md`。

## 验收清单（由用户执行）

1. 搜索页按书源分组、书源名搜索、反选、仅成功率筛选后发起搜索；返回搜索页重新进入时选择不保留。
2. 逐一验证包含、精准、模糊三种模式的结果范围与排序。
3. 书源页可切换总书源与任意分组，且屏蔽词/域名命中的书源不可见；搜索也不会调度这些书源。
4. 同步服务器书源后，命中屏蔽词或域名的书源仍落库，但不出现在书源列表或搜索候选中。
5. 新导入/新建的文字书源默认启用；视频、音乐、漫画等默认停用；已有书源状态不被改写。
6. App 安装后第一次实际进入正文时显示工具栏，之后打开其他书默认隐藏；重启 App、覆盖安装和切换账号后仍不再自动显示，卸载重装后重新显示一次。
7. 修改阅读设置后，关闭 App、打开另一书籍，字体、布局、亮度/方向等设置一致恢复；旧单书配置在无全局配置时可迁移一次。
8. 切换阅读配色后，设置、目录、书签、搜索、换源和下载等阅读器面板的前景/背景均可读且颜色一致。

## 待确认

“包含搜索、精准搜索、模糊搜索”在本方案中分别定义为“字段包含关键词”“字段完全相等”“沿用当前全部返回结果并将完全相等优先”。如果“模糊搜索”是拼音、编辑距离或其他算法，需要在实施前明确，以避免改变用户预期。

## 本次实施记录

- `BookSourceImportDecoder` 已将外部 JSON 中缺失 `enabled` 的非文字书源默认值改为关闭；新建书源保存时同样保护该默认值。
- 服务器游标同步通过 `ImportBookSourcesUseCase` 显式关闭导入准入过滤，仍保留解码、事务、冲突覆盖和错误统计；手动导入维持原有屏蔽行为。
- `BookSourceRepository.watchAll` 与 `BookSearchCoordinator` 已在书源列表展示和搜索调度前调用屏蔽词/域名检查，已同步但被屏蔽的书源不会显示或执行。
- 搜索筛选、书源分组、匹配模式均仅存在于 `SearchViewModel`，不写入数据库或偏好；页面销毁后自动失效。
- 阅读配置保存键已改为全局键，旧按书籍键只读兼容；菜单首显状态使用设备安装周期 MMKV 标记，并只在工具栏实际可见后提交；所有 `ReaderSheet` 通过路由层主题继承阅读背景和文字配色。
- 书源管理分组筛选已改为下拉选择；搜索页展开的书源候选区固定为独立滚动列表，避免候选数量过多时撑高页面。
- 修正搜索书源面板的分组 `Wrap`：分组改为紧凑的弹出菜单，避免大量分组在 `Column` 中参与全量布局造成 RenderFlex 溢出；书源页分组也使用同风格的筛选胶囊触发菜单。
- 书源管理搜索框改为紧凑、无常驻边框的弱化样式；分组筛选行显示“启用数量/当前可见总书源数量”，且统计不随搜索词、类型或分组筛选变化。
