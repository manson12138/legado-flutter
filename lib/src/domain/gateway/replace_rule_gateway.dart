import '../model/replace_rule.dart';

/// 定义正文替换规则读取边界，正文协调器不依赖 SQLite DAO。
abstract interface class ReplaceRuleGateway {
  /// 读取适用于指定书名或书源的已启用正文规则。
  Future<List<ReplaceRule>> getEnabledContentRules(String bookName, String origin);
}
