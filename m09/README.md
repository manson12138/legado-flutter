# M9 实施记录：Android 第一批验收

状态：`BLOCKED / 验收准备已完成，尚无用户运行证据，且 M4 与 M8.1 存在 P1 前置阻断`

## 本次已完成的验收准备

- 静态确认 Flutter Android `applicationId = io.legado.flutter`，原 Android `applicationId = io.legato.kazusa`，两者标识不同，具备共存前提；实际同时安装仍需用户真机确认。
- 静态确认 Flutter 固定版本为 `3.41.5`、Dart 约束为 `3.11.3`、App 版本为 `1.0.0+1`、独立数据库为 `legado_flutter.db` v2。
- 修复主 Android Manifest 缺少 `INTERNET` 权限的问题，使 debug、profile 和 release 合并结果都具备联网声明。
- 新增 Android `network_security_config.xml`：兼容仍使用 HTTP 的 Legado 书源；正式构建只信任系统证书，调试构建可额外信任用户证书用于用户自行抓包。
- 建立环境与命令结果、核心/异常路径、缺陷回归和 M10 差异交接四份验收表。
- 固定网络书源样本为 S1～S5，本地书样本覆盖 TXT、EPUB、UMD、MOBI/AZW3、PDF 与 ZIP/RAR/7Z。

## 当前阻断结论

M09 现在不能开始最终 A2 结论，也不能进入 M10：

1. `M09-P1-001`：M4 JavaScript 仍为 `BLOCKED`，没有 S2～S5 四段真机结果。
2. `M09-P1-002`：M8.1 尚未实现 MOBI/AZW/AZW3，核心本地书路径无法执行。
3. `M09-P1-003`：M8.1 尚未实现 ZIP/RAR/7Z 条目选择和安全导入。
4. `M09-P1-004`：EPUB 图片、封面与 Nav/NCX 层级尚未达到 M09 本地书验收要求。
5. `M09-GATE-001`：用户尚未提供 `pub get`、`analyze`、`test`、构建、启动或真机结果。

这些问题不会转换为空结果或降级为“可接受”，必须回到 M4/M8.1 修复或由用户明确调整范围。

## 用户最小命令顺序

AI 没有执行以下任何命令。请由你在真实 Android 设备连接后按顺序执行，并把第一次失败的完整输出发回：

```bash
cd flutter_app
flutter --version
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
flutter run -d <你的 Android 设备 ID>
```

不要在前一个命令失败时继续堆叠后续错误。命令输出登记到 [环境与命令结果](./01_environment_and_command_results.md)。

## 验收文件

- [环境与命令结果](./01_environment_and_command_results.md)
- [核心与异常路径矩阵](./02_core_and_exception_matrix.md)
- [缺陷与回归记录](./03_issue_and_regression_log.md)
- [M10 Android/iOS 差异交接](./04_m10_handoff.md)

用户提供全部运行证据并明确确认 Android 第一批可用前，M09 必须保持 `BLOCKED`。
