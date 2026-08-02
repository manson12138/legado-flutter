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

  /// 把一次查询扩展为可立即取消的表观察流，并串行合并查询执行期间到达的提交。
  ///
  /// 先监听变更再执行首查，避免首查与订阅之间遗漏提交；取消时直接释放底层广播订阅，
  /// 不再等待目标表下一次写入，因此适合账号切换和页面销毁时立即替换旧作用域数据流。
  Stream<T> watchQuery<T>({
    required Set<String> tableNames,
    required Future<T> Function() query,
  }) {
    /// 防止调用方在订阅期间修改观察集合，导致同一流前后监听不同表。
    final Set<String> observedTables = Set<String>.unmodifiable(tableNames);
    return Stream<T>.multi((MultiStreamController<T> controller) {
      /// 底层数据库提交广播订阅；初始化完成前允许保持为空以安全处理取消。
      StreamSubscription<_DatabaseChange>? changeSubscription;
      /// 当前流是否已被页面取消或随通知器关闭。
      bool cancelled = false;
      /// 是否已有查询正在执行，避免高频通知并发读取同一张表。
      bool queryRunning = false;
      /// 查询完成前观察到的最新相关表版本；变大时当前查询后再补查一次。
      int requestedRevision = revisionForTables(observedTables);

      /// 串行执行首查及查询期间累积的最新补查，失败后结束当前观察流。
      Future<void> queryLatest() async {
        if (cancelled || queryRunning) {
          return;
        }
        queryRunning = true;
        try {
          while (!cancelled) {
            /// 本轮查询开始前已经观察到的相关表版本。
            final int revisionAtStart = requestedRevision;
            final T value = await query();
            if (cancelled) {
              return;
            }
            controller.add(value);
            if (requestedRevision == revisionAtStart) {
              return;
            }
          }
        } catch (error, stackTrace) {
          if (!cancelled) {
            cancelled = true;
            controller.addError(error, stackTrace);
            controller.close();
            final StreamSubscription<_DatabaseChange>? subscription =
                changeSubscription;
            if (subscription != null) {
              unawaited(subscription.cancel());
            }
          }
        } finally {
          queryRunning = false;
        }
      }

      changeSubscription = _changes.stream.listen(
        (_DatabaseChange change) {
          if (cancelled ||
              !change.tableNames.any(observedTables.contains)) {
            return;
          }
          requestedRevision = change.revision;
          unawaited(queryLatest());
        },
        onDone: () {
          if (!cancelled) {
            cancelled = true;
            controller.close();
          }
        },
      );
      controller.onCancel = () {
        cancelled = true;
        final StreamSubscription<_DatabaseChange>? subscription =
            changeSubscription;
        if (subscription != null) {
          unawaited(subscription.cancel());
        }
      };
      unawaited(queryLatest());
    });
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
