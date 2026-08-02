# M00 功能矩阵

最后静态核对：2026-08-02。核对依据为当前 Flutter 源码、M4～M11 实施记录和 Android 只读参考；未运行构建、测试、分析、格式化或应用启动。

## 状态口径

| 状态 | 含义 |
|---|---|
| `BLOCKED` | 存在会阻止正式完成判断的兼容或验收门禁 |
| `IMPLEMENTED_PENDING_VERIFICATION` | 主体代码已接入真实调用链，但尚无足够用户运行或真机证据 |
| `PARTIAL` | 只完成子集、基础设施或入口，仍缺影响业务完整性的链路 |
| `NOT_STARTED` | 当前源码中没有可用主体实现 |
| `DEFERRED` | 保留在完整迁移范围，但不阻塞当前文本小说主流程 |

旧矩阵中的 `IN_PROGRESS` 曾同时表示“只有设计”“代码已写”和“等待真机”，容易造成误判；本次按上述口径重新校准。历史阶段文档继续保留当时事实，不用它们覆盖当前源码。

## 文本小说核心闭环

| 功能 | Android 对照入口 | Flutter 当前实现 | 当前差距或验收门禁 | 状态 |
|---|---|---|---|---|
| App 主框架 | `MainActivity`、`MainNavGraph` | `lib/main.dart`、`app/legado_app.dart`、`app/app_router.dart`、`ui/home/`；手机底栏、宽屏导航、游客直达主界面、登录后按用户重建业务页 | M9/M10 尚无正式双端通过记录 | `IMPLEMENTED_PENDING_VERIFICATION` |
| 书源导入 | `ImportBookSourceDialog`、扫码和文件关联 | 文本/剪贴板、文件、二维码、远程 URL；游客邀请码分页导入与登录账号远程同步复用统一导入边界 | 真实冲突、二维码、远程登录样本和双端系统入口待验证 | `IMPLEMENTED_PENDING_VERIFICATION` |
| 书源管理 | `BookSourceActivity` | 列表、搜索、启停、分组、编辑、删除、登录、扫码、游客/账号入口和完成后跳转搜索 | 高级字段编辑、真实分阶段调试、排序/置顶置底仍不完整 | `PARTIAL` |
| 普通规则 | `model/analyzeRule/**`、`model/webBook/**` | JSONPath、XPath、CSS/JSoup 等价选择、正则、混合规则、`@put/@get` 与四段业务链已接入 | 固定真实样本尚未形成 Android/Flutter 字段级结论 | `BLOCKED` |
| JavaScript 规则 | Rhino、`help/rhino/**`、`help/source/**` | QuickJS 执行、同步宿主调用重放、`jsLib`、受控模型/变量、Cookie、登录交互队列、后台 WebView 和部分 Java 白名单已接入 | S1～S8 未完成；任意 JVM API、部分加密 Helper、实时资源嗅探仍有差距 | `BLOCKED` |
| 网络、Cookie 与 WebView | `HttpHelper`、`CookieManager`、WebView helpers | 统一 HTTP、持久 Cookie、Android WebView/WKWebView 域同步、登录与后台页面脚本桥 | 登录、验证码、重定向、动态资源和双端生命周期待真实样本验证 | `IMPLEMENTED_PENDING_VERIFICATION` |
| 搜索 | `MainRouteSearch`、`SearchActivity` | 有界多源并发、取消/暂停恢复、失败重试、结果聚合、书名/作者/其他分类、书源选择、零书源引导、用户级关键字历史 | 每个书源固定只搜第 1 页；分页追加和分页失败重试未实现 | `PARTIAL` |
| 搜索候选持久化 | 搜索结果同书多源候选 | Schema v10、`BookSourceCandidateDao`、Repository、Gateway 已存在 | 未注入 `AppDependencies`，搜索 Cell 未写入，书架/阅读器/下载详情入口未读取；当前属于未接线基础设施 | `PARTIAL` |
| 书籍详情 | `BookInfoActivity`、`BookInfoScreen` | 渐进详情、目录摘要/完整目录、入架、备注、分组、允许更新、分享复制、移出书架、整书换源、更新目录、清离线正文、封面预览与更换 | 详情内阅读时长时间线、相关书、书源变量、Web 文件/压缩包、同步等仍未接入 | `PARTIAL` |
| 目录 | `TocActivity` | 分页目录抓取、URL 去重、连续索引、持久化、正倒序显示、启动后台尾部增量更新及定期全量校准 | 真实动态目录、超长目录和增量检查点待真机/书源验证 | `IMPLEMENTED_PENDING_VERIFICATION` |
| 书架与阅读历史 | `MainScreen`、`BookShelfItem`、`ReadRecord` | 书架/历史双页、列表/网格、分组、六种排序、选择态、批量刷新/移动/删除/换源、章节角标、独立历史快照 | 历史详情时间线和跨设备恢复未实现；长列表、后台刷新和账号切换待验证 | `IMPLEMENTED_PENDING_VERIFICATION` |
| 用户数据隔离 | Android 账号相关数据边界 | 游客 `userId=-1` 与同设备账号隔离书架、分组、目录、历史、进度、下载附属状态和搜索历史 | 游客数据不迁移到账号；无服务端书架/历史同步 | `IMPLEMENTED_PENDING_VERIFICATION` |
| 文本阅读器 | `ReadBookScreen`、`ReadBookViewModel`、`ReadBook.kt` | 连续滚动、上下/左右分页、覆盖/滑动/无动画/仿真、稳定字符锚点、设置、书签、全文搜索、替换、图片、选区、高亮/下划线、边缘退出、相邻章预取和处理后正文 LRU | 长时稳定、极端章节、横竖屏恢复、仿真视觉及双端平台行为待验证；TTS/自动翻页不在此实现 | `IMPLEMENTED_PENDING_VERIFICATION` |
| 整书换源 | 详情、书架、阅读器换源入口 | 重新搜索启用书源、候选详情/目录预览、原子主键与目录迁移、进度/分组/封面/备注/阅读设置迁移、路由替换 | 事务回滚、章节映射、取消及杀进程恢复待真实书源验证 | `IMPLEMENTED_PENDING_VERIFICATION` |
| 单章换源 | `ChangeChapterSourceSheet` | 候选目录模糊匹配、正文预览和目标章永久缓存替换；刷新当前章可恢复原源正文 | 中文数字章节兜底、失败/取消数据安全待样本验证 | `IMPLEMENTED_PENDING_VERIFICATION` |
| 阅读失败恢复 | Android 阅读器自动换源 | 手动整书/单章换源存在；下载任务有独立受控自动换源 | 前台当前章失败后的“一键尝试其他来源”与安全自动恢复未实现 | `NOT_STARTED` |
| 离线下载 | `DownloadSheet`、`CacheBookService`、缓存管理 | 当前书范围下载、跨书管理、持久队列、暂停恢复、清正文、Android 前台服务、iOS 有限后台窗口、下载专用自动换源 | 平台通知、系统回收恢复、真实限速效果待真机；漫画/图片章节下载未实现 | `IMPLEMENTED_PENDING_VERIFICATION` |
| 封面替换 | `ChangeCoverSheet`、本地图片选择 | 书架和详情共用候选面板，三级匹配书源封面；可复制本地图片到应用目录，稳定标识持久化并同步历史快照 | 真实图片选择、缓存刷新和跨重启路径待双端验证 | `IMPLEMENTED_PENDING_VERIFICATION` |

