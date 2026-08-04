import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../../api/remote_app/remote_app_api.dart';
import '../../api/remote_app/remote_app_service_config.dart';
import '../../domain/gateway/account_backup_gateway.dart';
import '../../domain/gateway/authentication_gateway.dart';
import '../../domain/model/account_backup.dart';
import '../../domain/model/book.dart';
import '../../domain/model/book_content_process.dart';
import '../../domain/model/book_group.dart';
import '../../domain/model/bookmark.dart';
import '../../domain/model/replace_rule.dart';
import '../../help/logging/app_logger.dart';
import '../dao/book_content_process_dao.dart';
import '../dao/book_dao.dart';
import '../dao/book_group_dao.dart';
import '../dao/bookmark_dao.dart';
import '../dao/reading_history_dao.dart';
import '../dao/replace_rule_dao.dart';
import '../local/entity_maps.dart';
import '../local/database_tables.dart';
import '../local/legado_database.dart';
import '../local/preferences/app_preferences_store.dart';

/// 账号备份链路的稳定日志标识；日志不得包含文件正文、用户数据或文件路径。
const String accountBackupLogTag = remoteAccountBackupLogTag;

/// 把当前账号的可迁移业务数据导出为版本化 ZIP 逻辑备份。
final class AccountBackupRepository implements AccountBackupGateway {
  /// 创建账号备份仓储。
  const AccountBackupRepository({
    required BookDao bookDao,
    required BookGroupDao bookGroupDao,
    required ReadingHistoryDao readingHistoryDao,
    required BookmarkDao bookmarkDao,
    required BookContentProcessDao bookContentProcessDao,
    required ReplaceRuleDao replaceRuleDao,
    required AppPreferencesStore preferencesStore,
    required int Function() currentUserId,
    required RemoteAppServiceConfig remoteAppConfig,
    required RemoteAppApi remoteAppApi,
    required AuthenticationGateway authenticationGateway,
    required LegadoDatabase database,
    required Future<void> Function() onAccountDataRestored,
    required AppLogger logger,
  }) : _bookDao = bookDao,
       _bookGroupDao = bookGroupDao,
       _readingHistoryDao = readingHistoryDao,
       _bookmarkDao = bookmarkDao,
       _bookContentProcessDao = bookContentProcessDao,
       _replaceRuleDao = replaceRuleDao,
       _preferencesStore = preferencesStore,
       _currentUserId = currentUserId,
       _remoteAppConfig = remoteAppConfig,
       _remoteAppApi = remoteAppApi,
       _authenticationGateway = authenticationGateway,
       _database = database,
       _onAccountDataRestored = onAccountDataRestored,
       _logger = logger;

  /// 当前备份格式版本。
  static const int _formatVersion = 1;

  /// 单个备份文件允许占用的最大字节数。
  static const int _maximumBackupBytes = 20 * 1024 * 1024;

  /// 本仓储拥有的临时备份目录名称。
  static const String _stagingDirectoryName = 'account_backup_staging';

  /// 书架书籍 DAO。
  final BookDao _bookDao;

  /// 书架分组 DAO。
  final BookGroupDao _bookGroupDao;

  /// 阅读历史 DAO。
  final ReadingHistoryDao _readingHistoryDao;

  /// 书签 DAO。
  final BookmarkDao _bookmarkDao;

  /// 正文标注 DAO。
  final BookContentProcessDao _bookContentProcessDao;

  /// 正文替换规则 DAO。
  final ReplaceRuleDao _replaceRuleDao;

  /// 小型偏好读取边界。
  final AppPreferencesStore _preferencesStore;

  /// 返回当前用户标识；游客固定为负数。
  final int Function() _currentUserId;

  /// 备份清单使用的应用版本配置。
  final RemoteAppServiceConfig _remoteAppConfig;

  /// 账号备份控制接口与二进制传输实现。
  final RemoteAppApi _remoteAppApi;

  /// 只在请求开始时读取当前内存 Access Token。
  final AuthenticationGateway _authenticationGateway;

  /// 恢复时提供当前账号 SQLite 原子替换事务。
  final LegadoDatabase _database;

  /// 恢复提交后清理书架首快照和处理后正文等内存派生状态。
  final Future<void> Function() _onAccountDataRestored;

  /// 只记录阶段与数量的安全日志器。
  final AppLogger _logger;

  @override
  AccountBackupRemoteState get remoteState =>
      AccountBackupRemoteState.available;

