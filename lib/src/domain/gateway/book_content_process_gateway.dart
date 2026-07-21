import '../model/book_content_process.dart';

/// 定义用户正文高亮与下划线的持久化边界，对应 Android `BookContentProcessGateway`。
abstract interface class BookContentProcessGateway {
  /// 观察一本书指定章节的全部未软删除标注。
  Stream<List<BookContentProcess>> watchForChapter(
    String bookUrl,
    int chapterIndex,
  );

  /// 读取一本书下一个稳定标注排序值。
  Future<int> nextOrder(String bookUrl);

  /// 新增或替换一条正文标注。
  Future<void> upsert(BookContentProcess process);

  /// 启用或停用一条正文标注。
  Future<void> setEnabled(String id, bool enabled);

  /// 将一条正文标注标记为已删除。
  Future<void> delete(String id);
}
