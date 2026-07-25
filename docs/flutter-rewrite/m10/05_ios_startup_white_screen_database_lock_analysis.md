# iOS 启动白屏与 SQLite 锁等待分析

状态：`IMPLEMENTED / 等待用户真机验证`。本记录基于 2026-07-24 的真机控制台日志和静态源码梳理；未运行构建、测试、分析或应用。

## 现象与排除项

- Dart VM 已启动，应用日志初始化和 SQLite Schema 创建均已完成；这不是 Flutter 引擎、签名或 iOS 宿主启动失败。
- `fopen failed`、PointerUI、键盘帧通知和 `FlutterView` 焦点缓存提示均为 iOS/模拟器运行时噪声，日志中没有表明它们阻塞 Dart UI。
- `runApp` 位于 `await dependencies.defaultBookSourceBootstrapper.importIfEmpty()` 之后。因此内置书源导入未结束前，Flutter 尚未挂载任何页面，用户看到的是白屏。

## 已确认的启动竞争

```text
AppDependencies.create()
  -> DownloadCoordinator 构造函数
     -> unawaited(_recoverAndStart())
        -> caches / download_tasks 的读写与调度扫描

main()
  -> await DefaultBookSourceBootstrapper.importIfEmpty()
     -> BookSourceRepository.importSourceJson()
        -> LegadoDatabase.transaction()
           -> 成人内容开关查询、逐条书源冲突检查与写入
  -> runApp()
```

`sqflite` 在事务执行期间要求事务内所有数据库操作使用传入的 `Transaction`。下载恢复流程从独立数据库连接发起查询，和内置书源导入长事务重叠，恰好对应日志中事务开始后出现的 `download_tasks`、`caches` 查询，以及连续的 10 秒数据库锁等待警告。

这类等待会延长内置导入完成时间；由于当前 UI 尚未挂载，最终表现为启动白屏。即使事务最终提交，用户也没有可见的启动反馈。

## 已实施改动

1. `DownloadCoordinator` 不再在构造函数中自行启动，改为幂等 `start()` 入口。
2. `LegadoApp` 首帧后先导入内置书源；成功后才恢复下载、启动 App 准入轮询及认证会话恢复。
3. `main.dart` 不再等待书源导入才调用 `runApp`。启动阶段仅恢复登录会话；登录成功并进入主界面后，内置书源导入在后台执行。
4. 保持内置书源的导入语义、成人内容过滤、事务原子性和数据表结构不变；未变更 Schema、依赖或 iOS 原生宿主。

## 验收重点（由用户执行）

1. 新安装或清空本应用数据后启动，首屏应立即出现启动页面而非白屏。
2. 控制台不再出现启动期“database has been locked for 10 seconds”警告。
3. 内置书源完成导入后，书源列表可见；下载任务仍能将残留 `running` 状态恢复为 `waiting` 并继续调度。
4. 未登录时不触发书源导入或下载恢复；登录成功后主界面应保持可用，后台任务不得阻塞界面。
5. 硬编码 `admin` 账号登录后不启动 App 准入与版本检查；其他账号保持原有轮询行为。

## iOS 认证输入焦点导致界面不可点击

状态：`IMPLEMENTED / 等待用户 iOS 验证`。

`LegadoApp.didChangeAppLifecycleState` 当前在每次收到 `resumed` 时都会调用认证会话恢复。认证根门在恢复期间会以全屏 Material 替换登录页。iOS 输入框获取焦点、键盘或 Autofill 状态切换可能触发该生命周期路径；一旦发生，恢复层会覆盖账号、密码、登录和注册控件，导致用户看到原界面后续点击都无效。

已实施最小修复：认证会话只在应用首帧启动时恢复，移除 `resumed` 生命周期中的重复恢复，避免输入焦点或键盘相关事件重新覆盖登录页。保留登录成功后的主界面后台初始化逻辑，不修改登录、注册、书源导入、下载恢复或平台宿主代码。

用户验收重点：在 iOS 登录页连续点击账号和密码输入框、切换“登录/注册”、点击密码显示图标与登录按钮，所有控件都应持续可点击。

补充输入法兜底：认证输入框首次获得焦点后不再立即手工调用 `TextInput.show`。若 100ms 内系统键盘仍未通过视图 Insets 变为可见，且该输入框仍保持焦点，才补发一次显示请求；切换焦点、收起键盘和页面销毁都会取消该单次计时器，避免重复唤起或保留页面引用。

## 不包含

- 不处理日志中的 iOS 系统噪声提示。
- 不改变书源 JSON、SQLite Schema、下载业务规则或 iOS 平台通道。
- 不宣称 M10 或 iOS 真机验收已通过。
