import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../api/http/http_contract.dart';
import '../../domain/gateway/manga_image_gateway.dart';
import '../../domain/model/manga_page.dart';
import '../theme/app_tokens.dart';

/// 漫画图片 Widget 使用的受控文件解析回调。
typedef MangaPageResolver = Future<MangaImageResource> Function(
  MangaPage page, {
  required HttpCancellationToken cancellationToken,
  MangaImageProgress? onProgress,
  required bool forceRefresh,
});

/// 惰性加载单张漫画图片，只消费 ViewModel 返回的受控本地文件。
final class MangaPageView extends StatefulWidget {
  /// 创建漫画图片页。
  const MangaPageView({
    required this.page,
    required this.scrollController,
    required this.resolveImage,
    required this.createCancellationToken,
    required this.onVisible,
    required this.onFirstFrame,
    required this.onTap,
    this.trackScrollVisibility = true,
    this.isCurrentPage = false,
    this.enableZoom = false,
    this.evictDecodedImageOnDispose = false,
    this.imageAlignment = Alignment.topCenter,
    this.placeholderAspectRatio,
    this.onAspectRatioResolved,
    this.onZoomChanged,
    super.key,
  });

  /// 当前稳定漫画页事实。
  final MangaPage page;

  /// 条漫列表滚动控制器，只用于判断当前 Cell 是否经过屏幕中心。
  final ScrollController scrollController;

  /// 通过 ViewModel 调用图片 Gateway 的受控回调。
  final MangaPageResolver resolveImage;

  /// 创建当前 Cell 生命周期取消令牌。
  final HttpCancellationToken Function() createCancellationToken;

  /// 当前图片经过屏幕中心时通知领域位置变化。
  final ValueChanged<int> onVisible;

  /// 图片完成真实首帧显示后通知阅读成功。
  final ValueChanged<int> onFirstFrame;

  /// 点击图片切换工具栏。
  final VoidCallback onTap;

  /// 是否按条漫列表的屏幕中心追踪当前页。
  final bool trackScrollVisibility;

  /// 当前 Cell 是否为分页阅读器的稳定页面。
  final bool isCurrentPage;

  /// 是否允许当前页面响应双指和双击缩放。
  final bool enableZoom;

  /// Cell 销毁时是否从 Flutter 图片缓存释放本次尺寸的解码结果。
  final bool evictDecodedImageOnDispose;

  /// 图片在当前页面可用空间内的对齐方式。
  final AlignmentGeometry imageAlignment;

  /// 条漫图片尚未完成解析时使用的已知宽高比。
  final double? placeholderAspectRatio;

  /// 图片文件尺寸解析完成后回传宽高比，供 Cell 重建时复用稳定高度。
  final ValueChanged<double>? onAspectRatioResolved;

  /// 当前图片进入或退出放大状态的回调。
  final ValueChanged<bool>? onZoomChanged;

  @override
  State<MangaPageView> createState() => _MangaPageViewState();
}

/// 管理单张图片请求、解码失败和可见性观察的瞬时 UI 状态。
final class _MangaPageViewState extends State<MangaPageView> {
  /// 当前图片的变换控制器，只作用于本 Cell。
  final TransformationController _transformationController =
      TransformationController();

  /// 当前图片请求取消令牌。
  HttpCancellationToken? _cancellationToken;

  /// 已完成校验的本地图片资源。
  MangaImageResource? _resource;

  /// 当前加载失败的安全提示。
  String? _errorMessage;

  /// 当前已下载字节数。
  int _receivedBytes = 0;

  /// 当前响应声明的总字节数。
  int? _totalBytes;

  /// 是否已为当前资源报告真实首帧。
  bool _reportedFirstFrame = false;

  /// 是否已在图片经过屏幕中心时报告真实阅读成功。
  bool _reportedVisibleFirstFrame = false;

  /// 是否已经安排解码失败状态更新，避免 errorBuilder 重复排队。
  bool _decodeFailureScheduled = false;

  /// 双击时记录的局部坐标，用于以手指位置为中心放大。
  Offset? _doubleTapPosition;

