# 搜索分类滑动选中背景与阅读器详情入口实施分析

> 文档状态：`IN_PROGRESS / 代码已写入，等待用户运行验证`
>
> 创建日期：2026-07-27
>
> 适用范围：搜索结果“书名/作者/其他”分类栏、小说文本阅读器顶部工具栏

## 实施快照

- `search_screen.dart` 已让分类栏复用现有 `PageController`，由小数页位置驱动单块共享背景和文字颜色插值；未新增动画控制器。
- 阅读器顶部已增加“书籍详情”信息图标，并通过 `OpenReaderBookInfoIntent/Effect` 收起菜单、保存进度后导航。
- `ReaderRoute` 打开详情前会暂停系统信息刷新并退出阅读系统模式；普通返回恢复原模式和键盘焦点。
- 详情页从阅读器进入时，阅读或选择章节会返回 `ReaderRouteArguments`，原阅读器再替换自身，避免形成双阅读器路由栈。
- 详情页整书换源替换路由时会保留阅读器返回标记；搜索、书架等原有详情入口逻辑不变。
- 未新增 Schema、依赖、日志或平台通道；按项目要求未运行构建、分析、测试、格式化或应用启动。

## 1. 结论

建议执行两项调整：

1. 搜索结果分类栏把每个选项各自切换背景的实现，改成一块由
   `PageController.page` 实时驱动的共享滑动背景。
2. 阅读器顶部工具栏增加 `Icons.info_outline` 书籍详情图标，点击后保存当前进度并通过
   Reader Intent/Effect 打开现有书籍详情页。

搜索分类滑动背景能直接解决当前 PageView 切换时的选中态闪烁；阅读器详情入口则补齐 Android
`ReadBookIntent.OpenBookInfo` 已有行为。两项都属于 Flutter UI 与导航接线，不改变搜索结果、
正文、目录或数据库模型。

## 2. 唯一目标与不包含范围

本专项目标：

- PageView 拖动期间，“书名/作者/其他”的选中背景与页面位置连续同步；
- 点击分类时，背景跟随 PageView 的现有切页动画滑动；
- 阅读器菜单显示时，可从顶部信息图标进入当前书籍详情；
- 从详情返回后恢复当前阅读界面和阅读系统状态；
- 在详情里再次点击阅读时不叠加第二个同书阅读器路由。

不包含：

- 修改搜索分类规则、关键字匹配、结果去重、排序和网络请求；
- 修改书籍详情 UI 或目录刷新业务；
- 修改普通翻页、边缘退出、正文选择和阅读配置；
- 修改 PDF 阅读器顶部工具栏；
- 修改数据库 Schema、应用版本号、平台通道或原 Android 工程；
- 新增第三方动画、路由或状态管理依赖。

## 3. 搜索分类选中态闪烁原因

当前调用链：

```text
_SearchResultPages
  -> PageController
  -> PageView.builder
  -> onPageChanged
  -> setState(_selectedPage)
  -> _SearchResultPageSelector
  -> 每一项独立 AnimatedContainer
```

当前每个分类项根据 `index == selectedPage` 独立决定：

- 是否显示 `secondaryContainer` 背景；
- 文字使用选中色还是普通色；
- 用 150ms `AnimatedContainer` 在透明色和选中色之间过渡。

PageView 拖动到切页阈值后，`onPageChanged` 才把 `_selectedPage` 从旧页改成新页。此时旧项开始
淡出背景，新项同时开始淡入背景，两块独立颜色动画与正在移动的 PageView 没有共享进度，中间帧会
出现背景过浅、两块同时过渡或短暂没有明确选中项的视觉闪烁。

结果增量更新会频繁重建搜索主体，但不是根因；只要 `selectedPage` 不变，颜色目标不变。
根因是“离散页码 + 两块独立颜色动画”不能表达 PageView 的连续滑动位置。

## 4. 搜索分类栏推荐实现

### 4.1 一块共享滑动背景

`_SearchResultPageSelector` 接收当前 `_pageController`，使用 `AnimatedBuilder` 监听控制器：

```text
pagePosition = pageController.hasClients
  ? pageController.page
  : selectedPage
```

分类栏内部使用 `LayoutBuilder + Stack`：

