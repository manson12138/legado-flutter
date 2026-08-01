# Android 外部 TXT“打开方式”关联实现方案

> 状态：`IMPLEMENTED / WAITING_FOR_USER_VERIFICATION`
>
> 分析日期：2026-07-31

## 1. 唯一目标

当用户在浏览器、下载管理器、文件管理器或其他 App 中对一个 TXT 文件选择“打开”或“打开方式”时：

1. Android 的候选应用列表中出现 `Legado Flutter`。
2. 用户选择本 App 后，无论 App 是冷启动还是已在前台，都能接收该 TXT。
3. App 打开现有“导入本地书”页面，并把该 TXT 作为已选候选文件展示。
4. 用户确认导入后，继续复用现有 `LocalBookImportCoordinator`、`LocalBookStorage` 和 `TxtLocalBookParser`，不在 Kotlin 中复制解析、书架或阅读业务。

## 2. 本次不包含

- iOS 的“在其他 App 中打开”或 Share Extension。
- Android `ACTION_SEND` 文本分享；本次只处理文件的 `ACTION_VIEW`。
- EPUB、UMD、MOBI、AZW、AZW3、PDF 和压缩包的外部文件关联。
- 接收后未经用户确认就自动写入书架或直接打开阅读器。
- TXT 编码、目录规则、书架数据库 Schema 或阅读器行为调整。
- 新增第三方依赖。

## 3. 当前实现事实与缺口

现有链路只支持 App 内主动选择文件：

```text
LocalBookImportRoute
  -> DefaultLocalBookPlatformBridge.pickBooks()
  -> file_picker / Android SAF
  -> LocalBookImportViewModel
  -> LocalBookImportCoordinator
  -> LocalBookStorage 私有副本
  -> TxtLocalBookParser
  -> 书架
```

当前 `android/app/src/main/AndroidManifest.xml` 的 `MainActivity` 只有 `MAIN/LAUNCHER` 入口，没有 `ACTION_VIEW` 的 TXT 文件关联，所以系统不会把本 App 放入 TXT 的“打开方式”列表。

`MainActivity` 当前也没有处理 `onNewIntent`，Dart 组合根没有全局 Navigator key 或外部文件事件队列。即使只增加 Manifest，用户选择本 App 后也只会普通启动首页，无法把目标 TXT 交给导入页面。

项目能力矩阵和 M8.1 实施记录已经把“外部打开/文件关联入口”登记为待实现项。本次正好补齐这一窄边界，不改变尚未完成的其他本地书格式门禁。

## 4. Android 参考实现

只读 Android 参考仓库中的相关事实：

- `app/src/main/AndroidManifest.xml`
  - `FileAssociationActivity` 通过 `ACTION_VIEW`、`CATEGORY_DEFAULT`、`CATEGORY_BROWSABLE`、`content/file` scheme 和 MIME/扩展名组合进入“打开方式”候选。
- `app/src/main/java/io/legado/app/ui/association/FileAssociationActivity.kt`
  - 接收外部 `Uri`，确认可读后导入本地书。
  - `content://` 文件不会被当作长期绝对路径保存，而是复制到可长期访问的位置后再进入业务链路。

Flutter 重写不复刻透明 Activity、旧存储权限和 Android 业务 ViewModel；只保留“系统文件关联、立即取得可读副本、交给共享导入链路”的行为。

## 5. 推荐实现

### 5.1 Manifest 文件关联

在 `MainActivity` 上新增独立 `ACTION_VIEW` intent-filter：

- `CATEGORY_DEFAULT`
- `CATEGORY_BROWSABLE`
- `content` 与 `file` scheme
- `text/plain`
- 对 MIME 不准确但 URI 路径仍带 `.txt`/`.TXT` 的发送方，增加扩展名匹配过滤

Android 的文件提供方并不总能同时提供可靠 MIME 和可见文件名，因此无法做到候选列表层面绝对只匹配 TXT。宿主接收后仍必须再次校验显示名、MIME、可读性和实际大小；无效输入返回受控提示，不能传入解析器伪装成 TXT。

