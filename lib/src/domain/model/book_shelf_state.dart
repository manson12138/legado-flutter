import 'book.dart';

/// 表示候选书籍与当前用户书架之间的匹配状态。
enum BookShelfState {
  /// 当前用户书架中已经存在相同书籍 URL。
  inShelf,

  /// 书名一致，但书籍 URL 来自另一个来源。
  sameName,

  /// 书架中没有精确记录或同名记录。
  notInShelf,
}

/// 保存书架匹配状态和命中的现有书籍。
final class ResolvedBookShelfState {
  /// 创建不可变书架匹配结果。
  const ResolvedBookShelfState({required this.state, this.existingBook});

  /// 当前候选书籍的三态匹配结论。
  final BookShelfState state;

  /// 精确命中或同名命中的现有书籍；未命中时为空。
  final Book? existingBook;
}
