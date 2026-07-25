import '../data/dao/cache_dao.dart';
import '../domain/model/cache.dart';

/// 持久化搜索页面的轻量展示偏好，不保存搜索词、书源或结果内容。
final class SearchPreferences {
  /// 创建复用通用缓存表的搜索偏好服务。
  const SearchPreferences(this._cacheDao);

  /// 通用缓存 DAO，仅保存稳定的枚举名称。
  final CacheDao _cacheDao;

  /// 搜索结果匹配方式的稳定缓存键。
  static const String _matchModeCacheKey = 'search_match_mode';

  /// 读取上次保存的匹配方式名称；无记录时返回空值供调用方使用默认值。
  Future<String?> readMatchModeName() async {
    return (await _cacheDao.get(_matchModeCacheKey))?.value;
  }

  /// 保存用户当前选择的匹配方式名称。
  Future<void> saveMatchModeName(String matchModeName) {
    return _cacheDao.upsert(Cache(key: _matchModeCacheKey, value: matchModeName));
  }
}
