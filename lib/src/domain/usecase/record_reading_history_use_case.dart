import '../../help/error/app_result.dart';
import '../gateway/reading_history_gateway.dart';
import '../model/book.dart';
import '../model/book_chapter.dart';
import 'use_case_guard.dart';

/// 在首次成功阅读后原子记录书籍和目录历史快照。
final class RecordReadingHistoryUseCase {
  /// 创建记录阅读历史 UseCase。
  const RecordReadingHistoryUseCase(this._gateway);

  /// 阅读历史领域边界。
  final ReadingHistoryGateway _gateway;

  /// 校验书籍与目录归属后写入幂等快照。
  Future<AppResult<void>> execute(
    Book book,
    List<BookChapter> chapters,
  ) {
    if (book.bookUrl.isEmpty) {
      return Future<AppResult<void>>.value(
        validationFailure<void>('阅读历史书籍 URL 不能为空'),
      );
    }
    if (chapters.isEmpty ||
        chapters.any((BookChapter chapter) => chapter.bookUrl != book.bookUrl)) {
      return Future<AppResult<void>>.value(
        validationFailure<void>('阅读历史目录为空或不属于当前书籍'),
      );
    }
    return guardUseCase<void>(() => _gateway.recordHistory(book, chapters));
  }
}
