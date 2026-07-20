# 小说正文阅读界面 UI 重构优先级

> 文档状态：`IN_PROGRESS / P0～P4 可落地项已写入 Flutter，标题排版、段落排版、长章节首屏增量分页和后台续算已接入；单章换源和离线下载（前台运行范围）已接入，等待用户运行验证`  
> 创建日期：2026-07-16  
> 适用范围：Flutter `ui/reader/` 小说正文阅读界面对齐 Android `ui/book/read/` 当前阅读界面。  
> 不包含范围：书籍详情页、书架页、搜索页、漫画阅读器完整能力、音频书完整能力、RSS 阅读器、原 Android 代码修改。

## 0. 本次目标

本文件的唯一目标是：先把 Flutter 小说正文阅读界面按 Android 阅读器已有 UI 功能拆成可执行的优先级批次，后续再逐批实现。

这里的“参照 Android 项目的 UI”不是像素级复制，而是保持：

- 阅读界面的入口、菜单层级、手势、面板、弹窗和系统能力可以找到对应映射；
- 高频阅读操作优先可用，低频高级能力保留明确入口和依赖边界；
- Flutter 继续使用统一跨 Android/iOS 视觉体系；
- UI 只渲染 `ReaderUiState` 并发送 `ReaderIntent`，正文获取、缓存、替换、进度、下载、朗读和平台能力不能写进 Widget。

## 0.1 实施快照

2026-07-16 已写入 P0 第一批 Flutter 实现，修改范围为
`flutter_app/lib/src/ui/reader/reader_screen.dart` 和新增
`flutter_app/lib/src/ui/reader/reader_menu_overlay.dart`：

- 阅读页从默认 `AppScaffold` 的 AppBar/BottomAppBar 改为全屏 `Scaffold` + `Stack`；
- 正文区域保持原有连续滚动和分页渲染逻辑，点击正文中央仍发送 `ToggleReaderMenuIntent`；
- 新增 `ReaderMenuOverlay`，用 `AnimatedOpacity` 和 `IgnorePointer` 实现阅读菜单浮层显示/隐藏；
- 顶部浮层提供返回、当前章节/书名、刷新当前章、整书换源和更多菜单；
- 本地书会禁用整书换源入口，章节加载中会禁用刷新入口；
- 更多菜单保留添加书签、目录和显示设置三个 P0 高频动作；
- 底部浮层提供章节进度滑杆、当前章节/总章节、章节内百分比、上一章、目录、书签、设置和下一章；
- 章节滑杆拖动时只更新本地草稿，松手后查找最近可阅读章节并复用 `OpenReaderChapterIntent` 跳转；
- 卷标题不会直接作为跳转目标，滑杆会优先向后再向前寻找可阅读章节；
- 未接入平台亮度、电量监听、自动翻页、TTS、离线下载、单章换源、阅读内搜索和书签编辑，这些仍按 P1～P4 拆分推进。

2026-07-16 已继续写入 P1 第一批 Flutter 实现，修改范围为
`flutter_app/lib/src/domain/model/reader_content.dart`、
`flutter_app/lib/src/data/repository/reader_repository.dart`、
`flutter_app/lib/src/ui/reader/reader_route.dart`、
`flutter_app/lib/src/ui/reader/reader_screen.dart`、
`flutter_app/lib/src/ui/reader/reader_page_layout.dart` 和新增
`flutter_app/lib/src/ui/reader/reader_settings_sheet.dart`：

- 阅读显示配置新增上下边距、字距、字重和斜体字段；
- 显示配置缓存 JSON 读写同步新增字段，旧缓存缺字段时使用默认值；
- 旧的 Route 内嵌设置 Sheet 已移出，Route 只负责展示 `ReaderSettingsSheetBody` 和提交配置；
- 设置面板拆成“样式 / 文字 / 间距 / 系统”四个页签；
- 样式页保留连续滚动、左右翻页、上下翻页，并补入纸张、护眼、白底、深色四套配色；
- 文字页支持字号、行高、字距、字重和斜体；
- 间距页支持段距、左右边距、上下边距；
- 系统页当时保留替换规则、常亮和预下载章节；平台亮度在该批次仍显示为待接入能力，后续已在 2026-07-17 的亮度/方向批次补齐；
- 连续滚动正文和分页正文都消费新增排版字段，避免只在单一阅读模式生效；
- 字号、字距、字重、斜体、行高、段距、边距和配色变化仍通过 `UpdateReaderConfigIntent` 持久化，并触发字符锚点重投影。

AI 未运行 `flutter analyze`、`dart analyze`、测试、构建、格式化或应用启动；是否可用以用户运行结果为准。

2026-07-16 已继续写入 P2 第一批 Flutter 实现，修改范围为
`flutter_app/lib/src/ui/reader/reader_contract.dart`、
`flutter_app/lib/src/ui/reader/reader_view_model.dart`、
`flutter_app/lib/src/ui/reader/reader_route.dart`、
`flutter_app/lib/src/ui/reader/reader_menu_overlay.dart` 和新增
`flutter_app/lib/src/ui/reader/reader_action_sheets.dart`：

