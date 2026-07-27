# M8 仿真翻页 Android 差距分析与修正建议

> 文档状态：`IN_PROGRESS / 日志确认后的页背介质与阴影同构修正已写入，等待用户真机验证`  
> 分析日期：2026-07-27  
> Android 只读参考仓库：`F:\code\legado-with-MD3`

## 1. 本次唯一目标

仔细对照本地 Android 仿真翻页实现与当前 Flutter 实现，解释 Flutter 动画手感和视觉质量明显
弱于 Android 的具体原因，并给出可分阶段执行、兼顾性能和内存的修正范围。

第一阶段已按用户确认写入 Flutter UI 代码，不修改 Android 参考工程，不运行构建、测试、分析、
格式化或应用。实现结果仍须由用户真机验证，不能据此标记完成。

本次不包含：

- 修改只读 Android 参考仓库；
- 调整正文分页、稳定字符锚点、书签、选区或书源业务；
- 修改数据库 Schema、版本号、路由或平台通道；
- 引入第三方翻页库；
- 在没有用户确认前直接开始重写动画。

## 2. 本地仓库和关键文件

Flutter 工程位于：

`F:\code\legado-flutter`

名称包含 `legado` 的 Android 参考工程位于：

`F:\code\legado-with-MD3`

Android 关键调用链：

```text
ReadView.onTouchEvent
  -> HorizontalPageDelegate.onTouch / onScroll
  -> SimulationPageDelegate.setDirection
  -> SimulationPageDelegate.calcCornerXY
  -> SimulationPageDelegate.calcPoints
  -> SimulationPageDelegate.onDraw
  -> PageDelegate.startScroll / computeScroll
  -> SimulationPageDelegate.onAnimStop
  -> ReadView.fillPage
```

Android 关键文件：

- `app/src/main/java/io/legado/app/ui/book/read/page/ReadView.kt`
- `app/src/main/java/io/legado/app/ui/book/read/page/delegate/PageDelegate.kt`
- `app/src/main/java/io/legado/app/ui/book/read/page/delegate/HorizontalPageDelegate.kt`
- `app/src/main/java/io/legado/app/ui/book/read/page/delegate/SimulationPageDelegate.kt`
- `app/src/main/java/io/legado/app/ui/book/read/page/provider/TextPageFactory.kt`

Flutter 关键调用链：

```text
ReaderPagedContent GestureDetector
  -> _handleHorizontalDragStart / Update / End
  -> _coverController
  -> _buildSimulationPager
  -> ReaderSimulationPageTurnFrame
  -> _ReaderSimulationGeometry.calculate
  -> ClipPath / Transform / _ReaderSimulationShadowPainter
```

Flutter 关键文件：

- `lib/src/ui/reader/reader_page_layout.dart`
- `lib/src/ui/reader/reader_simulation_page_turn.dart`
- `lib/src/ui/reader/reader_screen.dart`

## 3. 结论

当前 Flutter 不是 Android `SimulationPageDelegate` 的等价呈现。它复用了部分贝塞尔控制点公式，
但把 Android 的“二维真实触点驱动卷页”简化成了“横向进度 + 一个固定纵向比例”，同时简化了
上一页拓扑、页背反射轴、松手轨迹和四组阴影。

视觉差的首要原因不是正文分页，而是以下 P0 差距叠加：

1. 横坐标不跟真实手指，只由动画进度合成；
2. 松手完成或回弹时纵坐标被冻结，卷角不会向目标页角自然收束；
3. 上一页使用了 Android 没有采用的水平镜像；
4. 页背绕错了平行但不同位置的轴反射；
5. Android 四组有方向和裁剪范围的阴影被压缩成一组水平渐变和一条直线；
6. 固定 250ms 动画和 22%/速度阈值改变了 Android 的距离时长与取消语义。

因此，继续微调颜色、阴影透明度或 `1.28` 进度系数不能根治问题。需要先把输入状态从
`progress + touchYRatio` 改回 Android 同类的 `touch Offset + fixed corner + release target`。

## 4. 逐项差距