```text
Stack
  -> 一块 secondaryContainer 背景
     宽度 = 分类栏宽度 / 页面数量
     x = pagePosition × 单项宽度
  -> Row
     -> 书名文字和点击区
     -> 作者文字和点击区
     -> 可选其他文字和点击区
```

因此：

- 手指拖动 PageView 时，背景按同一小数页位置跟手滑动；
- 点击分类调用现有 `animateToPage`，背景自然跟随控制器动画；
- 不再同时执行旧背景淡出和新背景淡入；
- “其他”页出现或消失时，继续使用当前控制器重建与页码收窄逻辑。

### 4.2 文字颜色

每个分类文字根据与 `pagePosition` 的距离计算选中强度：

```text
strength = clamp(1 - abs(pagePosition - index), 0, 1)
color = Color.lerp(onSurfaceVariant, onSecondaryContainer, strength)
```

文字颜色会与共享背景同步过渡，不在 `onPageChanged` 时突然跳色。字体粗细不建议逐帧切换，
保持固定 `FontWeight.w600` 或只在最终语义选中页变化时切换，避免字体重新排版造成轻微抖动。

### 4.3 状态、语义和点击

- `_selectedPage` 继续由 `onPageChanged` 保存离散稳定页码，用于页面数量变化后的恢复；
- 共享背景只消费 `PageController.page` 的瞬时 UI 位置，不进入 ViewModel/UiState；
- 辅助功能 `selected` 使用最接近当前 `pagePosition` 的页，或使用稳定 `_selectedPage`；
- 点击当前页不重复启动动画；
- 页面数量变化时先将页码限制在有效范围，再创建新控制器；
- 每页已有 `PageStorageKey` 保持不变，列表滚动位置不受影响。

### 4.4 性能和动画

- 不增加 `AnimationController`，复用现有 `PageController`；
- `AnimatedBuilder` 只包裹分类栏，不重建结果 PageView 和列表；
- 共享背景可加 `RepaintBoundary`，拖动时只重绘顶部小区域；
- 背景只做水平位移，不使用模糊、阴影动画或 `saveLayer`；
- 页面切换时不调用 ViewModel，不产生网络、分类或列表重算。

## 5. 阅读器详情入口当前事实

Flutter 阅读器顶部当前包含：

```text
返回 -> 章节/书名 -> 刷新当前章 -> 整书换源 -> 更多
```

阅读器状态中已经有当前 `Book` 和完整目录，详情页也已经能从书架书构造单来源
`BookSearchResultGroup + SearchBook` 路由参数。

Android 参考行为：

```text
ReadBookIntent.OpenBookInfo
  -> 关闭阅读菜单
  -> ReadBookEffect.OpenBookInfo(name, author, bookUrl)
  -> BookInfoActivity
  -> 返回阅读器后恢复/更新正文
```

因此 Flutter 应沿用 Reader Intent/Effect，而不是在 `_ReaderTopBar` 的点击回调里直接调用
`Navigator`。

## 6. 阅读器详情入口推荐实现

### 6.1 顶栏图标

在书名/章节区域之后、刷新按钮之前增加：

```text
IconButton
  icon: Icons.info_outline
  tooltip: 书籍详情
```

规则：

- `state.book == null` 时禁用；
- 当前书是本地书时仍允许进入详情，本地书会优先展示已经持久化的元数据和目录；
- 使用图标而不是文字按钮，减少窄屏顶部工具栏宽度压力；
- 复用当前图标颜色、触控尺寸和菜单显隐动画；
- 不改变顶部标题区域本身的点击行为，避免新增隐蔽手势。

### 6.2 Reader MVI 链路

新增：

```text
OpenReaderBookInfoIntent
  -> ReaderViewModel
     -> 立即隐藏阅读菜单
     -> 保存当前稳定阅读进度
     -> OpenReaderBookInfoEffect(Book)
  -> ReaderRoute
     -> 暂时退出阅读系统模式
     -> pushNamed(AppRoute.bookInfo)
```

详情路由参数把当前 `Book` 转换为单来源 `SearchBook`，并构造只有当前来源的
`BookSearchResultGroup`。这与书架打开详情的现有做法一致：

- 不重新执行一次全书源搜索；
- 详情页仍可读取已入架书的本地书籍和目录快照；
- 网络书仍可按详情页现有规则后台刷新；
- 不把 ReaderScreen 直接依赖到 BookInfo Route。