- 目录 Sheet 打开时按当前章节初始定位，支持显示/隐藏卷标题；
- 目录继续禁止直接打开卷标题，跳章仍复用 `OpenReaderChapterIntent`；
- 顶部更多菜单新增“搜索正文”和“替换统计”入口；
- 搜索面板支持当前章节搜索、结果数量、上一条/下一条和点击结果跳转；
- 搜索跳转写入稳定字符锚点，并触发滚动恢复与进度保存；
- 书签列表新增编辑入口，删除操作增加二次确认；
- 书签编辑面板支持修改备注，空备注会回退到创建书签时的正文摘要；
- 替换统计面板展示当前章节替换开关、生效数量和正文缓存来源；
- 2026-07-17 继续补齐 P2 内容工具：搜索面板支持当前章/整书切换，整书搜索按目录顺序加载可阅读章节并点击跳转；书签面板支持导出 Markdown 文本到剪贴板；顶部更多菜单支持刷新后续章节和刷新全部章节；替换规则面板展示当前书可用的完整正文替换规则列表；
- 内容编辑器、复杂高亮规则编辑器、单章换源、离线下载、TTS、AI 和同步仍按依赖型能力推进。

2026-07-17 已继续写入 P3/P4 可落地 Flutter 实现，修改范围为
`flutter_app/lib/src/domain/model/reader_content.dart`、
`flutter_app/lib/src/data/repository/reader_repository.dart`、
`flutter_app/lib/src/ui/reader/reader_settings_sheet.dart`、
`flutter_app/lib/src/ui/reader/reader_screen.dart`、
`flutter_app/lib/src/ui/reader/reader_page_layout.dart`、
`flutter_app/lib/src/ui/reader/reader_menu_overlay.dart` 和
`flutter_app/lib/src/ui/reader/reader_action_sheets.dart`：

- 显示配置新增翻页动画策略、页眉页脚开关、底部工具文字开关、文字阴影和文字下划线，默认阅读方式为左右分页 + 覆盖翻页；
- 配置缓存 JSON 新增一次性默认迁移版本，已有单书缓存首次进入新版阅读器也切到左右分页 + 覆盖翻页，迁移后不再覆盖用户手动选择；
- 设置面板补入“覆盖 / 无动画 / 滑动”翻页动画、文字阴影、文字下划线、页眉页脚、底部工具文字开关；
- 连续滚动正文和分页正文都消费文字阴影、下划线和页眉页脚配置；
- 覆盖分页支持左右跟手拖动和左右区域点击；下一页由当前纸张左移露出，上一页从左侧覆盖回来，未达到阈值时回弹；
- 章节边界保留旧页等待相邻章节正文，加载完成后继续使用同一左右覆盖语义，不再清空正文并刷新列表；
- 分页模型改为标题行、正文行和间距行，章节标题使用独立样式进入每章第一页，正文仍使用原始字符偏移保存进度；
- 正文按 `TextPainter` 真实排版行逐行装页，段距和两个全角空格首行缩进参与高度与宽度测量，不再在页面后半段遇到换行就提前截断；
- 分页和渲染共用页眉、页脚、上下边距及正文高度，正文内容、标题或排版参数变化都会使分页签名失效并重新分页；
- 底部菜单工具按钮按配置隐藏或显示文字标签；
- 顶部更多菜单新增“后续能力”，面板以禁用清单登记单章换源、离线下载、TTS、自动翻页、内容编辑、AI 和同步进度的前置依赖；
- P4 依赖型能力未展示为可执行按钮，不把尚未迁移的底层服务伪装成已完成。

2026-07-17 已继续完成标题、段落和长章节分页优化，修改范围为
`flutter_app/lib/src/domain/model/reader_content.dart`、
`flutter_app/lib/src/data/repository/reader_repository.dart`、
`flutter_app/lib/src/ui/reader/reader_settings_sheet.dart`、
`flutter_app/lib/src/ui/reader/reader_screen.dart` 和
`flutter_app/lib/src/ui/reader/reader_page_layout.dart`：

- 显示配置新增章节标题左对齐/居中/隐藏、标题字号差值、标题字重、标题上下留白、首行缩进字数和两端对齐开关；
- 上述字段进入单书配置 JSON，旧缓存默认使用标题左对齐、标题字号 `+6`、标题字重 `600`、缩进 `2` 字和两端对齐；损坏数值会限制到设置面板支持范围；
- “文字”页新增两端对齐和章节标题模式、字号、字重，“间距”页新增首行缩进和标题上下留白；
- 分页和连续滚动都消费相同标题、缩进与对齐设置，隐藏标题不会影响页眉章节名；
- 分页器只对段落非末行分配剩余宽度，中文按字符间隙、英文多空格行优先按词距分配，正文字符锚点不包含显示用缩进；
- 长章节继续使用每段一次 `TextPainter` 的线性测量，新增最近三套分页结果的 LRU 缓存；组件重建、前后章返回或相同布局再次显示时不重复整章测量，缓存数量有界；
- 分页签名纳入全部标题、缩进和对齐参数，设置变化会正确失效并按稳定字符锚点恢复页面。

