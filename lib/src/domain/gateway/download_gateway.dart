import '../model/download_task.dart';

/// 定义离线下载队列持久化边界，UI 和调度器不直接访问 DownloadTaskDao。
abstract interface class DownloadGateway {
  /// 观察一本书的全部下载任务。
  Stream<List<DownloadTask>> watchTasks(String bookUrl);

  /// 观察一本书的下载批次、自动换源和锁定候选状态。
  Stream<DownloadBookState?> watchBookState(String bookUrl);

  /// 读取一本书当前下载状态；尚未配置时返回空。
  Future<DownloadBookState?> getBookState(String bookUrl);

  /// 保存一本书下载批次、自动换源和锁定候选状态。
  Future<void> upsertBookState(DownloadBookState state);

  /// 观察全部书籍的下载任务，供独立下载管理页面跨书汇总。
  Stream<List<DownloadTask>> watchAllTasks();

  /// 读取全部书籍下载任务快照，供通知和调度摘要使用。
  Future<List<DownloadTask>> getAllTasks();

  /// 读取一本书的全部下载任务。
  Future<List<DownloadTask>> getTasks(String bookUrl);

  /// 读取全部等待或运行中的任务，供调度器跨书调度。
  Future<List<DownloadTask>> getPendingTasks();

  /// 将全部等待或运行任务暂停，返回受影响任务数量。
  Future<int> pauseAll(int now);

  /// 将一本书的等待或运行任务暂停，返回受影响任务数量。
  Future<int> pauseBook(String bookUrl, int now);

  /// 将单章等待或运行任务暂停。
  Future<int> pauseTask(String bookUrl, int chapterIndex, int now);

  /// 将全部暂停任务恢复为等待。
  Future<int> resumeAll(int now);

  /// 将一本书的暂停任务恢复为等待。
  Future<int> resumeBook(String bookUrl, int now);

  /// 批量写入任务；已存在的章节任务直接覆盖。
  Future<void> upsertTasks(List<DownloadTask> tasks);

  /// 写入单个任务；已存在的章节任务直接覆盖。
  Future<void> upsertTask(DownloadTask task);

  /// 删除单个任务。
  Future<void> removeTask(String bookUrl, int chapterIndex);

  /// 删除一本书的全部下载任务。
  Future<void> clearBook(String bookUrl);

  /// 把全部残留“运行中”任务重置为“等待”；应用重启后旧运行状态已不可信。
  Future<void> resetRunningToWaiting(int now);
}
