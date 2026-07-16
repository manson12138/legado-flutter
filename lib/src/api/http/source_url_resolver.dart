import 'dart:convert';

import '../../domain/model/book_source.dart';
import 'http_contract.dart';

/// 已解析的书源请求与 Android URL 选项元数据。
final class ResolvedSourceRequest {
  /// 创建不可变书源请求。
  const ResolvedSourceRequest({
    required this.request,
    required this.charset,
    required this.retryCount,
    this.bodyJavaScript,
  });

  /// 可交给统一网络层执行的请求。
  final HttpRequest request;

  /// 规则显式指定的响应字符集。
  final String? charset;

  /// Android URL 选项中的重试次数；由上层编排执行。
  final int retryCount;

  /// Android URL 选项中的 `bodyJs`，由上层在响应解码后执行。
  final String? bodyJavaScript;
}

/// URL 普通部分与 Android JavaScript 选项的只读解析结果。
final class SourceUrlJavaScriptOptions {
  /// 创建不可变 URL JavaScript 选项。
  const SourceUrlJavaScriptOptions({
    required this.urlText,
    this.urlJavaScript,
    this.bodyJavaScript,
  });

  /// 不包含 `,{...}` 选项的 URL 文本。
  final String urlText;

  /// 发起请求前、以绝对 URL 为 `result` 执行的脚本。
  final String? urlJavaScript;

  /// 响应解码后、以正文为 `result` 执行的脚本。
  final String? bodyJavaScript;
}

/// 解析 Android 书源 URL 普通语法，不执行 JavaScript 或 WebView。
final class SourceUrlResolver {
  /// 创建无状态 URL 解析器。
  const SourceUrlResolver();

  /// 解析 URL、页码规则、Header、请求方法与 Body。
  ResolvedSourceRequest resolve({
    required String rawUrl,
    required Uri baseUri,
    required BookSource source,
    String? keyword,
    int? page,
    String? header,
    String? evaluatedOptionUrl,
    bool javaScriptOptionsEvaluated = false,
  }) {
    /// 仅允许无需脚本求值的内建变量，其余内嵌表达式仍交给 M4。
    final String variableResolved = rawUrl
        .replaceAll('{{key}}', keyword ?? '')
        .replaceAll('{{page}}', page?.toString() ?? '');
    /// 已替换 `<第一页,后续页>` 的 URL 规则。
    final String pageResolved = _replacePage(variableResolved, page);
    /// URL 与 JSON 选项分隔位置。
    final RegExpMatch? optionStart = RegExp(r'\s*,\s*(?=\{)').firstMatch(pageResolved);
    /// 不含选项的 URL。
    final String parsedUrlText = (optionStart == null
            ? pageResolved
            : pageResolved.substring(0, optionStart.start))
        .trim();
    _rejectJavaScript(parsedUrlText, 'URL');
    /// JSON 选项对象。
    final Map<String, Object?> option = optionStart == null
        ? <String, Object?>{}
        : _decodeObject(pageResolved.substring(optionStart.end));
    _rejectUnsupportedOptions(
      option,
      javaScriptOptionsEvaluated: javaScriptOptionsEvaluated,
    );
    /// 已执行 UrlOption.js 后得到的候选 URL；空值继续使用原始 URL。
    final String normalizedEvaluatedOptionUrl =
        evaluatedOptionUrl?.trim() ?? '';
    final String urlText = normalizedEvaluatedOptionUrl.isNotEmpty
        ? normalizedEvaluatedOptionUrl
        : parsedUrlText;
    /// 书源级 Header。
    final Map<String, String> headers = _decodeHeaders(header ?? source.header);
    headers.addAll(_coerceHeaders(option['headers']));
    if (_findHeader(headers, 'proxy')?.trim().isNotEmpty == true) {
      throw const UnifiedHttpException(
        HttpFailureKind.unsupportedOption,
        '书源代理需要跨平台代理实现',
      );
    }
    /// 请求方法文本。
    final String methodText = _asString(option['method'])?.toUpperCase() ?? 'GET';
    /// 请求体文本。
    final String? bodyText = _bodyString(option['body']);
    /// Content-Type Header。
    final String? contentType = _findHeader(headers, 'content-type');
    /// 请求体描述。
    final HttpRequestBody body = _buildBody(bodyText, contentType);
    /// Cookie 策略。
    final HttpCookieMode cookieMode = source.enabledCookieJar == false
        ? HttpCookieMode.disabled
        : HttpCookieMode.shared;
    return ResolvedSourceRequest(
      request: HttpRequest(
        uri: baseUri.resolve(urlText),
        method: _parseMethod(methodText),
        headers: headers,
        body: body,
        cookieMode: cookieMode,
      ),
      charset: _asString(option['charset']),
      retryCount: _asInt(option['retry']) ?? 0,
      bodyJavaScript: _asString(option['bodyJs']),
    );
  }