2026-07-17 已继续完成超长章节首屏增量分页和后台续算，修改范围为
`flutter_app/lib/src/ui/reader/reader_page_layout.dart`：

- 缓存未命中时不再同步计算完整章节页数，而是先生成首批 `8` 页或至少覆盖当前恢复字符锚点所在页；
- 首批页面渲染后启动 `_ReaderIncrementalPageLayoutJob` 分批续算完整分页，每批处理少量段落或页面后让出事件循环；
- 后台续算结果只在章节、正文、样式、尺寸和分页签名仍一致时回填，用户切章或修改设置后旧结果会被丢弃；
- 完整分页回填时使用当前可见页的稳定字符位置重新定位，避免总页数收敛时跳回章首或跳错页；
- 完整页集继续写入最近三套 LRU 缓存，后续返回同章或同布局时直接命中完整分页；
- 超长无换行段落按 `1200` 字符切块测量，首行缩进只加在真实段落第一块，段距只加在真实段落末尾；
- 完整分页未完成前，页脚总页数显示为省略号，末尾显示轻量分页中状态，并暂不触发下一章边界翻页。

2026-07-17 已继续完成点击区域、长按动作和音量键翻页可配置项，修改范围为
`flutter_app/lib/src/domain/model/reader_content.dart`、
`flutter_app/lib/src/data/repository/reader_repository.dart`、
`flutter_app/lib/src/ui/reader/reader_settings_sheet.dart`、
`flutter_app/lib/src/ui/reader/reader_screen.dart`、
`flutter_app/lib/src/ui/reader/reader_page_layout.dart` 和
`flutter_app/lib/src/ui/reader/reader_route.dart`：

- 显示配置新增左/中/右点击动作、长按动作、左右点击区宽度和音量键翻页开关；
- 上述字段进入单书配置 JSON，旧缓存默认保持左侧上一页、中间菜单、右侧下一页、长按添加书签、左右宽度各 `30%`、音量键开启；
- 设置面板“系统”页新增音量键翻页、四个动作下拉项和左右区域宽度滑杆；
- 分页模式点击动作优先翻当前页，章节边界再进入上一章或下一章，覆盖翻页动画语义保持不变；
- 连续模式点击动作优先滚动一个视口，到达顶部或底部后再切换章节；
- 分页组件直接接收音量键事件，能翻当前页；连续模式由 Route 兜底处理音量键并滚动一个视口；
- 长按动作当前支持无动作、上一页、下一页、菜单和添加书签；真正文本选择仍需后续富文本/选择态能力。

2026-07-17 已继续完成页眉页脚时间/电量、阅读亮度和方向锁定可配置项，修改范围为
`flutter_app/lib/src/domain/model/reader_content.dart`、
`flutter_app/lib/src/data/repository/reader_repository.dart`、
`flutter_app/lib/src/platform/reader_platform_service.dart`、
`flutter_app/lib/src/ui/reader/reader_contract.dart`、
`flutter_app/lib/src/ui/reader/reader_view_model.dart`、
`flutter_app/lib/src/ui/reader/reader_route.dart`、
`flutter_app/lib/src/ui/reader/reader_settings_sheet.dart`、
`flutter_app/lib/src/ui/reader/reader_screen.dart`、
`flutter_app/lib/src/ui/reader/reader_page_layout.dart`、
`flutter_app/android/app/src/main/kotlin/io/legado/flutter/MainActivity.kt` 和
`flutter_app/ios/Runner/AppDelegate.swift`：

- 显示配置新增时间显示、电量显示、跟随系统亮度、阅读亮度值和方向锁定策略；
- 上述字段进入单书配置 JSON，旧缓存默认显示时间/电量、跟随系统亮度、方向跟随系统；
- 分页页眉显示章节名、时间和电量，页脚显示书名、页码和章节百分比；
- 连续模式页眉显示书名、章节、章节百分比、时间和电量；
- Route 通过 `ReaderPlatformService` 轮询平台电量并写入 `ReaderUiState`，UI 不直接访问平台桥；
- Android/iOS Flutter 宿主桥新增阅读亮度设置、退出恢复和电量读取；
- 方向锁定使用 Flutter `SystemChrome.setPreferredOrientations`，退出阅读器时恢复跟随系统；
- 平台电量或亮度不可用时降级为隐藏电量或跟随系统，不阻断正文阅读。

2026-07-20 已接入单章换源和离线下载（前台运行范围），详见
[m11/chapter_change_source](../m11/chapter_change_source/README.md) 和
[m11/offline_download](../m11/offline_download/README.md)：

