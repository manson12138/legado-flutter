# App 准入轮询与升级提示实施方案

状态：`IN_PROGRESS`。`GET /api/v1/app/bootstrap` 的准入和升级状态已接入前台协调器：首次显示后立即检查，前台每 5 分钟检查；明确拒绝或强制更新时显示阻断 UI。Android 提供用户主动退出；服务端提供合法 HTTPS `downloadUrl` 时可通过系统浏览器打开升级页，iOS 仅展示受控提示。等待 Android 后 iOS 用户验收，AI 未运行构建、测试或检查。

## 1. 唯一目标与边界

目标：以 `GET /api/v1/app/bootstrap` 作为唯一准入和升级接口，在应用启动及前台存活期间每 5 分钟检查一次；服务端拒绝时停止业务访问并显示不可用状态；服务端有更新时显示更新提示。

不单独调用 `GET /api/v1/app/access-check`：`bootstrap` 已返回相同的准入数据并同时返回更新、公告与功能开关，单独调用会增加网络请求与状态分歧。

本次不包含：后台定时唤醒、绕过系统限制的常驻服务、自动下载/安装 APK、iOS App Store 更新跳转的硬编码地址，以及服务端路由或准入规则修改。

## 2. 平台行为

| 服务端状态 | Android | iOS |
| --- | --- | --- |
| 首次请求失败且无有效缓存 | 保持当前离线降级，不阻断本地阅读 | 同左 |
| `access.allowed = true` | 正常使用 | 正常使用 |
| `access.allowed = false` | 显示不可关闭的准入阻断页；用户点击“退出应用”时调用受控 Android 平台退出 | 显示不可关闭的准入阻断页；不能主动退出 App，用户只能离开或等待服务端恢复 |
| 有非强制更新 | 显示可关闭的升级弹窗；稍后再说后继续使用 | 同左 |
| 有强制更新 | 显示不可关闭的升级弹窗并阻断业务；Android 可退出，iOS 保持阻断页 | 同左的阻断语义 |

iOS 主动退出违反平台体验与审核预期，不能用 `exit(0)` 或等价方式伪造“退出 App”。因此“服务端不允许就退出”的需求在 Android 上实现为显式退出操作，在 iOS 上实现为不可绕过的阻断页。这是必要的平台差异，而非降级遗漏。

## 3. 生命周期与性能

- 首帧后立即检查一次；成功后只在应用处于 `resumed` 状态时每 5 分钟请求一次。
- `inactive`、`paused`、`detached` 时取消计时器与正在等待的后续轮询，回到前台立即重新检查；不创建后台保活任务，避免耗电与内存泄漏。
- 同一时刻最多一个 bootstrap 请求；慢请求未结束时跳过下一轮，避免并发请求产生旧状态覆盖新状态。
- 网络、签名、解码错误只记录不含敏感信息的统一 Tag 日志，并保留当前已确认的准入状态；不能因为网络瞬断踢出用户。
- 只有服务端明确返回 `access.allowed = false` 才进入阻断状态；不能使用过期缓存的“拒绝”结果主动退出应用。

## 4. 升级弹窗与外部跳转待确认项

当前 API 示例中的 `update` 只包含 `hasUpdate`、`versionName`、`versionCode`、`forceUpdate`，未提供下载地址、商店链接或更新说明。因此本轮升级弹窗可准确实现“发现新版本”与阻断语义，但点击“立即更新”没有合法目标。

实施前需要后端补充并确认至少一个字段：

- Android APK 下载 URL；和/或
- Android、iOS 对应的商店/发布页 URL；和
- 可选的更新说明。

在链接未定义前，非强制更新弹窗只能提供“知道了/稍后”，强制更新页只能说明“请从发布渠道获取最新版本”，不得显示无响应的“立即更新”按钮。

此外，`bootstrap` 需要的 `versionName` 目前未由 Flutter 发送。实施时必须从 `pubspec.yaml` 的 `version:` 前半段集中读取或由 `--dart-define` 注入，不能用 build number 代替语义版本；`versionCode` 与服务端数值规则也需要确认。

## 5. 分层与文件映射

```text
WidgetsBinding 生命周期
  -> AppAccessCoordinator（单定时器、单飞行请求、准入状态）
  -> RemoteAppConfigurationRepository
  -> RemoteAppApi.fetchBootstrap
  -> MaterialApp 顶层阻断层 / 升级对话框
  -> Android 退出平台桥（仅用户点击后调用）
```

- `AppAccessCoordinator` 持有 `ValueNotifier<AppAccessState>`，负责解析受控领域状态，释放计时器和生命周期观察器。
- `RemoteAppApi` 负责校验 bootstrap 的 `access` 和 `update` 字段，不将动态 Map 传入 Widget。
- `LegadoApp` 只订阅状态并覆盖阻断层/弹窗；不在 `build()` 发网络请求。
- Android 退出动作置于窄平台桥，必须由用户点击“退出应用”触发；不得在网络回调中强杀进程。

## 6. 用户验收

- 首次在线允许、首次离线、恢复前台和连续 5 分钟轮询各一次。
- 服务端明确拒绝后 Android 出现阻断页并可由用户点击退出；iOS 出现阻断页且不主动退出。
- 非强制更新可关闭；强制更新无法绕过；网络错误不误阻断。
- 后端提供更新链接后，分别验证 Android 下载页和 iOS 发布页跳转。
- Android 验收通过后再验证 iOS；AI 不运行构建、测试、分析或应用。
