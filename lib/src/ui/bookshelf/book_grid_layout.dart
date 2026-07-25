/// 书架与阅读历史共用的封面网格规格，保证两个页面的书籍卡片尺寸一致。
final class BookGridLayout {
  /// 限制为纯静态规格类，避免创建无意义实例。
  const BookGridLayout._();

  /// 单个书籍卡片的目标宽度，用于根据可用宽度计算列数。
  static const double targetTileWidth = 108;

  /// 手机窄屏最少显示的封面列数。
  static const int minimumColumns = 3;

  /// 宽屏最多显示的封面列数。
  static const int maximumColumns = 8;

  /// 书籍卡片宽高比，包含封面和书名区域。
  static const double childAspectRatio = 0.62;

  /// 卡片两侧的统一留白，保证书架与历史的实际卡片宽度相同。
  static const double cardHorizontalInset = 1.5;
}
