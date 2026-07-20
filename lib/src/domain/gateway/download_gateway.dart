import '../model/download_task.dart';

/// 定义离线下载队列持久化边界，UI 和调度器不直接访问 DownloadTaskDao。
abstract interface class DownloadGateway {
  /// 观察一本书的全部下载任务。
  Stream<List<DownloadTask>> watchTasks(String bookUrl);

  /// 读取一本书的全部下载任务。
  Future<List<DownloadTask>> getTasks(String bookUrl);

  /// 读取全部等待或运行中的任务，供调度器跨书调度。
  Future<List<DownloadTask>> getPendingTasks();

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
