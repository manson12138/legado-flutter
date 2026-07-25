import 'dart:convert';

import '../../api/remote_app/remote_app_api.dart';
import '../../api/remote_app/remote_app_service_config.dart';
import '../../domain/model/cache.dart';
import '../dao/cache_dao.dart';

/// 缓存远端启动配置并提供过滤规则的仓储。
final class RemoteAppConfigurationRepository {
  /// 创建远端配置仓储。
  RemoteAppConfigurationRepository(this._api, this._cacheDao, this._config);

  /// 已签名的 API。
  final RemoteAppApi _api;
  /// 通用缓存 DAO。
  final CacheDao _cacheDao;
  /// 当前安装包的产品、版本和渠道身份，用于隔离不同版本的准入缓存。
  final RemoteAppServiceConfig _config;
  /// 最近成功启动聚合响应的缓存键。
  static const String bootstrapCacheKey = 'remote_app_bootstrap_v1';
  /// 已确认准入和升级状态的持久化缓存键。
  static const String appAccessStatusCacheKey =
      'remote_app_access_status_v1';

  /// 公告缓存键。
  static const String announcementsCacheKey = 'remote_app_announcements_v1';
  /// 功能开关缓存键。
  static const String featureFlagsCacheKey = 'remote_app_feature_flags_v1';
  /// 已读公告标识集合的缓存键。
  static const String readAnnouncementIdsCacheKey = 'remote_app_read_announcement_ids_v1';

  /// 拉取并缓存启动配置。
  Future<Map<String, Object?>> refreshBootstrap() async {
    final Map<String, Object?> value = await _api.fetchBootstrap();
    await _cacheDao.upsert(Cache(key: bootstrapCacheKey, value: jsonEncode(value)));
    await _cacheRuntimePayloads(value);
    return value;
  }

  /// 获取、持久化服务端准入和升级状态；状态字段由 API 层校验，避免传递动态 Map。
  Future<RemoteAppBootstrapStatus> refreshBootstrapStatus() async {
    final RemoteAppBootstrapStatus status = await _api.fetchBootstrapStatus();
    await _cacheDao.upsert(
      Cache(key: appAccessStatusCacheKey, value: _encodeAccessStatus(status)),
    );
    return status;
  }

