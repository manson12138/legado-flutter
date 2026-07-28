# 书架/历史到阅读器封面全屏转场改造方案

状态：`IMPLEMENTED_PENDING_USER_VERIFICATION / 代码已写入，等待用户真机验收`

最后更新：2026-07-28。

## 1. 用户目标

从书架或阅读历史点击一本书时：

1. 使用被点击书籍在当前 cell 中实际显示的封面；
2. 封面从当前屏幕中的真实位置开始；
3. 封面平滑、较慢地放大并覆盖整个屏幕；
4. 点击后的动画首帧就开始按先快后慢的节奏淡出，200ms 时完全透明；
5. 封面淡出时露出已经在后台准备的阅读界面。

本次替换现有“移动到屏幕中央 + 3D 打开书脊”的进入动画，不修改书架、历史或阅读器业务行为。

## 2. 当前实现与问题

当前调用链：

```text
BookshelfScreen / ReadingHistoryScreen
  -> 点击时生成 ReaderTransitionSpec
  -> BookshelfViewModel / ReadingHistoryViewModel
  -> BookshelfRoute 单飞 pushNamed(/reader)
  -> AppRouter
  -> ReaderPageRoute
  -> BookReaderRoute
  -> ReaderRoute / PdfReaderRoute
```

当前 `ReaderPageRoute` 总时长为 250ms：

- 来源封面先移动到屏幕中央的小尺寸目标矩形；
- 中途以左侧书脊为轴旋转，模拟打开封面；
- 阅读页面从动画中段开始淡入；
- 返回时反向执行相同动画。

它与本次目标存在以下差异：

- 目标不是“拿到中央再打开”，而是“从原位置连续放大到全屏再消失”；
- 250ms 太短，放大、旋转和淡入叠在一起，视觉节奏急促；
- 书架/历史列表模式使用固定偏移和固定宽高估算封面矩形，没有读取封面 RenderBox 的真实位置；
- 返回动画复用进入时保存的旧矩形，阅读期间如果书架排序、进度或可见位置变化，可能缩回错误位置；
- 3D 旋转、阴影和中心目标矩形增加了视觉噪声，并不服务本次交互目标。

## 3. Android 参考结论

原 Android 文本阅读入口通过 `startActivityForBook` 进入阅读路由，没有书架封面到文本阅读器的等价
共享元素动画。Android Compose 的 `CoilBookCover` 共享元素目前主要用于书籍详情等页面，不能直接作为
本次 Flutter 阅读入口的行为基准。

因此本次属于用户明确指定的 Flutter 视觉交互改造：

- 保持打开书籍、参数传递、进度恢复和返回行为不变；
- 只替换 Flutter 路由动画；
- 不修改只读 Android 参考仓库。

## 4. 最终动画规格

### 4.1 进入动画

书架和历史的列表、网格入口统一使用最长 300ms 动画：

| 时间 | 画面行为 |
|---|---|
| `0～200ms` | 封面从真实 cell 位置放大的同时立即按先快后慢节奏变淡；阅读页从首帧开始在封面下方同步显现 |
| `200～300ms` | 临时封面层已经移除，只保留完整阅读页面直到路由动画结束 |

具体规则：

- 总时长固定不超过 300ms，不再设置全屏停留阶段；
- 放大曲线继续使用 `Curves.easeOutCubic`，淡出期间仍平滑完成剩余几何变化；
- 淡出从总进度 `0`、即点击后的动画首帧开始，到总进度 `2/3`、即约 `200ms`
  完全透明并移除临时封面层；
- 2026-07-28 真机反馈显示 `Curves.easeInOutCubic` 把透明变化过多集中在后半段，肉眼仍接近末段突然消失；
  书架与历史入口当前按用户反馈改为 `Curves.easeOut`，让 `0～200ms` 的透明变化先快后慢，
  末段平缓归零；详情和兼容入口继续保留各自原有曲线；
