import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

/// 在连续和分页阅读模式中共用的正文图片视图。
///
/// 图片由 Flutter ImageProvider 加载；重试只重建当前资源请求，保存入口交给路由层打开
/// 系统分享面板，避免 Widget 直接访问文件系统或自行申请平台权限。
final class ReaderContentImageView extends StatefulWidget {
  /// 创建带失败重试和保存入口的正文图片。
  const ReaderContentImageView({
    required this.imageUrl,
    required this.altText,
    required this.referer,
    required this.onSave,
    this.maximumHeight,
    super.key,
  });

  /// 已由正文处理管线校验的 HTTP(S) 图片地址。
  final String imageUrl;

  /// 图片加载失败时展示的替代文本。
  final String altText;

  /// 图片防盗链请求可携带的正文页面 Referer。
  final String referer;

  /// 用户请求保存或分享图片时的路由层回调。
  final VoidCallback onSave;

  /// 分页模式允许图片占用的最大高度；连续模式为空时按图片比例展示。
  final double? maximumHeight;

  /// 创建图片请求重试状态。
  @override
  State<ReaderContentImageView> createState() => _ReaderContentImageViewState();
}

/// 持有当前图片的本地重试世代，不进入阅读器业务状态。
final class _ReaderContentImageViewState extends State<ReaderContentImageView> {
  /// 每次失败重试递增，用于创建新的 Image Widget 和网络请求。
  int _retryGeneration = 0;

  /// 重新创建当前图片请求，不刷新章节正文或其他图片。
  void _retry() {
    setState(() {
      _retryGeneration += 1;
    });
  }

  /// 构建受高度限制的图片、加载进度、失败提示和保存入口。
  @override
  Widget build(BuildContext context) {
    /// 分页模式传入的安全最大高度。
    final double? maximumHeight = widget.maximumHeight;
    /// 防盗链图片请求头；空来源不发送 Referer。
    final Map<String, String>? headers = widget.referer.isEmpty
        ? null
        : <String, String>{'Referer': widget.referer};
    /// 图片主体和状态占位。
    final Widget image = Image.network(
      widget.imageUrl,
      key: ValueKey<String>('${widget.imageUrl}#$_retryGeneration'),
      fit: BoxFit.contain,
      width: double.infinity,
      height: maximumHeight,
      headers: headers,
      loadingBuilder: (
        BuildContext imageContext,
        Widget child,
        ImageChunkEvent? loadingProgress,
      ) {
        if (loadingProgress == null) {
          return child;
        }
        /// 已知总字节数时显示确定进度，否则显示循环进度。
        final int? expectedBytes = loadingProgress.expectedTotalBytes;
        /// 当前图片加载进度。
        final double? progress = expectedBytes == null || expectedBytes <= 0
            ? null
            : loadingProgress.cumulativeBytesLoaded / expectedBytes;
        return SizedBox(
          height: maximumHeight ?? 180,
          child: Center(child: CircularProgressIndicator(value: progress)),
        );
      },
      errorBuilder: (
        BuildContext imageContext,
        Object imageError,
        StackTrace? imageStackTrace,
      ) {
        return SizedBox(
          height: maximumHeight ?? 180,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Icon(Icons.broken_image_outlined),
                const SizedBox(height: SpacingToken.small),
                Text(
                  widget.altText.isEmpty ? '正文图片加载失败' : widget.altText,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                ),
                TextButton.icon(
                  onPressed: _retry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重试'),
                ),
              ],
            ),
          ),
        );
      },
    );
    return Stack(
      alignment: Alignment.topRight,
      children: <Widget>[
        image,
        IconButton.filledTonal(
          onPressed: widget.onSave,
          icon: const Icon(Icons.save_alt),
          tooltip: '保存或分享图片',
        ),
      ],
    );
  }
}
