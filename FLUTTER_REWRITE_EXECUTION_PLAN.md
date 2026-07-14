# Legado Flutter 1:1 重写规则与执行方案

> 文档定位：本文件首先是提供给 AI 编码代理阅读和执行的强制规则，其次才是提供给开发者阅读的迁移方案。
>
> 当前状态：M1 工程骨架与 M2 核心数据层代码已实现，均待用户运行验证。
>
> 最后更新：2026-07-13。

> 分阶段执行时，必须同时阅读 [`steps/MIGRATION_STEPS_INDEX.md`](./steps/MIGRATION_STEPS_INDEX.md) 和对应阶段文档。

---

# 第一部分：AI 必读强制规则

## 1. 指令优先级与执行原则

1. AI 在修改 Flutter 重写相关代码前，必须完整阅读本文件，不能只读取与当前任务看似相关的局部章节。
2. 用户当前回合的明确要求优先于本文件；本文件优先于 AI 自行推断的最佳实践。
3. 如果本文件与仓库根目录 `AGENTS.md` 冲突，优先执行用户最新明确要求，其次执行根目录 `AGENTS.md` 中更严格、更谨慎的规则。
4. 不允许将“1:1 重写”理解成逐行翻译。这里的 1:1 指：
   - 功能入口一致；
   - 业务行为一致；
   - 数据含义一致；
   - 普通规则解析结果一致；
   - JavaScript 规则在已定义兼容边界内结果一致；
   - 文件、类、方法尽量存在可搜索映射；
   - Android 与 iOS 在平台允许的范围内结果一致。
5. 优先保证行为正确，其次保证命名可映射，再其次才是视觉细节和代码形式相似。
6. 不得为了追求形式上的文件对应，创建没有职责、没有行为、以后也不会使用的空壳抽象。
7. 如果某个 Android 实现不能直接迁移，必须保留概念映射、近似类名或方法名，并在迁移映射中说明差异，不能静默省略。
8. 不允许超出当前任务顺便重构、格式化或删除原 Android 项目的代码。
9. 原 Android 项目是只读功能基准。除非用户明确要求，否则 Flutter 重写任务不得修改原 Android 业务实现。
10. 任何不确定且会改变数据模型、规则兼容、导航、平台桥接或交付范围的问题，必须先向用户说明，不能静默选择。

## 2. 用户已确认且不得擅自改变的项目决策

1. Flutter 工程与原 Android 工程放在同一个 Git 仓库内。
2. Flutter Android 是一个新的独立应用，与原 Android 应用共存。
3. Flutter 应用不迁移、不读取、不兼容原应用的私有数据库和历史安装数据。
4. 普通书源规则和 JavaScript 书源规则都属于必须实现的核心功能。
5. 允许编写 Android Kotlin 和 iOS Swift 原生桥接，但必须优先评估 Dart/Flutter 实现。
6. UI 只要求功能一致，不要求与原 Android 页面像素级一致。
7. Android 和 iOS 使用统一的 Flutter 视觉体系，不维护两套完整 UI。
8. iOS 主要用于自用安装，不以 App Store 上架审核作为第一阶段约束。
9. 原 Android 项目在重写期间不继续增加新功能，迁移基线保持稳定。
10. 第一批可用版本只要求打通核心阅读闭环：书源、搜索、书架、阅读。
11. 开发顺序必须是 Android 优先；Android 核心闭环验收后，再完成 iOS 核心闭环。
12. 系统版本暂定为 Android `minSdk 26`、iOS Deployment Target `16.0`。用户以后明确修改时再调整。

## 3. 禁止执行的操作

1. 不要运行编译、构建、测试、Lint、格式检查、静态分析或任何代码检查命令；代码写完后由用户运行。
2. 不要运行 `flutter analyze`、`dart analyze`、`flutter test`、`dart test`、`flutter build`、`flutter run`、Gradle 构建或 Xcode 构建。
3. 不得使用 Kotlin `!!` 强制解包。
4. Dart 代码也不得依赖 `!` 强制空值断言解决可空问题；应使用提前返回、模式匹配、空值判断、局部非空变量或安全默认值。
5. 不得吞掉异常后伪装成功，不得把规则解析失败转换为空结果而不保留错误原因。
6. 不得将业务逻辑写入 Widget 的 `build()`、点击回调或路由配置中。
7. 不得让 UI 层直接访问数据库、执行 HTTP、解析书源或操作文件系统。
8. 不得让 Dart 业务代码直接依赖 `BuildContext`、Android `Context`、`Activity`、iOS `UIViewController` 等平台对象。
9. 不得为了快速实现 Android，直接把核心业务长期留在 Kotlin，然后在 iOS 再写第二套逻辑。
10. 不得在没有真实兼容样本的情况下宣称 JavaScript 已 100% 兼容。
11. 不得未经说明更换书源、备份、导入导出或配置文件的数据格式。
12. 不得随意增加第三方依赖。新增依赖前必须说明用途、维护状态、平台支持、是否可替换以及引入风险。
13. 不得将密钥、Token、签名文件、证书、个人路径或用户隐私数据提交到仓库。
14. 不得主动执行 `git add`。每次产生新文件后，必须在交付说明中询问用户是否加入 Git 暂存区。
15. 不得删除原 Android 文件来表示“迁移完成”。Flutter 与原 Android 工程必须长期共存，直到用户另行决定。

