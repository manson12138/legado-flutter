# M02 Core Data Layer Output

Last updated: 2026-07-13

## Gate state

用户在 M1 尚未运行验证时明确要求执行 M02，因此本阶段按“允许带未验证状态继续”处理。
M1 和 M2 都不能标记为已验收；M2 当前状态为 `IN_PROGRESS / 实现待验证`。

## Deliverables

| Deliverable | Location | Status |
|---|---|---|
| 字段映射和可空性 | [01_field_mapping.md](./01_field_mapping.md) | IN_PROGRESS（待用户检查） |
| 不可变 Dart 领域实体 | `flutter_app/lib/src/domain/model/` | IN_PROGRESS（待用户检查） |
| SQLite Schema v1 | `flutter_app/lib/src/data/local/legado_database.dart` | IN_PROGRESS（待用户检查） |
| 第一批 DAO | `flutter_app/lib/src/data/dao/` | IN_PROGRESS（待用户检查） |
| Gateway/Repository | `flutter_app/lib/src/domain/gateway/`, `flutter_app/lib/src/data/repository/` | IN_PROGRESS（待用户检查） |
| 核心 UseCase | `flutter_app/lib/src/domain/usecase/` | IN_PROGRESS（待用户检查） |
| 数据错误模型 | `flutter_app/lib/src/data/local/data_error.dart` | IN_PROGRESS（待用户检查） |

## Database decision

- 依赖：`sqflite ^2.4.3`、`path ^1.9.1`。
- 用途：Android/iOS 共用 SQLite，支持事务、批量写入、版本化打开和后台数据库线程。
- 选择原因：M2 只支持 Android/iOS，`sqflite` 无需代码生成，数据库约束可直接与 Room 94 Schema 对照。
- 平台范围：`sqflite` 当前官方包页声明支持 Android、iOS、macOS；本项目第一批只使用 Android/iOS。
- 维护风险：DAO 使用显式 SQL 和手写映射，字段变更时必须同步 Schema、映射与字段文档；Stream 由表级提交通知后重新查询，不是假设 sqflite 自带响应式查询。
- 替代方案：Drift 可提供生成式类型安全查询，但会增加 build_runner/代码生成产物和当前阶段复杂度，M2 不引入。
- 官方资料：<https://pub.dev/packages/sqflite>、<https://pub.dev/packages/path>。

## Schema and transaction boundaries

- 数据库文件：`legado_flutter.db`，版本 1；不读取、不迁移原 Android `legado.db`。
- URL 主键原样保存，不做 trim、大小写转换、重定向归一化或尾斜杠归一化。
- 所有 `*Time`、`deadline`、`syncTime` 均为 Unix Epoch 毫秒；0 表示对应 Android 字段定义的未知、未发生或永不过期。
- `chapters` 主键为 `(url, bookUrl)`，同书 `(bookUrl, index)` 唯一，删除书籍级联删除章节。
- `searchBooks.origin` 外键指向 `book_sources.bookSourceUrl`，删除书源级联删除其搜索缓存。
- 书源批量导入、书籍加目录、目录整体替换均使用事务；只有事务提交成功后才发送观察流变更通知。
- UI 不获取 DAO。组合根只公开 Gateway 和 UseCase；Repository 捕获并转换数据库异常。

## User verification

Codex 没有运行依赖获取、代码生成、分析、测试、构建或启动。用户可按顺序执行：

```bash
cd flutter_app
flutter pub get
dart format --output=none --set-exit-if-changed lib
flutter analyze
flutter test
flutter run
```

建议另行补充并运行数据层测试，至少覆盖：

1. 首次打开数据库后九张表和索引存在，外键已启用。
2. 同书重复章节索引触发明确失败并回滚整次加入书架。
3. 删除书籍级联删除章节；删除书源级联删除搜索缓存。
4. 导入对象数组时任一书源非法会整体失败，不留下部分写入。
5. `null`、空字符串、0 和字段缺失在书源导入后仍保持文档定义的差异。
6. 保存并恢复章节索引、字符位置、章节标题、阅读时间和同步时间。
7. 观察流首次订阅立即返回当前值，事务提交后返回新值，事务失败不发送成功通知。

