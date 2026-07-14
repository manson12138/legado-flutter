import '../../help/error/app_result.dart';
import '../gateway/chapter_gateway.dart';
import '../model/book_chapter.dart';
import 'use_case_guard.dart';

/// 读取一本书的持久化目录。
final class LoadBookChaptersUseCase {
  /// 创建目录读取 UseCase。
  const LoadBookChaptersUseCase(this._gateway);

  /// 章节数据领域边界。
  final ChapterGateway _gateway;

  /// 校验书籍 URL 后按索引升序读取目录。
  Future<AppResult<List<BookChapter>>> execute(String bookUrl) {
    if (bookUrl.isEmpty) {
      return Future<AppResult<List<BookChapter>>>.value(
        validationFailure<List<BookChapter>>('书籍 URL 不能为空'),
      );
    }
    return guardUseCase<List<BookChapter>>(
      () => _gateway.getChapterList(bookUrl),
    );
  }
}