| 优先级 | 维度 | Android 行为 | 当前 Flutter 行为 | 用户可见后果 |
|---|---|---|---|---|
| P0 | 横向触点 | `calcPoints()` 每帧直接消费 `ReadView.touchX/touchY` | `touchX = width - width * 1.28 * progress`，没有消费真实手指横坐标 | 卷角会从预设轨迹出现，不能真正贴住手指；不同起手位置手感近似相同 |
| P0 | 松手二维轨迹 | `Scroller` 同时计算 `dx`、`dy`，完成和取消都会把触点带向对应页角或屏外终点 | `AnimationController` 只继续改变进度，最后一次手势的 `touchYRatio` 保持不变 | 完成和回弹末段折痕形状不收束，接近末帧时容易突然切页 |
| P0 | 上一页几何 | `PREV` 固定使用右下方向，以触点从左向右运动形成上一页展开；没有把整套几何水平镜像 | `direction < 0` 时同时执行时间反演和水平镜像 | 上一页的卷入侧、页背运动和 Android 不一致 |
| P0 | 页角选择 | 下一页按起手位置大体以上下半屏选择右上/右下；上一页强制右下，且中部手势会把触点 Y 拉到安全边缘 | 下一页只有 `touchYRatio < 1/3` 才使用上角；上一页固定走镜像后的左下 | 页面上半部中段会选错页角，上一页拓扑也不一致 |
| P0 | 页背反射轴 | 反射矩阵沿 `mBezierControl1 -> mBezierControl2` 直线，并以控制点平移定位 | 沿 `start1 -> start2` 直线反射 | 两条线虽然平行，但位置不同；页背内容会相对折痕发生位移 |
| P0 | 阴影模型 | 分别绘制目标页阴影、卷起页两段前景阴影和页背折叠阴影，共四个按角度旋转、按路径裁剪的渐变 | 只在 `foldPath` 内绘制一个以水平方向为主的宽渐变，再画一条直折线 | 卷页缺少前后厚度、曲面方向和纸张层次，观感更像异形遮罩 |
| P0 | 方向锁定 | 超过触摸松弛值后确定 `PREV/NEXT`，同一次手势不再切换目标页；反向移动只改变 `isCancel` | 每帧按累计距离正负重新计算方向，跨过起点可直接换成相反目标页 | 手指犹豫或回拉穿过起点时目标页可能跳变 |
| P0 | 完成/取消 | Android 根据松手前最后运动方向设置 `isCancel`，然后沿剩余二维距离收尾 | Flutter 使用宽度 22% 或 500 logical px/s 阈值 | 短距离有效拖动和回拉取消的手感与 Android 明显不同 |
| P0 | 动画时长 | 基准 300ms，再按剩余 `dx/width` 或 `dy/height` 比例计算，插值为线性 | 统一 `DurationToken.medium = 250ms`，控制器按剩余进度运行 | 长距离完成偏快，短距离与长距离缺少 Android 的距离感 |
| P1 | 程序化翻页 | 下一页从约 `(0.9w, 0.9h/1)` 起步并移动到屏外；上一页从 `(0,h)` 向右展开 | 点击/音量键复用默认 `touchYRatio`，横向终点由固定 `1.28w` 系数生成 | 点击翻页和音量键动画轨迹也与 Android 不一致 |
| P1 | 跨章节拖动 | `TextPageFactory` 可直接提供当前页、前页和后页，相邻章节已准备时可作为同一次拖动的目标页 | 到章边界时当前手势没有目标页；松手后先发切章 Intent，加载完成再播放固定卷页 | 章内跟手和跨章切换是两种明显不同的手感 |
| P1 | 页面介质 | Android 在方向确定时把当前/目标 `PageView` 截成临时 Bitmap，动画每帧只画位图和 Path | Flutter 同时放置目标页、当前页正面和反射页背的 Widget/合成层 | Flutter 没有长期位图内存，但同一正文正面和页背不是一个共享快照，合成成本和帧稳定性需真机验证 |
| P1 | 降级策略 | Android 始终使用同一套卷页几何 | Flutter 遇到无效几何时单帧退回整页覆盖 | 极端点可能出现卷页与覆盖动画之间的形态跳变 |

## 5. 当前 Flutter 几何中最关键的三个错误

### 5.1 固定纵坐标导致收尾跳变

Flutter 在拖动期间更新 `_simulationTouchYRatio`，但手指松开后只让 `_coverController` 从当前值
继续到 `1` 或退回 `0`。`ReaderSimulationPageTurnFrame` 每帧重新计算的 `touchY` 始终是最后一个
纵向比例，没有像 Android 一样随 `dy` 到达页角。

这会导致：

- 完成时折痕没有逐渐离开屏幕；
- 回弹时触点横向回到页角，纵向却仍停在手指松开位置；
- `progress >= 0.999` 直接返回目标页，掩盖了退化几何，但产生肉眼可见的末帧切换。

### 5.2 页背反射轴位置错误

Android 反射矩阵的方向向量来自：

```text
(cornerX - control1.x, control2.y - cornerY)
```

这等价于沿 `control1 -> control2` 的直线反射，并以 `control1` 为基准平移。

Flutter 使用 `start1 -> start2`。该线与控制点连线平行，但不重合，所以方向看起来接近，
页背内容的位置却不等价。这会使文字页背与实际折痕不贴合。

### 5.3 阴影不是 Android 的简化等价物

Android 阴影宽度和方向分别依赖：