- 单章换源新增 `model/reader/chapter_title_matcher.dart`（移植 `BookHelp.getDurChapter` 模糊匹配）、
  `model/web_book/change_chapter_source_coordinator.dart`（复用整书换源的多源搜索基础设施）和
  `ui/change_chapter_source/` 三件套；作为阅读器新增 `ReaderSheet` 变体接入，不是整页导航。
- 单章换源正文替换写入 `ReaderCacheGateway.saveChapterContent(..., deadline: 0)`，复用 `caches`
  表已有的“永久缓存”语义；`ReadBookCoordinator` 新增 `invalidateChapter` 清理内存 LRU，避免正在
  阅读的章节被旧内存内容挡住新缓存；"刷新本章"天然充当撤销。
- 离线下载新增 `download_tasks` 表（schemaVersion 2→3）、`DownloadTaskDao`/`DownloadGateway`/
  `DownloadRepository` 和 App 级单例 `model/reader/download_coordinator.dart`：`DownloadCoordinator`
  （事件驱动调度、有界并发、失败重试封顶 3 次）；正文同样写入永久缓存，与单章换源共用存储路径。
- 离线下载明确不包含 Android 式前台服务/通知、暂停恢复和跨书全局缓存管理仪表盘；应用被系统回收
  或退出后下载停止，下次打开只恢复继续调度，不补下线期间的下载。
- "后续能力"面板移除"单章换源"和"离线下载"两项禁用占位。

AI 未运行 `flutter analyze`、`dart analyze`、测试、构建或应用启动；是否可用以用户运行结果为准。

## 1. Android 对照范围

本次优先级盘点以以下 Android 阅读器文件为基准：

| 职责 | Android 文件 | 说明 |
|---|---|---|
| 阅读状态与 Intent | `app/src/main/java/io/legado/app/ui/book/read/ReadBookContract.kt` | Android 阅读器完整 UiState、Intent、Effect、Sheet、Dialog 和菜单配置。 |
| 阅读 Route | `app/src/main/java/io/legado/app/ui/book/read/ReadBookRouteScreen.kt` | ActivityResult、平台能力、导航、Effect 接线。 |
| 阅读主 UI | `app/src/main/java/io/legado/app/ui/book/read/ReadBookScreen.kt` | Dialog、Sheet、返回逻辑和无状态 UI 容器。 |
| 阅读菜单 | `app/src/main/java/io/legado/app/ui/book/read/ReadBookMenuBar.kt` | 顶栏、底栏、亮度条、进度条、工具按钮、菜单路由。 |
| 阅读协调器 | `app/src/main/java/io/legado/app/model/ReadBook.kt` | 当前书、章节、页面、预下载、保存进度、朗读、读时记录。 |
| 页面系统 | `app/src/main/java/io/legado/app/ui/book/read/page/**` | 分页、滚动、翻页动画、文字布局、页眉页脚、图片/评论列。 |
| 样式面板 | `app/src/main/java/io/legado/app/ui/book/read/sheet/ReadStyleSheet.kt`、`TextTitleSheet.kt`、`SystemMenuPage.kt` | 阅读样式、文字标题、全局主题、菜单外观、亮度和系统配置。 |
| 阅读行为面板 | `ReadAloudSheet.kt`、`AutoReadSheet.kt`、`ClickActionConfigSheet.kt`、`PageKeyConfigSheet.kt` | 朗读、自动翻页、点击区域、实体按键。 |
| 内容处理面板 | `EffectiveReplacesSheet.kt`、`ContentProcessesSheet.kt`、`ContentEditSheet.kt`、`HighlightRuleConfigSheet.kt` | 替换规则、生效列表、内容编辑、高亮规则。 |
| 章节/来源能力 | `ChangeChapterSourceSheet.kt`、`DownloadSheet.kt`、`CharsetConfigSheet.kt` | 单章换源、离线缓存、编码设置。 |
| 菜单资源 | `app/src/main/res/menu/book_read*.xml`、`bookmark.xml` | 刷新、换源、下载、书签、进度、书源、日志等旧菜单清单。 |

Flutter 当前目标文件：

| 职责 | Flutter 文件 | 当前状态 |
|---|---|---|
| Contract | `flutter_app/lib/src/ui/reader/reader_contract.dart` | 已有基础正文、目录、设置、书签、搜索、替换统计、换源入口、系统 Effect。 |
| ViewModel | `flutter_app/lib/src/ui/reader/reader_view_model.dart` | 已有初始化、章节加载、进度保存、书签、配置、当前章搜索和预加载。 |
| Route | `flutter_app/lib/src/ui/reader/reader_route.dart` | 已接入生命周期、滚动恢复、目录/设置/书签/搜索/替换统计底部面板、换源导航和平台系统栏。 |
| Screen | `flutter_app/lib/src/ui/reader/reader_screen.dart` | 已有基础 AppBar、BottomBar、连续滚动、分页模式入口、错误重试。 |
| 分页布局 | `flutter_app/lib/src/ui/reader/reader_page_layout.dart` | 已有简化左右/上下分页，但未覆盖 Android 多动画和复杂排版。 |
| P2～P4 辅助面板 | `flutter_app/lib/src/ui/reader/reader_action_sheets.dart` | 已有当前章搜索、书签备注编辑、替换统计和后续能力边界面板。 |
| 正文协调 | `flutter_app/lib/src/model/reader/read_book_coordinator.dart` | 已有正文加载、缓存、替换、预加载和内存释放。 |
| 平台能力 | `flutter_app/lib/src/platform/reader_platform_service.dart` | 已有沉浸系统栏和屏幕常亮，尚缺亮度、方向、按键等能力。 |

