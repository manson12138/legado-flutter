import 'package:webview_flutter/webview_flutter.dart';

import 'cookie_manager.dart';

/// 使用 Flutter 官方 WebView Cookie Store 连接统一 HTTP Cookie 与平台 WebView。
///
/// Android 由系统 `CookieManager` 承载，iOS 由 `WKHTTPCookieStore` 承载；业务层仍只保存
/// `name=value` 请求头文本，不依赖任何 Android 或 iOS 原生 Cookie 类型。
final class FlutterWebViewCookieBridge implements WebViewCookieBridge {
  /// 创建 WebView Cookie 桥，并允许组合根注入单例管理器供登录页和脚本页共享。
  FlutterWebViewCookieBridge({WebViewCookieManager? cookieManager})
    : _cookieManager = cookieManager ?? WebViewCookieManager();

  /// 当前应用内全部受控 WebView 共用的系统 Cookie 管理器。
  final WebViewCookieManager _cookieManager;

  /// 把统一 Cookie 请求头逐项写入目标域的 WebView Cookie Store。
  @override
  Future<void> writeCookies(Uri uri, String cookieHeader) async {
    if (uri.host.isEmpty || cookieHeader.trim().isEmpty) {
      return;
    }
    /// 目标域需要写入的 Cookie 名值对。
    final Map<String, String> cookies = _parseCookieHeader(cookieHeader);
    for (final MapEntry<String, String> cookie in cookies.entries) {
      await _cookieManager.setCookie(
        WebViewCookie(
          name: cookie.key,
          value: cookie.value,
          domain: uri.host,
          path: '/',
        ),
      );
    }
  }

  /// 从目标域的平台 Cookie Store 读取 Cookie，并转换为统一 HTTP 请求头格式。
  @override
  Future<String?> readCookies(Uri uri) async {
    if (uri.host.isEmpty) {
      return null;
    }
    /// 当前域由系统 WebView 返回的全部可见 Cookie，包含 iOS 的 HttpOnly Cookie。
    final List<WebViewCookie> cookies = await _cookieManager.getCookies(domain: uri);
    if (cookies.isEmpty) {
      return null;
    }
    return cookies
        .map((WebViewCookie cookie) => '${cookie.name}=${cookie.value}')
        .join('; ');
  }

  /// 清理受控 WebView 的隔离会话，防止上一本书源登录状态泄漏到下一次页面会话。
  ///
  /// Flutter 官方接口当前只提供全局清理，因此这里会清空 WebView Cookie Store；调用方随后
  /// 必须从统一 Cookie 管理器重新写入目标域 Cookie。持久事实仍以 Dart 数据库为准。
  @override
  Future<void> clearSessionCookies() async {
    await _cookieManager.clearCookies();
  }

  /// 将 `name=value; name2=value2` 请求头解析为名值对，不把属性或原文写入日志。
  Map<String, String> _parseCookieHeader(String value) {
    /// 解析后按 Cookie 名索引的结果，重复名称以后出现的值为准。
    final Map<String, String> result = <String, String>{};
    for (final String part in value.split(';')) {
      /// 当前 Cookie 片段中名称和值的分隔位置。
      final int equalsIndex = part.indexOf('=');
      if (equalsIndex <= 0) {
        continue;
      }
      /// 去除空白后的 Cookie 名称。
      final String name = part.substring(0, equalsIndex).trim();
      if (name.isEmpty) {
        continue;
      }
      /// 保留等号后的完整 Cookie 值，兼容 Base64 等包含等号的内容。
      final String cookieValue = part.substring(equalsIndex + 1).trim();
      result[name] = cookieValue;
    }
    return result;
  }
}
