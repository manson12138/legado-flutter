import 'dart:convert';

import 'package:flutter/services.dart';

import '../../api/http/http_contract.dart';
import '../../api/http/response_decoder.dart';
import '../../domain/gateway/adult_content_gateway.dart';
import '../../domain/model/cache.dart';
import '../../help/error/app_error.dart';
import '../../help/logging/app_logger.dart';
import '../dao/cache_dao.dart';

/// 使用内置 assets 词库/域名表 + 通用缓存表实现成人内容屏蔽领域边界。
///
/// 对应 Android `help.AdultContentFilter` + `help.source.SourceHelp.list18Plus`：
/// 关键词库判定书名/作者/分类/简介/书源名称/分组/备注，域名黑名单额外判定书源地址。
/// 复用项目已有 `caches` 通用缓存表保存“是否屏蔽”开关和远程更新后的词库覆盖，
/// 不引入新的本地持久化依赖。
final class AdultContentRepository implements AdultContentGateway {
  /// 创建成人内容屏蔽 Repository。
  AdultContentRepository(
    this._cacheDao,
    this._assetBundle,
    this._httpClient,
    this._logger,
  );

  /// 通用缓存 DAO，只在数据层持有。
  final CacheDao _cacheDao;

  /// 启动期读取 Flutter assets 内置词库/域名表的资源入口。
  final AssetBundle _assetBundle;

  /// 更新远程词库使用的统一 HTTP 客户端。
  final UnifiedHttpClient _httpClient;

  /// 词库更新失败原因使用应用统一日志记录。
  final AppLogger _logger;

  /// 是否屏蔽成人内容的开关缓存键。
  static const String _enabledCacheKey = 'flutter_adult_content_blocking_enabled';

  /// 远程更新后落地的关键词覆盖缓存键。
  static const String _keywordOverrideCacheKey = 'flutter_adult_content_keywords_override';

  /// Flutter assets 中内置关键词库的稳定路径。
  static const String _keywordAssetPath = 'assets/default_data/adult_keywords.json';

  /// Flutter assets 中内置 Base64 域名黑名单的稳定路径。
  static const String _domainAssetPath = 'assets/default_data/adult_domains.txt';

  /// 与 Android 端共用的同一份远程词库地址。
  static const String _remoteKeywordUrl =
      'https://cdn.jsdelivr.net/gh/manson12138/legado-with-MD3@main/docs/adult_keywords.json';

  /// 成人书源分组标签中作为独立标签才判定命中的固定名称；短词不适合纳入关键词子串匹配，
  /// 否则会命中大量正常书源名称或简介。
  static const String _adultGroupTag = '成人';

  /// 内存态屏蔽开关缓存，避免搜索等高频路径反复读取数据库。
  bool? _enabledCache;

  /// 内存态关键词缓存。
  Set<String>? _keywordCache;

  /// 内存态域名黑名单缓存。
  Set<String>? _domainCache;

  @override
  Future<bool> isBlockingEnabled() async {
    if (_enabledCache != null) {
      return _enabledCache!;
    }
    /// 缓存表中保存的开关文本；不存在时按默认开启处理。
    final String? raw = (await _cacheDao.get(_enabledCacheKey))?.value;
    final bool enabled = raw == null || raw == 'true';
    _enabledCache = enabled;
    return enabled;
  }

  @override
  Future<void> setBlockingEnabled(bool enabled) async {
    await _cacheDao.upsert(
      Cache(key: _enabledCacheKey, value: enabled ? 'true' : 'false'),
    );
    _enabledCache = enabled;
  }

  @override
  Future<int> keywordCount() async => (await _keywords()).length;

  @override
  Future<bool> isAdultBook({
    required String name,
    String? author,
    String? kind,
    String? intro,
  }) async {
    if (!await isBlockingEnabled()) {
      return false;
    }
    /// 当前生效关键词库。
    final Set<String> keywords = await _keywords();
    return _hit(name, keywords) ||
        _hit(author, keywords) ||
        _hit(kind, keywords) ||
        _hit(intro, keywords);
  }

  @override
  Future<bool> isAdultSource({
    required String name,
    String? group,
    String? comment,
    String? url,
  }) async {
    if (!await isBlockingEnabled()) {
      return false;
    }
    if (_hasAdultGroupTag(group)) {
      return true;
    }
    /// 当前生效关键词库。
    final Set<String> keywords = await _keywords();
    if (_hit(name, keywords) || _hit(group, keywords) || _hit(comment, keywords)) {
      return true;
    }
    return _isAdultDomain(url, await _domains());
  }