不声明 `application/octet-stream` 的无条件广泛匹配，避免本 App 出现在大量未知二进制文件的候选列表中。

### 5.2 原生接收与临时副本

新增窄职责 Android 宿主桥，职责仅限：

1. 从 `MainActivity.intent` 和 `onNewIntent` 接收 `ACTION_VIEW`。
2. 只接受单个 `content://` 或 `file://` TXT 输入。
3. 使用 `ContentResolver` 查询安全显示名和大小。
4. 在后台线程流式复制到应用 cache 下的专用临时目录。
5. 设置与 `LocalBookStorage.maxBookBytes` 一致的 1 GiB 上限，并在复制过程中再次计数，防止提供方谎报大小。
6. 通过 MethodChannel 返回临时绝对路径、显示名、实际大小和一次性清理 token。
7. 在成功、失败、用户取消、路由销毁和下次启动清理过期文件，所有输入流、输出流和后台执行器都有明确释放路径。

原生桥不得读取 TXT 正文、判断编码、生成目录、写数据库或决定书架冲突。

### 5.3 冷启动、热启动和导航

增加 Dart 侧外部本地书入口服务：

- 冷启动：Dart 通道就绪后主动消费原生保存的初始请求。
- 热启动：`MainActivity.onNewIntent` 通知同一通道，Dart 再消费新请求。
- 启动遮罩和游客/账号作用域尚未准备好时，入口服务只保留一个受控待处理请求；业务 Navigator 可用后再导航。
- `LegadoApp` 提供生命周期稳定的 `GlobalKey<NavigatorState>`，不依赖页面 `BuildContext`。
- 导航到 `AppRoute.localBookImport` 时通过类型化路由参数传入候选文件和临时文件所有权。

同一个 Intent 只能消费一次。快速重复收到相同 URI 时按本次会话去重，避免重复压入多个导入页；不同文件按到达顺序处理，不无界积压。

### 5.4 复用导入确认页

扩展 `LocalBookImportRoute` 和 `LocalBookImportViewModel`，允许路由创建时注入初始候选文件：

- 外部 TXT 默认选中，但不自动开始导入。
- 用户点击“导入所选”后，完全复用现有导入协调器。
- 导入成功、更新或失败后，释放原生临时副本。
- 用户未导入直接返回时，同样释放临时副本。
- 系统文件选择器产生的普通候选不改变现有生命周期。

这样既满足“用本 App 打开”，也避免仅因点错候选应用就立即产生书架持久数据。

## 6. 预计修改文件

| 文件 | 预计改动 |
|---|---|
| `android/app/src/main/AndroidManifest.xml` | 声明 TXT `ACTION_VIEW` 文件关联 |
| `android/app/src/main/kotlin/io/legado/flutter/MainActivity.kt` | 转发初始 Intent、`onNewIntent` 和宿主桥生命周期 |
| `android/app/src/main/kotlin/io/legado/flutter/ExternalTxtOpenBridge.kt` | 新增 URI 校验、后台临时复制、通道投递和清理 |
| `lib/src/platform/external_local_book_open_service.dart` | 新增类型化 Dart 平台入口、事件和临时文件释放边界 |
| `lib/src/app/app_route.dart` | 新增本地书导入类型化路由参数 |
| `lib/src/app/app_router.dart` | 把外部 TXT 候选注入导入路由 |
| `lib/src/app/legado_app.dart` | 增加稳定 Navigator key，协调冷/热启动外部请求 |
| `lib/src/ui/local_book_import/local_book_import_route.dart` | 接收初始候选并保证临时副本释放 |
| `docs/flutter-rewrite/m08_1/README.md` | 记录外部 TXT 关联实现状态和未验证边界 |
| `docs/flutter-rewrite/m00/03_file_mapping.md` | 补充 Android 文件关联到 Flutter 宿主/Dart 的映射 |
| `docs/flutter-rewrite/m00/07_platform_capability_matrix.md` | 更新 Android 外部 TXT 打开能力状态 |
| `docs/flutter-rewrite/AI_PROJECT_INDEX.md` | 更新本地书和平台宿主索引 |

