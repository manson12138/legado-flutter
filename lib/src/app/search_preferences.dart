import '../data/dao/cache_dao.dart';
import '../data/local/preferences/app_preferences_store.dart';
import '../data/local/preferences/versioned_app_preference_migrator.dart';

/// 使用 MMKV 持久化搜索匹配方式，并兼容迁移旧 SQLite 值。
final class SearchPreferences {
  /// 创建搜索偏好服务。
  SearchPreferences(
    this._preferencesStore,
    this._legacyCacheDao,
  ) : _migrator = VersionedAppPreferenceMigrator(_preferencesStore);

  /// MMKV 或其进程内降级实现。
  final AppPreferencesStore _preferencesStore;

  /// 只在首次迁移时读取旧值的 SQLite 缓存 DAO。
  final CacheDao _legacyCacheDao;

  /// 搜索匹配方式逐键迁移器。
  final VersionedAppPreferenceMigrator _migrator;

  /// 搜索匹配方式的新 MMKV 键。
  static const String _matchModeKey = 'search.match_mode.v1';

  /// 搜索匹配方式迁移版本键。
  static const String _matchModeMigrationKey =
      'migration.search.match_mode.v1';

  /// 搜索匹配方式的旧 SQLite 键。
  static const String _legacyMatchModeKey = 'search_match_mode';

  /// 读取上次保存的匹配方式名称；无记录时返回空值供调用方使用默认值。
  Future<String?> readMatchModeName() async {
    final AppPreferenceMigrationResult<String> result =
        await _migrator.migrate<String>(
      valueKey: _matchModeKey,
      migrationVersionKey: _matchModeMigrationKey,
      targetVersion: 1,
      readCurrentValue: () =>
          _validMatchMode(_preferencesStore.readString(_matchModeKey)),
      writeCurrentValue: (String value) =>
          _preferencesStore.writeString(_matchModeKey, value),
      readLegacyValue: () async =>
          (await _legacyCacheDao.get(_legacyMatchModeKey))?.value,
      decodeLegacyValue: _validMatchMode,
    );
    return result.value;
  }

  /// 保存用户当前选择的匹配方式名称。
  Future<void> saveMatchModeName(String matchModeName) async {
    final String? normalized = _validMatchMode(matchModeName);
    if (normalized == null) {
      throw ArgumentError.value(
        matchModeName,
        'matchModeName',
        '搜索匹配方式无效',
      );
    }
    if (!_preferencesStore.writeString(_matchModeKey, normalized)) {
      throw StateError('搜索匹配方式偏好写入失败');
    }
  }

  /// 只允许搜索页面当前支持的稳定枚举名称。
  String? _validMatchMode(String? value) {
    return switch (value) {
      'contains' || 'exact' || 'fuzzy' => value,
      _ => null,
    };
  }
}
