/// 跨页面共享的“已知可显示封面地址”内存缓存，只服务渲染层的展示回退，不写数据库。
///
/// 键使用书名 + 作者，和搜索候选分组、书签等既有“同一本书”判定口径保持一致——
/// 单用书名容易在不同作者的同名书之间互相顶替封面，必须搭配作者一起做 key。
/// 应用重启后清空；单个进程生命周期内足够覆盖“搜索页发现可用封面后，详情页/书架
/// 也能沿用”这一类跨页面场景。
final class CoverUrlCache {
  CoverUrlCache._();

  /// 全局唯一实例，供 [BookCover] 直接使用，不需要经由依赖注入传递。
  static final CoverUrlCache instance = CoverUrlCache._();

  /// 按 `书名|作者` 保存的最近一次成功加载地址。
  final Map<String, String> _knownGoodUrls = <String, String>{};

  /// 生成稳定缓存键；书名和作者都先去除首尾空白，避免格式差异导致命中失败。
  String _key(String name, String author) => '${name.trim()}|${author.trim()}';

  /// 查找同一本书之前在任意页面成功显示过的封面地址。
  String? lookup({required String name, required String author}) {
    if (name.trim().isEmpty) {
      return null;
    }
    return _knownGoodUrls[_key(name, author)];
  }

  /// 记录一次成功加载的封面地址，覆盖同一本书之前记住的旧地址。
  void remember({required String name, required String author, required String url}) {
    /// 清理后的地址。
    final String trimmedUrl = url.trim();
    if (name.trim().isEmpty || trimmedUrl.isEmpty) {
      return;
    }
    _knownGoodUrls[_key(name, author)] = trimmedUrl;
  }
}
