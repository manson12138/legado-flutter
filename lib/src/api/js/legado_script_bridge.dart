import 'dart:convert';

import '../../data/dao/cache_dao.dart';
import '../../domain/model/cache.dart';
import '../cookie/cookie_manager.dart';
import '../http/http_contract.dart';
import '../http/response_decoder.dart';
import '../http/source_url_resolver.dart';
import 'java_compatibility_bridge.dart';
import 'js_engine.dart';
import 'script_context.dart';
import 'webview_script_bridge.dart';

/// JavaScript 调用 Dart 时的统一 Legado API 桥。
///
/// 同步编码工具直接返回值；网络、Cookie、持久缓存和 WebView 返回 Future，在 JSF 中会转为
/// Promise。旧 Rhino 脚本若假设同步网络返回，必须由真实样本报告识别，不能静默转换。
final class LegadoScriptBridge {
  /// 创建脚本 API 桥。
  const LegadoScriptBridge(
    this._httpClient,
    this._responseDecoder,
    this._urlResolver,
    this._cookieManager,
    this._cacheDao,
    this._javaBridge,
    this._webViewBridge,
  );

  /// M3 统一 HTTP 客户端。
  final UnifiedHttpClient _httpClient;

  /// M3 响应字符集与压缩解码器。
  final HttpResponseDecoder _responseDecoder;

  /// M3 书源 URL 解析器。
  final SourceUrlResolver _urlResolver;

  /// M3 统一 Cookie 管理器。
  final LegadoCookieManager _cookieManager;

  /// M2 通用缓存 DAO。
  final CacheDao _cacheDao;

  /// Java/Rhino 白名单桥。
  final JavaCompatibilityBridge _javaBridge;

  /// 页面 WebView 独立边界。
  final WebViewScriptBridge _webViewBridge;

  /// 分派 JS 侧代理调用。
  Object? invoke(
    LegadoScriptContext context,
    String surface,
    String method,
    List<Object?> arguments, {
    JsCancellationToken? cancellationToken,
  }) {
    if (surface == 'java') {
      return _invokeJava(context, method, arguments, cancellationToken: cancellationToken);
    }
    if (surface == 'cookie') {
      return _invokeCookie(method, arguments);
    }
    if (surface == 'cache') {
      return _invokeCache(method, arguments);
    }
    if (surface == 'source') {
      return _invokeSource(context, method, arguments);
    }
    if (surface.startsWith('class:')) {
      return _javaBridge.invokeClass(surface.substring(6), method, arguments);
    }
    throw JsEngineException(
      kind: JsFailureKind.unsupportedApi,
      message: '未支持脚本 API $surface.$method',
    );
  }

  /// 分派 Android `java` 注入对象方法。
  Object? _invokeJava(
    LegadoScriptContext context,
    String method,
    List<Object?> arguments, {
    JsCancellationToken? cancellationToken,
  }) {
    return switch (method) {
      'ajax' => _request(context, arguments, responseObject: false),
      'connect' => _request(context, arguments, responseObject: true),
      'get' => arguments.length >= 2
          ? _rawRequest(context, HttpRequestMethod.get, arguments)
          : _getVariable(context, arguments),
      'head' => _rawRequest(context, HttpRequestMethod.head, arguments),
      'post' => _rawRequest(context, HttpRequestMethod.post, arguments),
      'getCookie' => _getCookie(arguments),
      'put' => _putVariable(context, arguments),
      'webView' => _webView(context, arguments, cancellationToken: cancellationToken),
      'webViewGetSource' => _webView(
        context,
        arguments,
        sourceMode: true,
        cancellationToken: cancellationToken,
      ),
      _ => _javaBridge.invokeHelper(method, arguments),
    };
  }

  /// 执行 Android `java.get/head/post` 的不跟随重定向请求。
  Future<Map<String, Object?>> _rawRequest(
    LegadoScriptContext context,
    HttpRequestMethod method,
    List<Object?> arguments,
  ) async {
    /// 请求 URL。
    final Uri uri = context.baseUri.resolve(_requiredString(arguments, 0, method.name));
    /// POST 正文；GET/HEAD 没有正文。
    final String? body = method == HttpRequestMethod.post
        ? _requiredString(arguments, 1, 'post')
        : null;
    /// Header 参数位置。
    final int headerIndex = method == HttpRequestMethod.post ? 2 : 1;
    /// 请求 Header。
    final Map<String, String> headers = headerIndex < arguments.length
        ? _decodeHeaders(arguments[headerIndex])
        : <String, String>{};
    /// 原始 HTTP 响应。
    final HttpResponse response = await _httpClient.execute(
      HttpRequest(
        uri: uri,
        method: method,
        headers: headers,
        body: body == null ? const EmptyHttpRequestBody() : TextHttpRequestBody(body),
        followRedirects: false,
        acceptHttpErrorStatus: true,
        cookieMode: context.source.enabledCookieJar == false
            ? HttpCookieMode.disabled
            : HttpCookieMode.shared,
      ),
      cancellationToken: context.httpCancellationToken,
    );
    /// 解码响应。
    final DecodedHttpResponse decoded = _responseDecoder.decode(response);
    return <String, Object?>{
      'url': response.finalUri.toString(),
      'body': decoded.text,
      'statusCode': response.statusCode,
      'headers': response.headers,
    };
  }

