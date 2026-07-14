import 'dart:convert';

import '../../domain/gateway/search_history_gateway.dart';
import '../../domain/model/cache.dart';
import '../dao/cache_dao.dart';

/// 使用通用缓存表保存搜索历史，避免为 M06 引入仅单表使用的新数据库版本。
final class SearchHistoryRepository implements SearchHistoryGateway {
  /// 创建搜索历史 Repository。
  const SearchHistoryRepository(this._cacheDao);

  /// 通用缓存 DAO，只在数据层持有。
  final CacheDao _cacheDao;

  /// Android 兼容搜索历史缓存键。
  static const String _cacheKey = 'flutter_m06_search_history';

  /// 最多保留的历史数量。
  static const int _maximumCount = 20;

  @override
  Future<List<String>> load() async {
    /// 缓存中的 JSON 文本。
    final String? raw = (await _cacheDao.get(_cacheKey))?.value;
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
    /// 可修改的已有历史。
    final List<String> history = List<String>.from(await load());
    history.removeWhere((String value) => value == normalized);
    history.insert(0, normalized);
    if (history.length > _maximumCount) {
      history.removeRange(_maximumCount, history.length);
    }
    await _cacheDao.upsert(Cache(key: _cacheKey, value: jsonEncode(history)));
    return List<String>.unmodifiable(history);
  }

  @override
  Future<void> clear() => _cacheDao.delete(_cacheKey);
}
