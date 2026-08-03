# 漫画步骤 0：样本与验收基线

状态：`DONE / 用户已确认 Android 原版样本验证无问题并明确通过步骤 0 门禁`

最后静态核对：2026-08-02。本文只根据仓库已有样本和 Android 只读源码冻结输入、观察字段与记录格式，
没有向外部站点发起请求，也没有运行 Android/Flutter 应用、构建、测试、分析或格式化。

## 1. 本步骤目标

在修改类型映射和漫画代码前固定至少两类真实样本：

1. 无需登录即可完成搜索、详情、目录和图片正文的公开基础图片书源。
2. 图片请求需要 Cookie、Referer 或自定义 Header 的受保护图片书源。

每个样本都要记录 Android Legado 的真实输出，后续 Flutter Android 和 Flutter iOS 使用相同输入逐字段对比。
敏感 Cookie、Authorization、账号、Token 和签名参数不得写入仓库。

## 2. 已选基础样本 A：🎨武芊漫画

### 2.1 样本身份

| 字段 | 固定值 |
|---|---|
| 样本编号 | `MANGA-A-PUBLIC` |
| 来源 | 仓库既有 M4 `S10` 图片书源样本 |
| 书源名称 | `🎨武芊漫画` |
| 书源根地址 | `https://comic.mkzcdn.com` |
| 书源类型 | `bookSourceType = 2` |
| 认证预期 | 基础样本按无需登录处理；实际结果由用户运行确认 |

引用位置：`docs/flutter-rewrite/m04/05_collection_validation_samples.md#S10`。

### 2.2 已冻结的规则事实

```json
{
  "bookSourceName": "🎨武芊漫画",
  "bookSourceUrl": "https://comic.mkzcdn.com",
  "bookSourceType": 2,
  "searchUrl": "https://comic.mkzcdn.com/search/keyword/?keyword={{key}}&page_num={{page}}&page_size=20",
  "ruleToc": {
    "chapterList": "$.data",
    "chapterName": "$.title",
    "chapterUrl": "https://comic.mkzcdn.com/chapter/content/?chapter_id={{$.chapter_id}}"
  },
  "ruleContent": {
    "content": "$.data[*].image\n@js:result.split('\\n').map(x=>'<img src=\"'+x+'\">').join('\\n')"
  }
}
```

该片段用于冻结类型、搜索 URL、目录和正文图片转换行为，不冒充可直接导入的完整书源 JSON。
真机验收应使用用户当前实际可导入的完整书源文件。

### 2.3 固定输入

| 输入 | 固定值或规则 |
|---|---|
| 搜索关键字 | `斗罗大陆` |
| 搜索页 | 第 1 页 |
| 目标漫画 | 优先选择书名精确等于 `斗罗大陆` 的第一项；没有精确项时停止并记录，不临时改选其他书 |
| 目标来源 | 必须为 `🎨武芊漫画` |
| 目标章节 | 目录第 1 个非卷标题且能成功取得正文的章节 |
| 图片观察范围 | 目标章节返回的全部图片，至少记录前 3 张和最后 1 张的顺序摘要 |

选择固定关键字的目的不是断言站点当前一定存在该漫画，而是让 Android、Flutter Android 和 Flutter iOS
获得完全相同的输入。若 Android 原版已经无法搜索该词或站点失效，应把结果记为“样本失效”，然后由用户确认
替换样本，不得由实现者静默更换关键字。

### 2.4 Android 必须记录的结果

| 阶段 | 必须记录 | 当前结果 |
|---|---|---|
| 导入 | 完整书源能否导入、导入后是否默认启用 | `PENDING_USER` |
| 搜索 | HTTP/规则是否成功、结果数、精确目标是否存在 | `PENDING_USER` |
| 搜索类型 | `SearchBook.type`，预期为 Android `BookType.image = 64` | `PENDING_USER` |
| 搜索字段 | 目标书名、作者、详情 URL、封面 URL、最新章节 | `PENDING_USER` |
| 详情 | 书名、作者、简介、封面、目录 URL | `PENDING_USER` |
| 目录 | 章节总数、第一章标题、末章标题、目标章节索引 | `PENDING_USER` |
| 正文 | 原始正文是否转换为有序 `<img>` 列表 | `PENDING_USER` |
| 图片顺序 | 图片总数、前 3 张和最后 1 张的脱敏摘要 | `PENDING_USER` |
| 阅读入口 | Android 是否进入 `ReadMangaActivity` | `PENDING_USER` |
| 防盗链 | 图片是否仅需公开请求，或还需要 Referer/Cookie/Header | `PENDING_USER` |