  /// 读取 URL 普通部分以及 `js/bodyJs`，网络层不在此执行脚本。
  SourceUrlJavaScriptOptions readJavaScriptOptions({
    required String rawUrl,
    String? keyword,
    int? page,
  }) {
    /// 替换搜索关键字和页码后的 URL 规则。
    final String variableResolved = rawUrl
        .replaceAll('{{key}}', keyword ?? '')
        .replaceAll('{{page}}', page?.toString() ?? '');
    /// 替换 Android 页码选择语法后的 URL 规则。
    final String pageResolved = _replacePage(variableResolved, page);
    /// URL 与 JSON 选项分隔位置。
    final RegExpMatch? optionStart = RegExp(r'\s*,\s*(?=\{)').firstMatch(pageResolved);
    /// 不包含选项的 URL 文本。
    final String urlText = (optionStart == null
            ? pageResolved
            : pageResolved.substring(0, optionStart.start))
        .trim();
    if (optionStart == null) {
      return SourceUrlJavaScriptOptions(urlText: urlText);
    }
    /// Android URL JSON 选项。
    final Map<String, Object?> option = _decodeObject(pageResolved.substring(optionStart.end));
    return SourceUrlJavaScriptOptions(
      urlText: urlText,
      urlJavaScript: _asString(option['js']),
      bodyJavaScript: _asString(option['bodyJs']),
    );
  }

  /// 将 Android 页码选择语法替换为当前页对应项。
  String _replacePage(String value, int? page) {
    if (page == null) {
      return value;
    }
    return value.replaceAllMapped(RegExp(r'<(.*?)>'), (Match match) {
      /// 页码候选项。
      final List<String> pages = (match.group(1) ?? '').split(',');
      if (pages.isEmpty) {
        return '';
      }
      /// Android 页码从 1 开始，超出范围重复最后一项。
      final int index = page > 0 && page <= pages.length ? page - 1 : pages.length - 1;
      return pages[index].trim();
    });
  }

  /// 构建普通请求体；无 Content-Type 且非 JSON/XML 时按表单处理。
  HttpRequestBody _buildBody(String? body, String? contentType) {
    if (body == null) {
      return const EmptyHttpRequestBody();
    }
    /// 去除首尾空白后的正文。
    final String trimmed = body.trim();
    if (contentType == null && !_looksLikeJson(trimmed) && !_looksLikeXml(trimmed)) {
      /// 表单字段。
      final Map<String, String> fields = <String, String>{};
      for (final String part in body.split('&')) {
        /// 等号位置。
        final int equalsIndex = part.indexOf('=');
        /// 字段名。
        final String key = equalsIndex < 0 ? part : part.substring(0, equalsIndex);
        if (key.isNotEmpty) {
          fields[key] = equalsIndex < 0 ? '' : part.substring(equalsIndex + 1);
        }
      }
      return FormHttpRequestBody(fields);
    }
    return TextHttpRequestBody(body, contentType: contentType);
  }

  /// 将请求方法文本转换为统一枚举。
  HttpRequestMethod _parseMethod(String method) {
    return switch (method) {
      'GET' => HttpRequestMethod.get,
      'POST' => HttpRequestMethod.post,
      'PUT' => HttpRequestMethod.put,
      'PATCH' => HttpRequestMethod.patch,
      'DELETE' => HttpRequestMethod.delete,
      'HEAD' => HttpRequestMethod.head,
      _ => throw UnifiedHttpException(
        HttpFailureKind.unsupportedOption,
        '不支持请求方法 $method',
      ),
    };
  }

  /// 解码 JSON 对象边界。
  Map<String, Object?> _decodeObject(String text) {
    try {
      /// JSON 解码结果。
      final Object? decoded = jsonDecode(text);
      if (decoded is Map<String, Object?>) {
        return decoded;
      }
      throw const FormatException('URL 选项必须是 JSON 对象');
    } on FormatException catch (error) {
      throw UnifiedHttpException(
        HttpFailureKind.unsupportedOption,
        'URL 选项 JSON 无效：${error.message}',
      );
    }
  }