  /// 当前图片是否已经放大。
  bool _isZoomed = false;

  /// 最近一次构建使用的解码宽度，供销毁时精确清理解码缓存键。
  int? _lastCacheWidth;

  /// 快速滑动期间已经完成下载、等待滚动停止后再提交布局的资源。
  MangaImageResource? _pendingResource;

  /// 当前监听滚动停止事件的位置对象。
  ScrollPosition? _observedScrollPosition;

  /// 最近一次已经刷新到界面的下载百分比。
  int _lastProgressPercent = -1;

  /// 总长度未知时最近一次已经刷新到界面的下载字节数。
  int _lastProgressBytes = 0;

  @override
  void initState() {
    super.initState();
    if (widget.trackScrollVisibility) {
      widget.scrollController.addListener(_checkVisibility);
    }
    _load();
  }

  @override
  void didUpdateWidget(covariant MangaPageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scrollController != widget.scrollController ||
        oldWidget.trackScrollVisibility != widget.trackScrollVisibility) {
      _stopObservingScrollIdle();
      if (oldWidget.trackScrollVisibility) {
        oldWidget.scrollController.removeListener(_checkVisibility);
      }
      if (widget.trackScrollVisibility) {
        widget.scrollController.addListener(_checkVisibility);
      }
    }
    if (oldWidget.page.stableKey != widget.page.stableKey) {
      _pendingResource = null;
      _stopObservingScrollIdle();
      _releaseDecodedImage();
      _resetZoom(notify: false);
      _load();
      return;
    }
    if ((!widget.isCurrentPage && oldWidget.isCurrentPage) ||
        (!widget.enableZoom && oldWidget.enableZoom)) {
      if (!widget.isCurrentPage && oldWidget.isCurrentPage) {
        _releaseDecodedImage();
      }
      _resetZoom(notify: false);
    }
    if (widget.isCurrentPage && !oldWidget.isCurrentPage) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _checkVisibility());
    }
  }

  /// 加载或强制刷新当前图片文件。
  Future<void> _load({bool forceRefresh = false}) async {
    _cancellationToken?.cancel('漫画图片 Cell 重新加载');
    _pendingResource = null;
    _stopObservingScrollIdle();
    /// 当前加载独占的取消令牌。
    final HttpCancellationToken token = widget.createCancellationToken();
    _cancellationToken = token;
    if (mounted) {
      setState(() {
        _resource = null;
        _errorMessage = null;
        _receivedBytes = 0;
        _totalBytes = null;
        _reportedFirstFrame = false;
        _reportedVisibleFirstFrame = false;
        _decodeFailureScheduled = false;
        _lastProgressPercent = -1;
        _lastProgressBytes = 0;
      });
    }
    try {
      /// Gateway 返回的受控本地文件描述。
      final MangaImageResource resource = await widget.resolveImage(
        widget.page,
        cancellationToken: token,
        forceRefresh: forceRefresh,
        onProgress: (int receivedBytes, int? totalBytes) {
          if (!mounted || token.isCancelled) {
            return;
          }
          /// 有总长度时只在整数百分比变化后刷新；未知长度时每 64 KiB 刷新一次。
          final int? progressPercent = totalBytes != null && totalBytes > 0
              ? (receivedBytes * 100 ~/ totalBytes).clamp(0, 100).toInt()
              : null;
          if (progressPercent != null) {
            if (progressPercent == _lastProgressPercent) {
              return;
            }
            _lastProgressPercent = progressPercent;
          } else if (receivedBytes - _lastProgressBytes < 64 * 1024) {
            return;
          } else {
            _lastProgressBytes = receivedBytes;
          }
          setState(() {
            _receivedBytes = receivedBytes;
            _totalBytes = totalBytes;
          });
        },
      );
      if (!mounted || token.isCancelled || !identical(_cancellationToken, token)) {
        return;
      }
      _acceptResolvedResource(resource);
    } on MangaImageException catch (error) {
      if (!mounted || token.isCancelled || !identical(_cancellationToken, token)) {
        return;
      }
      setState(() => _errorMessage = error.message);
    } on Object {
      if (!mounted || token.isCancelled || !identical(_cancellationToken, token)) {
        return;
      }
      setState(() => _errorMessage = '图片加载失败，请重试');
    }
  }

  /// 快速滑动时延迟改变 Cell 高度，避免异步图片完成打断惯性滚动。
  void _acceptResolvedResource(MangaImageResource resource) {
    if (widget.trackScrollVisibility &&
        widget.scrollController.hasClients &&
        widget.scrollController.position.isScrollingNotifier.value) {
      _pendingResource = resource;
      _observeScrollIdle(widget.scrollController.position);
      return;
    }
    _commitResolvedResource(resource);
  }

  /// 监听当前滚动位置，等待拖动或惯性滚动完全停止。
  void _observeScrollIdle(ScrollPosition position) {
    if (identical(_observedScrollPosition, position)) {
      return;
    }
    _stopObservingScrollIdle();
    _observedScrollPosition = position;
    position.isScrollingNotifier.addListener(_handleScrollIdle);
  }

  /// 停止后一次性提交等待中的资源尺寸变化。
  void _handleScrollIdle() {
    final ScrollPosition? position = _observedScrollPosition;
    if (position == null || position.isScrollingNotifier.value) {
      return;
    }
    _stopObservingScrollIdle();
    final MangaImageResource? resource = _pendingResource;
    _pendingResource = null;
    if (mounted && resource != null) {
      _commitResolvedResource(resource);
    }
  }

  /// 移除滚动停止监听，避免控制器切换或 Cell 销毁后残留回调。
  void _stopObservingScrollIdle() {
    final ScrollPosition? position = _observedScrollPosition;
    position?.isScrollingNotifier.removeListener(_handleScrollIdle);
    _observedScrollPosition = null;
  }

  /// 应用真实图片尺寸，并按当前 Cell 已滚过的比例补偿列表偏移。
  void _commitResolvedResource(MangaImageResource resource) {
    if (!mounted) {
      return;
    }
    widget.onAspectRatioResolved?.call(resource.width / resource.height);
    final RenderObject? beforeObject = context.findRenderObject();
    final RenderBox? beforeBox = beforeObject is RenderBox && beforeObject.hasSize
        ? beforeObject
        : null;
    final double oldHeight = beforeBox?.size.height ?? 0;
    final double oldTop = beforeBox?.localToGlobal(Offset.zero).dy ?? 0;
    final ScrollableState? scrollable = Scrollable.maybeOf(context);
    final RenderObject? viewportObject =
        scrollable?.context.findRenderObject();
    final double viewportTop = viewportObject is RenderBox && viewportObject.hasSize
        ? viewportObject.localToGlobal(Offset.zero).dy
        : 0;
    setState(() => _resource = resource);
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) {
        return;
      }
      if (widget.trackScrollVisibility &&
          oldHeight > 0 &&
          oldTop < viewportTop &&
          widget.scrollController.hasClients &&
          !widget.scrollController.position.isScrollingNotifier.value) {
        final RenderObject? afterObject = context.findRenderObject();
        if (afterObject is RenderBox && afterObject.hasSize) {
          final double hiddenFraction =
              ((viewportTop - oldTop) / oldHeight).clamp(0, 1).toDouble();
          final double heightDelta = afterObject.size.height - oldHeight;
          final double targetOffset = (widget.scrollController.offset +
                  heightDelta * hiddenFraction)
              .clamp(
                widget.scrollController.position.minScrollExtent,
                widget.scrollController.position.maxScrollExtent,
              )
              .toDouble();
          if ((targetOffset - widget.scrollController.offset).abs() > 0.5) {
            widget.scrollController.jumpTo(targetOffset);
          }
        }
      }
      _checkVisibility();
    });
  }

  /// 当前 Cell 中心经过可视屏幕中心时报告图片位置。
  void _checkVisibility() {
    if (!mounted || _resource == null || !_reportedFirstFrame) {
      return;
    }
    if (!widget.trackScrollVisibility) {
      if (widget.isCurrentPage) {
        widget.onVisible(widget.page.imageIndex);
        if (!_reportedVisibleFirstFrame) {
          _reportedVisibleFirstFrame = true;
          widget.onFirstFrame(widget.page.imageIndex);
        }
      }
      return;
    }
    /// 当前图片 RenderBox。
    final RenderObject? renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) {
      return;
    }
    /// 图片顶部在全局坐标中的位置。
    final double top = renderObject.localToGlobal(Offset.zero).dy;
    /// 图片底部在全局坐标中的位置。
    final double bottom = top + renderObject.size.height;
    /// 屏幕垂直中心位置。
    final double viewportCenter = MediaQuery.sizeOf(context).height / 2;
    if (top <= viewportCenter && bottom >= viewportCenter) {
      widget.onVisible(widget.page.imageIndex);
      if (!_reportedVisibleFirstFrame) {
        _reportedVisibleFirstFrame = true;
        widget.onFirstFrame(widget.page.imageIndex);
      }
    }
  }

  /// 文件成功解码出首帧后报告真实阅读成功。
  void _handleFrame(int? frame) {
    if (frame == null || _reportedFirstFrame) {
      return;
    }
    _reportedFirstFrame = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkVisibility());
  }

  /// 把变换矩阵同步为分页容器需要的缩放布尔状态。
  void _syncZoomState() {
    /// 当前矩阵的最大缩放轴。
    final double scale = _transformationController.value.getMaxScaleOnAxis();
    /// 浮点误差范围外才视为真正放大。
    final bool nextZoomed = scale > 1.01;
    if (nextZoomed == _isZoomed) {
      return;
    }
    setState(() => _isZoomed = nextZoomed);
    widget.onZoomChanged?.call(nextZoomed);
  }

  /// 记录双击位置。
  void _handleDoubleTapDown(TapDownDetails details) {
    _doubleTapPosition = details.localPosition;
  }

  /// 双击在原始比例和 2.5 倍之间切换。
  void _handleDoubleTap() {
    if (!widget.enableZoom || !widget.isCurrentPage) {
      return;
    }
    if (_isZoomed) {
      _resetZoom(notify: true);
      return;
    }
    /// 未收到坐标时使用当前 Cell 中心作为缩放锚点。
    final Offset position = _doubleTapPosition ??
        Offset(context.size?.width ?? 0, context.size?.height ?? 0) / 2;
    /// 双击使用的固定放大倍数。
    const double scale = 2.5;
    _transformationController.value = Matrix4.identity()
      ..translate(position.dx, position.dy)
      ..scale(scale)
      ..translate(-position.dx, -position.dy);
    _syncZoomState();
  }

  /// 退出当前图片缩放，换页时同步解锁分页手势。
  void _resetZoom({required bool notify}) {
    _transformationController.value = Matrix4.identity();
    if (!_isZoomed) {
      return;
    }
    _isZoomed = false;
    if (mounted && notify) {
      setState(() {});
    }
    if (notify) {
      widget.onZoomChanged?.call(false);
    }
  }

  /// 从 Flutter 图片缓存释放当前分页页面的指定尺寸解码结果。
  void _releaseDecodedImage() {
    final MangaImageResource? resource = _resource;
    final int? cacheWidth = _lastCacheWidth;
    if (!widget.evictDecodedImageOnDispose || resource == null) {
      return;
    }
    /// 与 `Image.file` 内部一致的文件及尺寸缓存键。
    final ImageProvider<Object> provider = ResizeImage.resizeIfNeeded(
      cacheWidth,
      null,
      FileImage(File(resource.filePath)),
    );
    unawaited(provider.evict());
  }

  /// Flutter 解码失败时切换为受控错误，并允许删除缓存后重试。
  Widget _decodeError(
    BuildContext context,
    Object error,
    StackTrace? stackTrace,
  ) {
    if (!_decodeFailureScheduled) {
      _decodeFailureScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() => _errorMessage = '图片解码失败，请重新下载');
        }
      });
    }
    return _errorView();
  }

  /// 构建加载失败和强制重试入口。
  Widget _errorView() {
    return _stableStatusExtent(
      Center(
        child: Padding(
          padding: const EdgeInsets.all(SpacingToken.large),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.broken_image_outlined, size: 42),
              const SizedBox(height: SpacingToken.small),
              Text(
                _errorMessage ?? widget.page.altText.ifEmpty('图片加载失败'),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: SpacingToken.small),
              FilledButton.tonalIcon(
                onPressed: () => _load(forceRefresh: true),
                icon: const Icon(Icons.refresh),
                label: const Text('重新下载'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 条漫的加载与错误状态保持稳定比例，避免状态切换导致列表高度塌缩。
  Widget _stableStatusExtent(Widget child) {
    if (!widget.trackScrollVisibility) {
      return ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 240),
        child: child,
      );
    }
    final MangaImageResource? resource = _resource;
    final double resolvedAspectRatio = resource == null
        ? MediaQuery.sizeOf(context).aspectRatio
        : resource.width / resource.height;
    return AspectRatio(
      aspectRatio: widget.placeholderAspectRatio ?? resolvedAspectRatio,
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    /// 当前完成校验的本地资源。
    final MangaImageResource? resource = _resource;
    if (_errorMessage != null) {
      return _errorView();
    }
    if (resource == null) {
      /// 已知总长度时展示的下载比例。
      final double? progress = _totalBytes != null && _totalBytes != 0
          ? (_receivedBytes / (_totalBytes ?? 1)).clamp(0, 1).toDouble()
          : null;
      final Widget loading = Center(
        child: CircularProgressIndicator(value: progress),
      );
      return _stableStatusExtent(loading);
    }
    /// 按逻辑宽度和设备像素比限制 Flutter 解码宽度，避免保留原始超宽位图。
    /// 分页邻页只保留低分辨率预览，当前页才使用完整屏幕像素宽度。
    final double decodeScale = widget.evictDecodedImageOnDispose &&
            !widget.isCurrentPage
        ? 0.35
        : 1;
    final int cacheWidth = _mathMaxOne(
      (MediaQuery.sizeOf(context).width *
              MediaQuery.devicePixelRatioOf(context) *
              decodeScale)
          .round(),
    );
    _lastCacheWidth = cacheWidth;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onDoubleTapDown: widget.enableZoom ? _handleDoubleTapDown : null,
      onDoubleTap: widget.enableZoom ? _handleDoubleTap : null,
      child: InteractiveViewer(
        transformationController: _transformationController,
        panEnabled: widget.enableZoom && widget.isCurrentPage && _isZoomed,
        scaleEnabled: widget.enableZoom && widget.isCurrentPage,
        minScale: 1,
        maxScale: 4,
        boundaryMargin: const EdgeInsets.all(80),
        onInteractionUpdate: (_) => _syncZoomState(),
        onInteractionEnd: (_) => _syncZoomState(),
        child: AspectRatio(
          aspectRatio: resource.width / resource.height,
          child: Image.file(
            File(resource.filePath),
            fit: BoxFit.contain,
            alignment: widget.imageAlignment,
            cacheWidth: cacheWidth,
            filterQuality: FilterQuality.low,
            semanticLabel: '${widget.page.chapterTitle}，第 ${widget.page.imageIndex + 1} 页',
            frameBuilder: (
              BuildContext context,
              Widget child,
              int? frame,
              bool wasSynchronouslyLoaded,
            ) {
              _handleFrame(frame);
              return child;
            },
            errorBuilder: _decodeError,
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _stopObservingScrollIdle();
    if (widget.trackScrollVisibility) {
      widget.scrollController.removeListener(_checkVisibility);
    }
    _releaseDecodedImage();
    _transformationController.dispose();
    _cancellationToken?.cancel('漫画图片 Cell 销毁');
    super.dispose();
  }
}

/// 返回至少为一的整数，避免图片解码参数出现零宽度。
int _mathMaxOne(int value) => value < 1 ? 1 : value;

/// 为简短替代文本提供空值回退，不引入可空强制解包。
extension _MangaAltTextFallback on String {
  /// 空字符串时返回 [fallback]。
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}