2026-08-02 用户明确反馈已经完成验证、没有问题，并确认通过本步骤门禁。用户未提供可写入仓库的动态字段、
图片数量或请求敏感信息，因此上表保留 `PENDING_USER` 原始记录位，不凭空补造运行数据；步骤完成结论以用户的
明确验收为依据。

图片摘要只记录 URL 的 `scheme + host + path` 不可逆散列或文件名末段，查询参数必须删除，避免把可能的签名
或临时 Token 写入仓库。

## 3. 待补样本 B：受保护图片请求

### 3.1 选择条件

样本 B 必须满足以下至少一项，并能在 Android 原版正常阅读：

- 图片请求缺少章节 Referer 时返回 403 或占位图；
- 图片请求需要书源 Cookie；
- 图片请求需要书源自定义 Header 或特定 User-Agent；
- 图片 URL 带短期签名，但正文刷新后能重新获取有效 URL。

优先使用用户日常使用且可以脱敏提交的图片书源。若完整 JSON 含账号、Cookie、Authorization、Token、
设备标识或私人服务器地址，用户只提供脱敏规则结构和 Android 运行结果，敏感值保留在本机，不进入 Git。

### 3.2 待用户提供

| 字段 | 当前值 |
|---|---|
| 样本编号 | `MANGA-B-PROTECTED` |
| 书源名称 | `PENDING_USER` |
| `bookSourceType` | 预期为 `2`，待确认 |
| 固定搜索关键字 | `PENDING_USER` |
| 固定目标漫画 | `PENDING_USER` |
| 固定目标章节 | `PENDING_USER` |
| 所需请求条件 | `PENDING_USER` |
| Android 阅读结果 | `PENDING_USER` |

## 4. 三端对比记录模板

后续不得用“能打开”代替字段级结论。每个样本按下表补充：

| 检查项 | Android Legado | Flutter Android | Flutter iOS | 差异结论 |
|---|---|---|---|---|
| 搜索成功与结果数 | 待记录 | 代码待验证 | 代码待验证 | 待定 |
| 搜索结果书籍类型 | 待记录 | 代码待验证 | 代码待验证 | 待定 |
| 目标书详情字段 | 待记录 | 代码待验证 | 代码待验证 | 待定 |
| 目录数量与顺序 | 待记录 | 代码待验证 | 代码待验证 | 待定 |
| 目标章图片数量 | 待记录 | 代码待验证 | 代码待验证 | 待定 |
| 图片 URL 顺序摘要 | 待记录 | 代码待验证 | 代码待验证 | 待定 |
| Cookie/Header/Referer | 待记录 | 代码待验证 | 代码待验证 | 待定 |
| 漫画阅读入口 | 待记录 | 代码待验证 | 代码待验证 | 待定 |
| 首张图片显示 | 待记录 | 代码待验证 | 代码待验证 | 待定 |
| 当前图片进度恢复 | 待记录 | 代码待验证 | 代码待验证 | 待定 |

## 5. 用户执行步骤

### 5.1 基础样本 A

1. 在 Android 原版导入当前完整的 `🎨武芊漫画` 书源，不要使用本文的规则片段直接导入。
2. 确认书源类型为图片，并明确记录导入后是否默认启用。
3. 只选择该书源，搜索 `斗罗大陆` 第 1 页。
4. 若存在书名精确结果，打开第一项并记录第 2.4 节字段；若不存在，记录“无精确结果”并停止。
5. 打开目录第一个非卷标题且可读取的章节，记录章节数量、图片数量及顺序摘要。
6. 确认实际进入漫画阅读器，并记录图片是否需要 Cookie、Referer 或额外 Header。

### 5.2 受保护样本 B

1. 选择一个 Android 原版当前可以阅读、且明确依赖 Cookie、Referer 或自定义 Header 的图片书源。
2. 提供脱敏后的书源名称、固定搜索词、目标漫画、目标章节和所需请求条件。
3. 不要发送 Cookie、Authorization、账号密码、Token、签名查询参数或私人服务器地址。

## 6. 当前结论与门禁

已完成：

- [x] 从仓库已有兼容样本中选定公开基础图片书源。
- [x] 冻结基础样本的类型、搜索、目录和正文图片规则事实。
- [x] 冻结基础样本的搜索词、目标选择规则和目标章节选择规则。
- [x] 建立 Android/Flutter Android/Flutter iOS 字段级记录模板。
- [x] 建立敏感请求数据的脱敏边界。

由用户明确验收：

- [x] 用户确认基础样本 Android 原版验证没有问题。
- [x] 用户明确同意通过步骤 0 门禁并进入下一步。

步骤 0 已按用户明确结论完成。受保护图片样本的具体非敏感字段仍可在步骤 5 图片请求实现前补充；这不改变
本次用户已确认的步骤 0 门禁结论，也不代表尚未实现的 Flutter 漫画搜索或阅读已经通过。
