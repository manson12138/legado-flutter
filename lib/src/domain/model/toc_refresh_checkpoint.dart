/// 保存一本用户级网络书目录增量更新所需的稳定检查点。
///
/// 检查点只用于优化启动后台更新；字段损坏、书源变化或锚点失效时必须回退完整目录刷新。
final class TocRefreshCheckpoint {
  /// 创建一次成功目录更新后的检查点。
  TocRefreshCheckpoint({
    required this.bookUrl,
    required this.sourceUrl,
    required this.tocUrl,
    required this.anchorPageUrl,
    required List<String> visitedPageUrls,
    required this.anchorChapterUrl,
    required this.reverse,
    required this.chapterCount,
    required this.lastSuccessfulAt,
    required this.lastFullRefreshAt,
  }) : visitedPageUrls = List<String>.unmodifiable(visitedPageUrls);

  /// 所属书籍稳定主键。
  final String bookUrl;

  /// 更新时使用的书源地址；书源变化后旧检查点失效。
  final String sourceUrl;

  /// 更新时使用的目录入口；目录入口变化后旧检查点失效。
  final String tocUrl;

  /// 正序目录为上次最后一页，倒序目录为上次第一页。
  final String anchorPageUrl;

  /// 上次完整或增量更新已确认的分页地址，用于从尾页过滤旧页并只跟随新增页。
  final List<String> visitedPageUrls;

  /// 上次完整合并后的最后一章地址，用于确认本地目录仍与检查点一致。
  final String anchorChapterUrl;

  /// 目录规则是否按最新章节在前的倒序返回。
  final bool reverse;

  /// 上次完整合并后的章节数量，用于发现目录回退或本地快照不一致。
  final int chapterCount;

  /// 最近一次完整或增量更新成功的毫秒时间戳，用于短时间重复启动节流。
  final int lastSuccessfulAt;

  /// 最近一次完整校准成功的毫秒时间戳，用于周期性强制全量校准。
  final int lastFullRefreshAt;
}