## 本地书

| 功能 | Flutter 当前实现 | 当前差距 | 状态 |
|---|---|---|---|
| TXT | 多编码基础判别、章节切分、私有副本、外部 TXT 冷/热启动打开、正文阅读 | Big5、手动编码切换、超大 TXT 流式扫描、非 TXT 外部关联待补 | `IMPLEMENTED_PENDING_VERIFICATION` |
| EPUB | OPF/manifest/spine、文本章节、安全 ZIP 边界 | Nav/NCX 层级、内嵌图片、封面和受控资源 URI 未完成 | `PARTIAL` |
| UMD | 元数据、章节标题、偏移和 zlib 正文解析；统一文本阅读链 | 图片型和损坏样本、双端真机待验证 | `IMPLEMENTED_PENDING_VERIFICATION` |
| PDF | 页数目录、页面渲染、纵向浏览、缩放和页码进度 | PDF outline、密码输入和加密文件交互未实现 | `PARTIAL` |
| MOBI/AZW/AZW3 | 格式可识别并返回明确未支持 | 元数据、DRM 判断、目录、正文和资源解析器未实现 | `NOT_STARTED` |
| ZIP/RAR/7Z 导入容器 | 格式可识别并返回明确未支持 | 条目选择、安全解压和 RAR/7Z 解码未实现 | `NOT_STARTED` |
| 本地文件生命周期 | 私有副本和稳定内容指纹 | 原文件变化后的同身份更新、删除副本选择、孤儿清理、文件夹扫描和自动同步未实现 | `PARTIAL` |

