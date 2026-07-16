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
  LegadoScriptBridge(
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

  /// 按书源隔离的运行时内存缓存，对应 Android `CacheManager` 的 memory API。
  final Map<String, Map<String, String>> _memoryCacheBySource =
      <String, Map<String, String>>{};

  /// 在脚本开始前读取 Android `BaseSource` 对应的持久变量，使 getter 保持同步返回。
  Future<void> prepareContext(LegadoScriptContext context) async {
    if (!context.variables.containsKey('sourceVariable')) {
      /// 当前书源持久化的自定义变量；没有配置时使用空字符串对齐 Android。
      final String? sourceVariable = await _cacheDao.getValidValue(
        _sourceRuntimeCacheKey('sourceVariable', context.source.bookSourceUrl),
        DateTime.now().millisecondsSinceEpoch,
      );
      context.variables['sourceVariable'] = sourceVariable ?? '';
    }
    if (!context.variables.containsKey('loginHeader')) {
      /// 当前书源持久化的登录 Header；null 表示从未配置。
      final String? loginHeader = await _cacheDao.getValidValue(
        _sourceRuntimeCacheKey('loginHeader', context.source.bookSourceUrl),
        DateTime.now().millisecondsSinceEpoch,
      );
      if (loginHeader != null) {
        context.variables['loginHeader'] = loginHeader;
      }
    }
  }

  /// 分派 JS 侧代理调用。
  Object? invoke(
    LegadoScriptContext context,
    String surface,
    String method,
    List<Object?> arguments, {
    JsCancellationToken? cancellationToken,
  }) {
    _recordBridgeCall(context, surface, method, arguments);
    if (surface == 'java') {
      return _invokeJava(context, method, arguments, cancellationToken: cancellationToken);
    }
    if (surface == 'cookie') {
      return _invokeCookie(method, arguments);
    }
    if (surface == 'cache') {
      return _invokeCache(context, method, arguments);
    }
    if (surface == 'source') {
      return _invokeSource(context, method, arguments);
    }
    if (surface.startsWith('class:')) {
      return _javaBridge.invokeClass(surface.substring(6), method, arguments);
    }
    if (surface.startsWith('host:')) {
      return _javaBridge.invokeHost(surface.substring(5), method, arguments);
    }
    throw JsEngineException(
      kind: JsFailureKind.unsupportedApi,
      message: '未支持脚本 API $surface.$method',
    );
  }

  /// 【FLUTTER_JS_COMPAT_LOG】记录宿主桥表面、方法名和参数类型，不保存任何参数值。
  void _recordBridgeCall(
    LegadoScriptContext context,
    String surface,
    String method,
    List<Object?> arguments,
  ) {
    /// 【FLUTTER_JS_COMPAT_LOG】只保留桥表面名称中的安全结构字符。
    final String normalizedSurface = surface.replaceAll(RegExp(r'[^A-Za-z0-9_.:$-]'), '_');
    /// 【FLUTTER_JS_COMPAT_LOG】限制后的桥表面名称，避免异常脚本制造超长日志字段。
    final String safeSurface = normalizedSurface.length <= 100
        ? normalizedSurface
        : normalizedSurface.substring(0, 100);
    /// 【FLUTTER_JS_COMPAT_LOG】只保留桥方法名称中的安全结构字符。
    final String normalizedMethod = method.replaceAll(RegExp(r'[^A-Za-z0-9_$-]'), '_');
    /// 【FLUTTER_JS_COMPAT_LOG】限制后的桥方法名称。
    final String safeMethod = normalizedMethod.length <= 80
        ? normalizedMethod
        : normalizedMethod.substring(0, 80);
    /// 【FLUTTER_JS_COMPAT_LOG】参数运行时类型列表，不包含字符串、URL、Cookie 或正文值。
    final String argumentTypes = arguments
        .map((Object? argument) => argument == null ? 'null' : argument.runtimeType.toString())
        .join(',');
    context.bridgeCalls.add('$safeSurface.$safeMethod($argumentTypes)');
    if (context.bridgeCalls.length > 24) {
      context.bridgeCalls.removeAt(0);
    }
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
      'removeCookie' => _removeCookie(arguments),
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

  /// 删除统一 Cookie 存储中指定地址的 Cookie。
  Future<void> _removeCookie(List<Object?> arguments) async {
    /// Cookie URL。
    final Uri uri = Uri.parse(_requiredString(arguments, 0, 'removeCookie'));
    await _cookieManager.removeCookieHeader(uri);
  }

  /// 分派持久缓存 API。
  Object? _invokeCache(
    LegadoScriptContext context,
    String method,
    List<Object?> arguments,
  ) {
    return switch (method) {
      'get' => _cacheDao.getValidValue(
        _requiredString(arguments, 0, 'cache.get'),
        DateTime.now().millisecondsSinceEpoch,
      ),
      'put' => _putCache(arguments),
      'delete' => _cacheDao.delete(_requiredString(arguments, 0, 'cache.delete')),
      'getFromMemory' => _getMemoryCache(context, arguments),
      'putMemory' => _putMemoryCache(context, arguments),
      'deleteMemory' => _deleteMemoryCache(context, arguments),
      _ => throw JsEngineException(
        kind: JsFailureKind.unsupportedApi,
        message: '未支持 cache.$method',
      ),
    };
  }

  /// 读取当前书源隔离的内存缓存值。
  String _getMemoryCache(
    LegadoScriptContext context,
    List<Object?> arguments,
  ) {
    /// 脚本请求读取的缓存键。
    final String key = _requiredString(arguments, 0, 'cache.getFromMemory');
    return _memoryCacheBySource[context.source.bookSourceUrl]?[key] ?? '';
  }

  /// 写入当前书源隔离的内存缓存并返回原值。
  String _putMemoryCache(
    LegadoScriptContext context,
    List<Object?> arguments,
  ) {
    /// 脚本请求写入的缓存键。
    final String key = _requiredString(arguments, 0, 'cache.putMemory');
    /// 脚本请求写入的缓存值。
    final String value = _requiredString(arguments, 1, 'cache.putMemory');
    /// 当前书源独占的内存缓存。
    final Map<String, String> sourceCache = _memoryCacheBySource.putIfAbsent(
      context.source.bookSourceUrl,
      () => <String, String>{},
    );
    sourceCache[key] = value;
    return value;
  }

  /// 删除当前书源隔离的单个内存缓存值。
  String _deleteMemoryCache(
    LegadoScriptContext context,
    List<Object?> arguments,
  ) {
    /// 脚本请求删除的缓存键。
    final String key = _requiredString(arguments, 0, 'cache.deleteMemory');
    return _memoryCacheBySource[context.source.bookSourceUrl]?.remove(key) ?? '';
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
      'setVariable' || 'putVariable' => _putPersistentSourceVariable(
        context,
        arguments,
      ),
      'getLoginHeader' => context.variables['loginHeader'],
      'putLoginHeader' => _putPersistentSourceValue(
        context,
        'loginHeader',
        arguments,
      ),
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

  /// 更新 `source.getVariable()` 的同步内存值，并把结果写入 Flutter 独立缓存表。
  Future<String> _putPersistentSourceVariable(
    LegadoScriptContext context,
    List<Object?> arguments,
  ) async {
    /// 脚本传入的自定义变量；null 对齐 Android 删除语义。
    final String? value = _optionalString(arguments, 0);
    if (value == null) {
      context.variables['sourceVariable'] = '';
      await _cacheDao.delete(
        _sourceRuntimeCacheKey('sourceVariable', context.source.bookSourceUrl),
      );
      return '';
    }
    context.variables['sourceVariable'] = value;
    await _cacheDao.upsert(
      Cache(
        key: _sourceRuntimeCacheKey('sourceVariable', context.source.bookSourceUrl),
        value: value,
      ),
    );
    return value;
  }

  /// 更新需要跨脚本保存的书源运行值，并复用 Android `前缀_书源URL` 缓存键语义。
  Future<String> _putPersistentSourceValue(
    LegadoScriptContext context,
    String name,
    List<Object?> arguments,
  ) async {
    /// 脚本传入的运行值；缺少参数时由统一参数校验报告桥错误。
    final String value = _requiredString(arguments, 0, 'source.$name');
    context.variables[name] = value;
    await _cacheDao.upsert(
      Cache(
        key: _sourceRuntimeCacheKey(name, context.source.bookSourceUrl),
        value: value,
      ),
    );
    return value;
  }

  /// 生成与 Android `BaseSource` 一致、且仅存在于 Flutter 独立数据库中的运行缓存键。
  String _sourceRuntimeCacheKey(String name, String sourceUrl) {
    return '${name}_$sourceUrl';
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
