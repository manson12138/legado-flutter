import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:sqflite/sqflite.dart';

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
    this._logger, {
    required void Function() notifySourceVisibilityChanged,
  }) : _notifySourceVisibilityChanged = notifySourceVisibilityChanged;

  /// 通用缓存 DAO，只在数据层持有。
  final CacheDao _cacheDao;

  /// 启动期读取 Flutter assets 内置词库/域名表的资源入口。
  final AssetBundle _assetBundle;

  /// 更新远程词库使用的统一 HTTP 客户端。
  final UnifiedHttpClient _httpClient;

  /// 词库更新失败原因使用应用统一日志记录。
  final AppLogger _logger;

  /// 通知书源观察链重新计算可见性，不改变数据库中的书源数据。
  final void Function() _notifySourceVisibilityChanged;

  /// 屏蔽规则成功变化后的应用级广播流。
  final StreamController<int> _ruleChangesController =
      StreamController<int>.broadcast(sync: true);

  /// 屏蔽规则的应用进程内单调修订号。
  int _ruleRevision = 0;

  /// 是否屏蔽成人内容的开关缓存键。
  static const String _enabledCacheKey = 'flutter_adult_content_blocking_enabled';

  /// 远程更新后落地的关键词覆盖缓存键。
  static const String _keywordOverrideCacheKey = 'flutter_adult_content_keywords_override';

  /// 远端管理平台下发的域名黑名单覆盖层缓存键。
  static const String _domainOverrideCacheKey = 'flutter_adult_content_domains_override';

  /// Flutter assets 中内置 Base64 关键词库的稳定路径。
  static const String _keywordAssetPath = 'assets/default_data/adult_keywords.txt';

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
  Stream<int> get ruleChanges => _ruleChangesController.stream;

  @override
  Future<bool> isBlockingEnabled({DatabaseExecutor? executor}) async {
    /// 已经读取过的开关值。
    final bool? cached = _enabledCache;
    if (cached != null) {
      return cached;
    }
    /// 缓存表中保存的开关文本；不存在时按默认开启处理。
    final String? raw =
        (await _cacheDao.get(_enabledCacheKey, executor: executor))?.value;
    final bool enabled = raw == null || raw == 'true';
    _enabledCache = enabled;
    return enabled;
  }

  @override
  Future<void> setBlockingEnabled(bool enabled) async {
    /// 写入前的生效值，用于避免重复切换产生无意义刷新。
    final bool previous = await isBlockingEnabled();
    if (previous == enabled) {
      return;
    }
    await _cacheDao.upsert(
      Cache(key: _enabledCacheKey, value: enabled ? 'true' : 'false'),
    );
    _enabledCache = enabled;
    _publishRulesChanged();
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
    DatabaseExecutor? executor,
  }) async {
    if (!await isBlockingEnabled(executor: executor)) {
      return false;
    }
    if (_hasAdultGroupTag(group)) {
      return true;
    }
    /// 当前生效关键词库。
    final Set<String> keywords = await _keywords(executor: executor);
    if (_hit(name, keywords) || _hit(group, keywords) || _hit(comment, keywords)) {
      return true;
    }
    return _isAdultDomain(url, await _domains(executor: executor));
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
      /// 更新前最终生效的本地基线与远程扩展集合。
      final Set<String> previous = await _keywords();
      await _cacheDao.upsert(Cache(key: _keywordOverrideCacheKey, value: body));
      _keywordCache = null;
      /// 更新后最终生效的合并关键词集合。
      final Set<String> effective = await _keywords();
      if (!_sameSet(previous, effective)) {
        _publishRulesChanged();
      }
      _logger.info(message: '成人内容词库更新成功 count=${effective.length}');
      return effective.length;
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

  @override
  Future<void> replaceRemoteRules({
    required Set<String> keywords,
    required Set<String> domains,
  }) async {
    /// 替换前最终生效的关键词集合。
    final Set<String> previousKeywords = await _keywords();
    /// 替换前最终生效的域名集合。
    final Set<String> previousDomains = await _domains();
    final List<String> normalizedKeywords = keywords
        .map((String value) => value.trim())
        .where((String value) => value.isNotEmpty)
        .toList(growable: false);
    final List<String> normalizedDomains = domains
        .map((String value) => value.trim().toLowerCase())
        .where((String value) => value.isNotEmpty)
        .toList(growable: false);
    await _cacheDao.upsert(Cache(key: _keywordOverrideCacheKey, value: jsonEncode(normalizedKeywords)));
    await _cacheDao.upsert(Cache(key: _domainOverrideCacheKey, value: jsonEncode(normalizedDomains)));
    _keywordCache = null;
    _domainCache = null;
    /// 替换后最终生效的本地基线与远程扩展关键词。
    final Set<String> effectiveKeywords = await _keywords();
    /// 替换后最终生效的域名规则。
    final Set<String> effectiveDomains = await _domains();
    if (!_sameSet(previousKeywords, effectiveKeywords) ||
        !_sameSet(previousDomains, effectiveDomains)) {
      _publishRulesChanged();
    }
  }

  /// 读取当前生效关键词库；内置 Base64 词库是最低基线，远程规则只做并集扩展。
  /// [executor] 用于在调用方已开启的事务内查询，避免另开主连接查询导致自锁。
  Future<Set<String>> _keywords({DatabaseExecutor? executor}) async {
    /// 已经解码并合并的关键词缓存。
    final Set<String>? cached = _keywordCache;
    if (cached != null) {
      return cached;
    }
    try {
      /// 缓存表中保存的远程更新覆盖 JSON 文本。
      final String? override =
          (await _cacheDao.get(_keywordOverrideCacheKey, executor: executor))?.value;
      /// 内置最低屏蔽基线，远程规则不得移除用户明确要求的本地词。
      final Set<String> keywords =
          _decodeBase64Lines(await _assetBundle.loadString(_keywordAssetPath));
      if (override != null) {
        keywords.addAll(_decodeKeywordList(override));
      }
      _keywordCache = keywords;
      return keywords;
    } catch (error, stackTrace) {
      _logger.error(message: '成人内容关键词库加载失败', error: error, stackTrace: stackTrace);
      _keywordCache = const <String>{};
      return const <String>{};
    }
  }

  /// 读取内置 Base64 编码域名黑名单；解码失败的单行会被跳过，不影响其余判定。
  Future<Set<String>> _domains({DatabaseExecutor? executor}) async {
    /// 已经解码的域名规则缓存。
    final Set<String>? cached = _domainCache;
    if (cached != null) {
      return cached;
    }
    try {
      /// 远端覆盖规则优先于内置 Base64 域名黑名单。
      final String? override =
          (await _cacheDao.get(_domainOverrideCacheKey, executor: executor))?.value;
      final Set<String> domains = override == null
          ? _decodeBase64Lines(await _assetBundle.loadString(_domainAssetPath))
          : _decodeKeywordList(override).map((String value) => value.toLowerCase()).toSet();
      _domainCache = domains;
      return domains;
    } catch (error, stackTrace) {
      _logger.error(message: '成人内容域名黑名单加载失败', error: error, stackTrace: stackTrace);
      _domainCache = const <String>{};
      return const <String>{};
    }
  }

  /// 解析每行一个 Base64 编码值的内置文本；解码失败的单行会被跳过，不影响其余判定。
  Set<String> _decodeBase64Lines(String raw) {
    /// 解码成功的值集合。
    final Set<String> values = <String>{};
    for (final String line in raw.split('\n')) {
      /// 去除换行和空白后的单行 Base64 文本。
      final String trimmed = line.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      try {
        values.add(utf8.decode(base64.decode(trimmed)));
      } on FormatException {
        continue;
      }
    }
    return values;
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

  /// 判断两个无序规则集合是否完全一致，避免无变化更新触发页面重载。
  bool _sameSet(Set<String> left, Set<String> right) {
    return left.length == right.length && left.containsAll(right);
  }

  /// 发布规则修订并让书源观察链重新计算可见性。
  void _publishRulesChanged() {
    _ruleRevision += 1;
    _notifySourceVisibilityChanged();
    if (!_ruleChangesController.isClosed) {
      _ruleChangesController.add(_ruleRevision);
    }
  }

  @override
  Future<void> dispose() async {
    await _ruleChangesController.close();
  }
}