- 目标矩形为当前阅读路由完整 viewport，覆盖系统栏所在的 edge-to-edge 区域；
- 封面内容使用 `BoxFit.cover`，保持图片比例，通过逐步裁切填满屏幕，不做非等比拉伸；
- 阅读页面从路由创建时就正常构建和准备，并从动画首帧开始随封面淡出逐步显现；
- 不为了凑动画时长等待网络；动画结束时按真实状态显示正文、首次先导页、恢复页或错误页。

### 4.2 起点测量

点击书架或历史中的任意书籍时，只把以下短生命周期数据传给路由：

- 单次点击 ID；
- 入口类型；
- 封面 URL；
- 点击瞬间封面 RenderBox 转换得到的全局 `Rect`。

列表和网格都应读取封面 Widget 的真实 RenderBox，不再使用 `tileOrigin + 固定偏移` 估算。测量只发生在
用户点击时，不在滚动帧中持续计算，不把 `BuildContext`、`RenderObject`、`GlobalKey` 或 Widget
传入路由。

如果点击时封面已经离屏、RenderBox 未挂载、尺寸无效或坐标超出 viewport：

- 使用屏幕中心的小封面矩形作为受控降级起点；
- 仍执行“放大到全屏后淡出”，不回退到旧 3D 动画。

### 4.3 来源页面与重复封面

路由动画使用同一封面 URL 创建独立封面隔离层。为避免隔离层离开 cell 后，原 cell 封面在后方形成明显
“第二本书”：

- 阅读页背景遮罩在动画前段随封面移动平滑显现；
- 遮罩只隐藏来源页面，不使用全屏截图或实时模糊；
- 封面隔离层始终位于遮罩和阅读页之上；
- 阅读页放在最底层并使用稳定 `RepaintBoundary`，动画帧不触发整页重建。

同一本书可以同时存在于书架和历史 PageView；继续使用每次点击生成的独立 ID，不用 `bookUrl` 作为全局
Hero Tag，避免重复 Tag。

### 4.4 返回动画

本次只把“书架/历史进入阅读器”改为封面全屏动画。返回时不反向缩回旧 cell：

- 使用约 200ms 的阅读页淡出，直接露出仍由 Navigator 保留的书架或历史页面；
- 不复用可能已经失效的旧 cell 位置；
- 不影响现有“保存进度后关闭”的单飞链路；
- 不创建或长期持有来源 cell 的 Key、Context 或元素引用。

如果以后确实需要反向缩回 cell，必须增加返回瞬间重新测量可见来源 cell 的独立协议，不能直接复用进入
时的旧矩形。

### 4.5 入口范围

- 书架列表：使用真实 leading 封面位置；
- 书架网格：使用真实封面区域；
- 历史列表：使用真实 leading 封面位置；
- 历史网格：使用真实封面区域；
- 文本书和 PDF：都使用相同封面放大动画，不再因 PDF 禁用 3D 后走另一套视觉；
- 书籍详情入口：本次不改变，继续使用轻量详情到阅读器转场；
- 旧字符串路由和缺少来源几何的入口：使用中心起点的全屏放大降级；
- 系统开启“减少动态效果”时：取消位移、缩放和停留，使用约 150ms 淡入淡出。

## 5. 实现边界

### 5.1 保留

- `ReaderTransitionSpec` 继续只保存不可变短生命周期视觉参数；
- 书架和历史仍通过 Intent、Effect 和 Route 打开阅读器；
- `_openingReader` 导航单飞保持不变；
- `Book`、目录、成员状态和阅读入口枚举继续复用现有参数；
- 正文预热、处理后正文 LRU、首次先导页、恢复页和错误页保持不变；
- 阅读进度保存、阅读历史写入、匿名事件和 PDF 分流保持不变。

### 5.2 移除或替换

- 移除书架/历史入口的中心封面目标矩形；
- 移除书架/历史入口的 3D 书脊旋转；
- 移除对应的开书阴影计算；
- 替换 250ms 进入时序；
- 替换列表模式的固定封面坐标估算；
- 返回时不再反向播放封面动画。

