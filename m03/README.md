# M3 实施记录：网络与普通规则

状态：`IN_PROGRESS / 实现待用户验证`

本阶段已经落地统一 HTTP 契约、Dio 实现、Cookie 管理、字符集与压缩解码、普通规则引擎，以及搜索、详情、目录、正文四段编排入口。当前没有运行 `pub get`、`analyze`、`test`、`build` 或真实网络请求，因此不能标记为 `ANDROID_READY`。

## 已实现范围

- HTTP 请求、响应、请求体、取消令牌和错误分类。
- 原始响应字节、最终重定向 URL、统一 Header 与 Cookie 处理。
- 规则指定字符集、Content-Type、HTML/XML 声明、UTF-8/GBK 回退。
- gzip、deflate 与 `application/zip` 首个文件解压。
- JSONPath、XPath、CSS、Regex、字符串替换与 `&&`、`||`、`%%` 常用组合。
- 搜索、详情、分页目录、分页正文解析入口。
- 四段 DOM/JSON/Regex 解析整体运行在后台 isolate。
- JavaScript、WebView、自定义 DNS 等未实现能力会明确失败。

## 明确不在 M3 的范围

- 任意 `{{ JavaScript }}`、`@js:` 与 `<js>` 表达式。
- `webView`、`webJs`、`bodyJs`、登录检查与 Cookie 的 WebView 平台同步。
- 自定义 DNS、代理和服务端选择。
- JSoup 与 Dart HTML 选择器所有边角语法的无条件等价声明。
- 跨书源并发限流；M3 仅提供取消与单书源分页编排。

上述项目分别进入 M4 或后续业务阶段。普通 URL 中只兼容无需求值的 `{{key}}`、`{{page}}` 两个内建变量，其余内嵌表达式会进入“不支持”错误。

## 用户验证前门禁

用户需先执行依赖获取和静态检查，再运行固定样本与至少一套真实普通书源的四段链路。结果未确认前，M3 保持 `IN_PROGRESS`。

