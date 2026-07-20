# M10 iOS 自用签名与真机运行

## 固定项目值

| 项目 | 当前值 |
|---|---|
| Flutter | 3.41.5 stable |
| Dart | 3.11.3 |
| Deployment Target | iOS 16.0 |
| 默认 Bundle Identifier | `io.legado.flutter` |
| 目标设备 | iPhone 15 Pro Max |
| 目标系统 | iOS 26 |
| Xcode 版本 | 待用户在本机记录；AI 未运行 `xcodebuild -version` |
| Signing Team | 只在用户本机 Xcode 选择，不写入仓库 |

## 用户执行顺序

1. 在 `flutter_app` 目录执行 `flutter --version`，确认 Flutter 3.41.5 和 Dart 3.11.3。
2. 执行 `flutter pub get`，让 `pubspec.lock` 记录 `webview_flutter` 的兼容解析结果。
3. 如 Flutter 未自动处理 Pods，在 `flutter_app/ios` 执行 `pod install`。
4. 用 Xcode 打开 `flutter_app/ios/Runner.xcworkspace`，不要打开 `.xcodeproj`。
5. 选择 Runner target → Signing & Capabilities → Automatically manage signing。
6. 在本机选择个人 Team；如果默认 Bundle Identifier 已被占用，只在自己的签名配置中改成唯一标识，并避免提交个人标识。
7. 连接 iPhone，信任电脑并按系统提示开启 Developer Mode。
8. Xcode 选择该 iPhone 为运行设备，执行 Run。
9. 若系统要求信任开发者证书，在设备“设置 → 通用 → VPN 与设备管理”中按提示信任。
10. 记录首次安装、冷启动、前后台、杀进程重启和覆盖安装结果。

## 不得提交

- `DEVELOPMENT_TEAM` 个人 Team ID。
- `.p12`、`.cer`、私钥、Provisioning Profile。
- Apple ID、设备 UDID、个人钥匙串或签名日志中的敏感信息。
- 为个人签名临时修改的唯一 Bundle Identifier，除非用户明确决定成为仓库新默认值。

## 首次失败时需要返回的信息

- Xcode 版本、macOS 版本、iPhone 型号与 iOS 版本。
- 失败发生在依赖解析、Pods、编译、签名、安装还是启动。
- Xcode Issue Navigator 中第一条根因错误及其必要上下文。
- 不要发送证书、Team ID、UDID、Cookie、账号、Token、书源正文或文件绝对路径。
