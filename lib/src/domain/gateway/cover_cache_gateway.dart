/// 定义跨页面“已知可显示封面地址”缓存的持久化边界。
///
/// 键是书名 + 作者，语义上和搜索候选分组、书签的“同一本书”判定口径一致；实现方决定
/// 具体存储位置，UI 层只通过本接口读写，不直接接触数据库。
abstract interface class CoverCacheGateway {
  /// 查找同一本书之前在任意页面成功显示过的封面地址；未命中返回 null。
  Future<String?> getCoverUrl(String name, String author);

  /// 记录一次成功加载的封面地址，覆盖同一本书之前记住的旧地址。
  Future<void> saveCoverUrl(String name, String author, String url);
}
