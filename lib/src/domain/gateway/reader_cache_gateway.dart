import '../model/reader_content.dart';

/// 定义正文缓存、稳定锚点和显示设置的持久化边界。
abstract interface class ReaderCacheGateway {
  /// 读取未过期的原始章节正文缓存。
  Future<String?> getChapterContent(String bookUrl, String chapterUrl, int now);

  /// 保存原始章节正文，替换规则变化后可重新处理而无需再次请求网络。
  Future<void> saveChapterContent(
    String bookUrl,
    String chapterUrl,
    String content,
    int deadline,
  );

  /// 读取一本书最后保存的稳定正文锚点。
  Future<ReaderPositionAnchor?> getPositionAnchor(String bookUrl);

  /// 保存章节地址、字符位置和附近正文组成的稳定锚点。
  Future<void> savePositionAnchor(String bookUrl, ReaderPositionAnchor anchor);

  /// 读取一本书的显示和替换配置。
  Future<ReaderDisplayConfig> getDisplayConfig(String bookUrl);

  /// 保存一本书的显示和替换配置。
  Future<void> saveDisplayConfig(String bookUrl, ReaderDisplayConfig config);
}
