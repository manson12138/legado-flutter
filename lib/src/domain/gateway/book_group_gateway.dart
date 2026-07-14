import '../model/book_group.dart';

/// 定义书架分组持久化边界，UI 不直接访问分组 DAO。
abstract interface class BookGroupGateway {
  /// 观察全部用户分组，按显示顺序返回。
  Stream<List<BookGroup>> watchGroups();

  /// 创建新的正数位值用户分组并返回实际分组。
  Future<BookGroup> createGroup(String name);
}
