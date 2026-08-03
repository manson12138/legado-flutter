# App 准入与升级状态持久化设计

状态：`IMPLEMENTED_PENDING_USER_VERIFICATION`。准入状态持久化、相同语义版本离线恢复以及新 `versionName` 安装包清理旧缓存的代码已写入；未运行编译、测试、分析、格式化或应用。

## 1. 问题与目标

当前 `AppAccessCoordinator` 只在内存中保存最近一次 bootstrap 的 `access` 和 `update` 结果。用户收到“当前版本不允许使用”或“必须升级”后杀掉 App，再断网重启，协调器从默认允许状态开始；网络请求失败后仍保持默认允许，导致之前已确认的阻断被绕过。

目标是在本地持久化服务端已成功确认的准入/升级状态。相同 App 版本再次启动且无法联网时，必须恢复此前的强制升级或拒绝准入阻断；非强制升级也要恢复提示信息。网络成功返回新的状态后，以新状态覆盖缓存。

## 2. 数据边界

使用现有 SQLite `caches` 表新增一个 JSON 缓存键，不新增表、字段或远端 API：

- 当前客户端身份：`productId`、实际安装包 `appVersionName`、`channel`。`appVersionCode` 继续随缓存保存并发送给服务端，但 Android versionCode 与 iOS build number 不参与跨平台缓存身份判断。
- 已确认状态：`allowed`、`accessMessage`、`hasUpdate`、`forceUpdate`、`versionName`、`latestVersionCode`、`downloadUrl`、`changelog`。
- 缓存记录时间，仅用于诊断和未来治理；本次不因时间过期自动放行已确认的阻断。

该状态与账号无关，而与 App 版本和服务端准入规则相关；登出不得清除。密码、Token、完整 bootstrap 正文及任何私密数据不得写入此缓存或日志。

## 3. 启动与离线语义

```text
已恢复会话 / 登录成功
  -> AppAccessCoordinator 启动
  -> 先异步读取“当前 App 身份”匹配的持久化状态
       -> 命中 forceUpdate 或 allowed=false：立即显示阻断层
       -> 命中普通升级：恢复可关闭提示
       -> 无命中：保持现有离线降级语义
  -> 并发/随后发起 bootstrap 最新检查（单飞）
       -> 成功：先原子覆盖持久化状态，再更新 UI
       -> 失败：保留已恢复状态；无缓存则不阻断
```

当持久化记录的 `productId`、实际安装包 `versionName` 或 `channel` 与当前安装不一致时，必须忽略并删除该记录：新语义版本不能被旧版本的强制升级或拒绝状态永久阻断。Android versionCode 与 iOS build number 允许独立变化，不参与判断。只有服务端成功返回 `allowed=true` 且 `forceUpdate=false` 时，才允许覆盖、解除此前阻断。

实际 `versionName` 由项目自有窄 MethodChannel 在 `runApp` 前一次性读取 Android `PackageManager` 中的当前安装包 `versionName` 或 iOS `CFBundleShortVersionString`，并覆盖仅供网络降级使用的 `dart-define` 后备版本名。该实现不依赖 Android `BuildConfig`，也不引入第三方插件或额外 Gradle artifact。若平台元数据读取失败或返回空版本名，本次启动不得恢复旧准入缓存，而应删除缓存并等待网络重新确认，避免后备常量误认成当前安装包身份。

为避免缓存读取尚未完成时短暂进入业务界面，协调器增加“正在恢复本地准入状态”的受控启动态，应用级遮罩仅等待这一次本地 SQLite 读取；不等待网络。读取失败时记录不含数据内容的统一日志后按无缓存降级，不阻塞登录页或无限等待。

## 4. 拟修改范围

- `platform/app_package_info_service.dart`、`RemoteAppServiceConfig`、`main.dart`：通过 Android/iOS 自有宿主在启动时一次性读取实际安装包 `versionName`；失败时标记版本身份不可信，不注册监听器或持有平台资源。
- `RemoteAppConfigurationRepository`：负责准入/升级状态的 JSON 编解码、按当前产品、实际 `versionName` 和渠道读取、成功 bootstrap 后写入和身份不匹配清理。
- `AppAccessCoordinator`：启动时先恢复持久化状态，再进行现有单飞网络刷新；成功网络结果须先落盘再发布内存状态。生命周期轮询、Android 退出和 iOS 阻断语义保持不变。
- `AppAccessState` 与 `PageNestApp`：增加本地恢复中状态，并在该状态下展示不可交互的短暂加载层，防止已缓存阻断被短暂绕过。
- `AppDependencies`：为协调器补充当前 App 服务配置或封装后的持久化状态入口。
- 项目索引和既有准入实施方案：记录离线恢复规则与验收。

不修改书架/历史数据、认证 Token 存储、数据库 schema、应用构建号、服务端路由或平台桥。

## 5. 一致性、性能和资源约束

- 缓存 JSON 解码失败、字段缺失或身份不匹配，一律视为无缓存并删除损坏/过期记录；不得根据部分字段推断阻断。
- 每次网络 bootstrap 只产生一条小型覆盖写入；沿用现有单飞请求，避免轮询并发造成旧结果覆盖新结果。
- 先成功持久化再发布新的允许状态，防止“内存已放行、进程立即被杀、离线重启又恢复旧阻断”的反向不一致。
- 预恢复层只等待本地数据库查询，不允许等待网络，也不得在 `build()` 发起读取。
- 现有定时器、生命周期观察器和 `ValueNotifier` 的释放责任保持不变。
- 安装包信息只在启动时读取一次，不创建轮询、监听器或长期平台对象；版本身份不可信时宁可清理旧缓存，也不恢复可能属于旧包的阻断状态。

## 6. 用户验收

1. 服务端返回强制升级后杀掉 App、断网重启：启动后仍显示不可绕过的“请升级 App”。
2. 服务端返回 `allowed=false` 后杀掉 App、断网重启：启动后仍显示不可绕过的“当前版本暂不可用”。
3. 服务端返回普通升级后杀掉 App、断网重启：仍能看到可关闭升级提示，但业务可以使用。
4. 已缓存阻断时重新联网且服务端明确允许当前版本：缓存和阻断都被清除，业务恢复可用。
5. 安装具有不同 `versionName` 的新包后断网启动：旧包缓存被删除且不应阻断新包；只改变 Android versionCode 或 iOS build number、保持 `versionName` 不变时仍视为同一语义版本。
6. 缓存损坏、首次离线和本地数据库读取失败：不永久卡住；按无缓存的现有离线降级进入应用。
