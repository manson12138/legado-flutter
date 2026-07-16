# Flutter 重写阶段文档索引

## AI 执行规则（必须先读）

1. AI 开始任何阶段前，必须先完整阅读 `../FLUTTER_REWRITE_EXECUTION_PLAN.md`，再使用 [`../AI_PROJECT_INDEX.md`](../AI_PROJECT_INDEX.md) 定位相关实现，并阅读本索引和目标阶段文档。
2. 还必须阅读所有前置阶段的“完成标准、退出门禁、最终自检”，确认前置条件真实满足。
3. 不得跳阶段规避高风险门禁；用户明确要求并接受风险时，必须记录跳过原因和补做条件。
4. 阶段完成必须以用户运行结果或用户明确确认作为最终依据，AI 不能自行宣称通过。
5. AI 不运行编译、测试、静态分析或构建。
6. 新增文件后必须询问用户是否执行 `git add`。

## 阶段顺序

1. [M0：项目决策与迁移账本](./M00_DECISIONS_AND_MIGRATION_LEDGER.md)
2. [M1：Flutter 工程骨架](./M01_FLUTTER_PROJECT_SCAFFOLD.md)
3. [M2：核心数据层](./M02_CORE_DATA_LAYER.md)
4. [M3：网络与普通规则](./M03_NETWORK_AND_STANDARD_RULES.md)
5. [M4：JavaScript 兼容原型](./M04_JAVASCRIPT_COMPATIBILITY_PROTOTYPE.md)
6. [M5：书源管理](./M05_BOOK_SOURCE_MANAGEMENT.md)
7. [M6：搜索、详情与目录](./M06_SEARCH_DETAIL_AND_TOC.md)
8. [M7：书架](./M07_BOOKSHELF.md)
9. [M8：文本阅读器](./M08_TEXT_READER.md)
10. [M8.1：本地书籍导入与阅读](./M08_1_LOCAL_BOOK_IMPORT_AND_READING.md)
11. [M9：Android 第一批验收](./M09_ANDROID_CORE_ACCEPTANCE.md)
12. [M10：iOS 第一批适配](./M10_IOS_CORE_ADAPTATION.md)
13. [M11：后续完整功能迁移](./M11_FULL_FEATURE_MIGRATION.md)

## 阶段依赖

```text
M0 决策与账本
 ↓
M1 工程骨架
 ↓
M2 数据层
 ↓
M3 网络与普通规则
 ↓
M4 JavaScript 原型
 ↓
M5 书源管理
 ↓
M6 搜索、详情、目录
 ↓
M7 书架
 ↓
M8 阅读器
 ↓
M8.1 本地书籍导入与阅读
 ↓
M9 Android 验收
 ↓
M10 iOS 适配与验收
 ↓
M11 其余功能逐项迁移
```

## 全局完成判断

一个阶段只有满足以下条件才能进入下一阶段：

- [ ] 前置阶段已经完成。
- [ ] 本阶段所有强制交付物存在。
- [ ] 所有完成标准均有证据。
- [ ] 最终自检全部勾选，或未勾选项有用户接受的理由。
- [ ] 没有未登记的阻断问题。
- [ ] 用户已经运行建议检查并提供结果，或明确允许带未验证状态继续。
- [ ] 文件映射、功能矩阵和平台差异已同步更新。
- [ ] 新增文件的 Git 暂存由用户决定。
