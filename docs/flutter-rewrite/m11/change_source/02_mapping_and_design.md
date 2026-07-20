# M11 整书换源：文件映射与分层设计

状态：`IN_PROGRESS / 代码已实现，双平台运行待用户验证`

## 文件、类和方法映射

| Android 路径 / 类型 | Flutter 路径 / 类型 | 方法或职责 | 实现 | 状态 |
|---|---|---|---|---|
| `ChangeSourceSearchUseCase.kt` | `model/web_book/change_source_coordinator.dart` / `ChangeSourceCoordinator` | `search` → `startSearch`；候选详情/目录 → `loadCandidate` | 纯 Dart，复用 M6 网络和规则链 | IN_PROGRESS |
| `ChangeBookSourceUseCase.kt` | `domain/usecase/change_book_source_use_case.dart` / `ChangeBookSourceUseCase` | `changeTo` → `execute`；`applyMigrationTo` → `_applyMigration` | 纯 Dart | IN_PROGRESS |
| `BookDao` + `BookChapterDao` 事务 | `BookshelfGateway.changeBookSource`、`BookRepository.changeBookSource` | 旧主键/目录与新主键/目录原子替换 | Dart/sqflite | IN_PROGRESS |
| `ChangeBookSourceComposeViewModel.kt` | `ui/change_book_source/change_book_source_view_model.dart` | 搜索世代、预览世代、选项和提交 | 纯 Dart MVI | IN_PROGRESS |
| `ChangeSourceMigrationOptionsSheet.kt` | `change_book_source_contract.dart`、`change_book_source_screen.dart` | 迁移选项状态与无状态 UI | Flutter | IN_PROGRESS |
| `BookInfoSheet.SourcePicker` | `change_book_source_route.dart` + `/books/change-source` | 独立整书换源路由 | Flutter | IN_PROGRESS |
| `ReadBookIntent.ChangeSource` | `OpenReaderBookSourceChangeIntent` / `OpenReaderBookSourceChangeEffect` | 保存进度、打开换源、用新主键替换阅读路由 | Flutter/Dart | IN_PROGRESS |
| 书架单书换源入口 | `OpenSelectedBookSourceChangeIntent` / `OpenBookshelfChangeSourceEffect` | 单选校验和导航 | Flutter/Dart | IN_PROGRESS |

## State / Intent / Effect

`ChangeBookSourceUiState` 保存：

- 旧书籍和启用书源快照；
- 全部/明确书源范围与作者校验；
- 搜索进度、取消状态、候选和单源失败；
- 选中候选、详情/目录预览、加载错误；
- 迁移选项和不可重复提交状态。

主要 Intent：

- `StartOrStopChangeSourceSearchIntent`
- `ToggleChangeSourceAuthorCheckIntent`
- `ToggleChangeSourceScopeIntent`
- `SelectChangeSourceCandidateIntent`
- `UpdateChangeSourceOptionsIntent`
- `ConfirmChangeBookSourceIntent`
- `BackFromChangeBookSourceIntent`

Effect：

- `ShowChangeBookSourceMessageEffect`
- `CloseChangeBookSourceEffect`
- `CompleteChangeBookSourceEffect`

## 数据与领域边界

```text
ChangeBookSourceScreen
  -> ChangeBookSourceIntent
  -> ChangeBookSourceViewModel
  -> ChangeSourceCoordinator
     -> BookSearchCoordinator
     -> BookDetailService
     -> StandardBookSourceService
  -> ChangeBookSourceUseCase
     -> BookshelfGateway.changeBookSource
     -> BookRepository + SQLite transaction
     -> ReaderCacheGateway（稳定锚点/显示配置复制）
```

- UI 不读取 DAO、不执行 HTTP、不解析规则、不操作文件系统。
- 候选搜索继续使用 M3/M4 的统一 HTTP、Cookie、普通规则和 JavaScript 接口。
- 数据库事务只保存最终书籍事实与目录；候选状态不写数据库。
- 稳定锚点和显示配置在主事务成功后复制。复制失败作为非阻断警告返回，不能把已经成功的数据库事务伪装成失败。

## 双平台边界

- 功能状态机、搜索过滤、目录预览、迁移和数据库事务全部在共享 Dart 中实现。
- Android 和 iOS 不新增原生业务代码，也不新增权限、Service 或后台任务。
- 平台差异只来自既有网络、TLS、JavaScript、WebView/Cookie 与 SQLite 插件行为，沿用 M3/M4/M10 的错误和验收边界。
- iOS 不需要 Android 前台 Service；缓存下载属于后续 Feature，届时另行设计后台降级。

## 已知差异和阻断

1. Android 的单章、自动、批量换源和候选书源管理不在本轮范围。
2. Android 可选择删除已下载章节；Flutter 的缓存下载尚未迁移，因此本轮没有提供虚假的删除下载选项。
3. 普通规则与 JavaScript 真实样本仍受 M3/M4/M10 未关闭门禁约束。
4. 两个平台都未由用户运行本轮代码，状态不能超过 `IN_PROGRESS`。
