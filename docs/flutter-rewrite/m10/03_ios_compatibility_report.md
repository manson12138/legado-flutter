# M10 iOS 兼容样本报告

状态只允许填写：`NOT_STARTED`、`PASS`、`FAIL`、`BLOCKED`、`NOT_APPLICABLE`。

## JavaScript 与 WebView

| 样本 | 覆盖能力 | Android 已知状态 | iOS 预期 | iOS 实际 | 状态 |
|---|---|---|---|---|---|
| S1 | 普通规则四段 | 主要逻辑冒烟，完整记录缺失 | 不进入 JS；搜索、详情、目录、正文一致 | 待填写 | NOT_STARTED |
| S2 | 标准 JS URL/字段 | 无正式四段记录 | 同一 JSF Scope 与值转换 | 待填写 | BLOCKED |
| S3 | `jsLib`、cache、混合规则 | 无正式四段记录 | 同一 Dart cache/HTTP/Cookie 与 JSF | 待填写 | BLOCKED |
| S4 | 同步 `java.ajax/connect` | Promise 与 Rhino 同步语义冲突 | 必须明确失败，不得假成功 | 待填写 | BLOCKED |
| S5 | `Packages.*`/Rhino 类 | 白名单外明确 unsupported | 返回同结构 unsupported 错误 | 待填写 | BLOCKED |
| S6 | 登录信息/Cookie | 统一 Cookie 已有 Dart 边界 | WKWebView 登录后 HTTP 可读取同域 Cookie | 待填写 | NOT_STARTED |
| S7 | `java.webView` 页面脚本 | 页面桥已接入；同步 Rhino 调用仍有 Promise 风险 | WKWebView 返回 DOM/脚本值，或明确记录同步语义不兼容 | 待填写 | BLOCKED |
| S8 | 脱敏 Cookie Header | 不得记录真实值 | Header、WKWebView、HTTP 同步且日志脱敏 | 待填写 | NOT_STARTED |

## 平台行为样本

| 编号 | 操作 | 预期 | 实际 | 状态 |
|---|---|---|---|---|
| I01 | Document Picker 导入书源 JSON | 取消无副作用；成功进入确认流程 | 待填写 | NOT_STARTED |
| I02 | 导入 TXT/EPUB/UMD/PDF 后撤销原文件访问 | 应用私有副本仍可重开 | 待填写 | NOT_STARTED |
| I03 | 拒绝相机权限 | 显示设置说明与剪贴板替代，无无响应入口 | 待填写 | NOT_STARTED |
| I04 | WKWebView 登录、重定向、关闭 | Cookie 回写统一 Store；再次请求携带同域 Cookie | 待填写 | NOT_STARTED |
| I05 | 登录页进入后台再回来 | 页面可继续或可刷新；Cookie 不丢失 | 待填写 | NOT_STARTED |
| I06 | 阅读旋转/尺寸变化 | 章节不变，恢复接近原字符锚点 | 待填写 | NOT_STARTED |
| I07 | 阅读进入后台再回来 | 进度保存，系统栏与常亮恢复 | 待填写 | NOT_STARTED |
| I08 | WKWebView 网页进程被系统回收/内存警告 | Cookie 已保存，页面可刷新，不崩溃 | 待填写 | NOT_STARTED |
| I09 | 外部明文 HTTP 书源 | 被 ATS 拒绝时显示网络错误，不为空结果 | 待填写 | NOT_STARTED |
| I10 | 局域网书源 | 权限说明准确；允许后以前台方式访问 | 待填写 | NOT_STARTED |

任何 iOS 结果都必须使用与 Android 相同的输入和期望字段。失败记录功能、样本、步骤、预期、实际和脱敏错误；不得记录 Cookie、账号、正文或私有文件路径。
