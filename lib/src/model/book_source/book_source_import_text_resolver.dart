import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path_util;
import 'package:path_provider/path_provider.dart';

import '../../api/http/http_contract.dart';
import '../../api/http/response_decoder.dart';
import '../../help/logging/app_logger.dart';

/// 将扫码得到的书源 JSON 或远程书源地址统一解析为待确认文本。
///
/// 此服务只负责读取和解码，不解析书源字段、更不会写入数据库；最终内容仍需经过书源导入
/// 对话框确认和既有书源导入用例校验。
final class BookSourceImportTextResolver {
  /// 创建书源导入文本解析器。
  const BookSourceImportTextResolver({
    required UnifiedHttpClient httpClient,
    required HttpResponseDecoder responseDecoder,
    required AppLogger logger,
  }) : _httpClient = httpClient,
       _responseDecoder = responseDecoder,
       _logger = logger;

  /// 远程书源列表允许的最大原始响应字节数。
  static const int _maximumResponseBytes = 5 * 1024 * 1024;

  /// 【扫码诊断文件】应用沙盒中保存最新扫码数据的目录名。
  static const String _diagnosticDirectoryName = 'book_source_qr_diagnostics';

  /// 【扫码诊断文件】保存最新二维码原始文本的固定文件名。
  static const String _scannedPayloadFileName = 'latest_scanned_payload.txt';

  /// 统一 HTTP 客户端，确保扫码导入复用超时、重定向和错误分类。
  final UnifiedHttpClient _httpClient;

  /// 集中处理 UTF-8、GBK、压缩响应和服务端字符集声明的解码器。
  final HttpResponseDecoder _responseDecoder;

  /// 【扫码诊断日志】不输出二维码原文、URL、Header 或 Cookie 的日志边界。
  final AppLogger _logger;

  /// 返回可交给书源导入对话框预览的 JSON 文本。
  ///
  /// 普通文本原样返回；绝对 HTTP/HTTPS 地址会先下载。其他协议不执行，避免二维码触发
  /// 本地文件、应用深链或平台私有协议。
  Future<String> resolve(
    String scannedText, {
    HttpCancellationToken? cancellationToken,
  }) async {
    /// 去除二维码外围空白后的候选内容。
    final String candidate = scannedText.trim();
    // 【扫码诊断日志】只记录输入长度，不记录二维码正文。
    _logger.debug(
      message: '$bookSourceQrScanLogTag stage=resolver_started chars=${candidate.length}',
    );
    if (candidate.isEmpty) {
      _logger.warning(message: '$bookSourceQrScanLogTag stage=resolver_rejected reason=empty');
      throw const FormatException('二维码中没有可导入的书源内容');
    }

    // 【扫码诊断文件】保存最新二维码原文并在统一 Tag 中显示沙盒绝对路径。
    await _saveDiagnosticBytes(
      kind: 'scanned_payload',
      fileName: _scannedPayloadFileName,
      bytes: utf8.encode(candidate),
    );

    /// 原生书源分享二维码可能使用的 `sourceUrls` 聚合对象。
    final List<String>? sourceUrls = _readSourceUrls(candidate);
    if (sourceUrls != null) {
      _logger.info(
        message:
            '$bookSourceQrScanLogTag stage=content_classified type=source_urls count=${sourceUrls.length}',
      );
      return _resolveSourceUrls(
        sourceUrls,
        cancellationToken: cancellationToken,
      );
    }

    /// 二维码可能包含的绝对地址；无法解析时按普通 JSON 文本继续预览。
    final Uri? uri = Uri.tryParse(candidate);
    if (uri == null || !uri.hasScheme) {
      _logger.info(
        message: '$bookSourceQrScanLogTag stage=content_classified type=inline_json',
      );
      return candidate;
    }

    _logger.info(
      message: '$bookSourceQrScanLogTag stage=content_classified type=remote_url',
    );
    return _downloadSourceText(uri, cancellationToken: cancellationToken);
  }