## 2. 当前 Flutter 差距摘要

Flutter 当前阅读器已经能支撑第一批文本阅读闭环，但距离 Android 阅读界面的完整 UI 功能还有明显差距：

| 能力 | Android 当前表现 | Flutter 当前表现 | 差距 |
|---|---|---|---|
| 菜单视觉 | 沉浸正文上叠加顶栏、底栏、可配置工具按钮、亮度条、进度条 | 默认 AppBar + BottomAppBar | 缺少阅读器专属 Overlay、进度拖动、亮度条和工具按钮配置。 |
| 阅读手势 | 点击区域可配置，上一页/下一页/菜单/自定义动作 | 点击切换菜单，滚动边界切章 | 缺少点击区域、长按选择、双击、按键翻页和鼠标滚轮策略。 |
| 翻页方式 | 覆盖、仿真、滑动、滚动、淡入、无动画等 | 连续滚动 + 简化分页 | 缺少动画配置、阅读模式切换细节、分页页眉页脚和双页模式。 |
| 阅读样式 | 多套样式、背景图、日夜/EInk、字体、标题、阴影、下划线、高亮 | 字号、行距、段距、左右边距、三套配色 | 缺少完整样式体系和分层配置面板。 |
| 页眉页脚 | 书名、章节、时间、电量、进度、分割线、位置和字体 | 分页页脚仅显示页码 | 缺少连续/分页统一的信息栏配置。 |
| 目录与进度 | 目录、进度滑杆、跳章确认、卷标题跳转 | 目录 Sheet + 前后章按钮 | 缺少进度滑杆、章节范围预览、卷跳转和跳章确认。 |
| 书签 | 添加、编辑、删除、导出、Markdown 导出 | 添加、跳转、删除 | 缺少备注编辑和导出。 |
| 正文搜索 | 阅读内搜索、结果跳转和搜索底栏 | 无阅读内搜索 | 缺少当前书正文搜索 UI 和结果定位。 |
| 替换/净化 | 替换开关、生效规则、规则编辑、内容处理列表 | 替换开关和生效数量 | 缺少生效列表、编辑入口、内容处理管理和高亮规则。 |
| 内容操作 | 内容编辑、反转正文、重分段、删除 ruby/h 标签、编码设置 | 基础刷新/重试 | 缺少本地 TXT/EPUB/网络章节编辑和格式处理 UI。 |
| 换源 | 整书换源、单章换源、章节源保存 | 整书换源入口 | 缺少单章换源和章节内容替换 Sheet。 |
| 离线缓存 | 下载当前/后续/范围章节 | 预加载相邻章 | 缺少用户可控离线下载 UI 和范围选择。 |
| 朗读/TTS | 阅读朗读、暂停、上一段/下一段、引擎、HTTP TTS、缓存清理 | 无 | 属后续大功能，需单独迁移。 |
| 自动翻页 | 自动阅读、速度和方向配置 | 无 | 缺少自动翻页引擎和控制面板。 |
| 系统能力 | 亮度、自动亮度、方向锁定、常亮、状态栏/导航栏、音量键 | 常亮和沉浸系统栏 | 缺少亮度、方向、实体键和更多系统栏策略。 |
| AI/高级能力 | 章节总结、AI 清理、AI 改写、预设管理 | 无 | 依赖 AI 能力和内容编辑链路，后续迁移。 |

## 3. 优先级原则

优先级按以下顺序判断：

1. 是否影响“书架 → 阅读 → 保存/恢复 → 继续阅读”的核心闭环。
2. 是否是阅读过程中高频可见或高频操作的 UI。
3. 是否会阻塞后续高级功能挂载，例如菜单路由、Sheet/Dialog、配置模型和平台 Effect。
4. 是否依赖尚未完成的数据表、平台通道、规则兼容或外部服务。
5. 是否需要大量复杂排版、TTS、AI、文件下载等独立子系统。

## 4. P0：阅读器外壳和核心操作对齐

P0 目标：先让 Flutter 阅读界面从“普通页面”变成“沉浸阅读器”，补齐高频入口和稳定操作布局。

