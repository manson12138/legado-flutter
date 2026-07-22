# 安装包覆盖安装版本基线

> 用途：每次晚间打包前，以本文件的“当前基线”和当天改动为依据，判断新安装包能否覆盖已安装的版本、是否必须升级 `versionCode` / `versionName`，以及是否需要 SQLite 数据库迁移。
>
> 本文档只记录静态基线和决策规则，不代表已进行编译、签名校验或真机覆盖安装验证。
>
> 基线日期：2026-07-22

## 当前基线

| 项目 | 当前值 | 来源 |
|---|---|---|
| Android applicationId | `io.legado.flutter` | `android/app/build.gradle.kts` |
| Android namespace | `io.legado.flutter` | `android/app/build.gradle.kts` |
| 应用显示版本 `versionName` | `1.0.0` | `pubspec.yaml` 的 `version: 1.0.0+5` |
| Android 安装版本 `versionCode` | `5` | `pubspec.yaml` 的 `version: 1.0.0+5`，由 Gradle 使用 `flutter.versionCode` |
| iOS Bundle Identifier | `io.legado.flutter` | `ios/Runner.xcodeproj/project.pbxproj` |
| SQLite 文件名 | `legado_flutter.db` | `lib/src/data/local/legado_database.dart` |
| SQLite Schema 版本 | `7` | `LegadoDatabase.schemaVersion` |
| 本地书副本目录 | 与数据库目录同级的 `local_books/` | `lib/src/model/local_book/local_book_storage.dart` |
| 当前 Android release 签名配置 | `debug` 签名配置 | `android/app/build.gradle.kts` |

## 覆盖安装的硬性条件（Android）

新 APK/AAB 要保留已安装应用的数据并完成覆盖升级，必须同时满足：

- `applicationId` 仍为 `io.legado.flutter`；改包名会被 Android 视为新应用，不能覆盖原安装包。
- 新包必须使用与已安装包相同的签名证书。当前 `release` 构建配置使用 debug 签名；若已安装包也是按此配置生成，晚间包改成新的发布签名后不能直接覆盖，通常需要卸载重装，应用私有数据会丢失。
- 新包的 `versionCode` 必须大于设备中已安装包的 `versionCode`。每次要分发并覆盖安装的 Android 构建都应递增此数字。
- 不得删除、清空或改用其他应用沙盒中的既有持久化数据；对已有 SQLite、`local_books/`、应用支持目录文件和持久化配置的读取必须保持兼容，或提供迁移。

`versionName` 仅用于向用户展示版本，不是 Android 是否允许覆盖安装的判定条件；但只要当天发布了用户可识别的新包，建议同步升级它，以便问题追踪。

## 晚间打包前对比清单

### 1. 先判定安装身份

- [ ] `android/app/build.gradle.kts` 中的 `applicationId` 仍是 `io.legado.flutter`。
- [ ] 本次实际签名证书与手机上已安装包一致；不要只比较 `debug` / `release` 这个配置名，应比较实际 keystore 证书。
- [ ] 若应用身份或签名证书不同，按“不能覆盖安装、需要卸载重装”处理；先备份需要保留的数据。

### 2. 再判定应用版本

- [ ] 本次要生成可安装给已有用户的 Android 包：将 `pubspec.yaml` 的 `version` 中 `+` 后的 `versionCode` 增加至少 1。
- [ ] 本次仅改源码、不打包给已有安装包覆盖：可不改版本号。
- [ ] 本次是可识别的功能、修复或数据兼容发布：同步调整 `versionName`（建议使用语义化版本，如 `1.0.1+6`）。
- [ ] iOS 同样从 `pubspec.yaml` 取得 `CFBundleShortVersionString` 和 `CFBundleVersion`；若要在同一 iOS 应用上更新，仍需保持 Bundle Identifier 与签名身份一致。

### 3. 判定是否需要数据库升级

以下任一项成立时，必须将 `LegadoDatabase.schemaVersion` 从 `7` 升至下一个整数，并在同一提交中完成迁移：

- [ ] 新增、删除或重命名表、列、索引、唯一约束、外键、触发器或默认值。
- [ ] 改变既有列的类型、可空性、默认值、主键/唯一键语义，或现有数据需要转换、回填、合并、拆分。
- [ ] 修改持久化 JSON、枚举值、文件引用等既有数据格式，使旧数据不能被新代码直接安全读取。

数据库升级必须同时满足：

- [ ] 新安装路径的建表 SQL 已包含最新结构。
- [ ] `onUpgrade` 增加从所有历史 Schema 升到新 Schema 的分支；不得只保证从 v7 升级。
- [ ] 迁移顺序遵守表、列和外键依赖，旧数据不会因覆盖安装被静默丢弃。
- [ ] `pubspec.yaml` 的 build number（`+` 后数字）在同一次改动中递增，便于识别带 Schema 变更的安装包。

下列情况通常不需要升级 SQLite Schema：只调整 UI、网络请求、内存状态、DAO 查询实现，且不改变表结构和已保存数据的解释方式。

### 4. 判定其他持久化数据兼容性

- [ ] 本地书仍能按 `Book.variable` 中保存的相对路径读取同级 `local_books/` 副本；若改动路径、JSON 字段或格式名，提供旧格式兼容或一次性迁移。
- [ ] 应用支持目录中的 Cookie、日志、诊断文件或其他持久化配置改名、移动或变更格式时，不会影响必要业务数据；必要时保留旧路径读取和迁移逻辑。
- [ ] 新增持久化配置时，为缺失字段提供安全默认值；重命名或删除配置时，考虑旧值兼容与清理时机。

## 打包结论记录模板

每次打包前，在此处追加一段记录（不要覆盖上方基线）：

```md
### YYYY-MM-DD 晚间包

- 与基线相比的持久化改动：无 / 说明具体表、列、JSON、文件或配置改动。
- applicationId：未变 / 已变（已变则不可覆盖安装）。
- 签名证书：与已安装包一致 / 不一致（不一致则不可覆盖安装）。
- 版本：`旧 versionName+versionCode` -> `新 versionName+versionCode`。
- SQLite：Schema `旧` -> `新`；无需迁移 / 已补齐 `onCreate` 与 `onUpgrade`。
- 其他数据：`local_books`、Cookie、配置等兼容结论。
- 最终结论：可覆盖安装并保留数据 / 可覆盖安装但需执行迁移 / 不可覆盖安装，需要卸载重装并备份数据。
```

## 当前基线的特别提醒

当前 `release` 类型暂时复用了 debug 签名配置。这意味着，在切换到正式发布 keystore 之前，应先确认设备上已安装的包到底由哪张证书签名；直接切换签名通常不能保留现有应用数据完成覆盖安装。