## 4. AI 每次开始任务前的强制流程

AI 在实现任何功能前必须按顺序完成以下动作：

1. 明确本次任务的唯一目标和不包含内容。
2. 找出对应的 Android 功能入口和所有关联文件，至少包括：
   - Activity、Fragment 或 Compose Screen；
   - Contract、ViewModel；
   - XML、菜单、Dialog、BottomSheet；
   - Adapter、ViewHolder、列表装饰；
   - Entity、DAO、Repository、UseCase；
   - Service、Receiver、事件总线；
   - Intent extra、Activity result、权限和文件选择；
   - 相关工具类和扩展函数。
3. 写出需要保持的行为清单，包括入口、状态、操作、副作用、数据保存和返回行为。
4. 查找 Flutter 中是否已经有可复用组件、Repository、UseCase 或平台接口。
5. 更新或准备文件映射，明确每个 Android 文件对应的 Flutter 文件。
6. 判断实现属于纯 Dart、Flutter 插件、Kotlin 桥接、Swift 桥接还是平台不支持。
7. 定义可由用户执行的验收步骤，再开始编码。
8. 只修改本次目标需要的文件。
9. 写完后列出改动、已知差异、用户需要运行的检查命令和人工验收步骤，但 AI 自己不运行。
10. 如果新增了文件，明确询问用户是否执行 `git add`。

## 5. 注释强制规则

1. 所有新增的类、枚举、扩展、顶级函数、方法和变量都必须有中文注释。
2. 公开 API 使用 Dart 文档注释 `///`；私有但职责不直观的方法和变量也必须使用 `///` 或紧邻的 `//` 说明。
3. 注释必须解释职责、输入输出、状态变化或平台差异，不能只把名称翻译一遍。
4. 从 Android 迁移的方法应在注释中标明对应的 Android 类或方法，便于全局搜索。
5. 平台桥接接口必须注明：
   - Android 实现位置；
   - iOS 实现位置；
   - 不同平台行为差异；
   - 失败时返回或抛出的错误类型。
6. 为兼容 JavaScript 暴露的类和方法必须注明其脚本可见名称，不能随意重命名。
7. 临时兼容代码必须标记原因和删除条件，禁止只有 `TODO` 而没有上下文。
8. 日志专用变量、方法和调用必须使用统一标识，方便以后完整移除。

## 6. 日志规则

