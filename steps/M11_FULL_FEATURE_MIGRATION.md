# M11：后续完整功能迁移

## AI 执行规则（必须先读）

1. 必须确认 Android 与 iOS 第一批核心闭环均已通过用户验收。
2. 本阶段不是一个无限大任务；每次只选择一个明确 Feature，重新执行“盘点→映射→Contract→领域/数据→UI→平台→验收”。
3. 每个 Feature 先完成 Android，再完成 iOS，不得留下未登记的永久 Android-only 业务。
4. 必须优先复用 M0～M10 建立的数据、网络、规则、UI 和平台接口。
5. 不得借迁移新功能重构无关已完成模块。
6. IM/AI 聊天列表必须保留原 RecyclerView 反转语义和历史消息锚点行为。
7. 所有新增类、方法和变量必须有中文注释；禁止 Kotlin `!!`、Swift 强制解包和 Dart `!`。
8. AI 不运行构建、测试或检查；用户运行并确认后才更新完成状态。

## 阶段目标

在已稳定的双平台架构上，逐项覆盖原 Android 项目的其余功能，最终达到约定的完整功能一致。

当前逐项实施记录见 [`../m11/README.md`](../m11/README.md)。记录中的 `IN_PROGRESS` 不代表 M9/M10 门禁已经通过。

## 推荐迁移顺序

1. 换源和缓存下载。
2. 替换规则、书签和阅读记录。
3. 漫画阅读器。
4. 音频播放。
5. TTS/HTTP TTS。
6. RSS。
7. 内置 Web 服务。
8. 二维码、高级文件管理、分享和非本地书外部打开；基础本地书导入已由 M8.1 完成。
9. 全部设置、主题和图标。
10. AI 与聊天功能。

## 单 Feature 强制流程

### 1. 定义范围

- 写明本次唯一功能、入口和明确不包含项。
- 从功能矩阵领取状态，不创建重复 Feature。

### 2. 盘点 Android

- Activity/Fragment/Screen、Contract、ViewModel。
- XML、菜单、Adapter、Dialog、Sheet。
- Entity、DAO、Repository、UseCase、Model。
- Service、Receiver、权限、Intent 和文件系统。
- 所有入口、状态、操作、副作用和保存行为。

### 3. 设计 Flutter 映射

- 文件、类、方法映射。
- State、Intent、Effect。
- 数据与领域边界。
- 纯 Dart/插件/Kotlin/Swift 分工。
- Android/iOS 差异和降级。

### 4. 分层实现

- Contract。
- 数据/领域。
- ViewModel。
- Stateless Screen。
- 平台桥接。
- 导航接线。

### 5. 双平台验收

- 先由用户验证 Android。
- 修复后由用户验证 iOS。
- 更新功能矩阵、映射和差异文档。

## 注意点

### 后台缓存

- Android 可使用前台 Service；iOS 使用受限后台任务或前台替代。
- 队列状态、暂停、恢复和失败重试应保持 Dart 领域模型一致。

### 音频与 TTS

- 播放队列和章节状态在 Dart。
- Android MediaSession/Service 与 iOS AVAudioSession/Now Playing 仅做平台接入。
- 锁屏控制、耳机按键和音频焦点必须分别验收。

### 漫画

- 大图内存、预加载、缩放、方向和缓存必须独立验收。
- 不复用文本阅读位置模型冒充漫画进度。

### Web 服务

- iOS 后台长期服务器能力受限，必须明确只在前台或局域网可用条件。
- API 与现有 Web 前端兼容性单独建立样本。

### AI/聊天

- 聊天列表保持底部最新消息和反转列表语义。
- 加载历史时保持视口锚点。
- 流式消息更新不应强制打断用户向上查看历史。
- 日志不得输出提示词、密钥和私人聊天正文。

## 交付物

每个 Feature 必须产生：

- [ ] Android 行为清单。
- [ ] 文件/类/方法映射。
- [ ] State/Intent/Effect。
- [ ] 数据与领域实现。
- [ ] Flutter UI。
- [ ] Android 平台实现（需要时）。
- [ ] iOS 平台实现（需要时）。
- [ ] Android 用户验收记录。
- [ ] iOS 用户验收记录。
- [ ] 平台差异更新。
- [ ] 功能矩阵状态更新。

## 完成标准

单个 Feature 完成必须满足：

1. 原 Android 入口和主要行为均有 Flutter 对应。
2. Android 和 iOS 均可使用，或不支持差异已由用户接受。
3. 数据、错误、取消、返回和恢复行为完整。
4. 用户分别确认两平台验收结果。
5. 映射、功能矩阵和差异文档同步更新。

整个 M11 完成必须满足：

1. 功能矩阵不存在未解释的 `NOT_STARTED`、`IN_PROGRESS` 或 `BLOCKED`。
2. 所有 Android 专属能力都有 iOS 替代、unsupported 结果或用户接受说明。
3. 普通规则和 JavaScript 兼容样本长期保持通过。
4. Android/iOS 均能完成所有约定核心用户路径。
5. 用户明确确认整个 Flutter 重写达到目标。

## 阶段退出门禁

- 不以“页面都能打开”代替业务完成。
- 不以“Android 完成”代替双平台完成。
- 不以“有插件”代替插件行为已经验收。
- 不以“无法实现”结束，除非差异已记录并得到用户接受。

## 最终自检

- [ ] 本次只迁移一个明确 Feature。
- [ ] 我完整盘点了 Android 行为和依赖。
- [ ] 文件、类、方法可以双向搜索。
- [ ] UI 使用 State/Intent/Effect 且无业务逻辑。
- [ ] Dart 业务未在 Kotlin/Swift 重复实现。
- [ ] Android 和 iOS 差异有明确处理。
- [ ] IM/聊天反转列表规则在适用时已保留。
- [ ] 无强制空值断言，新增符号有中文注释。
- [ ] 用户完成两平台验收。
- [ ] 功能矩阵、映射和差异文档已更新。
- [ ] AI 没有运行检查或构建。
- [ ] 新增文件已询问是否 `git add`。
