import '../../help/error/app_result.dart';
import '../gateway/chapter_gateway.dart';
import '../model/book_chapter.dart';
import 'use_case_guard.dart';

/// 将解析完成的完整目录原子替换到本地数据库。
final class SaveBookChaptersUseCase {
  /// 创建目录保存 UseCase。
  const SaveBookChaptersUseCase(this._gateway);

  /// 章节持久化领域边界。
  final ChapterGateway _gateway;

  /// 校验章节归属和唯一键后整体替换目录；空列表表示明确清空目录。
  Future<AppResult<void>> execute(
    String bookUrl,
    List<BookChapter> chapters,
  ) {
    if (bookUrl.isEmpty) {
      return Future<AppResult<void>>.value(
        validationFailure<void>('书籍 URL 不能为空'),
      );
    }

    /// 本次完整目录已经出现的章节索引。
    final Set<int> chapterIndices = <int>{};
    /// 本次完整目录已经出现的 `(bookUrl, url)` 复合主键。
    final Set<(String, String)> chapterKeys = <(String, String)>{};
    for (final BookChapter chapter in chapters) {
      if (chapter.bookUrl != bookUrl) {
        return Future<AppResult<void>>.value(
          validationFailure<void>('章节所属书籍与目标书籍不一致'),
        );
      }
      if (!chapterIndices.add(chapter.index)) {
        return Future<AppResult<void>>.value(
          validationFailure<void>('同一本书的章节索引不能重复'),
        );
      }
      /// 与数据库章节复合主键对应的类型安全记录。
      final (String, String) chapterKey = (chapter.bookUrl, chapter.url);
      if (!chapterKeys.add(chapterKey)) {
        return Future<AppResult<void>>.value(
          validationFailure<void>('同一本书的章节 URL 不能重复'),
        );
      }
    }
    return guardUseCase<void>(
      () => _gateway.replaceChapterList(bookUrl, chapters),
    );
  }
}
