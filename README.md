# PageNest（拾页）

这是与原 Android 应用共存的独立 Flutter 工程。M1～M8.1 已逐步实现应用骨架、独立数据层、
网络与规则、书源管理、搜索详情目录、书架、文本阅读器以及部分本地书格式，当前进入 M9
Android 第一批验收准备。所有阶段仍缺少用户运行证据，JavaScript 与部分本地书格式存在明确阻断，
不能宣称 Android A2 已完成。

## 固定环境

- Flutter：`3.41.5 stable`
- Dart：`3.11.3`
- Android applicationId：`com.contradiction.pagenest`
- Android namespace：`com.contradiction.pagenest`
- Android minSdk：`26`
- iOS Bundle Identifier：`com.contradiction.pagenest`
- iOS Deployment Target：`16.0`
- 中文名：`拾页`；英文名：`PageNest`

`.fvmrc` 固定 Flutter 版本，`pubspec.yaml` 固定 Dart 版本。首次获取依赖后应提交应用工程的 `pubspec.lock`；后续升级 SDK 或依赖必须单独记录原因并经过确认。

## 架构选择

- 路由使用 Flutter SDK 的 `MaterialApp.onGenerateRoute`。M1 只有一个页面，不引入第三方路由库；路由名称和依赖接线集中在 `lib/src/app`。
- 依赖注入使用组合根加构造参数。M1 依赖数量很少，不引入第三方容器，也不使用全局 Service Locator。
- 页面遵循 UiState、Intent、Effect、ViewModel、Route、Screen 分层。短暂的导航和系统 UI 行为通过 Effect 交给 Route 执行。
- Android 与 iOS 共用 Material 3 主题和 Design Token；系统能力差异以后通过 `platform` 抽象接入。
- 核心数据层使用 `sqflite` 的独立 `pagenest.db`，Schema v1 不读取或迁移原 Android 数据库。
- UI 只能使用 UseCase；DAO 由 Repository 隔离，数据库异常会转换为稳定应用错误。

## 用户运行步骤

Codex 未执行依赖获取、分析、测试、构建或启动。请在仓库根目录按需执行：

```bash
flutter pub get
flutter run
```

M9 最小命令、核心路径、异常路径和缺陷表见 `docs/flutter-rewrite/m09/README.md`。Codex 没有运行这些命令。

需要人工确认：

1. Android 安装后与原应用同时存在，简体中文系统桌面名称显示为 `拾页`，其他语言显示为 `PageNest`。
2. iOS 签名目标的 Bundle Identifier 是 `com.contradiction.pagenest`。
3. 启动后显示欢迎页，没有模板计数器，并可进入书源、搜索、书架和本地书导入入口。
4. 亮色、深色主题均可阅读，页面内容没有被 Android 系统栏或 iOS 安全区域遮挡。
5. 按 M9 矩阵完成网络书与本地书核心路径、异常路径和重启恢复。

用户完成 Android 真机验收并反馈前，M1～M9 均不能标记为 Android A2 已通过。

## PageNest 新应用身份

2026-08-03 已将旧 Flutter 应用身份整体替换为 PageNest（拾页）。Android 包名、
iOS Bundle ID、数据库文件名和发布签名均已改变，因此新包不能覆盖旧包，也不会自动
读取旧应用沙盒数据。

Android 新签名的本机私密文件为：

- `android/pagenest-signing.properties`
- `android/app/signing/pagenest_release.jks`

两个文件均已被 Git 忽略。必须一起离线备份；丢失任何一个都可能导致无法对已发布
Android 安装包继续签名更新。不得将它们发送到聊天、提交到 Git 或上传到公开网盘。
