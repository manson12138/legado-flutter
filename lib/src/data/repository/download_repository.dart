import '../../domain/gateway/download_gateway.dart';
import '../../domain/model/download_task.dart';
import '../dao/download_task_dao.dart';
import '../local/data_error.dart';

/// 实现离线下载队列持久化边界，统一转换数据库错误。
final class DownloadRepository implements DownloadGateway {
  /// 创建离线下载 Repository。
  const DownloadRepository(this._downloadTaskDao, this._requireUserId);

  /// 下载任务 DAO。
  final DownloadTaskDao _downloadTaskDao;

  /// 返回当前认证用户 ID；下载队列不存在未登录公共作用域。
  final int Function() _requireUserId;

  /// 观察一本书的全部下载任务并统一转换数据库错误。
  @override
  Stream<List<DownloadTask>> watchTasks(String bookUrl) {
    final int userId = _requireUserId();
    return guardDataStream<List<DownloadTask>>(
      _downloadTaskDao.watchByBook(userId, bookUrl),
    );
  }

  /// 观察一本书的下载批次与自动换源状态。
  @override
  Stream<DownloadBookState?> watchBookState(String bookUrl) {
    final int userId = _requireUserId();
    return guardDataStream<DownloadBookState?>(
      _downloadTaskDao.watchBookState(userId, bookUrl),
    );
  }

  /// 读取一本书的下载批次与自动换源状态。
  @override
  Future<DownloadBookState?> getBookState(String bookUrl) {
    final int userId = _requireUserId();
    return guardDataOperation<DownloadBookState?>(
      () => _downloadTaskDao.getBookState(userId, bookUrl),
    );
  }

  /// 保存一本书的下载批次与自动换源状态。
  @override
  Future<void> upsertBookState(DownloadBookState state) {
    final int userId = _requireUserId();
    return guardDataOperation<void>(
      () => _downloadTaskDao.upsertBookState(userId, state),
    );
  }

  /// 观察全部书籍下载任务并统一转换数据库错误。
  @override
  Stream<List<DownloadTask>> watchAllTasks() {
    final int userId = _requireUserId();
    return guardDataStream<List<DownloadTask>>(
      _downloadTaskDao.watchAll(userId),
    );
  }

  /// 读取全部书籍下载任务快照。
  @override
  Future<List<DownloadTask>> getAllTasks() {
    final int userId = _requireUserId();
    return guardDataOperation<List<DownloadTask>>(
      () => _downloadTaskDao.getAll(userId),
    );
  }

  /// 读取一本书的全部下载任务。
  @override
  Future<List<DownloadTask>> getTasks(String bookUrl) {
    final int userId = _requireUserId();
    return guardDataOperation<List<DownloadTask>>(
      () => _downloadTaskDao.getByBook(userId, bookUrl),
    );
  }

  /// 读取全部等待或运行中的任务。
  @override
  Future<List<DownloadTask>> getPendingTasks() {
    final int userId = _requireUserId();
    return guardDataOperation<List<DownloadTask>>(
      () => _downloadTaskDao.getPending(userId),
    );
  }

  /// 暂停全部等待或运行任务。
  @override
  Future<int> pauseAll(int now) {
    final int userId = _requireUserId();
    return guardDataOperation<int>(
      () => _downloadTaskDao.pauseAll(userId, now),
    );
  }

  /// 暂停一本书的等待或运行任务。
  @override
  Future<int> pauseBook(String bookUrl, int now) {
    final int userId = _requireUserId();
    return guardDataOperation<int>(
      () => _downloadTaskDao.pauseBook(userId, bookUrl, now),
    );
  }

  /// 暂停指定章节的等待或运行任务。
  @override
  Future<int> pauseTask(String bookUrl, int chapterIndex, int now) {
    final int userId = _requireUserId();
    return guardDataOperation<int>(
      () => _downloadTaskDao.pauseTask(
        userId,
        bookUrl,
        chapterIndex,
        now,
      ),
    );
  }

  /// 恢复全部暂停任务。
  @override
  Future<int> resumeAll(int now) {
    final int userId = _requireUserId();
    return guardDataOperation<int>(
      () => _downloadTaskDao.resumeAll(userId, now),
    );
  }

  /// 恢复一本书的全部暂停任务。
  @override
  Future<int> resumeBook(String bookUrl, int now) {
    final int userId = _requireUserId();
    return guardDataOperation<int>(
      () => _downloadTaskDao.resumeBook(userId, bookUrl, now),
    );
  }

  /// 批量写入任务。
  @override
  Future<void> upsertTasks(List<DownloadTask> tasks) {
    final int userId = _requireUserId();
    return guardDataOperation<void>(
      () => _downloadTaskDao.upsertAll(userId, tasks),
    );
  }

  /// 写入单个任务。
  @override
  Future<void> upsertTask(DownloadTask task) {
    final int userId = _requireUserId();
    return guardDataOperation<void>(
      () => _downloadTaskDao.upsert(userId, task),
    );
  }

  /// 删除单个任务。
  @override
  Future<void> removeTask(String bookUrl, int chapterIndex) {
    final int userId = _requireUserId();
    return guardDataOperation<void>(
      () => _downloadTaskDao.deleteTask(userId, bookUrl, chapterIndex),
    );
  }

  /// 删除一本书的全部下载任务。
  @override
  Future<void> clearBook(String bookUrl) {
    final int userId = _requireUserId();
    return guardDataOperation<void>(
      () => _downloadTaskDao.deleteByBook(userId, bookUrl),
    );
  }

  /// 把全部残留“运行中”任务重置为“等待”。
  @override
  Future<void> resetRunningToWaiting(int now) {
    final int userId = _requireUserId();
    return guardDataOperation<void>(
      () => _downloadTaskDao.resetRunningToWaiting(userId, now),
    );
  }
}
