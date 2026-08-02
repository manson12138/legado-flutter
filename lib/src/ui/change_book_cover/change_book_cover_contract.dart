import '../../domain/model/book.dart';
import '../../model/web_book/book_cover_search_coordinator.dart';
import '../../domain/model/book_search.dart';

/// 封面选择底部面板的不可变状态。
final class ChangeBookCoverUiState {
  /// 创建封面选择状态。
  ChangeBookCoverUiState({
    this.initializing = true,
    this.searching = false,
    this.saving = false,
    this.pickingLocalImage = false,
    List<BookCoverCandidate> candidates = const <BookCoverCandidate>[],
    this.matchLevel,
    this.progress = const BookSearchProgress(
      total: 0,
      completed: 0,
      succeeded: 0,
      failed: 0,
    ),
    this.visibleSourceCount = 0,
    this.enabledSourceCount = 0,
    this.failureCount = 0,
    this.statusMessage,
    this.errorMessage,
  }) : candidates = List<BookCoverCandidate>.unmodifiable(candidates);

  /// 是否正在加载书源和缓存候选。
  final bool initializing;

  /// 是否正在执行有限并发实时搜索。
  final bool searching;

  /// 是否正在字段级保存用户选择。
  final bool saving;

  /// 是否正在等待系统图片选择器返回。
  final bool pickingLocalImage;

  /// 当前最高匹配层级的网络封面候选。
  final List<BookCoverCandidate> candidates;

  /// 当前候选匹配层级。
  final BookCoverMatchLevel? matchLevel;

  /// 实时搜索进度。
  final BookSearchProgress progress;

  /// 当前内容策略下可见书源总数。
  final int visibleSourceCount;

  /// 当前可见且启用的书源数。
  final int enabledSourceCount;

  /// 本轮搜索失败书源数量。
  final int failureCount;

  /// 空状态、停止或搜索完成提示。
  final String? statusMessage;

  /// 初始化或保存失败摘要。
  final String? errorMessage;

  /// 复制封面选择状态。
  ChangeBookCoverUiState copyWith({
    bool? initializing,
    bool? searching,
    bool? saving,
    bool? pickingLocalImage,
    List<BookCoverCandidate>? candidates,
    BookCoverMatchLevel? matchLevel,
    BookSearchProgress? progress,
    int? visibleSourceCount,
    int? enabledSourceCount,
    int? failureCount,
    String? statusMessage,
    String? errorMessage,
    bool clearMatchLevel = false,
    bool clearStatusMessage = false,
    bool clearErrorMessage = false,
  }) {
    return ChangeBookCoverUiState(
      initializing: initializing ?? this.initializing,
      searching: searching ?? this.searching,
      saving: saving ?? this.saving,
      pickingLocalImage: pickingLocalImage ?? this.pickingLocalImage,
      candidates: candidates ?? this.candidates,
      matchLevel: clearMatchLevel ? null : matchLevel ?? this.matchLevel,
      progress: progress ?? this.progress,
      visibleSourceCount: visibleSourceCount ?? this.visibleSourceCount,
      enabledSourceCount: enabledSourceCount ?? this.enabledSourceCount,
      failureCount: failureCount ?? this.failureCount,
      statusMessage: clearStatusMessage
          ? null
          : statusMessage ?? this.statusMessage,
      errorMessage:
          clearErrorMessage ? null : errorMessage ?? this.errorMessage,
    );
  }
}

/// 封面选择面板的用户操作。
sealed class ChangeBookCoverIntent {
  /// 限制 Intent 类型。
  const ChangeBookCoverIntent();
}

/// 重新搜索全部当前启用书源。
final class RefreshBookCoverCandidatesIntent extends ChangeBookCoverIntent {
  /// 创建刷新 Intent。
  const RefreshBookCoverCandidatesIntent();
}

/// 停止当前封面搜索。
final class StopBookCoverSearchIntent extends ChangeBookCoverIntent {
  /// 创建停止 Intent。
  const StopBookCoverSearchIntent();
}

/// 请求通过系统选择器更换为本地图片。
final class PickLocalBookCoverIntent extends ChangeBookCoverIntent {
  /// 创建本地图片选择 Intent。
  const PickLocalBookCoverIntent();
}

/// 系统选择器取消或失败后恢复面板交互。
final class CancelLocalBookCoverPickIntent extends ChangeBookCoverIntent {
  /// 创建本地图片选择取消 Intent。
  const CancelLocalBookCoverPickIntent();
}

/// 系统选择器已经把图片复制到应用私有目录，继续字段级保存。
final class LocalBookCoverPickedIntent extends ChangeBookCoverIntent {
  /// 创建本地封面保存 Intent。
  const LocalBookCoverPickedIntent(this.coverPath);

  /// 已复制到应用私有目录的完整路径。
  final String coverPath;
}

/// 选择一个网络候选封面。
final class SelectBookCoverCandidateIntent extends ChangeBookCoverIntent {
  /// 创建候选选择 Intent。
  const SelectBookCoverCandidateIntent(this.coverUrl);

  /// 已由协调器验证非空的封面 URL。
  final String coverUrl;
}

/// 清除自定义封面并恢复书源默认封面。
final class RestoreDefaultBookCoverIntent extends ChangeBookCoverIntent {
  /// 创建恢复默认封面 Intent。
  const RestoreDefaultBookCoverIntent();
}

/// 封面选择面板的一次性副作用。
sealed class ChangeBookCoverEffect {
  /// 限制 Effect 类型。
  const ChangeBookCoverEffect();
}

/// 封面保存成功并携带数据库最新书籍关闭面板。
final class CloseBookCoverWithResultEffect extends ChangeBookCoverEffect {
  /// 创建成功关闭 Effect。
  const CloseBookCoverWithResultEffect(this.book);

  /// 字段级更新后重新读取的完整书籍事实。
  final Book book;
}

/// 展示不关闭面板的一次性提示。
final class ShowChangeBookCoverMessageEffect extends ChangeBookCoverEffect {
  /// 创建消息 Effect。
  const ShowChangeBookCoverMessageEffect(this.message);

  /// 面向用户的简短提示。
  final String message;
}

/// 请求 Route 边界打开系统图片选择器。
final class RequestLocalBookCoverPickerEffect extends ChangeBookCoverEffect {
  /// 创建系统选择器 Effect。
  const RequestLocalBookCoverPickerEffect();
}

/// 本地封面保存失败，请求 Route 删除尚未生效的应用私有副本。
final class DeleteUnusedLocalBookCoverEffect extends ChangeBookCoverEffect {
  /// 创建未使用副本清理 Effect。
  const DeleteUnusedLocalBookCoverEffect(this.coverPath);

  /// 等待删除的应用私有图片路径。
  final String coverPath;
}
