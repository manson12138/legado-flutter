import 'dart:io';

import 'package:flutter/material.dart';

/// 统一处理书架和详情封面、缺失占位与加载失败，不让列表项重复网络判断。
final class BookCover extends StatelessWidget {
  /// 创建公共封面组件。
  const BookCover({
    required this.coverUrl,
    required this.semanticLabel,
    this.fit = BoxFit.cover,
    this.borderRadius = const BorderRadius.all(Radius.circular(8)),
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

  /// 构建使用 Flutter ImageCache 的图片，并在失败时展示稳定占位。
  @override
  Widget build(BuildContext context) {
    /// 清理后的封面地址。
    final String value = coverUrl?.trim() ?? '';
    /// 封面失败占位构建器。
    Widget fallback(BuildContext context, Object? error, StackTrace? stackTrace) {
      return ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Center(
          child: Icon(
            Icons.menu_book_outlined,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            semanticLabel: '$semanticLabel，暂无封面',
          ),
        ),
      );
    }

    if (value.isEmpty) {
      return ClipRRect(borderRadius: borderRadius, child: fallback(context, null, null));
    }
    /// 可解析的封面 URI。
    final Uri? uri = Uri.tryParse(value);
    /// 网络或本地图片组件。
    final Widget image;
    if (uri?.scheme == 'http' || uri?.scheme == 'https') {
      image = Image.network(
        value,
        fit: fit,
        semanticLabel: semanticLabel,
        errorBuilder: fallback,
      );
    } else {
      /// file URI 使用系统路径，普通文本直接作为完整路径。
      final String path = uri?.scheme == 'file' ? uri?.toFilePath() ?? value : value;
      image = Image.file(
        File(path),
        fit: fit,
        semanticLabel: semanticLabel,
        errorBuilder: fallback,
      );
    }
    return ClipRRect(borderRadius: borderRadius, child: image);
  }
}
