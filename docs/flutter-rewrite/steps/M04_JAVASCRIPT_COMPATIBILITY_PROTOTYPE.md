# M4：JavaScript 兼容原型

> 当前状态：`BLOCKED / 原型与真实书源样本已准备，等待 Android/iOS 执行结果`。详见 `../m04/README.md`。

## AI 执行规则（必须先读）

1. 必须阅读总方案及 M0～M3 文档，并确认网络、Cookie 和数据接口可复用。
2. 本阶段是项目最高风险门禁；没有证明 iOS 可实现前，不得只复用 Android Rhino 后宣布成功。
3. 必须使用用户提供或确认的真实书源样本验证，不能只运行 `1 + 1` 示例。
4. JavaScript 兼容必须区分标准语法、Legado API 和 Rhino/Java API 三层。
5. iOS 无 JVM，不得承诺任意 `java.*` 类均可原样运行；应建立明确兼容桥和错误报告。
6. Dart 负责业务接口和兼容语义，Kotlin/Swift/FFI 只负责引擎与平台能力。
7. 所有脚本执行必须有超时、中断、资源释放和敏感信息保护。
8. AI 不运行脚本测试、构建或检查；由用户执行并提供结果。

## 阶段目标

选定能在 Android/iOS 落地的 JavaScript 方案，并证明真实 Legado JavaScript 书源可通过统一接口完成核心解析。

## 前置输入

- 普通规则与 HTTP 层可用。
- 至少一组用户常用书源样本。
- 样本覆盖搜索、详情、目录、正文和常见 Java/Rhino 调用。
- 敏感登录信息通过本地、不提交仓库的方式提供。

## 执行步骤

### 1. 扫描现有脚本 API

- 盘点 Rhino Scope、NativeBaseSource、ReadOnlyJavaObject 和注入变量。
- 盘点 `source`、`book`、`chapter`、`result`、网络、Cookie、缓存和工具 API。
- 收集脚本对 `java.*`、Android 类和项目工具类的调用。

### 2. 定义 `JsEngine`

- 创建引擎生命周期、Scope、编译脚本和执行脚本抽象。
- 定义同步值、Future、列表、Map、二进制和错误的桥接规则。
- 定义超时、取消、关闭、实例池和隔离策略。
- 不把具体引擎类型暴露给规则业务层。

### 3. 引擎候选对比

- 对比 Android/iOS 一致性、ECMAScript 支持、对象绑定、异步、超时、错误栈、内存、包体积、许可证和维护状态。
- 优先同一引擎跨平台，避免两个引擎产生不可控语义差异。
- 如果必须使用不同引擎，列出差异测试和兼容补丁责任。

### 4. Legado API 兼容层

- 用 Dart 定义脚本可见 API 和 DTO。
- 方法名、参数、返回类型、空值和异常尽量对应 Android。
- 网络请求必须复用 M3 网络层。
- Cookie 必须复用统一 Cookie 存储。

### 5. `JavaCompatibilityBridge`

- 建立类名、方法名到 Dart/平台实现的白名单映射。
- 记录每个映射来自哪些真实书源。
- Android 和 iOS 对外返回结构保持一致。
- 未支持调用抛出可诊断错误，不得静默返回 `null`。

### 6. WebView 边界

- 定义脚本请求何时需要 WebView。
- JavaScript 引擎与页面 WebView 分离，不共享隐式全局状态。
- 定义 Cookie 同步、超时、页面关闭和脚本结果提取。

### 7. 兼容报告

- 每个样本记录书源、功能、脚本 API、Android 结果、Flutter Android 结果、iOS 可实现性和差异。
- 失败必须记录具体类、方法、脚本位置和解决计划。

## 注意点

- Rhino 对 Java 对象属性访问可能自动映射 getter/setter，其他引擎不会自然复现。
- JavaScript `undefined`、`null`、Dart `null` 和字段缺失必须区分。
- Date、Regex、Map 顺序、数字精度和异常堆栈可能跨引擎不同。
- 脚本无限循环和超大内存必须可终止。
- 引擎实例不得跨不可信书源共享可变 Scope，避免数据泄漏。
- 自用安装降低分发约束，但不能降低运行时安全和稳定性要求。

## 交付物

- [x] 脚本 API 清单。
- [x] Java/Rhino 调用清单。
- [x] `JsEngine` 设计。
- [x] 引擎候选对比与决策记录。
- [x] Legado API 兼容层原型。
- [x] `JavaCompatibilityBridge` 原型。
- [x] WebView 边界设计。
- [x] 超时、取消和资源释放方案。
- [ ] 真实书源兼容报告。

## 完成标准

1. 选定方案有 Android 与 iOS 明确实现路径。
2. 至少一组 JavaScript 书源完成搜索、详情、目录和正文全链路。
3. 至少一个使用 Legado 注入对象的脚本通过。
4. 至少一个 Java/Rhino 调用被识别并通过兼容桥或明确判定不可直接支持。
5. 超时、无限循环、脚本异常和资源关闭具有明确行为。
6. 失败信息足以定位书源、脚本和 API。
7. 用户运行样本并确认结果；没有用户结果时只能标记原型实现待验证。

## 阶段退出门禁

- 不允许方案只在 Android JVM/Rhino 上成立。
- 不允许网络、Cookie 再造第二套实现。
- 不允许存在“以后再考虑 iOS”的核心引擎依赖。
- M5～M8 可以稳定依赖当前脚本接口，不需知道引擎类型。

## 最终自检

- [x] 我盘点了标准 JS、Legado API、Rhino/Java API 三层。
- [x] 引擎方案同时考虑 Android 和 iOS。
- [x] 真实书源已完成四段链路验证设计，实际结果待用户执行。
- [x] 未支持 Java 调用不会静默返回空值。
- [x] 脚本有超时、中断、隔离和关闭。
- [x] Cookie 和网络复用 M3。
- [x] 错误报告不主动包含账号、Cookie 和正文隐私。
- [x] 新增符号有中文注释且无强制空值断言。
- [x] 我没有运行脚本测试或构建。
- [x] 我提供了用户验证步骤；是否 `git add` 由用户明确决定。
