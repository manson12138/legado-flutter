import '../../data/dao/cookie_dao.dart';
import '../../domain/model/cookie.dart';
import '../http/http_contract.dart';

/// 未来 WebView 与普通 HTTP 同步 Cookie 的平台边界。
abstract interface class WebViewCookieBridge {
  /// 将普通 HTTP Cookie 同步给 WebView。
  Future<void> writeCookies(Uri uri, String cookieHeader);

  /// 读取 WebView 当前 Cookie，用于登录后回写统一 Cookie 管理器。
  Future<String?> readCookies(Uri uri);

  /// 清理 WebView 会话 Cookie。
  Future<void> clearSessionCookies();
}

/// M3 的占位 WebView 桥；调用时明确提示能力属于 M4/平台实现。
final class UnsupportedWebViewCookieBridge implements WebViewCookieBridge {
  /// 创建未支持的 WebView Cookie 桥。
  const UnsupportedWebViewCookieBridge();

  @override
  Future<void> clearSessionCookies() => _unsupported();

  @override
  Future<String?> readCookies(Uri uri) => _unsupported();

  @override
  Future<void> writeCookies(Uri uri, String cookieHeader) => _unsupported();

  /// 统一抛出未支持错误，避免调用方误认为同步成功。
  Future<T> _unsupported<T>() {
    throw const UnifiedHttpException(
      HttpFailureKind.unsupportedOption,
      'WebView Cookie 同步需要 M4 平台实现',
    );
  }
}

/// 集中管理持久 Cookie 与内存会话 Cookie。
///
/// 为兼容 Android，持久层仍按域保存 `name=value` 请求头文本；同名 Cookie 后写值覆盖
/// 先写值，不记录 Cookie 内容。
final class LegadoCookieManager {
  /// 创建 Cookie 管理器。
  LegadoCookieManager(this._cookieDao, this.webViewBridge);

  /// Cookie 持久化 DAO。
  final CookieDao _cookieDao;

  /// WebView Cookie 平台桥。
  final WebViewCookieBridge webViewBridge;

  /// 按 `会话键|域` 保存的会话 Cookie。
  final Map<String, Map<String, String>> _sessionCookies =
      <String, Map<String, String>>{};

  /// 将显式 Header 与适用 Cookie 合并为新 Header。
  Future<Map<String, String>> applyRequestCookies(
    Uri uri,
    Map<String, String> headers, {
    required HttpCookieMode mode,
    String? sessionKey,
  }) async {
    /// 可安全修改的 Header 副本。
    final Map<String, String> result = Map<String, String>.from(headers);
    if (mode == HttpCookieMode.disabled) {
      return result;
    }
    /// 显式请求 Cookie。
    final Map<String, String> merged = _parseCookieHeader(_findHeader(result, 'cookie'));
    /// 从父域到精确域依次应用，让更具体域覆盖父域。
    for (final String domain in _candidateDomains(uri.host).reversed) {
      if (mode == HttpCookieMode.shared) {
        /// 当前域持久 Cookie。
        final Cookie? saved = await _cookieDao.get(domain);
        if (saved != null) {
          merged.addAll(_parseCookieHeader(saved.cookie));
        }
      }
      /// 当前域会话 Cookie。
      final Map<String, String>? session = _sessionCookies[
        _sessionMapKey(mode, sessionKey, domain)
      ];
      if (session != null) {
        merged.addAll(session);
      }
    }
    _removeHeader(result, 'cookie');
    if (merged.isNotEmpty) {
      result['Cookie'] = _serializeCookies(merged);
    }
    return result;
  }

