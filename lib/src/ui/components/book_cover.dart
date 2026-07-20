import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

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
    this.onExhausted,
    super.key,
  });

  /// 网络 URL、本地文件 URL 或本地完整路径。
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
  /// 自身地址和缓存候选都无法显示时的回调，供调用方切换到自己另外掌握的候选地址。
  final VoidCallback? onExhausted;

  /// 创建加载状态。
  @override
  State<BookCover> createState() => _BookCoverState();
}

/// 持有当前尝试地址和是否已经用过缓存候选。
final class _BookCoverState extends State<BookCover> {
  /// 当前正在尝试展示的地址；为空表示没有可尝试的地址，直接展示占位。
  String? _attemptUrl;
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
    final String trimmed = widget.coverUrl?.trim() ?? '';
    _usedCacheFallback = false;
    _rememberedUrl = null;
    _attemptUrl = trimmed.isEmpty ? null : trimmed;
    if (_attemptUrl == null) {
      /// 原始地址为空时没有“加载失败”事件可依赖，直接主动查一次缓存。
      WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_tryCacheFallback()));
    }
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
    if (cached == null || cached == widget.coverUrl?.trim()) {
      widget.onExhausted?.call();
      return;
    }
    setState(() => _attemptUrl = cached);
  }

  /// 记录成功加载的地址；同一次加载只写入一次。
  void _rememberSuccess(String url) {
    if (_rememberedUrl == url) {
      return;
    }
    _rememberedUrl = url;
    /// 书名。
    final String? name = widget.bookName;
    /// 作者名。
    final String? author = widget.bookAuthor;
    if (name == null || author == null) {
      return;
    }
    CoverUrlCache.instance.remember(name: name, author: author, url: url);
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
    void handleFrame(int? frame) {
      if (frame != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _rememberSuccess(value));
      }
    }

    /// 可解析的封面 URI。
    final Uri? uri = Uri.tryParse(value);
    /// 网络或本地图片组件。
    final Widget image;
    if (uri?.scheme == 'http' || uri?.scheme == 'https') {
      image = Image.network(
        value,
        key: ValueKey<String>(value),
        fit: widget.fit,
        semanticLabel: widget.semanticLabel,
        errorBuilder: fallback,
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
          handleFrame(frame);
          return child;
        },
      );
    } else {
      /// file URI 使用系统路径，普通文本直接作为完整路径。
      final String path = uri?.scheme == 'file' ? uri?.toFilePath() ?? value : value;
      image = Image.file(
        File(path),
        key: ValueKey<String>(value),
        fit: widget.fit,
        semanticLabel: widget.semanticLabel,
        errorBuilder: fallback,
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
          handleFrame(frame);
          return child;
        },
      );
    }
    return ClipRRect(borderRadius: widget.borderRadius, child: image);
  }
}
