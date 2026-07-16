import 'dart:async';

import 'package:webview_flutter/webview_flutter.dart';

import '../cookie/cookie_manager.dart';
import 'js_engine.dart';

/// 需要页面环境执行的 WebView 脚本请求。
final class WebViewScriptRequest {
  /// 创建不可变 WebView 请求。
  WebViewScriptRequest({
    required this.sourceId,
    required this.uri,
    required this.timeout,
    Map<String, String> headers = const <String, String>{},
    this.html,
    this.script,
    this.sourceRegex,
    this.delay = Duration.zero,
  }) : headers = Map<String, String>.unmodifiable(headers);

  /// 书源隔离标识。
  final String sourceId;

  /// 页面地址，也是相对资源基准地址。
  final Uri uri;

  /// 可选直接载入的 HTML。
  final String? html;

  /// 页面加载后执行的脚本。
  final String? script;

  /// 可选资源 URL 提取正则。
  final String? sourceRegex;

  /// 页面加载完成后的等待时间。
  final Duration delay;

  /// 包含页面创建、加载、脚本与关闭的总超时。
  final Duration timeout;

  /// 页面请求 Header；不得写入日志。
  final Map<String, String> headers;
}

/// WebView 脚本结果。
final class WebViewScriptResponse {
  /// 创建不可变 WebView 响应。
  const WebViewScriptResponse({required this.finalUri, required this.value});

  /// 页面最终地址。
  final Uri finalUri;

  /// 脚本结果或完整页面文本。
  final Object? value;
}

/// JavaScript 引擎之外的页面 WebView 能力边界。
abstract interface class WebViewScriptBridge {
  /// 执行独立 WebView 请求；实现必须同步统一 Cookie 并在结束时销毁页面。
  Future<WebViewScriptResponse> execute(
    WebViewScriptRequest request, {
    JsCancellationToken? cancellationToken,
  });

  /// 关闭所有仍存活的受控 WebView。
  Future<void> close();
}

/// 使用 Flutter 官方 WebView 实现受控页面脚本，并在 Android/iOS 复用同一 Dart 编排。
///
/// iOS 底层由 WKWebView 执行，Android 底层由系统 WebView 执行；Cookie 始终通过
/// [LegadoCookieManager] 与统一 HTTP 会话双向同步，页面关闭后不保留 Delegate 或脚本 Handler。
final class FlutterWebViewScriptBridge implements WebViewScriptBridge {
  /// 创建页面脚本桥。
  FlutterWebViewScriptBridge(this._cookieManager, this._webViewCookieBridge);

  /// M3 统一 Cookie 管理器，是持久 Cookie 的唯一事实来源。
  final LegadoCookieManager _cookieManager;

  /// 平台 WebView Cookie Store 适配器。
  final WebViewCookieBridge _webViewCookieBridge;

  /// 当前仍在加载或执行脚本的短生命周期页面会话。
  final Set<_ManagedWebViewSession> _activeSessions = <_ManagedWebViewSession>{};

  /// 是否已经永久关闭桥；应用关闭后不允许继续创建原生页面资源。
  bool _closed = false;

  /// 创建独立页面、同步 Cookie、加载、执行脚本并回收所有页面回调。
  @override
  Future<WebViewScriptResponse> execute(
    WebViewScriptRequest request, {
    JsCancellationToken? cancellationToken,
  }) async {
    if (_closed) {
      throw const JsEngineException(
        kind: JsFailureKind.closed,
        message: '页面 WebView 脚本桥已经关闭',
      );
    }
    if (cancellationToken?.isCancelled ?? false) {
      throw const JsEngineException(
        kind: JsFailureKind.cancelled,
        message: '页面 WebView 脚本已取消',
      );
    }
    /// 本次执行独占的原生 WebView 会话，不与其他书源共享页面对象或脚本 Scope。
    final _ManagedWebViewSession session = _ManagedWebViewSession();
    _activeSessions.add(session);
    /// 从取消令牌移除监听器的回调。
    void Function()? removeCancellationListener;
    try {
      await session.initialize();
      removeCancellationListener = cancellationToken?.addCancellationListener(
        () => session.cancel(
          const JsEngineException(
            kind: JsFailureKind.cancelled,
            message: '页面 WebView 脚本已取消',
          ),
        ),
      );
      return await _executeSession(session, request).timeout(
        request.timeout,
        onTimeout: () {
          /// 超时异常同时用于中断当前页面等待，避免页面继续占用资源。
          const JsEngineException error = JsEngineException(
            kind: JsFailureKind.timeout,
            message: '页面 WebView 脚本执行超时',
          );
          session.cancel(error);
          throw error;
        },
      );
    } on JsEngineException {
      rethrow;
    } catch (error) {
      throw const JsEngineException(
        kind: JsFailureKind.bridge,
        message: '页面 WebView 加载或脚本执行失败',
      );
    } finally {
      removeCancellationListener?.call();
      _activeSessions.remove(session);
      await session.release();
    }
  }

