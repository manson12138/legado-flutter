# M9 → M10 Android/iOS 差异交接

本文件只准备 M10 输入，不表示 M09 已通过，也不授权提前进行 iOS 全面适配。

| 能力 | Android 当前路径 | iOS 对应路径 | M10 必验差异 | 当前状态 |
|---|---|---|---|---|
| 文件选择与私有副本 | SAF/file_picker 后立即复制 | Document Picker/security-scoped URL 后复制 | 安全作用域开始/结束、临时 URL 生命周期、后台中断 | 待 M10 |
| PDF | PDFx Android 原生后端 | PDFx iOS PDFKit 后端 | 页数、缩放、内存释放、加密错误差异 | 待 M9 Android 结果 |
| JavaScript | JSF/QuickJS Dart FFI | 同一 JSF/QuickJS 路径 | iOS 禁止 JVM/Rhino 类；同步网络脚本必须有共同方案 | BLOCKED by M4 |
| WebView/Cookie | Flutter 官方 Android WebView + 统一 Dart Cookie | Flutter 官方 WKWebView/WKHTTPCookieStore + 统一 Dart Cookie | 登录会话、HttpOnly/第三方 Cookie、页面脚本、后台和内存警告 | M10 代码已接入，待双端真机 |
| HTTP 书源 | Android Network Security Config 允许兼容 HTTP | iOS ATS 默认限制 HTTP | 仅 WebContent/local networking 例外；外部普通 HTTP 默认失败并提示，固定域例外需用户确认 | M10 已决策，待真机 |
| 阅读常亮 | Window `FLAG_KEEP_SCREEN_ON` | `isIdleTimerDisabled` | 进入前状态保存、后台与退出恢复 | 代码均已接入，待双端验证 |
| 系统栏/安全区 | Android edge-to-edge/预测返回 | iOS safe area/home indicator | 返回手势、底部菜单、键盘和旋转 | 待双端验证 |
| 应用共存 | `io.legado.flutter` 与 `io.legato.kazusa` | 独立 Bundle ID | 数据目录、钥匙串组和文件容器不能交叉 | Android 待真机，iOS 待 M10 |

M10 入口仍要求：M09 无 P0/P1、用户明确确认 Android A2，并且 JavaScript 核心方案存在 iOS 实现路径。
