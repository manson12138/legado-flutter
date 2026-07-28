import 'dart:ui';

/// FLUTTER_REWRITE_DEBUG_LOG：阅读器封面转场性能排查统一日志 Tag。
const String readerCoverTransitionLogTag = 'READER_COVER_TRANSITION';

/// FLUTTER_REWRITE_DEBUG_LOG：标识本轮只为转场性能排查存在的日志与辅助代码。
const String readerCoverTransitionDebugLogMarker =
    'FLUTTER_REWRITE_DEBUG_LOG';

/// 阅读器入口类型，决定使用专用封面转场或普通页面转场。
enum ReaderTransitionKind {
  /// 从书架封面进入，使用真实 cell 起点到全屏的放大淡出动画。
  bookshelf,

  /// 从历史封面进入，使用真实 cell 起点到全屏的放大淡出动画。
  history,

  /// 从书籍详情进入，由路由器使用标准 Material 页面转场。
  detail,

  /// 旧路由或来源不可用，从中心封面降级放大到全屏后淡出。
  fallback,
}

/// 单次阅读导航使用的短生命周期视觉参数，不持有 Widget、Context、Key 或图片对象。
final class ReaderTransitionSpec {
  /// 创建不可变阅读转场参数。
  const ReaderTransitionSpec({
    required this.id,
    required this.kind,
    required this.coverUrl,
    this.sourceRect,
  });

  /// 每次点击唯一的转场标识，避免同一本书在书架和历史同时出现时冲突。
  final String id;

  /// 当前入口动画类型。
  final ReaderTransitionKind kind;

  /// 只保存封面地址，由共享图片缓存复用已解码资源。
  final String? coverUrl;

  /// 点击瞬间的全局封面矩形；详情和降级入口允许为空。
  final Rect? sourceRect;

  /// 进程内递增序号，只用于生成单次点击 ID。
  static int _sequence = 0;

  /// 根据点击的全局/局部位置和封面尺寸生成精确来源矩形。
  factory ReaderTransitionSpec.fromTap({
    required ReaderTransitionKind kind,
    required String? coverUrl,
    required Offset globalPosition,
    required Offset localPosition,
    required Size sourceSize,
  }) {
    /// 当前封面左上角的全局坐标。
    final Offset origin = globalPosition - localPosition;
    return ReaderTransitionSpec(
      id: _nextId(),
      kind: kind,
      coverUrl: coverUrl,
      sourceRect: origin & sourceSize,
    );
  }

  /// 根据调用方已经计算好的全局封面矩形生成来源参数。
  factory ReaderTransitionSpec.fromRect({
    required ReaderTransitionKind kind,
    required String? coverUrl,
    required Rect sourceRect,
  }) {
    return ReaderTransitionSpec(
      id: _nextId(),
      kind: kind,
      coverUrl: coverUrl,
      sourceRect: sourceRect,
    );
  }

  /// 创建书籍详情进入阅读器的普通页面转场标识。
  ///
  /// 该参数只用于让应用路由器识别详情入口，不携带封面地址或来源几何，
  /// 因此不会触发阅读器专用的封面移动、缩放或开书动画。
  factory ReaderTransitionSpec.detail() {
    return ReaderTransitionSpec(
      id: _nextId(),
      kind: ReaderTransitionKind.detail,
      coverUrl: null,
    );
  }

  /// 创建没有来源几何的兼容降级封面转场。
  factory ReaderTransitionSpec.centered({
    required ReaderTransitionKind kind,
    required String? coverUrl,
  }) {
    return ReaderTransitionSpec(
      id: _nextId(),
      kind: kind,
      coverUrl: coverUrl,
    );
  }

  /// 生成不包含书籍 URL 或用户数据的单次进程内标识。
  static String _nextId() {
    _sequence += 1;
    return 'reader-transition-$_sequence';
  }
}
