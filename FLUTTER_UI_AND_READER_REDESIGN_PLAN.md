# Legado Flutter UI 与文本阅读器重构方案

> 文档状态：`IN_PROGRESS / 已开始按 Feature 实施，等待用户运行验收`  
> 创建日期：2026-07-16  
> 适用范围：Flutter 全局视觉、响应式布局、书架、搜索、书籍详情、书源管理、设置、文本阅读器、阅读预取与同书不同源入架逻辑。  
> 阶段归属：跨 M6、M7、M8，并为 M11 的高级阅读与缓存能力建立实施边界。

## 0. 2026-07-16 实施快照

本轮已经写入但尚未经过用户运行验收的内容：

- R1 第一批：暖纸色 Material 3 Token、组件主题、手机底部导航、平板/桌面 NavigationRail，以及保留四个一级页面状态的正式应用 Shell；
- R1 紧凑修订：根据用户反馈把全局视觉方向调整为“简约、低装饰、视觉尺寸约缩小 30%”，已收紧字体、间距、圆角、导航栏、输入框、列表、按钮、阅读默认字号、书架封面、搜索封面和详情封面；触摸热区仍保留不低于 44 logical pixels 的可访问性底线；
- R2 首页修订：书架网格继续缩小约 30%，搜索结果与书源列表继续缩小约 20%，底部导航标签固定为 8sp；书源和书架搜索框改为低高度轻量样式，原“设置”一级入口重构为包含本地资料、真实最近阅读、主题、多语言、书源、日志和关于的“我的”页面；
- R2 第一批：书架、搜索、详情的内容宽度与书籍封面层级；Android 对齐的 `inShelf / sameNameAuthor / notInShelf` 判断；替换并迁移用户事实、明确新增副本、取消三种冲突操作；
- R3 第一批：连续滚动章末自动进入下一章、章首下拉进入上一章并定位章尾，以及相邻切章并发防抖；
- R4 第一批：按当前屏幕、字号、行距和边距动态计算的左右分页与上下分页，支持滑动、左右点击和稳定字符锚点恢复；
- R5 第一批：预下载数量设置，以及后向范围、前向最多五章、并发 2、连续失败 3 次停止和旧队列取消；
- 新增文件已同步加入 `AI_PROJECT_INDEX.md`，原 Android 参考实现保持只读。

仍未完成且不得宣称完成的内容：仿真/覆盖/淡入等独立翻页呈现层、真正同时保留多章 Widget 的有限章节窗口、亮度/字体/字重/首行缩进等高级设置、预取状态可视化、离线下载队列、其余低频页面的逐页视觉重构，以及 Android/iOS 真机验收。

以下“当前实现审计”保留为实施前基线，用于对照本轮改动，不表示代码仍停留在该状态。

## 1. 文档目标

本方案的唯一目标是：在不破坏现有书源、搜索、目录、书架和正文业务链路的前提下，为 Flutter 应用建立一套可长期维护的简约视觉系统，并将当前基础上下滚动阅读页重构为支持连续章节、分页模式、阅读设置和可配置预取的完整文本阅读器。

本方案同时修复以下已确认问题：

1. 当前 Flutter 首页仍是工程骨架入口，所有业务页面缺少统一的产品级导航和视觉层级。
2. 页面大量直接使用默认 `AppBar`、`Card`、`ListTile`，视觉密度、内容宽度和交互层级不统一。
3. 当前阅读器只能在单章内上下滚动，滚动到章末仍需手动点击下一章。
4. 当前阅读器没有覆盖、滑动、淡入、无动画、仿真等翻页模式，也缺少完整的阅读自定义设置。
5. 当前 Flutter 阅读预加载只处理前后相邻章节，没有对齐 Android 可配置预下载范围、并发和失败控制。
6. Flutter 只按 `bookUrl` 判断是否已在书架，同名同作者但来源不同的书会静默成为两条书架记录。

本方案边界不包含：

- 修改原 Android 业务代码；
- 漫画阅读器、音频播放、TTS、RSS、Web 服务和 AI 功能实现；
- 对原 Android 阅读器进行重构；
- 更换数据库格式、书源格式或 JavaScript 对外 API；
- 在用户确认前把任何阶段状态标记为 `ANDROID_READY`、`IOS_READY` 或 `DONE`。

## 2. 强制实施原则

1. 原 Android 实现继续作为行为基准，只读，不因 Flutter 重构修改原业务代码。
2. 视觉可以重新设计，但功能入口、操作含义、数据保存时机、错误路径和返回行为必须保留。
3. Flutter 页面继续使用 Contract、ViewModel、Route、Screen 分层：
   - Screen 只渲染 `UiState` 并发送 `Intent`；
   - ViewModel 维护业务状态并调用 UseCase 或协调器；
   - Route 处理导航、系统能力、对话框和一次性 `Effect`；
   - DAO、HTTP、规则解析、文件系统和平台通道不得进入 Widget。