  @override
  Future<AccountBackupArtifact> prepareBackup() async {
    final int userId = _currentUserId();
    if (userId < 0) {
      throw StateError('游客数据不能创建账号备份');
    }
    final DateTime createdAt = DateTime.now().toUtc();
    final String clientBackupId = _newClientBackupId();
    _logger.info(
      tag: accountBackupLogTag,
      message: 'stage=prepare_started formatVersion=$_formatVersion',
    );

    final _AccountBackupSnapshot snapshot =
        await _database.transaction<_AccountBackupSnapshot>(
      (Transaction transaction) async {
        return _AccountBackupSnapshot(
          shelfBooks: await _bookDao.getAll(userId, executor: transaction),
          historyBooks: await _readingHistoryDao.getAllBooks(
            userId,
            executor: transaction,
          ),
          groups: await _bookGroupDao.getAll(userId, executor: transaction),
          bookmarks: await _bookmarkDao.getAll(userId, executor: transaction),
          annotations: await _bookContentProcessDao.getAllActive(
            userId,
            executor: transaction,
          ),
          replaceRules: await _replaceRuleDao.getAll(
            userId,
            executor: transaction,
          ),
        );
      },
    );
    _ensureUserUnchanged(userId);
    final List<Book> shelfBooks = snapshot.shelfBooks
        .where((Book book) => book.origin != 'loc_book')
        .toList(growable: false);
    final List<Book> historyBooks = snapshot.historyBooks
        .where((Book book) => book.origin != 'loc_book')
        .toList(growable: false);
    final List<Map<String, Object?>> groups = snapshot.groups
        .map(_groupToBackupJson)
        .toList(growable: false);
    final List<Map<String, Object?>> bookmarks = snapshot.bookmarks
        .map(bookmarkToMap)
        .toList(growable: false);
    final List<Map<String, Object?>> annotations = snapshot.annotations
        .map(_annotationToJson)
        .toList(growable: false);
    final List<Map<String, Object?>> replaceRules = snapshot.replaceRules
        .map(_replaceRuleToBackupJson)
        .toList(growable: false);

    final Map<String, List<Map<String, Object?>>> datasets =
        <String, List<Map<String, Object?>>>{
          'bookshelf.json': shelfBooks.map(_bookToBackupJson).toList(growable: false),
          'groups.json': groups,
          'reading_history.json': historyBooks.map(_bookToBackupJson).toList(growable: false),
          'bookmarks.json': bookmarks,
          'annotations.json': annotations,
          'replace_rules.json': replaceRules,
        };
    final Map<String, int> itemCounts = <String, int>{
      'books': shelfBooks.length,
      'bookGroups': groups.length,
      'readingHistory': historyBooks.length,
      'bookmarks': bookmarks.length,
      'annotations': annotations.length,
      'replaceRules': replaceRules.length,
    };
    final Map<String, Object?> preferences = _exportPreferences();
    itemCounts['preferences'] = preferences.length;
    final String appVersionName = _remoteAppConfig.appVersionName;
    final int appVersionCode = _remoteAppConfig.appVersionCode;

    _ensureUserUnchanged(userId);
    final Uint8List archiveBytes = await Isolate.run<Uint8List>(
      () => _encodeBackupArchive(
        datasets: datasets,
        preferences: preferences,
        itemCounts: itemCounts,
        clientBackupId: clientBackupId,
        createdAt: createdAt,
        userId: userId,
        appVersionName: appVersionName,
        appVersionCode: appVersionCode,
      ),
    );
    _ensureUserUnchanged(userId);
    if (archiveBytes.length > _maximumBackupBytes) {
      throw StateError('备份文件超过客户端大小限制');
    }
    final Directory supportDirectory = await getApplicationSupportDirectory();
    final Directory stagingDirectory = Directory(
      path.join(supportDirectory.path, _stagingDirectoryName),
    );
    await stagingDirectory.create(recursive: true);
    final File buildingFile = File(
      path.join(stagingDirectory.path, '$clientBackupId.building'),
    );
    final File completedFile = File(
      path.join(stagingDirectory.path, '$clientBackupId.pnbak'),
    );
    try {
      await buildingFile.writeAsBytes(archiveBytes, flush: true);
      await buildingFile.rename(completedFile.path);
    } catch (_) {
      if (await buildingFile.exists()) {
        await buildingFile.delete();
      }
      rethrow;
    }
    if (_currentUserId() != userId) {
      if (await completedFile.exists()) {
        await completedFile.delete();
      }
      throw StateError('账号已在备份生成期间切换');
    }
    final AccountBackupArtifact artifact = AccountBackupArtifact(
      path: completedFile.path,
      clientBackupId: clientBackupId,
      createdAt: createdAt,
      byteSize: archiveBytes.length,
      sha256: sha256.convert(archiveBytes).toString(),
      itemCounts: itemCounts,
    );
    _logger.info(
      tag: accountBackupLogTag,
      message: 'stage=prepare_succeeded byteSize=${artifact.byteSize} datasets=${artifact.itemCounts.length}',
    );
    return artifact;
  }

  @override
  Future<AccountBackupRecord> backupCurrentAccount() async {
    final AccountBackupArtifact artifact = await prepareBackup();
    try {
      final AccountBackupRecord record = await uploadPreparedBackup(artifact);
      try {
        await deletePreparedBackup(artifact);
      } catch (_) {
        _logger.warning(
          tag: accountBackupLogTag,
          message: 'stage=prepared_file_cleanup_degraded',
        );
      }
      return record;
    } catch (_) {
      _logger.warning(
        tag: accountBackupLogTag,
        message: 'stage=upload_failed preparedFileRetained=true',
      );
      rethrow;
    }
  }

  @override
  Future<AccountBackupRecord> uploadPreparedBackup(
    AccountBackupArtifact artifact,
  ) async {
    final int userId = _requireLoggedInUserId();
    final String token = _requireAccessToken();
    final Uint8List bytes = await _readAndValidatePreparedArtifact(artifact);
    _ensureUserUnchanged(userId);
    final String platform = _backupPlatform();
    _logger.info(
      tag: accountBackupLogTag,
      message: 'stage=upload_initialize_started byteSize=${bytes.length}',
    );
    final RemoteAccountBackupUpload upload =
        await _remoteAppApi.initializeAccountBackup(
      token,
      <String, Object?>{
        'clientBackupId': artifact.clientBackupId,
        'formatVersion': _formatVersion,
        'appVersionName': _remoteAppConfig.appVersionName,
        'appVersionCode': _remoteAppConfig.appVersionCode,
        'databaseSchemaVersion': LegadoDatabase.schemaVersion,
        'platform': platform,
        'createdAt': artifact.createdAt.toUtc().toIso8601String(),
        'byteSize': artifact.byteSize,
        'sha256': artifact.sha256,
        'containsLocalBookFiles': false,
        'itemCounts': artifact.itemCounts,
      },
    );
    _ensureUserUnchanged(userId);
    if (upload.maximumByteSize case final int maximum
        when artifact.byteSize > maximum) {
      throw StateError('备份文件超过服务端大小限制');
    }
    if (upload.state == 'READY') {
      return _findIdempotentReadyBackup(token, upload.backupId, userId);
    }
    final String? uploadId = upload.uploadId;
    final DateTime? expiresAt = upload.expiresAt;
    if (uploadId == null ||
        expiresAt == null ||
        !expiresAt.isAfter(DateTime.now().toUtc())) {
      throw const FormatException('备份上传会话无效或已经过期');
    }
    _logger.info(
      tag: accountBackupLogTag,
      message: 'stage=upload_content_started byteSize=${bytes.length}',
    );
    await _remoteAppApi.uploadAccountBackupContent(
      token: token,
      upload: upload,
      bytes: bytes,
    );
    _ensureUserUnchanged(userId);
    final RemoteAccountBackupMetadata completed =
        await _remoteAppApi.completeAccountBackup(
      token: token,
      uploadId: uploadId,
      clientBackupId: artifact.clientBackupId,
      byteSize: artifact.byteSize,
      sha256Value: artifact.sha256,
    );
    _ensureUserUnchanged(userId);
    if (completed.backupId != upload.backupId ||
        completed.byteSize != artifact.byteSize ||
        completed.sha256 != artifact.sha256) {
      throw const FormatException('服务端备份完成元数据与本地文件不一致');
    }
    _logger.info(
      tag: accountBackupLogTag,
      message: 'stage=upload_succeeded byteSize=${completed.byteSize}',
    );
    return _recordFromRemote(completed);
  }