  /// 读取原生兼容的 `sourceUrls` 聚合对象；普通书源对象返回 null。
  List<String>? _readSourceUrls(String candidate) {
    /// 尝试解码后的二维码 JSON 根值；普通 URL 或文本不在此方法处理。
    final Object? decoded;
    try {
      decoded = jsonDecode(candidate);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<Object?, Object?> || !decoded.containsKey('sourceUrls')) {
      return null;
    }
    /// 聚合对象中的远程书源地址列表。
    final Object? rawSourceUrls = decoded['sourceUrls'];
    if (rawSourceUrls is! List<Object?> || rawSourceUrls.isEmpty) {
      throw const FormatException('sourceUrls 必须是非空地址数组');
    }
    /// 完成字符串和非空校验的远程地址列表。
    final List<String> sourceUrls = <String>[];
    for (final Object? value in rawSourceUrls) {
      if (value is! String || value.trim().isEmpty) {
        throw const FormatException('sourceUrls 只能包含非空地址');
      }
      sourceUrls.add(value.trim());
    }
    return sourceUrls;
  }

  /// 依次下载聚合二维码中的书源数组，并合并成既有导入对话框可识别的 JSON 数组。
  Future<String> _resolveSourceUrls(
    List<String> sourceUrls, {
    HttpCancellationToken? cancellationToken,
  }) async {
    /// 所有远程列表合并后的不可信书源 JSON 值。
    final List<Object?> combinedSources = <Object?>[];
    for (int index = 0; index < sourceUrls.length; index += 1) {
      /// 当前聚合地址在列表中的安全索引。
      final int displayIndex = index + 1;
      /// 当前聚合地址文本；仅用于解析，不写入日志。
      final String sourceUrl = sourceUrls[index];
      _logger.debug(
        message:
            '$bookSourceQrScanLogTag stage=aggregate_item_started index=$displayIndex total=${sourceUrls.length}',
      );
      /// 当前聚合地址的 URI 解析结果。
      final Uri? uri = Uri.tryParse(sourceUrl);
      if (uri == null || !uri.hasScheme) {
        throw const FormatException('sourceUrls 包含无效地址');
      }
      /// 当前远程地址下载并解码后的 JSON 文本。
      final String remoteText = await _downloadSourceText(
        uri,
        cancellationToken: cancellationToken,
      );
      /// 原生远程书源地址要求返回书源数组。
      final Object? remoteRoot = jsonDecode(remoteText);
      if (remoteRoot is! List<Object?>) {
        _logger.warning(
          message:
              '$bookSourceQrScanLogTag stage=aggregate_item_rejected index=$displayIndex reason=not_array',
        );
        throw const FormatException('sourceUrls 指向的远程内容必须是书源数组');
      }
      combinedSources.addAll(remoteRoot);
      _logger.debug(
        message:
            '$bookSourceQrScanLogTag stage=aggregate_item_finished index=$displayIndex items=${remoteRoot.length}',
      );
    }
    if (combinedSources.isEmpty) {
      _logger.warning(
        message: '$bookSourceQrScanLogTag stage=aggregate_finished reason=no_items',
      );
      throw const FormatException('sourceUrls 没有解析到可导入书源');
    }
    _logger.info(
      message:
          '$bookSourceQrScanLogTag stage=aggregate_finished items=${combinedSources.length}',
    );
    return jsonEncode(combinedSources);
  }

  /// 下载一个 HTTP/HTTPS 书源地址，并按响应声明完成解压和字符集解码。
  Future<String> _downloadSourceText(
    Uri uri, {
    HttpCancellationToken? cancellationToken,
  }) async {
    /// 小写协议名，用于阻止 file、content、intent 等非网络协议。
    final String scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      _logger.warning(
        message:
            '$bookSourceQrScanLogTag stage=http_rejected reason=unsupported_scheme scheme=$scheme',
      );
      throw const FormatException('二维码书源地址只支持 HTTP 或 HTTPS');
    }
    if (uri.host.trim().isEmpty) {
      _logger.warning(
        message: '$bookSourceQrScanLogTag stage=http_rejected reason=empty_host',
      );
      throw const FormatException('二维码中的书源地址无效');
    }
    /// 是否启用原生书源地址约定的无默认 UA 请求模式。
    final bool requestWithoutUserAgent = uri.fragment == 'requestWithoutUA';
    /// 移除只供客户端识别、不应发送给服务器的控制片段后的请求地址。
    final Uri requestUri = requestWithoutUserAgent ? uri.replace(fragment: '') : uri;
    // 【扫码诊断日志】不记录 host、完整 URL 或请求 Header。
    _logger.debug(
      message:
          '$bookSourceQrScanLogTag stage=http_started scheme=$scheme withoutUa=$requestWithoutUserAgent '
          'connectTimeoutMs=15000 receiveTimeoutMs=30000 totalTimeoutMs=30000 '
          'followRedirects=true maxRedirects=10 cookieMode=disabled',
    );
    /// 禁用 Cookie 的远程书源列表请求，避免向二维码目标泄漏应用会话。
    final HttpResponse response = await _httpClient.execute(
      HttpRequest(
        uri: requestUri,
        headers: requestWithoutUserAgent
            ? const <String, String>{'User-Agent': 'null'}
            : const <String, String>{},
        cookieMode: HttpCookieMode.disabled,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
        totalTimeout: const Duration(seconds: 30),
        // 【扫码诊断日志】让 Dio 全链路日志归入扫码书源统一 Tag。
        logContext: bookSourceQrScanLogTag,
      ),
      cancellationToken: cancellationToken,
    );
    if (response.bytes.length > _maximumResponseBytes) {
      _logger.warning(
        message:
            '$bookSourceQrScanLogTag stage=http_rejected status=${response.statusCode} bytes=${response.bytes.length} reason=too_large',
      );
      throw const FormatException('远程书源内容超过 5 MiB，已停止导入');
    }