- 触点到页角距离；
- 两条贝塞尔控制边；
- `mIsRtOrLb` 对应的角方向；
- 前景区、目标页区和页背区的不同裁剪 Path。

Flutter 的渐变只依据整个 `foldPath` 的包围矩形，并主要按左右方向渐变。它没有表达两条曲线
各自的法线方向，也没有在当前页正面外侧和目标页区域分别塑造阴影，因此页面缺少“弯曲纸张”
的体积感。

## 6. 建议实施范围

### 6.1 第一阶段：单章内 Android 同构手感，已写入待验证

实际修改：

- `lib/src/ui/reader/reader_simulation_page_turn.dart`
- `lib/src/ui/reader/reader_page_layout.dart`
- `lib/src/ui/reader/reader_screen.dart`：仅适配跨章节现有程序化仿真帧的新二维触点接口，
  未扩大相邻章节状态模型
- 对应 M8 文档和项目索引

实施内容：

1. 把仿真帧输入从 `progress + touchYRatio + mirror` 改成真实 `touch Offset + corner`。
2. 手势超过松弛值后锁定方向；同一次手势回拉只切换完成/取消状态，不更换目标页。
3. 保存起手点、当前触点、松手触点和动画终点，完成/回弹时同时插值 X、Y。
4. 下一页固定右侧页角并按起手上下半屏选择上/下角；上一页固定右下角，不水平镜像。
5. 页背改为沿 `control1 -> control2` 反射。
6. 按 Android 四组阴影职责重建有限渐变，并使用各自 Path 裁剪和旋转角度。
7. 程序化下一页和上一页使用 Android 同类起点与终点。
8. 收尾时长按剩余二维距离和 300ms 基准计算，使用线性曲线。
9. 保留现有选区保护、分页结果延迟应用、稳定字符锚点和动画单飞。
10. 无效几何优先钳制真实触点；只有整段动画无法安全计算时才稳定降级，避免逐帧来回切换。

这一阶段不需要修改 ViewModel、数据库、平台桥或相邻章节正文状态，风险和回归面最小。

### 6.2 第二阶段：跨章节同一次手势跟手，已写入待验证

当前 Flutter UI 只有当前章节分页结果。要达到 Android `TextPageFactory` 在章末直接提供
`nextPage/prevPage` 的行为，需要让阅读器呈现层能取得已预加载相邻章节的第一页或末页。

实际修改：

- `ReadBookCoordinator.preloadAdjacent` 在每个有效预加载结果完成时回调章节索引和处理后正文；
- `ReaderUiState` 只持有最接近的上一章、下一章两个只读正文快照，并在切章、配置变化和内存
  压力时清理；
- 下一章只额外测量首屏；上一章优先复用完整分页 LRU，未命中时等待当前章完整分页后再分批
  测量末页；
- 章首/章末拖动、点击区域和音量键优先使用已经就绪的相邻目标页；
- 目标页未就绪或当前章完整分页尚未完成时保留原延迟切章行为，不展示空白假页；
- 新增 `CommitReaderAdjacentPageTurnIntent`，只在边界动画完成后提交章节；
- `animateChapterTransition=false` 标记该视觉切换已经完成，新正文就绪后直接稳定接管，不再补播
  第二次跨章动画；
- 章节索引、字符锚点、进度保存和正文加载仍由原 ViewModel/协调器调用链负责。

该阶段会跨越 UI、Contract 和协调器边界，不应与第一阶段的几何修正混成一次大改。

## 7. 性能和内存建议

第一阶段建议先保留 Flutter 现有“无长期全屏位图”方向，但需要收紧合成成本：

1. 当前页、目标页在动画开始后保持稳定 Widget，不在每帧重新分页或重新生成正文行。
2. 正面和页背分别使用独立、可缓存的 `RepaintBoundary`；不能把同一个 Widget 对象出现两次
   误认为共享同一张栅格结果。
3. 去掉只为页背整体 `ColorFiltered` 服务的全层颜色过滤，优先用页背 Path 内的轻量颜色叠加，
   减少额外合成层。
4. 阴影继续使用有限线性渐变，不使用大半径模糊、全屏 `saveLayer` 或历史轨迹缓存。
5. 每帧只保留当前几何点、Path 和矩阵，不保存触摸轨迹列表。
6. 模式、章节、尺寸、排版代次改变时停止控制器并清理动画页引用。
7. 动画控制器继续由单个分页 State 持有并在 `dispose` 释放，不新增 Timer、Stream 或监听泄漏点。

如果第一阶段真机仍存在明显掉帧，再单独评估 Android 同类的“动画期临时快照”：

- 只捕获正在折叠的页面和必要目标页；
- 只在动画期间持有；
- 完成、取消、切章、旋转和 `dispose` 时显式释放 `ui.Image`；
- 捕获失败立即回到稳定的实时 Widget 路径；
- 不建立长期全屏快照缓存。

