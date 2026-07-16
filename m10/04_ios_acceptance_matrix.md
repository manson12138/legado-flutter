# M10 iOS 第一批核心验收矩阵

目标环境：iPhone 15 Pro Max、iOS 26、用户自用签名安装。

状态只允许填写：`NOT_STARTED`、`PASS`、`FAIL`、`BLOCKED`、`NOT_APPLICABLE`。

## 与 Android 相同的 15 步核心路径

| 编号 | 用户动作 | 预期 | 实际 | 状态 |
|---|---|---|---|---|
| N01 | 全新安装并启动 | 不读取原 Android 数据，无启动崩溃 | 待填写 | NOT_STARTED |
| N02 | 导入 S1 普通书源 | 列表显示且不进入 JS | 待填写 | NOT_STARTED |
| N03 | 导入 S2/S3 JavaScript 书源 | 可导入，脚本错误可诊断 | 待填写 | BLOCKED |
| N04 | 停用、编辑、重新启用 | 状态持久化 | 待填写 | NOT_STARTED |
| N05 | 搜索目标书籍 | 增量结果和单源错误同时可见 | 待填写 | NOT_STARTED |
| N06 | 打开详情 | 字段、相对 URL 与来源正确 | 待填写 | NOT_STARTED |
| N07 | 获取目录 | 顺序、分页、去重正确 | 待填写 | NOT_STARTED |
| N08 | 加入书架 | 事务成功且立即显示 | 待填写 | NOT_STARTED |
| N09 | 从书架打开阅读器 | 当前章节正文非空 | 待填写 | NOT_STARTED |
| N10 | 切换章节 | 快速操作不串章 | 待填写 | NOT_STARTED |
| N11 | 修改字号、行距和颜色 | 立即重排且稳定锚点不丢 | 待填写 | NOT_STARTED |
| N12 | 添加书签并目录跳转 | 跳转和持久化正确 | 待填写 | NOT_STARTED |
| N13 | 退出到书架并关闭 App | 当前稳定进度保存 | 待填写 | NOT_STARTED |
| N14 | 杀进程后重新启动 | 书架、章节和接近原位置恢复 | 待填写 | NOT_STARTED |
| N15 | 前后台、旋转、键盘和返回手势 | Safe Area/Home Indicator 无遮挡，返回一致 | 待填写 | NOT_STARTED |

## 文件、二维码、WebView 与资源

| 编号 | 用户动作 | 预期 | 实际 | 状态 |
|---|---|---|---|---|
| P01 | 选择书源文件后取消/成功 | 取消无写入，成功显示确认 | 待填写 | NOT_STARTED |
| P02 | 导入本地 TXT/EPUB/UMD/PDF | 私有副本可重启阅读 | 待填写 | NOT_STARTED |
| P03 | 相机允许、拒绝、设置后恢复 | 扫码可用；拒绝有替代路径 | 待填写 | NOT_STARTED |
| P04 | 登录页输入、验证码、重定向 | WKWebView 可操作且 Cookie 回写 | 待填写 | NOT_STARTED |
| P05 | WebView 页面脚本超时/取消 | 明确错误并释放页面资源 | 待填写 | NOT_STARTED |
| P06 | 连续阅读 30 分钟并切章/翻页 | 无持续内存增长、句柄泄漏或崩溃 | 待填写 | NOT_STARTED |
| P07 | 后台停留后回前台 | 页面与阅读位置可恢复，常亮状态正确 | 待填写 | NOT_STARTED |

用户完成全部非 `NOT_APPLICABLE` 项、关闭 P0/P1、确认 JavaScript 差异并明确回复“iOS 第一批可用”后，M10 才能从 `IN_PROGRESS` 更新为 `IOS_READY/DONE`。