1. 同一次问题排查使用统一 Tag，不能每个文件各自创建 Tag。
2. 仅为日志创建的方法、变量、格式化代码和调用位置必须加统一标识，例如 `FLUTTER_REWRITE_DEBUG_LOG`。
3. Kotlin 日志字符串必须特别检查 `\`、`$`、引号和模板表达式转义。
4. Dart 日志字符串必须特别检查 `\`、`$`、单引号、双引号和多行文本转义。
5. 不记录书源账号、Cookie、Authorization、正文隐私内容、文件绝对路径或用户输入的密钥。
6. 移除日志时必须同时移除：
   - 日志调用；
   - 只为日志存在的变量；
   - 只为日志存在的方法；
   - 只调用日志专用方法的调用点；
   - 因日志产生的 import。
7. 移除日志不得改变业务判断、返回值、异常处理和异步顺序。

## 7. 文件规模与拆分规则

1. 新文件应保持单一职责，但不得为了形式整齐过度拆分。
2. 当一个文件超过 4,000 行后，再新增方法前必须评估是否可以迁移到职责明确的独立文件。
3. 拆分必须按领域职责进行，例如解析器、平台桥接、状态契约、页面区块，不得按任意行数切割。
4. 不得在迁移一个功能时顺便拆分原 Android 超大文件，除非用户明确要求修改原项目。
5. Flutter 页面复杂时优先拆分无状态 UI 区块；业务状态仍由同一 Feature ViewModel/Controller 统一管理。

## 8. 空安全规则

1. Kotlin 可空变量只能使用安全调用、空判断、`?.let`、Elvis 或提前返回，禁止 `!!`。
2. Dart 禁止用 `!` 掩盖模型设计问题。
3. 外部输入一律视为不可信，包括 JSON、数据库、书源规则、JavaScript 返回值、平台通道结果和文件内容。
4. Entity 的可空性必须参考原 Android 数据含义，不能为了少写判断把所有字段改成非空默认空字符串。
5. 空字符串、空集合、`null` 和字段缺失具有不同业务含义时必须分别处理。
6. 平台通道返回值应转换为明确的领域结果或受控异常，不能把动态 Map 直接传入 UI。

## 9. IM/聊天界面特殊规则

1. 用户的 IM 项目聊天列表 RecyclerView 是反转的；迁移或实现聊天/AI 聊天列表时必须保留“底部为最新消息”的反转语义。
2. Flutter 中不能仅靠视觉排序模拟，必须明确处理：
   - 数据顺序；
   - `reverse` 列表行为；
   - 加载历史消息时的滚动位置保持；
   - 新消息到达后的自动滚动条件；
   - 键盘弹出后的锚点；
   - 重试消息和流式消息更新。
3. 在未检查原聊天实现前，不得自行决定列表数据是正序还是倒序。

---

# 第二部分：项目目标、范围与完成定义

## 10. 最终目标

在当前仓库中新增一个 Flutter 应用，用 Flutter/Dart 重写现有 Legado Android 项目的功能，最终使 Android 和 iOS 都能够正常运行。

最终产品应满足：

1. Android 和 iOS 使用同一套核心业务代码。
2. Android 和 iOS 能导入并使用普通规则书源和 JavaScript 书源。
3. 两个平台均可完成搜索、加入书架、获取目录、阅读正文和恢复进度。
4. 后续逐步覆盖原 Android 项目的其余功能。
5. Flutter 文件、类和方法与 Android 原实现保持可搜索映射。
6. 平台无法等价实现的功能有明确替代行为和差异文档。
7. 新应用不依赖原应用安装，也不读取原应用数据库。

## 11. “Android 能运行”的分级定义

为避免把空壳启动误认为迁移完成，Android 运行状态分为四级：

### A0：工程启动

- Flutter Android 可以安装并启动。
- 能显示欢迎页或主框架。
- 路由、主题、依赖注入和错误边界已接入。

### A1：技术闭环

- 可导入一份受控测试书源。
- 可搜索并解析一本书。
- 可获取目录与正文。
- 可在基础阅读页展示正文。

### A2：第一批可用版本

- 真实书源可导入和管理。
- 搜索、详情、书架、目录、阅读完整可用。
- 阅读进度可以保存和恢复。
- 常见错误有明确反馈。

### A3：Android 功能对齐

- 原 Android 项目功能矩阵中约定的功能全部完成。
- 所有平台差异均已登记并经用户接受。

用户所说的第一阶段目标至少指 A2，不得只交付 A0 后宣称 Android 已完成。

## 12. “iOS 正常运行”的定义

1. 在用户的 iPhone 15 Pro Max、iOS 26 真机上可以自用签名安装。
2. 能完成与 Android A2 相同的核心阅读闭环。
3. 普通规则和目标 JavaScript 兼容样本在 iOS 上通过。
4. 文件选择、相机、WebView、网络、Cookie 和本地存储使用 iOS 合法能力实现。
5. 前后台切换、内存警告、安全区域、系统手势和音频会话行为可控。
6. iOS 不支持的 Android 能力有明确降级，不出现无响应按钮。

## 13. 第一批范围

第一批只包含：

1. 应用基础框架。
2. 书源导入和基础管理。
3. 普通规则解析。
4. JavaScript 运行与兼容桥接。
5. 网络、Cookie、字符集与必要 WebView 能力。
6. 搜索。
7. 书籍详情与目录。
8. 加入书架。
9. 书架展示与基础管理。
10. 文本阅读器。
11. 阅读进度保存和恢复。

第一批默认不包含：

1. 完整 RSS。
2. AI 全部功能。
3. 漫画阅读器完整能力。
4. 音频播放完整能力。
5. TTS/HTTP TTS 完整能力。
6. 内置 Web 服务完整能力。
7. 全部高级主题和图标切换。
8. 与旧 App 的数据升级迁移。

以上默认不包含项不是永久删除，而是在功能矩阵中保持待迁移状态。

---

# 第三部分：目标架构

## 14. 总体架构原则

采用 Flutter UI + Dart 核心业务 + 最小平台桥接：

```text
Flutter UI
    ↓ Intent
Feature ViewModel / Controller
    ↓ UseCase
Domain Gateway
    ↓
Repository
    ↓
DAO / HTTP / File / JavaScript Engine / Platform API
```

规则：

1. UI 只渲染状态并发送 Intent。
2. ViewModel/Controller 维护页面状态并调度 UseCase。
3. UseCase 表达可复用业务动作。
4. Repository 组合数据来源。
5. DAO 只负责数据库访问。
6. 平台接口位于 `platform` 或独立插件包中。
7. Kotlin/Swift 不持有跨页面业务状态。
8. Android 与 iOS 不得各自复制书源解析、数据库业务或阅读进度逻辑。

## 15. 推荐目录

```text
flutter_app/
├── android/
├── ios/
├── lib/
│   ├── main.dart
│   └── src/
│       ├── app/
│       ├── api/
│       ├── base/
│       ├── constant/
│       ├── data/
│       │   ├── dao/
│       │   ├── entities/
│       │   ├── local/
│       │   ├── model/
│       │   └── repository/
│       ├── domain/
│       │   ├── gateway/
│       │   ├── model/
│       │   └── usecase/
│       ├── help/
│       ├── model/
│       │   ├── analyze_rule/
│       │   ├── cache/
│       │   ├── local_book/
│       │   ├── rss/
│       │   └── web_book/
│       ├── platform/
│       ├── service/
│       ├── ui/
│       ├── utils/
│       └── web/
├── packages/
│   └── legado_platform/
├── test/
└── integration_test/
```

最终目录以实际职责为准，但不得失去与 Android 包结构的可搜索关系。

## 16. MVI/UDF 页面规则

行为复杂的页面统一包含：

```text
feature_contract.dart
feature_view_model.dart
feature_screen.dart
feature_route.dart          # 只有路由接线复杂时需要
feature_dialogs.dart        # 只有对话框较多时需要
feature_sheets.dart         # 只有底部面板较多时需要
```

Contract 至少定义：

```dart
/// 页面所有可渲染状态。
final class FeatureUiState {}