    /// 【扫码诊断文件】根据响应媒体类型选择便于直接查看的文件扩展名。
    final String responseFileName = _diagnosticResponseFileName(response);
    // 【扫码诊断文件】在任何业务解码前保存 Dio 返回的响应字节，便于确认实际内容。
    await _saveDiagnosticBytes(
      kind: 'http_response',
      fileName: responseFileName,
      bytes: response.bytes,
    );

    /// 按响应字符集和压缩格式解码后的书源文本。
    final DecodedHttpResponse decodedResponse = _responseDecoder.decode(response);
    /// 去除远程响应外围空白后的书源文本。
    final String resolvedText = decodedResponse.text.trim();
    _logger.debug(
      message:
          '$bookSourceQrScanLogTag stage=http_finished status=${response.statusCode} bytes=${response.bytes.length} charset=${decodedResponse.charset} chars=${resolvedText.length}',
    );
    if (resolvedText.isEmpty) {
      _logger.warning(
        message: '$bookSourceQrScanLogTag stage=http_rejected reason=empty_response',
      );
      throw const FormatException('远程书源内容为空');
    }
    return resolvedText;
  }

  /// 【扫码诊断文件】根据 Content-Type 返回最新远程响应使用的固定文件名。
  String _diagnosticResponseFileName(HttpResponse response) {
    /// 【扫码诊断文件】服务端返回的小写媒体类型。
    final String contentType = (response.firstHeader('content-type') ?? '')
        .toLowerCase();
    if (contentType.contains('html')) {
      return 'latest_http_response.html';
    }
    if (contentType.contains('json')) {
      return 'latest_http_response.json';
    }
    if (contentType.startsWith('text/')) {
      return 'latest_http_response.txt';
    }
    return 'latest_http_response.bin';
  }

  /// 【扫码诊断文件】保存最新诊断数据并输出沙盒绝对路径；失败不影响扫码导入。
  Future<void> _saveDiagnosticBytes({
    required String kind,
    required String fileName,
    required List<int> bytes,
  }) async {
    try {
      /// 【扫码诊断文件】应用私有支持目录，不需要申请外部存储权限。
      final Directory supportDirectory = await getApplicationSupportDirectory();
      /// 【扫码诊断文件】扫码书源诊断文件的独立沙盒目录。
      final Directory diagnosticDirectory = Directory(
        path_util.join(supportDirectory.path, _diagnosticDirectoryName),
      );
      if (!await diagnosticDirectory.exists()) {
        await diagnosticDirectory.create(recursive: true);
      }
      /// 【扫码诊断文件】本次覆盖写入的最新诊断文件。
      final File diagnosticFile = File(
        path_util.join(diagnosticDirectory.path, fileName),
      );
      await diagnosticFile.writeAsBytes(bytes, flush: true);
      _logger.info(
        message:
            '$bookSourceQrScanLogTag stage=diagnostic_file_saved kind=$kind '
            'bytes=${bytes.length} path=${diagnosticFile.path}',
      );
    } catch (error, stackTrace) {
      // 【扫码诊断文件】诊断文件写入失败只能记录，不能改变正常添加书源逻辑。
      _logger.error(
        message: '$bookSourceQrScanLogTag stage=diagnostic_file_save_failed kind=$kind',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
}
