import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../cookie/cookie_manager.dart';
import 'http_contract.dart';

/// 基于 Dio 的取消令牌适配器，不向业务层暴露 Dio 类型。
final class DioHttpCancellationToken implements HttpCancellationToken {
  /// Dio 内部取消令牌。
  final CancelToken _token = CancelToken();

  /// 仅供网络适配器读取的 Dio 令牌。
  CancelToken get dioToken => _token;

  @override
  bool get isCancelled => _token.isCancelled;

  @override
  void cancel([String reason = '用户取消请求']) {
    if (!_token.isCancelled) {
      _token.cancel(reason);
    }
  }
}

/// Dio 统一 HTTP 实现；集中处理 Cookie、重定向、超时和错误映射。
final class DioUnifiedHttpClient implements UnifiedHttpClient {
  /// 创建网络客户端。
  DioUnifiedHttpClient(this._dio, this._cookieManager);

  /// 无全局敏感日志拦截器的 Dio 实例。
  final Dio _dio;

  /// 集中 Cookie 管理器。
  final LegadoCookieManager _cookieManager;

  @override
  Future<HttpResponse> execute(
    HttpRequest request, {
    HttpCancellationToken? cancellationToken,
  }) async {
    /// 实际使用的取消令牌。
    final DioHttpCancellationToken token = cancellationToken is DioHttpCancellationToken
        ? cancellationToken
        : DioHttpCancellationToken();
    if (cancellationToken?.isCancelled ?? false) {
      throw const UnifiedHttpException(HttpFailureKind.cancelled, '请求已取消');
    }
    /// 已合并 Cookie 的请求 Header。
    final Map<String, String> headers = await _cookieManager.applyRequestCookies(
      request.uri,
      request.headers,
      mode: request.cookieMode,
      sessionKey: request.sessionKey,
    );
    /// Dio 可接受的请求体。
    final Object? requestData = _toDioBody(request.body);
    /// Dio 请求选项。
    final Options options = Options(
      method: request.method.name.toUpperCase(),
      headers: headers,
      responseType: ResponseType.bytes,
      followRedirects: request.followRedirects,
      maxRedirects: request.maxRedirects,
      validateStatus: (int? status) => status != null,
      contentType: _contentType(request.body),
      sendTimeout: request.sendTimeout,
      receiveTimeout: request.receiveTimeout,
    );
    try {
      /// Dio 原始字节响应。
      final Response<List<int>> response = await _dio
          .requestUri<List<int>>(
            request.uri,
            data: requestData,
            options: options,
            cancelToken: token.dioToken,
          )
          .timeout(
            request.totalTimeout,
            onTimeout: () {
              token.cancel('请求总超时');
              throw const UnifiedHttpException(
                HttpFailureKind.totalTimeout,
                '请求超过总超时限制',
              );
            },
          );
      /// 最终响应地址。
      final Uri finalUri = response.realUri;
      /// 多值响应 Header。
      final Map<String, List<String>> responseHeaders = response.headers.map;
      await _cookieManager.saveResponseCookies(
        finalUri,
        responseHeaders,
        mode: request.cookieMode,
        sessionKey: request.sessionKey,
      );
      /// 响应字节；空响应转换为空数组。
      final Uint8List bytes = Uint8List.fromList(response.data ?? const <int>[]);
      /// HTTP 状态码。
      final int statusCode = response.statusCode ?? 0;
      if (!request.acceptHttpErrorStatus && (statusCode < 200 || statusCode >= 300)) {
        throw UnifiedHttpException(
          HttpFailureKind.httpStatus,
          'HTTP 状态异常',
          statusCode: statusCode,
        );
      }
      return HttpResponse(
        requestUri: request.uri,
        finalUri: finalUri,
        statusCode: statusCode,
        bytes: bytes,
        headers: responseHeaders,
        reasonPhrase: response.statusMessage,
      );
    } on UnifiedHttpException {
      rethrow;
    } on DioException catch (error) {
      throw _mapDioException(error);
    } on TimeoutException {
      throw const UnifiedHttpException(HttpFailureKind.totalTimeout, '请求超过总超时限制');
    } catch (error) {
      throw _mapUnknownException(error);
    }
  }

  /// 将统一请求体转换为 Dio 请求数据。
  Object? _toDioBody(HttpRequestBody body) {
    return switch (body) {
      EmptyHttpRequestBody() => null,
      TextHttpRequestBody(:final String text) => text,
      FormHttpRequestBody(:final Map<String, String> fields) => _encodeForm(fields),
      BytesHttpRequestBody(:final Uint8List bytes) => bytes,
    };
  }

  /// 将表单字段编码为 `application/x-www-form-urlencoded` 正文。
  String _encodeForm(Map<String, String> fields) {
    return fields.entries
        .map(
          (MapEntry<String, String> entry) =>
              '${Uri.encodeQueryComponent(entry.key)}=${Uri.encodeQueryComponent(entry.value)}',
        )
        .join('&');
  }

  /// 读取请求体声明的媒体类型。
  String? _contentType(HttpRequestBody body) {
    return switch (body) {
      TextHttpRequestBody(:final String? contentType) => contentType,
      BytesHttpRequestBody(:final String? contentType) => contentType,
      FormHttpRequestBody() => Headers.formUrlEncodedContentType,
      EmptyHttpRequestBody() => null,
    };
  }

  /// 将 Dio 异常映射为稳定错误分类。
  UnifiedHttpException _mapDioException(DioException error) {
    return switch (error.type) {
      DioExceptionType.cancel => const UnifiedHttpException(
        HttpFailureKind.cancelled,
        '请求已取消',
      ),
      DioExceptionType.connectionTimeout => const UnifiedHttpException(
        HttpFailureKind.connectTimeout,
        '连接超时',
      ),
      DioExceptionType.sendTimeout => const UnifiedHttpException(
        HttpFailureKind.sendTimeout,
        '发送超时',
      ),
      DioExceptionType.receiveTimeout => const UnifiedHttpException(
        HttpFailureKind.receiveTimeout,
        '接收超时',
      ),
      DioExceptionType.transformTimeout => const UnifiedHttpException(
        HttpFailureKind.receiveTimeout,
        '响应转换超时',
      ),
      DioExceptionType.badCertificate => const UnifiedHttpException(
        HttpFailureKind.tls,
        'TLS 证书校验失败',
      ),
      DioExceptionType.connectionError => _mapUnknownException(error.error),
      DioExceptionType.badResponse => UnifiedHttpException(
        HttpFailureKind.httpStatus,
        'HTTP 状态异常',
        statusCode: error.response?.statusCode,
      ),
      DioExceptionType.unknown => _mapUnknownException(error.error),
    };
  }

  /// 根据底层异常判断 DNS、连接、TLS 或未知错误。
  UnifiedHttpException _mapUnknownException(Object? error) {
    if (error is HandshakeException || error is TlsException) {
      return const UnifiedHttpException(HttpFailureKind.tls, 'TLS 连接失败');
    }
    if (error is SocketException) {
      /// Socket 系统错误码；部分平台 DNS 失败没有稳定错误码。
      final int? code = error.osError?.errorCode;
      if (code == 7 || code == 8 || code == -2) {
        return const UnifiedHttpException(HttpFailureKind.dns, '域名解析失败');
      }
      return const UnifiedHttpException(HttpFailureKind.connection, '网络连接失败');
    }
    return const UnifiedHttpException(HttpFailureKind.unknown, '未知网络错误');
  }
}
