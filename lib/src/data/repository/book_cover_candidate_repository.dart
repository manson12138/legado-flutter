import '../../domain/gateway/book_cover_candidate_gateway.dart';
import '../../domain/model/search_book.dart';
import '../dao/search_book_dao.dart';
import '../local/data_error.dart';

/// 使用现有 `searchBooks` 表保存和读取封面搜索派生候选。
final class BookCoverCandidateRepository
    implements BookCoverCandidateGateway {
  /// 创建封面候选缓存 Repository。
  const BookCoverCandidateRepository(this._dao);

  /// 搜索结果缓存 DAO。
  final SearchBookDao _dao;

  /// 限量读取候选，并再次按成人内容过滤后的启用书源快照收紧范围。
  @override
  Future<List<SearchBook>> loadCandidates({
    required String bookName,
    required Set<String> enabledSourceUrls,
    int limit = 200,
  }) {
    return guardDataOperation<List<SearchBook>>(() async {
      if (bookName.trim().isEmpty || enabledSourceUrls.isEmpty) {
        return const <SearchBook>[];
      }
      /// SQLite 预过滤后的最近候选。
      final List<SearchBook> candidates = await _dao.loadCoverCandidates(
        bookName.trim(),
        limit: limit,
      );
      return List<SearchBook>.unmodifiable(
        candidates.where(
          (SearchBook book) =>
              enabledSourceUrls.contains(book.origin) &&
              (book.coverUrl?.trim().isNotEmpty ?? false),
        ),
      );
    });
  }

  /// 批量写入已经通过封面非空和三级书名规则的候选。
  @override
  Future<void> saveCandidates(List<SearchBook> books) {
    return guardDataOperation<void>(() => _dao.upsertAll(books));
  }
}
