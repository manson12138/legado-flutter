import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../help/media/app_media_directories.dart';
import '../../help/media/media_cache_downloader.dart';
import '../../platform/local_book_cover_service.dart';
import 'cover_url_cache.dart';

/// 统一处理书架和详情封面、缺失占位、加载失败和跨页面已知可用地址回退。
///
/// 渲染顺序固定为：先尝试当前资源自身声明的 [coverUrl]；如果为空或加载失败，且
/// 调用方提供了 [bookName]/[bookAuthor]，就去 [CoverUrlCache] 找同一本书之前在任意
/// 页面成功显示过的地址再试一次；两者都不可用才展示统一占位图标。任意一次成功
/// 加载都会把该地址写回缓存，供其他页面下次直接复用，不需要重新试错。
final class BookCover extends StatefulWidget {
  /// 创建公共封面组件。
  const BookCover({
    required this.coverUrl,
    required this.semanticLabel,
    this.fit = BoxFit.cover,
    this.borderRadius = const BorderRadius.all(Radius.circular(8)),
    this.bookName,
    this.bookAuthor,
    this.keepPreviousFrame = false,
    this.onExhausted,
    this.onTransitionCacheLookup,
    this.onTransitionImageFrame,
    super.key,
  });

  /// 网络 URL、本地文件 URL、本地完整路径或应用私有封面稳定标识。
  final String? coverUrl;
  /// 无障碍封面说明。
  final String semanticLabel;
  /// 图片填充方式。
  final BoxFit fit;
  /// 统一圆角。
  final BorderRadius borderRadius;
  /// 书名；和 [bookAuthor] 同时提供时才启用跨页面已知可用地址缓存。
  final String? bookName;
  /// 作者名；和 [bookName] 同时提供时才启用跨页面已知可用地址缓存。
  final String? bookAuthor;
  /// 地址更新时是否保留上一帧，适合详情快照被异步完整数据替换的场景。
  final bool keepPreviousFrame;
  /// 自身地址和缓存候选都无法显示时的回调，供调用方切换到自己另外掌握的候选地址。
  final VoidCallback? onExhausted;
  /// FLUTTER_REWRITE_DEBUG_LOG：仅供阅读转场统计同步缓存检查耗时与命中状态。
  final void Function(Duration elapsed, bool cacheHit)?
      onTransitionCacheLookup;
  /// FLUTTER_REWRITE_DEBUG_LOG：仅供阅读转场记录图片帧时机及是否同步命中解码缓存。
  final void Function(bool wasSynchronouslyLoaded)?
      onTransitionImageFrame;

  /// 创建加载状态。
  @override
  State<BookCover> createState() => _BookCoverState();
}

/// 持有当前尝试地址和是否已经用过缓存候选。
final class _BookCoverState extends State<BookCover> {
  /// 当前正在尝试展示的地址；为空表示没有可尝试的地址，直接展示占位。
  String? _attemptUrl;
  /// 当前显示地址对应的稳定持久化值，受管本地封面不会回写易变绝对路径。
  String? _attemptPersistentUrl;
  /// 等待 Application Support 目录就绪后解析的受管封面标识。
  String? _pendingManagedReference;
  /// 是否已经尝试过缓存候选，避免主地址失败后反复查询。
  bool _usedCacheFallback = false;
  /// 已经成功写入缓存的地址，避免同一次加载重复写入。
  String? _rememberedUrl;

  /// 初始化首次尝试地址。
  @override
  void initState() {
    super.initState();
    _resetAttempt();
  }

