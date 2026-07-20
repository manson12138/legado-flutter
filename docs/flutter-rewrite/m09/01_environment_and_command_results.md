# M9 Android 验收环境与命令结果

## 已静态确认

| 项目 | 当前值 | 证据 | 状态 |
|---|---|---|---|
| 仓库分支 | `main` | 用户工作区 | 已记录 |
| 基线提交 | `307f2a45f6d7` | 当前 HEAD；不包含未提交的 Flutter 重写改动 | 已记录 |
| Flutter 固定版本 | `3.41.5` | `flutter_app/.fvmrc` | 待用户命令确认 |
| Dart SDK 约束 | `3.11.3` | `flutter_app/pubspec.yaml` | 待用户命令确认 |
| Flutter App 版本 | `1.0.0+1` | `flutter_app/pubspec.yaml` | 已记录 |
| Flutter applicationId | `io.legado.flutter` | Android Gradle 配置 | 已记录 |
| 原 Android applicationId | `io.legato.kazusa` | 原 App Gradle 配置 | 已记录 |
| Flutter 数据库 | `legado_flutter.db` v2 | `LegadoDatabase` | 已记录 |
| 安装类型 | 未知 | 用户填写 | 未开始 |

## 用户填写的真机环境

| 项目 | 用户结果 |
|---|---|
| Android 设备型号 | 待填写 |
| Android 系统版本 | 待填写 |
| ABI | 待填写 |
| 是否物理设备 | 待填写；M9 最终结果必须是“是” |
| 是否全新安装 | 待填写 |
| 原 Android App 是否同时安装 | 待填写 |
| 网络类型 | 待填写：Wi-Fi / 移动网络 / 代理 |
| 是否使用 VPN/代理 | 待填写 |
| 可用存储空间 | 待填写 |
| 验收日期与时区 | 待填写 |

## 用户命令结果

| 顺序 | 命令 | 预期 | 实际摘要 | 状态 | 原始输出位置 |
|---|---|---|---|---|---|
| 1 | `flutter --version` | Flutter 3.41.5、Dart 3.11.3 | 待填写 | NOT_STARTED | 待填写 |
| 2 | `flutter pub get` | 依赖解析成功并生成/更新 lockfile | 待填写 | NOT_STARTED | 待填写 |
| 3 | `flutter analyze` | 无阻断错误 | 待填写 | NOT_STARTED | 待填写 |
| 4 | `flutter test` | 已有测试全部通过；无测试也需记录 | 待填写 | NOT_STARTED | 待填写 |
| 5 | `flutter build apk --debug` | 生成可安装 APK | 待填写 | NOT_STARTED | 待填写 |
| 6 | `flutter run -d <device>` | 真机启动且无启动崩溃 | 待填写 | NOT_STARTED | 待填写 |

## 日志采集边界

- 只截取失败动作前后必要范围，记录发生时间、功能、输入样本编号和异常堆栈。
- 必须删除 Cookie、Authorization、账号、Token、文件绝对路径和正文内容后再提交日志。
- 不要开启全局网络正文日志；M09 不需要保存完整响应正文证明成功。
