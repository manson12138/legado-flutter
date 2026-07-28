import 'app_preferences_store.dart';

/// 单个偏好键从旧存储迁移到新存储后的受控结果。
enum AppPreferenceMigrationStatus {
  /// 新存储已经存在合法值，本次没有访问旧存储。
  currentValue,

  /// 该版本迁移已完成，但新存储没有值，应由调用方使用默认值。
  completedWithoutValue,

  /// 已把合法旧值写入新存储并记录迁移版本。
  migrated,

  /// 新存储原值损坏，已删除并阻止回退到可能过期的旧值。
  discardedInvalidCurrentValue,

  /// 旧存储没有值，已记录迁移版本。
  noLegacyValue,

  /// 旧存储值无效，已记录迁移版本并由调用方使用默认值。
  discardedInvalidLegacyValue,

  /// 新值写入失败，未记录迁移版本，下次允许重试。
  valueWriteFailed,

  /// 迁移版本写入失败；没有可用新值时，下次允许重新读取旧存储。
  versionWriteFailed,

  /// 新值已写入，但迁移版本写入失败；下次会优先命中新值。
  migratedWithoutVersionMarker,
}

/// 携带单键迁移状态和可选可用值。
final class AppPreferenceMigrationResult<T extends Object> {
  /// 创建不可变迁移结果。
  const AppPreferenceMigrationResult({
    required this.status,
    this.value,
  });

  /// 本次迁移所处状态。
  final AppPreferenceMigrationStatus status;

  /// 新存储已有值或本次成功迁移出的值。
  final T? value;
}

/// 按键、按版本执行 SQLite 等旧存储到 MMKV 的一次性兼容迁移。
///
/// 本类型不感知 SQLite，也不持有 DAO；各类型化偏好服务负责提供旧值读取和
/// 严格解码函数。读取旧存储抛出异常时不会写迁移标记，因此下次仍可重试。
final class VersionedAppPreferenceMigrator {
  /// 使用目标偏好存储创建逐键迁移器。
  const VersionedAppPreferenceMigrator(this._store);

  /// 迁移后的目标偏好存储。
  final AppPreferencesStore _store;

  /// 迁移一个非空基础值，并通过独立版本键控制旧存储是否还允许被读取。
  Future<AppPreferenceMigrationResult<T>> migrate<T extends Object>({
    required String valueKey,
    required String migrationVersionKey,
    required int targetVersion,
    required T? Function() readCurrentValue,
    required bool Function(T value) writeCurrentValue,
    required Future<String?> Function() readLegacyValue,
    required T? Function(String rawValue) decodeLegacyValue,
  }) async {
    if (targetVersion <= 0) {
      throw ArgumentError.value(
        targetVersion,
        'targetVersion',
        '迁移版本必须大于零',
      );
    }

    if (_store.contains(valueKey)) {
      final T? currentValue = readCurrentValue();
      if (currentValue != null) {
        return AppPreferenceMigrationResult<T>(
          status: AppPreferenceMigrationStatus.currentValue,
          value: currentValue,
        );
      }
      _store.remove(valueKey);
      final bool versionRecorded = _store.writeInt(
        migrationVersionKey,
        targetVersion,
      );
      return AppPreferenceMigrationResult<T>(
        status: versionRecorded
            ? AppPreferenceMigrationStatus.discardedInvalidCurrentValue
            : AppPreferenceMigrationStatus.versionWriteFailed,
      );
    }

    final int? completedVersion = _store.readInt(migrationVersionKey);
    if (completedVersion != null && completedVersion >= targetVersion) {
      return AppPreferenceMigrationResult<T>(
        status: AppPreferenceMigrationStatus.completedWithoutValue,
      );
    }
    if (_store.contains(migrationVersionKey) && completedVersion == null) {
      _store.remove(migrationVersionKey);
    }

    final String? legacyValue = await readLegacyValue();
    if (legacyValue == null) {
      final bool versionRecorded = _store.writeInt(
        migrationVersionKey,
        targetVersion,
      );
      return AppPreferenceMigrationResult<T>(
        status: versionRecorded
            ? AppPreferenceMigrationStatus.noLegacyValue
            : AppPreferenceMigrationStatus.versionWriteFailed,
      );
    }

    final T? decodedValue = decodeLegacyValue(legacyValue);
    if (decodedValue == null) {
      final bool versionRecorded = _store.writeInt(
        migrationVersionKey,
        targetVersion,
      );
      return AppPreferenceMigrationResult<T>(
        status: versionRecorded
            ? AppPreferenceMigrationStatus.discardedInvalidLegacyValue
            : AppPreferenceMigrationStatus.versionWriteFailed,
      );
    }

    if (!writeCurrentValue(decodedValue)) {
      return AppPreferenceMigrationResult<T>(
        status: AppPreferenceMigrationStatus.valueWriteFailed,
      );
    }
    final bool versionRecorded = _store.writeInt(
      migrationVersionKey,
      targetVersion,
    );
    return AppPreferenceMigrationResult<T>(
      status: versionRecorded
          ? AppPreferenceMigrationStatus.migrated
          : AppPreferenceMigrationStatus.migratedWithoutVersionMarker,
      value: decodedValue,
    );
  }
}