/// 页面允许发送给 ViewModel 的用户意图。
sealed class FeatureIntent {}

/// 导航、Toast、文件选择等一次性副作用。
sealed class FeatureEffect {}
```

强制要求：

1. `FeatureScreen` 不直接获取 DAO、Repository 或平台插件。
2. 所有用户业务操作通过 `onIntent` 进入 ViewModel。
3. 导航、Toast、系统选择器、权限请求属于 Effect，不作为长期布尔状态保存。
4. 对话框是否显示可保存在 UiState；真正执行系统行为仍使用 Effect。
5. UiState 对外不可变。
6. 长列表项必须使用稳定业务 ID 作为 key。
7. 页面局部动画、菜单展开和滚动控制可以使用 Widget 本地状态，但不得保存业务事实。

## 17. 依赖注入规则

1. 依赖注入方案只选择一种，项目中不得并存多套容器。
2. ViewModel 通过构造参数获取 UseCase 或 Gateway。
3. Repository 通过构造参数获取 DAO、网络客户端、文件接口或脚本引擎。
4. 禁止在业务代码中到处调用全局 Service Locator。
5. 平台实现注册在应用组合根，不得让领域层判断 `Platform.isAndroid`。

## 18. 并发与生命周期规则

1. 所有异步操作必须明确取消方式、超时策略和生命周期归属。
2. 搜索、多书源校验、章节下载必须限制并发数，不得无界创建 Future。
3. 页面销毁后不再向已销毁状态对象发送更新。
4. 新搜索开始时，旧搜索是否取消必须与原 Android 行为一致。
5. JavaScript 执行必须支持超时和中断，避免恶意或错误脚本永久占用线程。
6. 数据库事务边界必须由 Repository 或 DAO 明确控制。
7. 不在 UI isolate 执行大文本解析、压缩、复杂正则或大批量 JSON 转换。

---

# 第四部分：命名与映射规则

## 19. 文件映射规则

Android 到 Flutter 的默认映射：

| Android | Flutter | 规则 |
|---|---|---|
| `Book.kt` | `book.dart` | Dart 类仍为 `Book` |
| `BookSource.kt` | `book_source.dart` | Dart 类仍为 `BookSource` |
| `BookDao.kt` | `book_dao.dart` | 接口或类仍为 `BookDao` |
| `AnalyzeRule.kt` | `analyze_rule.dart` | 类仍为 `AnalyzeRule` |
| `AnalyzeUrl.kt` | `analyze_url.dart` | 类仍为 `AnalyzeUrl` |
| `ReadBook.kt` | `read_book.dart` | 协调器仍为 `ReadBook` |
| `BookInfoContract.kt` | `book_info_contract.dart` | State/Intent/Effect 保持 BookInfo 前缀 |
| `BookInfoViewModel.kt` | `book_info_view_model.dart` | 类仍为 `BookInfoViewModel` |
| `BookInfoScreen.kt` | `book_info_screen.dart` | Widget 仍为 `BookInfoScreen` |

## 20. 方法映射规则

1. 原方法的业务含义未改变时，Dart 方法名保持一致。
2. Kotlin `suspend` 方法转换为返回 `Future<T>` 的同名 Dart 方法。
3. Kotlin `Flow<T>` 根据语义转换为 `Stream<T>` 或状态容器，但方法基础名称保持一致。
4. Kotlin 扩展函数优先转换为 Dart extension；不适合时转换为同名工具类方法并记录原因。
5. Kotlin 重载在 Dart 无法保持时，保留最常用名称，其余使用语义后缀，并在映射文档中登记。
6. Java Bean 风格脚本 API 必须保留脚本实际调用的方法名。
7. 不得为了符合个人 Dart 风格而大规模重命名领域术语。

## 21. 迁移映射记录格式

每个迁移项至少包含：

```text
Android 路径：
Flutter 路径：
Android 类型/方法：
Flutter 类型/方法：
迁移状态：
实现方式：Dart / Plugin / Kotlin / Swift / 不支持
行为差异：
平台差异：
验收方式：
备注：
```

迁移状态只能使用：

- `NOT_STARTED`
- `MAPPING`
- `IN_PROGRESS`
- `ANDROID_READY`
- `IOS_READY`
- `DONE`
- `BLOCKED`
- `NOT_APPLICABLE`

不得用模糊的“差不多完成”“基本可用”。

---

# 第五部分：数据、网络与规则兼容

## 22. 数据库规则

1. Flutter 使用全新数据库，不执行原 Room 1～94 的历史迁移。
2. 为便于对照，表名、字段名、索引和领域含义尽量与当前 Android 最新 Schema 一致。
3. 不得直接复制 Room 注解或 SQL 而不核对其真实查询语义。
4. Entity、DAO、Repository 必须分层，UI 不得直接使用 DAO。
5. 每个字段记录：类型、可空性、默认值、主键、唯一约束、索引和序列化名称。
6. 时间字段统一说明单位和时区，禁止同一字段有秒/毫秒混用。
7. URL 作为业务主键时必须明确规范化规则，不能随意 trim 或转小写。
8. 批量导入必须使用事务，失败时保持可预测的回滚行为。
9. 第一批只迁移核心阅读闭环需要的表，其余表进入功能矩阵，不创建无用空表。

## 23. 网络规则

1. 网络层必须统一处理 Header、Cookie、重定向、代理、超时、字符集、压缩和错误类型。
2. 规则引擎不能绕开统一网络层自行选择任意 HTTP 客户端。
3. 保留书源自定义 Header、请求体、编码方式和响应字符集能力。
4. Cookie 行为必须在纯 HTTP、JavaScript 和 WebView 之间定义同步策略。
5. Android 与 iOS 的 TLS/WebView 差异必须记录，不能将平台错误误判为书源规则错误。
6. 网络错误至少区分 DNS、连接、TLS、超时、HTTP 状态、解码、取消和脚本错误。
7. 日志不得输出敏感 Header 和 Cookie。

## 24. 普通规则兼容范围

第一批必须覆盖：

1. JSONPath。
2. XPath。
3. CSS/JSoup 风格选择器。
4. 正则表达式。
5. 字符串拼接与替换规则。
6. URL 规则与请求选项。
7. 书籍列表规则。
8. 书籍详情规则。
9. 目录规则。
10. 正文规则。
11. 登录和验证码流程所需规则。
12. 字符编码和必要的字体处理入口。

兼容不是“语法能解析”即可，必须比较实际输出。

## 25. JavaScript 兼容边界

JavaScript 兼容分为三个层级：

### JS-L1：标准语法与运行环境

- 支持项目真实书源使用的 ECMAScript 语法。
- 支持对象、数组、正则、JSON、日期和常见内置对象。
- 支持编译、执行、超时、中断和错误堆栈。

### JS-L2：Legado 暴露 API

- 兼容书源脚本实际使用的 `source`、`book`、`chapter`、`result`、Cookie、缓存、网络和工具对象。
- 脚本可见名称、参数含义和返回结构尽量保持一致。
- Dart 内部实现可以不同，但脚本观察到的行为必须一致。

### JS-L3：Rhino/Java 兼容 API

- 扫描真实书源对 `java.*`、Android 类、Kotlin/Java 工具类的调用。
- 为常用调用提供 `JavaCompatibilityBridge`。
- 桥接在 Android 和 iOS 暴露相同脚本表面。
- iOS 无法运行任意 JVM 类，因此不得承诺无限制 Java 反射兼容。
- 未支持调用必须返回包含书源、类名、方法名和调用位置的明确错误。

项目的“JavaScript 必须兼容”以通过用户确认的真实书源兼容样本为最终标准，而不是以任意 JVM 字节码均可执行为标准。

## 26. JavaScript 引擎选择门禁

在确定引擎前必须完成原型对比，至少评估：

1. Android/iOS 是否使用同一引擎和版本。
2. ECMAScript 支持范围。
3. Dart 对象和函数绑定能力。
4. 同步与异步桥接。
5. 超时和主动中断。
6. 内存限制和引擎实例隔离。
7. 错误堆栈质量。
8. 正则和日期行为差异。
9. 中文字符和编码行为。
10. 原生代码量。
11. 包体积和维护状态。
12. 许可证是否允许项目使用。

没有完成该原型，不得大批量迁移依赖 JavaScript 的 UI。

## 27. 真实兼容样本

用户需要提供或确认一组常用书源 JSON。样本应覆盖：

- 普通规则书源；
- JavaScript 搜索；
- JavaScript 详情；
- JavaScript 目录；
- JavaScript 正文；
- 自定义 Header；
- Cookie；
- 登录；
- 验证码；
- WebView；
- POST；
- 字符编码；
- Java/Rhino API 调用；
- 多步骤请求。

每份样本记录固定输入和预期输出，敏感账号和 Cookie 不得提交仓库。

---

# 第六部分：Flutter UI 设计规范

## 28. UI 一致性的定义

UI 不要求复制原 Android 像素，但必须保留：

1. 页面入口和信息层级。
2. 主要操作、次要操作和危险操作。
3. 点击、长按、滑动、选择和返回行为。
4. 搜索、排序、筛选和刷新行为。
5. 加载、空数据、错误、离线和正常状态。
6. 对话框、底部面板、菜单和选择模式。
7. 数据保存时机和页面恢复行为。
8. 用户完成同一任务所需的关键步骤。

可以改变：

- Android XML 层级；
- Activity/Fragment 结构；
- RecyclerView Adapter 结构；
- Material 3 或 Miuix 的具体外观；
- 不影响操作含义的过渡动画。

## 29. 单一视觉系统

1. Android 和 iOS 默认使用同一套 Flutter 组件。
2. 不为 Android 做一套 Material 页面、为 iOS 做一套 Cupertino 页面。
3. 系统文件选择、权限、分享、通知、键盘、WebView 和媒体控制允许平台原生差异。
4. 所有页面从统一 Theme 和 Design Token 取值，禁止散落魔法数字和颜色。
5. 原 Android 主题只作为功能和内容层级参考，不作为逐像素复制目标。

## 30. Design Token

必须统一定义：

```text
ColorToken
TypographyToken
SpacingToken
RadiusToken
ElevationToken
DurationToken
ReaderToken
```

基础间距建议以 4 为节奏，至少提供：4、8、12、16、20、24、32。

不得在业务页面重复定义已有 Token。

## 31. 公共组件

第一批开发前应优先提供：

```text
AppScaffold
AppTopBar
AppNavigationBar
AppButton
AppIconButton
AppListTile
AppCard
AppDialog
AppBottomSheet
AppSearchBar
AppEmptyView
AppErrorView
AppLoadingView
AppSelectionBar
BookCover
BookListItem
SourceListItem
SettingItem
```

新增公共组件的条件：至少两个明确页面需要，或它代表项目级视觉/交互约束。单页面一次性小部件留在 Feature 内部。

## 32. 页面状态规则

每个数据页面必须明确处理：

1. 首次加载。
2. 正常数据。
3. 空数据。
4. 可恢复错误。
5. 不可恢复错误。
6. 刷新中。
7. 分页加载中和分页失败（适用时）。
8. 用户选择模式（适用时）。
9. 权限被拒绝（适用时）。

禁止仅显示无限转圈而不给错误出口。

## 33. 可访问性与布局规则

1. 交互触摸区域不得小于 44×44 logical pixels。
2. 普通页面支持系统文字缩放；阅读器正文使用用户独立字号设置。
3. 页面必须处理 Android edge-to-edge 和 iOS Safe Area。
4. 深色模式下文字、图标、分割线和选中状态必须可辨识。
5. 图标按钮提供语义标签。
6. 颜色不能成为表达状态的唯一方式。
7. 长列表使用惰性构建并提供稳定 key。
8. 键盘弹出时输入框、提交按钮和当前内容不得被不可恢复地遮挡。

## 34. 阅读器专项规则

阅读器必须独立设计，至少考虑：

1. 章节内容模型。
2. 文本排版与分页结果。
3. 阅读位置的稳定标识，不能只保存屏幕滚动像素。
4. 章节前后预加载。
5. 字体、字号、行距、段距和边距。
6. 背景、文字颜色和亮度。
7. 状态栏、导航栏和安全区域。
8. 点击区域和手势冲突。
9. 上下滚动、覆盖翻页和后续动画扩展。
10. 横竖屏、窗口尺寸和字体变化后的进度恢复。
11. 替换规则、正文净化和内容刷新。
12. 目录跳转、书签和章节错误重试。
13. 后续 TTS 高亮和媒体控制扩展点。

第一批允许只实现上下滚动，但数据结构不得阻止后续翻页模式。

---

# 第七部分：平台桥接规则

## 35. 使用优先级

每项能力按以下顺序评估：

1. 纯 Dart 实现。
2. Flutter 官方或稳定跨平台插件。
3. 自研 Flutter Plugin，Dart 暴露统一接口。
4. Kotlin/Swift 原生实现。
5. 平台替代方案。
6. 明确标记不支持。

不得因为 Android 原项目已有 Kotlin 实现，就跳过 Dart 方案评估。

## 36. 平台接口规则

1. 领域层只依赖抽象接口。
2. Android/iOS 实现通过依赖注入提供。
3. MethodChannel/EventChannel/FFI 数据必须使用明确 DTO。
4. 通道名称、方法名、参数和错误码集中定义。
5. Kotlin 和 Swift 都不得复制领域状态机。
6. 原生回调转换为 Stream 或受控 Effect。
7. 每个原生能力提供生命周期关闭方法，避免监听器和资源泄漏。

## 37. 已知平台差异

以下 Android 能力在 iOS 上不能直接 1:1：

- 任意外部存储访问；
- 安装 APK；
- Android 前台 Service；
- BroadcastReceiver；
- 长时间无限制后台 Web 服务；
- 部分无限期后台缓存；
- Cronet；
- Android Intent；
- 厂商专属功能和快捷入口；
- 任意 JVM 类加载。

处理规则：

1. 优先使用 iOS 系统等价能力。
2. 没有等价能力时提供功能目标相近的替代流程。
3. 替代后仍无法达到目标时，在 UI 中明确提示平台限制。
4. 保留对应方法或能力接口，返回明确的 unsupported 结果。
5. 所有差异写入平台能力矩阵。

---

# 第八部分：分阶段执行方案

## 38. M0：决策与迁移账本

交付物：

- 项目决策文档；
- 架构文档；
- 文件和命名映射；
- UI 规范；
- 功能矩阵；
- JavaScript 兼容规范；
- 平台能力矩阵；
- 验收标准。

完成门禁：第一批范围内每个主要 Android 文件都有迁移归属。

## 39. M1：Flutter 工程骨架

交付物：

- `flutter_app`；
- Android 与 iOS 宿主工程；
- 固定的 Flutter SDK 配置；
- 路由、主题、依赖注入、日志、错误边界；
- 基础 State/Intent/Effect/ViewModel 模式；
- 空欢迎页和主框架。

建议默认标识，需用户最终确认：

```text
目录：flutter_app
显示名称：Legado Flutter
Android applicationId：io.legado.flutter
iOS Bundle Identifier：io.legado.flutter
Android minSdk：26
iOS Deployment Target：16.0
```

## 40. M2：核心数据层

第一批实体：

- `Book`；
- `BookSource`；
- `BookChapter`；
- `BookGroup`；
- `SearchBook`；
- `Bookmark`；
- `Cookie`；
- `Cache`；
- `ReplaceRule`；
- 核心配置模型。

按 Entity → DAO → Repository → UseCase 顺序实现。

## 41. M3：网络与普通规则

交付物：

- 统一 HTTP 客户端；
- Cookie 管理；
- 编码和压缩；
- 请求选项；
- JSONPath、XPath、选择器、Regex；
- 搜索、详情、目录、正文普通规则链路。

完成门禁：受控普通规则样本的关键结果与 Android 一致。

## 42. M4：JavaScript 兼容原型

交付物：

- `JsEngine` 抽象；
- 备选引擎对比结果；
- 脚本 Scope；
- Legado API 绑定；
- JavaCompatibilityBridge 初版；
- 超时、中断和错误模型；
- 真实书源兼容报告。

完成门禁：已证明同一架构可在 Android 和 iOS 实现，禁止只完成 Android Rhino 复用后继续扩张。

## 43. M5：书源管理

交付物：

- JSON/文本导入；
- 书源列表；
- 启用、停用、分组、编辑和删除；
- 基础调试信息；
- 登录/验证码入口（实际样本需要时）。

## 44. M6：搜索、详情与目录

交付物：

- 多书源搜索；
- 并发限制与取消；
- 搜索结果；
- 详情解析；
- 目录加载；
- 基础换源；
- 加入书架。

## 45. M7：书架

交付物：

- 列表和网格；
- 分组和排序；
- 更新目录；
- 未读状态；
- 选择模式；
- 删除；
- 阅读进度展示。

## 46. M8：文本阅读器

第一批交付物：

- 正文加载；
- 上下滚动；
- 上下章节；
- 目录跳转；
- 进度保存和恢复；
- 字号、行距、边距；
- 背景和文字颜色；
- 书签；
- 替换规则；
- 预加载；
- 错误重试；
- 屏幕常亮和系统栏处理。

## 46.1 M8.1：本地书籍导入与阅读

在 M8 与 M9 之间增加独立门禁阶段，完整范围见 `steps/M08_1_LOCAL_BOOK_IMPORT_AND_READING.md`。

固定目标：

- 系统文件选择和外部打开导入；
- TXT、EPUB、UMD、PDF、MOBI、AZW3、AZW；
- ZIP、RAR、7Z 安全容器导入；
- 元数据、封面、目录和稳定文件身份；
- 接入书架、文本阅读器和 PDF 页面阅读；
- 进度、书签、替换、删除和文件丢失恢复；
- Android 真机完成后才进入 M9。

## 47. M9：Android 第一批验收

固定验收路径：

```text
安装新 App
→ 导入真实书源
→ 搜索书籍
→ 打开详情
→ 加入书架
→ 打开目录
→ 阅读正文
→ 切换章节
→ 退出应用
→ 再次打开
→ 恢复书籍和阅读位置
```

所有步骤成功后，状态才可从 `ANDROID_READY` 更新为 Android 第一批可用。

## 48. M10：iOS 第一批适配

交付物：

- JavaScript 引擎 iOS 实现；
- WKWebView；
- 文件导入；
- iOS 网络/Cookie 适配；
- 相机二维码；
- Safe Area 和系统手势；
- 自用签名配置说明；
- iPhone 15 Pro Max、iOS 26 验收清单。

## 49. M11：后续完整功能迁移

建议顺序：

1. 换源和缓存下载。
2. 替换规则、书签和阅读记录。
3. 漫画阅读器。
4. 音频播放。
5. TTS/HTTP TTS。
6. RSS。
7. Web 服务。
8. 二维码、文件管理和分享。
9. 全部设置、主题和图标。
10. AI 功能。

每组仍按 Android 完成后再补齐 iOS，不得长期留下未登记的 Android-only 逻辑。

---

# 第九部分：验收、交付与变更控制

## 50. 功能验收模板

每个 Feature 必须填写：

```text
功能名称：
Android 对照入口：
Flutter 入口：
前置条件：
输入：
操作步骤：
预期状态变化：
预期数据变化：
预期副作用：
错误路径：
返回行为：
Android 结果：
iOS 结果：
已知差异：
```

## 51. AI 交付格式

每次代码交付必须说明：

1. 本次完成了什么。
2. 修改了哪些文件。
3. 新增了哪些文件。
4. 与 Android 哪些文件对应。
5. 哪些行为保持一致。
6. 哪些行为尚未实现或存在差异。
7. 用户应该运行哪些命令检查。
8. 用户应该如何人工验收。
9. 是否存在需要用户决定的问题。
10. 是否需要将新增文件执行 `git add`。

## 52. 用户运行的建议检查

AI 不执行，但可根据变更建议用户运行：

```bash
flutter pub get
flutter analyze
flutter test
flutter run
flutter build apk
flutter build ios --no-codesign
```

只建议与本次变更有关的最小命令，不要求用户每次运行全部命令。

## 53. 完成状态规则

一个功能只有同时满足以下条件才能标记完成：

1. 代码已实现。
2. 文件映射已登记。
3. 功能矩阵已更新。
4. 平台差异已记录。
5. 验收步骤已提供。
6. 用户已经确认或提供运行结果。
7. 没有把必要工作隐藏在未说明的 TODO 中。

在用户尚未运行检查时，AI 只能说明“代码已实现，等待用户验证”，不能宣称已经编译通过或测试通过。

## 54. 范围变更规则

1. 原 Android 项目基线冻结，不追踪未发生的新功能。
2. 用户提出新功能时，先判断它属于重写范围还是 Flutter 新功能。
3. 新功能不得破坏现有文件映射和兼容接口。
4. 修改数据格式、脚本 API 或平台通道属于架构变更，必须更新本文档或对应设计文档。
5. 临时实现如果会影响 iOS 路线，必须在 Android 开发阶段立即登记，不能留到 iOS 阶段才暴露。

---

# 第十部分：当前待用户确认项

创建 Flutter 工程前仍需最终确认：

1. Flutter 子目录是否使用 `flutter_app`。
2. 应用显示名称是否使用 `Legado Flutter`。
3. Android applicationId 是否使用 `io.legado.flutter`。
4. iOS Bundle Identifier 是否使用 `io.legado.flutter`。
5. 新应用图标是复用当前图标还是先使用占位图标。
6. 用于 JavaScript 兼容验收的常用书源样本如何提供。

在这些问题未确认前，可以继续做迁移盘点和技术原型设计，但不得把临时标识当成最终发布标识。

---

# 附录 A：首批功能映射检查表

## A.1 书源

- [ ] `BookSource` 实体映射。
- [ ] 书源 DAO。
- [ ] 书源 Repository/Gateway。
- [ ] JSON 导入。
- [ ] 书源启用/停用。
- [ ] 书源分组。
- [ ] 书源编辑。
- [ ] 书源删除。
- [ ] 登录和 Cookie。
- [ ] 调试错误展示。

## A.2 规则引擎

- [ ] `AnalyzeRule`。
- [ ] `AnalyzeUrl`。
- [ ] `AnalyzeByJSonPath`。
- [ ] `AnalyzeByXPath`。
- [ ] `AnalyzeByJSoup` 等价实现。
- [ ] `AnalyzeByRegex`。
- [ ] `RuleAnalyzer`。
- [ ] `CustomUrl`。
- [ ] JavaScript Scope。
- [ ] Legado 脚本 API。
- [ ] JavaCompatibilityBridge。
- [ ] WebView 请求。
- [ ] 超时和取消。
- [ ] 错误堆栈。

## A.3 搜索

- [ ] 搜索关键字历史。
- [ ] 单书源搜索。
- [ ] 多书源搜索。
- [ ] 并发限制。
- [ ] 取消搜索。
- [ ] 结果去重。
- [ ] 空状态。
- [ ] 错误状态。
- [ ] 打开详情。

## A.4 书架

- [ ] `Book`。
- [ ] `BookGroup`。
- [ ] 书架 DAO。
- [ ] 列表模式。
- [ ] 网格模式。
- [ ] 分组。
- [ ] 排序。
- [ ] 目录更新。
- [ ] 选择模式。
- [ ] 删除。
- [ ] 阅读进度。

## A.5 阅读器

- [ ] `BookChapter`。
- [ ] 正文缓存。
- [ ] 章节加载。
- [ ] 上一章/下一章。
- [ ] 目录跳转。
- [ ] 上下滚动。
- [ ] 进度保存。
- [ ] 进度恢复。
- [ ] 字体设置。
- [ ] 行距和边距。
- [ ] 日间/夜间颜色。
- [ ] 替换规则。
- [ ] 书签。
- [ ] 预加载。
- [ ] 错误重试。
- [ ] 横竖屏恢复。

---

# 附录 B：AI 开始编码前的简短自检

```text
[ ] 我已经完整阅读本文件。
[ ] 我明确了本次唯一目标和不包含内容。
[ ] 我已经检查对应 Android 实现及其关联文件。
[ ] 我已经列出需要保持的行为。
[ ] 我已经确定文件、类和方法映射。
[ ] 我已经确定纯 Dart 或平台桥接边界。
[ ] 我没有使用 Kotlin !! 或 Dart 强制空值断言 !。
[ ] 我为新增类、方法和变量写了详细中文注释。
[ ] 我只修改了任务范围内的文件。
[ ] 我没有运行构建、测试或代码检查。
[ ] 我准备了用户可执行的验收步骤。
[ ] 如果新增文件，我会询问用户是否执行 git add。
```