临时快照会换取更稳定的每帧绘制，但高 DPR 全屏图片内存较大，不应在没有真机证据前默认引入。

## 8. 用户验收重点

代码改造后由用户执行，AI 不运行检查：

1. 从右上、右下、页面中部不同横坐标起手，确认卷角从真实手指附近出现并持续贴手。
2. 小幅左滑后继续向左松手，确认可以按 Android 手感完成；末段折痕自然离开，无最后一帧跳页。
3. 左滑后反向回拉并松手，确认目标页不切换、当前页二维回弹到原位。
4. 右滑上一页，确认从左侧带入上一页但几何使用 Android 同类右下展开，不出现镜像错误。
5. 在页面上半部中段起手，确认下一页选择右上角而不是错误落到下角。
6. 观察页背文字是否贴合折痕，没有漂移、重影或方向错误。
7. 在浅色、护眼和深色背景分别确认四组阴影方向清楚但不过黑。
8. 点击区域和音量键翻页，确认轨迹、时长与拖动松手后的程序化动画一致。
9. 连续快速点击、拖动回拉、旋转和切后台，确认动画单飞、无残留状态和无持续内存增长。
10. 第一阶段仍按当前延迟切章策略验收；跨章节实时跟手单独留给第二阶段。

## 9. 2026-07-27 第一阶段实施快照

已写入：

- 仿真帧改为直接消费真实 `Offset` 触点和锁定页角，进度不再合成横坐标；
- 手势首次有效移动后锁定上一页/下一页，回拉只改变完成或取消状态；
- 下一页按起手上下半屏锁定右上/右下，上一页固定右下且不再水平镜像；
- 完成和回弹按 Android 300ms 距离基准同时插值 X、Y；
- 页背反射轴由曲线起点连线改为两个贝塞尔控制点连线；
- 阴影拆为目标页阴影、两段卷起页正面阴影和页背折叠阴影；
- 移除页背整层 `ColorFiltered`，保留有限 Path 着色，降低额外合成层风险；
- 点击区域、音量键和现有跨章节程序化动画已适配真实二维触点接口；
- 分页、选区保护、稳定字符锚点、完整分页延迟应用和动画单飞保持原逻辑。

未完成：

- 未运行编译、分析、测试、格式化或应用；
- Android/iOS 真机视觉、帧率、发热和内存仍待用户验证；
- 动画期临时 `ui.Image` 快照没有引入，是否需要须以真机掉帧证据决定。

## 10. 2026-07-27 第二阶段实施快照

已写入：

- 相邻正文预加载结果通过世代保护回调进入 `ReaderUiState`，只保留当前章前后两个快照；
- 卷标题会在协调器候选顺序中跳过，直接优先预加载真正可阅读的前后章；
- 当前章完整分页未完成时禁止边界预览，避免把首批 8 页末尾误判成章末；
- 下一章目标首屏在首帧后有限测量，不与当前章完整分页争抢长任务；
- 上一章末页先查三套完整分页 LRU，未命中时在当前章完整分页完成后使用可让出事件循环的
  分批任务计算；
- 相邻目标页只保存正文模型和一个 `ReaderTextPage`，不保存 Widget、控制器、图片快照或触摸
  历史；
- 边界拖动提交后保持已展示目标页，ViewModel 保存旧章进度并加载新章期间不闪回；
- 新章节正文到达后由章节切换容器直接接管，不重复播放程序化仿真；
- 回弹、加载世代变化、显示配置变化、内存压力和组件释放都会淘汰过期相邻预览；
- 未运行构建、分析、测试、格式化或应用启动，全部结果等待用户真机验证。

## 11. 2026-07-27 真机截图复核：页面像“两页没有合在一起”

### 11.1 截图事实

用户提供的真机帧同时清晰显示：

- 左侧大面积当前页正面；
- 右侧大面积目标页；
- 中间一条从顶部延伸到底部、带反射正文的狭长页背；
- 页背与右侧目标页之间虽然有阴影，但卷角没有收敛在真实触点附近。

这不是正文分页把一页拆成了两页。当前页和目标页仍按同一个全屏页面坐标渲染，问题发生在
`ReaderSimulationPageTurnFrame` 对折叠区域的几何和页面介质合成：本应局部连接当前页与目标页的
卷角被拉成贯穿整屏的长斜带，于是视觉上变成“两张平铺页面，中间夹一条页背”。

### 11.2 P0 根因：越界修正只正确更新了 X，没有按 Android 联动更新 Y

Android `SimulationPageDelegate.calcPoints()` 在 `mBezierStart1.x` 越界后按以下顺序修正触点：

