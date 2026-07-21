import '../../domain/gateway/download_gateway.dart';
import '../../domain/model/download_task.dart';
import '../dao/download_task_dao.dart';
import '../local/data_error.dart';

/// 实现离线下载队列持久化边界，统一转换数据库错误。
final class DownloadRepository implements DownloadGateway {
  /// 创建离线下载 Repository。
  const DownloadRepository(this._downloadTaskDao);

  /// 下载任务 DAO。
  final DownloadTaskDao _downloadTaskDao;

  /// 观察一本书的全部下载任务并统一转换数据库错误。
  @override
  Stream<List<DownloadTask>> watchTasks(String bookUrl) {
    return guardDataStream<List<DownloadTask>>(_downloadTaskDao.watchByBook(bookUrl));
  }

  /// 观察一本书的下载批次与自动换源状态。
  @override
  Stream<DownloadBookState?> watchBookState(String bookUrl) {
    return guardDataStream<DownloadBookState?>(
      _downloadTaskDao.watchBookState(bookUrl),
    );
  }

  /// 读取一本书的下载批次与自动换源状态。
  @override
  Future<DownloadBookState?> getBookState(String bookUrl) {
    return guardDataOperation<DownloadBookState?>(
      () => _downloadTaskDao.getBookState(bookUrl),
    );
  }

  /// 保存一本书的下载批次与自动换源状态。
  @override
  Future<void> upsertBookState(DownloadBookState state) {
    return guardDataOperation<void>(
      () => _downloadTaskDao.upsertBookState(state),
    );
  }

  /// 观察全部书籍下载任务并统一转换数据库错误。
  @override
  Stream<List<DownloadTask>> watchAllTasks() {
    return guardDataStream<List<DownloadTask>>(_downloadTaskDao.watchAll());
  }

  /// 读取全部书籍下载任务快照。
  @override
  Future<List<DownloadTask>> getAllTasks() {
    return guardDataOperation<List<DownloadTask>>(
      _downloadTaskDao.getAll,
    );
  }

  /// 读取一本书的全部下载任务。
  @override
  Future<List<DownloadTask>> getTasks(String bookUrl) {
    return guardDataOperation<List<DownloadTask>>(() => _downloadTaskDao.getByBook(bookUrl));
  }

  /// 读取全部等待或运行中的任务。
  @override
  Future<List<DownloadTask>> getPendingTasks() {
    return guardDataOperation<List<DownloadTask>>(() => _downloadTaskDao.getPending());
  }

  /// 暂停全部等待或运行任务。
  @override
  Future<int> pauseAll(int now) {
    return guardDataOperation<int>(() => _downloadTaskDao.pauseAll(now));
  }

  /// 暂停一本书的等待或运行任务。
  @override
  Future<int> pauseBook(String bookUrl, int now) {
    return guardDataOperation<int>(
      () => _downloadTaskDao.pauseBook(bookUrl, now),
    );
  }

  /// 暂停指定章节的等待或运行任务。
  @override
  Future<int> pauseTask(String bookUrl, int chapterIndex, int now) {
    return guardDataOperation<int>(
      () => _downloadTaskDao.pauseTask(bookUrl, chapterIndex, now),
    );
  }

  /// 恢复全部暂停任务。
  @override
  Future<int> resumeAll(int now) {
    return guardDataOperation<int>(() => _downloadTaskDao.resumeAll(now));
  }

  /// 恢复一本书的全部暂停任务。
  @override
  Future<int> resumeBook(String bookUrl, int now) {
    return guardDataOperation<int>(
      () => _downloadTaskDao.resumeBook(bookUrl, now),
    );
  }

  /// 批量写入任务。
  @override
  Future<void> upsertTasks(List<DownloadTask> tasks) {
    return guardDataOperation<void>(() => _downloadTaskDao.upsertAll(tasks));
  }

  /// 写入单个任务。
  @override
  Future<void> upsertTask(DownloadTask task) {
    return guardDataOperation<void>(() => _downloadTaskDao.upsert(task));
  }

  /// 删除单个任务。
  @override
  Future<void> removeTask(String bookUrl, int chapterIndex) {
    return guardDataOperation<void>(() => _downloadTaskDao.deleteTask(bookUrl, chapterIndex));
  }

  /// 删除一本书的全部下载任务。
  @override
  Future<void> clearBook(String bookUrl) {
    return guardDataOperation<void>(() => _downloadTaskDao.deleteByBook(bookUrl));
  }

  /// 把全部残留“运行中”任务重置为“等待”。
  @override
  Future<void> resetRunningToWaiting(int now) {
    return guardDataOperation<void>(() => _downloadTaskDao.resetRunningToWaiting(now));
  }
}
