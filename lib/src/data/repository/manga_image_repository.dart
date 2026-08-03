import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../api/http/http_contract.dart';
import '../../api/http/source_url_resolver.dart';
import '../../api/js/js_engine.dart';
import '../../api/js/script_context.dart';
import '../../data/dao/cache_dao.dart';
import '../../domain/gateway/manga_image_gateway.dart';
import '../../domain/model/book.dart';
import '../../domain/model/book_chapter.dart';
import '../../domain/model/book_source.dart';
import '../../domain/model/manga_page.dart';
import '../../model/analyze_rule/legado_javascript_service.dart';
import '../../model/analyze_rule/legado_rule_evaluator.dart';
import '../../model/analyze_rule/source_rules.dart';
import '../cache/manga_image_cache.dart';

/// 使用统一 HTTP/Cookie 边界获取漫画图片并写入受控私有缓存。
final class MangaImageRepository implements MangaImageGateway {
  /// 创建漫画图片仓储。
  MangaImageRepository({
    required UnifiedHttpClient httpClient,
    required SourceUrlResolver urlResolver,
    required MangaImageCache cache,
    required int Function() currentUserId,
    required HttpCancellationToken Function() cancellationTokenFactory,
    required LegadoJavaScriptService javaScriptService,
    required CacheDao cacheDao,
  }) : _httpClient = httpClient,
       _urlResolver = urlResolver,
       _cache = cache,
       _currentUserId = currentUserId,
       _cancellationTokenFactory = cancellationTokenFactory,
       _javaScriptService = javaScriptService,
       _ruleEvaluator = LegadoRuleEvaluator(javaScriptService),
       _cacheDao = cacheDao;

  /// Android 默认网络 User-Agent；书源、登录 Header 或图片 URL 选项可以覆盖它。
  static const String _defaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/131.0.0.0 Safari/537.36';

  /// 共享 Cookie 和网络错误分类的统一 HTTP 客户端。
  final UnifiedHttpClient _httpClient;

  /// 解析书源 Header 与图片地址 JSON 选项的统一 URL 解析器。
  final SourceUrlResolver _urlResolver;

  /// 漫画图片文件校验和原子缓存实现。
  final MangaImageCache _cache;

  /// 当前游客或登录用户作用域。
  final int Function() _currentUserId;

  /// 无外部生命周期令牌时创建当前下载独占的取消令牌。
  final HttpCancellationToken Function() _cancellationTokenFactory;

  /// 执行图片 URL、Header 和 `imageDecode` 脚本的书源隔离 JavaScript 服务。
  final LegadoJavaScriptService _javaScriptService;

  /// 对齐 Android `AnalyzeUrl` 顺序执行图片 URL 与 Header 混合规则。
  final LegadoRuleEvaluator _ruleEvaluator;

  /// 读取 `source.putLoginHeader` 保存的当前书源登录 Header。
  final CacheDao _cacheDao;

  /// 同一缓存身份当前正在执行的唯一真实下载。
  final Map<String, Future<MangaImageResource>> _inFlight =
      <String, Future<MangaImageResource>>{};

  /// 单飞下载期间所有调用方的进度观察者。
  final Map<String, Set<MangaImageProgress>> _progressListeners =
      <String, Set<MangaImageProgress>>{};