  /// 完成单个 WebView 会话的 Cookie、页面和结果编排。
  Future<WebViewScriptResponse> _executeSession(
    _ManagedWebViewSession session,
    WebViewScriptRequest request,
  ) async {
    /// 普通 HTTP 当前可发送给初始页面的 Cookie 请求头。
    final String initialCookieHeader = await _cookieManager.getCookieHeader(request.uri);
    await _webViewCookieBridge.writeCookies(request.uri, initialCookieHeader);
    await session.load(request);
    if (request.delay > Duration.zero) {
      await Future<void>.delayed(request.delay);
      session.throwIfCancelled();
    }
    /// 页面脚本为空时返回完整 DOM；非空时返回脚本结构化结果。
    final Object? rawValue = await session.evaluate(request.script);
    /// sourceMode 提供正则时，从页面结果提取首个匹配或首个捕获组。
    final Object? value = _extractSourceValue(rawValue, request.sourceRegex);
    /// 重定向完成后的页面地址，用于 Cookie 回写和相对资源基准。
    final Uri finalUri = await session.currentUri(request.uri);
    await _syncCookiesBack(request.uri);
    if (finalUri.host != request.uri.host) {
      await _syncCookiesBack(finalUri);
    }
    return WebViewScriptResponse(finalUri: finalUri, value: value);
  }

  /// 将指定页面域的 WebView Cookie 回写统一持久 Cookie Store。
  Future<void> _syncCookiesBack(Uri uri) async {
    /// 页面关闭前读取的 Cookie 请求头；为空时保留原统一 Cookie，避免插件读取失败被误判为登出。
    final String? cookieHeader = await _webViewCookieBridge.readCookies(uri);
    if (cookieHeader != null && cookieHeader.trim().isNotEmpty) {
      await _cookieManager.replaceCookieHeader(uri, cookieHeader);
    }
  }

  /// 根据可选正则返回首个捕获值，未匹配时返回空字符串以兼容 Android sourceMode。
  Object? _extractSourceValue(Object? rawValue, String? sourceRegex) {
    if (sourceRegex == null || sourceRegex.trim().isEmpty) {
      return rawValue;
    }
    /// WebView 脚本或 DOM 转成的待匹配文本。
    final String text = rawValue?.toString() ?? '';
    /// 用户书源提供的正则表达式；语法错误会进入受控 bridge 异常。
    final RegExpMatch? match = RegExp(sourceRegex).firstMatch(text);
    if (match == null) {
      return '';
    }
    return match.groupCount > 0 ? match.group(1) ?? '' : match.group(0) ?? '';
  }

  /// 终止全部页面并永久关闭桥，供应用进程释放原生 WebView 资源。
  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    /// 关闭时的会话快照，避免释放回调修改正在迭代的集合。
    final List<_ManagedWebViewSession> sessions = _activeSessions.toList(growable: false);
    _activeSessions.clear();
    for (final _ManagedWebViewSession session in sessions) {
      session.cancel(
        const JsEngineException(
          kind: JsFailureKind.closed,
          message: '页面 WebView 脚本桥已经关闭',
        ),
      );
      await session.release();
    }
  }
}

/// 管理一次 WebView 加载的 Controller、Delegate、取消和资源释放。
final class _ManagedWebViewSession {
  /// 注入页面的 Flutter JavaScript Channel 名称，只传回结果文本，不暴露业务对象。
  static const String _resultChannelName = 'LegadoWebViewResult';

  /// 页面 Controller；初始化完成前为空，避免使用强制空值断言。
  WebViewController? _controller;

  /// 主页面加载完成信号，每个会话只加载一个业务页面。
  Completer<void>? _pageLoaded;

  /// 取消或关闭原因；为空表示会话仍可继续。
  JsEngineException? _terminalError;