### 6.3 阅读系统状态

阅读器可能启用了：

- 沉浸全屏；
- 阅读亮度；
- 常亮；
- 方向锁定；
- 低频电量刷新。

打开普通详情页前，`ReaderRoute` 必须参照现有整书换源导航：

1. 防止重复打开详情；
2. 停止阅读器低频系统信息刷新；
3. 调用 `ReaderPlatformService.exitReader()` 恢复普通页面系统状态；
4. 打开详情路由；
5. 普通返回时重新按当前 `ReaderDisplayConfig` 进入阅读系统模式；
6. 重新启动系统信息刷新并恢复阅读器键盘/音量键焦点。

这样详情页不会继续使用阅读器亮度、全屏或方向锁定。

## 7. 防止详情再次打开重复阅读器

当前详情页的“阅读”和目录章节操作会执行：

```text
BookInfoRoute
  -> Navigator.pushNamed(AppRoute.reader)
```

若详情页是从阅读器上方打开，继续沿用该行为会形成：

```text
旧阅读器 -> 详情页 -> 新阅读器
```

返回时会再次看到旧阅读器，且两套路由可能持有同一本书的进度和平台状态。

建议为 `BookInfoRouteArguments` 增加默认关闭的内部参数：

```text
returnReaderResult = false
```

只有阅读器打开详情时传 `true`。此时详情页用户明确点击“阅读”或目录章节后：

- 不再 push 新阅读器；
- `Navigator.pop` 返回一个 `ReaderRouteArguments`；
- 其中包含详情页当前书籍、当前目录和目标章节；
- 下层 `ReaderRoute` 使用 `pushReplacementNamed` 替换自己；
- 新阅读器按详情页最终来源和章节重新初始化；
- 旧阅读器被释放，不形成双阅读器路由栈。

若用户只是点击返回：

- 详情页返回空结果；
- 原阅读器不重建，保留当前页、正文缓存和动画状态；
- 重新进入阅读系统模式后继续显示原位置。

该参数只控制内部导航返回方式，不改变正常从搜索、书架或历史进入详情页的旧逻辑。

## 8. 返回与异常行为

| 场景 | 行为 |
|---|---|
| 阅读器尚未加载到书籍 | 详情图标禁用 |
| 保存进度失败 | 沿用现有进度保存错误提示；不伪装已保存 |
| 详情普通返回 | 恢复原阅读器系统状态和原页面 |
| 详情点击当前书阅读 | 返回参数并替换原阅读路由，不叠加 |
| 详情换源后点击阅读 | 使用详情最终书籍 URL、目录和章节替换原阅读路由 |
| 本地书详情 | 使用本地持久化数据；网络刷新失败不清空已展示本地数据 |
| 详情打开过程中重复点击 | ReaderRoute 单飞保护，只创建一个详情路由 |
| 阅读器在详情打开期间被销毁 | 不恢复已销毁 Route，不写入已释放状态 |

详情页如果只刷新了目录然后直接返回，原阅读器继续保持当前已加载目录，避免在返回瞬间重排或切章；
下次重新进入阅读器会读取详情页已经持久化的新目录。用户若在详情里选择章节或点击阅读，则通过
路由替换立即使用详情页的新书籍和目录快照。

## 9. 计划修改文件

### 9.1 搜索分类动画

| 文件 | 计划改动 |
|---|---|
| `lib/src/ui/search/search_screen.dart` | 分类选择栏接入当前 `PageController`，用共享背景按小数页位置平移；文字颜色同步插值 |
| `docs/flutter-rewrite/m06/02_search_result_and_book_info_interaction_plan.md` | 补充分类栏闪烁原因、实施快照和验收项 |

### 9.2 阅读器详情入口

