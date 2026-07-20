# M4 脚本 API 清单

## 三层分类

| 层级 | Android 事实 | M4 原型策略 | 状态 |
|---|---|---|---|
| 标准 JavaScript | Rhino 1.8.0 语法、JSON、Regex、Date、数组和对象 | JSF/QuickJS；双平台使用同类原生引擎 | 实现待样本验证 |
| Legado API | `java`、`source`、`book`、`chapter`、`result`、`cookie`、`cache` 等 | Dart DTO、Proxy 与白名单回调 | 原型实现 |
| Rhino/Java API | `Packages.*`、Java.type、JavaImporter、JavaAdapter、Android/Java 类 | 仅固定类名与方法白名单 | 部分实现，其余明确失败 |

## Android 注入变量

Android 真实调用点出现以下变量：

- `java`、`baseUrl`、`result`、`source`、`book`、`chapter`。
- `cookie`、`cache`、`key`、`page`、`title`、`src`、`nextChapterUrl`。
- 其他 Feature 专属变量：`rssArticle`、`infoMap`、`speakText`、`speakSpeed`、`index`、`gInt`、`epubIndex` 等。

M4 第一批只注入书源核心闭环需要的变量。遇到未注入变量时 QuickJS 会产生 ReferenceError，不会静默返回 `null`。

## Legado API 原型

| 表面 | 已实现 | 当前限制 |
|---|---|---|
| `java` 工具 | MD5、Base64、Hex、URI 编解码、UUID、`put/get` | 加密 Cipher、文件、繁简、HTML 工具待真实样本决定 |
| `java` 网络 | `ajax`、`connect`、`get`、`head`、`post` | 返回 Promise；同步 Rhino 脚本不透明兼容 |
| `source` | 常见字段 getter、变量、登录 Header/Info 的当前上下文读写 | 尚未把登录信息持久化回书源记录 |
| `book/chapter` | 字段属性、Java 风格 getter、变量 Map 读取 | 只读 DTO；setter 和复杂方法未实现 |
| `result` | 字段以及 `body()`、`url()`、`statusCode()`、`headers()`、`header()` | 仅统一响应 DTO |
| `cookie` | get/set/replace | 复用 M3 Cookie；M10 已接统一 WebView Cookie，待双端真机验证 |
| `cache` | get/put/delete、秒级有效期 | 复用 M2 `CacheDao` |
| WebView | Flutter 官方 Android WebView/WKWebView、请求/响应 DTO、超时、取消和关闭 | 已接代码；S7 双端真机结果待验证 |

## Java/Rhino 白名单

当前支持：

- `java.net.URLEncoder.encode`
- `android.util.Base64.encodeToString/decode`
- Legado helper 的 MD5、Base64、Hex、URI 与 UUID 方法

明确不支持：

- 任意 `Packages.java.*`、反射和文件系统类。
- `JavaImporter`、`importClass`、`importPackage`、`JavaAdapter`。
- `org.jsoup.Jsoup.parse` Java 对象链。
- 未登记的 Android 类、项目 Kotlin 类和第三方库类。

新增白名单前必须记录真实书源、调用签名、双平台实现和安全影响。
