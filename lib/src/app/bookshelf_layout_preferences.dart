import '../data/dao/cache_dao.dart';
import '../data/local/preferences/app_preferences_store.dart';
import '../data/local/preferences/versioned_app_preference_migrator.dart';
import '../ui/bookshelf/bookshelf_contract.dart';
import '../ui/bookshelf/reading_history_contract.dart';

/// 使用 MMKV 持久化书架与阅读历史页面布局，并兼容迁移旧 SQLite 值。
final class BookshelfLayoutPreferences {
  /// 创建页面布局偏好服务。
  BookshelfLayoutPreferences(
    this._preferencesStore,
    this._legacyCacheDao,
  ) : _migrator = VersionedAppPreferenceMigrator(_preferencesStore);

  /// MMKV 或其进程内降级实现。
  final AppPreferencesStore _preferencesStore;

  /// 只在首次迁移时读取旧值的 SQLite 缓存 DAO。
  final CacheDao _legacyCacheDao;

  /// 按键记录迁移版本，避免长期维护双事实源。
  final VersionedAppPreferenceMigrator _migrator;

  /// 书架布局的新 MMKV 键。
  static const String _bookshelfLayoutKey = 'bookshelf.layout_mode.v1';

  /// 书架布局迁移版本键。
  static const String _bookshelfLayoutMigrationKey =
      'migration.bookshelf.layout_mode.v1';

  /// 书架布局的旧 SQLite 键。
  static const String _legacyBookshelfLayoutKey = 'bookshelf_layout_mode';

  /// 阅读历史布局的新 MMKV 键。
  static const String _readingHistoryLayoutKey =
      'reading_history.layout_mode.v1';

  /// 阅读历史布局迁移版本键。
  static const String _readingHistoryLayoutMigrationKey =
      'migration.reading_history.layout_mode.v1';

  /// 阅读历史布局的旧 SQLite 键。
  static const String _legacyReadingHistoryLayoutKey =
      'reading_history_layout_mode';

  /// 读取书架布局；缺失或旧值时保持默认网格布局。
  Future<BookshelfLayoutMode> readBookshelfLayout() async {
    final AppPreferenceMigrationResult<String> result =
        await _migrator.migrate<String>(
      valueKey: _bookshelfLayoutKey,
      migrationVersionKey: _bookshelfLayoutMigrationKey,
      targetVersion: 1,
      readCurrentValue: () =>
          _validLayoutName(_preferencesStore.readString(_bookshelfLayoutKey)),
      writeCurrentValue: (String value) =>
          _preferencesStore.writeString(_bookshelfLayoutKey, value),
      readLegacyValue: () async =>
          (await _legacyCacheDao.get(_legacyBookshelfLayoutKey))?.value,
      decodeLegacyValue: _validLayoutName,
    );
    final String? value = result.value;
    return switch (value) {
      'list' => BookshelfLayoutMode.list,
      _ => BookshelfLayoutMode.grid,
    };
  }

  /// 保存书架布局，供下次创建书架页面时恢复。
  Future<void> saveBookshelfLayout(BookshelfLayoutMode layoutMode) async {
    if (!_preferencesStore.writeString(
      _bookshelfLayoutKey,
      layoutMode.name,
    )) {
      throw StateError('书架布局偏好写入失败');
    }
  }

  /// 读取阅读历史布局；缺失或旧值时保持与书架一致的默认网格布局。
  Future<ReadingHistoryLayoutMode> readReadingHistoryLayout() async {
    final AppPreferenceMigrationResult<String> result =
        await _migrator.migrate<String>(
      valueKey: _readingHistoryLayoutKey,
      migrationVersionKey: _readingHistoryLayoutMigrationKey,
      targetVersion: 1,
      readCurrentValue: () => _validLayoutName(
        _preferencesStore.readString(_readingHistoryLayoutKey),
      ),
      writeCurrentValue: (String value) =>
          _preferencesStore.writeString(_readingHistoryLayoutKey, value),
      readLegacyValue: () async =>
          (await _legacyCacheDao.get(_legacyReadingHistoryLayoutKey))?.value,
      decodeLegacyValue: _validLayoutName,
    );
    final String? value = result.value;
    return switch (value) {
      'list' => ReadingHistoryLayoutMode.list,
      _ => ReadingHistoryLayoutMode.grid,
    };
  }

  /// 保存阅读历史布局，供下次创建历史页面时恢复。
  Future<void> saveReadingHistoryLayout(
    ReadingHistoryLayoutMode layoutMode,
  ) async {
    if (!_preferencesStore.writeString(
      _readingHistoryLayoutKey,
      layoutMode.name,
    )) {
      throw StateError('阅读历史布局偏好写入失败');
    }
  }

  /// 只接受当前布局枚举支持的稳定名称。
  String? _validLayoutName(String? value) {
    return value == 'list' || value == 'grid' ? value : null;
  }
}