```text
f1 = abs(cornerX - oldTouchX)
f2 = width * f1 / correctedBezierStart1X
touchX = abs(cornerX - f2)
f3 = abs(cornerX - touchX) * abs(cornerY - oldTouchY) / f1
touchY = abs(cornerY - f3)
```

关键点是第四步使用**已经更新后的 `touchX`**。因此 X 被拉回安全范围时，Y 也会按同一比例向页角
收束，卷起区域保持为一个局部、连续的纸张折角。

当前 Flutter
`lib/src/ui/reader/reader_simulation_page_turn.dart` 的 `_ReaderSimulationGeometry.calculate()`
在对应分支中先算出 `correctedHorizontal`，但 `correctedVertical` 仍使用修正前的
`(safeCorner.dx - safeTouch.dx).abs()`：

```text
correctedVertical =
  oldHorizontalDistance * verticalDistance / oldHorizontalDistance
```

分子和分母中的旧水平距离会直接抵消，所以 `correctedVertical` 实际退化为原垂直距离，
`safeTouch.dy` 基本保持不变。X 已靠近页角而 Y 仍停在原触摸高度时，两条贝塞尔曲线会形成截图中的
超长对角折叠区。这是当前截图“像两页没有合在一起”的首要代码原因，优先级高于阴影颜色调节。

建议修正时严格保留 Android 的计算顺序：

1. 保存修正前的水平距离作为分母；
2. 先得到修正后的 `touchX`；
3. 再用 `abs(cornerX - correctedTouchX)` 计算垂直缩放；
4. 用修正后的 X、Y 重新计算中点、控制点和曲线起点；
5. 对右上、右下、页面中部和上一页方向分别人工验收。

### 11.3 P1 差距：Flutter 的正面和页背不是 Android 那样的同一页面快照

Android 在方向确定后把当前页和目标页各截成临时 `Bitmap`。当前页正面与反射页背都绘制同一张
`curBitmap` 或 `prevBitmap`，因此同一帧中的文字、时间、图片加载状态和栅格坐标天然一致。

Flutter 当前为 `frontFoldingPage` 和 `backFoldingPage` 分别创建 `RepaintBoundary`。即使二者传入
同一个 Widget 描述，也会形成两个独立渲染子树；`RepaintBoundary` 只隔离重绘，并不会让正面和页背
共享同一张栅格快照。页眉时间、异步图片、选择/标注状态或任何局部 StatefulWidget 都可能在两棵树
中处于不同帧，同时还会重复栅格化整页内容。

这个差距不是本次长斜带的第一根因，但会强化“纸张背面和正面没有粘在一起”的观感。建议先修正
P0 几何并真机复测；如果静态正文仍有明显接缝、图片页掉帧或正反面状态不一致，再引入仅动画期存在
的共享页面快照：

- 只捕获实际折叠页；
- 当前页正面和页背复用同一张 `ui.Image`；
- 完成、取消、尺寸变化、切章和 `dispose` 时立即释放；
- 捕获未就绪时保持稳定当前页，不在首个拖动帧切换两套介质；
- 不建立长期全屏快照缓存。

### 11.4 P1 差距：页背裁剪没有显式保持 Android 的双路径交集

Android 绘制页背时先裁剪 `mPath0`，再裁剪 `mPath1`，实际区域始终是：

```text
foldPath ∩ foldBackPath
```

Flutter 当前页背 Widget 只由 `foldBackPath` 裁剪。理想几何下 `foldBackPath` 应落在
`foldPath` 内，但越界修正、极端触点和数值钳制后不能继续依赖这一隐含关系。修正时应显式用
`Path.combine(PathOperation.intersect, foldPath, foldBackPath)` 生成页背可见区；目标页露出区和
阴影也保持与 Android 相同的路径交集，避免页背越过折叠区后像独立纸条浮在两页之间。

### 11.5 P2 观感差距：阴影仍是职责映射，不是 Android 参数等价

Flutter 已拆出目标页、两段当前页正面和页背四组阴影，但仍存在以下简化：

- Android 前景阴影约为半透明黑到透明，Flutter 当前峰值透明度更低；
- Android 页背折叠阴影更深，Flutter 当前峰值只有 `0.22`；
- Android 第二段前景阴影会根据 `hmg` 调整旋转后矩形范围，Flutter 使用统一对角线长度；
- Android 的 `GradientDrawable` 边界包含额外的 `±1` 像素过渡，Flutter 没有等价边界补偿。

这些差距会让折痕体积不足、当前页与目标页分界偏“平”，但不应在修正 P0 公式前单独调色，否则只能
掩盖长斜带，不能让纸张重新连成一个连续曲面。

### 11.6 建议执行顺序

