# M4 兼容报告

状态：用户已确认合集中的代表样本；完整 JSON 已准备，等待 Android Legado、Flutter Android 和 Flutter iOS 执行结果。样本见 `05_collection_validation_samples.md`。

## 仓库扫描证据（非验收）

| 书源 | 证据位置 | 调用 | 原型判断 |
|---|---|---|---|
| 消消乐听书 | `app/src/main/assets/defaultData/bookSources.json` | `java.connect`、`java.md5Encode`、`java.put/get`、登录 Header、模型 getter | 工具和 DTO 可映射；同步 `connect(...).body()` 被异步 Promise 阻断 |
| 默认封面规则 | `app/src/main/assets/defaultData/coverRule.json` | `java.ajaxAll`、Base64、Hex | 编解码可补齐；并发网络与同步返回待设计 |
| 默认词典规则 | `app/src/main/assets/defaultData/dictRules.json` | `org.jsoup.Jsoup.parse` | 不允许直接暴露 Java Jsoup；应改用 Dart 规则/HTML DTO 或白名单桥 |
| 默认 HTTP TTS | `app/src/main/assets/defaultData/httpTTS.json` | `android.util.Base64`、`java.net.URLEncoder`、`java.lang.String`、网络 helper | Base64/URLEncoder 已有原型；String 构造和完整 TTS 不属于首批书源闭环 |

这些文件没有由用户确认，且网站结果可能变化，所以不能作为 M4 退出样本。

## 已确认核心样本

| 编号 | 完整文件 | 固定输入 | 主要门禁 | 当前结论 |
|---|---|---|---|---|
| S2 | `samples/s2_101kanshu_standard_js.json` | 搜索“斗破苍穹”，完全匹配结果，第一章免费正文 | 标准 JS、`key/page`、四段链路 | IMPLEMENTED_PENDING_DEVICE；已接入 JS URL 与混合规则执行链路 |
| S3 | `samples/s3_fanqie_jslib.json` | 搜索“斗破苍穹”，完全匹配结果，第一章免费正文 | `jsLib`、`result/baseUrl/src/cache` | IMPLEMENTED_PENDING_DEVICE；已接入内嵌普通规则与书源隔离内存缓存 |
| S4 | `samples/s4_deqixs_java_ajax.json` | 搜索“斗破苍穹”，完全匹配结果，第一章免费正文 | `java.ajax` 同步网络语义 | PENDING；Promise 差异预计阻塞 |
| S5 | `samples/s5_remexs_rhino_java.json` | 搜索“斗破苍穹”，完全匹配结果，进入目录 | `Packages.org.jsoup.Jsoup`、WebView | PENDING；应明确报告不支持调用 |

## 每个样本结果字段

| 字段 | 必须记录的内容 |
|---|---|
| Android Legado 搜索 | 结果数量、完全匹配书名、作者、bookUrl |
| Flutter Android/iOS 搜索 | 与 Android 相同字段或具体错误 |
| 详情 | 名称、作者、封面、tocUrl、简介长度 |
| 目录 | 章节数量、首章、末章、VIP/卷标记 |
| 正文 | 第一章正文长度、首尾脱敏摘要、分页数 |
| 脚本 API | 实际进入的方法、参数类型、同步/异步行为 |
| Java/Rhino API | 类名、方法名、支持结果或拒绝原因 |
| 资源行为 | 超时、中断、峰值和关闭后是否释放 |
| 最终结论 | PASS / DIFFERENCE / BLOCKED |

## 当前阻塞项

1. S2～S5 尚未产生 Android Legado、Flutter Android 和 Flutter iOS 的实际结果；S2、S3 目前只是代码路径完成，不能替代真机证据。
2. 如果样本使用同步 `java.ajax/connect`，需决定：实现安全的同步宿主通道、受控源码转换，或明确该书源不兼容。不能直接返回 Promise 后宣称通过。
3. 需要 Android 与 iOS 真机分别执行相同样本。

## 2026-07-16 诊断推进

- 用户 Android 实机搜索中，S2 `101看书` 与 S3 `🍅番茄小说源` 已分别返回 12 和 20 条搜索结果，证明核心 URL JavaScript、`jsLib` 与混合字段链路可执行；详情、目录、正文和 iOS 证据仍待补齐。
- 新增宿主桥方法名与参数类型轨迹，用于区分 `TypeError: not a function` 是缺失代理方法、同步 Rhino API 还是返回对象形状差异。
- Android 已确认的 `UrlOption.js/bodyJs` 顺序已实现，尚待用户重新构建验证。
- 顶层 `return` 仅在 QuickJS 返回对应语法错误时使用函数包装重试，尚待用户重新构建验证。
- 最新完整调度结果为 95 个书源中 46 个执行成功、49 个失败并合并 791 组结果；附件从第 41 个完成项开始，后半段可见失败中有 20 个外部网络问题、8 个 JavaScript 问题、3 个 URL 选项问题和 1 个格式问题，不能把全部失败归因于 JavaScript。
- 宿主桥轨迹确认历史 `java.ajax` 同步返回差异仍会导致 Promise 对象方法失败；该门禁未绕过。
- 宿主桥异常已改为结构化传播，避免未支持 API 被 JSF 当业务对象后继续形成 `TypeError` 或无效 URL，等待用户重新构建验证。
- 2026-07-16 实机日志证明结构化桥接已能把 `createSymmetricCrypto`、`toast`、`androidId`、`longToast` 分类为 `unsupportedApi` 并保留桥调用轨迹；同次日志也暴露 URL 残留诊断曾把 `{{key}}/{{page}}` 内建占位符误判为 JavaScript，现已改为复用真实 URL 脚本判定并等待用户重新运行验证。
- `source.getVariable/putVariable` 已接入独立缓存和书源编辑入口；需要自定义 JSON 变量的书源可由用户显式配置，等待真机验证。
- `org.jsoup.Jsoup` 已接入跨平台只读白名单；对称加密对象仍因缺少经过评估的 AES/DES 依赖保持阻塞。