不涉及 SQLite Schema，也不需要修改 `LegadoDatabase.schemaVersion` 或 `pubspec.yaml` 构建号。

实际实现没有修改 `LocalBookPickedFile` 和 `LocalBookImportViewModel`：路由参数独立持有清理
token，`LocalBookImportRoute` 使用既有 `LocalBooksPickedIntent` 注入候选，并监听已有状态流
判断导入终态。这样没有把 Android 临时文件所有权写入共享领域模型，也没有增加 ViewModel
职责。

## 7. 性能、内存与隐私边界

- 外部文件必须流式复制，禁止 `readBytes()` 把整本 TXT 放进 Kotlin 或 Dart 内存。
- 复制必须运行在后台线程，不能阻塞 Android 主线程或 Flutter 首帧。
- 待处理请求和临时文件数量必须有上限，避免恶意 App 连续投递造成磁盘占用。
- 不长期持有 `Activity`、`Intent`、`Uri`、输入流或 MethodChannel 回调，防止内存和句柄泄漏。
- 日志默认不记录文件绝对路径、完整文件名或 TXT 内容。
- 本任务不需要新增诊断日志；如果实现时确有必要，全部使用统一 Tag `EXTERNAL_TXT_OPEN`，并用统一标识包围只为日志服务的变量和方法。

## 8. 用户验收

代码写入后由用户执行，不由 Codex 运行：

1. 冷启动：在浏览器或文件管理器下载一个 UTF-8 `.txt`，点“打开方式”，确认列表出现 `Legado Flutter`。
2. 选择本 App，确认进入本地书导入页，且该文件已显示并默认选中。
3. 点击导入，确认成功加入当前游客或登录账号的书架，并能正常阅读。
4. 把 App 留在前台，再从其他 App 打开另一个 TXT，确认热启动也进入新的导入确认页。
5. 分别验证 `content://`、可用时的 `file://`、`.txt` 和 `.TXT`。
6. 在导入页直接返回，确认下次打开不会重复出现旧请求。
7. 使用空文件、超过上限文件、不可读 URI 和伪装扩展名，确认给出受控错误且 App 不崩溃。
8. 使用 PDF、图片和其他二进制文件，确认本 App不会因宽泛的 octet-stream 声明普遍出现在候选列表。
9. 导入成功、失败和取消后检查应用 cache，确认外部打开临时副本能够被清理。

## 9. 完成判断

只有用户完成至少冷启动、热启动、真实 `content://` TXT 导入和取消清理验收后，才能把该能力从 `IN_PROGRESS` 改为 `DONE`。本分析文档本身不代表代码已经实现。

## 10. 2026-07-31 首次真机反馈修正

- 外部文件 Intent 会被自有 MethodChannel 正常消费，但 Flutter embedding 的默认深链路还会把同一个 `content://` 当成应用路由；导入页返回后因此露出“未找到路由”错误页。
- `MainActivity` 已声明 `flutter_deeplinking_enabled=false`，外部文件 Uri 现在只经过 `ExternalTxtOpenBridge`，不再进入 Flutter 页面路由栈。
- `MainActivity` 的启动模式由只复用栈顶实例的 `singleTop` 调整为 `singleTask`，避免从其他 App 打开 TXT 时创建第二个 Flutter Activity/引擎并返回旧实例的书架快照；后续请求统一经现有实例的 `onNewIntent` 处理。
- 导入操作区由内容宽度驱动的 `Wrap` 改为固定单行比例布局；“全选/取消”文字变化不再把“加入书架”挤到第二排。
- “导入完成”提示仍只会在 `AddBookToBookshelfUseCase.save` 的数据库事务成功后出现；书架通过既有数据库流刷新，不新增第二套手工书架状态。