  @override
  Future<AccountBackupPage> listBackups({
    String? beforeId,
    int limit = 20,
  }) async {
    final int userId = _requireLoggedInUserId();
    final String token = _requireAccessToken();
    final RemoteAccountBackupPage page =
        await _remoteAppApi.fetchAccountBackups(
      token,
      beforeId: beforeId,
      limit: limit,
    );
    _ensureUserUnchanged(userId);
    return _pageFromRemote(page);
  }

  @override
  Future<AccountBackupRecord?> latestBackup() async {
    final int userId = _requireLoggedInUserId();
    final String token = _requireAccessToken();
    final RemoteAccountBackupMetadata? latest =
        await _remoteAppApi.fetchLatestAccountBackup(token);
    _ensureUserUnchanged(userId);
    return latest == null ? null : _recordFromRemote(latest);
  }

  @override
  Future<void> deleteRemoteBackup(String backupId) async {
    final int userId = _requireLoggedInUserId();
    final String token = _requireAccessToken();
    await _remoteAppApi.deleteAccountBackup(token, backupId);
    _ensureUserUnchanged(userId);
    _logger.info(
      tag: accountBackupLogTag,
      message: 'stage=remote_delete_succeeded',
    );
  }

  @override
  Future<AccountBackupRestoreResult> restoreBackup(String backupId) async {
    final int userId = _requireLoggedInUserId();
    final String token = _requireAccessToken();
    final RemoteAccountBackupDownload download =
        await _remoteAppApi.createAccountBackupDownload(token, backupId);
    if (download.backupId != backupId ||
        download.byteSize > _maximumBackupBytes ||
        download.expiresAt.isBefore(DateTime.now().toUtc())) {
      throw const FormatException('备份下载凭据无效');
    }
    _ensureUserUnchanged(userId);
    final Uint8List bytes =
        await _remoteAppApi.downloadAccountBackupContent(download);
    _ensureUserUnchanged(userId);
    if (bytes.length != download.byteSize ||
        sha256.convert(bytes).toString() != download.sha256) {
      throw const FormatException('下载备份的大小或摘要校验失败');
    }
    final _DecodedAccountBackup decoded = await Isolate.run<_DecodedAccountBackup>(
      () => AccountBackupRepository._decodeBackupArchive(
        bytes,
        expectedUserId: userId,
      ),
    );
    _ensureUserUnchanged(userId);
    await _restoreDecodedBackup(userId, decoded);
    _ensureUserUnchanged(userId);
    _logger.info(
      tag: accountBackupLogTag,
      message: 'stage=restore_succeeded datasets=${decoded.itemCounts.length}',
    );
    return AccountBackupRestoreResult(
      backupId: backupId,
      restoredItemCounts: decoded.itemCounts,
    );
  }

  @override
  Future<void> deletePreparedBackup(AccountBackupArtifact artifact) async {
    final File file = File(artifact.path);
    final Directory supportDirectory = await getApplicationSupportDirectory();
    final String ownedDirectory = path.normalize(
      path.join(supportDirectory.path, _stagingDirectoryName),
    );
    final bool isOwnedFile =
        path.equals(path.normalize(file.parent.absolute.path), ownedDirectory) &&
        path.basename(file.path) == '${artifact.clientBackupId}.pnbak';
    if (!isOwnedFile) {
      throw ArgumentError.value(artifact.path, 'artifact', '不是账号备份临时文件');
    }
    if (await file.exists()) {
      await file.delete();
    }
  }

  /// 移除不能跨设备恢复的本地路径和书源运行变量。
  static Map<String, Object?> _bookToBackupJson(Book book) {
    final Map<String, Object?> value = Map<String, Object?>.from(bookToMap(book));
    value['group'] = value.remove('`group`');
    value['order'] = value.remove('`order`');
    value.remove('variable');
    final Object? customCoverUrl = value['customCoverUrl'];
    if (customCoverUrl is String && customCoverUrl.startsWith('legado-cover:')) {
      value['customCoverUrl'] = null;
    }
    return value;
  }

  /// 把书架分组转换为不含 SQLite 转义列名的逻辑 JSON。
  static Map<String, Object?> _groupToBackupJson(BookGroup group) {
    final Map<String, Object?> value = Map<String, Object?>.from(
      bookGroupToMap(group),
    );
    value['order'] = value.remove('`order`');
    final Object? cover = value['cover'];
    if (cover is String && cover.startsWith('legado-cover:')) {
      value['cover'] = null;
    }
    return value;
  }

  /// 把替换规则转换为不含本机自增主键和 SQLite 转义列名的逻辑 JSON。
  static Map<String, Object?> _replaceRuleToBackupJson(ReplaceRule rule) {
    final Map<String, Object?> value = Map<String, Object?>.from(
      replaceRuleToMap(rule),
    );
    value['group'] = value.remove('`group`');
    value.remove('id');
    return value;
  }

  /// 把正文标注转换为与 SQLite 实现无关的逻辑 JSON。
  static Map<String, Object?> _annotationToJson(BookContentProcess process) {
    return <String, Object?>{
      'id': process.id,
      'bookUrl': process.bookUrl,
      'chapterIndex': process.chapterIndex,
      'kind': process.kind.storageName,
      'anchor': <String, Object?>{
        'chapterIndex': process.anchor.chapterIndex,
        'chapterPosition': process.anchor.chapterPosition,
        'selectedText': process.anchor.selectedText,
        'contextBefore': process.anchor.contextBefore,
        'contextAfter': process.anchor.contextAfter,
        'normalizedTextHash': process.anchor.normalizedTextHash,
      },
      'style': <String, Object?>{
        'backgroundColorValue': process.style.backgroundColorValue,
        'underlineColorValue': process.style.underlineColorValue,
        'underlineWidth': process.style.underlineWidth,
      },
      'enabled': process.enabled,
      'sortOrder': process.sortOrder,
      'status': process.status,
      'createdAt': process.createdAt,
      'updatedAt': process.updatedAt,
    };
  }

