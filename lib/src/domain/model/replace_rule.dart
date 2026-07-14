/// 表示正文或标题净化规则，对应 Android `data.entities.ReplaceRule`。
final class ReplaceRule {
  /// 创建不可变替换规则；[id] 为 `null` 时由 SQLite 自增主键生成。
  const ReplaceRule({
    this.id,
    this.name = '',
    this.group,
    this.pattern = '',
    this.replacement = '',
    this.scope,
    this.scopeTitle = false,
    this.scopeContent = true,
    this.excludeScope,
    this.isEnabled = true,
    this.isRegex = true,
    this.timeoutMillisecond = 3000,
    this.order = 0,
  });

  /// SQLite 自增主键；未入库的新规则为 `null`。
  final int? id;
  /// 规则名称。
  final String name;
  /// 规则分组文本。
  final String? group;
  /// 待匹配的普通文本或正则表达式。
  final String pattern;
  /// 替换结果文本。
  final String replacement;
  /// 适用书名或书源范围文本。
  final String? scope;
  /// 是否应用于章节标题。
  final bool scopeTitle;
  /// 是否应用于正文。
  final bool scopeContent;
  /// 排除的书名或书源范围文本。
  final String? excludeScope;
  /// 是否启用规则。
  final bool isEnabled;
  /// 是否将 [pattern] 作为正则表达式。
  final bool isRegex;
  /// 单次正则替换超时时间，单位毫秒。
  final int timeoutMillisecond;
  /// 数据库列名为 `sortOrder` 的手动排序值。
  final int order;
}
