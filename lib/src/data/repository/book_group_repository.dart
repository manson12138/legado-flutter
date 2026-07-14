import '../../domain/gateway/book_group_gateway.dart';
import '../../domain/model/book_group.dart';
import '../dao/book_group_dao.dart';
import '../local/data_error.dart';

/// 将分组 DAO 转换为领域 Gateway，并统一数据错误边界。
final class BookGroupRepository implements BookGroupGateway {
  /// 创建分组 Repository。
  const BookGroupRepository(this._dao);

  /// 分组 DAO。
  final BookGroupDao _dao;

  @override
  Stream<List<BookGroup>> watchGroups() {
    return guardDataStream<List<BookGroup>>(_dao.watchAll());
  }

  @override
  Future<BookGroup> createGroup(String name) {
    return guardDataOperation<BookGroup>(() async {
      /// 当前全部分组。
      final List<BookGroup> groups = await _dao.getAll();
      /// 已使用正数位值。
      final Set<int> usedIds = groups.where((BookGroup group) => group.groupId > 0).map(
        (BookGroup group) => group.groupId,
      ).toSet();
      /// 从最低位开始寻找未使用的 Android 兼容分组位值。
      int groupId = 1;
      while (usedIds.contains(groupId) && groupId < 0x40000000) {
        groupId <<= 1;
      }
      if (usedIds.contains(groupId)) {
        throw const FormatException('用户分组数量已达到第一批上限');
      }
      /// 新分组显示顺序。
      final int order = groups.isEmpty
          ? 0
          : groups.map((BookGroup group) => group.order).reduce(
              (int left, int right) => left > right ? left : right,
            ) + 1;
      /// 待保存的新分组。
      final BookGroup group = BookGroup(
        groupId: groupId,
        groupName: name,
        order: order,
      );
      await _dao.upsert(group);
      return group;
    });
  }
}