  /// 解码书源级 Header JSON。
  Map<String, String> _decodeHeaders(String? text) {
    if (text == null || text.trim().isEmpty) {
      return <String, String>{};
    }
    _rejectJavaScript(text, 'Header');
    return _coerceHeaders(_decodeObject(text));
  }

  /// 将不可信 Header 对象收敛为字符串 Map。
  Map<String, String> _coerceHeaders(Object? value) {
    /// Header 结果。
    final Map<String, String> result = <String, String>{};
    if (value is Map) {
      for (final MapEntry<Object?, Object?> entry in value.entries) {
        if (entry.key != null && entry.value != null) {
          result[entry.key.toString()] = entry.value.toString();
        }
      }
    }
    return result;
  }

  /// 拒绝 M3 不支持的 JS、WebView、自定义 DNS 与服务端选项。
  void _rejectUnsupportedOptions(
    Map<String, Object?> option, {
    required bool javaScriptOptionsEvaluated,
  }) {
    /// Android 除空、false 与字符串 false 外均视为启用 WebView。
    final bool webView = _isTruthyOption(option['webView']);
    if (webView || _asString(option['webJs'])?.isNotEmpty == true) {
      throw const UnifiedHttpException(
        HttpFailureKind.unsupportedOption,
        'WebView 请求属于 M4 平台能力',
      );
    }
    if (!javaScriptOptionsEvaluated &&
        (_asString(option['js'])?.isNotEmpty == true ||
            _asString(option['bodyJs'])?.isNotEmpty == true)) {
      throw const UnifiedHttpException(
        HttpFailureKind.unsupportedOption,
        'URL JavaScript 选项属于 M4',
      );
    }
    if (_asString(option['dnsIp'])?.isNotEmpty == true ||
        _asString(option['serverID'])?.isNotEmpty == true) {
      throw const UnifiedHttpException(
        HttpFailureKind.unsupportedOption,
        '自定义 DNS 或服务端选项尚无跨平台实现',
      );
    }
    if (_asString(option['type'])?.isNotEmpty == true) {
      throw const UnifiedHttpException(
        HttpFailureKind.unsupportedOption,
        '二进制媒体 type 选项不属于文本普通规则链路',
      );
    }
  }

  /// 检查规则是否包含 Android JavaScript 语法。
  void _rejectJavaScript(String value, String location) {
    if (value.contains('{{') ||
        value.contains('@js:') ||
        value.contains('<js>') ||
        value.contains('</js>')) {
      throw UnifiedHttpException(
        HttpFailureKind.unsupportedOption,
        '$location 包含 JavaScript，必须进入 M4',
      );
    }
  }

  /// 宽松读取字符串字段。
  String? _asString(Object? value) {
    if (value == null) {
      return null;
    }
    return value is String ? value : value.toString();
  }

  /// 将 URL 选项 Body 转成 Android 兼容文本，JSON 对象和数组保持 JSON 格式。
  String? _bodyString(Object? value) {
    if (value == null) {
      return null;
    }
    return value is String ? value : jsonEncode(value);
  }

  /// 判断 Android `webView: Any` 的启用语义。
  bool _isTruthyOption(Object? value) {
    if (value == null || value == false) {
      return false;
    }
    if (value is String) {
      return value.isNotEmpty && value.toLowerCase() != 'false';
    }
    return true;
  }

  /// 宽松读取整数。
  int? _asInt(Object? value) {
    return value is int ? value : int.tryParse(value?.toString() ?? '');
  }

  /// 判断文本是否像 JSON。
  bool _looksLikeJson(String value) {
    return (value.startsWith('{') && value.endsWith('}')) ||
        (value.startsWith('[') && value.endsWith(']'));
  }

  /// 判断文本是否像 XML。
  bool _looksLikeXml(String value) {
    return value.startsWith('<') && value.endsWith('>');
  }

  /// 忽略大小写查找 Header。
  String? _findHeader(Map<String, String> headers, String name) {
    for (final MapEntry<String, String> entry in headers.entries) {
      if (entry.key.toLowerCase() == name) {
        return entry.value;
      }
    }
    return null;
  }
}
