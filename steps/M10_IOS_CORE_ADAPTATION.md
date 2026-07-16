# M10：iOS 第一批适配

> 当前状态：`IN_PROGRESS / 平台代码与验收文档已接入，等待 M9 前置确认、依赖解析、Xcode、iPhone 15 Pro Max 与兼容样本结果`。实施记录见 `../m10/README.md`。

## AI 执行规则（必须先读）

1. 必须确认用户已验收 Android A2，并阅读总方案及 M0～M8.1、M9 文档。
2. iOS 阶段复用 Dart 业务代码，不得重写第二套书源、数据库、搜索或阅读状态机。
3. Swift 只实现平台能力和引擎接入，业务规则保持在 Dart。
4. 目标设备为 iPhone 15 Pro Max、iOS 26；Deployment Target 暂定 iOS 16.0。
5. iOS 无法等价实现的 Android 能力必须提供替代或明确 unsupported，不得保留无响应入口。
6. JavaScript 行为必须复用同一兼容 API 和样本。
7. 所有新增 Dart/Swift 类、方法和变量必须有详细中文注释；禁止强制空值解包。
8. AI 不运行 Xcode、签名、build、test 或真机安装。

## 阶段目标

在不复制核心业务的前提下，让 iOS 完成与 Android A2 相同的书源、搜索、书架和阅读闭环。

## 执行步骤

### 1. iOS 能力盘点

- 文件导入与安全作用域 URL。
- WKWebView、Cookie 和登录。
- 相机二维码。
- 网络权限和本地网络说明。
- Safe Area、状态栏、屏幕常亮和系统手势。
- App 生命周期、后台切换和内存警告。
- 自用签名、Bundle Identifier 和真机部署说明。

### 2. JavaScript 引擎

- 实现 M4 `JsEngine` 的 iOS 版本或接入同一跨平台引擎。
- 保持 Scope、值转换、异常、超时和中断一致。
- 执行同一批普通规则和 JavaScript 样本。
- JavaCompatibilityBridge 在 iOS 上返回相同结构或明确 unsupported。

### 3. 文件与二维码

- 书源文件与 M8.1 本地书通过 iOS Document Picker；需要长期读取的本地书复制到应用沙盒，安全作用域访问必须及时释放。
- 正确复制或读取用户选择文件，处理权限生命周期。
- 二维码权限被拒绝时提供设置指引或替代粘贴方式。

### 4. WKWebView 与 Cookie

- 登录、验证码、动态页面请求使用受控 WebView。
- 定义 WKWebView Cookie 与统一 Cookie Store 同步。
- 页面关闭时释放 Delegate、观察者和脚本 Handler。

### 5. 阅读器适配

- 处理 Safe Area、Home Indicator、系统栏和手势冲突。
- 处理前后台、旋转/尺寸变化和内存警告后的恢复。
- 屏幕常亮通过平台接口实现。

### 6. 自用安装说明

- 记录 Xcode 版本、签名 Team、Bundle Identifier 和设备信任流程。
- 不将证书、Provisioning Profile 或个人 Team ID 提交仓库。

## 注意点

- iOS 文件 URL 可能只在安全作用域会话内有效，不能永久保存外部路径。
- WKWebView 与普通 HTTP Cookie 不会自动完全同步。
- iOS 后台能力比 Android 严格，第一批核心闭环应以前台为主。
- Swift Optional 不得使用强制解包。
- iOS 返回手势和 Flutter 路由返回要保持一致。
- Debug 本地网络权限不要错误带入 Release 配置。

## 交付物

- [x] iOS 平台接口代码实现。
- [x] 同一 JSF/QuickJS iOS 路径接入；真机结果待用户。
- [x] WKWebView/Cookie 同步代码。
- [x] Document Picker 后私有副本导入路径。
- [x] 二维码与权限拒绝替代提示。
- [x] Safe Area/系统栏/常亮适配代码。
- [x] 生命周期和资源释放代码。
- [x] 自用签名与真机运行说明。
- [x] iOS 兼容样本报告模板。
- [x] 平台差异矩阵更新。

## 完成标准

1. 用户在 iPhone 15 Pro Max、iOS 26 上成功自用签名安装。
2. 同一 Flutter 数据层和业务层完成核心闭环。
3. 普通规则和 JavaScript 样本结果与 Android 一致或差异已接受。
4. 文件、二维码、WebView 和 Cookie 可用。
5. 前后台切换后当前页面和阅读位置可恢复。
6. Safe Area、Home Indicator、键盘和手势无阻断问题。
7. 无证书、密钥或个人标识进入仓库。

## 阶段退出门禁

- 用户完成与 Android 相同的 15 步核心验收。
- 不存在 iOS 单独复制的核心业务实现。
- 不存在无响应的平台功能入口。
- 所有 iOS 限制已写入平台矩阵。
- 用户明确确认 iOS 第一批可用。

## 最终自检

- [ ] Android A2 已由用户确认。
- [ ] iOS 复用同一 Dart 业务代码。
- [ ] JavaScript 使用同一兼容接口和样本。
- [ ] 文件权限生命周期处理正确。
- [ ] WKWebView/Cookie 同步明确。
- [ ] Safe Area、手势和前后台恢复已覆盖。
- [ ] Swift 无强制 Optional 解包。
- [ ] 仓库无证书、Profile、Team ID 或密钥。
- [ ] AI 没有运行 Xcode/build/test。
- [ ] 用户确认真机结果，新增文件已询问是否 `git add`。
