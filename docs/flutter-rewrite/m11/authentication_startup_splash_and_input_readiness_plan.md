# 认证启动页与输入就绪门控方案

状态：`IN_PROGRESS`。启动页与认证输入门控代码已写入 Flutter，仍需 Android 与 iOS 真机验收；本方案不代表已通过真机验收。

## 1. 目标与边界

目标：应用冷启动时先显示仅含居中 App 图标的 Flutter 启动页；完成认证会话恢复、应用根部 Navigator 首帧挂载和认证输入交互门控后，才展示并允许操作登录/注册表单。Android 与 iOS 使用同一套 Dart/Flutter 状态机。

包含：

- 居中图标的 Flutter 启动页；
- 首帧后的认证会话恢复与认证根 Navigator 挂载；
- 认证输入框在就绪前不可获取焦点、不可提交；
- 就绪后首击的焦点与软键盘请求；
- `LEGADO_STARTUP` 和 `LEGADO_AUTH` 的非敏感阶段日志；
- Android/iOS 共用 Dart 实现与分别验收。

不包含：

- 在启动页预先聚焦不可见输入框或弹出后立即隐藏键盘；
- 新增 Android/iOS 原生输入法预热通道；
- 更改认证 API、Token、数据库或密码加密逻辑；
- 改变已登录用户进入主业务页的权限与准入行为。

## 2. 原因判断

当前日志已证明首次点击会进入 Flutter 输入框焦点并调用 Android `showSoftInput`，但冷启动极早期系统可能尚未接受首个输入法展示请求。该阶段没有跨平台、可靠且无副作用的“IME 已就绪”回调。

因此不能把“启动页显示”错误地当成“已初始化 Android/iOS 输入法服务”。可控做法是确保 Flutter Widget 树、认证嵌入 Navigator、Overlay 和 FocusScope 已稳定完成至少一个绘制帧，并在此之前禁止表单接收焦点；真正的软键盘仅在用户点击已启用的可见输入框后请求展示。

## 3. 设计

```text
main.dart / LegadoApp
  -> 启动页（居中应用图标，表单不可见）
  -> 恢复认证会话
  -> 挂载认证门的内嵌 Navigator
  -> 等待首帧结束 + 下一事件循环
  -> 输入就绪
  -> 未登录：认证表单可交互
  -> 已登录：进入现有主业务路由
```

### 3.1 启动状态

在 `LegadoApp` 引入仅限 UI 层的不可变启动状态，至少区分：`booting`、`restoringAuthentication`、`preparingAuthenticationInput`、`ready`。启动页在前三种状态显示；只有 `ready` 时才允许认证页渲染可操作的 `TextFormField`。

认证会话恢复失败保持当前受控的未登录降级行为：启动页退出后显示登录表单，不因网络错误无限阻塞。

### 3.2 输入就绪门控

1. 启动页出现后注册 post-frame 回调；
2. 认证恢复结束后，挂载已有的认证根 Navigator；
3. 等待认证 Navigator 的首帧结束，并再让出一次事件循环；
4. 将状态切换为 `ready`，认证表单才设置为可交互；
5. 用户点击时仍使用已有的焦点请求与下一帧 `TextInput.show` 请求；
6. 点击非输入区域继续按当前产品行为取消焦点并收起键盘。

不使用固定长延时作为“输入法已经就绪”的依据。若需视觉最小展示时长，仅可作为体验下限，不能替代第 2 至 4 步的状态条件。

### 3.3 平台策略

- Android：依赖 Flutter `FocusScope`、`EditableText` 和 `SystemChannels.textInput`；不新增 Kotlin 通道。验收首击焦点、系统 IME 展示和空白处收起。
- iOS：使用同一 Dart 逻辑，由 Flutter 对接 UIKit 文本输入；不新增 Swift 通道。验收首击焦点、系统键盘展示、Safe Area 与键盘遮挡下的布局。
- 两端都不尝试预聚焦或主动隐藏键盘，避免键盘闪烁、无障碍焦点被抢占和无用户操作时的系统输入法展示。

## 4. 预期改动

| 文件 | 改动职责 |
|---|---|
| `lib/src/app/legado_app.dart` | 启动状态、居中图标启动页、认证恢复与输入就绪时序 |
| `lib/src/ui/authentication/authentication_route.dart` | 接收输入就绪状态，在未就绪时禁用输入与提交；保留焦点、键盘和日志边界 |
| `lib/src/help/logging/app_logger.dart` | 仅在现有 tag 无法表达阶段时补充固定日志标识；本方案优先复用 `LEGADO_STARTUP` / `LEGADO_AUTH` |
| `docs/flutter-rewrite/AI_PROJECT_INDEX.md` | 记录实施文件与本方案入口 |

预计不新增持久化数据、数据库表或字段，因此不调整 `LegadoDatabase.schemaVersion` 和 `pubspec.yaml` build number。

## 5. 日志与隐私

- 启动阶段使用 `LEGADO_STARTUP`：启动页显示、认证恢复结束、认证 Navigator 首帧完成、输入交互开放。
- 表单阶段使用 `LEGADO_AUTH`：输入点击、焦点变化、键盘请求与收起请求。
- 严禁记录用户名、密码、邀请码、Token、密钥、键盘输入文本或完整异常正文。

## 6. 用户验收

Android 与 iOS 分别验证：

1. 冷启动时先看到居中的 App 图标；
2. 启动页期间不存在可点击的认证输入框；
3. 登录页出现后，首次点击账号、密码及注册表单各输入框都能弹出键盘；
4. 点击非输入区域收起键盘；
5. 已有安全会话恢复成功后仍能正常进入主页面；
6. 认证恢复失败时能进入登录页，不会永久停在启动页；
7. 日志仅含阶段字段，不包含认证数据。

AI 不运行 Flutter、Dart、Gradle、Xcode、构建、测试、分析、格式化或应用启动命令；由用户执行上述验收。
