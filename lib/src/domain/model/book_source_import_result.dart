/// 书源导入遇到同 URL 记录时采用的冲突策略。
enum BookSourceConflictPolicy {
  /// 使用导入记录覆盖数据库中的同 URL 书源。
  overwrite,

  /// 保留数据库中的同 URL 书源并跳过导入记录。
  skip,
}

/// 单条书源导入失败的安全摘要。
final class BookSourceImportIssue {
  /// 创建不包含原始 JSON、Cookie 或脚本正文的失败摘要。
  const BookSourceImportIssue({required this.index, required this.message});

  /// 当前条目在外部数组中的零基索引。
  final int index;

  /// 可以展示给用户的字段校验说明。
  final String message;
}

/// 一次书源导入的完整统计结果。
final class BookSourceImportResult {
  /// 创建不可变导入结果。
  BookSourceImportResult({
    required this.total,
    required this.added,
    required this.overwritten,
    required this.skipped,
    required this.invalid,
    List<BookSourceImportIssue> issues = const <BookSourceImportIssue>[],
  }) : issues = List<BookSourceImportIssue>.unmodifiable(issues);

  /// 外部输入中的书源条目总数。
  final int total;

  /// 数据库中原本不存在并成功新增的数量。
  final int added;

  /// 按覆盖策略成功替换的数量。
  final int overwritten;

  /// 因冲突策略或同批重复 URL 而跳过的数量。
  final int skipped;

  /// 无法转换为有效书源的数量。
  final int invalid;

  /// 每条无效记录的安全错误摘要。
  final List<BookSourceImportIssue> issues;

  /// 实际写入数据库的书源数量。
  int get imported => added + overwritten;
}