  /// 读取仅适用于当前安装包身份的已确认准入和升级状态。
  ///
  /// 缓存损坏或来自其他版本时删除该记录，防止旧版本的阻断错误影响新安装包。
  Future<RemoteAppBootstrapStatus?> loadCachedBootstrapStatus() async {
    final String? raw =
        (await _cacheDao.get(appAccessStatusCacheKey))?.value;
    if (raw == null) {
      return null;
    }
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map<Object?, Object?> || !_matchesCurrentApp(decoded)) {
        await _cacheDao.delete(appAccessStatusCacheKey);
        return null;
      }
      final Object? statusValue = decoded['status'];
      if (statusValue is! Map<Object?, Object?>) {
        await _cacheDao.delete(appAccessStatusCacheKey);
        return null;
      }
      final Object? allowed = statusValue['allowed'];
      final Object? hasUpdate = statusValue['hasUpdate'];
      final Object? forceUpdate = statusValue['forceUpdate'];
      if (allowed is! bool || hasUpdate is! bool || forceUpdate is! bool) {
        await _cacheDao.delete(appAccessStatusCacheKey);
        return null;
      }
      return RemoteAppBootstrapStatus(
        allowed: allowed,
        hasUpdate: hasUpdate,
        forceUpdate: forceUpdate,
        accessMessage: _readOptionalString(statusValue, 'accessMessage'),
        versionName: _readOptionalString(statusValue, 'versionName'),
        latestVersionCode: _readOptionalInt(statusValue, 'latestVersionCode'),
        downloadUrl: _readOptionalString(statusValue, 'downloadUrl'),
        changelog: _readOptionalString(statusValue, 'changelog'),
      );
    } on FormatException {
      await _cacheDao.delete(appAccessStatusCacheKey);
      return null;
    }
  }

  /// 判断缓存记录是否属于当前产品、版本、构建号和渠道。
  bool _matchesCurrentApp(Map<Object?, Object?> value) {
    final Object? versionCode = value['appVersionCode'];
    return value['productId'] == _config.productId &&
        value['appVersionName'] == _config.appVersionName &&
        versionCode is num &&
        versionCode.toInt() == _config.appVersionCode &&
        value['channel'] == _config.channel;
  }

  /// 为已确认状态创建包含当前安装包身份的小型 JSON 缓存记录。
  String _encodeAccessStatus(RemoteAppBootstrapStatus status) => jsonEncode(
        <String, Object?>{
          'productId': _config.productId,
          'appVersionName': _config.appVersionName,
          'appVersionCode': _config.appVersionCode,
          'channel': _config.channel,
          'checkedAt': DateTime.now().toUtc().millisecondsSinceEpoch,
          'status': <String, Object?>{
            'allowed': status.allowed,
            'hasUpdate': status.hasUpdate,
            'forceUpdate': status.forceUpdate,
            'accessMessage': status.accessMessage,
            'versionName': status.versionName,
            'latestVersionCode': status.latestVersionCode,
            'downloadUrl': status.downloadUrl,
            'changelog': status.changelog,
          },
        },
      );

  /// 从不可信缓存对象读取可空字符串字段。
  String? _readOptionalString(Map<Object?, Object?> value, String key) {
    final Object? item = value[key];
    return item is String ? item : null;
  }

  /// 从不可信缓存对象读取可空整数字段。
  int? _readOptionalInt(Map<Object?, Object?> value, String key) {
    final Object? item = value[key];
    return item is num ? item.toInt() : null;
  }

  /// 拉取关键字规则。
  Future<Map<String, Object?>> refreshKeywords() => _api.fetchKeywords();
  /// 拉取域名规则。
  Future<Map<String, Object?>> refreshDomains() => _api.fetchDomains();

  /// 单独刷新公告并覆盖缓存，供后续页面按需调用。
  Future<List<Object?>> refreshAnnouncements() async {
    final List<Object?> value = await _api.fetchAnnouncements();
    await _cacheDao.upsert(Cache(key: announcementsCacheKey, value: jsonEncode(value)));
    return value;
  }

  /// 单独刷新功能开关并覆盖缓存，供具体 Feature 按 key 读取。
  Future<List<Object?>> refreshFeatureFlags() async {
    final List<Object?> value = await _api.fetchFeatureFlags();
    await _cacheDao.upsert(Cache(key: featureFlagsCacheKey, value: jsonEncode(value)));
    return value;
  }

  /// 从 bootstrap 聚合结果中持久化公告和开关，避免为同一次启动重复请求。
  Future<void> _cacheRuntimePayloads(Map<String, Object?> bootstrap) async {
    final Object? announcements = bootstrap['announcements'];
    final Object? flags = bootstrap['flags'];
    if (announcements is List<Object?>) {
      await _cacheDao.upsert(Cache(key: announcementsCacheKey, value: jsonEncode(announcements)));
    }
    if (flags is List<Object?>) {
      await _cacheDao.upsert(Cache(key: featureFlagsCacheKey, value: jsonEncode(flags)));
    }
  }

  /// 优先刷新公告，失败时回退到最近一次缓存，并返回尚未标记已读的公告对象。
  Future<List<Map<String, Object?>>> loadUnreadAnnouncements() async {
    List<Object?> values;
    try { values = await refreshAnnouncements(); } catch (_) { values = await _readCachedList(announcementsCacheKey); }
    final Set<String> readIds = await _readStringSet(readAnnouncementIdsCacheKey);
    return values.whereType<Map<Object?, Object?>>().map((Map<Object?, Object?> item) => item.map<String, Object?>((Object? key, Object? value) => key is String ? MapEntry<String, Object?>(key, value) : throw const FormatException('公告字段无效'))).where((Map<String, Object?> item) => item['id'] != null && !readIds.contains('${item['id']}')).toList(growable: false);
  }

  /// 将用户已关闭的公告标记为已读，避免同一公告在后续启动重复打扰。
  Future<void> markAnnouncementRead(Object id) async {
    final Set<String> ids = await _readStringSet(readAnnouncementIdsCacheKey);
    ids.add('$id');
    await _cacheDao.upsert(Cache(key: readAnnouncementIdsCacheKey, value: jsonEncode(ids.toList(growable: false))));
  }

  /// 从缓存读取 JSON 列表；缓存不存在或损坏时返回空列表。
  Future<List<Object?>> _readCachedList(String key) async {
    final String? raw = (await _cacheDao.get(key))?.value;
    if (raw == null) { return <Object?>[]; }
    try { final Object? decoded = jsonDecode(raw); return decoded is List<Object?> ? decoded : <Object?>[]; } on FormatException { return <Object?>[]; }
  }

  /// 从缓存读取字符串集合；缓存不存在或损坏时返回空集合。
  Future<Set<String>> _readStringSet(String key) async {
    final List<Object?> values = await _readCachedList(key);
    return values.whereType<String>().toSet();
  }
}
