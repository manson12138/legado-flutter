# M10 iOS 能力盘点与平台差异

## 第一批能力

| 能力 | 当前实现 | iOS 行为 | 释放/恢复 | 状态 |
|---|---|---|---|---|
| JS 引擎 | Dart `JsEngine` + JSF/QuickJS | 与 Android 使用同一接口、Scope、值转换、错误、超时和中断 | 引擎租约失败时关闭；真机 ABI/内存待验 | 实现待验证 |
| Java 兼容桥 | Dart 白名单 | 返回与 Android 相同 DTO；任意 JVM/反射明确 unsupported | 无原生 JVM 状态 | 部分实现 |
| 登录 WebView | `BookSourceLoginRoute` + `webview_flutter` | iOS 使用 WKWebView；只允许 HTTP/HTTPS/about/data 页面内导航 | 退出时替换 Delegate、载入空白页；后台先同步 Cookie | 实现待验证 |
| 页面脚本 WebView | `FlutterWebViewScriptBridge` | 每次请求创建独立 WKWebView，返回脚本结果或 DOM | 超时/取消唤醒等待，最终解除 Delegate 和页面引用 | 实现待验证 |
| Cookie | `LegadoCookieManager` + `FlutterWebViewCookieBridge` | 统一数据库与 WKHTTPCookieStore 按域双向同步；不记录内容 | 登录完成/后台/内存警告回写 | 实现待验证 |
| 书源文件 | `file_picker` 内存字节 | Document Picker 结果不保存外部 URL | 解码后只保留书源数据 | 实现待验证 |
| 本地书文件 | `file_picker` + `LocalBookStorage.persist` | Picker 结果立即复制到应用私有目录 | 只保存相对路径与指纹；失败补偿清理 | 实现待验证 |
| 二维码 | `mobile_scanner` | 使用相机权限和 iOS 原生采集 | inactive 停止、resumed 恢复、dispose 释放 Controller | 实现待验证 |
| 相机拒绝 | 扫码错误页 | 提示到系统设置授权，或返回使用剪贴板导入 | 不保留无响应入口 | 已接入 |
| Safe Area | `AppScaffold`/页面 `SafeArea` | 避开灵动岛、圆角和 Home Indicator | 尺寸变化由 Flutter 重布局 | 实现待验证 |
| 阅读位置 | 稳定章节 + 字符锚点 / PDF 页码 | 旋转和尺寸变化重新投影字符锚点；PDF 保留页码 | 后台、退出保存 | 实现待验证 |
| 屏幕常亮 | `reader_platform` MethodChannel | `UIApplication.isIdleTimerDisabled` | 后台临时关闭，前台恢复请求值，退出恢复原值 | 实现待验证 |
| 本地网络 | Info.plist 用途说明与 ATS local networking | 用户配置局域网书源时触发系统权限 | Release 同一用途说明；不含 Debug 专属代理信任 | 实现待验证 |

## 网络与 ATS 决策

- 普通互联网书源默认要求 HTTPS。
- `NSAllowsArbitraryLoadsInWebContent` 只允许受控 WKWebView 加载必要页面，不等于全局放开 Dart HTTP。
- `NSAllowsLocalNetworking` 只服务用户主动配置的局域网地址。
- 未配置具体域例外的外部明文 HTTP 书源可能被 iOS 拒绝；第一批必须显示网络错误，不伪装为空结果。
- 不提交通配域 ATS 例外。若用户确认某个固定 HTTP 书源为核心样本，再按域添加最小例外并更新本表。

## 前台与后台边界

- 第一批搜索、详情、目录、正文和脚本执行以前台为主。
- 不在 Swift 新建后台书源、搜索、缓存或阅读状态机。
- iOS 没有 Android 前台 Service 等价物；长时间后台缓存、Web 服务和下载保持后续或 unsupported。
- App 后台时阅读器保存稳定进度，登录页保存 Cookie，相机停止采集；回前台由现有 Dart 页面状态恢复。

## 明确 unsupported / 后续

| Android 能力 | iOS 第一批结论 |
|---|---|
| 任意 JVM 类、Java 反射、Android API | `JavaCompatibilityBridge` 白名单外明确 unsupported |
| 安装 APK | iOS 不适用，不提供入口 |
| Android 前台 Service / BroadcastReceiver | 无直接等价，首批不提供后台业务入口 |
| 任意外部存储路径长期访问 | 不支持；必须复制到应用沙盒 |
| 无限期后台 Web 服务/下载 | 首批不支持，避免无响应入口 |
| 通配明文 HTTP | 不全局放开；HTTPS、局域网或按域例外 |