  /// 只导出经过白名单审查且不含凭据的小型设置。
  Map<String, Object?> _exportPreferences() {
    final Map<String, Object?> values = <String, Object?>{};
    for (final String key in const <String>[
      'reader.display_config.v1',
      'bookshelf.layout_mode.v1',
      'reading_history.layout_mode.v1',
      'search.match_mode.v1',
    ]) {
      final String? value = _preferencesStore.readString(key);
      if (value != null) {
        values[key] = value;
      }
    }
    final bool? sourceInteraction =
        _preferencesStore.readBool('search.source_interaction.v1');
    if (sourceInteraction != null) {
      values['search.source_interaction.v1'] = sourceInteraction;
    }
    return values;
  }

  /// 拒绝把旧账号快照交给已经切换的新会话。
  void _ensureUserUnchanged(int expectedUserId) {
    if (_currentUserId() != expectedUserId) {
      throw StateError('账号已在备份生成期间切换');
    }
  }

  /// 返回当前登录账号 ID，并拒绝游客作用域。
  int _requireLoggedInUserId() {
    final int userId = _currentUserId();
    if (userId < 0) {
      throw StateError('游客不能使用账号备份服务');
    }
    return userId;
  }

  /// 返回当前内存 Access Token，不从普通持久化存储读取凭据。
  String _requireAccessToken() {
    final String? token = _authenticationGateway.currentToken();
    if (token == null || token.isEmpty) {
      throw StateError('账号会话不可用');
    }
    return token;
  }

  /// 返回服务端契约支持的平台枚举。
  String _backupPlatform() {
    if (Platform.isAndroid) {
      return 'android';
    }
    if (Platform.isIOS) {
      return 'ios';
    }
    throw UnsupportedError('当前平台不支持账号备份');
  }

  /// 读取本仓储拥有的临时文件，并再次校验大小与整体摘要。
  Future<Uint8List> _readAndValidatePreparedArtifact(
    AccountBackupArtifact artifact,
  ) async {
    final Directory supportDirectory = await getApplicationSupportDirectory();
    final String ownedDirectory = path.normalize(
      path.join(supportDirectory.path, _stagingDirectoryName),
    );
    final File file = File(artifact.path);
    final bool isOwnedFile =
        path.equals(path.normalize(file.parent.absolute.path), ownedDirectory) &&
        path.basename(file.path) == '${artifact.clientBackupId}.pnbak';
    if (!isOwnedFile || !await file.exists()) {
      throw const FileSystemException('备份临时文件不存在或不受当前仓储管理');
    }
    final int fileLength = await file.length();
    if (fileLength != artifact.byteSize || fileLength > _maximumBackupBytes) {
      throw const FormatException('备份临时文件大小无效');
    }
    final Uint8List bytes = await file.readAsBytes();
    if (sha256.convert(bytes).toString() != artifact.sha256) {
      throw const FormatException('备份临时文件摘要无效');
    }
    return bytes;
  }

  /// 在初始化接口幂等命中 READY 时，从列表中恢复完整元数据。
  Future<AccountBackupRecord> _findIdempotentReadyBackup(
    String token,
    String backupId,
    int userId,
  ) async {
    String? cursor;
    for (int pageIndex = 0; pageIndex < 5; pageIndex += 1) {
      final RemoteAccountBackupPage page =
          await _remoteAppApi.fetchAccountBackups(
        token,
        beforeId: cursor,
        limit: 50,
      );
      _ensureUserUnchanged(userId);
      for (final RemoteAccountBackupMetadata item in page.items) {
        if (item.backupId == backupId) {
          return _recordFromRemote(item);
        }
      }
      if (!page.hasMore) {
        break;
      }
      cursor = page.nextCursor;
    }
    throw const FormatException('幂等备份已完成但无法读取对应元数据');
  }

  /// 把远端 DTO 转换为不依赖 API 层的领域模型。
  AccountBackupRecord _recordFromRemote(RemoteAccountBackupMetadata value) {
    return AccountBackupRecord(
      backupId: value.backupId,
      formatVersion: value.formatVersion,
      byteSize: value.byteSize,
      sha256: value.sha256,
      completedAt: value.completedAt,
      createdAt: value.createdAt,
      appVersionName: value.appVersionName,
      appVersionCode: value.appVersionCode,
      databaseSchemaVersion: value.databaseSchemaVersion,
      platform: value.platform,
      itemCounts: value.itemCounts,
    );
  }

  /// 把远端分页 DTO 转换为领域分页。
  AccountBackupPage _pageFromRemote(RemoteAccountBackupPage value) {
    return AccountBackupPage(
      items: value.items.map(_recordFromRemote).toList(growable: false),
      nextCursor: value.nextCursor,
      hasMore: value.hasMore,
      totalReadyCount: value.totalReadyCount,
      usedQuotaBytes: value.usedQuotaBytes,
      userQuotaBytes: value.userQuotaBytes,
    );
  }

