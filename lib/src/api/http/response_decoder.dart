import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:enough_convert/enough_convert.dart';

import 'http_contract.dart';

/// 解码后的文本响应，同时保留最终 URL 与实际字符集。
final class DecodedHttpResponse {
  /// 创建不可变文本响应。
  const DecodedHttpResponse({
    required this.text,
    required this.charset,
    required this.response,
  });

  /// 解码文本。
  final String text;

  /// 最终采用的小写字符集名称。
  final String charset;

  /// 原始字节响应。
  final HttpResponse response;
}

/// 集中处理压缩与字符集，优先级对齐 Android：规则指定、响应 Header、正文声明、检测。
final class HttpResponseDecoder {
  /// 创建无状态响应解码器。
  const HttpResponseDecoder();

  /// 解压并解码 HTTP 响应。
  DecodedHttpResponse decode(HttpResponse response, {String? ruleCharset}) {
    /// 解压后的响应字节。
    final Uint8List bytes = _decompress(response);
    /// 规则显式字符集。
    final String? normalizedRuleCharset = _normalizeCharset(ruleCharset);
    /// Content-Type 声明的字符集。
    final String? headerCharset = _charsetFromContentType(
      response.firstHeader('content-type'),
    );
    /// HTML meta 或 XML 声明的字符集。
    final String? documentCharset = _charsetFromDocument(bytes);
    /// 最终字符集。
    final String charset = normalizedRuleCharset ??
        headerCharset ??
        documentCharset ??
        (_isValidUtf8(bytes) ? 'utf-8' : 'gbk');
    try {
      return DecodedHttpResponse(
        text: _stripUtf8Bom(_decodeBytes(bytes, charset)),
        charset: charset,
        response: response,
      );
    } on FormatException catch (error) {
      throw UnifiedHttpException(
        HttpFailureKind.decode,
        '响应无法按字符集 $charset 解码：${error.message}',
      );
    } on UnifiedHttpException {
      rethrow;
    } catch (error) {
      throw UnifiedHttpException(
        HttpFailureKind.decode,
        '响应无法按字符集 $charset 解码',
      );
    }
  }

  /// 根据媒体类型或 Content-Encoding 解压响应。
  Uint8List _decompress(HttpResponse response) {
    /// 原始字节。
    final Uint8List bytes = response.bytes;
    /// Content-Encoding 小写值。
    final String encoding = (response.firstHeader('content-encoding') ?? '').toLowerCase();
    /// Content-Type 小写值。
    final String contentType = (response.firstHeader('content-type') ?? '').toLowerCase();
    if (encoding.contains('gzip')) {
      return Uint8List.fromList(GZipDecoder().decodeBytes(bytes));
    }
    if (encoding.contains('deflate')) {
      return Uint8List.fromList(ZLibDecoder().decodeBytes(bytes));
    }
    if (contentType.contains('application/zip') || _hasZipSignature(bytes)) {
      /// ZIP 归档。
      final Archive archive = ZipDecoder().decodeBytes(bytes);
      for (final ArchiveFile file in archive.files) {
        if (file.isFile) {
          return Uint8List.fromList(file.content);
        }
      }
      throw const UnifiedHttpException(HttpFailureKind.decode, 'ZIP 响应不包含可读取文件');
    }
    return bytes;
  }

  /// 判断字节是否具有常见 ZIP 文件头。
  bool _hasZipSignature(Uint8List bytes) {
    return bytes.length >= 4 &&
        bytes[0] == 0x50 &&
        bytes[1] == 0x4B &&
        (bytes[2] == 0x03 || bytes[2] == 0x05 || bytes[2] == 0x07) &&
        (bytes[3] == 0x04 || bytes[3] == 0x06 || bytes[3] == 0x08);
  }

  /// 从 Content-Type 提取 charset。
  String? _charsetFromContentType(String? contentType) {
    if (contentType == null) {
      return null;
    }
    /// charset 参数匹配结果。
    final RegExpMatch? match = RegExp(
      r'''charset\s*=\s*["']?([^;"'\s]+)''',
      caseSensitive: false,
    ).firstMatch(contentType);
    return _normalizeCharset(match?.group(1));
  }

  /// 从文档开头的 HTML meta 或 XML 声明提取字符集。
  String? _charsetFromDocument(Uint8List bytes) {
    /// 只需扫描文档头部，Latin-1 可无损保留 ASCII 声明。
    final int previewLength = bytes.length < 8192 ? bytes.length : 8192;
    /// 文档头部预览。
    final String preview = latin1.decode(bytes.sublist(0, previewLength), allowInvalid: true);
    /// HTML charset 属性匹配。
    final RegExpMatch? direct = RegExp(
      r'''<meta[^>]+charset\s*=\s*["']?([^"'\s/>;]+)''',
      caseSensitive: false,
    ).firstMatch(preview);
    if (direct != null) {
      return _normalizeCharset(direct.group(1));
    }
    /// HTML http-equiv content 属性或 XML encoding 匹配。
    final RegExpMatch? embedded = RegExp(
      r'''(?:charset|encoding)\s*=\s*["']([^"']+)["']''',
      caseSensitive: false,
    ).firstMatch(preview);
    return _normalizeCharset(embedded?.group(1));
  }

  /// 判断整段字节是否为严格 UTF-8。
  bool _isValidUtf8(Uint8List bytes) {
    try {
      utf8.decode(bytes, allowMalformed: false);
      return true;
    } on FormatException {
      return false;
    }
  }

  /// 使用受支持字符集解码。
  String _decodeBytes(Uint8List bytes, String charset) {
    return switch (charset) {
      'utf-8' => utf8.decode(bytes, allowMalformed: false),
      'us-ascii' => ascii.decode(bytes, allowInvalid: false),
      'iso-8859-1' => latin1.decode(bytes, allowInvalid: false),
      'gbk' || 'gb2312' => gbk.decode(bytes),
      'big5' => big5.decode(bytes),
      _ => throw UnifiedHttpException(
        HttpFailureKind.decode,
        '暂不支持字符集 $charset',
      ),
    };
  }

  /// 统一字符集别名。
  String? _normalizeCharset(String? value) {
    if (value == null || value.trim().isEmpty) {
      return null;
    }
    /// 小写字符集。
    final String charset = value.trim().toLowerCase().replaceAll('_', '-');
    return switch (charset) {
      'utf8' => 'utf-8',
      'ascii' => 'us-ascii',
      'latin1' || 'latin-1' || 'iso8859-1' => 'iso-8859-1',
      'gb-2312' || 'gb_2312-80' => 'gb2312',
      'cp936' || 'ms936' => 'gbk',
      'big-5' || 'cp950' => 'big5',
      _ => charset,
    };
  }

  /// 移除 UTF-8 BOM 转换成的零宽字符。
  String _stripUtf8Bom(String text) {
    return text.startsWith('\uFEFF') ? text.substring(1) : text;
  }
}