  @override
  Future<int> updateFromRemote() async {
    try {
      /// 远程词库原始响应。
      final HttpResponse response = await _httpClient.execute(
        HttpRequest(uri: Uri.parse(_remoteKeywordUrl)),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw UnifiedHttpException(
          HttpFailureKind.httpStatus,
          '词库更新响应异常',
          statusCode: response.statusCode,
        );
      }
      /// 按响应字符集解码后的词库 JSON 文本。
      final String body = const HttpResponseDecoder().decode(response).text;
      /// 解码校验通过的关键词列表。
      final List<String> list = _decodeKeywordList(body);
      if (list.isEmpty) {
        throw const FormatException('远程词库为空或格式无效');
      }
      await _cacheDao.upsert(Cache(key: _keywordOverrideCacheKey, value: body));
      _keywordCache = list.toSet();
      _logger.info(message: '成人内容词库更新成功 count=${list.length}');
      return list.length;
    } catch (error, stackTrace) {
      _logger.error(
        message: '成人内容词库更新失败',
        error: error,
        stackTrace: stackTrace,
      );
      if (error is AppError) {
        rethrow;
      }
      throw AppError(
        kind: error is FormatException
            ? AppErrorKind.validation
            : AppErrorKind.infrastructure,
        message: '词库更新失败',
        cause: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// 读取当前生效关键词库；优先使用远程更新覆盖，否则回退内置 assets。
  Future<Set<String>> _keywords() async {
    if (_keywordCache != null) {
      return _keywordCache!;
    }
    try {
      /// 缓存表中保存的远程更新覆盖 JSON 文本。
      final String? override = (await _cacheDao.get(_keywordOverrideCacheKey))?.value;
      /// 最终使用的关键词 JSON 文本来源。
      final String json = override ?? await _assetBundle.loadString(_keywordAssetPath);
      final Set<String> keywords = _decodeKeywordList(json).toSet();
      _keywordCache = keywords;
      return keywords;
    } catch (error, stackTrace) {
      _logger.error(message: '成人内容关键词库加载失败', error: error, stackTrace: stackTrace);
      _keywordCache = const <String>{};
      return const <String>{};
    }
  }

  /// 读取内置 Base64 编码域名黑名单；解码失败的单行会被跳过，不影响其余判定。
  Future<Set<String>> _domains() async {
    if (_domainCache != null) {
      return _domainCache!;
    }
    try {
      /// 内置域名黑名单原始文本，每行一个 Base64 编码域名。
      final String raw = await _assetBundle.loadString(_domainAssetPath);
      final Set<String> domains = <String>{};
      for (final String line in raw.split('\n')) {
        /// 去除换行和空白后的单行 Base64 文本。
        final String trimmed = line.trim();
        if (trimmed.isEmpty) {
          continue;
        }
        try {
          domains.add(utf8.decode(base64.decode(trimmed)));
        } on FormatException {
          continue;
        }
      }
      _domainCache = domains;
      return domains;
    } catch (error, stackTrace) {
      _logger.error(message: '成人内容域名黑名单加载失败', error: error, stackTrace: stackTrace);
      _domainCache = const <String>{};
      return const <String>{};
    }
  }

  /// 解析不可信关键词 JSON 数组；格式无效时返回空列表而不是抛出异常。
  List<String> _decodeKeywordList(String json) {
    try {
      /// 未经信任的 JSON 值。
      final Object? decoded = jsonDecode(json);
      if (decoded is! List<Object?>) {
        return const <String>[];
      }
      return decoded
          .whereType<String>()
          .map((String value) => value.trim())
          .where((String value) => value.isNotEmpty)
          .toList(growable: false);
    } on FormatException {
      return const <String>[];
    }
  }

  /// 判断文本是否命中任意关键词，忽略大小写。
  bool _hit(String? text, Set<String> keywords) {
    if (text == null || text.trim().isEmpty || keywords.isEmpty) {
      return false;
    }
    /// 转小写后的待判定文本。
    final String lower = text.toLowerCase();
    return keywords.any((String keyword) => lower.contains(keyword.toLowerCase()));
  }

  /// 分组文本按分隔符拆分后是否包含独立的“成人”标签；短标签不适合走关键词子串匹配。
  bool _hasAdultGroupTag(String? group) {
    if (group == null || group.trim().isEmpty) {
      return false;
    }
    return group
        .split(RegExp('[,;，；]'))
        .map((String value) => value.trim())
        .contains(_adultGroupTag);
  }

  /// 判断书源地址主机名是否命中域名黑名单，兼容 `m.xxx.com` 等子域名。
  bool _isAdultDomain(String? url, Set<String> domains) {
    if (url == null || url.trim().isEmpty || domains.isEmpty) {
      return false;
    }
    /// 解析后的书源地址主机名，解析失败时视为未命中。
    final String? host = Uri.tryParse(url.trim())?.host;
    if (host == null || host.isEmpty) {
      return false;
    }
    if (domains.contains(host)) {
      return true;
    }
    /// 主机名按点号拆分后的最后两段，用于兼容未单独收录的子域名。
    final List<String> parts = host.split('.');
    if (parts.length < 2) {
      return false;
    }
    final String baseDomain = '${parts[parts.length - 2]}.${parts[parts.length - 1]}';
    return domains.contains(baseDomain);
  }
}
