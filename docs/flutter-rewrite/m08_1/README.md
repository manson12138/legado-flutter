# M8.1 实施记录：本地书导入与阅读

状态：`IN_PROGRESS / TXT、EPUB、UMD 与 PDF 主链路代码待用户运行，MOBI 家族和压缩容器仍未通过阶段门禁`

## 本次已实现

- 新增 `LocalBookFormat`、系统选择文件、应用内文件引用、解析结果和导入结果领域模型。
- 新增 `LocalBookPlatformBridge`。Android 与 iOS 都通过系统文档选择器多选；插件只返回可立即复制的路径和元数据，不在 UI isolate 读取文件内容。
- 新增 `LocalBookStorage`。文件先计算 SHA-256，再复制到数据库同级的 `local_books/` 应用私有目录；数据库只保存相对路径、格式、指纹、大小和写入时间，不保存 picker 临时绝对路径。
- `bookUrl` 使用 `local://<sha256>`。同一内容重复导入命中同一记录并更新目录；同名但内容不同因指纹不同可以并存。
- 复制采用同目录 `.importing` 临时文件完成后改名；解析或数据库写入失败时补偿删除本次新副本。
- 新增统一 `LocalBookParser` 与 `LocalBookParserRegistry`。未注册格式返回明确错误，不回退成 TXT 或空书。
- TXT 支持 UTF-8 BOM、UTF-16LE/BE BOM、严格 UTF-8 和 GBK 回退，使用常见中文章节规则生成字符范围；无章节时建立单一“正文”章节。
- TXT 的文件解码、目录正则和章节正文提取运行于后台 isolate；章节使用字符半开区间和稳定 `txt:` 地址。
- EPUB 校验 ZIP、`META-INF/container.xml`、OPF、manifest 与 spine；限制条目数量、声明解压总大小、绝对路径、`..` 越界路径和符号链接。
- EPUB 按 spine 建立稳定 `epub:<entryPath>` 章节地址，读取 OPF 书名/作者，并在后台 isolate 展开单个 XHTML、移除标签和脚本影响后送入 M8 文本管线。
- 新增 `UmdLocalBookParser`，等价移植 Android 内置 `UmdReader` 的小端分段、UTF-16LE 元数据/标题、章节偏移和 zlib 正文块逻辑；导入和目标章节读取均在后台 isolate。
- 新增 `LocalBookImport` Contract、ViewModel、无状态 Screen 和 Route，支持系统多选、单选/全选、逐文件进度、成功/更新/失败状态和批量失败隔离。
- 欢迎页和 M7 书架顶部均新增“导入本地书”入口。
- `ReadBookCoordinator` 已通过 `LocalBookContentService` 读取 TXT/EPUB，不再对全部 `loc_book` 返回 M08 占位错误；本地文本继续复用替换规则、字符锚点、书签、缓存和相邻章预加载。
- 新增 `pdfx ^2.9.2` 依赖、`PdfLocalBookParser`、统一 `BookReaderRoute` 和 `PdfReaderRoute`。导入时读取真实页数并每页建立稳定目录；阅读时使用原生页面渲染、纵向翻页、双指缩放和页码目录跳转。
- PDF 进度以零基页索引保存到章节字段，`chapterPos` 固定为 0；不执行正文替换，也不进入 `ReaderChapterContent` 文本分块模型。
- 书架网络目录刷新会跳过 `loc_book` 和 `canUpdate=false` 的书籍，避免把本地书错误送入网络书源刷新器。

## 当前明确未实现

- MOBI、AZW、AZW3 元数据、DRM 判断、目录、正文和资源解析器。
- PDF outline 尚未读取；当前按每页建立平面目录。密码输入交互也尚未实现，加密 PDF 会明确失败。
- ZIP 条目选择及安全解压导入；RAR、7Z 解码依赖尚未确定。
- EPUB nav/NCX 标题层级、图片块、封面和受控资源 URI；当前目录顺序来自 spine，标题来自 XHTML。
- Big5 自动判别和用户手动切换 TXT 编码；当前无 BOM 且非 UTF-8 时按 GBK 回退。
- 超大 TXT 流式分块扫描；当前整本读取发生在后台 isolate，但仍受内存上限约束。
- 文件夹浏览、递归扫描、自动同步、导入取消、外部打开/文件关联入口。
- 原文件变化后的同身份更新与章节锚点迁移；当前内容变化会产生新 SHA-256 身份。
- 删除书架记录时“保留/删除应用内副本”双选和孤儿副本清理任务。
- iOS 真机安全作用域生命周期验证，以及 Android SAF 各文件提供方兼容验证。

以上条目仍属于 M8.1 完成标准，不能因为 TXT/EPUB/UMD/PDF 主链路存在而标记 `ANDROID_READY`。

## PDF 依赖决策

- 依赖：`pdfx 2.9.2`，MIT License。
- 平台：插件声明支持 Android 5.0+、iOS、macOS、Windows 和 Web；本工程 Android 最低版本 26 满足要求，iOS 仍需 M10 真机验证。
- 用途：只负责 PDF 文档打开、页面数量和受控页面渲染/缩放；书籍身份、目录、数据库和阅读进度仍由 Dart 领域层管理。
- 风险：原生 PDF 后端的加密文件行为和大页面峰值内存存在平台差异；当前限制为按插件可见页面渲染并在路由退出时释放控制器，不缓存无界页面位图。

## 人工验收步骤

AI 未运行 format、analyze、test、build 或真机命令。请由你执行：

1. 在 `flutter_app` 执行你需要的依赖获取、静态检查和 Android 构建，先把完整错误文本发给我处理。
2. 从欢迎页点击“导入本地书”，确认系统选择器允许多选且取消后仍停留在当前页面。
3. 选择一个 UTF-8 TXT、一个 GBK TXT、一个无章节 TXT 和一个标准 EPUB，确认列表显示文件名、大小和默认选中状态。
4. 取消其中一本的选择后点击“加入书架”，确认只处理选中项，进度逐本前进，单本失败不影响其他书。
5. 确认成功项显示“已加入书架”，再次选择完全相同文件后显示“已更新同一内容书籍”，书架中没有重复副本。
6. 选择 MOBI/AZW/AZW3、ZIP、RAR、7Z，确认逐项显示明确尚未支持原因，不生成空书。
7. 返回书架，确认本地书可见，书名/作者、章节数和最近章节与文件事实一致；点击顶部导入图标能再次进入导入页。
8. 打开各 TXT，验证目录、上一章/下一章、无章节单章、正文编码和章节边界；错误编码文件应明确反馈，不应出现永久 loading。
9. 打开 EPUB，验证 spine 顺序、章节标题和正文；损坏 container.xml、缺失 OPF 或越界路径样本应明确失败。
10. 导入文本型 UMD，验证书名、作者、章节标题和正文边界；图片型或损坏 UMD 应明确失败。
11. 导入普通 PDF，验证真实页数、纵向页面、双指缩放、页码目录跳转；返回重开后应恢复最近页码。
12. 导入损坏或加密 PDF，确认显示明确打开失败，不进入文本阅读器，也不产生空白正文。
13. 在 TXT/EPUB/UMD 中滚动、添加书签、切换替换规则、返回并重新打开，确认恢复到同一章节和接近原字符位置。
14. 关闭 App 后重新启动并断开原文件提供方，确认已经导入的 TXT/EPUB/UMD/PDF 仍可从应用私有副本读取。
15. 在书架执行刷新，确认本地书不会出现“原书源不存在”；网络书仍按 M7 行为刷新。

用户提供运行结果前，本阶段保持 `IN_PROGRESS`。