4. 阅读进度必须以章节稳定标识和章节内字符锚点为事实，页码、滚动比例和像素只能作为当前布局的临时投影。
5. Android 与 iOS 使用同一套 Flutter 视觉和阅读状态机；亮度、方向、常亮等系统能力通过窄平台接口实现。
6. 新增依赖前必须单独说明用途、维护状态、Android/iOS 支持和替代方案；本方案优先使用 Flutter SDK 与现有依赖。
7. 每次只实施一个可验收 Feature，避免把全局主题、书架冲突、分页引擎和缓存下载一次性混成一个不可验证改动。

## 3. 当前实现审计

### 3.1 全局 UI

当前 UI 基础入口：

| 职责 | 当前 Flutter 文件 | 已确认问题 |
|---|---|---|
| 应用首页 | `flutter_app/lib/src/ui/home/welcome_screen.dart` | 仍展示“验证骨架交互”和功能按钮，不是正式产品主框架 |
| 全局主题 | `flutter_app/lib/src/ui/theme/app_theme.dart` | 只有基础 Material 3 Theme，缺少页面级组件主题和响应式规则 |
| Design Token | `flutter_app/lib/src/ui/theme/app_tokens.dart` | 已有颜色、字号、间距、圆角基础，但没有完整内容宽度、导航、表单、书籍和阅读器 Token |
| 页面骨架 | `flutter_app/lib/src/ui/components/app_scaffold.dart` | 仅统一 `Scaffold` 和 `SafeArea`，没有紧凑/中等/扩展布局和主导航策略 |
| 公共组件 | `flutter_app/lib/src/ui/components/` | 当前组件数量较少，多数页面继续直接组装 Material 默认控件 |

页面层现状：

- 搜索结果使用统一书籍图标，没有封面主信息，来源和书架状态的区分较弱。
- 书籍详情缺少封面主视觉、固定主要操作区和简介/目录的清晰层级，完整目录直接铺在详情页中。
- 书架列表和网格虽然共享状态，但搜索、分组、排序、刷新和布局切换集中在顶部，紧凑屏容易拥挤。
- 书源、换源、本地导入、设置和日志页面仍以大量 Card/ListTile 为主要布局语言。
- 当前只有部分网格根据宽度计算列数，尚未形成覆盖手机横屏、平板、折叠屏和大字号的统一适配策略。

### 3.2 文本阅读器

当前阅读器主链：

```text
ReaderRoute
  -> ReaderViewModel
  -> ReadBookCoordinator
  -> ReaderRepository / ReaderTextProcessor
  -> ReaderScreen
```

已存在并应保留的能力：

- 正文缓存、净化、替换和分块；
- 当前请求与旧请求的世代隔离；
- 章节 URL、字符位置和摘要组成的稳定锚点；
- 目录跳转、书签、错误重试、常亮和系统栏；
- 字号、行距、段距、左右边距和基础配色；
- 前后相邻章节预加载；
- 正常退出、切章和后台时保存进度。

当前结构性限制：

1. `ReaderScreen` 固定使用单章 `ListView.builder`，章末显示“阅读下一章”按钮。
2. `ReaderUiState` 没有页面排版结果、翻页模式、页面索引、章节窗口和预取状态。
3. `ReaderDisplayConfig` 只保存基础排版、配色、替换和常亮配置。
4. `ReadBookCoordinator.preloadAdjacent` 只处理相邻章节，没有 Android 的预下载数量、前后范围、并发和失败次数语义。
5. 当前字符位置通过滚动比例估算；作为初版锚点投影可以保留，但不能作为分页和连续章节的最终首个可见字符算法。

### 3.3 同书不同源入架

当前 Flutter 行为：

```text
BookInfoViewModel
  -> BookshelfGateway.getBook(bookUrl)
  -> 仅判断当前 URL 是否存在
  -> AddBookToBookshelfUseCase
  -> BookRepository.addBook
  -> 按 bookUrl 主键 upsert
```

因此，同名同作者但不同来源的 `bookUrl` 会被视为两本不同书并直接写入。

Android 对照行为：

- `ResolveBookShelfStateUseCase` 区分 `IN_SHELF`、`SAME_NAME_AUTHOR` 和 `NOT_IN_SHELF`；
- `BookDao.getShelfBookConflict(name, author)` 只查真正位于书架中的同名同作者书籍；
- 发生冲突时提示用户：
  - 替换现有书源并保留阅读数据；
  - 用户明确确认后仍然新增一本；
  - 取消则不写数据库。

Flutter 不应给 `books(name, author)` 增加唯一约束，因为 Android 仍允许用户显式保留两份副本，也不能把同名同作者永久等价为同一本书。

