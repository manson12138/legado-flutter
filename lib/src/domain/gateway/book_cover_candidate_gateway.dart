import '../model/search_book.dart';

/// 隔离封面搜索使用的派生候选缓存，避免 UI 直接访问 `searchBooks`。
abstract interface class BookCoverCandidateGateway {
  /// 读取目标书名附近、属于当前可见启用书源的非空封面候选。
  Future<List<SearchBook>> loadCandidates({
    required String bookName,
    required Set<String> enabledSourceUrls,
    int limit = 200,
  });

  /// 缓存实时搜索已经接受的非空封面候选。
  Future<void> saveCandidates(List<SearchBook> books);
}