  /// Android `window.legado.getHTML/getSource` 异步回调的结果信号。
  Completer<Object?>? _scriptCallback;

  /// 是否已经解除 Delegate 并释放业务页面引用。
  bool _released = false;

  /// 创建 Controller 并安装只捕获当前会话的短生命周期导航 Delegate。
  Future<void> initialize() async {
    /// 本会话独占的原生 WebView Controller。
    final WebViewController controller = WebViewController();
    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await controller.addJavaScriptChannel(
      _resultChannelName,
      onMessageReceived: (JavaScriptMessage message) {
        /// 当前脚本正在等待的页面回调；重复回调只消费第一次。
        final Completer<Object?>? scriptCallback = _scriptCallback;
        if (scriptCallback != null && !scriptCallback.isCompleted) {
          scriptCallback.complete(message.message);
        }
      },
    );
    await controller.setNavigationDelegate(
      NavigationDelegate(
        onPageFinished: (String url) {
          /// 页面可能因重定向多次完成，只消费第一个最终完成信号。
          final Completer<void>? pageLoaded = _pageLoaded;
          if (pageLoaded != null && !pageLoaded.isCompleted) {
            pageLoaded.complete();
          }
        },
        onWebResourceError: (WebResourceError error) {
          if (error.isForMainFrame != true) {
            return;
          }
          /// 主框架错误转换为不包含页面正文、Cookie 或 Header 的稳定异常。
          final Completer<void>? pageLoaded = _pageLoaded;
          if (pageLoaded != null && !pageLoaded.isCompleted) {
            pageLoaded.completeError(
              const JsEngineException(
                kind: JsFailureKind.bridge,
                message: '页面 WebView 主页面加载失败',
              ),
            );
          }
        },
        onNavigationRequest: (NavigationRequest navigation) {
          /// 只允许普通网页、内联 HTML 和空白释放页，拒绝页面拉起外部系统 Scheme。
          final Uri? uri = Uri.tryParse(navigation.url);
          final String scheme = uri?.scheme.toLowerCase() ?? '';
          return <String>{'http', 'https', 'about', 'data'}.contains(scheme)
              ? NavigationDecision.navigate
              : NavigationDecision.prevent;
        },
      ),
    );
    _controller = controller;
  }

  /// 加载 URL 或调用方提供的 HTML，并等待主页面完成。
  Future<void> load(WebViewScriptRequest request) async {
    throwIfCancelled();
    /// 已完成初始化的 Controller。
    final WebViewController? controller = _controller;
    if (controller == null) {
      throw const JsEngineException(
        kind: JsFailureKind.bridge,
        message: '页面 WebView 尚未初始化',
      );
    }
    /// 本次业务页面加载完成信号。
    final Completer<void> pageLoaded = Completer<void>();
    _pageLoaded = pageLoaded;
    /// 可选内联页面文本；非空时基于请求 URI 解析相对资源。
    final String? html = request.html;
    /// 页面请求提交与主框架完成两个阶段的组合等待，取消监听在请求提交期间也已生效。
    final Future<void> loadRequest;
    if (html != null) {
      loadRequest = controller.loadHtmlString(html, baseUrl: request.uri.toString());
    } else {
      loadRequest = controller.loadRequest(request.uri, headers: request.headers);
    }
    await Future.wait<void>(<Future<void>>[loadRequest, pageLoaded.future]);
    throwIfCancelled();
  }