### 5.3 不包含

- 不修改书架或历史 cell 布局；
- 不修改书籍详情页转场；
- 不修改阅读器内部翻页动画；
- 不改变路由、数据库 Schema、MMKV key、缓存身份或 `pubspec.yaml` 版本；
- 不引入第三方动画依赖；
- 不制作全屏或长页面位图快照；
- 正式功能不保留逐帧日志；2026-07-28 按用户要求临时加入统一 Tag 性能采样，
  待用户提供证据并完成分析后按 `FLUTTER_REWRITE_DEBUG_LOG` 标识完整移除。

## 6. 性能与内存约束

- 每帧只更新封面隔离层的矩形、裁剪圆角、遮罩透明度和封面透明度；
- 阅读页作为 `AnimatedBuilder.child` 和 `RepaintBoundary` 复用，不在动画帧重新构建正文；
- 封面隔离层复用 `BookCover` 及现有图片缓存，不主动重新下载；
- 不在动画期间执行 SQLite/MMKV 写入、正文解析、复杂正则、分页或批量章节转换；
- 不使用实时模糊、BackdropFilter、全屏截图或持续图片采样；
- 不创建独立长期 `AnimationController`，优先复用路由提供的 animation；
- 路由释放后不保留 cell Context、RenderObject、图片监听或 Overlay；
- 快速重复点击继续由现有导航单飞拒绝，避免多层全屏封面和多条阅读任务；
- 屏幕旋转、窗口尺寸变化或来源矩形失效时使用中心降级，不让旧尺寸导致越界。

## 7. 预计修改文件

代码：

- `lib/src/app/reader_transition_spec.dart`
- `lib/src/app/app_router.dart`
- `lib/src/ui/components/book_cover.dart`
- `lib/src/ui/bookshelf/bookshelf_screen.dart`
- `lib/src/ui/bookshelf/reading_history_screen.dart`
- `lib/src/ui/bookshelf/bookshelf_route.dart`
- `lib/src/ui/reader/reader_page_route.dart`

实施记录：

- `docs/flutter-rewrite/m11/mmkv_and_reader_entry_loading_optimization_plan.md`
- `docs/flutter-rewrite/m11/README.md`
- `docs/flutter-rewrite/m08/README.md`
- `docs/flutter-rewrite/AI_PROJECT_INDEX.md`

预计不新增 Dart 文件，不改变数据库或平台桥接。

## 8. 人工验收

1. 书架列表点击任意一行，确认动画从该行真实封面开始，而不是从点击文字位置或屏幕中心开始。
2. 书架网格分别点击屏幕左上、右上和底部可见封面，确认每本书都从自身 cell 连续放大。
3. 历史列表和网格重复以上操作，确认起点准确。
4. 确认封面从点击后的动画首帧就开始按先快后慢节奏淡出，50ms、100ms、150ms 附近能够逐步
   看见更多正文，并在 200ms 时完全透明；没有末段突变、旧 3D 翻开、中心停靠或闪白。
5. 确认放大过程不非等比拉伸封面，屏幕比例差异通过 `BoxFit.cover` 平滑裁切。
6. 封面淡出后确认正文、首次先导页、恢复页和错误页仍按真实加载状态展示。
7. 分别打开文本书、TXT/EPUB 和 PDF，确认入口动画一致，目标阅读页面分流不变。
8. 在动画期间快速重复点击，确认只打开一个阅读器。
9. 进入阅读器后返回，确认约 200ms 淡出回到原书架/历史页面，不缩回错误 cell。
10. 打开阅读器期间让书架数据发生进度或排序变化后返回，确认没有飞向旧位置。
11. 开启系统“减少动态效果”，确认只执行短淡入淡出。
12. 在 Android/iOS 真机及宽屏窗口观察动画帧率，确认没有明显卡顿、封面重复解码或内存持续增长。

## 9. 2026-07-28 实施快照

