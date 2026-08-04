/// 账号备份服务端接入状态。
enum AccountBackupRemoteState {
  /// 客户端可以生成本地备份，但服务器接口尚未开放。
  waitingForServer,

  /// 服务器接口已开放，可以上传备份文件。
  available,
}

/// 已生成且完成完整性计算的账号备份文件。
final class AccountBackupArtifact {
  /// 创建只读备份文件描述。
  AccountBackupArtifact({
    required this.path,
    required this.clientBackupId,
    required this.createdAt,
    required this.byteSize,
    required this.sha256,
    required Map<String, int> itemCounts,
  }) : itemCounts = Map<String, int>.unmodifiable(itemCounts);

  /// 应用私有临时目录中的绝对文件路径。
  final String path;

  /// 客户端生成的幂等备份标识。
  final String clientBackupId;

  /// 备份快照的 UTC 创建时间。
  final DateTime createdAt;

  /// 最终压缩文件字节数。
  final int byteSize;

  /// 最终压缩文件的小写 SHA-256。
  final String sha256;

  /// 各逻辑数据集导出的记录数量。
  final Map<String, int> itemCounts;
}

/// 服务端已经完成并可下载恢复的账号备份。
final class AccountBackupRecord {
  /// 创建只读备份元数据。
  AccountBackupRecord({
    required this.backupId,
    required this.formatVersion,
    required this.byteSize,
    required this.sha256,
    required this.completedAt,
    required this.createdAt,
    required this.appVersionName,
    required this.appVersionCode,
    required this.databaseSchemaVersion,
    required this.platform,
    required Map<String, int> itemCounts,
  }) : itemCounts = Map<String, int>.unmodifiable(itemCounts);

  /// 服务端生成的备份标识。
  final String backupId;

  /// 客户端逻辑备份格式版本。
  final int formatVersion;

  /// 备份对象真实字节数。
  final int byteSize;

  /// 备份对象 SHA-256。
  final String sha256;

  /// 服务端确认备份完成的 UTC 时间。
  final DateTime completedAt;

  /// 客户端开始生成快照的 UTC 时间。
  final DateTime? createdAt;

  /// 创建备份的应用版本名。
  final String? appVersionName;

  /// 创建备份的应用构建号。
  final int? appVersionCode;

  /// 创建备份时的数据库版本。
  final int? databaseSchemaVersion;

  /// 创建备份的平台。
  final String? platform;

  /// 服务端保存的数据集计数摘要。
  final Map<String, int> itemCounts;
}

/// 当前账号的服务端备份分页和容量摘要。
final class AccountBackupPage {
  /// 创建不可变备份分页。
  AccountBackupPage({
    required List<AccountBackupRecord> items,
    required this.nextCursor,
    required this.hasMore,
    required this.totalReadyCount,
    required this.usedQuotaBytes,
    required this.userQuotaBytes,
  }) : items = List<AccountBackupRecord>.unmodifiable(items);

  /// 当前页备份。
  final List<AccountBackupRecord> items;

  /// 下一页不透明游标。
  final String? nextCursor;

  /// 是否仍有下一页。
  final bool hasMore;

  /// READY 备份总数。
  final int totalReadyCount;

  /// 当前账号已使用容量。
  final int usedQuotaBytes;

  /// 当前账号服务端总容量。
  final int userQuotaBytes;
}

/// 一次账号备份恢复完成后的数据集计数。
final class AccountBackupRestoreResult {
  /// 创建恢复结果。
  AccountBackupRestoreResult({
    required this.backupId,
    required Map<String, int> restoredItemCounts,
  }) : restoredItemCounts = Map<String, int>.unmodifiable(restoredItemCounts);

  /// 本次恢复的服务端备份标识。
  final String backupId;

  /// 已替换写入的各数据集记录数量。
  final Map<String, int> restoredItemCounts;
}
