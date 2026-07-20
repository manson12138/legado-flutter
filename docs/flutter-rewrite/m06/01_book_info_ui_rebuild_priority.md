# 小说阅读详情界面 UI 重构优先级

> 文档状态：`IN_PROGRESS / P0～P3 基础入口已写入 Flutter 详情页，等待用户运行验证`  
> 创建日期：2026-07-16  
> 适用范围：Flutter `ui/book_info/` 书籍详情页对齐 Android `ui/book/info/` 当前 Compose 详情页。  
> 不包含范围：正文阅读器、漫画阅读器、音频播放、RSS、Web 服务、AI、原 Android 代码修改。

## 0. 实施快照

2026-07-16 已写入 P0～P3 第一批 Flutter 实现，修改范围为
`flutter_app/lib/src/ui/book_info/book_info_screen.dart`、`book_info_contract.dart`、
`book_info_view_model.dart` 和 `book_info_route.dart`：

- 详情页 AppBar 保留返回、基础换源和更多菜单入口；
- 主体改为封面头部、标签、四个主操作卡、底部阅读主按钮、书籍概览和目录预览；
- “加入书架”从悬浮按钮迁移到主操作卡；
- 底部“开始阅读”优先打开当前阅读进度章节，否则打开第一个可读章节；
- “查看目录”使用底部面板展示完整目录，点击章节后复用现有阅读入口；
- 目录预览只展示前 8 章，避免超长目录直接铺满详情页；
- 更多菜单已接入刷新、分享、复制书籍地址、复制目录地址、编辑备注、整书换源、阅读记录占位和移出书架；
- 分享由 Route 调用 `share_plus` 系统分享面板，复制由 Route 写入系统剪贴板；
- 编辑备注通过 ViewModel 复用 `BookshelfGateway.addBook(book, emptyList)` 更新书籍行，不改目录；
- 移出书架通过 `BookshelfGateway.deleteBook` 删除当前书籍，并依赖数据库外键级联删除目录；
- P2/P3 已补入封面预览、分组选择/新建分组、允许更新开关和“后续能力”面板；
- 分组选择通过 `BookGroupGateway.watchGroups`、`CreateBookshelfGroupUseCase` 和
  `ReplaceBooksGroupUseCase` 写入当前书籍分组；
- 允许更新通过 ViewModel 复制 `Book.canUpdate` 并复用 `BookshelfGateway.addBook(book, emptyList)` 更新书籍行；
- 阅读记录、换封面/保存封面、相关书、书源登录/变量、Web 文件/压缩包、清缓存、日志和同步仍只保留
  明确能力映射与依赖说明，尚未接入真实业务。

AI 未运行 `flutter analyze`、`dart analyze`、测试、构建、格式化或应用启动；是否可用以用户运行结果为准。

## 1. 目标

本文件的唯一目标是：在正式重构 Flutter 小说阅读详情界面前，先把 Android 详情页已有 UI 功能按优先级拆成可执行、可验收的实施批次。

这里的“参照 Android 项目的 UI”不是像素级复制，而是保持：

- 页面入口、主次信息层级和操作位置一致；
- 详情、目录、书架、阅读、换源、封面、分组、菜单、弹窗和返回行为可找到对应入口；
- Flutter 保持统一跨 Android/iOS 视觉体系；
- 业务仍走 ViewModel、UseCase、Gateway、Repository，不把数据库、网络、规则解析或文件操作写进 Widget。

## 2. Android 对照范围

本次优先级盘点以以下 Android 文件为基准：

| 职责 | Android 文件 | 说明 |
|---|---|---|
| 页面入口 | `app/src/main/java/io/legado/app/ui/book/info/BookInfoActivity.kt` | 承载详情页 Activity。 |
| 路由与系统副作用 | `app/src/main/java/io/legado/app/ui/book/info/BookInfoRouteScreen.kt` | 处理编辑页、目录页、阅读器、书源登录、变量弹窗、文件选择、分享/复制等 Effect。 |
| 状态、Intent、Effect | `app/src/main/java/io/legado/app/ui/book/info/BookInfoContract.kt` | 定义详情页全部 UI 状态、Sheet、Dialog、菜单动作和副作用。 |
| 主 UI | `app/src/main/java/io/legado/app/ui/book/info/BookInfoScreen.kt` | 封面背景、动态主题、头部、操作卡、简介、相关书、菜单和对话框。 |
| Sheet | `app/src/main/java/io/legado/app/ui/book/info/BookInfoSheets.kt` | Web 文件、分组、封面、换源、压缩包条目等底部面板。 |
| 阅读记录 | `app/src/main/java/io/legado/app/ui/book/info/BookInfoReadRecordSheet.kt` | 阅读时长和时间线。 |
| 编辑页 | `app/src/main/java/io/legado/app/ui/book/info/edit/**` | 书籍信息编辑、类型切换和封面编辑入口。 |
| 旧菜单资源 | `app/src/main/res/menu/book_info.xml` | 菜单功能清单对照，现 Compose 菜单仍保留同类能力。 |
| 历史 View 资源 | `app/src/main/res/layout/activity_book_info.xml`、`activity_book_info_edit.xml` | 仅作旧入口参考，不作为 Flutter 新实现方式。 |

