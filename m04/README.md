# M4 实施记录：JavaScript 兼容原型

状态：`BLOCKED / 原型与真实书源样本已准备，等待双平台执行结果`

本阶段已经落地引擎无关 `JsEngine`、JSF/QuickJS 适配器、按书源隔离的实例池、Legado API 桥、Java 白名单桥、WebView 边界以及超时、取消、内存和资源释放策略。

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
- WebView 与纯 JavaScript 引擎分离，当前平台实现明确未支持。

## 尚未证明

- JSF 原生库在本项目 Android ABI、R8 和 iOS 真机上的构建结果。
- 取消监听是否能在所有平台立即触发 QuickJS interrupt handler。
- JSF 1.1.0 的最终 APK/IPA 增量和内存峰值。
- Rhino Date、Regex、数字、getter/setter 与异常堆栈的全部兼容差异。
- 同步网络历史脚本的跨平台解决方案。
- 任意 `Packages.*`、JavaImporter、JavaAdapter、Android API 或 Java 反射。
