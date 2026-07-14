import '../../help/error/app_result.dart';
import '../gateway/reading_progress_gateway.dart';
import '../model/reading_progress.dart';
import 'use_case_guard.dart';

/// 保存阅读章节和字符位置，对应 Android `BookDao.upProgress` 及完整进度更新调用点。
final class SaveReadingProgressUseCase {
  /// 创建阅读进度保存 UseCase。
  const SaveReadingProgressUseCase(this._gateway);

  /// 阅读进度领域边界。
  final ReadingProgressGateway _gateway;

  /// 校验非负章节位置和毫秒时间戳后保存；成功值表示目标书籍是否存在。
  Future<AppResult<bool>> execute(ReadingProgress progress) {
    if (progress.bookUrl.isEmpty) {
      return Future<AppResult<bool>>.value(
        validationFailure<bool>('书籍 URL 不能为空'),
      );
    }
    if (progress.chapterIndex < 0 || progress.chapterPos < 0) {
      return Future<AppResult<bool>>.value(
        validationFailure<bool>('阅读章节和字符位置不能为负数'),
      );
    }
    if (progress.readTime < 0 || progress.syncTime < 0) {
      return Future<AppResult<bool>>.value(
        validationFailure<bool>('阅读时间和同步时间必须是非负毫秒时间戳'),
      );
    }
    return guardUseCase<bool>(() => _gateway.saveProgress(progress));
  }
}
