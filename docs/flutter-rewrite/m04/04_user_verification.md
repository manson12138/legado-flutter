# M4 用户验证步骤

AI 未执行以下命令或脚本。

## 依赖与静态检查

1. `cd flutter_app`
2. `flutter pub get`
3. `flutter analyze`

## 引擎门禁

1. Android 与 iOS 真机分别执行 JSON、Regex、Date、BigInt、TypedArray、Promise 和异常栈样本。
2. 执行 `while (true) {}`，确认约 5 秒内被原生 interrupt handler 终止。
3. 使用极大数组触发 64 MiB 限制，确认分类为内存错误且 App 不崩溃。
4. 执行深递归触发 1 MiB 栈限制，确认分类为栈溢出。
5. 执行中调用 `JsCancellationController.cancel()`，记录 Android/iOS 实际中断时间。
6. 连续创建、执行并关闭 100 个实例，检查内存是否回落。

## API 门禁

1. 验证 `source/book/chapter/result` 字段与 Java getter 形式。
2. 验证 `undefined`、`null` 和数组空洞没有合并。
3. 验证 MD5、Base64、Hex、URI、UUID 与 Android 结果一致。
4. 验证 cache 与 cookie 复用现有数据库和统一 Cookie 管理器。
5. 调用未支持 Java 类，确认错误包含类名和方法名。
6. 验证错误与日志不包含 Authorization、Cookie、登录信息或正文。

## 真实书源门禁

分类样本见 `05_collection_validation_samples.md`，完整核心 JSON 位于 `samples/`。依次导入 S2～S5，统一搜索“斗破苍穹”，只接受标题完全匹配的结果并验证第一章免费正文。随后分别记录搜索、详情、目录、正文结果；没有完全匹配结果时记录 `BLOCKED`，不要临时更换书籍。若后续脚本包含登录信息，只通过本地不提交文件提供。

所有门禁有结果后，才能把 M4 从 `BLOCKED` 更新为 `IN_PROGRESS` 或 `ANDROID_READY`。