  /// 保存响应 `Set-Cookie`；持久 Cookie 进入数据库，会话 Cookie 仅留内存。
  Future<void> saveResponseCookies(
    Uri uri,
    Map<String, List<String>> headers, {
    required HttpCookieMode mode,
    String? sessionKey,
  }) async {
    if (mode == HttpCookieMode.disabled) {
      return;
    }
    /// 响应中的全部 Set-Cookie 行。
    final List<String> setCookieLines = _findHeaderValues(headers, 'set-cookie');
    if (setCookieLines.isEmpty) {
      return;
    }
    /// 当前响应主机。
    final String responseHost = uri.host.toLowerCase();
    for (final String line in setCookieLines) {
      /// 分号分隔的 Cookie 属性。
      final List<String> parts = line.split(';');
      if (parts.isEmpty) {
        continue;
      }
      /// 首段 `name=value`。
      final Map<String, String> cookie = _parseCookieHeader(parts.first);
      if (cookie.isEmpty) {
        continue;
      }
      /// Cookie 声明的域；缺省使用响应主机。
      String domain = responseHost;
      /// 是否为可持久 Cookie。
      bool persistent = false;
      /// 是否要求立即删除 Cookie。
      bool deleteCookie = false;
      for (final String rawAttribute in parts.skip(1)) {
        /// 去除空白的属性。
        final String attribute = rawAttribute.trim();
        /// 属性等号位置。
        final int equalsIndex = attribute.indexOf('=');
        /// 小写属性名。
        final String name = (equalsIndex < 0
                ? attribute
                : attribute.substring(0, equalsIndex))
            .trim()
            .toLowerCase();
        /// 属性值。
        final String value = equalsIndex < 0
            ? ''
            : attribute.substring(equalsIndex + 1).trim();
        if (name == 'domain' && value.isNotEmpty) {
          domain = value.startsWith('.') ? value.substring(1).toLowerCase() : value.toLowerCase();
        } else if (name == 'expires') {
          persistent = true;
          /// 过期时间。
          final DateTime? expiresAt = DateTime.tryParse(value);
          deleteCookie = expiresAt != null && expiresAt.isBefore(DateTime.now().toUtc());
        } else if (name == 'max-age') {
          persistent = true;
          /// 最大存活秒数。
          final int? maxAge = int.tryParse(value);
          deleteCookie = maxAge != null && maxAge <= 0;
        }
      }
      if (!_domainMatches(responseHost, domain)) {
        continue;
      }
      if (persistent && mode == HttpCookieMode.shared) {
        await _mergePersistent(domain, cookie, deleteCookie: deleteCookie);
      } else {
        _mergeSession(
          _sessionMapKey(mode, sessionKey, domain),
          cookie,
          deleteCookie: deleteCookie,
        );
      }
    }
  }

  /// 清空指定独立内存会话，不影响共享持久 Cookie。
  void clearIsolatedSession(String sessionKey) {
    _sessionCookies.removeWhere(
      (String key, Map<String, String> value) => key.startsWith('isolated:$sessionKey|'),
    );
  }

  /// 读取指定地址当前可发送的 Cookie 请求头。
  Future<String> getCookieHeader(Uri uri) async {
    /// 合并 Cookie 后的 Header。
    final Map<String, String> headers = await applyRequestCookies(
      uri,
      const <String, String>{},
      mode: HttpCookieMode.shared,
    );
    return _findHeader(headers, 'cookie') ?? '';
  }

  /// 以 Android `CookieStore.setCookie` 语义替换当前主域持久 Cookie。
  Future<void> setCookieHeader(Uri uri, String cookieHeader) async {
    /// 持久化作用域域名。
    final String domain = _candidateDomains(uri.host).lastOrNull ?? uri.host.toLowerCase();
    if (cookieHeader.trim().isEmpty) {
      await _cookieDao.delete(domain);
    } else {
      await _cookieDao.upsert(Cookie(url: domain, cookie: cookieHeader));
    }
  }

  /// 合并写入当前主域持久 Cookie，同名值覆盖旧值。
  Future<void> replaceCookieHeader(Uri uri, String cookieHeader) async {
    /// 持久化作用域域名。
    final String domain = _candidateDomains(uri.host).lastOrNull ?? uri.host.toLowerCase();
    await _mergePersistent(domain, _parseCookieHeader(cookieHeader), deleteCookie: false);
  }

