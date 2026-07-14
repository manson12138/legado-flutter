import '../../help/error/app_result.dart';
import '../gateway/bookshelf_gateway.dart';
import 'use_case_guard.dart';

/// 批量替换书籍用户分组，避免页面直接修改实体位掩码。
final class ReplaceBooksGroupUseCase {
  /// 创建分组替换 UseCase。
  const ReplaceBooksGroupUseCase(this._gateway);

  /// 书架事务边界。
  final BookshelfGateway _gateway;

  /// 把所选书籍移动到正数用户分组；非正数表示清除用户分组。
  Future<AppResult<void>> execute(Set<String> bookUrls, int groupId) {
    if (bookUrls.isEmpty) {
      return Future<AppResult<void>>.value(
        validationFailure<void>('未选择需要设置分组的书籍'),
      );
    }
    return guardUseCase<void>(() => _gateway.replaceBooksGroup(bookUrls, groupId));
  }
}
