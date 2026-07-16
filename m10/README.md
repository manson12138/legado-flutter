# M10 实施记录：iOS 第一批适配

状态：`IN_PROGRESS / iOS 平台代码已接入，等待依赖解析、Xcode、真机与兼容样本验证；M9/M4 门禁未关闭`

## 本次实现

- 继续复用同一 Dart 数据层、规则层、书源、搜索、书架、本地书和阅读状态机，没有新增 iOS 业务副本。
- 引入 Flutter 官方 `webview_flutter 4.14.1`；Android 使用系统 WebView，iOS 使用 WKWebView，最低 Flutter/Dart 要求与项目固定版本兼容。
- 新增 `FlutterWebViewCookieBridge`，在统一 Dart Cookie Store 与平台 WebView Cookie Store 之间按域双向同步。
- 新增书源登录 WebView 路由；进入前写入统一 Cookie，完成、后台和内存警告时回写 Cookie。
- `java.webView` 页面请求接入 `FlutterWebViewScriptBridge`，具备独立页面、超时、取消、结果回传和 Delegate/页面释放。
- 本地书继续通过 Document Picker 选择后立即复制到应用私有目录，只持久化相对路径和 SHA-256 身份。
- 二维码继续使用 `mobile_scanner`；iOS 权限拒绝页明确提示系统设置与剪贴板替代路径。
- 阅读器在旋转/尺寸变化后按稳定字符锚点恢复；前后台重新应用系统栏和常亮设置。
- iOS 宿主进入后台时临时关闭常亮，恢复前台时按 Dart 最近设置恢复，退出阅读器或终止时恢复原系统值。
- iOS Deployment Target 在 Podfile 与 Xcode 工程统一为 16.0；声明相机、本地网络用途，并仅为 WebView 与本地网络配置 ATS 例外，没有全局 `NSAllowsArbitraryLoads`。

## 当前不能宣称

1. M9 记录仍未包含用户明确确认的 Android A2 结论，且 M4、M8.1 仍有 P1 阻断。
2. 本次未运行 `flutter pub get`，所以 `pubspec.lock` 和 iOS Pods 仍等待用户更新。
3. JSF/QuickJS 尚无 iPhone 15 Pro Max、iOS 26 的构建与 S2～S5/S7 样本结果；历史同步 `java.webView` 仍可能遇到 Promise 语义差异。
4. WKWebView 登录、HttpOnly Cookie、第三方 Cookie、验证码和网页进程回收尚无真机结果。
5. Document Picker 安全作用域的原生释放时机需要通过真机文件提供者场景观察；Dart 代码已确保不保存外部路径。
6. 普通 HTTP 外部书源仍受 iOS ATS 约束；当前没有全局放开，HTTPS 是首批默认支持路径。

## 新增依赖说明

| 依赖 | 用途 | 维护与平台 | 替代评估 | 风险 |
|---|---|---|---|---|
| `webview_flutter ^4.14.1` | 登录、页面脚本、按域 Cookie 读写 | flutter.dev 官方维护；Android/iOS | 自写 Kotlin/Swift WebView 会重复生命周期与 Cookie 适配，不采用 | 依赖系统 WebView/WKWebView 行为；必须真机验证重定向、Cookie 和网页进程回收 |

## 交付物状态

- [x] iOS 平台接口代码接入。
- [x] 同一 JSF/QuickJS iOS 路径保留并补齐页面 WebView。
- [x] WKWebView/Cookie 双向同步代码。
- [x] Document Picker 后应用私有副本路径。
- [x] iOS 相机二维码入口与拒绝替代提示。
- [x] Safe Area、尺寸变化、系统栏和常亮代码。
- [x] 登录、扫码、阅读和 PDF 的生命周期/资源释放边界。
- [x] 自用签名与真机运行说明。
- [x] iOS 兼容样本报告模板。
- [x] 平台差异矩阵更新。
- [ ] 用户依赖解析、Xcode 构建、签名和安装结果。
- [ ] 用户完成 iOS 核心与异常路径。
- [ ] 用户明确确认 iOS 第一批可用。

AI 没有运行 Flutter、Dart、CocoaPods、Xcode、构建、测试、分析、格式化或真机命令。