1. **最小 P0 修正**：修正越界分支中 Y 对更新后 X 的依赖，并显式约束页背为双路径交集。
2. **同一组样本真机复测**：右上、右下、页面中部、上一页、回弹和程序化翻页逐项截图对照 Android。
3. **阴影参数对齐**：只在几何稳定后对齐四组阴影的透明度、方向和第二段范围。
4. **按证据决定页面快照**：若仍有正反面接缝或图片页掉帧，再实现动画期临时共享快照及释放链路。

本节只完成静态源码和截图分析，未修改 Flutter 业务代码，也未运行构建、测试、分析、格式化或应用。

## 12. 2026-07-27 真机截图 P0 修正实施快照

用户确认执行后已写入以下最小修正：

- `_ReaderSimulationGeometry.calculate()` 保留修正前的水平距离作为稳定分母；
- 贝塞尔起点越界时先计算修正后的 `touchX`，再使用
  `abs(cornerX - correctedTouchX)` 联动收束 `touchY`，对齐 Android `calcPoints()` 的计算顺序；
- 页背原始内部路径与完整卷起路径通过
  `Path.combine(PathOperation.intersect, foldPath, rawFoldBackPath)` 显式求交；
- 路径布尔运算在极端几何下失败时返回空几何，沿现有稳定覆盖动画降级，不提交错误页码或进度；
- 没有引入全屏 `ui.Image`、长期页面快照、第三方依赖、平台桥或新的动画控制器。

本轮刻意未调整四组阴影透明度，也未引入动画期共享页面快照。应先由用户使用产生问题截图的同一
书籍、字号、边距和触摸位置复测；如果长斜带已消失但正反面仍有接缝，再根据真机证据执行 P1/P2，
避免在几何尚未确认前扩大内存和合成风险。

AI 未运行构建、测试、静态分析、格式化或应用启动，结果仍保持 `IN_PROGRESS`。

## 13. 2026-07-27 第二张真机截图复核

### 13.1 结论修正

用户在上一轮 X/Y 联动和页背路径交集修正后提供了第二张真机截图。画面仍然存在：

- 从页面顶部一直延伸到底部的平直页背纸带；
- 左侧当前页、中央页背和右侧目标页三块区域边界明显；
- 页背更像覆盖在两页之间的独立半透明层，而不是当前纸张连续翻起后的背面。

因此，上一轮越界公式是实际代码差距，但不是这组截图的主要持续原因；当前手势可能没有进入该
越界修正分支，或即使几何已经收窄，页面介质与阴影仍不足以表达连续纸张。后续不能继续只调整
触点公式，应优先对齐 Android 的页背底色和折叠阴影。

### 13.2 P0：页背折叠阴影的明暗方向与 Android 相反

Android `SimulationPageDelegate` 为页背折叠阴影单独使用：

```text
mFolderShadowDrawableLR / mFolderShadowDrawableRL
colors = [透明, 深色]
```

它与目标页阴影、当前页正面阴影的 `[深色, 透明]` 顺序相反。Android 根据
`mIsRtOrLb` 选择 LR 或 RL，使深色端贴近纸张折叠内侧。

Flutter `_drawFoldBackShadow()` 复用了通用 `_drawRotatedBand()` 的 `[深色, 较浅, 透明]`，
并传入：

```text
reverseGradient = !isRightTopOrLeftBottom
```

由于颜色数组本身没有像 Android 页背阴影那样反转，这里的方向应与当前实现相反。按 Android
边界和旋转关系映射后，页背折叠阴影应使用：

```text
reverseGradient = isRightTopOrLeftBottom
```

当前错误方向会把暗边放到纸带的外侧，纸张正面和页背应连接的位置反而缺少压暗过渡，从而强化
“中间另有一张纸”的观感。

### 13.3 P0：Flutter 缺少 Android 页背反射前的不透明纸张底色

Android `drawCurrentBackArea()` 在页背双路径裁剪后先执行：

```text
canvas.drawColor(ReadBookConfig.bgMeanColor)
canvas.drawBitmap(bitmap, reflectionMatrix, paint)
```

第一步会把整个页背可见区填成不透明纸张颜色。即使反射后的 Bitmap 在边缘没有完全覆盖裁剪区，
那里仍然是一张连续纸，而不会透出底层目标页。

Flutter 当前顺序是：

```text
目标页
当前页正面
反射后的独立 foldingPage Widget
半透明 backTint
页背阴影
```

`_drawBackTint()` 使用的纸张色透明度只有 `0.12`，而且在反射内容之后绘制。它既不能充当反射前的
不透明页背介质，也无法填补变换后页面矩形未覆盖的边缘。下一轮应在 `foldBackPath` 裁剪内部先绘制
不透明 `paperColor`，再绘制反射内容，最后才叠加轻微着色与折叠阴影。

该修正不需要 `ui.Image`，只增加一个受页背 Path 限制的纯色层，不建立额外长期缓存。

### 13.4 P1：四组阴影透明度远弱于 Android

