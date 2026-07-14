/// 表示书架分组，对应 Android `data.entities.BookGroup`。
final class BookGroup {
  /// 创建不可变书架分组。
  const BookGroup({
    required this.groupId,
    required this.groupName,
    this.cover,
    this.order = 0,
    this.enableRefresh = true,
    this.show = true,
    this.bookSort = -1,
    this.isPrivate = false,
  });

  /// 根分组标识。
  static const int idRoot = -100;
  /// 全部分组标识。
  static const int idAll = -1;
  /// 本地书分组标识。
  static const int idLocal = -2;
  /// 音频书分组标识。
  static const int idAudio = -3;
  /// 网络未分组标识。
  static const int idNetNone = -4;
  /// 本地未分组标识。
  static const int idLocalNone = -5;
  /// 漫画分组标识。
  static const int idManga = -7;
  /// 文本书分组标识。
  static const int idText = -8;
  /// 更新错误分组标识。
  static const int idError = -11;
  /// 阅读中分组标识。
  static const int idReading = -20;
  /// 未读分组标识。
  static const int idUnread = -21;
  /// 已读完分组标识。
  static const int idReadFinished = -22;
  /// 已读完且可更新分组标识。
  static const int idReadFinishedUpdate = -23;
  /// 已读完且完结分组标识。
  static const int idReadFinishedComplete = -24;

  /// 用户分组位值或负数系统分组标识，也是表主键。
  final int groupId;
  /// 分组名称。
  final String groupName;
  /// 分组封面地址。
  final String? cover;
  /// 分组显示顺序。
  final int order;
  /// 刷新书架时是否刷新该组书籍。
  final bool enableRefresh;
  /// 是否在书架分组入口显示。
  final bool show;
  /// 分组独立排序方式；-1 表示继承全局书架排序。
  final int bookSort;
  /// 是否为私密分组。
  final bool isPrivate;
}
