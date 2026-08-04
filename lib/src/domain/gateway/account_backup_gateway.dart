import '../model/account_backup.dart';

/// 生成与清理账号逻辑备份文件的领域边界。
abstract interface class AccountBackupGateway {
  /// 当前服务器上传能力的接入状态。
  AccountBackupRemoteState get remoteState;

  /// 为当前已登录账号生成经过哈希校验的本地备份文件。
  Future<AccountBackupArtifact> prepareBackup();

  /// 生成并上传当前登录账号的完整逻辑备份，成功后清理临时文件。
  Future<AccountBackupRecord> backupCurrentAccount();

  /// 上传调用方持有的本地备份文件，并完成服务端完整性确认。
  Future<AccountBackupRecord> uploadPreparedBackup(
    AccountBackupArtifact artifact,
  );

  /// 分页读取当前登录账号已经 READY 的服务端备份。
  Future<AccountBackupPage> listBackups({String? beforeId, int limit = 20});

  /// 读取当前登录账号最近完成的一份备份。
  Future<AccountBackupRecord?> latestBackup();

  /// 下载、校验并以替换语义恢复当前账号的业务数据。
  Future<AccountBackupRestoreResult> restoreBackup(String backupId);

  /// 幂等删除当前账号的一份服务端备份。
  Future<void> deleteRemoteBackup(String backupId);

  /// 删除由本边界生成且尚未上传的本地临时备份。
  Future<void> deletePreparedBackup(AccountBackupArtifact artifact);
}