  /// 执行调用方脚本；脚本为空时读取当前完整 DOM。
  Future<Object?> evaluate(String? script) async {
    throwIfCancelled();
    /// 已完成初始化的 Controller。
    final WebViewController? controller = _controller;
    if (controller == null) {
      throw const JsEngineException(
        kind: JsFailureKind.bridge,
        message: '页面 WebView 尚未初始化',
      );
    }
    /// 去除首尾空白后的调用方脚本，只用于判断 Android 页面回调语义，不写入日志。
    final String normalizedScript = script?.trim() ?? '';
    /// 实际交给页面执行的脚本，不记录其内容。
    final String source = normalizedScript.isEmpty
        ? 'document.documentElement.outerHTML'
        : normalizedScript;
    /// 是否等待 Android `window.legado.getHTML/getSource` 异步页面回调。
    final bool waitsForLegadoCallback = normalizedScript.contains('legado.getHTML') ||
        normalizedScript.contains('legado.getSource');
    if (waitsForLegadoCallback) {
      /// 本次脚本回调信号，在总请求超时或取消时由外层统一终止。
      final Completer<Object?> scriptCallback = Completer<Object?>();
      _scriptCallback = scriptCallback;
      await _installLegadoPageBridge(controller);
      /// 页面脚本提交结果；与异步 channel 回调同时等待，避免取消错误无人接收。
      final Future<Object?> scriptExecution = controller
          .runJavaScript(source)
          .then<Object?>((_) => null);
      /// 第一项是脚本提交完成，第二项是 `window.legado` 结果回调。
      final List<Object?> callbackResults = await Future.wait<Object?>(
        <Future<Object?>>[scriptExecution, scriptCallback.future],
      );
      /// `window.legado` 回传的页面结果文本。
      final Object? callbackValue = callbackResults.length > 1
          ? callbackResults[1]
          : null;
      throwIfCancelled();
      return callbackValue;
    }
    final Object value = await controller.runJavaScriptReturningResult(source);
    throwIfCancelled();
    return value;
  }

  /// 注入 Android WebView 兼容的最小 `window.legado` 结果桥，不暴露网络或文件能力。
  Future<void> _installLegadoPageBridge(WebViewController controller) async {
    await controller.runJavaScript('''
      globalThis.legado = globalThis.legado || {};
      globalThis.legado.getHTML = function(value) {
        LegadoWebViewResult.postMessage(String(value == null ? '' : value));
      };
      globalThis.legado.getSource = function(value) {
        LegadoWebViewResult.postMessage(String(value == null ? '' : value));
      };
    ''');
  }

  /// 返回重定向后的当前地址；无法解析时安全回退到初始地址。
  Future<Uri> currentUri(Uri fallback) async {
    /// 已完成初始化的 Controller。
    final WebViewController? controller = _controller;
    if (controller == null) {
      return fallback;
    }
    /// 平台 WebView 当前 URL 文本。
    final String? currentUrl = await controller.currentUrl();
    return currentUrl == null ? fallback : Uri.tryParse(currentUrl) ?? fallback;
  }

  /// 标记会话终止并唤醒仍在等待页面完成的 Future。
  void cancel(JsEngineException error) {
    if (_terminalError != null) {
      return;
    }
    _terminalError = error;
    /// 仍在等待的主页面加载信号。
    final Completer<void>? pageLoaded = _pageLoaded;
    if (pageLoaded != null && !pageLoaded.isCompleted) {
      pageLoaded.completeError(error);
    }
    /// 仍在等待的 Android 页面脚本回调信号。
    final Completer<Object?>? scriptCallback = _scriptCallback;
    if (scriptCallback != null && !scriptCallback.isCompleted) {
      scriptCallback.completeError(error);
    }
  }

  /// 在每个异步阶段之间检查取消或关闭状态。
  void throwIfCancelled() {
    final JsEngineException? error = _terminalError;
    if (error != null) {
      throw error;
    }
  }

  /// 用空 Delegate 替换业务回调并加载空白页，释放页面、闭包和脚本上下文引用。
  Future<void> release() async {
    if (_released) {
      return;
    }
    _released = true;
    /// 等待释放的 Controller；为空表示初始化前已经取消。
    final WebViewController? controller = _controller;
    _controller = null;
    _pageLoaded = null;
    _scriptCallback = null;
    if (controller == null) {
      return;
    }
    try {
      await controller.removeJavaScriptChannel(_resultChannelName);
      await controller.setNavigationDelegate(NavigationDelegate());
      await controller.loadHtmlString('<!doctype html><html><body></body></html>');
    } catch (error) {
      // 页面资源正在由系统销毁时无需重试；Controller 引用已经解除。
    }
  }
}

/// 尚未接入原生页面容器时的明确失败实现。
final class UnsupportedWebViewScriptBridge implements WebViewScriptBridge {
  /// 创建未支持的 WebView 桥。
  const UnsupportedWebViewScriptBridge();

  @override
  Future<void> close() async {}

  @override
  Future<WebViewScriptResponse> execute(
    WebViewScriptRequest request, {
    JsCancellationToken? cancellationToken,
  }) {
    throw const JsEngineException(
      kind: JsFailureKind.unsupportedApi,
      message: '页面 WebView 脚本桥尚未接入 Android/iOS 平台实现',
    );
  }
}