## Android 小说能力中仍待迁移

| 功能 | 现状 | 状态 |
|---|---|---|
| 系统 TTS、HTTP TTS、后台朗读、媒体控制 | 阅读器后续能力面板仅登记边界 | `NOT_STARTED` |
| 自动翻页 | 阅读器后续能力面板仅登记边界 | `NOT_STARTED` |
| 备份、WebDAV、跨设备书架/进度/书签同步 | 当前只有本机游客/账号隔离 | `NOT_STARTED` |
| 阅读内容编辑 | 只有选区书签、高亮和下划线；网络/本地正文写回边界未实现 | `NOT_STARTED` |
| 相关书、书源变量、详情 Web 文件 | 详情页保留入口或说明，业务链未接入 | `NOT_STARTED` |
| 高级阅读样式 | 自定义字体文件、背景图片、宽屏双页、淡入等动画、样式导入导出仍不完整 | `PARTIAL` |
| 书源高级维护 | 分阶段真实调试、导出未知字段往返、置顶置底、完整高级字段编辑 | `PARTIAL` |
| 漫画、音频、RSS、Web 服务、AI | 不属于当前文本小说主流程 | `DEFERRED` |

## Flutter Schema v11 覆盖

| 表或存储 | 当前职责 | 状态说明 |
|---|---|---|
| `books`、`book_groups`、`chapters` | 用户级书架、分组、目录和进度 | 已进入真实业务链，待用户验证 |
| `book_sources`、`cookies`、`caches` | 书源、Cookie 和兼容键值数据 | 已进入真实业务链；规则/登录结果受 M4 门禁约束 |
| `searchBooks` | 封面搜索派生候选缓存 | 已用于封面搜索 |
| `bookmarks`、`replace_rules`、`book_content_processes` | 书签、替换规则、高亮与下划线 | 已进入阅读器，待双端交互验证 |
| `download_tasks`、`download_book_states` | 下载队列、失败摘要和下载专用自动换源状态 | 已进入下载协调器，待后台恢复验证 |
| `reading_history_books`、`reading_history_chapters` | 与书架成员独立的用户级阅读历史快照 | 已进入书架历史双页 |
| `book_source_candidates` | 搜索点击时的同书多源候选快照 | 表、DAO、Repository、Gateway 已存在，但当前没有业务接线 |
| `toc_refresh_checkpoints` | 用户级目录尾部增量刷新检查点 | 已进入启动后台目录刷新服务，待真实书源验证 |
| MMKV 类型化偏好 | 阅读显示、布局、交互等小型高频偏好 | 已迁移十组十一个键并保留内存降级，待双端验证 |
| 安全存储 | App Token 和刷新凭据 | 已接入 Keychain/Keystore 边界，待双端会话验证 |

## 维护规则

- 代码存在但没有组合根注入或真实调用方时，只能标为 `PARTIAL`，不能标为已实现。
- 历史方案顶部状态与其末尾实施结果冲突时，应同时修正顶部状态和完成判断。
- 用户没有提供运行结果时，不得把 `IMPLEMENTED_PENDING_VERIFICATION` 改成 `DONE`。
- 新增小说 Feature、稳定路由、Schema 表或平台桥时，必须同步更新本矩阵和 `AI_PROJECT_INDEX.md`。
