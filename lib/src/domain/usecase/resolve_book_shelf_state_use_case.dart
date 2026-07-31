import '../../help/error/app_result.dart';
import '../gateway/bookshelf_gateway.dart';
import '../model/book.dart';
import '../model/book_shelf_state.dart';
import 'use_case_guard.dart';

/// 判断精确入架、同名冲突和未入架状态。
final class ResolveBookShelfStateUseCase {
  /// 创建书架状态解析 UseCase。
  const ResolveBookShelfStateUseCase(this._gateway);

  /// 提供精确主键和同名查询的数据边界。
  final BookshelfGateway _gateway;

  /// 保持书名精确匹配，不执行 trim、大小写或模糊归一化。
  Future<AppResult<ResolvedBookShelfState>> execute(Book book) async {
    /// 精确 URL 查询结果。
    final AppResult<Book?> exactResult = await guardUseCase<Book?>(
      () => _gateway.getBook(book.bookUrl),
    );
    switch (exactResult) {
      case AppFailure<Book?>(error: final error):
        return AppFailure<ResolvedBookShelfState>(error);
      case AppSuccess<Book?>(value: final Book? exactBook):
        if (exactBook != null) {
          return AppSuccess<ResolvedBookShelfState>(
            ResolvedBookShelfState(
              state: BookShelfState.inShelf,
              existingBook: exactBook,
            ),
          );
        }
    }

    /// 同名查询结果，仅在精确 URL 未命中后执行。
    final AppResult<Book?> conflictResult = await guardUseCase<Book?>(
      () => _gateway.getShelfBookNameConflict(book.name),
    );
    return switch (conflictResult) {
      AppFailure<Book?>(error: final error) =>
        AppFailure<ResolvedBookShelfState>(error),
      AppSuccess<Book?>(value: final Book? conflict) =>
        AppSuccess<ResolvedBookShelfState>(
          ResolvedBookShelfState(
            state: conflict == null
                ? BookShelfState.notInShelf
                : BookShelfState.sameName,
            existingBook: conflict,
          ),
        ),
    };
  }
}