  /// 以当前账号替换语义原子恢复 SQLite 数据，偏好设置在提交后按白名单写入。
  Future<void> _restoreDecodedBackup(
    int userId,
    _DecodedAccountBackup backup,
  ) async {
    await _database.transaction<void>((Transaction transaction) async {
      _ensureUserUnchanged(userId);
      final Set<int> occupiedBookmarkTimes = (await transaction.query(
        DatabaseTables.bookmarks,
        columns: const <String>['time'],
        where: 'userId != ?',
        whereArgs: <Object?>[userId],
      )).map((Map<String, Object?> row) => row['time'])
          .whereType<int>()
          .toSet();
      final Set<String> occupiedAnnotationIds = (await transaction.query(
        DatabaseTables.bookContentProcesses,
        columns: const <String>['id'],
        where: 'userId != ?',
        whereArgs: <Object?>[userId],
      )).map((Map<String, Object?> row) => row['id'])
          .whereType<String>()
          .toSet();

      for (final String table in const <String>[
        DatabaseTables.bookmarks,
        DatabaseTables.bookContentProcesses,
        DatabaseTables.replaceRules,
        DatabaseTables.readingHistoryChapters,
        DatabaseTables.readingHistoryBooks,
        DatabaseTables.chapters,
        DatabaseTables.books,
        DatabaseTables.bookGroups,
      ]) {
        await transaction.delete(
          table,
          where: 'userId = ?',
          whereArgs: <Object?>[userId],
        );
      }

      for (final Map<String, Object?> group in backup.groups) {
        await transaction.insert(
          DatabaseTables.bookGroups,
          <String, Object?>{'userId': userId, ...group},
          conflictAlgorithm: ConflictAlgorithm.abort,
        );
      }
      for (final Map<String, Object?> book in backup.books) {
        await transaction.insert(
          DatabaseTables.books,
          <String, Object?>{'userId': userId, ...book},
          conflictAlgorithm: ConflictAlgorithm.abort,
        );
      }
      for (final Map<String, Object?> historyBook in backup.historyBooks) {
        await transaction.insert(
          DatabaseTables.readingHistoryBooks,
          <String, Object?>{'userId': userId, ...historyBook},
          conflictAlgorithm: ConflictAlgorithm.abort,
        );
      }
      for (final Map<String, Object?> bookmark in backup.bookmarks) {
        final Map<String, Object?> restored = Map<String, Object?>.from(bookmark);
        final Object? originalTime = restored['time'];
        if (originalTime is! int) {
          throw const FormatException('备份书签时间无效');
        }
        int restoredTime = originalTime;
        while (occupiedBookmarkTimes.contains(restoredTime)) {
          restoredTime += 1;
        }
        occupiedBookmarkTimes.add(restoredTime);
        restored['time'] = restoredTime;
        await transaction.insert(
          DatabaseTables.bookmarks,
          <String, Object?>{'userId': userId, ...restored},
          conflictAlgorithm: ConflictAlgorithm.abort,
        );
      }
      for (final Map<String, Object?> annotation in backup.annotations) {
        final Map<String, Object?> restored = Map<String, Object?>.from(annotation);
        final Object? originalId = restored['id'];
        if (originalId is! String) {
          throw const FormatException('备份正文标注 ID 无效');
        }
        String restoredId = originalId;
        while (occupiedAnnotationIds.contains(restoredId)) {
          restoredId = _newClientBackupId();
        }
        occupiedAnnotationIds.add(restoredId);
        restored['id'] = restoredId;
        await transaction.insert(
          DatabaseTables.bookContentProcesses,
          <String, Object?>{'userId': userId, ...restored},
          conflictAlgorithm: ConflictAlgorithm.abort,
        );
      }
      for (final Map<String, Object?> rule in backup.replaceRules) {
        await transaction.insert(
          DatabaseTables.replaceRules,
          <String, Object?>{'userId': userId, ...rule},
          conflictAlgorithm: ConflictAlgorithm.abort,
        );
      }
      _ensureUserUnchanged(userId);
    });
    _database.changeNotifier.notifyTables(const <String>{
      DatabaseTables.bookmarks,
      DatabaseTables.bookContentProcesses,
      DatabaseTables.replaceRules,
      DatabaseTables.readingHistoryChapters,
      DatabaseTables.readingHistoryBooks,
      DatabaseTables.chapters,
      DatabaseTables.books,
      DatabaseTables.bookGroups,
    });
    _restorePreferences(backup.preferences);
    try {
      await _onAccountDataRestored();
    } catch (_) {
      _logger.warning(
        tag: accountBackupLogTag,
        message: 'stage=restore_memory_refresh_degraded',
      );
    }
  }

  /// 按固定白名单恢复非敏感小型偏好；单键失败只降级该设置，不回滚业务数据。
  void _restorePreferences(Map<String, Object?> preferences) {
    for (final MapEntry<String, Object?> entry in preferences.entries) {
      final bool saved = switch (entry.value) {
        final String value => _preferencesStore.writeString(entry.key, value),
        final bool value => _preferencesStore.writeBool(entry.key, value),
        _ => false,
      };
      if (!saved) {
        _logger.warning(
          tag: accountBackupLogTag,
          message: 'stage=restore_preference_degraded key=${entry.key}',
        );
      }
    }
  }