Flutter 当前目标文件：

| 职责 | Flutter 文件 | 当前状态 |
|---|---|---|
| Contract | `flutter_app/lib/src/ui/book_info/book_info_contract.dart` | 已覆盖详情、目录、加入书架、同名冲突、基础换源和整书换源入口。 |
| ViewModel | `flutter_app/lib/src/ui/book_info/book_info_view_model.dart` | 已覆盖普通规则详情/目录、加入书架事务和当前候选换源。 |
| Route | `flutter_app/lib/src/ui/book_info/book_info_route.dart` | 已处理 Snackbar、返回、阅读器跳转、整书换源结果和同名冲突对话框。 |
| Screen | `flutter_app/lib/src/ui/book_info/book_info_screen.dart` | 当前是基础 Material 详情卡、简介、完整目录和加入书架 FAB。 |

## 3. 当前 Flutter 差距摘要

Flutter 当前详情页已经能服务第一批核心闭环，但距离 Android 详情页完整 UI 功能还有明显差距：

| 能力 | Android 当前表现 | Flutter 当前表现 | 差距 |
|---|---|---|---|
| 封面主视觉 | 封面、模糊背景、渐变遮罩、可选跟随封面色 | 小封面卡片 | 缺少主视觉、背景和动态色策略。 |
| 顶栏 | 透明/玻璃顶栏、滚动后变色、编辑/分享/更多 | 默认 AppBar、基础换源按钮 | 缺少视觉层级和完整菜单。 |
| 主操作区 | 书架、目录、书源、阅读记录四个操作卡 | 加入书架 FAB、目录内嵌列表 | 缺少操作卡和长按分组入口。 |
| 信息展示 | 标签、分组、分类、阅读进度、最新章节、备注、简介 | 书名、作者、来源、分类、字数、最新章节、简介 | 缺少标签/分组/备注/阅读进度层级。 |
| 目录入口 | 独立 TocActivity，详情页只展示概要 | 完整目录直接铺开 | 缺少独立目录体验和详情页目录摘要策略。 |
| 换源 | Sheet 支持替换、另存、冲突替换和迁移选项 | 当前搜索组换源 + M11 整书换源入口 | 缺少详情页内 Sheet 体验和迁移选项 UI。 |
| 封面 | 点击预览，长按/Sheet 换封面，保存封面 | 只展示封面 | 缺少封面预览、换封面和保存入口。 |
| 分组 | 长按书架操作进入分组选择，支持新增/编辑分组 | 同名冲突保留分组迁移，详情页无分组 UI | 缺少分组选择 Sheet。 |
| 阅读记录 | 阅读时长和时间线 Sheet | 无入口 | 缺少 readRecord 数据和 UI。 |
| Web 文件 | 展示可下载/导入文件、压缩包条目、外部打开 | 无入口 | 需要文件下载/导入能力后实现。 |
| 菜单 | 编辑、分享、上传、同步、刷新、登录、置顶、变量、复制 URL、允许更新、拆分长章、删除提醒、清缓存、日志 | 仅整书换源和当前候选换源 | 大量菜单动作未映射。 |
| 相关书 | 规则提供 relatedBooks 时展示横向 Banner，可进入更多 | 无入口 | 需要规则字段和搜索/发现跳转支持。 |
| 本地/音频/图片分流 | 根据类型打开文本、漫画、音频或外部文件 | 主要服务文本阅读闭环 | 音频/漫画属后续功能，需登记降级。 |

## 4. 优先级原则

优先级按以下顺序判断：

