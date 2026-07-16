# M11 实施记录：后续完整功能迁移

状态：`IN_PROGRESS / 当前唯一 Feature 为整书换源，代码已实现，等待 Android 后 iOS 用户验收`

## 阶段门禁说明

- M9 尚无用户明确确认的 Android A2 结论，M10 也没有 iPhone 15 Pro Max、iOS 26 真机通过记录。
- 用户在已被明确告知“M10 仍待真机验收”后再次要求执行 M11，因此本轮按“允许带未验证状态继续”处理。
- 该允许只解除本次编码阻塞，不把 M9、M10 或 M11 标记为通过；普通规则、JavaScript、WebView/Cookie 与本地书既有阻断仍保留。

## 当前唯一 Feature

本轮只迁移“网络书整书换源”：

- 从书籍详情、书架单选和文本阅读器进入。
- 在当前启用书源中有界并发搜索同名候选，可选作者校验和书源范围。
- 候选必须完成详情和完整目录加载后才允许确认。
- 原子替换旧书主键、旧目录、新书和新目录，并在事务内复查目标主键冲突。
- 可选择迁移阅读进度、分组排序、自定义封面、分类标签、备注简介和单书阅读/显示配置。
- 阅读器入口换源前保存稳定进度，成功后使用新主键替换当前阅读路由。

明确不包含：单章换源、自动换源、批量换源、书源置顶/禁用/删除、缓存下载和旧正文缓存批量删除。缓存下载仍是后续独立 Feature。

## 专项记录

- [Android 行为清单](./change_source/01_android_behavior_inventory.md)
- [文件映射与分层设计](./change_source/02_mapping_and_design.md)
- [Android/iOS 验收矩阵](./change_source/03_acceptance_matrix.md)

AI 没有运行 Flutter、Dart、Gradle、Xcode、构建、测试、分析、格式化或应用启动命令。
