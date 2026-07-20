# M4 实施记录：JavaScript 兼容原型

状态：`BLOCKED / 原型与真实书源样本已准备，等待双平台执行结果`

本阶段已经落地引擎无关 `JsEngine`、JSF/QuickJS 适配器、按书源隔离的实例池、Legado API 桥、Java 白名单桥、WebView 边界以及超时、取消、内存和资源释放策略。

搜索、详情、目录和正文四段现已接入普通规则与 JavaScript 顺序串联执行器：URL/Header 的 `@js:`、`<js>`、`{{...}}` 会在请求解析前执行，字段规则可按 Android `AnalyzeRule` 语义把普通选择器结果继续交给脚本；纯普通规则仍保留 isolate 快路径。搜索、详情和阅读入口已移除 `javascriptPending` 预拦截。该代码尚未由用户运行，不能据此把阶段改为 `ANDROID_READY`。

用户提供的 100 个书源合集已经按兼容类型提取为校验样本，详见 `05_collection_validation_samples.md`。样本覆盖普通规则、标准 JavaScript、`jsLib`、Legado `java.*`、Rhino/Java 类、登录、WebView 和 Cookie；原合集中的真实 Cookie 没有复制进文档。S2～S5 已进一步提取为 `samples/` 下的完整可导入 JSON，并固定首轮关键词“斗破苍穹”。

M4 不能进入 `ANDROID_READY`，原因有两项：

1. 用户已经确认使用合集中的代表书源，但尚未完成搜索、详情、目录、正文四段真机对照。
2. Android Rhino 的 `java.ajax/connect/get/post` 是同步调用；Dart 统一网络层是异步调用，JSF 桥会返回 Promise。未使用 `await` 的历史脚本会出现可诊断失败，不能宣称透明兼容。

仓库自带“消消乐听书”只能作为 API 扫描证据，不能替代用户确认样本。它使用同步 `java.connect(...).body()`、登录 Header 与模型 getter，当前原型能识别相关 API，但同步网络语义仍不兼容。

## 已实现

- `undefined`、`null` 和数组空洞的独立契约。
- 脚本、编译句柄、运行时、Scope、取消和关闭抽象。
- 默认 64 MiB 内存、1 MiB 栈、5 秒原生 QuickJS 中断超时。
- 不同书源永不共享可变 Scope；同书源最多保留一个空闲实例。
- `source`、`book`、`chapter`、`result`、`baseUrl`、`key`、`page` 等 DTO 注入。
- `java`、`cookie`、`cache`、`Java.type` 代理。
- 网络、Cookie 和缓存分别复用 M3/M2，未创建第二套存储或网络栈。
- MD5、Base64、Hex、URI、UUID 及少量 Java 类白名单。
- 未支持 API 抛出带表面、类名和方法名的错误，不返回伪造空值。
- WebView 与纯 JavaScript 引擎分离；M10 已用 Flutter 官方 WebView 接入 Android/iOS 页面脚本、超时、取消、结果回传和统一 Cookie，同一套代码仍待双端真机样本验证。
- S2 标准 JavaScript URL 与 S3 `jsLib`/混合字段规则已建立四段真实调用路径，包含 `src` 注入和按书源隔离的 `cache.putMemory/getFromMemory`。
- `Packages.*` 现在进入 Java 白名单桥并报告具体类和方法，不再只产生无法定位的全局变量缺失。
- Android `UrlOption.js` 已按“请求前、绝对 URL 作为 `result`”接入，`bodyJs` 已按“响应解码后、正文作为 `result`”接入；WebView 选项由独立受控页面桥执行，不混入 QuickJS Scope。
- QuickJS 明确报告顶层 `return` 时，会使用函数作用域做一次 Rhino 兼容重试；其他语法错误不会进行猜测性改写。
- `FLUTTER_JS_COMPAT_LOG` 会记录脱敏后的 QuickJS 摘要，以及宿主桥方法名和参数类型轨迹；不记录脚本、参数值、正文、Header 或 Cookie。
- 可选字段告警按“字段 + 原因”去重，避免同一搜索列表逐项重复输出。
- JSF 宿主函数统一返回结构化成功/失败信封，Dart `unsupportedApi/bridge` 不再被当作普通对象或 URL 文本继续执行。
- `source.getVariable/putVariable` 复用 Flutter 独立缓存，并在书源编辑器提供自定义变量入口；脚本开始前预载变量以保持同步 getter 语义。
- `Packages.org.jsoup.Jsoup` 与直接 `org.jsoup.Jsoup` 已建立跨平台只读白名单，覆盖 `parse/select/size/get/first/last/attr/text/html`；需要可变 DOM 的 `remove` 仍明确不支持。

## 尚未证明

- JSF 原生库在本项目 Android ABI、R8 和 iOS 真机上的构建结果。
- 取消监听是否能在所有平台立即触发 QuickJS interrupt handler。
- JSF 1.1.0 的最终 APK/IPA 增量和内存峰值。
- Rhino Date、Regex、数字、getter/setter 与异常堆栈的全部兼容差异。
- 同步网络历史脚本的跨平台解决方案。
- 任意 `Packages.*`、JavaImporter、JavaAdapter、Android API 或 Java 反射；当前 Jsoup 仅是固定只读白名单。
- `java.createSymmetricCrypto` 需要新增经过评估的跨平台 AES/DES 依赖，当前不能用哈希库或伪对象替代。
- M10 WebView/Cookie 实现尚无 S6～S8 的 Android/iOS 真机结果，不能据此关闭 M4。
- 历史脚本同步调用 `java.webView` 时仍可能观察到 Promise；页面桥实现不等于 Rhino 同步调用已透明兼容。