1. 是否影响第一批核心阅读闭环：搜索、详情、目录、入架、阅读。
2. 是否会阻塞后续 UI 功能挂载：Contract、Route、Sheet、Dialog、菜单结构。
3. 是否需要新数据表、平台通道或高风险业务迁移。
4. 是否属于 Android 详情页高频可见入口。
5. 是否依赖当前仍 `BLOCKED` 的 JavaScript、M9/M10 真机验收或 M11 后续功能。

## 5. P0：先补页面骨架和核心操作

P0 目标：让 Flutter 详情页先拥有与 Android 详情页同级的信息层级和核心操作入口，不引入低频业务。

| 项目 | Android 对照 | Flutter 目标 | 验收 |
|---|---|---|---|
| 头部主视觉 | `BookInfoHeader`、`BookInfoBackdrop` | 封面 + 书名 + 作者 + 来源 + 分类/分组标签，保留简约低装饰风格 | 小屏不拥挤，宽屏内容居中，封面和文字不重叠。 |
| 顶栏结构 | `BookInfoTransparentTopAppBar`、`BookInfoTopBarActions` | 返回、分享、更多；已入架时显示编辑入口占位或可用入口 | 滚动时顶栏不遮挡内容，图标有 tooltip/语义。 |
| 四个主操作卡 | `BookInfoActions` | 书架/已在书架、目录、书源/换源、阅读记录入口；未实现业务时给明确提示 | 操作卡稳定等宽，禁用/占位状态清楚。 |
| 简介与进度摘要 | `BookInfoSummary` | 最新章节、目录数量、当前阅读章节、备注、简介分区 | 无目录、目录加载中、目录失败都有状态。 |
| 加入书架位置调整 | `ShelfClick` | 从 FAB 迁移到主操作卡；阅读保留底部/悬浮主按钮 | 加入书架、已入架、加入中、目录失败时状态正确。 |
| 目录摘要策略 | `TocClick` | 详情页展示摘要和最近若干章节，完整目录入口独立展示 | 大目录不直接铺满详情页造成滚动压力。 |

P0 不做：真实编辑页、真实阅读记录数据、Web 文件导入、封面搜索、远程同步。

## 6. P1：补齐高频 Sheet、Dialog 和菜单骨架

P1 目标：把 Android 详情页的高频交互容器迁移到 Flutter，业务可按能力逐步接线。

| 项目 | Android 对照 | Flutter 目标 | 验收 |
|---|---|---|---|
| 更多菜单 | `BookInfoOverflowMenu`、`BookInfoMenuAction` | 建立 `BookInfoMenuAction` Dart 对照，按书籍状态显示菜单项 | 菜单项显隐与本地/网络、是否入架、是否有书源登录能力一致。 |
| 分享/复制 | `RunSourceCallback.ShareText`、`CopyText` | Route 层处理系统分享和剪贴板，敏感字段不进日志 | 分享内容可由用户确认，复制 bookUrl/tocUrl 有提示。 |
| 刷新 | `Refresh` | 重新加载详情和目录，旧请求不污染新状态 | 刷新中状态明确，失败可恢复旧内容或显示错误。 |
| 删除/移除书架 | `DeleteBook` | 已入架时提供移除入口，本地书可选择是否删除原文件 | 取消不写入，确认后返回/刷新书架状态。 |
| 备注编辑 | `EditRemark` | Dialog 修改备注并持久化 | 空备注、取消、保存失败都有明确反馈。 |
| 书架冲突对话框保留 | 当前 Flutter 已有 | 视觉对齐详情页 Dialog 体系 | 替换、仍然新增、取消三种选择保持可用。 |

P1 不做：WebDAV 上传/同步、变量编辑真实脚本联动、日志 Sheet 完整能力。

## 7. P2：补齐 Android 详情页特色能力

P2 目标：迁移 Android 详情页中重要但依赖额外数据或功能链路的 UI 能力。

| 项目 | Android 对照 | Flutter 目标 | 前置依赖 |
|---|---|---|---|
| 封面预览和换封面 | `CoverClick`、`CoverLongClick`、`ChangeCoverSheet`、`PhotoPreview` | 已接入点击封面/菜单预览；长按和菜单换封面给出依赖提示 | 换封面仍需封面搜索协调器、封面保存/缓存策略。 |
| 分组选择 | `GroupSelectSheet` | 已接入选择已有分组、清除分组、新建分组并移动当前书籍 | 编辑分组详情页入口仍留待书架分组管理能力。 |
| 阅读记录 | `BookReadRecordSheet` | 已保留入口和能力面板说明 | 仍需 `readRecord` 系列表和阅读器写入记录。 |
| 完整换源 Sheet | `ChangeSourceSheet`、迁移选项 Sheet | 当前保留搜索组基础换源和独立整书换源页入口 | 详情内候选预览和迁移选项仍需 M11 换源协调器、迁移选项模型。 |
| 相关书 | `RelatedBooksBanner`、`RelatedBooksMore` | 已在后续能力面板登记 | 仍需规则字段解析和 Explore/搜索跳转。 |
| 书源登录和变量 | `OpenSourceLogin`、`ShowVariableDialog` | 已在后续能力面板登记 | 仍需 M10 WebView/Cookie 真机验证、变量 Gateway。 |

