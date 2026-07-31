import '../../domain/gateway/book_source_candidate_gateway.dart';
import '../../domain/model/search_book.dart';
import '../../help/error/app_error.dart';
import '../dao/book_source_candidate_dao.dart';
import '../local/data_error.dart';

/// 使用 SQLite 保存搜索确认的详情书源候选，并隔离具体数据库实现。
final class BookSourceCandidateRepository
    implements BookSourceCandidateGateway {
  /// 创建候选 Repository。
  const BookSourceCandidateRepository(this._dao);

  /// 候选持久化 DAO。
  final BookSourceCandidateDao _dao;

  /// 读取严格书名作者对应的不可变候选列表。
  @override
  Future<List<SearchBook>> load(String name, String author) {
    return guardDataOperation<List<SearchBook>>(() async {
      if (name.isEmpty || author.isEmpty) {
        return const <SearchBook>[];
      }
      /// 数据库按搜索点击顺序返回的候选。
      final List<SearchBook> books = await _dao.loadByNameAuthor(
        name,
        author,
      );
      return List<SearchBook>.unmodifiable(books);
    });
  }

  /// 校验候选身份一致后原子覆盖旧组。
  @override
  Future<void> replaceFromSearch(List<SearchBook> books) {
    return guardDataOperation<void>(() async {
      if (books.isEmpty) {
        throw const AppError(
          kind: AppErrorKind.validation,
          message: '搜索书源候选不能为空',
        );
      }
      /// 本次候选组的严格书名。
      final String name = books.first.name;
      /// 本次候选组的严格作者。
      final String author = books.first.author;
      if (name.isEmpty || author.isEmpty) {
        throw const AppError(
          kind: AppErrorKind.validation,
          message: '搜索书源候选缺少书名或作者',
        );
      }
      /// 候选是否全部属于同一个严格书名作者分组。
      final bool sameIdentity = books.every(
        (SearchBook book) => book.name == name && book.author == author,
      );
      if (!sameIdentity) {
        throw const AppError(
          kind: AppErrorKind.validation,
          message: '搜索书源候选不属于同一本书',
        );
      }
      await _dao.replaceByNameAuthor(name, author, books);
    });
  }
}