  /// 上层传入新地址时重新从头尝试。
  @override
  void didUpdateWidget(covariant BookCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.coverUrl != widget.coverUrl) {
      _resetAttempt();
    }
  }

  /// 把当前尝试重置为调用方提供的原始地址；为空时立即尝试缓存候选。
  void _resetAttempt() {
    /// 清理后的原始地址。
    final String originalValue = widget.coverUrl?.trim() ?? '';
    /// 书名为空时不启用跨页面缓存。
    final String? name = widget.bookName;
    /// 作者为空时不启用跨页面缓存。
    final String? author = widget.bookAuthor;
    /// 当前进程曾成功显示的同步缓存，避免列表重建后先闪占位。
    final String? memoryCachedValue = originalValue.isEmpty &&
            name != null &&
            author != null
        ? CoverUrlCache.instance.lookupSync(name: name, author: author)
        : null;
    /// 优先使用调用方事实，没有地址时才使用进程内已知可用地址。
    final String initialValue = originalValue.isNotEmpty
        ? originalValue
        : memoryCachedValue?.trim() ?? '';
    _usedCacheFallback = memoryCachedValue != null;
    _rememberedUrl = null;
    _attemptPersistentUrl = initialValue.isEmpty
        ? null
        : LocalBookCoverReference.normalize(initialValue);
    _attemptUrl = initialValue.isEmpty
        ? null
        : LocalBookCoverReference.resolveSync(initialValue);
    _pendingManagedReference = initialValue.isNotEmpty &&
            _attemptUrl == null &&
            LocalBookCoverReference.isManaged(initialValue)
        ? initialValue
        : null;
    final String? pendingManagedReference = _pendingManagedReference;
    if (pendingManagedReference != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => unawaited(_resolveManagedReference(pendingManagedReference)),
      );
    } else if (_attemptUrl == null) {
      /// 原始地址为空时没有“加载失败”事件可依赖，直接主动查一次缓存。
      WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_tryCacheFallback()));
    }
  }

  /// 异步取得当前运行真实沙盒路径，完成后直接进入图片缓存加载链路。
  Future<void> _resolveManagedReference(String reference) async {
    /// 当前运行可读取的真实文件路径。
    final String? resolvedPath = await LocalBookCoverReference.resolve(reference);
    if (!mounted || _pendingManagedReference != reference) {
      return;
    }
    _pendingManagedReference = null;
    if (resolvedPath == null || resolvedPath.isEmpty) {
      await _tryCacheFallback();
      return;
    }
    setState(() {
      _attemptUrl = resolvedPath;
      _attemptPersistentUrl = LocalBookCoverReference.normalize(reference);
    });
  }

  /// 从缓存里找一个和刚失败地址不同的候选；找不到就走向调用方的 onExhausted。
  Future<void> _tryCacheFallback() async {
    if (!mounted || _usedCacheFallback) {
      return;
    }
    _usedCacheFallback = true;
    /// 书名。
    final String? name = widget.bookName;
    /// 作者名。
    final String? author = widget.bookAuthor;
    if (name == null || author == null) {
      widget.onExhausted?.call();
      return;
    }
    /// 缓存里已知可用的地址。
    final String? cached = await CoverUrlCache.instance.lookup(name: name, author: author);
    if (!mounted) {
      return;
    }
    /// 当前调用方地址的稳定形式。
    final String currentValue = LocalBookCoverReference.normalize(
      widget.coverUrl?.trim() ?? '',
    );
    if (cached == null ||
        LocalBookCoverReference.normalize(cached) == currentValue) {
      widget.onExhausted?.call();
      return;
    }
    /// 缓存地址在当前运行中对应的同步显示路径。
    final String? resolvedCached = LocalBookCoverReference.resolveSync(cached);
    if (resolvedCached != null && resolvedCached.isNotEmpty) {
      setState(() {
        _attemptUrl = resolvedCached;
        _attemptPersistentUrl = LocalBookCoverReference.normalize(cached);
      });
      return;
    }
    if (!LocalBookCoverReference.isManaged(cached)) {
      widget.onExhausted?.call();
      return;
    }
    /// 稳定本地标识等待目录预热后的真实路径。
    final String? resolvedManaged = await LocalBookCoverReference.resolve(cached);
    if (!mounted || resolvedManaged == null || resolvedManaged.isEmpty) {
      widget.onExhausted?.call();
      return;
    }
    setState(() {
      _attemptUrl = resolvedManaged;
      _attemptPersistentUrl = LocalBookCoverReference.normalize(cached);
    });
  }

  /// 记录成功加载的地址；同一次加载只写入一次。
  void _rememberSuccess(String url) {
    /// 受管本地封面使用稳定标识，其他地址使用真实显示地址。
    final String rememberedValue = _attemptPersistentUrl ?? url;
    if (_rememberedUrl == rememberedValue) {
      return;
    }
    _rememberedUrl = rememberedValue;
    /// 书名。
    final String? name = widget.bookName;
    /// 作者名。
    final String? author = widget.bookAuthor;
    if (name == null || author == null) {
      return;
    }
    CoverUrlCache.instance.remember(
      name: name,
      author: author,
      url: rememberedValue,
    );
  }

  /// 当前尝试地址加载失败：先查缓存，查过还是不行就展示占位并通知调用方。
  void _onAttemptFailed() {
    if (!mounted) {
      return;
    }
    if (!_usedCacheFallback) {
      unawaited(_tryCacheFallback());
      return;
    }
    if (_attemptUrl != null) {
      setState(() => _attemptUrl = null);
    }
  }

  /// 构建当前尝试地址的图片，失败或为空时展示统一占位。
  @override
  Widget build(BuildContext context) {
    /// 封面失败占位构建器。
    Widget fallback(BuildContext context, Object? error, StackTrace? stackTrace) {
      if (error != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _onAttemptFailed());
      }
      return ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Center(
          child: Icon(
            Icons.menu_book_outlined,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            semanticLabel: '${widget.semanticLabel}，暂无封面',
          ),
        ),
      );
    }

    /// 当前需要展示的地址。
    final String? value = _attemptUrl;
    if (value == null || value.isEmpty) {
      return ClipRRect(borderRadius: widget.borderRadius, child: fallback(context, null, null));
    }
    /// 首帧成功解码时记录成功地址。
    void handleFrame(int? frame, bool wasSynchronouslyLoaded) {
      if (frame != null) {
        // FLUTTER_REWRITE_DEBUG_LOG：回调只传递时机，不传递 URL、路径或图片内容。
        widget.onTransitionImageFrame?.call(wasSynchronouslyLoaded);
        WidgetsBinding.instance.addPostFrameCallback((_) => _rememberSuccess(value));
      }
    }

    /// 可解析的封面 URI。
    final Uri? uri = Uri.tryParse(value);
    /// 网络或本地图片组件。
    final Widget image;
    if (uri?.scheme == 'http' || uri?.scheme == 'https') {
      /// FLUTTER_REWRITE_DEBUG_LOG：只有转场传入诊断回调时才创建同步缓存检查计时器。
      final Stopwatch? transitionCacheLookupStopwatch =
          widget.onTransitionCacheLookup == null
          ? null
          : (Stopwatch()..start());
      /// 已经落盘的本地缓存；命中时直接读本地文件，完全不发起网络请求。
      final File? cachedFile = MediaCacheDownloader.instance.lookupCachedFileSync(
        value,
        MediaCategory.cover,
      );
      /// FLUTTER_REWRITE_DEBUG_LOG：同步缓存检查的可空耗时，普通封面不采集。
      final Duration? transitionCacheLookupElapsed =
          transitionCacheLookupStopwatch?.elapsed;
      if (transitionCacheLookupElapsed != null) {
        // FLUTTER_REWRITE_DEBUG_LOG：只报告耗时和布尔命中，不暴露封面地址或文件路径。
        widget.onTransitionCacheLookup?.call(
          transitionCacheLookupElapsed,
          cachedFile != null,
        );
      }
      if (cachedFile != null) {
        image = Image.file(
          cachedFile,
          key: widget.keepPreviousFrame ? null : ValueKey<String>(value),
          fit: widget.fit,
          gaplessPlayback: widget.keepPreviousFrame,
          semanticLabel: widget.semanticLabel,
          errorBuilder: fallback,
          frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
            handleFrame(frame, wasSynchronouslyLoaded);
            return child;
          },
        );
      } else {
        image = Image.network(
          value,
          key: widget.keepPreviousFrame ? null : ValueKey<String>(value),
          fit: widget.fit,
          gaplessPlayback: widget.keepPreviousFrame,
          semanticLabel: widget.semanticLabel,
          errorBuilder: fallback,
          frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
            handleFrame(frame, wasSynchronouslyLoaded);
            return child;
          },
        );
        /// 展示网络图的同时后台补齐本地缓存，下次同一地址直接命中本地。
        unawaited(MediaCacheDownloader.instance.resolve(value, MediaCategory.cover));
      }
    } else {
      /// file URI 使用系统路径，普通文本直接作为完整路径。
      final String path = uri?.scheme == 'file' ? uri?.toFilePath() ?? value : value;
      image = Image.file(
        File(path),
        key: widget.keepPreviousFrame ? null : ValueKey<String>(value),
        fit: widget.fit,
        gaplessPlayback: widget.keepPreviousFrame,
        semanticLabel: widget.semanticLabel,
        errorBuilder: fallback,
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
          handleFrame(frame, wasSynchronouslyLoaded);
          return child;
        },
      );
    }
    return ClipRRect(borderRadius: widget.borderRadius, child: image);
  }
}