## 8. P3：低频和平台差异能力

P3 目标：保留 Android 功能映射，但不阻塞第一批可用版本。

| 项目 | Android 对照 | Flutter 处理策略 |
|---|---|---|
| Web 文件下载/导入 | `WebFiles`、`ArchiveEntries`、`OpenFile` | 已在后续能力面板登记；等文件下载、压缩包和本地书导入能力稳定后接入。 |
| WebDAV 上传/同步 | `Upload`、`SyncRemote` | 已在后续能力面板登记；属备份/远程同步后续功能。 |
| 音频/漫画分流 | `AudioPlayActivity`、`ReadMangaActivity` | 当前文本阅读优先；音频/漫画入口先提示未支持或隐藏。 |
| 清缓存 | `ClearCache` | 已在后续能力面板登记；需要明确缓存范围：正文、封面、书源脚本或全部缓存，再接入。 |
| 日志 Sheet | `ShowLog`、`AppLogSheet` | 已在后续能力面板登记；等全局日志页面能力稳定后，从详情页菜单跳转或弹出。 |
| 置顶、允许更新、拆分长章、删除提醒 | 对应菜单 Toggle | 已接入允许更新开关；置顶、拆分长章、删除提醒仍按数据字段后续逐项接入。 |

## 9. 建议实施顺序

1. 新建 Flutter 详情页 UI 子组件文件：头部、操作卡、摘要、目录摘要、菜单、Dialog/Sheet 容器。
2. 扩展 `BookInfoContract`：补齐 UI 所需状态、Sheet、Dialog、MenuAction，但只接入 P0/P1 必需字段。
3. 改造 `BookInfoScreen`：用 Android 信息层级重排页面，避免完整目录直接铺满详情。
4. 改造 `BookInfoRoute`：集中处理分享、剪贴板、Dialog、Sheet、完整目录页面或目录面板。
5. 改造 `BookInfoViewModel`：只接线 P0/P1 已有数据能力；未实现功能通过明确 Effect 提示，不伪装成功。
6. 后续按 P2/P3 单项拆 Feature，每次更新本文件、功能矩阵和映射文档。

## 10. 验收清单

P0 验收：

- 从搜索结果打开详情，加载中、成功、详情失败、目录失败、空目录状态都可见。
- 头部显示封面、书名、作者、来源、分类/分组标签和简介摘要。
- “阅读”能打开阅读器；“加入书架/已在书架”状态准确。
- “目录”能查看完整目录或目录面板，点击章节能打开阅读器对应章节。
- “书源/换源”在已支持路径中可用，不支持时提示明确。
- 页面在窄屏、宽屏、大字号、深色模式下无文字溢出和控件重叠。

P1 验收：

- 更多菜单按当前书籍类型和入架状态显示可用项。
- 分享、复制、刷新、删除/移除、备注编辑不把业务逻辑写进 Screen。
- 所有一次性系统行为经 Route Effect 处理。
- 取消 Dialog/Sheet 不写入数据，失败不会显示成功提示。

P2/P3 验收：

- 每个能力都有 Android 对照、Flutter 入口、数据写入位置和平台差异说明。
- 依赖未满足的能力保持隐藏或明确提示，不宣称完成。

## 11. 风险和边界

- M4 JavaScript 兼容仍是 `BLOCKED`，相关书、变量和部分详情字段可能依赖真实脚本结果，不能因 UI 完成宣称脚本书源完整可用。
- M9/M10 真机验收未完成，WebView/Cookie、文件选择和系统分享需要用户运行确认。
- Flutter UI 可以重构视觉，但不能改变书籍、目录、阅读进度和书架冲突的业务事实。
- 新增手写文件后必须更新 `AI_PROJECT_INDEX.md`，并在交付时询问是否加入 Git 暂存区。
