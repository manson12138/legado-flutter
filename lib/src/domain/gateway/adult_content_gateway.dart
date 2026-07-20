/// 成人内容屏蔽领域边界，供搜索、换源和书源导入复用同一套判定逻辑。
///
/// 对应 Android `help.AdultContentFilter`；默认屏蔽开启，判定粒度到“书籍”和
/// “书源”两级，Flutter 端另外增加基于域名黑名单的书源判定。
abstract interface class AdultContentGateway {
  /// 是否启用成人内容屏蔽；默认开启。
  Future<bool> isBlockingEnabled();

  /// 修改是否启用成人内容屏蔽。
  Future<void> setBlockingEnabled(bool enabled);

  /// 当前生效关键词数量，供“关于”页展示。
  Future<int> keywordCount();

  /// 判定一本搜索结果或书架书是否为成人内容；命中书名/作者/分类/简介任意关键词即真。
  Future<bool> isAdultBook({
    required String name,
    String? author,
    String? kind,
    String? intro,
  });

  /// 判定一个书源是否为成人书源；命中分组标签“成人”、名称/分组/备注关键词，
  /// 或书源地址落在域名黑名单即真。
  Future<bool> isAdultSource({
    required String name,
    String? group,
    String? comment,
    String? url,
  });

  /// 从远程拉取最新词库并落地缓存，成功后立即生效，返回新词条数量。
  Future<int> updateFromRemote();
}
