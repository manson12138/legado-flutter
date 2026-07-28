import '../model/replace_rule.dart';

/// 定义正文替换规则读取边界，正文协调器不依赖 SQLite DAO。
abstract interface class ReplaceRuleGateway {
  /// 返回替换规则表最近一次提交修订，用于使处理后正文缓存身份失效。
  int get contentRevision;

  /// 读取适用于指定书名或书源的已启用正文规则。
  Future<List<ReplaceRule>> getEnabledContentRules(String bookName, String origin);
}