| 项目 | Android 对照 | Flutter 目标 | 验收 |
|---|---|---|---|
| 阅读 Overlay 外壳 | `ReadBookMenuBar` 顶栏/底栏 | 用阅读专属 Overlay 替代默认 AppBar/BottomAppBar；正文不被菜单永久挤压 | 点击中央切换菜单，菜单显示/隐藏有稳定动画，正文不跳动。 |
| 顶栏 | `MenuTitleBar` | 返回、书名/章节、刷新、换源、更多菜单；本地书隐藏网络书源项 | 图标显隐按书籍类型正确，长标题不溢出。 |
| 底栏工具区 | `ToolButtonContent` | 目录、上一章、下一章、书签、设置、换源/刷新常用入口 | 单手可点，禁用状态清楚，横竖屏不重叠。 |
| 章节进度 | `ReadMenuSlider`、`SeekToChapter` | 章节进度滑杆和当前章节/总章节显示，松手后跳章 | 拖动中显示目标章节，取消/越界不写入错误进度。 |
| 阅读状态信息 | `time`、`battery`、`seekProgress` | 页面可显示章节名、页/章进度、时间、电量的最小可用信息 | 没有电量权限或平台不支持时降级为隐藏。 |
| 返回行为 | `BackHandler` | 搜索/菜单/面板/自动翻页优先关闭，最后保存进度退出 | Android 返回手势只退出一次，退出前保存进度。 |

P0 不做：完整样式管理、TTS、自动翻页、AI、离线缓存、单章换源。

## 5. P1：阅读设置高频项补齐

P1 目标：把用户每天会调的显示和系统设置接到 Flutter，并保持配置可持久化、可恢复、可重排。

| 项目 | Android 对照 | Flutter 目标 | 验收 |
|---|---|---|---|
| 设置面板分层 | `ReadBookMenuRoute.ReadStyle`、`TextTitle`、`PaddingConfig` | 将当前简化设置拆成“样式 / 文字 / 间距 / 系统”页签或二级菜单 | 设置项不堆在一个长 Sheet，面板关闭不丢已应用配置。 |
| 字体与排版 | `TextTitleSheet` | 字号、字体、粗细、斜体、字距、行距、段距、缩进 | 修改后正文即时重排并尽量保持字符锚点。 |
| 页面边距 | `PaddingConfigSheet` | 上下左右边距、安全区避让 | 刘海屏、横屏、折叠宽屏不遮挡正文。 |
| 主题和配色 | `ReadStyleSheet`、`BgTextConfigSheet` | 多套阅读样式、日/夜切换、背景色、文字色，先不做背景图 | 深色模式可读，日夜切换不改变阅读位置。 |
| 亮度 | `BrightnessBar`、`SetBrightness` | 阅读内亮度滑杆和跟随系统开关，使用平台 Effect | Android/iOS 平台不支持项明确降级，不影响常亮。 |
| 常亮和系统栏 | `KeepLightChanged`、`UpSystemUiVisibility` | 扩展现有常亮/沉浸为设置面板中的稳定项 | 退出阅读器后恢复进入前状态。 |

P1 不做：阴影/下划线/高亮规则的完整编辑器、背景图导入导出、菜单玻璃效果个性化。

## 6. P2：目录、书签、搜索和内容刷新

P2 目标：补齐阅读过程中的常用内容定位、标记和刷新能力。

| 项目 | Android 对照 | Flutter 目标 | 验收 |
|---|---|---|---|
| 目录增强 | `OpenChapter`、`SkipToPage`、`menu_chapter_actions.xml` | 目录支持当前章定位、卷标题折叠/跳转、跳章确认 | 大目录打开不卡顿，点击卷标题不误开正文。 |
| 书签编辑 | `ReadBookSheet.Bookmark`、`bookmark.xml` | 书签备注编辑、删除确认、导出文本/Markdown | 编辑失败不覆盖旧书签，导出走 Route Effect。 |
| 阅读内搜索 | `ReadBookSearchBar`、`SearchBottomMenuContent` | 搜索当前书/当前章，显示结果数，上一条/下一条跳转 | 搜索结果跳转保持章节和字符锚点正确。 |
| 刷新菜单 | `book_read_refresh.xml` | 刷新当前章、刷新后续、刷新全部；当前章刷新可绕过缓存 | 刷新失败保留旧内容并显示错误，不伪装成功。 |
| 替换规则入口 | `EffectiveReplacesSheet` | 查看本章生效替换规则，入口跳转替换规则管理或保留提示 | 生效数量与正文处理结果一致。 |
| 内容处理状态 | `sameTitleRemoved`、`reSegment`、`delRubyTag`、`delHTag` | 先补开关 UI 和明确支持边界；真实处理按格式逐项接线 | 不支持格式隐藏或提示，不对所有书籍强行显示。 |

P2 不做：复杂高亮规则编辑器、AI 清理/改写、完整内容编辑保存到源。

## 7. P3：阅读模式、翻页动画和高级样式

P3 目标：补齐 Android 阅读器最有体感差异的翻页和排版功能，但不阻塞 P0～P2。