  /// 将新 Cookie 合并进指定域的持久记录。
  Future<void> _mergePersistent(
    String domain,
    Map<String, String> incoming, {
    required bool deleteCookie,
  }) async {
    /// 已持久化 Cookie。
    final Cookie? saved = await _cookieDao.get(domain);
    /// 合并后的 Cookie Map。
    final Map<String, String> merged = _parseCookieHeader(saved?.cookie);
    for (final MapEntry<String, String> entry in incoming.entries) {
      if (deleteCookie) {
        merged.remove(entry.key);
      } else {
        merged[entry.key] = entry.value;
      }
    }
    if (merged.isEmpty) {
      await _cookieDao.delete(domain);
    } else {
      await _cookieDao.upsert(Cookie(url: domain, cookie: _serializeCookies(merged)));
    }
  }

  /// 将新 Cookie 合并进内存会话。
  void _mergeSession(
    String key,
    Map<String, String> incoming, {
    required bool deleteCookie,
  }) {
    /// 当前会话 Cookie Map。
    final Map<String, String> merged = _sessionCookies.putIfAbsent(
      key,
      () => <String, String>{},
    );
    for (final MapEntry<String, String> entry in incoming.entries) {
      if (deleteCookie) {
        merged.remove(entry.key);
      } else {
        merged[entry.key] = entry.value;
      }
    }
    if (merged.isEmpty) {
      _sessionCookies.remove(key);
    }
  }

  /// 将 Cookie 请求头解析为按名称索引的值。
  Map<String, String> _parseCookieHeader(String? value) {
    /// 解析结果。
    final Map<String, String> result = <String, String>{};
    if (value == null || value.trim().isEmpty) {
      return result;
    }
    for (final String part in value.split(';')) {
      /// 首个等号位置，Cookie 值自身可以继续包含等号。
      final int equalsIndex = part.indexOf('=');
      if (equalsIndex <= 0) {
        continue;
      }
      /// Cookie 名称。
      final String name = part.substring(0, equalsIndex).trim();
      if (name.isNotEmpty) {
        result[name] = part.substring(equalsIndex + 1).trim();
      }
    }
    return result;
  }

  /// 将 Cookie Map 序列化成请求头文本。
  String _serializeCookies(Map<String, String> cookies) {
    return cookies.entries
        .map((MapEntry<String, String> entry) => '${entry.key}=${entry.value}')
        .join('; ');
  }

  /// 生成从精确主机到父域的候选域。
  List<String> _candidateDomains(String host) {
    if (Uri(host: host).host == host && RegExp(r'^\d+(?:\.\d+){3}$').hasMatch(host)) {
      return <String>[host];
    }
    /// 小写域名分段。
    final List<String> labels = host.toLowerCase().split('.');
    /// 候选域结果。
    final List<String> result = <String>[];
    for (int index = 0; index < labels.length - 1; index += 1) {
      /// 当前候选域。
      final String domain = labels.sublist(index).join('.');
      if (domain.isNotEmpty) {
        result.add(domain);
      }
    }
    return result;
  }

  /// 判断响应主机是否允许写入声明域。
  bool _domainMatches(String host, String domain) {
    return host == domain || host.endsWith('.$domain');
  }

  /// 构建会话 Cookie Map 键。
  String _sessionMapKey(HttpCookieMode mode, String? sessionKey, String domain) {
    return mode == HttpCookieMode.isolated
        ? 'isolated:${sessionKey ?? 'default'}|$domain'
        : 'shared|$domain';
  }

  /// 忽略大小写读取单值 Header。
  String? _findHeader(Map<String, String> headers, String name) {
    for (final MapEntry<String, String> entry in headers.entries) {
      if (entry.key.toLowerCase() == name) {
        return entry.value;
      }
    }
    return null;
  }

  /// 忽略大小写删除 Header。
  void _removeHeader(Map<String, String> headers, String name) {
    headers.removeWhere((String key, String value) => key.toLowerCase() == name);
  }

  /// 忽略大小写读取多值 Header。
  List<String> _findHeaderValues(Map<String, List<String>> headers, String name) {
    for (final MapEntry<String, List<String>> entry in headers.entries) {
      if (entry.key.toLowerCase() == name) {
        return entry.value;
      }
    }
    return const <String>[];
  }
}

/// 为列表提供不抛异常的末元素读取。
extension _LastOrNullExtension<T> on List<T> {
  /// 返回末元素，空列表返回 `null`。
  T? get lastOrNull => isEmpty ? null : last;
}