  /// 解压并严格校验不可信 `.pnbak`，只返回可以进入恢复事务的 SQLite 写入值。
  static _DecodedAccountBackup _decodeBackupArchive(
    Uint8List bytes, {
    required int expectedUserId,
  }) {
    final Archive archive = ZipDecoder().decodeBytes(bytes, verify: true);
    const Set<String> expectedFiles = <String>{
      'manifest.json',
      'bookshelf.json',
      'groups.json',
      'reading_history.json',
      'bookmarks.json',
      'annotations.json',
      'replace_rules.json',
      'preferences.json',
    };
    final Map<String, Uint8List> files = <String, Uint8List>{};
    int totalUncompressedBytes = 0;
    for (final ArchiveFile entry in archive) {
      if (!entry.isFile ||
          !expectedFiles.contains(entry.name) ||
          files.containsKey(entry.name) ||
          entry.size < 0 ||
          entry.size > _maximumBackupBytes) {
        throw const FormatException('备份压缩包包含不受支持的项目');
      }
      totalUncompressedBytes += entry.size;
      if (totalUncompressedBytes > _maximumBackupBytes * 2) {
        throw const FormatException('备份解压后超过安全大小限制');
      }
      final Uint8List? content = entry.readBytes();
      if (content == null || content.length != entry.size) {
        throw const FormatException('备份压缩项目读取失败');
      }
      files[entry.name] = content;
    }
    if (files.keys.toSet().difference(expectedFiles).isNotEmpty ||
        expectedFiles.difference(files.keys.toSet()).isNotEmpty) {
      throw const FormatException('备份文件集合不完整');
    }

    final Map<String, Object?> manifest = _decodeJsonObject(
      files['manifest.json'],
      fileName: 'manifest.json',
    );
    if (manifest['format'] != 'pagenest-account-backup' ||
        manifest['formatVersion'] != _formatVersion) {
      throw const FormatException('备份格式版本不受支持');
    }
    final Object? accountValue = manifest['account'];
    if (accountValue is! Map<Object?, Object?> ||
        accountValue['userId'] != expectedUserId) {
      throw const FormatException('备份不属于当前登录账号');
    }
    final Object? fileManifestValue = manifest['files'];
    if (fileManifestValue is! Map<Object?, Object?> ||
        fileManifestValue.length != expectedFiles.length - 1) {
      throw const FormatException('备份文件清单无效');
    }
    for (final String fileName in expectedFiles.where(
      (String value) => value != 'manifest.json',
    )) {
      final Object? metadataValue = fileManifestValue[fileName];
      final Uint8List? content = files[fileName];
      if (metadataValue is! Map<Object?, Object?> || content == null) {
        throw const FormatException('备份文件清单缺少项目');
      }
      if (metadataValue['byteSize'] != content.length ||
          metadataValue['sha256'] != sha256.convert(content).toString()) {
        throw const FormatException('备份内部文件完整性校验失败');
      }
    }

    final List<Map<String, Object?>> books = _decodeBooks(
      files['bookshelf.json'],
      fileName: 'bookshelf.json',
    );
    final List<Map<String, Object?>> groups = _decodeGroups(
      files['groups.json'],
    );
    final List<Map<String, Object?>> historyBooks = _decodeBooks(
      files['reading_history.json'],
      fileName: 'reading_history.json',
    );
    final List<Map<String, Object?>> bookmarks = _decodeBookmarks(
      files['bookmarks.json'],
    );
    final List<Map<String, Object?>> annotations = _decodeAnnotations(
      files['annotations.json'],
    );
    final List<Map<String, Object?>> replaceRules = _decodeReplaceRules(
      files['replace_rules.json'],
    );
    final Map<String, Object?> preferences = _decodePreferences(
      files['preferences.json'],
    );
    final Map<String, int> actualCounts = <String, int>{
      'books': books.length,
      'bookGroups': groups.length,
      'readingHistory': historyBooks.length,
      'bookmarks': bookmarks.length,
      'annotations': annotations.length,
      'replaceRules': replaceRules.length,
      'preferences': preferences.length,
    };
    final Object? countsValue = manifest['itemCounts'];
    if (countsValue is! Map<Object?, Object?> ||
        countsValue.length != actualCounts.length) {
      throw const FormatException('备份数据计数清单无效');
    }
    for (final MapEntry<String, int> entry in actualCounts.entries) {
      if (countsValue[entry.key] != entry.value) {
        throw const FormatException('备份数据计数与文件内容不一致');
      }
    }
    return _DecodedAccountBackup(
      books: books,
      groups: groups,
      historyBooks: historyBooks,
      bookmarks: bookmarks,
      annotations: annotations,
      replaceRules: replaceRules,
      preferences: preferences,
      itemCounts: actualCounts,
    );
  }

  /// 解码书架或历史书籍列表，并移除不能跨设备恢复的运行变量。
  static List<Map<String, Object?>> _decodeBooks(
    Uint8List? bytes, {
    required String fileName,
  }) {
    final List<Map<String, Object?>> values = _decodeJsonObjectList(
      bytes,
      fileName: fileName,
    );
    return values.map((Map<String, Object?> value) {
      if (value.containsKey('variable')) {
        throw const FormatException('备份书籍包含禁止恢复的运行变量');
      }
      final Book book = bookFromMap(value);
      if (book.origin == 'loc_book') {
        throw const FormatException('首版账号备份不支持本地书');
      }
      final Map<String, Object?> row = Map<String, Object?>.from(bookToMap(book));
      row['variable'] = null;
      final Object? customCoverUrl = row['customCoverUrl'];
      if (customCoverUrl is String && customCoverUrl.startsWith('legado-cover:')) {
        row['customCoverUrl'] = null;
      }
      return row;
    }).toList(growable: false);
  }

  /// 解码书架分组列表并转换为 SQLite 写入值。
  static List<Map<String, Object?>> _decodeGroups(Uint8List? bytes) {
    return _decodeJsonObjectList(bytes, fileName: 'groups.json')
        .map((Map<String, Object?> value) {
          final Map<String, Object?> row = Map<String, Object?>.from(
            bookGroupToMap(bookGroupFromMap(value)),
          );
          final Object? cover = row['cover'];
          if (cover is String && cover.startsWith('legado-cover:')) {
            row['cover'] = null;
          }
          return row;
        })
        .toList(growable: false);
  }

  /// 解码书签列表并转换为 SQLite 写入值。
  static List<Map<String, Object?>> _decodeBookmarks(Uint8List? bytes) {
    return _decodeJsonObjectList(bytes, fileName: 'bookmarks.json')
        .map((Map<String, Object?> value) => bookmarkToMap(bookmarkFromMap(value)))
        .toList(growable: false);
  }

  /// 解码替换规则，忽略备份中的本机自增主键。
  static List<Map<String, Object?>> _decodeReplaceRules(Uint8List? bytes) {
    return _decodeJsonObjectList(bytes, fileName: 'replace_rules.json')
        .map((Map<String, Object?> value) {
          final Map<String, Object?> row = Map<String, Object?>.from(value);
          row['id'] = 0;
          final Map<String, Object?> restored = Map<String, Object?>.from(
            replaceRuleToMap(replaceRuleFromMap(row)),
          );
          restored.remove('id');
          return restored;
        })
        .toList(growable: false);
  }