  @override
  Future<MangaImageResource> resolve({
    required Book book,
    required BookSource source,
    required MangaPage page,
    String? evaluatedSourceHeader,
    HttpCancellationToken? cancellationToken,
    MangaImageProgress? onProgress,
  }) async {
    /// 固定本次请求的用户作用域，避免异步期间切换账号改变缓存身份。
    final int userId = _currentUserId();
    /// 不暴露原始地址的稳定缓存键。
    final String cacheKey = _cache.cacheKey(
      userId: userId,
      bookUrl: book.bookUrl,
      chapterUrl: page.chapterUrl,
      requestUrl: page.requestUrl,
    );
    /// 已存在且通过文件头复检的缓存。
    final MangaCachedImage? cached = await _cache.lookup(cacheKey);
    if (cached != null) {
      return _resource(cached, fromCache: true);
    }
    if (cancellationToken?.isCancelled ?? false) {
      throw const MangaImageException(
        MangaImageFailureKind.cancelled,
        '图片请求已取消',
      );
    }
    if (onProgress != null) {
      (_progressListeners[cacheKey] ??= <MangaImageProgress>{}).add(onProgress);
    }
    /// 已经由其他页面触发的同缓存身份下载。
    final Future<MangaImageResource>? existing = _inFlight[cacheKey];
    /// 当前调用最终等待的单飞任务。
    final Future<MangaImageResource> task;
    if (existing != null) {
      task = existing;
    } else {
      task = _download(
        cacheKey: cacheKey,
        book: book,
        source: source,
        page: page,
        evaluatedSourceHeader: evaluatedSourceHeader,
        cancellationToken: cancellationToken,
      );
      _inFlight[cacheKey] = task;
    }
    /// 单飞任务成功时保存的最终资源。
    MangaImageResource? completedResource;
    /// 低优先级首调用方取消共享任务时，高优先级活动调用方是否需要重新发起。
    bool retryCancelledSharedTask = false;
    try {
      completedResource = await task;
      if (cancellationToken?.isCancelled ?? false) {
        throw const MangaImageException(
          MangaImageFailureKind.cancelled,
          '图片请求已取消',
        );
      }
    } on MangaImageException catch (error) {
      retryCancelledSharedTask = error.kind == MangaImageFailureKind.cancelled &&
          !(cancellationToken?.isCancelled ?? false) &&
          existing != null;
      if (!retryCancelledSharedTask) {
        rethrow;
      }
    } finally {
      if (onProgress != null) {
        final Set<MangaImageProgress>? listeners = _progressListeners[cacheKey];
        listeners?.remove(onProgress);
        if (listeners?.isEmpty ?? false) {
          _progressListeners.remove(cacheKey);
        }
      }
      if (identical(_inFlight[cacheKey], task)) {
        _inFlight.remove(cacheKey);
      }
    }
    if (retryCancelledSharedTask) {
      return resolve(
        book: book,
        source: source,
        page: page,
        evaluatedSourceHeader: evaluatedSourceHeader,
        cancellationToken: cancellationToken,
        onProgress: onProgress,
      );
    }
    final MangaImageResource? resource = completedResource;
    if (resource != null) {
      return resource;
    }
    throw const MangaImageException(
      MangaImageFailureKind.cancelled,
      '图片请求已取消',
    );
  }

