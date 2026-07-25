import '../data/dao/cache_dao.dart';
import '../domain/model/cache.dart';
import '../ui/bookshelf/bookshelf_contract.dart';
import '../ui/bookshelf/reading_history_contract.dart';

/// 持久化书架与阅读历史页面的显示布局；只保存枚举值，不保存书籍或用户内容。
final class BookshelfLayoutPreferences {
  /// 创建复用通用缓存表的页面布局偏好服务。
  const BookshelfLayoutPreferences(this._cacheDao);

  /// 通用缓存 DAO，使用无过期记录保存用户界面偏好。
  final CacheDao _cacheDao;

  /// 书架布局的稳定缓存键。
  static const String _bookshelfLayoutCacheKey = 'bookshelf_layout_mode';
  /// 阅读历史布局的稳定缓存键。
  static const String _readingHistoryLayoutCacheKey =
      'reading_history_layout_mode';

  /// 读取书架布局；缺失或旧值时保持默认网格布局。
  Future<BookshelfLayoutMode> readBookshelfLayout() async {
    final String? value =
        (await _cacheDao.get(_bookshelfLayoutCacheKey))?.value;
    return switch (value) {
      'list' => BookshelfLayoutMode.list,
      _ => BookshelfLayoutMode.grid,
    };
  }

  /// 保存书架布局，供下次创建书架页面时恢复。
  Future<void> saveBookshelfLayout(BookshelfLayoutMode layoutMode) {
    return _cacheDao.upsert(Cache(
      key: _bookshelfLayoutCacheKey,
      value: layoutMode.name,
    ));
  }

  /// 读取阅读历史布局；缺失或旧值时保持与书架一致的默认网格布局。
  Future<ReadingHistoryLayoutMode> readReadingHistoryLayout() async {
    final String? value =
        (await _cacheDao.get(_readingHistoryLayoutCacheKey))?.value;
    return switch (value) {
      'grid' => ReadingHistoryLayoutMode.grid,
      _ => ReadingHistoryLayoutMode.grid,
    };
  }

  /// 保存阅读历史布局，供下次创建历史页面时恢复。
  Future<void> saveReadingHistoryLayout(ReadingHistoryLayoutMode layoutMode) {
    return _cacheDao.upsert(Cache(
      key: _readingHistoryLayoutCacheKey,
      value: layoutMode.name,
    ));
  }
}
