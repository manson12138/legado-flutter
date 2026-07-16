# M11 整书换源：Android 行为清单

状态：`MAPPING COMPLETE / Flutter 代码已实现，行为待用户验收`

## 入口

| Android 入口 | 主要行为 | Flutter 入口 |
|---|---|---|
| `BookInfoScreen` → `BookInfoIntent.ChangeSourceClick` | 从详情页打开整书换源 | 详情页顶部“整书换源” |
| `ReadBookScreen` → `ReadBookSheet.ChangeBookSource` | 阅读中保存进度并换源 | 阅读器顶部“整书换源” |
| 书架管理/单书操作 | 对书架中的网络书换源 | 书架长按单选 → “整书换源” |

## Android 主要文件

- `ui/book/changesource/ChangeBookSourceComposeViewModel.kt`
- `ui/book/changesource/ChangeSourceConfig.kt`
- `ui/book/changesource/ChangeSourceMigrationOptionsSheet.kt`
- `domain/usecase/ChangeSourceSearchUseCase.kt`
- `domain/usecase/ChangeBookSourceUseCase.kt`
- `ui/book/info/BookInfoViewModel.kt`、`BookInfoScreen.kt`、`BookInfoSheets.kt`
- `ui/book/read/ReadBookContract.kt`、`ReadBookViewModel.kt`、`ReadBookScreen.kt`
- `data/entities/Book.kt`、`BookChapter.kt`、`SearchBook.kt`
- `data/dao/BookDao.kt`、`BookChapterDao.kt`、`SearchBookDao.kt`
- `model/webBook/WebBook.kt`、`model/ReadBook.kt`

## 必须保持的行为

1. 只允许网络书执行整书换源；本地书入口必须给出明确不支持提示。
2. 搜索默认覆盖全部启用书源，可缩小范围，并允许停止当前任务。
3. 书名使用精确匹配；作者校验开启时，候选作者必须包含旧作者。
4. 多书源搜索存在并发上限、单源超时、取消和部分失败；单源失败不清空已找到候选。
5. 当前书源、当前详情 URL 完全相同的搜索结果不能作为换源目标。
6. 用户选择候选后加载详情和完整目录；空目录、来源缺失、规则失败或取消均不能写数据库。
7. 新主键已经属于书架中另一条书时，必须阻止静默覆盖。
8. 确认前可选择迁移阅读进度、分组排序、自定义封面、分类标签、备注简介和阅读配置。
9. 阅读进度优先按旧章节标题映射；找不到时使用受控旧索引，并跳过卷标题。
10. 旧书/旧目录删除与新书/新目录写入必须在一个事务中完成，失败时整体回滚。
11. 换源成功后详情和阅读器不能继续持有已删除的旧 `bookUrl`；必须切到新主键。
12. 阅读器发起换源前立即保存当前章节和字符锚点；取消换源后恢复阅读系统模式。
13. 书签按 Android 现有“书名 + 作者”关联，书名作者不变时无需改写书签主键。
14. 搜索、候选详情和目录的旧异步结果不能覆盖新搜索或新候选。
15. 日志不输出完整 URL、Cookie、认证信息、正文或用户备注。
16. 原子事务提交期间必须拦截顶部返回、系统返回和返回手势，避免数据库已成功但调用页仍持有旧主键。

## 本轮明确不包含

- 单章换源和临时正文替换。
- 阅读失败后的自动换源。
- 多本书批量换源和批量候选预览。
- 候选列表中的书源置顶、置底、禁用和删除。
- 缓存下载、下载队列、后台任务和旧正文缓存批量删除。

这些行为不会被标记为完成，后续按 M11 单 Feature 流程分别领取。