  /// 执行唯一真实请求，合并 Header/Referer/Cookie 并验证响应。
  Future<MangaImageResource> _download({
    required String cacheKey,
    required Book book,
    required BookSource source,
    required MangaPage page,
    required String? evaluatedSourceHeader,
    required HttpCancellationToken? cancellationToken,
  }) async {
    /// 当前下载实际使用的生命周期取消令牌。
    final HttpCancellationToken token =
        cancellationToken ?? _cancellationTokenFactory();
    /// 下载进度是否已触发单文件体积上限取消。
    bool exceededDownloadLimit = false;
    try {
      /// 已执行 URL/Header JavaScript、登录 Header 和 Android 默认 UA 的图片请求。
      final ResolvedSourceRequest resolved = await _resolveImageRequest(
        book: book,
        page: page,
        source: source,
        evaluatedSourceHeader: evaluatedSourceHeader,
        cancellationToken: token,
      );
      if (resolved.request.uri.host.isEmpty ||
          !<String>{'http', 'https'}
              .contains(resolved.request.uri.scheme.toLowerCase())) {
        throw const MangaImageException(
          MangaImageFailureKind.invalidRequest,
          '图片请求地址不是安全的远端 HTTP 地址',
        );
      }
      /// 图片地址选项优先，缺失 Referer 时再使用章节最终响应地址。
      final Map<String, String> headers = Map<String, String>.from(
        resolved.request.headers,
      );
      _removeNullUserAgent(headers);
      if (page.referer.isNotEmpty && !_containsHeader(headers, 'referer')) {
        headers['Referer'] = page.referer;
      }
      /// 收紧图片二进制请求的超时，同时保留统一客户端有限重试策略。
      final HttpRequest request = HttpRequest(
        uri: resolved.request.uri,
        method: resolved.request.method,
        headers: headers,
        body: resolved.request.body,
        connectTimeout: const Duration(seconds: 15),
        sendTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 45),
        totalTimeout: const Duration(seconds: 60),
        followRedirects: resolved.request.followRedirects,
        maxRedirects: resolved.request.maxRedirects,
        cookieMode: resolved.request.cookieMode,
        sessionKey: resolved.request.sessionKey,
        logContext: 'mangaImage',
      );
      /// 共享 Cookie 完成后的原始图片响应。
      final HttpResponse response = await _httpClient.execute(
        request,
        cancellationToken: token,
        onReceiveProgress: (int received, int? total) {
          _notifyProgress(cacheKey, received, total);
          if (received > MangaImageCache.maximumByteLength && !token.isCancelled) {
            exceededDownloadLimit = true;
            token.cancel('图片超过下载大小限制');
          }
        },
      );
      if (response.bytes.length > MangaImageCache.maximumByteLength) {
        throw const MangaImageException(
          MangaImageFailureKind.tooLarge,
          '图片文件超过大小限制',
        );
      }
      /// Android `ImageUtils.decode` 对齐结果；无解密规则时原样复用响应字节。
      final Uint8List decodedBytes = await _decodeImageBytes(
        source: source,
        book: book,
        page: page,
        requestUri: response.finalUri,
        bytes: response.bytes,
        cancellationToken: token,
      );
      if (decodedBytes.length > MangaImageCache.maximumByteLength) {
        throw const MangaImageException(
          MangaImageFailureKind.tooLarge,
          '解密后的图片文件超过大小限制',
        );
      }
      /// 校验后写入正式缓存的图片。
      final MangaCachedImage stored = await _cache.store(
        cacheKey: cacheKey,
        bytes: decodedBytes,
        declaredContentType: response.firstHeader('content-type'),
      );
      return _resource(stored, fromCache: false);
    } on MangaImageException {
      rethrow;
    } on UnifiedHttpException catch (error) {
      if (exceededDownloadLimit) {
        throw const MangaImageException(
          MangaImageFailureKind.tooLarge,
          '图片文件超过大小限制',
        );
      }
      throw _mapHttpFailure(error);
    } on JsEngineException {
      if (token.isCancelled) {
        throw const MangaImageException(
          MangaImageFailureKind.cancelled,
          '图片请求已取消',
        );
      }
      throw const MangaImageException(
        MangaImageFailureKind.unsupportedRequestRule,
        '图片 URL 或 Header JavaScript 执行失败',
      );
    } on FormatException {
      throw const MangaImageException(
        MangaImageFailureKind.invalidRequest,
        '图片地址或请求选项无效',
      );
    }
  }

  /// 对齐 Android `AnalyzeUrl`，为单张图片执行 URL/Header 脚本和登录 Header 合并。
  Future<ResolvedSourceRequest> _resolveImageRequest({
    required Book book,
    required BookSource source,
    required MangaPage page,
    required String? evaluatedSourceHeader,
    required HttpCancellationToken cancellationToken,
  }) async {
    /// 图片所属章节的脚本可见快照，补齐 Android 图片请求中的 `book/chapter` 上下文。
    final BookChapter chapter = BookChapter(
      url: page.chapterUrl,
      title: page.chapterTitle,
      bookUrl: book.bookUrl,
      index: page.chapterIndex,
      baseUrl: page.referer,
    );
    /// 同时观察图片生命周期取消状态的脚本取消令牌。
    final JsCancellationToken jsCancellationToken =
        _MangaHttpBackedJsCancellationToken(cancellationToken);
    /// 图片 URL 和书源 Header 共享的脚本上下文。
    final LegadoScriptContext scriptContext = LegadoScriptContext(
      source: source,
      baseUri: page.imageUri,
      book: book,
      chapter: chapter,
      result: page.requestUrl,
      operation: LegadoScriptOperation.content,
      interactionPolicy: LegadoScriptInteractionPolicy.deny,
      httpCancellationToken: cancellationToken,
    );
    /// 已执行图片 URL 主体脚本的请求规则；JSON 选项脚本稍后按 Android 顺序执行。
    final String resolvedUrl = _urlRequiresJavaScript(page.requestUrl)
        ? await _ruleEvaluator.string(
            rule: page.requestUrl,
            input: page.requestUrl,
            context: scriptContext,
            cancellationToken: jsCancellationToken,
          )
        : page.requestUrl;
    if (_urlRequiresJavaScript(resolvedUrl)) {
      throw const MangaImageException(
        MangaImageFailureKind.unsupportedRequestRule,
        '图片 URL JavaScript 执行后仍包含未解析规则',
      );
    }
    /// Android URL JSON 选项中的请求前 `js` 与响应后 `bodyJs`。
    final SourceUrlJavaScriptOptions scriptOptions =
        _urlResolver.readJavaScriptOptions(rawUrl: resolvedUrl);
    /// URL 选项脚本接收的绝对图片地址。
    final String absoluteOptionUrl =
        page.imageUri.resolve(scriptOptions.urlText).toString();
    /// URL 选项脚本独占上下文，`result/src` 对齐 Android 的绝对请求地址。
    final LegadoScriptContext optionContext = LegadoScriptContext(
      source: source,
      baseUri: Uri.parse(absoluteOptionUrl),
      book: book,
      chapter: chapter,
      result: absoluteOptionUrl,
      operation: LegadoScriptOperation.content,
      interactionPolicy: LegadoScriptInteractionPolicy.deny,
      executionState: scriptContext.executionState,
      httpCancellationToken: cancellationToken,
    );
    /// `UrlOption.js` 执行后的最终请求地址。
    final String? evaluatedOptionUrl =
        scriptOptions.urlJavaScript?.trim().isNotEmpty == true
        ? await _ruleEvaluator.string(
            rule: '@js:${scriptOptions.urlJavaScript}',
            input: absoluteOptionUrl,
            context: optionContext,
            cancellationToken: jsCancellationToken,
          )
        : null;
    /// 已执行脚本的书源 Header；调用方显式传入时不重复执行。
    final String? sourceHeader = evaluatedSourceHeader ?? source.header;
    final String? resolvedSourceHeader = evaluatedSourceHeader == null &&
            _ruleEvaluator.containsJavaScript(sourceHeader)
        ? await _ruleEvaluator.string(
            rule: sourceHeader,
            input: sourceHeader,
            context: scriptContext,
            cancellationToken: jsCancellationToken,
          )
        : sourceHeader;
    /// 按 Android `BaseSource.getHeaderMap(true)` 合并默认 UA 与登录 Header。
    final String mergedHeader = await _mergeSourceAndLoginHeaders(
      source: source,
      sourceHeader: resolvedSourceHeader,
    );
    return _urlResolver.resolve(
      rawUrl: resolvedUrl,
      baseUri: page.imageUri,
      source: source,
      header: mergedHeader,
      evaluatedOptionUrl: evaluatedOptionUrl,
      javaScriptOptionsEvaluated:
          scriptOptions.urlJavaScript?.trim().isNotEmpty == true ||
          scriptOptions.bodyJavaScript?.trim().isNotEmpty == true,
    );
  }

  /// 将书源 Header、Android 默认 UA 和持久登录 Header 按原版优先级合并。
  Future<String> _mergeSourceAndLoginHeaders({
    required BookSource source,
    required String? sourceHeader,
  }) async {
    /// 书源静态或脚本计算后的 Header。
    final Map<String, String> headers = _decodeHeaderMap(
      sourceHeader,
      ignoreInvalid: false,
    );
    if (!_containsHeader(headers, 'user-agent')) {
      _putHeader(headers, 'User-Agent', _defaultUserAgent);
    }
    /// `source.putLoginHeader` 按书源地址隔离保存的 JSON 文本。
    final String? loginHeader = await _cacheDao.getValidValue(
      'loginHeader_${source.bookSourceUrl}',
      DateTime.now().millisecondsSinceEpoch,
    );
    /// Android 在默认 Header 后合并登录 Header，图片 URL 选项随后仍可覆盖它。
    final Map<String, String> loginHeaders = _decodeHeaderMap(
      loginHeader,
      ignoreInvalid: true,
    );
    for (final MapEntry<String, String> entry in loginHeaders.entries) {
      _putHeader(headers, entry.key, entry.value);
    }
    return jsonEncode(headers);
  }

  /// 执行正文规则 `imageDecode`，对应 Android `ImageUtils.decode`。
  Future<Uint8List> _decodeImageBytes({
    required BookSource source,
    required Book book,
    required MangaPage page,
    required Uri requestUri,
    required Uint8List bytes,
    required HttpCancellationToken cancellationToken,
  }) async {
    /// 当前书源配置的图片解密脚本。
    final String? rule =
        const BookSourceRuleDecoder().decodeContent(source).imageDecode;
    if (rule?.trim().isNotEmpty != true) {
      return bytes;
    }
    /// 图片所属章节的脚本可见事实。
    final BookChapter chapter = BookChapter(
      url: page.chapterUrl,
      title: page.chapterTitle,
      bookUrl: book.bookUrl,
      index: page.chapterIndex,
      baseUrl: page.referer,
    );
    /// 解密脚本上下文；显式 bindings 让 `result` 为字节、`src` 为图片 URL。
    final LegadoScriptContext context = LegadoScriptContext(
      source: source,
      baseUri: requestUri,
      book: book,
      chapter: chapter,
      result: bytes,
      operation: LegadoScriptOperation.content,
      interactionPolicy: LegadoScriptInteractionPolicy.deny,
      httpCancellationToken: cancellationToken,
    );
    try {
      /// 图片解密脚本返回的跨引擎字节结果。
      final Object? decoded = await _javaScriptService.evaluate(
        scriptName: '${source.bookSourceName}/imageDecode',
        script: rule ?? '',
        context: context,
        bindings: <String, Object?>{
          'result': bytes,
          'src': requestUri.toString(),
        },
        cancellationToken:
            _MangaHttpBackedJsCancellationToken(cancellationToken),
      );
      return _coerceDecodedBytes(decoded);
    } on MangaImageException {
      rethrow;
    } on Object {
      if (cancellationToken.isCancelled) {
        throw const MangaImageException(
          MangaImageFailureKind.cancelled,
          '图片请求已取消',
        );
      }
      throw const MangaImageException(
        MangaImageFailureKind.unsupportedRequestRule,
        '图片解密规则执行失败',
      );
    }
  }

  /// 将 QuickJS 返回的 Uint8List 或数值数组收窄为可缓存图片字节。
  static Uint8List _coerceDecodedBytes(Object? value) {
    if (value is Uint8List) {
      return value;
    }
    if (value is List) {
      /// 经范围校验的图片字节。
      final List<int> bytes = <int>[];
      for (final Object? item in value) {
        if (item is! num || item.isNaN || item.isInfinite) {
          throw const MangaImageException(
            MangaImageFailureKind.unsupportedRequestRule,
            '图片解密规则没有返回有效字节数组',
          );
        }
        /// JavaScript 数值转换后的整数值。
        final int byte = item.toInt();
        if (byte < 0 || byte > 255 || byte.toDouble() != item.toDouble()) {
          throw const MangaImageException(
            MangaImageFailureKind.unsupportedRequestRule,
            '图片解密规则返回了越界字节',
          );
        }
        bytes.add(byte);
      }
      return Uint8List.fromList(bytes);
    }
    throw const MangaImageException(
      MangaImageFailureKind.unsupportedRequestRule,
      '图片解密规则没有返回字节数组',
    );
  }

  /// 判断图片 URL 主体是否包含需要 QuickJS 执行的规则，忽略 JSON 选项脚本。
  bool _urlRequiresJavaScript(String rawUrl) {
    /// URL JSON 选项的起点。
    final RegExpMatch? optionStart =
        RegExp(r'\s*,\s*(?=\{)').firstMatch(rawUrl);
    /// 不包含 URL JSON 选项的地址主体。
    final String urlRule = optionStart == null
        ? rawUrl
        : rawUrl.substring(0, optionStart.start);
    return _ruleEvaluator.containsJavaScript(urlRule);
  }

  /// 解码 Header JSON；登录 Header 损坏时按 Android 行为忽略，书源 Header 损坏时保留错误。
  static Map<String, String> _decodeHeaderMap(
    String? value, {
    required bool ignoreInvalid,
  }) {
    if (value == null || value.trim().isEmpty) {
      return <String, String>{};
    }
    try {
      /// Header JSON 解码结果。
      final Object? decoded = jsonDecode(value);
      if (decoded is! Map) {
        throw const FormatException('Header 必须是 JSON 对象');
      }
      /// 字符串化后的 Header Map。
      final Map<String, String> headers = <String, String>{};
      for (final MapEntry<Object?, Object?> entry in decoded.entries) {
        if (entry.key != null && entry.value != null) {
          _putHeader(headers, entry.key.toString(), entry.value.toString());
        }
      }
      return headers;
    } on FormatException {
      if (ignoreInvalid) {
        return <String, String>{};
      }
      rethrow;
    }
  }

  /// 以忽略大小写的 Header 名覆盖旧值，避免产生两个语义相同的键。
  static void _putHeader(
    Map<String, String> headers,
    String name,
    String value,
  ) {
    /// 已存在的同名 Header 键。
    String? existingName;
    for (final String key in headers.keys) {
      if (key.toLowerCase() == name.toLowerCase()) {
        existingName = key;
        break;
      }
    }
    if (existingName != null) {
      headers.remove(existingName);
    }
    headers[name] = value;
  }

  /// 对齐 Android HTTP 拦截器：值为字符串 `null` 时不发送 User-Agent。
  static void _removeNullUserAgent(Map<String, String> headers) {
    /// 用户显式要求移除的 User-Agent 键。
    String? removedName;
    for (final MapEntry<String, String> entry in headers.entries) {
      if (entry.key.toLowerCase() == 'user-agent' &&
          entry.value.toLowerCase() == 'null') {
        removedName = entry.key;
        break;
      }
    }
    if (removedName != null) {
      headers.remove(removedName);
    }
  }

  @override
  Future<void> invalidate({required Book book, required MangaPage page}) {
    /// 使用失效调用时的固定用户作用域生成目标缓存键。
    final int userId = _currentUserId();
    /// 待删除资源的稳定缓存键。
    final String cacheKey = _cache.cacheKey(
      userId: userId,
      bookUrl: book.bookUrl,
      chapterUrl: page.chapterUrl,
      requestUrl: page.requestUrl,
    );
    return _cache.invalidate(cacheKey);
  }

  /// 向当前单飞任务的全部观察者广播有界字节进度。
  void _notifyProgress(String cacheKey, int received, int? total) {
    /// 防止观察者在回调中移除自己而改变当前迭代集合。
    final List<MangaImageProgress> listeners = List<MangaImageProgress>.from(
      _progressListeners[cacheKey] ?? const <MangaImageProgress>{},
    );
    for (final MangaImageProgress listener in listeners) {
      try {
        listener(received, total);
      } on Object {
        // 展示层进度回调失败不能取消或伪造真实图片下载结果。
      }
    }
  }

  /// 判断 Header Map 是否已包含忽略大小写的指定键。
  static bool _containsHeader(Map<String, String> headers, String name) {
    /// 待匹配的小写 Header 名。
    final String normalizedName = name.toLowerCase();
    return headers.keys.any((String key) => key.toLowerCase() == normalizedName);
  }

  /// 把缓存内部事实转换为领域资源，不向 UI 暴露 File 操作。
  static MangaImageResource _resource(
    MangaCachedImage image, {
    required bool fromCache,
  }) {
    return MangaImageResource(
      filePath: image.file.path,
      mimeType: image.mimeType,
      width: image.width,
      height: image.height,
      byteLength: image.byteLength,
      fromCache: fromCache,
    );
  }

  /// 将统一网络失败转换为漫画领域错误，不携带敏感请求信息。
  static MangaImageException _mapHttpFailure(UnifiedHttpException error) {
    return switch (error.kind) {
      HttpFailureKind.cancelled => const MangaImageException(
        MangaImageFailureKind.cancelled,
        '图片请求已取消',
      ),
      HttpFailureKind.httpStatus => MangaImageException(
        MangaImageFailureKind.httpStatus,
        '图片服务器返回错误状态',
        statusCode: error.statusCode,
      ),
      HttpFailureKind.unsupportedOption => const MangaImageException(
        MangaImageFailureKind.unsupportedRequestRule,
        '图片请求规则包含当前不支持的选项',
      ),
      _ => const MangaImageException(
        MangaImageFailureKind.network,
        '漫画图片网络请求失败',
      ),
    };
  }
}

/// 通过短周期观察统一 HTTP 令牌，把漫画页面取消同步给 QuickJS 中断处理器。
final class _MangaHttpBackedJsCancellationToken
    implements JsCancellationToken {
  /// 创建只读取消适配器。
  const _MangaHttpBackedJsCancellationToken(this._httpToken);

  /// 页面或图片协调器持有的统一 HTTP 取消令牌。
  final HttpCancellationToken _httpToken;

  @override
  bool get isCancelled => _httpToken.isCancelled;

  @override
  void Function() addCancellationListener(void Function() listener) {
    if (_httpToken.isCancelled) {
      listener();
      return () {};
    }
    /// 脚本执行期间观察图片生命周期取消状态的轻量计时器。
    final Timer timer = Timer.periodic(
      const Duration(milliseconds: 50),
      (Timer current) {
        if (_httpToken.isCancelled) {
          current.cancel();
          listener();
        }
      },
    );
    return timer.cancel;
  }
}