## 4. 外部 UI 参考与取舍

外部产品只用于提炼信息层级和交互模式，不复制品牌、插画、图标或专有视觉资产。

### 4.1 Apple Books

参考：[Apple Books iPhone 阅读说明](https://support.apple.com/guide/iphone/read-books-iphc1af7c57/ios)

可吸收：

- 阅读时默认隐藏工具栏，让正文成为唯一主视觉；
- 阅读设置使用覆盖在正文上的底部面板；
- 先展示主题预设和字号快捷操作，再进入高级自定义；
- 将连续滚动和逐页翻页作为同一阅读器的不同呈现方式。

不照搬：

- Apple 专属排版和页面卷曲动画；
- 与 Apple Books 商店、阅读目标和账号体系相关的入口。

### 4.2 Kindle

参考：[Kindle App 官方介绍](https://www.aboutamazon.com/news/devices/kindle-app-guide)

可吸收：

- 使用统一的“阅读样式”入口集中字体、字号、页面颜色和排版密度；
- 常用设置保持短路径，高级设置不占用阅读工具栏；
- 书架以封面、书名和阅读进度为主，管理操作退居次级菜单。

### 4.3 Moon+ Reader

参考：[Moon+ Reader Google Play 页面](https://play.google.com/store/apps/details?id=com.flyersoft.moonreader)

可吸收：

- 多种翻页效果和速度设置；
- 点击区域、滑动手势、最大化阅读空间和高度自定义能力；
- 高级功能保留，但通过分层设置避免一次展示全部选项。

不照搬：

- 复杂且密集的配置菜单；
- 依赖 Android 特有能力的长期业务实现。

## 5. 视觉方向

### 5.1 总体风格

采用“简约紧凑、低干扰、内容优先”的风格：

- 主色使用克制的灰绿色，只在选中、主操作和少量状态上出现；
- 普通页面使用平坦 Surface 和细分割，不再把每个列表项都做成厚重 Card；
- 字体、间距、圆角、封面和控件视觉尺寸以缩小约 30% 为默认方向；
- 触摸区域不能跟随视觉尺寸无限缩小，主要可点击区域仍保持不低于 44 logical pixels；
- 阅读页使用浅灰白、护眼绿、深灰黑等低刺激主题，默认字号和边距偏小；
- 卡片只用于需要形成独立语义的内容，不作为默认列表容器；
- 书封统一使用 2:3 比例，封面、书名、作者和阅读进度构成书籍主信息；
- 动画只表达导航、选择和面板层级，不添加与任务无关的装饰动画；
- 危险操作仅在确认区域使用错误色，不能让整页长期呈现高警示色。

### 5.2 Design Token 扩展

在现有 Token 基础上补齐：

```text
ColorToken
  -> brand / neutral / success / warning / error
  -> surface / surfaceContainer / scrim / divider
  -> readerPaper / readerEyeCare / readerDark

TypographyToken
  -> display / pageTitle / sectionTitle / bookTitle
  -> body / metadata / label / readerBody / readerChapterTitle

SpacingToken
  -> 保留 4、8、12、16、20、24、32 节奏

RadiusToken
  -> control / card / cover / sheet / dialog

ElevationToken
  -> flat / raised / overlay

DurationToken
  -> feedback / transition / sheet / pageTurn

LayoutToken
  -> compact / medium / expanded
  -> contentMaxWidth / readerMaxWidth / sidePanelWidth
  -> bookCoverRatio / minimumTouchTarget

ReaderToken
  -> 默认字体、行距、段距、边距、主题和分页动画参数
```

禁止业务页面重复声明已经存在的颜色、圆角、内容宽度和动画时长。

### 5.3 公共组件目标

只在两个以上明确页面复用或代表全局约束时创建公共组件：

```text
AdaptiveAppScaffold
AppNavigationBar / AppNavigationRail
AppTopBar
AppSearchBar
AppSectionHeader
AppListItem
AppDialog
AppBottomSheet
AppSelectionBar
AppEmptyView / AppErrorView / AppLoadingView
BookCover
BookGridItem
BookListItem
BookProgressIndicator
SourceListItem
SettingSection
SettingItem
ReaderBottomPanel
ReaderThemePreset
```

阅读器专属组件留在 `ui/reader/`，不能因为单页面复杂就全部提升为全局组件。

## 6. 响应式与适配方案

### 6.1 布局等级

默认按可用宽度而不是设备名称判断：

| 布局等级 | 建议宽度 | 导航和页面形态 |
|---|---:|---|
| Compact | `< 600` | 单栏、底部导航、全宽 BottomSheet |
| Medium | `600～839` | 导航栏或窄 NavigationRail，增大内容留白，可使用宽面板 |
| Expanded | `>= 840` | NavigationRail，书架/详情和书源/编辑器可使用双栏 |

具体阈值在实现时集中进入 `LayoutToken`，业务页面不得各自声明不同断点。

### 6.2 安全区和系统 UI

- `AdaptiveAppScaffold` 统一处理 edge-to-edge、状态栏、底部手势区、刘海和圆角屏；
- 不在所有层级重复添加 `SafeArea`，避免 AppBar、正文和底部导航重复缩进；
- 阅读页背景可以延伸到系统栏，正文、菜单和点击区域必须使用安全区域；
- 键盘弹出时搜索框、表单当前字段和提交操作不能被永久遮挡；
- 使用 `MediaQuery.sizeOf`、`MediaQuery.textScalerOf` 和显示特征判断布局，不缓存过期窗口尺寸。

Flutter 适配参考：[SafeArea 与 MediaQuery](https://docs.flutter.dev/ui/adaptive-responsive/safearea-mediaquery)。

### 6.3 大字号和可访问性

- 普通页面至少验收系统文字缩放 1.0、1.3、2.0；
- 阅读正文继续使用用户独立字号，但菜单和设置遵循系统文字缩放；
- 触摸区域不得小于 44×44 logical pixels；
- 图标按钮必须有语义标签；
- 选中、失败、禁用和缓存状态不能只依靠颜色表达；
- 横屏和平板阅读正文设置最大可读宽度，避免单行过长。

## 7. 应用主框架与页面重构

### 7.1 应用主框架

将当前欢迎页替换为正式应用 Shell：

```text
手机底部导航：书架 / 搜索或发现 / 书源 / 设置
平板侧边导航：NavigationRail + 当前功能内容
```

本地书导入作为书架页面主要操作，不独占一级导航。

Shell 只负责稳定一级目的地和响应式导航，不把搜索、书架刷新或书源业务放入全局状态。

### 7.2 书架

视觉层级：

```text
标题与主要操作
  -> 分组标签
  -> 可收起搜索和排序
  -> 封面网格或紧凑列表
  -> 刷新/失败进度
```

调整目标：

- 默认以封面、书名、当前章节和阅读进度为主；
- 未读数量使用小型 Badge，不与详情按钮争抢空间；
- 搜索默认不长期占据一整行，可通过顶部入口展开；
- 分组使用可滚动标签，排序、正倒序和布局模式进入统一菜单；
- 长按进入选择模式，返回优先退出选择；
- 平板网格按最小卡片宽度计算列数，书籍详情可在右侧面板打开；
- 保留 `bookUrl` 作为列表稳定 key。

### 7.3 搜索

- 搜索输入保持页面首要操作；
- 结果使用真实封面、书名、作者、最新章节、主要来源和来源数量；
- 展示“已在书架”“同书不同源”“未入架”状态；
- 单书源失败折叠到结果之后，不长期占据首屏；
- 多来源结果进入详情后继续保留候选来源；
- 搜索取消后保留已返回结果，旧运行结果不能污染新搜索。

### 7.4 书籍详情和目录

建议结构：

```text
封面 + 书名 + 作者 + 来源
开始阅读 / 加入书架 / 换源
阅读进度或最新章节
简介（折叠）
分类与字数
目录预览
打开完整目录
```

- 完整目录不再直接全部铺在详情主页面；
- 主页面只显示当前阅读章节附近或最近若干章节；
- 完整目录使用 BottomSheet，平板使用侧面板；
- 目录保持稳定章节 key、卷标题和当前章节高亮；
- 未入架书点击章节进入阅读前，仍通过 UseCase 完成入架或冲突处理，不能由 UI 直接写库。

### 7.5 书源管理

- 使用扁平列表而不是每条书源一个高阴影 Card；
- 名称、分组、URL、启用状态和异常状态形成固定信息层级；
- 编辑、调试、登录和删除进入尾部菜单；
- 批量选择后显示固定选择操作栏；
- 手机编辑使用独立页面或全屏面板，平板可以列表/编辑双栏；
- 导入文件、剪贴板、文本和二维码继续保持原入口和错误语义。

### 7.6 设置、导入、换源和日志

- 设置按“阅读、缓存、书源、外观、数据与日志”分区；
- 本地导入使用步骤清晰的选择、预览、冲突和结果状态；
- 整书换源突出当前来源、候选来源、详情/目录加载状态和迁移选项；
- 日志页面保持诊断能力，但普通用户入口退居设置的高级区域；
- 所有页面统一空、加载、可恢复错误、不可恢复错误和权限拒绝状态。

## 8. 文本阅读器目标架构

### 8.1 分层

目标链路：

```text
ReaderScreen
  -> ReaderIntent
  -> ReaderViewModel
  -> ReaderSessionCoordinator
     -> ReadBookCoordinator（正文获取、处理和原始缓存）
     -> ReaderLayoutEngine（滚动块与分页结果）
     -> ReaderPrefetchCoordinator（低优先级预取）
  -> ReaderGateway / ReadingProgressGateway
```

职责要求：

- `ReadBookCoordinator` 继续负责获取、取消、正文处理和原始正文缓存；
- `ReaderLayoutEngine` 只负责将已处理内容映射为当前窗口可呈现的滚动块或页面；
- `ReaderSessionCoordinator` 维护前章、当前章、后章窗口和当前稳定锚点；
- `ReaderPrefetchCoordinator` 负责可取消、有界并发、低优先级的章节预取；
- `ReaderScreen` 只选择对应呈现组件，不执行正文、分页、预取或进度业务。

### 8.2 领域模型

建议新增或扩展概念：

```text
ReaderPresentationMode
  -> continuousScroll
  -> horizontalPage

ReaderPageAnimation
  -> cover
  -> slide
  -> simulation
  -> fade
  -> none

ReaderChapterWindow
  -> previous
  -> current
  -> next

ReaderPageLayout
  -> chapterUrl
  -> chapterIndex
  -> pageIndex
  -> startCharacterOffset
  -> endCharacterOffset
  -> blocks

ReaderPositionAnchor
  -> chapterUrl
  -> chapterIndex
  -> characterOffset
  -> context

ReaderPrefetchState
  -> queued / running / cached / failed / cancelled
```

页面索引和滚动像素不能进入持久进度事实。

## 9. 连续上下阅读

### 9.1 章节窗口

使用有限章节窗口替代当前单章列表：

```text
上一章尾部（按需保留）
当前章节
下一章头部（提前加载）
```

行为：

1. 接近当前章节底部时自动请求下一章并追加；
2. 用户滚过章节边界后自动更新当前章节和持久阅读位置；
3. 不再要求点击“阅读下一章”；
4. 下一章加载失败时在边界显示可重试错误，不清空当前章节；
5. 到最后一章时显示明确结束状态；
6. 向上加载上一章时，插入内容后保持当前视觉锚点不跳动；
7. 默认只保留有限前后章节，移除远离视口的已处理布局，避免无限内存增长；
8. 被移出的章节仍可从原始正文缓存重新处理。

章末按钮可以作为错误恢复或无障碍备用操作，但不能再是进入下一章的唯一方式。

### 9.2 进度判断

滚动模式应根据首个可见正文块和块内字符位置更新锚点，不能继续只使用全列表滚动比例。

保存时机继续包括：

- 受控节流保存；
- 章节边界切换；
- 应用进入后台；
- 正常退出阅读器；
- 换源前；
- 排版模式切换前。

## 10. 分页和翻页模式

### 10.1 第一批模式

建议先实现：

1. 连续上下滚动；
2. 横向滑动；
3. 覆盖翻页；
4. 淡入翻页；
5. 无动画翻页。

仿真卷页作为高风险专项，在页面模型和其他模式稳定后实现。不能把仿真卷页从架构中删除，也不能用普通滑动改名冒充。

Flutter `PageView` 可用于稳定逐页手势和相邻页承载，参考：[PageView](https://api.flutter.dev/flutter/widgets/PageView-class.html)。分页内容、章节边界和稳定锚点仍由阅读状态机控制。

### 10.2 分页要求

- 根据当前可用正文宽高、字体、字号、字重、行距、段距和边距重新生成页面；
- 页尾和页首不能重复或丢失字符；
- 章节最后一页继续翻页时自动进入下一章第一页；
- 快速连续翻页时旧章节加载结果不能覆盖最终目标；
- 页面动画切换不改变内容锚点；
- 横竖屏、分屏、字体和边距变化后重新分页并恢复到原字符附近；
- 当前页、前一页、后一页优先构建，其余页面按需生成；
- 真实文本测量需要 Flutter UI 排版能力，正文净化和复杂正则仍留在后台 isolate，不能把 `TextPainter` 工作错误地伪装成纯后台业务。

## 11. 阅读交互

默认点击区域：

```text
左侧：上一页
中间：显示或隐藏菜单
右侧：下一页
```

连续滚动模式下：

- 上下滑动负责阅读；
- 中间点击显示菜单；
- 左右区域是否翻屏由用户设置控制，避免抢占正文滚动手势。

分页模式下：

- 横向滑动和左右点击翻页；
- 中间点击显示菜单；
- 长按继续预留文本选择入口；
- 边缘系统返回手势优先于自定义翻页手势。

菜单默认隐藏，显示后包含：

- 顶部：返回、章节标题、书签、更多；
- 底部快捷：目录、进度、主题/字体、翻页、上一章/下一章；
- 高级能力进入分层 BottomSheet，不把所有操作同时铺在工具栏。

## 12. 阅读设置

### 12.1 配置层级

配置分为：

```text
全局默认配置
  -> 所有书籍默认继承

单书覆盖配置
  -> 仅保存用户明确覆盖的字段
```

不得继续让每本书都保存一份完整默认配置，否则全局设置变化后无法区分用户覆盖和旧默认值。

### 12.2 设置面板

快捷层：

- 字号减小/增大；
- 亮度与自动亮度；
- 日间/护眼/深色主题；
- 连续滚动/分页；
- 当前翻页动画。

高级层：

| 分组 | 配置 |
|---|---|
| 字体 | 字体、字号、字重、正文颜色、章节标题样式 |
| 排版 | 行距、段距、首行缩进、上下左右边距、对齐方式 |
| 主题 | 背景色、背景图扩展点、文字颜色、跟随系统或手动日夜模式 |
| 翻页 | 阅读模式、动画类型、动画速度、点击区域、滑动方向 |
| 系统 | 亮度、自动亮度、屏幕常亮、方向策略、系统栏 |
| 内容 | 替换规则、重复标题处理、正文刷新和缓存状态 |
| 缓存 | 预下载数量、当前缓存状态、离线下载入口 |

设置改变后应尽量实时预览；影响正文处理或分页的字段通过受控重新处理/重新分页，不得在滑杆每个细微变化时无限创建并发任务。

## 13. 阅读预取与离线缓存

### 13.1 两种能力必须分离

阅读预取：

- 自动、低优先级、临时；
- 目标是保证即将翻到的章节快速显示；
- 可以按缓存策略自动过期。

离线缓存：

- 用户明确选择章节范围；
- 长期持久化；
- 有队列、暂停、继续、失败重试和清理；
- 属于 M11 独立 Feature，不能因阅读预取存在就宣称离线缓存完成。

### 13.2 阅读预取对齐 Android

建议默认配置：

- 预下载数量默认 10；
- 提供 0、2、5、10、20 等清晰选项；
- 当前章节和相邻章节拥有最高优先级；
- 从当前章 `+2` 开始向后预取到配置数量；
- 从当前章 `-2` 开始向前最多预取 `min(5, 配置数量)`；
- 网络预取并发默认 2；
- 单章连续失败达到 3 次后停止自动重试；
- 换书、换源、目录变化、退出阅读器或用户关闭预取时取消旧任务；
- 当前可见请求永远优先于预取；
- 预取失败只更新缓存状态，不弹出当前正文错误；
- 内存中只保留有限处理后章节，原始正文可进入有期限的持久缓存。

### 13.3 iOS 边界

- 前台阅读时可以与 Android 使用同一 Dart 预取状态机；
- 应用进入后台后不能假设可以无限继续网络下载；
- 大范围离线缓存需要根据 iOS 后台限制提供暂停或前台完成提示；
- Android 前台 Service 仅用于平台承载，队列和任务事实仍保留在 Dart。

## 14. 同书不同源入架修复

### 14.1 领域状态

新增与 Android 可搜索映射的状态：

```text
BookShelfState.inShelf
BookShelfState.sameNameAuthor
BookShelfState.notInShelf
```

判断顺序：

1. 书名、作者和 `bookUrl` 完全一致：`inShelf`；
2. 书名、作者一致但 `bookUrl` 不同：`sameNameAuthor`；
3. 其余：`notInShelf`。

书名和作者默认保持 Android 精确匹配语义，不自行 trim、转小写或做模糊归一化。

### 14.2 数据和领域边界

建议扩展：

```text
BookDao
  -> getShelfBookConflict(name, author)

BookshelfGateway
  -> getShelfBookConflict(name, author)

ResolveBookShelfStateUseCase
  -> resolve exact / same-name-author / missing

AddBookToBookshelfUseCase
  -> 返回结构化 AddBookToBookshelfResult
```

建议结果：

```text
added
alreadyInShelf(existingBook)
conflict(existingBook, incomingBook, incomingChapters)
failure(error)
```

`AddBookToBookshelfUseCase` 不直接弹窗；冲突作为领域结果交给 ViewModel，UiState 保存待确认冲突，Screen 渲染对话框。

### 14.3 冲突交互

弹窗展示：

- 书名和作者；
- 现有来源；
- 新来源；
- 现有目录数量和最新章节；
- “替换现有书源并保留阅读数据”；
- “仍然新增一本”；
- “取消”。

操作：

1. 替换现有书源：调用现有整书换源事务和迁移选项，保留阅读进度、分组、排序、封面、简介/备注和单书阅读配置；
2. 仍然新增一本：使用显式 Intent 绕过本次冲突保护，只新增用户确认的第二份记录；
3. 取消：不写入书籍或章节。

从详情目录直接进入阅读器时，如果未入架，也必须复用同一冲突流程，不能静默新增后继续导航。

### 14.4 数据库约束

- 保留 `books.bookUrl` 主键；
- 保留 `(name, author)` 普通索引；
- 不添加 `(name, author)` 唯一索引；
- 如果只增加 DAO 查询和领域状态，不需要数据库 Schema 升级；
- 如果未来增加显式“逻辑书籍 ID”，必须作为单独架构变更，不在本轮静默加入。

## 15. 文件映射建议

以下是实施时的职责建议，不代表文件已经创建：

| Android 对照 | Flutter 现有/建议位置 | 职责 |
|---|---|---|
| `ui/book/read/ReadBookContract.kt` | `ui/reader/reader_contract.dart` | 阅读 UiState、Intent、Effect、Sheet/Dialog |
| `model/ReadBook.kt` | `model/reader/read_book_coordinator.dart` | 当前章节获取、正文处理、相邻内容和取消 |
| `ui/book/read/page/provider/` | `model/reader/reader_layout_engine.dart` | 当前窗口滚动块和分页结果 |
| `ui/book/read/page/delegate/` | `ui/reader/presentation/` | 不同翻页呈现和动画 |
| `model/ReadBook.preDownload()` | `model/reader/reader_prefetch_coordinator.dart` | 有界预取范围、并发、取消和失败控制 |
| `domain/model/BookShelfState.kt` | `domain/model/book_shelf_state.dart` | 书架匹配状态 |
| `domain/usecase/ResolveBookShelfStateUseCase.kt` | `domain/usecase/resolve_book_shelf_state_use_case.dart` | 精确和同名同作者匹配 |
| `BookDao.getShelfBookConflict` | `data/dao/book_dao.dart` | 书架冲突查询 |
| 原生书籍冲突对话框 | `ui/book_info/` 与复用的冲突对话框 | 替换、仍然新增和取消 |

所有新手写文件创建后必须同步更新 `AI_PROJECT_INDEX.md` 和相关阶段映射。

## 16. 分阶段实施顺序

### R0：视觉基线与行为冻结

目标：在代码修改前确认视觉方向和本轮行为范围。

交付物：

- 最终色彩、字体、导航和书籍卡片方向；
- 手机、横屏和平板线框；
- 当前关键页面截图基线；
- 阅读器行为矩阵；
- 同书不同源冲突文案和默认操作确认。

退出条件：用户确认可以进入 UI 基础实施。

### R1：Design Token、公共组件和应用 Shell

目标：建立后续页面不会反复推翻的视觉与适配基础。

范围：

- 主题和 Token；
- Adaptive App Scaffold；
- 手机底部导航和平板 NavigationRail；
- 公共状态、书籍、设置和选择组件；
- 首页替换为正式应用 Shell。

不包含：阅读分页、预取和书架冲突业务。

### R2：书架、搜索、详情与同书冲突

目标：先完成最常使用的选书闭环和数据正确性。

范围：

- 书架视觉和适配；
- 搜索结果视觉；
- 书籍详情和完整目录面板；
- `BookShelfState`；
- 同书不同源冲突查询和对话框；
- 替换现有书源或明确新增副本；
- 搜索、详情和书架状态实时同步。

退出条件：不同来源的同名同作者书不会在无提示情况下产生第二条记录。

### R3：连续章节上下阅读

目标：解决当前最直接的阅读体验问题。

范围：

- 有限章节窗口；
- 章末自动追加下一章；
- 向上加载上一章并保持视口；
- 章节边界进度更新；
- 边界加载失败和重试；
- 不再依赖章末按钮进入下一章。

### R4：分页模型和基础翻页模式

目标：支持真正的逐页阅读。

范围：

- 页面排版结果和稳定字符范围；
- 横向滑动、覆盖、淡入、无动画；
- 点击区域和手势；
- 跨章节自动翻页；
- 字体、方向和尺寸变化后恢复。

仿真卷页进入 R6 专项，不阻塞其他模式验收。

### R5：阅读设置和预取

目标：完善阅读自定义和相邻章节速度。

范围：

- 全局默认与单书覆盖；
- 快捷设置和高级设置面板；
- 字体、排版、主题、亮度、翻页和系统设置；
- 可配置预下载数量；
- 并发 2、失败 3 次、取消和优先级；
- 缓存状态展示。

### R6：其余页面、离线缓存和仿真卷页

按独立 Feature 实施：

1. 书源、换源、本地导入、设置、日志和 PDF 页面视觉统一；
2. 离线缓存队列；
3. 仿真卷页；
4. 横屏、平板双栏、折叠屏和大字号专项；
5. Android 验收后再完成 iOS 对应验收。

## 17. 验收标准

### 17.1 全局 UI

- [ ] 首页不再出现工程骨架验证入口。
- [ ] 书架、搜索、书源和设置拥有稳定一级导航。
- [ ] 所有页面使用统一 Token 和公共组件，不散落重复颜色、圆角和内容宽度。
- [ ] Compact、Medium、Expanded 三档布局没有溢出、遮挡或不可达操作。
- [ ] Android edge-to-edge、iOS Safe Area、横屏和键盘行为正确。
- [ ] 系统文字缩放 1.0、1.3、2.0 时主要操作仍可完成。
- [ ] 深色模式下文字、图标、分割线、选中和禁用状态清晰。

### 17.2 连续阅读

- [ ] 用户滚动到章末后自动加载并进入下一章，无需点击按钮。
- [ ] 下一章失败时当前章仍可阅读，并在边界提供明确重试。
- [ ] 向上加载上一章后当前视口不跳到错误位置。
- [ ] 长时间连续阅读不会无限保留全部章节布局。
- [ ] 章节边界后书架当前章节和阅读进度正确更新。

### 17.3 分页和设置

- [ ] 连续滚动、滑动、覆盖、淡入和无动画模式可切换。
- [ ] 每种模式跨章节行为一致，不出现重复页、空页或丢字。
- [ ] 切换模式、字号、行距、边距、横竖屏后仍恢复到原字符附近。
- [ ] 快速连续翻页或切章时旧请求不会覆盖最终目标。
- [ ] 全局默认和单书覆盖语义明确。
- [ ] 菜单隐藏时正文占据主要空间，点击区域和系统返回手势不冲突。

### 17.4 预取

- [ ] 预下载数量可设为 0、2、5、10、20。
- [ ] 当前请求优先于预取，预取失败不影响当前阅读。
- [ ] 预取并发受限，换书、换源、退出和目录变化会取消旧任务。
- [ ] 连续失败达到限制后不会无限重试。
- [ ] 断网时已经预取的相邻章节可读取，未缓存章节显示真实网络错误。

### 17.5 同书不同源

- [ ] 完全相同 `bookUrl` 不会重复加入。
- [ ] 同名同作者但 URL 不同会显示冲突确认，而不是静默新增。
- [ ] 替换现有书源后书架仍只有一条记录，并保留用户选择的阅读数据。
- [ ] 只有用户明确选择“仍然新增一本”时才允许第二条记录。
- [ ] 取消冲突后书籍和章节表均不发生变化。
- [ ] 从详情目录直接阅读也遵循同一冲突流程。

## 18. 风险与控制

| 风险 | 控制方式 |
|---|---|
| 一次重构所有页面导致范围失控 | 按 R1～R6 分 Feature 实施，每步单独验收 |
| 分页测量造成掉帧 | 正文处理放 isolate；页面按当前和相邻范围增量构建；真实文本测量不进入 Widget `build()` 业务逻辑 |
| 连续滚动插入上一章导致视口跳动 | 插入前记录稳定块与局部偏移，插入后恢复同一锚点 |
| 快速翻页出现串章 | 当前加载和预取使用独立优先级、取消令牌和世代编号 |
| 同名同作者并不一定是同一本书 | 只提示冲突，不建立数据库唯一约束；允许用户明确新增副本 |
| 新阅读配置破坏旧配置 | 定义兼容解码和默认值；配置 Schema 改动单独登记并提供回退 |
| iOS 后台缓存能力不足 | 前台共用 Dart 队列；后台行为明确降级或暂停，不伪装持续下载 |
| 仿真卷页开发风险过高 | 在稳定页面模型之后作为独立专项，不阻塞其他翻页模式 |

## 19. 用户待确认项

进入代码实施前建议确认：

1. 一级导航是否采用“书架 / 搜索或发现 / 书源 / 设置”。
2. 视觉是否采用“暖白纸张感 + 墨绿强调色 + 低阴影”的简约方向。
3. 同书不同源冲突是否默认突出“替换现有书源”，同时保留“仍然新增一本”。
4. 仿真卷页是否接受在其他翻页模式完成后单独实施。
5. 第一轮代码是否从 R1 开始，还是先单独执行 R2 的重复书籍修复。

## 20. 交付说明

本文件只记录方案和验收边界，没有宣称任何功能已经实现或通过。后续每个 Feature 实施时仍需：

1. 重新检查 Android 和 Flutter 最新源码；
2. 更新 Contract、ViewModel、Screen、Route、Domain/Data 映射；
3. 更新 `AI_PROJECT_INDEX.md`、阶段记录、功能矩阵和平台差异；
4. 由用户运行 Flutter、Dart、Gradle 或 Xcode 检查；
5. 新增文件时由用户决定是否执行 `git add`。