Android 颜色整数换算后的峰值 Alpha 大致为：

| 阴影 | Android 峰值 Alpha | Flutter 当前峰值 |
|---|---:|---:|
| 目标页阴影 | `1.00` | `0.16` |
| 当前页两段正面阴影 | `0.50` | `0.28` |
| 页背折叠阴影 | `0.69` | `0.22` |

Android 使用窄而深的两色渐变，Flutter 使用更浅的三段渐变。截图中折痕缺少厚度并不是错觉。
建议按 Android 的颜色顺序和 Alpha 先做参数等价，再根据 Flutter 真机视觉只缩窄阴影宽度，不先
任意降低峰值。第二段正面阴影还应补回 Android 根据 `hmg` 调整旋转矩形水平范围的分支。

### 13.5 P1：当前页正面与页背仍不是同一张动画介质

Flutter 的两个 `RepaintBoundary` 仍是独立渲染子树，不是共享快照。第二张截图没有单独证明文字
状态已经分叉，但连续两次真机结果都表明实时 Widget 合成无法仅靠当前阴影参数达到 Android
Bitmap 路径的纸张整体感。

仍建议分两步执行，避免一次引入高 DPR 位图生命周期：

1. 先修正页背不透明底色、折叠阴影方向、Android 同类 Alpha 和第二段阴影边界；
2. 用户用同一书籍和同一触点复测；
3. 若页面仍明显分成三块，再实现只在动画期间存在、正面和页背共享的折叠页 `ui.Image`；
4. 快照在完成、取消、旋转、切章、配置变化和 `dispose` 时显式释放。

### 13.6 下一轮最小修正范围

建议下一轮只修改 `reader_simulation_page_turn.dart`：

1. 在页背裁剪区内增加反射内容之前的不透明 `paperColor`；
2. 把页背折叠阴影方向改为 `reverseGradient = isRightTopOrLeftBottom`；
3. 将目标页、正面和页背三类阴影的颜色顺序与峰值 Alpha 对齐 Android；
4. 补齐第二段当前页阴影的 `hmg` 范围修正；
5. 暂不引入 `ui.Image`，不修改分页、章节、进度、手势状态或数据库。

本节只完成第二张截图和静态源码复核，没有修改 Flutter 业务代码，也没有运行构建、测试、分析、
格式化或应用。

## 14. 2026-07-27 仿真翻页临时诊断日志

用户要求先添加日志确认真实运行几何，再决定下一轮视觉修正。已加入统一临时日志：

```text
Tag: READER_SIMULATION_TURN
Marker: FLUTTER_READER_SIMULATION_LOG
```

日志范围：

- 横向手势起点和页面尺寸；
- 首次有效移动锁定的上一页/下一页方向及页角；
- 松手时距离、速度、完成/取消判断和目标页类型；
- 程序化点击/音量键翻页的起点、触点与页角；
- 完成或回弹的二维起止触点和控制器区间；
- 约每 `120ms` 一条的受控几何摘要；
- 原始触点、安全触点、是否进入贝塞尔越界修正；
- 两个控制点、两个曲线起点、完整折叠路径和页背路径包围矩形；
- 无效几何降级到覆盖动画的帧。

日志不记录书名、章节名、正文、URL、账号、Cookie、Token 或文件路径。逐帧日志由分页组件节流，
避免每个刷新帧都写文件；没有新增 Timer、Stream 或监听器。

日志相关常量、字段、方法、参数、调用点和 import 均使用
`FLUTTER_READER_SIMULATION_LOG` 注释或 Marker。用户后续要求“移除日志”时，应只移除本节新增的
诊断代码和为其服务的接线，不移除仿真翻页业务修正。

AI 未运行构建、测试、静态分析、格式化或应用启动。

## 15. 2026-07-27 真机日志结论

用户提供了一次下一页左滑的完整持帧日志。关键输入为：

```text
pageSize = 392.7 × 818.9
dragStart = (307.4, 628.2)
corner = (392.7, 818.9)
direction = NEXT
isRtOrLb = false
```

### 15.1 上一轮越界分支不是本次截图原因

全部几何日志均为：

```text
bezierCorrected=false
```

并且没有出现 `geometry_fallback`。因此：

- 上一轮修正的贝塞尔起点横向越界分支没有在这次手势中执行；
- 当前画面不是覆盖动画降级；
- 页背双路径交集也成功生成；
- 第二张截图仍不正确，不能归因于上一轮 X/Y 修正失效。

### 15.2 全高纸带由真实左下拖动轨迹直接触发

手指从 `(307.4, 628.2)` 持续移动到约 `(115.5, 780.3)`。当触点 Y 接近右下页角
`(392.7, 818.9)`，但 X 仍远离页角时，第二条贝塞尔公式的垂直分母快速接近零。