  /// 执行复用 M3 的脚本网络请求。
  Future<Object?> _request(
    LegadoScriptContext context,
    List<Object?> arguments, {
    required bool responseObject,
  }) async {
    /// 脚本 URL。
    final String rawUrl = _requiredString(arguments, 0, responseObject ? 'connect' : 'ajax');
    /// Android `connect` 的可选 Header JSON。
    final Map<String, String> extraHeaders = arguments.length > 1
        ? _decodeHeaders(arguments[1])
        : <String, String>{};
    /// 解析后的书源请求。
    final ResolvedSourceRequest resolved = _urlResolver.resolve(
      rawUrl: rawUrl,
      baseUri: context.baseUri,
      source: context.source,
      keyword: context.key,
      page: context.page,
    );
    /// 合并脚本显式 Header 的请求。
    final HttpRequest request = _copyRequestWithHeaders(resolved.request, extraHeaders);
    /// 原始响应。
    final HttpResponse response = await _httpClient.execute(
      request,
      cancellationToken: context.httpCancellationToken,
    );
    /// 文本响应。
    final DecodedHttpResponse decoded = _responseDecoder.decode(
      response,
      ruleCharset: resolved.charset,
    );
    if (!responseObject) {
      return decoded.text;
    }
    return <String, Object?>{
      'url': response.finalUri.toString(),
      'body': decoded.text,
      'statusCode': response.statusCode,
      'headers': response.headers,
    };
  }

  /// 分派 Cookie API。
  Object? _invokeCookie(String method, List<Object?> arguments) {
    return switch (method) {
      'getCookie' => _getCookie(arguments),
      'setCookie' => _setCookie(arguments, replace: false),
      'replaceCookie' => _setCookie(arguments, replace: true),
      _ => throw JsEngineException(
        kind: JsFailureKind.unsupportedApi,
        message: '未支持 cookie.$method',
      ),
    };
  }

  /// 读取统一 Cookie。
  Future<String> _getCookie(List<Object?> arguments) async {
    /// Cookie URL。
    final Uri uri = Uri.parse(_requiredString(arguments, 0, 'getCookie'));
    /// 当前 Cookie Header。
    final String cookie = await _cookieManager.getCookieHeader(uri);
    if (arguments.length < 2 || arguments[1] == null) {
      return cookie;
    }
    /// 指定 Cookie 名称。
    final String key = arguments[1]?.toString() ?? '';
    for (final String part in cookie.split(';')) {
      /// Cookie 等号位置。
      final int equalsIndex = part.indexOf('=');
      if (equalsIndex > 0 && part.substring(0, equalsIndex).trim() == key) {
        return part.substring(equalsIndex + 1).trim();
      }
    }
    return '';
  }

  /// 写入统一 Cookie。
  Future<void> _setCookie(List<Object?> arguments, {required bool replace}) async {
    /// Cookie URL。
    final Uri uri = Uri.parse(_requiredString(arguments, 0, 'setCookie'));
    /// Cookie Header。
    final String cookie = _requiredString(arguments, 1, 'setCookie');
    if (replace) {
      await _cookieManager.replaceCookieHeader(uri, cookie);
    } else {
      await _cookieManager.setCookieHeader(uri, cookie);
    }
  }

  /// 分派持久缓存 API。
  Object? _invokeCache(String method, List<Object?> arguments) {
    return switch (method) {
      'get' => _cacheDao.getValidValue(
        _requiredString(arguments, 0, 'cache.get'),
        DateTime.now().millisecondsSinceEpoch,
      ),
      'put' => _putCache(arguments),
      'delete' => _cacheDao.delete(_requiredString(arguments, 0, 'cache.delete')),
      _ => throw JsEngineException(
        kind: JsFailureKind.unsupportedApi,
        message: '未支持 cache.$method',
      ),
    };
  }

  /// 写入带可选秒级有效期的缓存。
  Future<void> _putCache(List<Object?> arguments) async {
    /// 缓存键。
    final String key = _requiredString(arguments, 0, 'cache.put');
    /// 缓存值。
    final String value = _requiredString(arguments, 1, 'cache.put');
    /// 缓存秒数。
    final int saveSeconds = arguments.length > 2
        ? int.tryParse(arguments[2]?.toString() ?? '') ?? 0
        : 0;
    /// 过期毫秒时间。
    final int deadline = saveSeconds <= 0
        ? 0
        : DateTime.now().millisecondsSinceEpoch + saveSeconds * 1000;
    await _cacheDao.upsert(Cache(key: key, value: value, deadline: deadline));
  }

