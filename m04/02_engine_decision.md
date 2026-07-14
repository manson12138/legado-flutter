# M4 引擎候选与临时决策

## 候选对比

| 候选 | Android/iOS 引擎 | Dart 桥 | 超时/资源限制 | 主要风险 | 结论 |
|---|---|---|---|---|---|
| JSF 1.1.0 | 原生平台均为 QuickJS；Web 另有实现 | 同步回调、Future/Promise、结构化值和句柄 | QuickJS interrupt timeout、内存和栈限制 | 1.0 API 很新，需本项目真机构建和回归 | M4 临时选择 |
| quickjs_engine 0.1.1 | QuickJS-NG 0.14.0 全平台统一 | flutter_js 兼容 message channel | 文档未给出同等完整的硬限制 API | 包很新、使用量低 | 保留候选 |
| flutter_js 0.8.7 | Android QuickJS，iOS JavaScriptCore | 成熟 message channel、Promise | 有内存泄漏修复，但平台语义分叉 | 不满足优先同一引擎目标 | 不选 |
| FJS 3.0.0 | Rust + QuickJS，Android/iOS 支持 | 类型化异步桥 | 超时、取消、内存和栈错误模型较完整 | Rust/native 体积与 iOS 模拟器限制需验证 | 第二候选 |

## 临时决策

选择 `jsf: ^1.1.0` 建立原型，原因：

- Android/iOS 可采用同一 QuickJS 语义。
- 原生 interrupt handler 能表达硬超时，不只是在 Dart Future 外层超时。
- 提供内存、栈、Promise/Future、回调和结构化值转换。
- `JsEngine` 隔离了具体包，若真机验证失败可以替换为 FJS 或其他 QuickJS 适配器。

该选择不是最终通过结论。以下数据必须由用户构建后补录：Android 四 ABI、R8、iOS 真机、APK/IPA 增量、冷启动耗时、64 MiB 限制下峰值、无限循环中断时间和关闭后的内存回收。

## 生命周期与隔离

- 一个引擎实例只属于一个书源，不跨不可信书源复用。
- 同一实例串行执行，不允许并发进入。
- 同书源可复用 jsLib Scope，执行失败后销毁污染实例。
- 每个书源最多保留一个空闲实例。
- 关闭服务时释放全部运行时；编译句柄单独关闭。
- 默认脚本 5 秒、64 MiB 内存、1 MiB 栈；调用方可以缩短单次超时。

## 已知语义差异

- Rhino Java getter/setter 自动映射由 DTO Proxy 模拟，只覆盖第一批字段。
- QuickJS 的标准语法和 Rhino 1.8.0 不完全相同。
- Android 同步网络 API 在 Dart 中成为 Promise，这是当前最高风险差异。
- `undefined`、`null`、数组空洞分别映射，不合并。
- `Date`、`RegExp`、BigInt、TypedArray 与异常栈需固定样本比较。

