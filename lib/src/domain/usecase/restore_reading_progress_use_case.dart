import '../../help/error/app_result.dart';
import '../gateway/reading_progress_gateway.dart';
import '../model/reading_progress.dart';
import 'use_case_guard.dart';

/// 恢复一本书最后保存的阅读位置。
final class RestoreReadingProgressUseCase {
  /// 创建阅读进度恢复 UseCase。
  const RestoreReadingProgressUseCase(this._gateway);

  /// 阅读进度领域边界。
  final ReadingProgressGateway _gateway;

  /// 校验书籍 URL 后恢复进度；书籍不存在时成功值为 null。
  Future<AppResult<ReadingProgress?>> execute(String bookUrl) {
    if (bookUrl.isEmpty) {
      return Future<AppResult<ReadingProgress?>>.value(
        validationFailure<ReadingProgress?>('书籍 URL 不能为空'),
      );
    }
    return guardUseCase<ReadingProgress?>(
      () => _gateway.restoreProgress(bookUrl),
    );
  }
}
