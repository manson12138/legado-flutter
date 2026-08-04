# App 准入轮询与升级提示实施方案

状态：`IN_PROGRESS`。`GET /api/v1/app/bootstrap` 的准入和升级状态已接入前台协调器：请求明确携带 `platform=android|ios`；登录后先恢复与当前安装包身份匹配的本地已确认状态，再立即检查，前台每 5 分钟检查；明确拒绝或强制更新时显示阻断 UI。Android 服务端 APK 使用 Range 断点续传，完成后严格校验 `downloadByteSize` 与 `downloadSha256`，再交给系统安装器；iOS 不展示 APK 地址、大小、下载或安装入口，只通过服务端返回地址前往 TestFlight。等待 Android 后 iOS 用户验收，AI 未运行构建、测试或检查。

## 1. 唯一目标与边界

目标：以 `GET /api/v1/app/bootstrap` 作为唯一准入和升级接口，在应用启动及前台存活期间每 5 分钟检查一次；服务端拒绝时停止业务访问并显示不可用状态；服务端有更新时显示更新提示。

不单独调用 `GET /api/v1/app/access-check`：`bootstrap` 已返回相同的准入数据并同时返回更新、公告与功能开关，单独调用会增加网络请求与状态分歧。

本次不包含：后台定时唤醒、绕过系统限制的常驻服务、静默安装 APK、iOS TestFlight 地址硬编码，以及服务端路由或准入规则修改。

## 2. 平台行为

| 服务端状态 | Android | iOS |
| --- | --- | --- |
| 首次请求失败且无匹配的已确认缓存 | 保持当前离线降级，不阻断本地阅读 | 同左 |
| 首次请求失败且缓存为 `access.allowed = false` 或 `forceUpdate = true` | 恢复不可关闭的阻断页 | 同左 |
| `access.allowed = true` | 正常使用 | 正常使用 |
| `access.allowed = false` | 显示不可关闭的准入阻断页；用户点击“退出应用”时调用受控 Android 平台退出 | 显示不可关闭的准入阻断页；不能主动退出 App，用户只能离开或等待服务端恢复 |
| 有非强制更新 | 显示可关闭的升级弹窗；服务端 APK 在应用缓存中续传、校验后打开系统安装器；手动外链退化为外部浏览器 | 显示可关闭的升级弹窗；按钮只显示“前往 TestFlight”，不展示 APK 信息 |
| 有强制更新 | 显示不可关闭的升级页并阻断业务；APK 更新流程同上；Android 可退出 | 保持相同阻断语义，只允许前往 TestFlight，不提供 APK 能力 |

iOS 主动退出违反平台体验与审核预期，不能用 `exit(0)` 或等价方式伪造“退出 App”。因此“服务端不允许就退出”的需求在 Android 上实现为显式退出操作，在 iOS 上实现为不可绕过的阻断页。这是必要的平台差异，而非降级遗漏。

## 3. 生命周期与性能

- 首帧后立即检查一次；成功后只在应用处于 `resumed` 状态时每 5 分钟请求一次。
- `inactive`、`paused`、`detached` 时取消计时器与正在等待的后续轮询，回到前台立即重新检查；不创建后台保活任务，避免耗电与内存泄漏。
- 同一时刻最多一个 bootstrap 请求；慢请求未结束时跳过下一轮，避免并发请求产生旧状态覆盖新状态。
- 网络、签名、解码错误只记录不含敏感信息的统一 Tag 日志，并保留当前已确认的准入状态；不能因为网络瞬断改变已确认的允许或阻断结果。
- 相同产品、版本、构建号和渠道的已确认缓存可恢复 `access.allowed = false` 或 `forceUpdate = true` 阻断；客户端身份不匹配、损坏或字段不完整的缓存必须删除并按无缓存降级。只有服务端成功确认允许当前版本后才能解除该阻断。

## 4. APK 与 TestFlight 更新契约

2026-08-04 API 导出已明确：Android 服务端 APK 同时返回 `downloadUrl`、64 位小写 `downloadSha256` 和正整数 `downloadByteSize`，下载接口支持 200/206、Range 和不可变制品；iOS 的 `downloadUrl` 是 TestFlight 地址，两个 APK 校验字段为空。三个 Android 字段只有完整且合法时才启用应用内下载；手动外链没有摘要和大小时只允许外部浏览器打开，不能把未知文件当 APK 安装。

Android 临时文件只写入 `cache/app_updates`，`.part` 长度作为下一次 Range 起点；服务端忽略 Range 返回 200 时从头覆盖，206 的 `Content-Range` 必须与本地长度衔接。完成后先核对精确大小，再流式计算 SHA-256；失败时删除损坏文件。校验通过的 `.apk` 通过仅暴露该子目录的 FileProvider 临时授权给系统安装器，Android 8+ 缺少未知来源权限时先打开系统设置。包签名与覆盖安装兼容性仍由 Android 安装器最终判断，客户端不静默安装。

`bootstrap` 使用项目自有窄 MethodChannel 从 Android `PackageManager`、iOS `CFBundleShortVersionString` 读取实际安装包 `versionName` 并发送，不能用 build number 代替语义版本；准入缓存也只以实际 `versionName` 作为跨平台版本失效依据。`versionCode`/build number 继续发送给服务端，但不参与旧升级状态清理，其服务端数值规则仍需确认。

## 5. 分层与文件映射

```text
WidgetsBinding 生命周期
  -> AppAccessCoordinator（单定时器、单飞行请求、准入状态）
  -> RemoteAppConfigurationRepository
  -> RemoteAppApi.fetchBootstrap
  -> MaterialApp 顶层阻断层 / 升级对话框
  -> AndroidApkUpdateService -> AppUpdateBridge（Range、大小/SHA-256、FileProvider、系统安装器）
  -> iOS url_launcher -> TestFlight
```

- `AppAccessCoordinator` 持有 `ValueNotifier<AppAccessState>`，负责解析受控领域状态，释放计时器和生命周期观察器。
- `RemoteAppApi` 负责校验 bootstrap 的 `access` 和 `update` 字段，不将动态 Map 传入 Widget。
- `LegadoApp` 只订阅状态并覆盖阻断层/弹窗；不在 `build()` 发网络请求。
- Android APK 动作置于窄平台桥，必须由用户点击“立即更新”触发；iOS 不注册 APK 平台桥，也不声明安装权限。

## 6. 用户验收

- 首次在线允许、首次离线、恢复前台和连续 5 分钟轮询各一次。
- 服务端明确拒绝后 Android 出现阻断页并可由用户点击退出；iOS 出现阻断页且不主动退出。
- 非强制更新可关闭；强制更新无法绕过；网络错误不误阻断。
- Android 下载中断后再次点击可从已有长度继续；错误大小或 SHA-256 不打开安装器。
- Android 首次安装权限引导、返回后复用已校验 APK，以及安装器签名校验分别验证。
- iOS 只显示“前往 TestFlight”，不出现 APK 地址、大小、下载进度或安装权限入口。
- Android 验收通过后再验证 iOS；AI 不运行构建、测试、分析或应用。
