import '../../api/http/http_contract.dart';
import '../model/book.dart';
import '../model/book_source.dart';
import '../model/manga_page.dart';

/// 漫画图片加载过程的字节进度，总长度未知时 [totalBytes] 为 null。
typedef MangaImageProgress = void Function(int receivedBytes, int? totalBytes);

/// 漫画图片获取失败的稳定分类，UI 不依赖 Dio 或文件系统异常类型。
enum MangaImageFailureKind {
  /// 页面或路由生命周期主动取消请求。
  cancelled,

  /// 图片地址或请求选项不合法。
  invalidRequest,

  /// 书源图片请求使用了当前跨平台实现不支持的选项。
  unsupportedRequestRule,

  /// DNS、连接、TLS 或超时等网络失败。
  network,

  /// 服务端返回非成功状态。
  httpStatus,

  /// 响应没有图片字节。
  emptyResponse,

  /// 图片文件超过受控字节或像素上限。
  tooLarge,

  /// MIME 或文件头不是当前支持的图片格式。
  unsupportedFormat,

  /// 图片缓存目录、临时文件或原子替换失败。
  cacheIo,
}

/// 漫画图片获取过程中向上层暴露的受控异常。
final class MangaImageException implements Exception {
  /// 创建不包含 URL、Cookie、Header 或本地绝对路径的安全异常。
  const MangaImageException(this.kind, this.message, {this.statusCode});

  /// 失败分类。
  final MangaImageFailureKind kind;

  /// 可直接转换为用户提示的安全说明。
  final String message;

  /// HTTP 状态失败时的可选状态码。
  final int? statusCode;

  @override
  String toString() => 'MangaImageException($kind, $message)';
}

/// 已完成校验并落入应用私有缓存的漫画图片资源。
final class MangaImageResource {
  /// 创建 UI 可以安全交给 `FileImage` 的不可变资源描述。
  const MangaImageResource({
    required this.filePath,
    required this.mimeType,
    required this.width,
    required this.height,
    required this.byteLength,
    required this.fromCache,
  });

  /// 应用私有缓存文件路径；业务层不得将其持久化或写入日志。
  final String filePath;

  /// 由文件头确认的图片 MIME。
  final String mimeType;

  /// 文件头声明的像素宽度。
  final int width;

  /// 文件头声明的像素高度。
  final int height;

  /// 缓存文件字节数。
  final int byteLength;

  /// 是否直接命中已有且通过复检的缓存。
  final bool fromCache;
}

/// 漫画图片网络获取、校验和私有缓存的统一边界。
abstract interface class MangaImageGateway {
  /// 获取一张漫画图片；同一缓存身份的并发调用由实现方单飞合并。
  Future<MangaImageResource> resolve({
    required Book book,
    required BookSource source,
    required MangaPage page,
    String? evaluatedSourceHeader,
    HttpCancellationToken? cancellationToken,
    MangaImageProgress? onProgress,
  });

  /// 删除一张图片的缓存，供解码失败或用户强制重试时重新下载。
  Future<void> invalidate({required Book book, required MangaPage page});
}