| 项目 | Android 对照 | Flutter 目标 | 前置依赖 |
|---|---|---|---|
| 翻页动画 | `page/delegate/*`、`PageAnimConfigSheet` | 覆盖、滑动、无动画、滚动优先；仿真翻页单独评估 | 需要 Flutter 分页引擎稳定和手势冲突处理。 |
| 页眉页脚 | `HeaderFooterPage` | 书名、章节、时间、电量、百分比、页码，可配置位置和颜色 | 需要 P0 状态信息和分页/滚动统一渲染。 |
| 高级文字效果 | `ShadowSetSheet`、`UnderlineConfigSheet`、`HighlightRuleConfigSheet` | 阴影、下划线、正则高亮规则 | 需要富文本分段渲染，不应把整章变成单个超大 TextSpan。 |
| 背景图和样式导入导出 | `BgTextConfigSheet`、`ReadStyleImageSelected` | 背景图选择、样式导入导出 | 需要文件选择、沙盒复制和跨平台路径策略。 |
| 菜单外观配置 | `SystemMenuPage`、`ToolButtonConfigSheet`、`TitleBarIconSheet` | 工具按钮启停、排序、菜单位置、按钮文字显示 | 需要稳定按钮 ID 和配置存储模型。 |
| 双页/横屏优化 | `DoubleHorizontalPage`、`Orientation` | 宽屏双页和方向锁定 | 需要平台方向接口和分页测量增强。 |

## 8. P4：依赖型完整功能

P4 目标：登记 Android 阅读器完整功能，但必须等对应业务子系统成熟后再迁移，不能用 UI 空壳宣称完成。

| 项目 | Android 对照 | Flutter 处理策略 |
|---|---|---|
| 单章换源 | `ChangeChapterSourceSheet` | 已接入（[m11/chapter_change_source](../m11/chapter_change_source/README.md)），等待用户真机验收。 |
| 离线下载 | `DownloadSheet`、`DownloadChapters` | 已接入前台运行范围（[m11/offline_download](../m11/offline_download/README.md)）；Android 式前台服务/通知、暂停恢复和跨书仪表盘仍延后。 |
| 朗读/TTS | `ReadAloudSheet`、`ReadAloudConfigSheet`、HTTP TTS 系列 Intent | 单独作为 TTS Feature 迁移，包含平台音频焦点、媒体按钮、后台播放和缓存清理。 |
| 自动翻页 | `AutoReadSheet`、`AutoPager` | 等分页/滚动引擎稳定后接入速度、方向、暂停和退出保存。 |
| 内容编辑 | `ContentEditSheet`、`SaveChapterContent` | 先支持本地书或缓存章节，再评估网络源回写；不能误改书源原始数据。 |
| 编码设置 | `CharsetConfigSheet` | 主要面向本地 TXT，等本地书导入和重新解析链路稳定后接入。 |
| 图片操作 | `PhotoSheet`、`RefreshImage`、`SaveImage` | 等正文图片列渲染、图片缓存和保存权限策略明确后接入。 |
| 阅读记录 | `ReadRecordRepository`、自动保存会话 | 需要 Flutter 读时记录表和后台计时策略；不能只显示本次临时时长。 |
| AI 总结/清理/改写 | `ChapterSummarySheet`、`AiTextCleanSheet`、`AiTextRewriteSheet` | 等 AI 能力和内容替换确认链路稳定后接入。 |
| 同步进度 | `uploadProgress`、`syncProgress` | 等 WebDAV/云同步能力迁移后接入冲突 Dialog。 |
| 日志与帮助 | `AppLogSheet`、`menu_help` | 低频调试入口，等全局日志页面稳定后可从更多菜单进入。 |

## 9. 建议实施顺序

1. 扩展 `ReaderContract`：新增菜单路由、更多菜单动作、进度滑杆、亮度、搜索、书签编辑、刷新和设置分层所需状态。
2. 改造 `ReaderScreen`：从默认 Scaffold 菜单改为沉浸 Overlay，正文区域保持无业务逻辑。
3. 拆分 UI 文件：建议新增 `reader_menu_overlay.dart`、`reader_settings_sheet.dart`、`reader_toc_sheet.dart`、`reader_bookmark_sheet.dart`，避免 `reader_route.dart` 继续膨胀。
4. 改造 `ReaderRoute`：集中处理平台 Effect、系统分享/导出、亮度、返回拦截、Sheet/Dialog 生命周期。
5. 改造 `ReaderViewModel`：按 P0/P1 只接入已有业务能力；未实现功能发出明确提示或隐藏入口。
6. 为 P2 之后的能力补映射文档：单章换源、离线下载、TTS、AI、内容编辑都必须有独立行为清单和验收。
7. 每完成一个批次，更新 `m08/README.md`、本文件实施快照、`AI_PROJECT_INDEX.md` 和必要的功能矩阵。

## 10. 验收清单

P0 验收：

