import 'dart:async';
import 'dart:convert';

import '../../domain/gateway/search_history_gateway.dart';
import '../../domain/model/cache.dart';
import '../dao/cache_dao.dart';

/// 使用通用缓存表保存搜索历史，避免为 M06 引入仅单表使用的新数据库版本。
final class SearchHistoryRepository implements SearchHistoryGateway {
  /// 创建搜索历史 Repository。
  SearchHistoryRepository(this._cacheDao, this._requireUserId);

  /// 通用缓存 DAO，只在数据层持有。
  final CacheDao _cacheDao;

  /// 返回当前认证用户 ID；未登录访问不能回退到设备公共搜索历史。
  final int Function() _requireUserId;

  /// 升级前所有账号共用的旧搜索历史缓存键，仅用于一次性删除。
  static const String _legacyCacheKey = 'flutter_m06_search_history';

  /// 用户级搜索历史缓存键前缀；末尾拼接稳定整数用户 ID。
  static const String _userCacheKeyPrefix =
      'flutter_m06_search_history_user_v1_';

  /// 最多保留的历史数量。
  static const int _maximumCount = 20;

  /// 串行化搜索历史读改写的尾任务，避免快速连续搜索发生丢失更新。
  Future<void> _operationTail = Future<void>.value();

  /// 删除旧设备级历史的单飞任务；旧记录不认领给任何登录用户。
  Future<void>? _legacyCleanupFuture;

  @override
  Future<List<String>> load() {
    /// 本次调用入口捕获的用户缓存键，账号切换后仍保持不变。
    final String cacheKey = _currentUserCacheKey();
    return _enqueue<List<String>>(() async {
      await _cleanupLegacyHistory();
      return _loadByKey(cacheKey);
    });
  }

  /// 从已经捕获的用户缓存键读取并校验历史 JSON。
  Future<List<String>> _loadByKey(String cacheKey) async {
    /// 缓存中的 JSON 文本。
    final String? raw = (await _cacheDao.get(cacheKey))?.value;
    if (raw == null || raw.trim().isEmpty) {
      return const <String>[];
    }
    try {
      /// 未经信任的 JSON 值。
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List<Object?>) {
        return const <String>[];
      }
      return List<String>.unmodifiable(
        decoded.whereType<String>().map((String value) => value.trim()).where(
          (String value) => value.isNotEmpty,
        ),
      );
    } on FormatException {
      return const <String>[];
    }
  }

  @override
  Future<List<String>> record(String keyword) async {
    /// 规范化后的关键字，空关键字不写入历史。
    final String normalized = keyword.trim();
    if (normalized.isEmpty) {
      return load();
    }
    /// 本次读改写入口捕获的用户缓存键，异步等待后不重新读取当前账号。
    final String cacheKey = _currentUserCacheKey();
    return _enqueue<List<String>>(() async {
      await _cleanupLegacyHistory();
      /// 可修改的当前用户已有历史。
      final List<String> history = List<String>.from(
        await _loadByKey(cacheKey),
      );
      history.removeWhere((String value) => value == normalized);
      history.insert(0, normalized);
      if (history.length > _maximumCount) {
        history.removeRange(_maximumCount, history.length);
      }
      await _cacheDao.upsert(
        Cache(key: cacheKey, value: jsonEncode(history)),
      );
      return List<String>.unmodifiable(history);
    });
  }

  @override
  Future<void> clear() {
    /// 清空操作只删除入口时当前用户的缓存键。
    final String cacheKey = _currentUserCacheKey();
    return _enqueue<void>(() async {
      await _cleanupLegacyHistory();
      await _cacheDao.delete(cacheKey);
    });
  }

  /// 根据当前认证用户生成稳定缓存键；不包含用户名、Token 或搜索词。
  String _currentUserCacheKey() {
    final int userId = _requireUserId();
    return '$_userCacheKeyPrefix$userId';
  }

  /// 单飞删除无法确认归属的旧设备级搜索历史。
  Future<void> _cleanupLegacyHistory() {
    final Future<void>? existing = _legacyCleanupFuture;
    if (existing != null) {
      return existing;
    }
    final Future<void> cleanup = _deleteLegacyHistory();
    _legacyCleanupFuture = cleanup;
    return cleanup;
  }

  /// 删除失败时清除单飞句柄，使后续搜索历史访问可以重试清理。
  Future<void> _deleteLegacyHistory() async {
    try {
      await _cacheDao.delete(_legacyCacheKey);
    } on Object {
      _legacyCleanupFuture = null;
      rethrow;
    }
  }

  /// 将读取、记录和清空放入同一有界尾队列，并把结果返回原调用方。
  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final Completer<T> completer = Completer<T>();
    _operationTail = _operationTail.then<void>((_) async {
      try {
        completer.complete(await operation());
      } on Object catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
}
