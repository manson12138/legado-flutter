import 'dart:typed_data';

/// 统一 HTTP 请求方法，避免业务层依赖具体网络库的枚举。
enum HttpRequestMethod { get, post, put, patch, delete, head }

/// 统一 HTTP 请求体的不可变描述。
sealed class HttpRequestBody {
  /// 创建请求体描述。
  const HttpRequestBody();
}

/// 表示没有请求体。
final class EmptyHttpRequestBody extends HttpRequestBody {
  /// 创建空请求体。
  const EmptyHttpRequestBody();
}

/// 表示未经二次转换的文本请求体。
final class TextHttpRequestBody extends HttpRequestBody {
  /// 创建文本请求体。
  const TextHttpRequestBody(this.text, {this.contentType});

  /// 请求正文。
  final String text;

  /// 可选媒体类型；为空时由请求 Header 决定。
  final String? contentType;
}

/// 表示表单字段请求体。
final class FormHttpRequestBody extends HttpRequestBody {
  /// 创建不可变表单请求体。
  FormHttpRequestBody(Map<String, String> fields)
    : fields = Map<String, String>.unmodifiable(fields);

  /// 表单字段。
  final Map<String, String> fields;
}

/// 表示原始字节请求体。
final class BytesHttpRequestBody extends HttpRequestBody {
  /// 创建原始字节请求体。
  BytesHttpRequestBody(Uint8List bytes, {this.contentType})
    : bytes = Uint8List.fromList(bytes);

  /// 请求正文原始字节。
  final Uint8List bytes;

  /// 可选媒体类型。
  final String? contentType;
}

/// 统一 HTTP 请求；Header、Cookie、超时和重定向均在网络层处理。
final class HttpRequest {
  /// 创建不可变 HTTP 请求。
  HttpRequest({
    required this.uri,
    this.method = HttpRequestMethod.get,
    Map<String, String> headers = const <String, String>{},
    this.body = const EmptyHttpRequestBody(),
    this.connectTimeout = const Duration(seconds: 15),
    this.sendTimeout = const Duration(seconds: 15),
    this.receiveTimeout = const Duration(seconds: 60),
    this.totalTimeout = const Duration(seconds: 60),
    this.followRedirects = true,
    this.maxRedirects = 10,
    this.acceptHttpErrorStatus = false,
    this.cookieMode = HttpCookieMode.shared,
    this.sessionKey,
    this.logContext,
  }) : headers = Map<String, String>.unmodifiable(headers);

  /// 目标地址。
  final Uri uri;

  /// 请求方法。
  final HttpRequestMethod method;

  /// 请求 Header；不得写入包含敏感值的日志。
  final Map<String, String> headers;

  /// 请求体。
  final HttpRequestBody body;

  /// 建连超时。
  final Duration connectTimeout;

  /// 发送超时。
  final Duration sendTimeout;

  /// 接收超时。
  final Duration receiveTimeout;

  /// 包含重试与响应读取的总超时。
  final Duration totalTimeout;

  /// 是否跟随重定向。
  final bool followRedirects;

  /// 最大重定向次数。
  final int maxRedirects;

  /// 是否允许调用方自行处理非成功 HTTP 状态。
  final bool acceptHttpErrorStatus;

  /// Cookie 会话策略。
  final HttpCookieMode cookieMode;

  /// 独立会话键；仅在 [cookieMode] 为独立会话时使用。
  final String? sessionKey;

  /// 可选诊断日志上下文；仅用于串联请求日志，不参与网络请求。
  final String? logContext;
}

/// Cookie 会话策略。
enum HttpCookieMode {
  /// 不自动读取或保存 Cookie。
  disabled,

  /// 使用应用共享 Cookie 会话，对齐 Android 默认 Cookie Jar。
  shared,

  /// 使用由 `sessionKey` 标识的独立内存会话。
  isolated,
}

/// 统一 HTTP 响应，正文始终保留原始字节。
final class HttpResponse {
  /// 创建不可变 HTTP 响应。
  HttpResponse({
    required this.requestUri,
    required this.finalUri,
    required this.statusCode,
    required Uint8List bytes,
    Map<String, List<String>> headers = const <String, List<String>>{},
    this.reasonPhrase,
  }) : bytes = Uint8List.fromList(bytes),
       headers = Map<String, List<String>>.unmodifiable(
         headers.map(
           (String key, List<String> value) => MapEntry<String, List<String>>(
             key.toLowerCase(),
             List<String>.unmodifiable(value),
           ),
         ),
       );

  /// 初始请求地址。
  final Uri requestUri;

  /// 完成重定向后的最终地址；相对链接必须基于它解析。
  final Uri finalUri;

  /// HTTP 状态码。
  final int statusCode;

  /// 响应原始字节。
  final Uint8List bytes;

  /// 小写键的多值响应 Header。
  final Map<String, List<String>> headers;

  /// 可选状态说明。
  final String? reasonPhrase;

  /// 返回指定 Header 的首个值。
  String? firstHeader(String name) {
    /// Header 的全部值。
    final List<String>? values = headers[name.toLowerCase()];
    return values == null || values.isEmpty ? null : values.first;
  }
}

/// 网络失败分类，供 UI 和重试策略精确判断。
enum HttpFailureKind {
  cancelled,
  dns,
  connection,
  tls,
  connectTimeout,
  sendTimeout,
  receiveTimeout,
  totalTimeout,
  httpStatus,
  decode,
  unsupportedOption,
  unknown,
}

/// 统一网络异常；不携带 Cookie、Authorization 或正文。
final class UnifiedHttpException implements Exception {
  /// 创建安全的网络异常。
  const UnifiedHttpException(this.kind, this.message, {this.statusCode});

  /// 失败分类。
  final HttpFailureKind kind;

  /// 不含敏感数据的说明。
  final String message;

  /// HTTP 状态失败时的状态码。
  final int? statusCode;

  @override
  String toString() => 'UnifiedHttpException($kind, $message)';
}

/// 与具体网络库隔离的取消令牌。
abstract interface class HttpCancellationToken {
  /// 当前请求是否已经取消。
  bool get isCancelled;

  /// 取消所有使用本令牌的请求。
  void cancel([String reason = '用户取消请求']);
}

/// 统一 HTTP 客户端接口。
abstract interface class UnifiedHttpClient {
  /// 执行请求并返回原始响应。
  Future<HttpResponse> execute(
    HttpRequest request, {
    HttpCancellationToken? cancellationToken,
  });
}