  /// 解码用户正文标注并生成 Android 兼容 SQLite 行。
  static List<Map<String, Object?>> _decodeAnnotations(Uint8List? bytes) {
    return _decodeJsonObjectList(bytes, fileName: 'annotations.json')
        .map((Map<String, Object?> value) {
          final String kindName = _requiredJsonString(value, 'kind');
          final BookContentProcessKind? kind =
              BookContentProcessKindStorage.fromStorageName(kindName);
          final Map<String, Object?> anchor = _requiredJsonMap(value, 'anchor');
          final Map<String, Object?> style = _requiredJsonMap(value, 'style');
          final int status = _requiredJsonInt(value, 'status');
          if (kind == null || status == BookContentProcess.deletedStatus) {
            throw const FormatException('备份正文标注类型或状态无效');
          }
          final int chapterIndex = _requiredJsonInt(value, 'chapterIndex');
          if (_requiredJsonInt(anchor, 'chapterIndex') != chapterIndex) {
            throw const FormatException('备份正文标注章节索引不一致');
          }
          return <String, Object?>{
            'id': _requiredJsonString(value, 'id'),
            'bookUrl': _requiredJsonString(value, 'bookUrl'),
            'chapterIndex': chapterIndex,
            'kind': kind.storageName,
            'stage': 'style',
            'target': 'selection',
            'anchorJson': jsonEncode(<String, Object?>{
              'chapterIndex': chapterIndex,
              'chapterPosition': _requiredJsonInt(anchor, 'chapterPosition'),
              'selectedText': _requiredJsonString(anchor, 'selectedText'),
              'contextBefore': _requiredJsonString(anchor, 'contextBefore', allowEmpty: true),
              'contextAfter': _requiredJsonString(anchor, 'contextAfter', allowEmpty: true),
              'normalizedTextHash': _requiredJsonString(anchor, 'normalizedTextHash'),
            }),
            'actionJson': jsonEncode(<String, Object?>{'type': 'style'}),
            'styleJson': jsonEncode(<String, Object?>{
              'bgColor': _optionalJsonInt(style, 'backgroundColorValue'),
              'underlineColor': _optionalJsonInt(style, 'underlineColorValue'),
              'underlineWidth': _requiredJsonNumber(style, 'underlineWidth'),
            }),
            'source': 'user',
            'aiArtifactId': null,
            'sourceContentHash': null,
            'enabled': _requiredJsonBool(value, 'enabled') ? 1 : 0,
            'sortOrder': _requiredJsonInt(value, 'sortOrder'),
            'status': status,
            'schemaVersion': 1,
            'createdAt': _requiredJsonInt(value, 'createdAt'),
            'updatedAt': _requiredJsonInt(value, 'updatedAt'),
          };
        })
        .toList(growable: false);
  }

  /// 解码固定白名单的小型偏好，不接受其他键或类型。
  static Map<String, Object?> _decodePreferences(Uint8List? bytes) {
    final Map<String, Object?> values = _decodeJsonObject(
      bytes,
      fileName: 'preferences.json',
    );
    const Set<String> stringKeys = <String>{
      'reader.display_config.v1',
      'bookshelf.layout_mode.v1',
      'reading_history.layout_mode.v1',
      'search.match_mode.v1',
    };
    const String boolKey = 'search.source_interaction.v1';
    for (final MapEntry<String, Object?> entry in values.entries) {
      if (stringKeys.contains(entry.key) && entry.value is String) {
        continue;
      }
      if (entry.key == boolKey && entry.value is bool) {
        continue;
      }
      throw const FormatException('备份偏好包含不受支持的键或类型');
    }
    return values;
  }

  /// 解码 UTF-8 JSON 对象。
  static Map<String, Object?> _decodeJsonObject(
    Uint8List? bytes, {
    required String fileName,
  }) {
    if (bytes == null) {
      throw FormatException('备份缺少 $fileName');
    }
    final Object? value = jsonDecode(utf8.decode(bytes));
    if (value is! Map<Object?, Object?>) {
      throw FormatException('备份文件 $fileName 不是 JSON 对象');
    }
    return _stringKeyedJsonMap(value, fileName: fileName);
  }

  /// 解码 UTF-8 JSON 对象列表，并限制记录数量。
  static List<Map<String, Object?>> _decodeJsonObjectList(
    Uint8List? bytes, {
    required String fileName,
  }) {
    if (bytes == null) {
      throw FormatException('备份缺少 $fileName');
    }
    final Object? value = jsonDecode(utf8.decode(bytes));
    if (value is! List<Object?> || value.length > 100000) {
      throw FormatException('备份文件 $fileName 列表无效');
    }
    return value.map((Object? item) {
      if (item is! Map<Object?, Object?>) {
        throw FormatException('备份文件 $fileName 包含非对象记录');
      }
      return _stringKeyedJsonMap(item, fileName: fileName);
    }).toList(growable: false);
  }

  /// 把动态 JSON Map 转换为字符串键 Map。
  static Map<String, Object?> _stringKeyedJsonMap(
    Map<Object?, Object?> value, {
    required String fileName,
  }) {
    final Map<String, Object?> result = <String, Object?>{};
    for (final MapEntry<Object?, Object?> entry in value.entries) {
      if (entry.key is! String) {
        throw FormatException('备份文件 $fileName 包含非字符串字段');
      }
      result[entry.key as String] = entry.value;
    }
    return result;
  }

  /// 读取 JSON 必填字符串字段。
  static String _requiredJsonString(
    Map<String, Object?> value,
    String key, {
    bool allowEmpty = false,
  }) {
    final Object? field = value[key];
    if (field is! String ||
        field.length > 1048576 ||
        (!allowEmpty && field.isEmpty)) {
      throw FormatException('备份字段 $key 无效');
    }
    return field;
  }

  /// 读取 JSON 必填整数字段。
  static int _requiredJsonInt(Map<String, Object?> value, String key) {
    final Object? field = value[key];
    if (field is! num || !field.isFinite || field.toInt() != field) {
      throw FormatException('备份字段 $key 无效');
    }
    return field.toInt();
  }

  /// 读取 JSON 可选整数字段。
  static int? _optionalJsonInt(Map<String, Object?> value, String key) {
    if (value[key] == null) {
      return null;
    }
    return _requiredJsonInt(value, key);
  }

  /// 读取 JSON 必填有限数值字段。
  static num _requiredJsonNumber(Map<String, Object?> value, String key) {
    final Object? field = value[key];
    if (field is! num || !field.isFinite) {
      throw FormatException('备份字段 $key 无效');
    }
    return field;
  }

