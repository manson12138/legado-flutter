/// 定义搜索历史持久化边界，页面和 ViewModel 不直接访问缓存 DAO。
abstract interface class SearchHistoryGateway {
  /// 读取按最近使用时间倒序排列的关键字。
  Future<List<String>> load();

  /// 把关键字移动到历史首位并限制保存数量。
  Future<List<String>> record(String keyword);

  /// 清空全部搜索历史。
  Future<void> clear();
}

