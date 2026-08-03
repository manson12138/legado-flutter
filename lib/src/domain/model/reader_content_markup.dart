import 'dart:convert';

/// 正文管线在纯文本缓存中保存受控资源时使用的不可见标记协议。
///
/// 该协议只在书源解析器与阅读正文处理器之间传递图片元数据，不直接展示给用户，
/// 也不允许把任意 HTML 或脚本重新带入阅读页面。
abstract final class ReaderContentMarkup {
  /// 图片标记固定前缀，使用私用区字符降低与真实小说正文冲突的概率。
  static const String _imagePrefix = '\uE120LEGADO_IMAGE:';

  /// 资源标记固定后缀。
  static const String _markerSuffix = ':END\uE121';

  /// 匹配一整段图片资源标记，不接受标记外的任意可执行内容。
  static final RegExp imageMarkerPattern = RegExp(
    '${RegExp.escape(_imagePrefix)}([A-Za-z0-9_-]+)${RegExp.escape(_markerSuffix)}',
  );

  /// 把已校验的绝对图片地址和替代文本编码为可缓存的纯文本标记。
  static String encodeImage({
    required Uri uri,
    required String altText,
    required Uri referer,
    String? requestUrl,
  }) {
    /// 图片资源的最小 JSON 载荷。
    final String payload = jsonEncode(<String, String>{
      'url': uri.toString(),
      'alt': altText.trim(),
      'referer': referer.toString(),
      if (requestUrl != null && requestUrl.trim().isNotEmpty)
        'requestUrl': requestUrl.trim(),
    });
    /// 不含补位符的 URL-safe Base64，避免标记引入换行或 HTML 字符。
    final String encoded = base64Url.encode(utf8.encode(payload)).replaceAll('=', '');
    return '$_imagePrefix$encoded$_markerSuffix';
  }

  /// 从完整段落解析图片标记；损坏、超长或非 HTTP(S) 地址统一视为普通文本。
  static ReaderMarkedImage? tryParseImage(String paragraph) {
    /// 去除段落外层空白后的候选标记。
    final String normalized = paragraph.trim();
    /// 完整图片标记匹配结果。
    final RegExpMatch? match = imageMarkerPattern.firstMatch(normalized);
    if (match == null || match.start != 0 || match.end != normalized.length) {
      return null;
    }
    /// Base64 图片元数据；缺失时不继续解析。
    final String? encoded = match.group(1);
    if (encoded == null || encoded.length > 16 * 1024) {
      return null;
    }
    try {
      /// 恢复 Base64 标准要求的补位符。
      final String padded = encoded.padRight((encoded.length + 3) ~/ 4 * 4, '=');
      /// 解码后的不可信 JSON 值。
      final Object? decoded = jsonDecode(utf8.decode(base64Url.decode(padded)));
      if (decoded is! Map<String, Object?>) {
        return null;
      }
      /// 图片绝对地址文本。
      final Object? urlValue = decoded['url'];
      if (urlValue is! String) {
        return null;
      }
      /// 图片绝对地址。
      final Uri? uri = Uri.tryParse(urlValue);
      if (uri == null ||
          uri.host.isEmpty ||
          !<String>{'http', 'https'}.contains(uri.scheme.toLowerCase())) {
        return null;
      }
      /// 图片不可用时展示的简短替代文本。
      final String altText = decoded['alt'] is String
          ? (decoded['alt'] as String).trim()
          : '';
      /// 图片请求可使用的正文页面来源地址。
      final Uri? referer = decoded['referer'] is String
          ? Uri.tryParse(decoded['referer'] as String)
          : null;
      /// 可保留图片 Header 选项的绝对请求规则；旧缓存缺失时回退图片地址。
      final String requestUrl = decoded['requestUrl'] is String &&
              (decoded['requestUrl'] as String).trim().isNotEmpty
          ? (decoded['requestUrl'] as String).trim()
          : uri.toString();
      return ReaderMarkedImage(
        uri: uri,
        altText: altText,
        requestUrl: requestUrl,
        referer: referer != null &&
                referer.host.isNotEmpty &&
                <String>{'http', 'https'}.contains(referer.scheme.toLowerCase())
            ? referer.toString()
            : '',
      );
    } on FormatException {
      return null;
    }
  }

  /// 临时保护全部资源标记，并对非标记文本执行转换后恢复原标记。
  static String transformTextOutsideMarkers(
    String input,
    String Function(String text) transform,
  ) {
    /// 转换结果缓冲区。
    final StringBuffer output = StringBuffer();
    /// 上一个资源标记结束位置。
    int cursor = 0;
    for (final RegExpMatch match in imageMarkerPattern.allMatches(input)) {
      output.write(transform(input.substring(cursor, match.start)));
      output.write(match.group(0));
      cursor = match.end;
    }
    output.write(transform(input.substring(cursor)));
    return output.toString();
  }
}

/// 从正文资源标记解码得到的安全图片元数据。
final class ReaderMarkedImage {
  /// 创建已验证为 HTTP(S) 的图片资源。
  const ReaderMarkedImage({
    required this.uri,
    required this.altText,
    required this.requestUrl,
    required this.referer,
  });

  /// 图片绝对地址。
  final Uri uri;

  /// 图片加载失败时使用的替代文本。
  final String altText;

  /// 可保留 Android URL Header 选项的图片请求规则。
  final String requestUrl;

  /// 图片防盗链请求可使用的正文页面 Referer。
  final String referer;
}
