import 'search_book.dart';

/// 离线下载队列中单个章节任务的状态，对应 `download_tasks` 表 `status` 列。
enum DownloadTaskStatus {
  /// 已加入队列，等待调度器领取。
  waiting,

  /// 正在下载。
  running,

  /// 用户主动暂停，应用重启后保持暂停且不会自动领取。
  paused,

  /// 已成功下载并写入永久正文缓存。
  success,

  /// 已达到重试上限，需要用户手动重试。
  failed,
}

/// 表示离线下载队列中的一个章节任务，只负责队列可见状态；实际正文仍落在
/// 通用正文缓存表，任务表不冗余存储章节标题或 URL。
final class DownloadTask {
  /// 创建不可变下载任务。
  const DownloadTask({
    required this.bookUrl,
    required this.chapterIndex,
    required this.status,
    this.retryCount = 0,
    this.errorMessage,
    this.contentLength = 0,
    this.generation = 0,
    this.attemptedSourceUrls = const <String>{},
    this.successfulSourceUrl,
    required this.updatedAt,
  });

  /// 所属书籍主键，外键指向 `books.bookUrl`。
  final String bookUrl;

  /// 目标章节在目录中的稳定索引。
  final int chapterIndex;

  /// 当前任务状态。
  final DownloadTaskStatus status;

  /// 已消耗的自动重试次数；达到 5 次后转为 [DownloadTaskStatus.failed]。
  final int retryCount;

  /// 最近一次失败的安全摘要，不包含正文、Cookie 或原始请求参数。
  final String? errorMessage;

  /// 下载成功时保存的正文字符数，用于管理页展示近似离线数据量。
  final int contentLength;

  /// 所属下载批次编号，用于保证书源成功率每本书每批只结算一次。
  final int generation;

  /// 本批任务真实尝试过的书源 URL；同一书源多次重试只记录一次。
  final Set<String> attemptedSourceUrls;

  /// 最终成功提供本章正文的书源 URL；命中既有缓存时为空且不参与书源评分。
  final String? successfulSourceUrl;

  /// 最近一次状态变化时间，Unix Epoch 毫秒。
  final int updatedAt;

