import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../app/app_dependencies.dart';

/// 使用受控 WebView 完成书源登录，并在进入和退出时同步统一 Cookie Store。
///
/// Android 使用系统 WebView，iOS 使用 WKWebView；本页面只管理平台视图、返回手势和 Cookie，
/// 不解析书源规则，也不持有搜索、书架或阅读业务状态。
final class BookSourceLoginRoute extends StatefulWidget {
  /// 创建书源登录页面。
  const BookSourceLoginRoute({
    required this.dependencies,
    required this.sourceUrl,
    super.key,
  });

  /// 应用组合根依赖，用于访问统一 Cookie 管理器。
  final AppDependencies dependencies;

  /// 书源配置提供的登录起始地址，只允许 HTTP 或 HTTPS。
  final String sourceUrl;

  /// 创建登录页面状态。
  @override
  State<BookSourceLoginRoute> createState() => _BookSourceLoginRouteState();
}

/// 管理单个登录 WebView 的加载、前后台 Cookie 保存、网页历史和资源释放。
final class _BookSourceLoginRouteState extends State<BookSourceLoginRoute>
    with WidgetsBindingObserver {
  /// 本页面独占的 WebView Controller，页面销毁后解除全部业务 Delegate。
  late final WebViewController _controller;

  /// 校验后的登录起始地址；无效输入保持为空并显示错误页。
  Uri? _initialUri;

  /// 重定向后的当前页面地址，用于按真实域回写 Cookie。
  Uri? _currentUri;

  /// 页面是否仍在加载主框架。
  bool _loading = true;

  /// 是否正在保存 Cookie 并退出，防止重复点击完成按钮。
  bool _closing = false;

  /// 当前 Cookie 同步任务；手动关闭会等待后台同步完成后再释放 WebView。
  Future<void>? _activeCookieSync;

  /// 可安全展示的主页面错误，不包含 URL、Cookie、Header 或网页正文。
  String? _errorMessage;

  /// 创建 Controller、注册应用生命周期并开始受控页面加载。
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = WebViewController();
    unawaited(_initialize());
  }

  /// 校验 URL、配置 Delegate、写入统一 Cookie 后加载登录页。
  Future<void> _initialize() async {
    /// 去除用户书源配置首尾空白后的地址。
    final String normalizedSourceUrl = widget.sourceUrl.trim();
    /// 解析后的登录地址；格式错误不交给平台 WebView。
    final Uri? initialUri = Uri.tryParse(normalizedSourceUrl);
    if (initialUri == null ||
        initialUri.host.isEmpty ||
        !<String>{'http', 'https'}.contains(initialUri.scheme.toLowerCase())) {
      if (mounted) {
        setState(() {
          _loading = false;
          _errorMessage = '书源登录地址无效，只支持 HTTP 或 HTTPS';
        });
      }
      return;
    }
    _initialUri = initialUri;
    _currentUri = initialUri;
    await _controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await _controller.setNavigationDelegate(
      NavigationDelegate(
        onPageStarted: (String url) {
          /// 页面重定向后的候选地址。
          final Uri? currentUri = Uri.tryParse(url);
          if (mounted) {
            setState(() {
              _currentUri = currentUri ?? _currentUri;
              _loading = true;
              _errorMessage = null;
            });
          }
        },
        onPageFinished: (String url) {
          /// 页面完成时最终确认的地址。
          final Uri? currentUri = Uri.tryParse(url);
          if (mounted) {
            setState(() {
              _currentUri = currentUri ?? _currentUri;
              _loading = false;
            });
          }
        },
        onWebResourceError: (WebResourceError error) {
          if (error.isForMainFrame != true || !mounted) {
            return;
          }
          setState(() {
            _loading = false;
            _errorMessage = '登录页面加载失败，请检查网络或书源登录地址';
          });
        },
        onNavigationRequest: (NavigationRequest navigation) {
          /// 页面申请跳转的目标地址。
          final Uri? target = Uri.tryParse(navigation.url);
          final String scheme = target?.scheme.toLowerCase() ?? '';
          if (<String>{'http', 'https', 'about', 'data'}.contains(scheme)) {
            return NavigationDecision.navigate;
          }
          _showMessage('已阻止登录页面打开外部应用');
          return NavigationDecision.prevent;
        },
      ),
    );
    try {
      /// 统一 HTTP Cookie Store 中当前登录域可发送的 Cookie。
      final String cookieHeader = await widget.dependencies.cookieManager.getCookieHeader(
        initialUri,
      );
      await widget.dependencies.cookieManager.webViewBridge.writeCookies(
        initialUri,
        cookieHeader,
      );
      await _controller.loadRequest(initialUri);
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _errorMessage = '登录页面初始化失败，请稍后重试';
        });
      }
    }
  }

  /// 前后台切换时保存已产生的 Cookie，页面本身由 WKWebView/WebView 保持。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      unawaited(_syncCookies(showError: false));
    }
  }

  /// 内存警告发生时先保存 Cookie；平台可回收网页进程，用户仍可用刷新恢复页面。
  @override
  void didHaveMemoryPressure() {
    unawaited(_syncCookies(showError: false));
  }

  /// 将起始域和重定向域 Cookie 回写统一 Store，不输出 Cookie 内容。
  Future<void> _syncCookies({required bool showError}) async {
    /// 已经运行的同步任务；新的关闭请求必须等待它结束，避免先销毁 WKWebView。
    final Future<void>? activeCookieSync = _activeCookieSync;
    if (activeCookieSync != null) {
      await activeCookieSync;
      return;
    }
    /// 本次同步完成信号，供并发的后台、内存警告或关闭请求等待。
    final Completer<void> completion = Completer<void>();
    _activeCookieSync = completion.future;
    try {
      /// 需要同步的去重页面域。
      final Set<Uri> targets = <Uri>{
        if (_initialUri case final Uri uri) uri,
        if (_currentUri case final Uri uri) uri,
      };
      for (final Uri target in targets) {
        /// 平台 WebView Store 中目标域的 Cookie 请求头。
        final String? cookieHeader = await widget.dependencies.cookieManager.webViewBridge
            .readCookies(target);
        await widget.dependencies.cookieManager.setCookieHeader(
          target,
          cookieHeader ?? '',
        );
      }
    } catch (error) {
      if (showError) {
        _showMessage('登录 Cookie 保存失败，请重试');
      }
    } finally {
      completion.complete();
      _activeCookieSync = null;
    }
  }

  /// 优先返回网页历史；没有网页历史时保存 Cookie 并关闭 Flutter 路由。
  Future<void> _handleBack() async {
    if (await _controller.canGoBack()) {
      await _controller.goBack();
      return;
    }
    await _finishLogin();
  }

  /// 保存登录 Cookie 并退出页面，重复触发只执行一次。
  Future<void> _finishLogin() async {
    if (_closing) {
      return;
    }
    setState(() {
      _closing = true;
    });
    await _syncCookies(showError: true);
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  /// 重新加载当前页面，供网络失败或 WKWebView 网页进程被系统回收后恢复。
  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _errorMessage = null;
    });
    await _controller.reload();
  }

  /// 展示不包含网页敏感数据的一次性提示。
  void _showMessage(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// 解除生命周期观察、替换 Delegate 并释放当前网页与闭包引用。
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_releaseWebView());
    super.dispose();
  }

  /// 用空白页和空 Delegate 解除 WebView 对页面、回调及 Route State 的引用。
  Future<void> _releaseWebView() async {
    try {
      await _controller.setNavigationDelegate(NavigationDelegate());
      await _controller.loadHtmlString('<!doctype html><html><body></body></html>');
    } catch (error) {
      // 原生页面已随路由销毁时不再重试，Dart 侧已解除生命周期观察。
    }
  }

  /// 构建支持 Safe Area、键盘、网页历史返回、刷新和完成操作的登录页面。
  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop) {
          unawaited(_handleBack());
        }
      },
      child: Scaffold(
        resizeToAvoidBottomInset: true,
        appBar: AppBar(
          leading: IconButton(
            onPressed: _closing ? null : _handleBack,
            icon: const Icon(Icons.arrow_back),
            tooltip: '返回',
          ),
          title: const Text('书源登录'),
          actions: <Widget>[
            IconButton(
              onPressed: _closing ? null : _reload,
              icon: const Icon(Icons.refresh),
              tooltip: '刷新页面',
            ),
            TextButton(
              onPressed: _closing ? null : _finishLogin,
              child: const Text('完成'),
            ),
          ],
        ),
        body: SafeArea(
          child: Stack(
            children: <Widget>[
              if (_initialUri != null) WebViewWidget(controller: _controller),
              if (_errorMessage case final String message)
                ColoredBox(
                  color: Theme.of(context).colorScheme.surface,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          const Icon(Icons.language_outlined, size: 48),
                          const SizedBox(height: 16),
                          Text(message, textAlign: TextAlign.center),
                          const SizedBox(height: 16),
                          FilledButton.icon(
                            onPressed: _initialUri == null ? _finishLogin : _reload,
                            icon: Icon(
                              _initialUri == null ? Icons.arrow_back : Icons.refresh,
                            ),
                            label: Text(_initialUri == null ? '返回' : '重新加载'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              if (_loading)
                const Align(
                  alignment: Alignment.topCenter,
                  child: LinearProgressIndicator(minHeight: 2),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
