import '../../help/error/app_result.dart';
import '../gateway/bookshelf_gateway.dart';
import '../model/book.dart';
import 'use_case_guard.dart';

/// 字段级保存用户选择的书籍封面，避免页面旧快照覆盖阅读事实。
final class UpdateBookCustomCoverUseCase {
  /// 创建封面更新 UseCase。
  const UpdateBookCustomCoverUseCase(this._gateway);

  /// 书架持久化边界。
  final BookshelfGateway _gateway;

  /// 保存非空远程封面；传入空值时恢复书源默认封面。
  Future<AppResult<Book>> execute(String bookUrl, String? customCoverUrl) {
    if (bookUrl.trim().isEmpty) {
      return Future<AppResult<Book>>.value(
        validationFailure<Book>('书籍 URL 不能为空'),
      );
    }
    /// 清理后的自定义封面；空字符串与恢复默认封面使用同一持久化语义。
    final String normalizedCoverUrl = customCoverUrl?.trim() ?? '';
    return guardUseCase<Book>(
      () => _gateway.updateCustomCover(
        bookUrl,
        normalizedCoverUrl.isEmpty ? null : normalizedCoverUrl,
      ),
    );
  }
}
