import '../../domain/model/local_book.dart';

/// 单个候选文件的导入状态。
enum LocalBookImportItemStatus {
  /// 等待用户开始导入。
  pending,

  /// 正在复制、解析或写入数据库。
  importing,

  /// 新书已成功加入书架。
  imported,

  /// 同一内容书籍已成功更新。
  updated,

  /// 当前文件导入失败。
  failed,
}

/// 保存本地书导入列表中的单个不可变候选项。
final class LocalBookImportItem {
  /// 创建候选文件显示状态。
  const LocalBookImportItem({
    required this.file,
    this.selected = true,
    this.status = LocalBookImportItemStatus.pending,
    this.message,
    this.bookUrl,
  });

  /// 平台选择器提供的文件事实。
  final LocalBookPickedFile file;

  /// 是否包含在下一次批量导入中。
  final bool selected;

  /// 当前导入状态。
  final LocalBookImportItemStatus status;

  /// 单文件成功摘要或受控错误。
  final String? message;

  /// 成功后生成的稳定书籍 URL。
  final String? bookUrl;

  /// 复制候选项并覆盖本次变化字段。
  LocalBookImportItem copyWith({
    bool? selected,
    LocalBookImportItemStatus? status,
    String? message,
    String? bookUrl,
    bool clearMessage = false,
    bool clearBookUrl = false,
  }) {
    return LocalBookImportItem(
      file: file,
      selected: selected ?? this.selected,
      status: status ?? this.status,
      message: clearMessage ? null : message ?? this.message,
      bookUrl: clearBookUrl ? null : bookUrl ?? this.bookUrl,
    );
  }
}

/// 保存本地书导入页面全部长期状态。
final class LocalBookImportUiState {
  /// 创建不可变导入页面状态。
  LocalBookImportUiState({
    List<LocalBookImportItem> items = const <LocalBookImportItem>[],
    this.busy = false,
    this.completed = 0,
    this.total = 0,
  }) : items = List<LocalBookImportItem>.unmodifiable(items);

  /// 当前系统选择的所有候选文件。
  final List<LocalBookImportItem> items;

  /// 是否正在执行不可重入的批量导入。
  final bool busy;

  /// 当前批次已经完成的文件数。
  final int completed;

  /// 当前批次总文件数。
  final int total;

  /// 当前被选中的文件数量。
  int get selectedCount => items.where((LocalBookImportItem item) => item.selected).length;

  /// 复制页面状态并冻结列表。
  LocalBookImportUiState copyWith({
    List<LocalBookImportItem>? items,
    bool? busy,
    int? completed,
    int? total,
  }) {
    return LocalBookImportUiState(
      items: items ?? this.items,
      busy: busy ?? this.busy,
      completed: completed ?? this.completed,
      total: total ?? this.total,
    );
  }
}

/// 定义本地书导入页面允许处理的用户意图。
sealed class LocalBookImportIntent {
  /// 限制意图只能由本文件中的明确类型创建。
  const LocalBookImportIntent();
}

/// 请求路由层打开系统文件选择器。
final class PickLocalBooksIntent extends LocalBookImportIntent {
  /// 创建选择文件意图。
  const PickLocalBooksIntent();
}

/// 将系统选择结果交回 ViewModel。
final class LocalBooksPickedIntent extends LocalBookImportIntent {
  /// 创建包含不可变选择结果的意图。
  LocalBooksPickedIntent(List<LocalBookPickedFile> files)
    : files = List<LocalBookPickedFile>.unmodifiable(files);

  /// 本次选择到的文件。
  final List<LocalBookPickedFile> files;
}

/// 切换单个候选文件选择状态。
final class ToggleLocalBookSelectionIntent extends LocalBookImportIntent {
  /// 创建指定列表索引的切换意图。
  const ToggleLocalBookSelectionIntent(this.index);

  /// 候选文件列表索引。
  final int index;
}

/// 选中或取消选中全部候选文件。
final class SetAllLocalBooksSelectedIntent extends LocalBookImportIntent {
  /// 创建批量选择意图。
  const SetAllLocalBooksSelectedIntent(this.selected);

  /// 目标选择状态。
  final bool selected;
}

/// 开始顺序导入当前选中文件。
final class ImportSelectedLocalBooksIntent extends LocalBookImportIntent {
  /// 创建批量导入意图。
  const ImportSelectedLocalBooksIntent();
}

/// 请求关闭当前页面。
final class CloseLocalBookImportIntent extends LocalBookImportIntent {
  /// 创建关闭意图。
  const CloseLocalBookImportIntent();
}

/// 定义本地书导入页面的一次性副作用。
sealed class LocalBookImportEffect {
  /// 限制副作用只能由本文件中的明确类型创建。
  const LocalBookImportEffect();
}

/// 请求系统文件选择器。
final class PickLocalBooksEffect extends LocalBookImportEffect {
  /// 创建文件选择副作用。
  const PickLocalBooksEffect();
}

/// 请求展示一次性消息。
final class ShowLocalBookImportMessageEffect extends LocalBookImportEffect {
  /// 创建消息副作用。
  const ShowLocalBookImportMessageEffect(this.message);

  /// 安全展示文本。
  final String message;
}

/// 请求关闭导入页面。
final class CloseLocalBookImportEffect extends LocalBookImportEffect {
  /// 创建关闭页面副作用。
  const CloseLocalBookImportEffect();
}