  /// 分派书源变量 API。
  Object? _invokeSource(
    LegadoScriptContext context,
    String method,
    List<Object?> arguments,
  ) {
    return switch (method) {
      'getVariable' => context.variables['sourceVariable'] ?? '',
      'setVariable' || 'putVariable' => _putNamedVariable(
        context,
        'sourceVariable',
        arguments,
      ),
      'getLoginHeader' => context.variables['loginHeader'],
      'putLoginHeader' => _putNamedVariable(context, 'loginHeader', arguments),
      'getLoginInfo' => context.variables['loginInfo'],
      'putLoginInfo' => _putNamedVariable(context, 'loginInfo', arguments),
      'getKey' => context.source.bookSourceUrl,
      'getTag' => context.source.bookSourceName,
      _ => throw JsEngineException(
        kind: JsFailureKind.unsupportedApi,
        message: '未支持 source.$method',
      ),
    };
  }

  /// 写入指定书源上下文变量。
  String _putNamedVariable(
    LegadoScriptContext context,
    String key,
    List<Object?> arguments,
  ) {
    /// 变量值。
    final String value = _requiredString(arguments, 0, 'source.$key');
    context.variables[key] = value;
    return value;
  }

  /// 写入当前规则变量并返回原值，兼容 Android `java.put`。
  String _putVariable(LegadoScriptContext context, List<Object?> arguments) {
    /// 变量键。
    final String key = _requiredString(arguments, 0, 'put');
    /// 变量值。
    final String value = _requiredString(arguments, 1, 'put');
    context.variables[key] = value;
    return value;
  }

  /// 读取当前规则变量。
  String _getVariable(LegadoScriptContext context, List<Object?> arguments) {
    /// 变量键。
    final String key = _requiredString(arguments, 0, 'get');
    if (key == 'bookName') {
      return context.book?.name ?? '';
    }
    if (key == 'title') {
      return context.chapter?.title ?? '';
    }
    return context.variables[key] ?? '';
  }

  /// 调用受控 WebView 边界。
  Future<Object?> _webView(
    LegadoScriptContext context,
    List<Object?> arguments, {
    bool sourceMode = false,
    JsCancellationToken? cancellationToken,
  }) async {
    /// 可选 HTML。
    final String? html = _optionalString(arguments, 0);
    /// 页面地址。
    final Uri uri = Uri.parse(_optionalString(arguments, 1) ?? context.baseUri.toString());
    /// 页面脚本。
    final String? script = _optionalString(arguments, 2);
    /// 资源提取正则。
    final String? sourceRegex = sourceMode ? _optionalString(arguments, 3) : null;
    /// WebView 结果。
    final WebViewScriptResponse response = await _webViewBridge.execute(
      WebViewScriptRequest(
        sourceId: context.source.bookSourceUrl,
        uri: uri,
        html: html,
        script: script,
        sourceRegex: sourceRegex,
        timeout: const Duration(seconds: 30),
      ),
      cancellationToken: cancellationToken,
    );
    return response.value;
  }

  /// 合并额外 Header 并复制不可变请求。
  HttpRequest _copyRequestWithHeaders(HttpRequest request, Map<String, String> extraHeaders) {
    /// 合并结果。
    final Map<String, String> headers = Map<String, String>.from(request.headers)
      ..addAll(extraHeaders);
    return HttpRequest(
      uri: request.uri,
      method: request.method,
      headers: headers,
      body: request.body,
      connectTimeout: request.connectTimeout,
      sendTimeout: request.sendTimeout,
      receiveTimeout: request.receiveTimeout,
      totalTimeout: request.totalTimeout,
      followRedirects: request.followRedirects,
      maxRedirects: request.maxRedirects,
      acceptHttpErrorStatus: request.acceptHttpErrorStatus,
      cookieMode: request.cookieMode,
      sessionKey: request.sessionKey,
    );
  }

  /// 解码脚本 Header JSON 边界。
  Map<String, String> _decodeHeaders(Object? value) {
    if (value == null || value.toString().trim().isEmpty) {
      return <String, String>{};
    }
    try {
      /// JSON 或已经桥接的 Map。
      final Object? decoded = value is String ? jsonDecode(value) : value;
      if (decoded is! Map) {
        throw const FormatException('Header 必须是 JSON 对象');
      }
      /// 字符串 Header Map。
      final Map<String, String> headers = <String, String>{};
      for (final MapEntry<Object?, Object?> entry in decoded.entries) {
        if (entry.key != null && entry.value != null) {
          headers[entry.key.toString()] = entry.value.toString();
        }
      }
      return headers;
    } on FormatException catch (error) {
      throw JsEngineException(
        kind: JsFailureKind.bridge,
        message: '脚本 Header 无效：${error.message}',
      );
    }
  }

  /// 读取必需字符串参数。
  String _requiredString(List<Object?> arguments, int index, String method) {
    if (index >= arguments.length || arguments[index] == null) {
      throw JsEngineException(
        kind: JsFailureKind.bridge,
        message: '$method 缺少第 ${index + 1} 个参数',
      );
    }
    return arguments[index].toString();
  }

  /// 读取可选字符串参数。
  String? _optionalString(List<Object?> arguments, int index) {
    if (index >= arguments.length || arguments[index] == null) {
      return null;
    }
    return arguments[index].toString();
  }
}