  /// 读取 JSON 必填布尔字段。
  static bool _requiredJsonBool(Map<String, Object?> value, String key) {
    final Object? field = value[key];
    if (field is! bool) {
      throw FormatException('备份字段 $key 无效');
    }
    return field;
  }

  /// 读取 JSON 必填对象字段。
  static Map<String, Object?> _requiredJsonMap(
    Map<String, Object?> value,
    String key,
  ) {
    final Object? field = value[key];
    if (field is! Map<Object?, Object?>) {
      throw FormatException('备份字段 $key 无效');
    }
    return _stringKeyedJsonMap(field, fileName: key);
  }

  /// 在后台 Isolate 中完成大 JSON 编码、逐文件摘要和 ZIP 压缩。
  static Uint8List _encodeBackupArchive({
    required Map<String, List<Map<String, Object?>>> datasets,
    required Map<String, Object?> preferences,
    required Map<String, int> itemCounts,
    required String clientBackupId,
    required DateTime createdAt,
    required int userId,
    required String appVersionName,
    required int appVersionCode,
  }) {
    final Map<String, Uint8List> files = <String, Uint8List>{
      for (final MapEntry<String, List<Map<String, Object?>>> entry
          in datasets.entries)
        entry.key: Uint8List.fromList(utf8.encode(jsonEncode(entry.value))),
      'preferences.json': Uint8List.fromList(
        utf8.encode(jsonEncode(preferences)),
      ),
    };
    files['manifest.json'] = Uint8List.fromList(
      utf8.encode(jsonEncode(<String, Object?>{
        'format': 'pagenest-account-backup',
        'formatVersion': _formatVersion,
        'clientBackupId': clientBackupId,
        'createdAt': createdAt.toIso8601String(),
        'account': <String, Object?>{'userId': userId},
        'app': <String, Object?>{
          'versionName': appVersionName,
          'versionCode': appVersionCode,
          'databaseSchemaVersion': LegadoDatabase.schemaVersion,
        },
        'itemCounts': itemCounts,
        'files': <String, Object?>{
          for (final MapEntry<String, Uint8List> entry in files.entries)
            entry.key: <String, Object?>{
              'byteSize': entry.value.length,
              'sha256': sha256.convert(entry.value).toString(),
            },
        },
      })),
    );
    final Archive archive = Archive();
    for (final MapEntry<String, Uint8List> entry in files.entries) {
      archive.addFile(ArchiveFile.bytes(entry.key, entry.value));
    }
    return Uint8List.fromList(
      ZipEncoder().encodeBytes(archive, modified: createdAt),
    );
  }

  /// 使用安全随机数生成不依赖第三方包的 UUID v4。
  static String _newClientBackupId() {
    final List<int> bytes = List<int>.generate(
      16,
      (_) => Random.secure().nextInt(256),
    );
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final String hex = bytes
        .map((int value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }
}

/// 同一 SQLite 只读事务取得的账号备份业务快照。
final class _AccountBackupSnapshot {
  /// 创建事务内已经固定版本的数据集合。
  _AccountBackupSnapshot({
    required List<Book> shelfBooks,
    required List<Book> historyBooks,
    required List<BookGroup> groups,
    required List<Bookmark> bookmarks,
    required List<BookContentProcess> annotations,
    required List<ReplaceRule> replaceRules,
  }) : shelfBooks = List<Book>.unmodifiable(shelfBooks),
       historyBooks = List<Book>.unmodifiable(historyBooks),
       groups = List<BookGroup>.unmodifiable(groups),
       bookmarks = List<Bookmark>.unmodifiable(bookmarks),
       annotations = List<BookContentProcess>.unmodifiable(annotations),
       replaceRules = List<ReplaceRule>.unmodifiable(replaceRules);

  /// 书架书快照。
  final List<Book> shelfBooks;

  /// 阅读历史书快照。
  final List<Book> historyBooks;

  /// 书架分组快照。
  final List<BookGroup> groups;

  /// 书签快照。
  final List<Bookmark> bookmarks;

  /// 正文标注快照。
  final List<BookContentProcess> annotations;

  /// 替换规则快照。
  final List<ReplaceRule> replaceRules;
}

/// 已完成格式、哈希、类型和账号归属校验的恢复事务输入。
final class _DecodedAccountBackup {
  /// 创建只包含可安全写入值的恢复快照。
  _DecodedAccountBackup({
    required List<Map<String, Object?>> books,
    required List<Map<String, Object?>> groups,
    required List<Map<String, Object?>> historyBooks,
    required List<Map<String, Object?>> bookmarks,
    required List<Map<String, Object?>> annotations,
    required List<Map<String, Object?>> replaceRules,
    required Map<String, Object?> preferences,
    required Map<String, int> itemCounts,
  }) : books = List<Map<String, Object?>>.unmodifiable(books),
       groups = List<Map<String, Object?>>.unmodifiable(groups),
       historyBooks = List<Map<String, Object?>>.unmodifiable(historyBooks),
       bookmarks = List<Map<String, Object?>>.unmodifiable(bookmarks),
       annotations = List<Map<String, Object?>>.unmodifiable(annotations),
       replaceRules = List<Map<String, Object?>>.unmodifiable(replaceRules),
       preferences = Map<String, Object?>.unmodifiable(preferences),
       itemCounts = Map<String, int>.unmodifiable(itemCounts);

  /// 书架书 SQLite 行。
  final List<Map<String, Object?>> books;

  /// 书架分组 SQLite 行。
  final List<Map<String, Object?>> groups;

  /// 阅读历史书籍 SQLite 行。
  final List<Map<String, Object?>> historyBooks;

  /// 书签 SQLite 行。
  final List<Map<String, Object?>> bookmarks;

  /// 正文标注 SQLite 行。
  final List<Map<String, Object?>> annotations;

  /// 替换规则 SQLite 行。
  final List<Map<String, Object?>> replaceRules;

  /// 白名单小型偏好。
  final Map<String, Object?> preferences;

  /// 完成实际解析后的数据集计数。
  final Map<String, int> itemCounts;
}
