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
| S2 | `samples/s2_101kanshu_standard_js.json` | 搜索“斗破苍穹”，完全匹配结果，第一章免费正文 | 标准 JS、`key`、四段链路 | PENDING |
| S3 | `samples/s3_fanqie_jslib.json` | 搜索“斗破苍穹”，完全匹配结果，第一章免费正文 | `jsLib`、`result/baseUrl/cache` | PENDING；内存缓存 API 预计阻塞 |
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

1. S2～S5 尚未产生 Android Legado、Flutter Android 和 Flutter iOS 的实际结果。
2. 如果样本使用同步 `java.ajax/connect`，需决定：实现安全的同步宿主通道、受控源码转换，或明确该书源不兼容。不能直接返回 Promise 后宣称通过。
3. 需要 Android 与 iOS 真机分别执行相同样本。
