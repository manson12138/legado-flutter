# M5 实施记录：书源管理

状态：`IN_PROGRESS / 实现待用户验证，且受 M4 BLOCKED 门禁约束`

## 已实现

- 欢迎页新增“打开书源管理”入口和稳定路由 `/book-sources`。
- `BookSourceManagementUiState`、Intent、Effect、ViewModel、Route 和纯 Screen。
- 书源列表、名称/URL/分组搜索，以及全部、启用、停用、未分组、JavaScript 筛选。
- URL 稳定 key、长按选择、批量启停、替换分组和删除确认。
- JSON 文件、文本和剪贴板导入；支持对象、数组及包裹 JSON 的转义字符串。
- 新安装 Flutter App 在书源表为空时，会从 `flutter_app/assets/default_data/book_sources.json`
  导入内置默认书源，复用同一套导入 UseCase、解码器、冲突策略和事务写入流程。
- 同 URL 冲突可选择覆盖或跳过；同批重复 URL 跳过。
- 单条无效书源进入导入摘要，有效项仍在同一事务中写入；JSON 根格式错误不触碰数据库。
- 导入未知字段保存到 `extraFieldsJson`，编辑已知字段时继续保留。
- 第一批分组编辑器覆盖名称、URL、类型、启用状态、Header、入口、四段规则、`jsLib`、登录字段、`source.getVariable()` 自定义变量和说明。
- 修改书源 URL 时原子删除旧书源并写入新书源；搜索缓存按外键清理，书架书籍不删除。
- 基础调试按网络配置、规则字段、标准 JS、同步 `java.ajax/connect`、Rhino `Packages.*` 和 WebView 依赖分类。
- 系统文件选择器通过 `file_picker` 读取 UTF-8 的 JSON/TXT/HTML，限制 5 MiB。
- Android/iOS 使用 `mobile_scanner` 打开相机，只识别二维码并隔离重复帧；相机结果限制为 64 KiB。
- 二维码可直接包含书源 JSON、HTTP/HTTPS 书源地址或原生兼容的 `{"sourceUrls":[...]}` 聚合对象；兼容 `#requestWithoutUA` 地址约定，远程读取禁用 Cookie，限制 30 秒和 5 MiB，下载后仍进入原导入对话框由用户确认。
- 外部扫码控制器显式跟随应用 inactive/resumed 生命周期停止和恢复，避免权限弹窗或前后台切换造成重复初始化。
- 扫码调试日志统一使用 `[BOOK_SOURCE_QR_SCAN]`，通过 `stage=` 串联入口、相机状态、识别、解析、远程请求、确认和最终导入结果；只记录类型、长度、数量及错误分类，不记录二维码正文、书源 URL、Header 或 Cookie。默认控制台日志器仅在 Flutter debug 模式输出。
- Android 声明相机权限，iOS 声明相机用途说明；拒绝权限、无摄像头和启动失败均显示可重试错误状态。
- M10 新增受控 WebView 登录 Route；Android/iOS 进入前写入统一 Cookie，完成、后台和内存警告时按域回写，页面销毁时解除 Delegate。
- 数据库升级到 v2，为 `book_sources` 增加 `extraFieldsJson`。

## Android 行为对照

- Android 以 `bookSourceUrl` 为唯一标识；Flutter 保持同样覆盖和稳定 key 语义。
- Android 默认书源来自 assets 出厂数据；Flutter 使用 Flutter assets 保存同类 JSON，并在空书源库启动时导入。
- Android 导入页区分新增、更新、已有，并允许保留名称、分组和启用状态；Flutter 第一批改为用户明确选择“覆盖”或“跳过”，统计新增、覆盖、跳过、无效。
- Android 支持置顶、置底、拖拽排序、导出、在线导入和分组追加/移除；Flutter 第一批只保留数据库手动顺序和分组替换，这些高级动作列入后续。
- Android 删除会清理书源缓存和配置；Flutter 删除书源、搜索缓存和独立缓存中的书源变量，不删除书架记录。
- Android 调试会真实执行搜索、详情、目录和正文；Flutter M5 只做静态分类，真实调试依赖 M4 JavaScript 门禁和 M6 搜索链路。
- Android 登录包含表单、验证码和 WebView；Flutter 已接 Android WebView/WKWebView 与统一 Cookie，真实登录、验证码和第三方 Cookie 仍受 M4/M10 真机门禁约束。

## 当前阻塞与后续矩阵

1. M4 尚未通过 Android/iOS JavaScript 真机门禁，因此 M5 不能标记完成。
2. WebView 登录和 Cookie 插件代码已实现，但尚无 Android/iOS 真实登录样本结果。
3. 扫码已支持相机中的二维码，但尚未实现从相册图片识别二维码。
4. 除二维码包含的 HTTP/HTTPS 地址外，尚未实现独立的远程 URL 在线导入入口、导出、拖拽排序、置顶/置底、分组追加/移除和全量高级字段编辑。
5. 基础调试尚不发起真实网络请求，不产生搜索、详情、目录、正文结果。
6. 未知字段已持久化保存，但导出能力未实现前还不能验证完整往返。

## 用户验收步骤

AI 未运行以下命令或操作：

1. 在 `flutter_app` 执行 `flutter pub get` 和 `flutter analyze`。
2. Android 与 iOS 各启动一次，确认数据库从 v1 升到 v2 后原书源仍存在。
3. 从欢迎页进入书源管理，导入 M04 的 `samples/s2_101kanshu_standard_js.json`。
4. 再次导入同一文件，分别验证“跳过”和“覆盖”统计。
5. 创建一个数组，其中一条有效、一条缺少 `bookSourceUrl`，确认有效项导入且失败项显示索引和原因。
6. 导入包含未知字段的书源，编辑名称后重新打开，确认其他规则和未知字段仍保留在数据库。
7. 验证搜索、筛选、单项启停、长按多选、批量启停、设置/清除分组。
8. 修改名称和规则文本，确认反斜杠、换行和 JavaScript 没有变化。
9. 修改书源 URL，确认旧 URL 不再显示、新 URL 存在，书架书籍没有被删除。
10. 在编辑器填写 JSON 书源变量，保存并重新打开确认原文保留；使用 `source.getVariable()` 的书源应读取该值。
11. 删除单项和批量项，确认都先出现明确确认对话框。
12. 打开 S2～S5 的基础调试，确认分别显示标准 JS、内存缓存缺口、同步网络差异和 Rhino/Java 不支持分类。
13. 点击“扫描二维码”，分别扫描包含单条 JSON、JSON 数组、HTTP/HTTPS 书源地址和 `sourceUrls` 聚合对象的二维码，确认识别后先展示导入文本和冲突策略，不会自动写入数据库。
14. Android 与 iOS 分别拒绝一次相机权限，确认显示明确错误；返回系统设置授权后点击重试，确认相机恢复。
15. 扫描空响应、超过 5 MiB 的远程地址、非 HTTP/HTTPS 协议和不可访问地址，确认显示安全错误且现有书源不变。
16. 点击登录入口，完成一次表单/验证码/重定向登录；关闭页面后用同域 HTTP 请求确认 Cookie 已回写，后台返回与刷新不崩溃。

用户提供 Android/iOS 结果前，M5 保持 `IN_PROGRESS`。