  /// 复制任务并覆盖指定字段。
  DownloadTask copyWith({
    DownloadTaskStatus? status,
    int? retryCount,
    String? errorMessage,
    int? contentLength,
    int? generation,
    Set<String>? attemptedSourceUrls,
    String? successfulSourceUrl,
    int? updatedAt,
    bool clearError = false,
    bool clearSuccessfulSource = false,
  }) {
    return DownloadTask(
      bookUrl: bookUrl,
      chapterIndex: chapterIndex,
      status: status ?? this.status,
      retryCount: retryCount ?? this.retryCount,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
      contentLength: contentLength ?? this.contentLength,
      generation: generation ?? this.generation,
      attemptedSourceUrls: attemptedSourceUrls ?? this.attemptedSourceUrls,
      successfulSourceUrl: clearSuccessfulSource
          ? null
          : successfulSourceUrl ?? this.successfulSourceUrl,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

/// 保存一本书离线下载批次的自动换源策略、锁定候选和一次性评分状态。
final class DownloadBookState {
  /// 创建不可变下载书籍状态；锁定候选字段必须同时存在才会恢复为有效候选。
  const DownloadBookState({
    required this.bookUrl,
    this.autoChangeSource = false,
    this.generation = 0,
    this.lockedSourceUrl,
    this.lockedSourceName,
    this.lockedBookUrl,
    this.lockedBookName,
    this.lockedBookAuthor,
    this.lockedBookTocUrl = '',
    this.lockedBookVariable,
    this.lockedBookType = 0,
    this.triedSourceUrls = const <String>{},
    this.scoredSourceUrls = const <String>{},
    required this.updatedAt,
  });

  /// 书架书籍稳定主键。
  final String bookUrl;

  /// 是否允许下载失败后自动搜索并验证替代书源。
  final bool autoChangeSource;

  /// 当前下载批次编号；新批次会清空候选尝试和评分状态。
  final int generation;

  /// 当前锁定候选的书源 URL。
  final String? lockedSourceUrl;

  /// 当前锁定候选的书源名称。
  final String? lockedSourceName;

  /// 当前锁定候选的详情页 URL。
  final String? lockedBookUrl;

  /// 当前锁定候选的书名。
  final String? lockedBookName;

  /// 当前锁定候选的作者。
  final String? lockedBookAuthor;

  /// 当前锁定候选搜索阶段已有的目录 URL。
  final String lockedBookTocUrl;

  /// 当前锁定候选搜索规则产生的变量 JSON。
  final String? lockedBookVariable;

  /// 当前锁定候选的书籍类型位掩码。
  final int lockedBookType;

  /// 当前批次已尝试或排除的书源 URL，避免失败后反复搜索同一来源。
  final Set<String> triedSourceUrls;

  /// 当前批次已经完成整书成功率结算的书源 URL。
  final Set<String> scoredSourceUrls;

  /// 最近一次策略、锁定或评分状态变化时间。
  final int updatedAt;

  /// 将完整锁定字段恢复为搜索候选；任一关键字段缺失时返回空。
  SearchBook? get lockedCandidate {
    /// 已持久化的候选书源 URL。
    final String? sourceUrl = lockedSourceUrl;
    /// 已持久化的候选书源名称。
    final String? sourceName = lockedSourceName;
    /// 已持久化的候选详情页 URL。
    final String? candidateBookUrl = lockedBookUrl;
    /// 已持久化的候选书名。
    final String? candidateBookName = lockedBookName;
    /// 已持久化的候选作者。
    final String? candidateBookAuthor = lockedBookAuthor;
    if (sourceUrl == null ||
        sourceName == null ||
        candidateBookUrl == null ||
        candidateBookName == null ||
        candidateBookAuthor == null) {
      return null;
    }
    return SearchBook(
      bookUrl: candidateBookUrl,
      origin: sourceUrl,
      originName: sourceName,
      name: candidateBookName,
      author: candidateBookAuthor,
      tocUrl: lockedBookTocUrl,
      variable: lockedBookVariable,
      type: lockedBookType,
    );
  }

  /// 复制状态并按需清除或替换锁定候选。
  DownloadBookState copyWith({
    bool? autoChangeSource,
    int? generation,
    SearchBook? lockedCandidate,
    Set<String>? triedSourceUrls,
    Set<String>? scoredSourceUrls,
    int? updatedAt,
    bool clearLockedCandidate = false,
  }) {
    return DownloadBookState(
      bookUrl: bookUrl,
      autoChangeSource: autoChangeSource ?? this.autoChangeSource,
      generation: generation ?? this.generation,
      lockedSourceUrl: clearLockedCandidate
          ? null
          : lockedCandidate?.origin ?? lockedSourceUrl,
      lockedSourceName: clearLockedCandidate
          ? null
          : lockedCandidate?.originName ?? lockedSourceName,
      lockedBookUrl: clearLockedCandidate
          ? null
          : lockedCandidate?.bookUrl ?? lockedBookUrl,
      lockedBookName: clearLockedCandidate
          ? null
          : lockedCandidate?.name ?? lockedBookName,
      lockedBookAuthor: clearLockedCandidate
          ? null
          : lockedCandidate?.author ?? lockedBookAuthor,
      lockedBookTocUrl: clearLockedCandidate
          ? ''
          : lockedCandidate?.tocUrl ?? lockedBookTocUrl,
      lockedBookVariable: clearLockedCandidate
          ? null
          : lockedCandidate == null
              ? lockedBookVariable
              : lockedCandidate.variable,
      lockedBookType: clearLockedCandidate
          ? 0
          : lockedCandidate?.type ?? lockedBookType,
      triedSourceUrls: triedSourceUrls ?? this.triedSourceUrls,
      scoredSourceUrls: scoredSourceUrls ?? this.scoredSourceUrls,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
