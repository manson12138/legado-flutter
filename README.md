# Legado Flutter

这是与原 Android 应用共存的独立 Flutter 工程。M1～M8.1 已逐步实现应用骨架、独立数据层、
网络与规则、书源管理、搜索详情目录、书架、文本阅读器以及部分本地书格式，当前进入 M9
Android 第一批验收准备。所有阶段仍缺少用户运行证据，JavaScript 与部分本地书格式存在明确阻断，
不能宣称 Android A2 已完成。

## 固定环境

- Flutter：`3.41.5 stable`
- Dart：`3.11.3`
- Android applicationId：`io.legado.flutter`
- Android minSdk：`26`
- iOS Bundle Identifier：`io.legado.flutter`
- iOS Deployment Target：`16.0`

`.fvmrc` 固定 Flutter 版本，`pubspec.yaml` 固定 Dart 版本。首次获取依赖后应提交应用工程的 `pubspec.lock`；后续升级 SDK 或依赖必须单独记录原因并经过确认。

## 架构选择

- 路由使用 Flutter SDK 的 `MaterialApp.onGenerateRoute`。M1 只有一个页面，不引入第三方路由库；路由名称和依赖接线集中在 `lib/src/app`。
- 依赖注入使用组合根加构造参数。M1 依赖数量很少，不引入第三方容器，也不使用全局 Service Locator。
- 页面遵循 UiState、Intent、Effect、ViewModel、Route、Screen 分层。短暂的导航和系统 UI 行为通过 Effect 交给 Route 执行。
- Android 与 iOS 共用 Material 3 主题和 Design Token；系统能力差异以后通过 `platform` 抽象接入。
- 核心数据层使用 `sqflite` 的独立 `legado_flutter.db`，Schema v1 不读取或迁移原 Android 数据库。
- UI 只能使用 UseCase；DAO 由 Repository 隔离，数据库异常会转换为稳定应用错误。

## 用户运行步骤

Codex 未执行依赖获取、分析、测试、构建或启动。请在仓库根目录按需执行：

```bash
cd flutter_app
flutter pub get
flutter run
```

M9 最小命令、核心路径、异常路径和缺陷表见 `docs/flutter-rewrite/m09/README.md`。Codex 没有运行这些命令。

需要人工确认：

1. Android 安装后与原应用同时存在，桌面名称显示为 `Legado Flutter`。
2. iOS 签名目标的 Bundle Identifier 是 `io.legado.flutter`。
3. 启动后显示欢迎页，没有模板计数器，并可进入书源、搜索、书架和本地书导入入口。
4. 亮色、深色主题均可阅读，页面内容没有被 Android 系统栏或 iOS 安全区域遮挡。
5. 按 M9 矩阵完成网络书与本地书核心路径、异常路径和重启恢复。

用户完成 Android 真机验收并反馈前，M1～M9 均不能标记为 Android A2 已通过。
