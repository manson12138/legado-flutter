import '../../help/error/app_result.dart';
import '../gateway/bookshelf_gateway.dart';
import 'use_case_guard.dart';

/// 在确认后批量删除书架书籍及其级联目录。
final class DeleteBooksFromBookshelfUseCase {
  /// 创建批量删除 UseCase。
  const DeleteBooksFromBookshelfUseCase(this._gateway);

  /// 书架事务边界。
  final BookshelfGateway _gateway;

  /// 删除稳定 URL 集合；空集合直接返回校验失败。
  Future<AppResult<void>> execute(Set<String> bookUrls) {
    if (bookUrls.isEmpty) {
      return Future<AppResult<void>>.value(
        validationFailure<void>('未选择需要删除的书籍'),
      );
    }
    return guardUseCase<void>(() => _gateway.deleteBooks(bookUrls));
  }
}
