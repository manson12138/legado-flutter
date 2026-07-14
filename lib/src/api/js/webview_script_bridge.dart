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