- `ReaderPageRoute` 进入时长改为 300ms，返回时长改为 200ms；
- 书架/历史进入时移除中心停靠、3D 书脊旋转和反向缩回旧 cell；
- 封面从动画首帧开始按先快后慢节奏淡出的同时放大，并在 200ms 时完全透明；
  阅读页也从首帧开始在封面下方逐步显现，剩余约 100ms 只展示完整阅读页面；
- 书架与历史的列表、网格都在点击时读取封面 RenderBox 的真实全局矩形，失效时中心降级；
- 文本书、PDF 和旧兼容入口共用全屏封面放大；详情入口继续保留轻量中心转场；
- 系统减少动态效果时继续使用约 150ms 淡入淡出；
- 返回只让阅读页约 200ms 淡出，不复用进入时保存的旧 cell 位置；
- 临时性能日志使用统一 Tag `READER_COVER_TRANSITION` 和统一标识
  `FLUTTER_REWRITE_DEBUG_LOG`，不记录书籍、封面地址、文件路径或正文；
- 未运行格式化、分析、测试、构建或应用启动，以上实现等待用户真机验收。

只有用户真机确认本方案第 8 节结果后，才能记录通过。

## 10. 2026-07-28 首次打开卡顿静态分析

本节只记录静态调用链结论，没有运行 Flutter DevTools、Profile 构建、性能覆盖层、测试或应用。
当前能确认和需要真机取证的热点如下。

### 10.1 已确认的 Dart UI isolate 同步热点

全屏封面层位于 `ReaderPageRoute._buildFullScreenCoverTransition` 的 `AnimatedBuilder.builder` 内，
路由动画每一帧都会重新构建该 `BookCover`。网络封面路径随后进入：

```text
ReaderPageRoute AnimatedBuilder 每帧
  -> BookCover.build
  -> MediaCacheDownloader.lookupCachedFileSync
  -> SHA-256 文件名计算
  -> File.existsSync
```

缓存文件尚未命中时，`BookCover.build` 还会调用异步 `resolve`；`resolve` 的入口会再次执行一次
`lookupCachedFileSync`。下载本身是异步的，但哈希和 `File.existsSync` 明确发生在 Dart UI isolate，
不应位于 300ms 路由动画的逐帧构建路径中。这是当前最直接、最符合“第一次打开更明显”的主线程卡顿候选。

### 10.2 首次打开更容易出现的图片解码切换

书架 cell 可能先使用 `Image.network` 显示封面，并在后台把文件写入本地缓存。点击时转场层重新创建
`BookCover`，如果此时本地文件已经存在，就会改用 `Image.file`。网络图片与文件图片是不同
`ImageProvider` 缓存身份，即使内容相同，转场层也可能在动画期间重新读取和解码图片。首次解码主要涉及
I/O 与图片解码/栅格线程，但会直接造成动画丢帧；后续打开命中已经解码的图片缓存时通常会减轻。

当前没有在书架点击后、路由动画开始前对转场层实际使用的 `ImageProvider` 做固定或预解码，也没有把
cell 已经解析成功的图片提供者交给隔离层复用。

### 10.3 其余可能叠加的布局与栅格压力

- 转场每帧使用 `Positioned.fromRect` 改变位置和尺寸，并连续改变 `ClipRRect` 圆角，会触发布局和裁剪；
- 封面与复杂阅读页面在约 0～200ms 期间通过两个全屏 `Opacity` 层交叉显示，可能产生额外离屏合成；
- 阅读页面虽然作为 `AnimatedBuilder.child` 避免了由动画本身重复创建，但首次路由仍会在动画期间完成
  `ReaderRoute`、先导页/恢复壳和后续正文状态的首次 build/layout；
- 目录、锚点和进度读取返回后会在动画期间发射阅读状态；随后 `SystemChrome`、Android 窗口常亮/
  亮度和方向调用也可能改变窗口或系统栏状态。它们是异步平台调用，不是已确认的 Dart 同步阻塞，
  但时间上可能与首次 300ms 转场重叠；
