# 本地书可见入口与导入后直接阅读方案

> 状态：`IMPLEMENTED / WAITING_FOR_USER_VERIFICATION`
>
> 分析日期：2026-07-31

## 1. 用户目标

1. 单本本地书导入成功后，不停留在导入结果页，直接进入对应阅读界面。
2. 用户之后能够明确找到已经导入的本地书。
3. “我的”页面提供“本地书籍”按钮。
4. 书架现有分组筛选中显示“本地”，只列出 `origin == 'loc_book'` 的书籍。

## 2. 当前数据事实

本地书没有写入独立的隐藏数据表：

- 书籍与目录通过 `AddBookToBookshelfUseCase.save` 原子写入当前游客或登录账号作用域的 `books`、`book_chapters`。
- 本地主键为 `local://<SHA-256>`，不是外部 `content://` 或临时路径。
- 正式文件副本位于应用私有 `local_books` 目录，数据库只保存相对路径和文件事实。
- `BookGroup.idLocal` 和 `_matchesGroup(... idLocal)` 已经存在，判断条件是 `book.origin == 'loc_book'`。

当前可见系统分组只注册了“全部、未分组、未读、阅读中”，遗漏了已经实现的 `idLocal`，因此用户无法通过明确入口确认本地书。这个缺口不代表导入事务没有写入。

## 3. 选择“我的入口 + 书架本地分组”，不新增第三套页面

用户提出两个可选入口：

- “我的”页面增加“本地书籍”按钮；
- 书架顶部把“书架 / 历史”扩展为“书架 / 历史 / 本地”三页。

本次推荐第一种，同时把现有书架分组栏中的“本地”恢复可见：

```text
我的 -> 本地书籍
  -> AppRoute.bookshelf(initialGroupId: BookGroup.idLocal)
  -> 现有 BookshelfRoute / BookshelfViewModel
  -> 当前用户 books 实时流
  -> origin == loc_book
```

原因：

- 本地书本来就是书架成员，已有完整的列表/网格、搜索、排序、长按选择、删除、分组、封面与阅读入口。
- 新增第三 PageView 页面需要复制或拆分书架显示状态、选择模式、封面几何和数据库订阅，增加内存、状态同步和动画风险。
- “我的”入口满足用户给出的可选方案；书架分组栏同时显示“本地”，从两个位置都能明确找到书籍。
- 不新增表、不迁移数据，也不把本地书从现有书架移走。

## 4. 单本导入成功后直接进入阅读器

### 4.1 ViewModel 规则

`LocalBookImportViewModel` 在一个批次只有一个选中文件，且该文件导入或同内容更新成功时，发送类型化 `OpenImportedLocalBookReaderEffect`，其中携带刚刚成功写入的 `Book` 快照和提示文案。

- 新导入：提示“已加入书架”。
- 同内容更新：提示“已更新本地书”。
- 失败：保留当前页显示受控错误，不进入阅读器。
- 多选批量导入：继续留在导入页显示新增、更新、失败汇总，不能任意选择其中一本自动打开。

### 4.2 路由规则

`LocalBookImportRoute` 收到成功 Effect 后使用 `pushReplacementNamed(AppRoute.reader)`：

- 传入 `ReaderRouteArguments.bookUrl`。
- 传入刚保存的 `initialBook`，避免再等待一次数据库查询。
- `initialIsInBookshelf = true`。
- 使用现有允许的书架阅读入口语义，不扩展匿名分析字段。
- 导入页被替换，返回阅读器时直接回到导入前的书架/我的/主界面，不再露出已完成的导入页。

统一 `BookReaderRoute` 会按书籍事实继续分流：

- TXT、EPUB、UMD 等文本本地书进入 `ReaderRoute`。
- PDF 进入 `PdfReaderRoute`。

外部打开产生的 cache 临时副本会在导入页被替换和销毁时释放；阅读器使用的是 `LocalBookStorage` 已经创建的正式私有副本，不依赖外部 URI。

## 5. 本地书入口实现

### 5.1 书架类型化参数

新增 `BookshelfRouteArguments(initialGroupId)`。`AppRouter` 只接受有效系统/用户分组 ID；“我的”入口固定传入 `BookGroup.idLocal`。