- 从书架打开网络书和本地 TXT/EPUB，阅读界面进入沉浸模式，不再像普通 App 页面。
- 点击正文中央显示/隐藏菜单；菜单关闭时正文可继续滚动或翻页。
- 顶栏返回、刷新、换源、更多入口显隐正确；本地书不显示无效书源操作。
- 底栏目录、书签、设置、上一章、下一章可用，边界章节禁用状态明确。
- 进度滑杆可跳章，跳转前保存当前进度，跳转后显示目标章节。
- 退出、后台、旋转或分屏后再次进入，仍恢复到正确章节和接近原文字。

P1 验收：

- 字号、字体、行距、段距、边距、主题、亮度和常亮设置按用户操作生效并持久化。
- 标题显示/对齐、标题字号/字重/上下留白、首行缩进和两端对齐在分页与连续模式中一致生效并持久化。
- 配置变化后正文重排不回到章首，至少恢复到接近原字符位置。
- 深色、浅色、护眼和大字号下，菜单和正文没有重叠、溢出或不可读。
- 平台不支持的亮度/方向/电量能力有明确降级，不出现无响应按钮。

P2 验收：

- 目录能定位当前章，阅读内搜索结果能在当前章或整书范围内跳转。
- 书签可新增、编辑备注、删除和导出；取消操作不写入数据。
- 当前章刷新、后续刷新、全部刷新状态明确，失败不覆盖可读旧正文。
- 替换规则生效列表与正文处理结果一致。

P3/P4 验收：

- 每个高级能力都有 Android 对照、Flutter 入口、业务写入位置、平台差异和失败行为。
- TTS、AI、离线下载、同步等依赖型能力未实现前不展示假入口，或展示明确“待迁移”说明。
- 覆盖翻页、无动画、滑动、页眉页脚、底部工具文字和基础文字效果配置能持久化并在正文中生效。
- 长章节首次分页先显示首批页面，后台分批续算完整页数；相同布局返回时命中有界缓存，不重复整章分页且不无界占用内存。

## 11. 风险和边界

### 11.1 当前仍未完成

阅读核心体验仍可独立继续的项目：

- 超长章节首屏增量分页已接入，但仍需真机确认极端单段长文本、低端设备帧率和后台续算期间的触摸手感；
- 点击区域和音量键翻页配置已接入，但仍需真机确认 Android/iOS 是否都能收到系统音量键事件；真正文本选择、双击、鼠标滚轮和更复杂自定义动作尚未完成；
- 页眉页脚已接入时间、电量、书名、章节名、页码和章节百分比，但仍缺分割线、位置、字体、颜色和更多 Android 细项配置；
- 复杂翻页尚缺仿真、淡入和滚动动画，宽屏双页尚未接入；基础方向锁定已接入但仍需真机确认；
- 背景图、字体文件选择、样式导入导出、正则高亮和菜单按钮排序尚未完成；
- 当前书全文搜索、书签 Markdown 导出、刷新后续/全部章节和完整替换规则列表已接入；内容处理编辑器尚未完成。

依赖底层子系统后才能继续的项目：

- 自动亮度策略、实体按键真机兼容和更完整的系统栏策略；
- 单章换源、离线下载队列（应用前台运行范围）已接入，等待真机验收；离线下载的 Android 式前台服务/通知、暂停恢复仍延后；TTS/后台音频、自动翻页、正文编辑、阅读记录和同步进度仍未开始；
- 正文图片操作、UMD/MOBI/AZW/PDF/压缩包完整阅读、AI 总结/清理/改写；
- JavaScript 正文书源仍受 M4 门禁约束，不能因阅读 UI 完成而宣称真实书源全量可用。

### 11.2 建议继续顺序

1. 继续优化页眉页脚样式细项，例如分割线、字体、颜色、位置和宽屏双页布局。
2. 继续优化分页后台任务的可取消粒度和进度反馈，真机确认后再评估是否需要 isolate 外挂测量替代方案。
3. 做真正文本长按选择、复制、划线或高亮规则入口，需要先把富文本/选择态模型设计清楚。
4. 为内容处理编辑器、正则高亮规则和单章换源分别补行为文档，避免把依赖型能力混进阅读 UI 主链路。
5. 最后按独立 Feature 推进离线下载、TTS、自动翻页、单章换源和同步，不与分页核心继续耦合。

- M4 JavaScript 兼容仍为 `BLOCKED`，脚本正文书源的阅读结果不能因 UI 完成而宣称完整可用。
- M9/M10 真机验收未完成，亮度、方向、文件选择、系统栏、电量、TTS 和媒体按钮都需要用户设备验证。
- 阅读位置必须继续使用章节 URL、章节索引、字符位置和摘要锚点；不能退回只保存像素。
- 高级富文本、高亮、图片列和仿真翻页会影响正文排版模型，应单独验证性能和内存。
- 新增手写文件后必须更新 `AI_PROJECT_INDEX.md`，并在交付时询问是否加入 Git 暂存区。
