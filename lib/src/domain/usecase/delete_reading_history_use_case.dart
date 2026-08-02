import '../../help/error/app_result.dart';
import '../gateway/reading_history_gateway.dart';
import 'use_case_guard.dart';

/// 在用户确认后批量删除阅读历史成员及其级联目录快照。
final class DeleteReadingHistoryUseCase {
  /// 创建阅读历史批量删除动作。
  const DeleteReadingHistoryUseCase(this._gateway);

  /// 与书架成员资格独立的阅读历史事务边界。
  final ReadingHistoryGateway _gateway;

  /// 删除稳定 URL 集合；空集合直接返回可展示的校验失败。
  Future<AppResult<void>> execute(Set<String> bookUrls) {
    if (bookUrls.isEmpty) {
      return Future<AppResult<void>>.value(
        validationFailure<void>('未选择需要删除的阅读历史'),
      );
    }
    return guardUseCase<void>(() => _gateway.deleteHistory(bookUrls));
  }
}
