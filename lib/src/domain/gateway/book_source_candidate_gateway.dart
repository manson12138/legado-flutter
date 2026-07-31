import '../model/search_book.dart';

/// 保存搜索 Cell 命中的完整书源候选，并供所有非搜索详情入口只读恢复。
abstract interface class BookSourceCandidateGateway {
  /// 按严格书名和作者读取上一次由搜索入口确认的候选快照。
  Future<List<SearchBook>> load(String name, String author);

  /// 使用一次搜索 Cell 点击携带的完整候选组原子覆盖同名同作者旧快照。
  Future<void> replaceFromSearch(List<SearchBook> books);
}