- 把淡出提前到动画首帧不会制造上述同步 I/O，但会更早露出仍在首次布局的阅读页面，因此若底层首帧
  尚未稳定，视觉上可能更容易观察到掉帧。

### 10.4 已排除的主要误判

- 书架/历史入口已经携带 `initialBook`，正常新入口不会先串行查询书籍事实；
- SQLite 目录、锚点和进度通过 Future 并行发起，不是在路由创建回调中同步读取整个数据库；
- 文件日志写入使用异步串行队列，入口日志调用本身不等待文件落盘；
- 封面网络下载使用异步 Dio，并有同 URL 的在途请求去重；真正明确留在逐帧主线程上的部分是同步
  文件命中判断和哈希计算。

### 10.5 后续修复优先级与取证

若用户确认继续修复，建议按以下顺序实施：

1. P0：让转场封面 Widget/ImageProvider 在动画外只解析一次，移除逐帧
   `lookupCachedFileSync`、哈希和重复 `resolve`；
2. P0：点击时固定与 cell 相同的图片提供者，或在 push 前完成一次受控 `precacheImage`，避免
   `Image.network` 到 `Image.file` 的首次解码切换；
3. P1：把矩形变化改为合成层友好的 Transform/裁剪方案，并评估是否能减少全屏双 Opacity；
4. P1：把阅读系统栏/窗口配置延后到进入动画结束或首帧稳定点，前提是不破坏沉浸模式语义；
5. 用户在 Profile 模式分别采集首次与第二次打开同一本书的 UI/Raster 帧、图片解码事件和平台通道
   时间线，用实际 trace 确认 P0 顺序。

## 11. 2026-07-28 临时转场诊断日志

用户要求先加入日志并在真机复现后回传。本轮所有日志统一使用：

```text
Tag: READER_COVER_TRANSITION
Marker: FLUTTER_REWRITE_DEBUG_LOG
```

日志事件：

| `event` | 含义 |
|---|---|
| `navigation_push` | 书架/历史 Route 开始执行 `pushNamed` |
| `route_created` | `AppRouter` 完成阅读参数归一化并创建 `ReaderPageRoute` |
| `start` | 转场 State 开始监听进入动画和 `FrameTiming` |
| `geometry` | 首次有效 viewport、来源矩形尺寸及是否中心降级 |
| `first_cache_lookup` | 转场封面第一次同步本地缓存检查耗时与命中状态；`resolve` 入口的第二次检查仍由静态调用链判断 |
| `cache_source_changed` | 动画中网络提供者和本地文件提供者发生切换 |
| `cover_first_image_frame` | 转场封面首次交付图片帧的相对时间，以及是否同步命中 Flutter 已解码图片缓存 |
| `slow_frame` | build、raster 或总跨度任一达到 16ms 的异常帧；8ms 以上帧仍进入汇总计数以兼顾 120Hz 屏幕 |
| `animation_completed` | 300ms 动画状态已经完成 |
| `summary` | 动画加 200ms 尾帧窗口的最大耗时、慢帧和缓存检查汇总 |

为了避免诊断本身放大卡顿：

- 8ms 以上帧进入汇总计数，只有达到 16ms 才逐条记录，减少日志本身对动画的干扰；
- 封面同步缓存检查每帧只累计，除第一次命中和来源切换外不逐条写日志；
- `FrameTiming` 在动画完成后仅保留 200ms 接收尾帧，然后自动移除；
- 日志不输出书名、书籍 URL、封面 URL、绝对路径、正文或账号信息；
- 详情入口、兼容入口和返回动画不采集本组日志。

用户复现步骤：

1. 冷启动 App，先打开此前本次进程没有进入过的一本书；
2. 返回书架，再次打开同一本书；
3. 如历史页也会卡顿，再从历史页打开一次；
4. 导出或筛选全部 `READER_COVER_TRANSITION` 行，保留每个 `transitionId` 从
   `navigation_push` 到 `summary` 的完整事件顺序后发回分析。
