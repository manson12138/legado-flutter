import 'dart:async';

/// 发布数据库表级变更，供 DAO 将一次查询扩展为明确的观察流。
///
/// 通知只表示“相关表可能已变化”，订阅者收到通知后重新查询，通知本身不保存页面状态。
final class DatabaseChangeNotifier {
  /// 创建表级通知器。
  DatabaseChangeNotifier();

  /// 广播带单调版本号的表变更事件。
  final StreamController<_DatabaseChange> _changes =
      StreamController<_DatabaseChange>.broadcast(sync: true);

  /// 每张表最近一次提交的单调版本号。
  final Map<String, int> _tableRevisions = <String, int>{};

  /// 全数据库最近一次提交通知版本号。
  int _revision = 0;

  /// 通知一组写入已经提交；调用方应只在事务成功后调用。
  void notifyTables(Set<String> tableNames) {
    if (tableNames.isEmpty || _changes.isClosed) {
      return;
    }
    _revision += 1;
    for (final String tableName in tableNames) {
      _tableRevisions[tableName] = _revision;
    }
    _changes.add(
      _DatabaseChange(
        revision: _revision,
        tableNames: Set<String>.unmodifiable(tableNames),
      ),
    );
  }

  /// 返回指定表集合最近一次提交的最大版本号。
  int revisionForTables(Set<String> tableNames) {
    /// 当前观察表集合中的最大版本号。
    int latestRevision = 0;
    for (final String tableName in tableNames) {
      /// 当前表最后一次提交的版本号；0 表示从未收到写入通知。
      final int tableRevision = _tableRevisions[tableName] ?? 0;
      if (tableRevision > latestRevision) {
        latestRevision = tableRevision;
      }
    }
    return latestRevision;
  }

  /// 等待指定表在 [afterRevision] 之后提交，且不会遗漏查询与订阅之间的变化。
  Future<int> waitForTableChange(
    Set<String> tableNames,
    int afterRevision,
  ) async {
    /// 调用等待前已经提交的相关表最新版本。
    final int existingRevision = revisionForTables(tableNames);
    if (existingRevision > afterRevision) {
      return existingRevision;
    }

    /// 第一个命中观察表且版本更新的提交事件。
    final _DatabaseChange change = await _changes.stream.firstWhere(
      (_DatabaseChange event) {
        /// 当前事件是否涉及任一观察表。
        final bool containsObservedTable =
            event.tableNames.any(tableNames.contains);
        return event.revision > afterRevision && containsObservedTable;
      },
    );
    return change.revision;
  }

  /// 关闭通知器；通常仅在测试或显式释放应用数据层时使用。
  Future<void> close() async {
    await _changes.close();
  }
}

/// 保存一次已提交数据库变更的版本和表集合。
final class _DatabaseChange {
  /// 创建不可变变更事件。
  const _DatabaseChange({required this.revision, required this.tableNames});

  /// 单调递增的提交版本号。
  final int revision;

  /// 本次提交可能改变的表名集合。
  final Set<String> tableNames;
}
