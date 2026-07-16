import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../help/logging/app_logger.dart';

/// 统一记录全部 Dio 请求、响应和异常，同时遮盖常见认证字段。
final class AppDioLogInterceptor extends Interceptor {
  /// 创建绑定应用日志器的网络拦截器。
  AppDioLogInterceptor({required AppLogger logger}) : _logger = logger;

  /// 请求开始时间在 Dio extra 中使用的内部键。
  static const String _requestStartedAtKey = '_legadoLogStartedAt';

  /// 判断 Header、查询参数或结构化正文键是否敏感的关键词。
  static const Set<String> _sensitiveKeys = <String>{
    'authorization',
    'cookie',
    'set-cookie',
    'token',
    'access_token',
    'refresh_token',
    'password',
    'passwd',
    'secret',
    'api_key',
    'apikey',
  };

  /// 应用组合根注入的统一日志器。
  final AppLogger _logger;

  /// 在请求发出前记录配置；扫码请求只记录安全摘要，不输出地址或正文。
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra[_requestStartedAtKey] = DateTime.now().microsecondsSinceEpoch;
    /// 【扫码诊断日志】当前请求是否属于扫码添加书源链路。
    final bool isBookSourceQrRequest = _isBookSourceQrRequest(options);
    /// 【扫码诊断日志】当前请求使用的 Logcat Tag。
    final String requestLogTag = _requestLogTag(options);
    /// 【扫码诊断日志】当前请求的稳定业务前缀。
    final String requestLogPrefix = _requestLogPrefix(options);
    _logger.info(
      tag: requestLogTag,
      message: '${requestLogPrefix}stage=http_transport_request\n'
          'method=${options.method}\n'
          'target=${_formatRequestTarget(options.uri, hideAddress: isBookSourceQrRequest)}\n'
          'connectTimeoutMs=${options.connectTimeout?.inMilliseconds ?? -1}\n'
          'sendTimeoutMs=${options.sendTimeout?.inMilliseconds ?? -1}\n'
          'receiveTimeoutMs=${options.receiveTimeout?.inMilliseconds ?? -1}\n'
          'followRedirects=${options.followRedirects}\n'
          'maxRedirects=${options.maxRedirects}\n'
          'responseType=${options.responseType.name}\n'
          'headers=${isBookSourceQrRequest ? _formatRequestHeaderSummary(options.headers) : _formatJson(_sanitizeMap(options.headers))}\n'
          'body=${isBookSourceQrRequest ? _formatBodySummary(options.data, options.contentType) : _formatRequestBody(options.data, options.contentType)}',
    );
    handler.next(options);
  }

  /// 在响应返回后记录状态和耗时；扫码请求只记录安全摘要。
  @override
  void onResponse(Response<dynamic> response, ResponseInterceptorHandler handler) {
    /// 【扫码诊断日志】Dio 返回的原始请求配置。
    final RequestOptions request = response.requestOptions;
    /// 【扫码诊断日志】当前请求是否属于扫码添加书源链路。
    final bool isBookSourceQrRequest = _isBookSourceQrRequest(request);
    /// 【扫码诊断日志】当前请求使用的 Logcat Tag。
    final String requestLogTag = _requestLogTag(request);
    /// 【扫码诊断日志】当前请求的稳定业务前缀。
    final String requestLogPrefix = _requestLogPrefix(request);
    _logger.info(
      tag: requestLogTag,
      message: '${requestLogPrefix}stage=http_transport_response\n'
          'method=${request.method}\n'
          'target=${_formatRequestTarget(response.realUri, hideAddress: isBookSourceQrRequest)}\n'
          'status=${response.statusCode ?? 0}\n'
          'durationMs=${_durationMilliseconds(request)}\n'
          'redirectCount=${response.redirects.length}\n'
          'contentType=${response.headers.value('content-type') ?? 'none'}\n'
          'headers=${isBookSourceQrRequest ? _formatResponseHeaderSummary(response.headers.map) : _formatJson(_sanitizeResponseHeaders(response.headers.map))}\n'
          'body=${isBookSourceQrRequest ? _formatBodySummary(response.data, response.headers.value('content-type')) : _formatResponseBody(response.data, response.headers.value('content-type'))}',
    );
    handler.next(response);
  }

  /// 在请求失败时记录错误类型、耗时和可能存在的服务端响应。
  @override
  void onError(DioException error, ErrorInterceptorHandler handler) {
    /// 【扫码诊断日志】发生异常的原始请求配置。
    final RequestOptions request = error.requestOptions;
    /// 【扫码诊断日志】服务端可能已经返回的响应。
    final Response<dynamic>? response = error.response;
    /// 【扫码诊断日志】Dio 包装的底层传输异常。
    final Object? transportError = error.error;
    /// 【扫码诊断日志】当前请求是否属于扫码添加书源链路。
    final bool isBookSourceQrRequest = _isBookSourceQrRequest(request);
    /// 【扫码诊断日志】当前请求使用的 Logcat Tag。
    final String requestLogTag = _requestLogTag(request);
    /// 【扫码诊断日志】当前请求的稳定业务前缀。
    final String requestLogPrefix = _requestLogPrefix(request);
    _logger.error(
      tag: requestLogTag,
      message: '${requestLogPrefix}stage=http_transport_error\n'
          'method=${request.method}\n'
          'target=${_formatRequestTarget(request.uri, hideAddress: isBookSourceQrRequest)}\n'
          'dioType=${error.type.name}\n'
          'cause=${_formatTransportError(transportError)}\n'
          'responsePresent=${response != null}\n'
          'status=${response?.statusCode ?? 0}\n'
          'durationMs=${_durationMilliseconds(request)}\n'
          'connectTimeoutMs=${request.connectTimeout?.inMilliseconds ?? -1}\n'
          'sendTimeoutMs=${request.sendTimeout?.inMilliseconds ?? -1}\n'
          'receiveTimeoutMs=${request.receiveTimeout?.inMilliseconds ?? -1}\n'
          'followRedirects=${request.followRedirects}\n'
          'maxRedirects=${request.maxRedirects}\n'
          'redirectCount=${response?.redirects.length ?? 0}\n'
          'responseHeaders=${isBookSourceQrRequest ? _formatResponseHeaderSummary(response?.headers.map ?? const <String, List<String>>{}) : _formatJson(_sanitizeResponseHeaders(response?.headers.map ?? const <String, List<String>>{}))}\n'
          'responseBody=${isBookSourceQrRequest ? _formatBodySummary(response?.data, response?.headers.value('content-type')) : _formatResponseBody(response?.data, response?.headers.value('content-type'))}',
      // 【扫码诊断日志】扫码请求不附加可能包含目标地址的原始异常文本。
      error: isBookSourceQrRequest ? null : transportError ?? error,
      stackTrace: error.stackTrace,
    );
    handler.next(error);
  }

  /// 【扫码诊断日志】判断请求是否属于二维码添加书源业务。
  bool _isBookSourceQrRequest(RequestOptions request) {
    return request.extra[networkRequestLogContextExtraKey] == bookSourceQrScanLogTag;
  }

  /// 【扫码诊断日志】根据业务上下文选择稳定的 Logcat Tag。
  String _requestLogTag(RequestOptions request) {
    return _isBookSourceQrRequest(request) ? bookSourceQrLogTag : networkLogTag;
  }

  /// 【扫码诊断日志】返回用于串联二维码添加书源全链路的稳定前缀。
  String _requestLogPrefix(RequestOptions request) {
    return _isBookSourceQrRequest(request) ? '$bookSourceQrScanLogTag ' : '';
  }

  /// 【扫码诊断日志】格式化请求目标；扫码请求只保留结构，不输出地址正文。
  String _formatRequestTarget(Uri uri, {required bool hideAddress}) {
    if (!hideAddress) {
      return _sanitizeUri(uri);
    }
    return 'scheme=${uri.scheme.toLowerCase()} '
        'hostChars=${uri.host.length} '
        'port=${uri.hasPort ? uri.port : 0} '
        'pathChars=${uri.path.length} '
        'pathSegments=${uri.pathSegments.length} '
        'queryParameters=${uri.queryParametersAll.length} '
        'fragmentPresent=${uri.hasFragment}';
  }

  /// 【扫码诊断日志】安全格式化底层传输异常，不输出主机名、地址或请求正文。
  String _formatTransportError(Object? error) {
    if (error == null) {
      return 'type=none';
    }
    if (error is SocketException) {
      /// 【扫码诊断日志】Socket 异常携带的系统错误对象。
      final OSError? osError = error.osError;
      return 'type=${error.runtimeType} '
          'osErrorType=${osError?.runtimeType.toString() ?? 'none'} '
          'osErrorCode=${osError?.errorCode ?? 0} '
          'osErrorMessage=${_singleLineDiagnosticText(osError?.message ?? 'none')}';
    }
    if (error is HandshakeException) {
      return 'type=${error.runtimeType} category=tls_handshake '
          'message=${_singleLineDiagnosticText(error.message)}';
    }
    if (error is TlsException) {
      return 'type=${error.runtimeType} category=tls '
          'message=${_singleLineDiagnosticText(error.message)}';
    }
    if (error is HttpException) {
      return 'type=${error.runtimeType} category=http_transport '
          'message=${_singleLineDiagnosticText(error.message)}';
    }
    if (error is String) {
      return 'type=String category=transport_message '
          'message=${_singleLineDiagnosticText(error)}';
    }
    return 'type=${error.runtimeType} category=unmapped';
  }

  /// 【扫码诊断日志】把允许输出的系统诊断文本压缩为安全单行。
  String _singleLineDiagnosticText(String value) {
    /// 【扫码诊断日志】去除换行后的系统错误说明。
    final String singleLineValue = value
        .replaceAll(RegExp(r'https?://[^\s,;)]+', caseSensitive: false), '<redacted-url>')
        .replaceAll(RegExp(r'[\r\n]+'), ' ')
        .trim();
    if (singleLineValue.length <= 200) {
      return singleLineValue;
    }
    return '${singleLineValue.substring(0, 200)}<truncated>';
  }

  /// 【扫码诊断日志】汇总请求 Header，只记录数量和敏感 Header 是否存在。
  String _formatRequestHeaderSummary(Map<String, dynamic> headers) {
    /// 【扫码诊断日志】统一为小写的请求 Header 名称集合。
    final Set<String> normalizedNames = headers.keys
        .map((String name) => name.toLowerCase())
        .toSet();
    return 'count=${headers.length} '
        'hasUserAgent=${normalizedNames.contains('user-agent')} '
        'hasCookie=${normalizedNames.contains('cookie')} '
        'hasAuthorization=${normalizedNames.contains('authorization')}';
  }

  /// 【扫码诊断日志】汇总响应 Header，不输出 Header 名称和值。
  String _formatResponseHeaderSummary(Map<String, List<String>> headers) {
    return 'count=${headers.length}';
  }

  /// 【扫码诊断日志】汇总扫码请求正文或响应体，只记录类型、字节数和媒体类型。
  String _formatBodySummary(Object? data, String? contentType) {
    if (data == null) {
      return 'type=none bytes=0 contentType=${contentType ?? 'none'}';
    }
    if (data is Uint8List) {
      return 'type=Uint8List bytes=${data.length} contentType=${contentType ?? 'none'}';
    }
    if (data is List<int>) {
      return 'type=List<int> bytes=${data.length} contentType=${contentType ?? 'none'}';
    }
    return 'type=${data.runtimeType} bytes=unknown contentType=${contentType ?? 'none'}';
  }

  /// 遮盖 URL 查询参数中的认证信息，同时保留可用于复现请求的其他参数。
  String _sanitizeUri(Uri uri) {
    if (uri.queryParametersAll.isEmpty) {
      return uri.toString();
    }
    final Map<String, List<String>> safeParameters = <String, List<String>>{};
    uri.queryParametersAll.forEach((String key, List<String> values) {
      safeParameters[key] = _isSensitiveKey(key)
          ? const <String>['<redacted>']
          : List<String>.from(values);
    });
    return uri.replace(queryParameters: safeParameters).toString();
  }

  /// 递归复制结构化 Header 或正文，并遮盖敏感键对应的值。
  Map<String, Object?> _sanitizeMap(Map<dynamic, dynamic> source) {
    final Map<String, Object?> result = <String, Object?>{};
    source.forEach((dynamic key, dynamic value) {
      final String stringKey = key.toString();
      result[stringKey] = _isSensitiveKey(stringKey)
          ? '<redacted>'
          : _sanitizeValue(value);
    });
    return result;
  }

  /// 把任意结构化值转换为可安全写入日志的副本。
  Object? _sanitizeValue(Object? value) {
    if (value is Map) {
      return _sanitizeMap(value);
    }
    if (value is Iterable) {
      return value.map<Object?>(_sanitizeValue).toList(growable: false);
    }
    return value;
  }

  /// 遮盖 Dio 多值响应 Header 中的 Cookie 和认证字段。
  Map<String, Object?> _sanitizeResponseHeaders(Map<String, List<String>> source) {
    final Map<String, Object?> result = <String, Object?>{};
    source.forEach((String key, List<String> values) {
      result[key] = _isSensitiveKey(key)
          ? '<redacted>'
          : List<String>.from(values);
    });
    return result;
  }

  /// 根据正文运行时类型输出文本、JSON、表单信息或二进制摘要。
  String _formatRequestBody(Object? data, String? contentType) {
    if (data == null) {
      return '<empty>';
    }
    if (data is FormData) {
      final Map<String, Object?> fields = <String, Object?>{};
      for (final MapEntry<String, String> field in data.fields) {
        fields[field.key] = _isSensitiveKey(field.key)
            ? '<redacted>'
            : field.value;
      }
      final List<Map<String, Object?>> files = data.files
          .map(
            (MapEntry<String, MultipartFile> entry) => <String, Object?>{
              'field': entry.key,
              'fileName': entry.value.filename,
              'length': entry.value.length,
            },
          )
          .toList(growable: false);
      return _formatJson(<String, Object?>{'fields': fields, 'files': files});
    }
    if (data is Map) {
      return _formatJson(_sanitizeMap(data));
    }
    if (data is Iterable && data is! List<int>) {
      return _formatJson(_sanitizeValue(data));
    }
    if (data is Uint8List) {
      return _formatBytes(data, contentType);
    }
    if (data is List<int>) {
      return _formatBytes(Uint8List.fromList(data), contentType);
    }
    return _redactSensitiveText(data.toString());
  }

  /// 根据响应媒体类型完整输出文本响应，二进制响应只记录字节数。
  String _formatResponseBody(Object? data, String? contentType) {
    if (data == null) {
      return '<empty>';
    }
    if (data is Uint8List) {
      return _formatBytes(data, contentType);
    }
    if (data is List<int>) {
      return _formatBytes(Uint8List.fromList(data), contentType);
    }
    if (data is Map) {
      return _formatJson(_sanitizeMap(data));
    }
    if (data is Iterable) {
      return _formatJson(_sanitizeValue(data));
    }
    return _redactSensitiveText(data.toString());
  }

  /// 文本媒体类型使用 UTF-8 完整解码，其他媒体类型返回稳定二进制摘要。
  String _formatBytes(Uint8List bytes, String? contentType) {
    if (bytes.isEmpty) {
      return '<empty>';
    }
    final String normalizedType = contentType?.toLowerCase() ?? '';
    final bool isText = normalizedType.startsWith('text/') ||
        normalizedType.contains('json') ||
        normalizedType.contains('xml') ||
        normalizedType.contains('html') ||
        normalizedType.contains('javascript') ||
        normalizedType.contains('x-www-form-urlencoded');
    if (normalizedType.isEmpty) {
      try {
        return _redactSensitiveText(utf8.decode(bytes));
      } on FormatException {
        return '<binary length=${bytes.length} contentType=unknown>';
      }
    }
    if (!isText) {
      return '<binary length=${bytes.length} contentType=${contentType ?? 'unknown'}>';
    }
    return _redactSensitiveText(utf8.decode(bytes, allowMalformed: true));
  }

  /// 对无法结构化解析的文本遮盖常见 JSON 与表单认证字段。
  String _redactSensitiveText(String value) {
    String result = value;
    for (final String key in _sensitiveKeys) {
      final RegExp jsonPattern = RegExp(
        '("$key"\\s*:\\s*")[^"]*(")',
        caseSensitive: false,
      );
      result = result.replaceAllMapped(
        jsonPattern,
        (Match match) => '${match.group(1)}<redacted>${match.group(2)}',
      );
      final RegExp formPattern = RegExp(
        '(^|[&?])($key)=([^&]*)',
        caseSensitive: false,
      );
      result = result.replaceAllMapped(
        formPattern,
        (Match match) => '${match.group(1)}${match.group(2)}=<redacted>',
      );
    }
    return result;
  }

  /// 判断字段名称是否包含常见认证或隐私关键词。
  bool _isSensitiveKey(String key) {
    final String normalizedKey = key.toLowerCase().replaceAll('-', '_');
    return _sensitiveKeys.any(normalizedKey.contains);
  }

  /// 把结构化对象转换成带缩进的稳定 JSON 文本。
  String _formatJson(Object? value) {
    try {
      return const JsonEncoder.withIndent('  ').convert(value);
    } on JsonUnsupportedObjectError {
      return value.toString();
    }
  }

  /// 计算请求从进入拦截器到当前回调的毫秒耗时。
  int _durationMilliseconds(RequestOptions request) {
    final Object? startedAtValue = request.extra[_requestStartedAtKey];
    if (startedAtValue is! int) {
      return -1;
    }
    return (DateTime.now().microsecondsSinceEpoch - startedAtValue) ~/ 1000;
  }
}
