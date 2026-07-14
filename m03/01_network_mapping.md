# M3 网络行为映射

## Android 到 Flutter

| 行为 | Android 事实 | Flutter M3 实现 | 当前差异 |
|---|---|---|---|
| 默认超时 | connect/write 15 秒，read/call 60 秒 | connect/send 15 秒，receive/total 60 秒 | 用户检查后确认 Dio 平台实际行为 |
| 响应正文 | 先保留字节再按字符集转换 | `HttpResponse.bytes` 后交给 `HttpResponseDecoder` | 无已知设计差异 |
| 字符集优先级 | URL 规则、Content-Type、文档声明、检测 | 相同；严格 UTF-8 失败后回退 GBK | Android 的统计编码检测覆盖面更广 |
| 压缩 | OkHttp Content-Encoding；ZIP 取首文件 | gzip、deflate、ZIP 首文件 | 用户样本待验证 |
| 重定向 | 默认跟随，最终 URL 参与相对地址解析 | 默认跟随，保存 `finalUri` | 用户样本待验证 |
| Cookie | 按域持久 Cookie + 内存会话，同名覆盖 | 相同数据语义，支持共享/禁用/独立会话 | Path、SameSite 等信息与 Android 旧表一样不持久化 |
| Header | 书源 Header 与 URL 选项集中合并 | `SourceUrlResolver` 集中合并 | 含 JS 的 Header 进入 M4 |
| GET/POST | GET query；POST 表单或原始 JSON/XML | 统一请求体模型与 Dio 转换 | `charset=escape` 等特殊编码待兼容样本确认 |
| 重试 | URL 选项 `retry` | DNS、连接和超时错误有限重试 | 不重试取消、解析、HTTP 状态 |
| 错误 | 取消、DNS、连接、TLS、超时等可区分 | `HttpFailureKind` 明确分类 | 各平台 Socket 错误码需真机确认 |
| WebView | 受控介入 | 只定义 Cookie 桥并明确抛出未支持 | 进入 M4 |
| DNS/代理 | Android 可按书源定制 | 明确抛出未支持 | 需后续平台设计，不做伪实现 |

## URL 普通语法

- 支持 URL 后 `, { ... }` JSON 选项。
- 支持 `method`、`charset`、`headers`、`body`、`retry`。
- 支持 `<第一页,第二页,后续页>`；页码超出候选数时重复最后一项。
- 支持普通内建变量 `{{key}}` 与 `{{page}}`。
- 检测到其他 `{{...}}`、`@js:`、`<js>`、`webView`、`webJs`、`js`、`bodyJs`、`dnsIp` 或 `serverID` 时明确失败。

## 安全边界

网络实现没有安装 Dio 日志拦截器，不记录 Cookie、Authorization、请求正文或响应正文。异常消息只包含分类和安全说明。

