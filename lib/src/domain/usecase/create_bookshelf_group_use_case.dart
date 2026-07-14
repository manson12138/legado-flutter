import '../../help/error/app_result.dart';
import '../gateway/book_group_gateway.dart';
import '../model/book_group.dart';
import 'use_case_guard.dart';

/// 校验并创建用户书架分组。
final class CreateBookshelfGroupUseCase {
  /// 创建分组 UseCase。
  const CreateBookshelfGroupUseCase(this._gateway);

  /// 分组持久化边界。
  final BookGroupGateway _gateway;

  /// 创建非空名称分组，并返回分配的正数位值 ID。
  Future<AppResult<BookGroup>> execute(String name) {
    /// 去除首尾空白后的名称。
    final String normalized = name.trim();
    if (normalized.isEmpty) {
      return Future<AppResult<BookGroup>>.value(
        validationFailure<BookGroup>('分组名称不能为空'),
      );
    }
    return guardUseCase<BookGroup>(() => _gateway.createGroup(normalized));
  }
}