| 文件 | 计划改动 |
|---|---|
| `lib/src/ui/reader/reader_menu_overlay.dart` | 顶部工具栏增加书籍详情信息图标 |
| `lib/src/ui/reader/reader_contract.dart` | 增加打开详情 Intent 和携带当前书籍的 Effect |
| `lib/src/ui/reader/reader_view_model.dart` | 隐藏菜单、保存进度并发出详情导航 Effect |
| `lib/src/ui/reader/reader_route.dart` | 转换当前书籍为详情参数，暂退/恢复阅读系统状态，处理详情返回 |
| `lib/src/ui/book_info/book_info_contract.dart` | 增加只供阅读器入口使用的返回阅读标记 |
| `lib/src/ui/book_info/book_info_route.dart` | 从阅读器进入时把阅读动作作为参数返回，不 push 第二个阅读器 |
| `lib/src/app/app_router.dart` | 允许详情 Route 返回受控阅读器路由参数 |
| `docs/flutter-rewrite/m08/README.md` | 记录阅读器详情入口实现和待验收边界 |
| `docs/flutter-rewrite/m08/01_reader_ui_rebuild_priority.md` | 更新顶部工具栏和返回行为实施快照 |

### 9.3 索引

| 文件 | 计划改动 |
|---|---|
| `docs/flutter-rewrite/AI_PROJECT_INDEX.md` | 索引本专项、搜索滑动指示器和阅读器详情入口 |

不新增数据库字段、第三方依赖、日志、平台通道或路由名称，因此不涉及 Schema 和
`pubspec.yaml` build number。

## 10. 性能和内存约束

1. 搜索分类背景只监听已有 `PageController`，不创建第二个动画控制器。
2. 拖动 PageView 时只重建/重绘分类选择栏，不重建搜索结果列表。
3. 页面数据和滚动位置继续使用现有 `PageStorageKey`。
4. 阅读器详情导航使用单飞布尔状态，不创建 Timer、Stream 或重复 Effect 订阅。
5. 详情打开时暂停阅读器低频系统信息 Timer，返回时恢复；Route 销毁后不恢复。
6. 阅读器被详情替换时释放原 ViewModel、滚动控制器、分页控制器和平台状态。
7. 不复制正文、分页页集或图片缓存到详情页；只传递当前书籍和目录快照。
8. 不在 Widget 点击回调中查询数据库、刷新详情或保存阅读进度。

## 11. 用户验收清单

代码实施后由用户运行和真机验收，AI 不执行构建、分析、测试、格式化或应用启动。

### 11.1 搜索分类栏

1. 在“书名”和“作者”之间缓慢左右拖动，确认选中背景连续跟手，没有透明闪帧。
2. 快速甩动切页，确认背景只是一块并最终停在正确分类。
3. 点击“书名”“作者”和存在时的“其他”，确认背景与 PageView 同步滑动。
4. 搜索仍在增量返回结果时反复切页，确认背景不闪、结果不重复、列表位置不丢失。
5. “其他”页从无到有或从有到无时，确认当前页安全收窄且背景宽度、位置正确。
6. 深色、浅色主题下确认背景和文字对比度可读。
7. 使用系统放大字体和屏幕阅读器，确认分类文字不溢出且选中语义正确。

### 11.2 阅读器详情入口

1. 打开阅读菜单，确认顶部有信息图标和“书籍详情”提示。
2. 点击图标，确认菜单先隐藏、进度保存后打开当前书籍详情。
3. 在全屏、阅读亮度和方向锁定状态下进入详情，确认详情恢复普通系统状态。
4. 从详情直接返回，确认回到原阅读页和原位置，并恢复阅读器系统状态。
5. 在详情点击“阅读”或选择目录章节，确认只保留一层阅读器，不会返回到旧阅读器。
6. 在详情换源后点击阅读，确认进入新来源并使用目标章节。
7. 网络书、已入架书、未入架历史书和本地书分别测试详情入口。
8. 快速连续点击详情图标，确认只打开一个详情页。
9. 在详情页停留后切后台再返回，确认阅读器和详情页没有重复恢复系统亮度或方向。

## 12. 完成判定

代码写入后状态只能记录为：

```text
IN_PROGRESS / 搜索分类滑动背景与阅读器详情入口已实现，等待用户 Android、iOS 真机验证
```

只有用户确认以下结果后才能进一步更新状态：

- PageView 拖动、点击和动态页面数量下均无选中背景闪烁；
- 搜索结果、分类和列表滚动位置无回归；
- 阅读器详情图标可用且不绕过进度保存；
- 详情返回正确恢复阅读系统状态；
- 详情再次阅读不会叠加双阅读器路由；
- Android、iOS 真机结果均可接受。