`BookshelfRoute` 把初始分组交给 `BookshelfViewModel`，ViewModel 首状态直接使用该分组，避免先闪现全部书籍再切换本地。

### 5.2 书架分组栏

把已有 `BookGroup.idLocal` 加入 `_buildGroups()` 的系统分组列表，名称为“本地”。数量继续由当前用户 `_allBooks` 实时计算。

### 5.3 “我的”页面

在“应用管理”分组靠近“书源管理”位置增加：

- 图标：本地书/文件夹语义图标。
- 标题：`本地书籍`。
- 摘要：`查看已导入的 TXT、EPUB、UMD 和 PDF`。
- 点击：打开 `AppRoute.bookshelf` 并指定本地分组。

入口不直接访问 DAO，不创建新的本地书 Repository。

## 6. 预计修改文件

| 文件 | 改动 |
|---|---|
| `lib/src/ui/local_book_import/local_book_import_contract.dart` | 增加导入成功后打开阅读器 Effect |
| `lib/src/ui/local_book_import/local_book_import_view_model.dart` | 单文件成功时发出阅读导航，批量继续汇总 |
| `lib/src/ui/local_book_import/local_book_import_route.dart` | 使用统一阅读路由替换导入页 |
| `lib/src/app/app_route.dart` | 增加 `BookshelfRouteArguments` |
| `lib/src/app/app_router.dart` | 解析书架初始分组参数 |
| `lib/src/ui/bookshelf/bookshelf_route.dart` | 把初始分组注入 ViewModel |
| `lib/src/ui/bookshelf/bookshelf_view_model.dart` | 初始分组支持与“本地”系统分组可见性 |
| `lib/src/ui/settings/settings_screen.dart` | 增加“本地书籍”设置项 |
| `lib/src/ui/settings/settings_route.dart` | 导航到书架本地分组 |
| `lib/src/ui/home/welcome_route.dart` | 保活主框架从“我的”切换到现有书架并请求本地分组 |
| `docs/flutter-rewrite/m08_1/README.md` | 记录实现与验证状态 |
| `docs/flutter-rewrite/AI_PROJECT_INDEX.md` | 更新入口和调用链索引 |

不修改 SQLite Schema、MMKV、`pubspec.yaml` 或原 Android 参考仓库。

## 7. 性能、动画与生命周期

- 保活主框架中的“我的”入口和书架分组共用一个 `BookshelfViewModel` 页面实例，不新增并行书架数据库订阅；独立设置路由才使用带初始本地分组的普通书架路由作为安全回退。
- 初始状态直接选择 `idLocal`，避免“全部 -> 本地”的首帧闪烁。
- 导入成功携带现有 `Book` 快照进入阅读器，减少一次首屏数据库往返。
- 阅读器仍使用现有 `BookReaderRoute` 分流、进度恢复和退出动画，不新写页面切换动画。
- 单飞导航防止连续 Effect 创建重复阅读器。
- 导入页销毁时继续释放 Effect 订阅、ViewModel 流和外部临时文件。

## 8. 用户验收

代码写入后由用户运行：

1. 从其他 App 打开一份 TXT，点击“加入书架”，确认直接进入文本阅读器。
2. 返回阅读器，确认回到主界面且不出现导入页或 `content://` 错误页。
3. 彻底退出重开，进入“我的 -> 本地书籍”，确认该 TXT 存在。
4. 在书架分组中选择“本地”，确认显示同一本书；切换“全部”时仍能看到它。
5. 重复导入同一 TXT，确认更新后也直接进入阅读器且不制造重复记录。
6. 单独导入 PDF，确认成功后进入 PDF 阅读器。
7. 一次选择两本书，确认仍停留在导入页显示汇总，不自动任选一本打开。
8. 导入失败时确认留在当前页并展示错误，不进入阅读器。
9. 游客和登录账号分别导入本地书，确认“本地书籍”入口遵守当前用户隔离。

## 9. 完成判断

代码写入后仍保持 `IN_PROGRESS`；只有用户完成单本 TXT、PDF、批量导入、重启持久化和游客/账号隔离验收后，才能标记完成。