日志中的变化为：

| 序号 | 触点 | `control2.y` | `start2.y` | 页背顶部 |
|---|---|---:|---:|---:|
| 3 | `(261.0, 622.5)` | `676.5` | `605.3` | `622.5` |
| 11 | `(161.7, 707.7)` | `523.2` | `375.3` | `509.4` |
| 14 | `(138.5, 750.2)` | `314.4` | `62.1` | `305.8` |
| 18 | `(115.5, 780.3)` | `-194.3` | `-701.0` | `-199.0` |

到序号 18 时，`foldBounds.top=-701.0`、`backBounds.top=-199.0`，两个路径都已经越过页面顶部，
经过外层 `ClipRect` 后自然形成从顶部贯穿到底部的纸带。日志与截图形态完全对应。

### 15.3 Android 触摸基类没有额外限制这类轨迹

重新检查 Android：

- `HorizontalPageDelegate.onScroll()` 把真实 `sumX/sumY` 直接交给
  `ReadView.setTouchPoint()`；
- `SimulationPageDelegate.onTouch()` 只对起手位于中部三分区或上一页方向时固定 Y；
- 本次起手 Y 约为页面高度的 `76.7%`，不在 Android 的中部修正规则内；
- Android `calcPoints()` 的第二控制点和曲线起点公式与当前 Flutter 相同。

因此，如果在原 Android 中执行同样的“从右下区域继续向左下压到接近底边”轨迹，几何公式本身也会
产生越过页面顶部的折叠路径。为了追求 Android 行为映射，不应直接给 Flutter 单独增加任意 Y 钳制；
那会改变原生手感和触点响应。

### 15.4 日志确认下一步应修页面介质与阴影，而不是继续改触点

这次日志同时确认：

- 页面尺寸正常；
- 方向和右下页角选择正确；
- 输入触点与安全触点一致；
- 没有非法数值、路径失败或目标页跳变；
- 当前长纸带是合法但极端的原生同类几何。

用户仍明显感觉“三块页面没有合在一起”，差距应继续收敛到第 13 节已经定位的渲染层：

1. 页背反射前缺少 Android 的不透明纸张底色；
2. 页背折叠阴影的颜色顺序和明暗方向与 Android 相反；
3. 三类阴影峰值 Alpha 明显弱于 Android；
4. 第二段正面阴影缺少 Android `hmg` 范围修正；
5. Flutter 正面和页背仍是两个实时 Widget 子树，不是同一临时页面快照。

建议先执行前四项无位图修正，再用同一手势复测。只有修正后仍有明显断层，才进入动画期共享
`ui.Image`，避免现在就扩大内存和释放链路。

本节只分析用户提供的受控几何日志，没有运行项目、构建、测试、静态分析或格式化。

## 16. 2026-07-27 日志确认后的渲染修正

用户确认执行后，本轮只修改 `reader_simulation_page_turn.dart`，保持日志已经验证的真实触点、页角、
贝塞尔控制点和路径公式不变。

已写入：

1. 页背双路径裁剪区内先绘制不透明 `paperColor`，再绘制反射页面，最后叠加折叠阴影，对齐
   Android `drawColor(bgMeanColor) -> drawBitmap()` 的页面介质顺序；
2. 移除原先反射内容之后的半透明 `backTint`，避免它继续承担错误的纸张底层职责；
3. 目标页阴影改用 Android `mBackShadowColors` 同类的
   `0xFF111111 -> 0x00111111` 两色渐变；
4. 当前页两段正面阴影改用 Android `mFrontShadowColors` 同类的
   `0x80111111 -> 0x00111111` 两色渐变；
5. 页背折叠阴影改用 Android 相反颜色顺序的
   `0x00333333 -> 0xB0333333`，并继续按 `mIsRtOrLb` 选择 LR/RL 方向；
6. 页背阴影边界补回 Android 的 `±1` 过渡；
7. 第二段当前页阴影补回 `hmg` 斜距分支，在控制点越过页面上方时同步移动旋转后的矩形范围；
8. 诊断日志继续保留，用于将本轮截图与上一轮相同手势的路径范围直接对照。

未引入：

- `ui.Image` 或任何全屏页面快照；
- 新动画控制器、Timer、Stream 或监听器；
- 分页、章节、进度、选区、数据库、路由或平台桥修改。

下一步由用户使用相同书籍、排版和“右下向左下”手势复测。预期几何纸带范围仍可能与日志一致，
但中央页背应成为不透底的连续纸张，当前页—页背—目标页之间出现与 Android 同类的深浅折痕，
不再像三块透明平面。若仍有明显断层，下一阶段才评估动画期共享折叠页快照。

AI 未运行构建、测试、静态分析、格式化或应用启动，状态保持 `IN_PROGRESS`。
