import 'dart:async';

import '../../domain/model/local_book.dart';
import '../../model/local_book/local_book_parser.dart';
import '../../model/local_book/local_book_service.dart';
import 'local_book_import_contract.dart';

/// 管理候选选择、逐文件导入进度和批量失败隔离。
final class LocalBookImportViewModel {
  /// 创建页面生命周期内唯一导入 ViewModel。
  LocalBookImportViewModel({required LocalBookImportCoordinator coordinator})
    : _coordinator = coordinator;

  /// 本地文件复制、解析和书架事务协调器。
  final LocalBookImportCoordinator _coordinator;

  /// 当前不可变页面状态。
  LocalBookImportUiState _state = LocalBookImportUiState();

  /// 页面状态广播流。
  final StreamController<LocalBookImportUiState> _stateController =
      StreamController<LocalBookImportUiState>.broadcast();

  /// 一次性副作用广播流。
  final StreamController<LocalBookImportEffect> _effectController =
      StreamController<LocalBookImportEffect>.broadcast();

  /// 当前页面状态快照。
  LocalBookImportUiState get state => _state;

  /// 路由层监听的状态流。
  Stream<LocalBookImportUiState> get states => _stateController.stream;

  /// 路由层监听的一次性副作用流。
  Stream<LocalBookImportEffect> get effects => _effectController.stream;

  /// 页面全部用户操作的唯一入口。
  void onIntent(LocalBookImportIntent intent) {
    switch (intent) {
      case PickLocalBooksIntent():
        if (!_state.busy) {
          _effectController.add(const PickLocalBooksEffect());
        }
      case LocalBooksPickedIntent(files: final List<LocalBookPickedFile> files):
        _acceptFiles(files);
      case ToggleLocalBookSelectionIntent(index: final int index):
        _toggleSelection(index);
      case SetAllLocalBooksSelectedIntent(selected: final bool selected):
        _setAllSelected(selected);
      case ImportSelectedLocalBooksIntent():
        _importSelected();
      case CloseLocalBookImportIntent():
        if (!_state.busy) {
          _effectController.add(const CloseLocalBookImportEffect());
        }
    }
  }

  /// 用新一批系统选择结果替换候选列表。
  void _acceptFiles(List<LocalBookPickedFile> files) {
    if (_state.busy || files.isEmpty) {
      return;
    }
    _emit(
      LocalBookImportUiState(
        items: files.map((LocalBookPickedFile file) => LocalBookImportItem(file: file)).toList(growable: false),
      ),
    );
  }

  /// 切换有效索引对应候选项。
  void _toggleSelection(int index) {
    if (_state.busy || index < 0 || index >= _state.items.length) {
      return;
    }
    /// 可修改副本。
    final List<LocalBookImportItem> items = List<LocalBookImportItem>.of(_state.items);
    /// 当前候选项。
    final LocalBookImportItem item = items[index];
    items[index] = item.copyWith(selected: !item.selected);
    _emit(_state.copyWith(items: items));
  }

  /// 批量设置所有候选项选择状态。
  void _setAllSelected(bool selected) {
    if (_state.busy) {
      return;
    }
    _emit(
      _state.copyWith(
        items: _state.items
            .map((LocalBookImportItem item) => item.copyWith(selected: selected))
            .toList(growable: false),
      ),
    );
  }

  /// 顺序导入选中文件，使单文件失败不会回滚其他成功文件。
  Future<void> _importSelected() async {
    if (_state.busy) {
      return;
    }
    /// 本批次需要处理的列表索引。
    final List<int> selectedIndices = _state.items.indexed
        .where(((int, LocalBookImportItem) entry) => entry.$2.selected)
        .map(((int, LocalBookImportItem) entry) => entry.$1)
        .toList(growable: false);
    if (selectedIndices.isEmpty) {
      _effectController.add(const ShowLocalBookImportMessageEffect('请先选择要导入的文件'));
      return;
    }
    _emit(_state.copyWith(busy: true, completed: 0, total: selectedIndices.length));
    /// 本批次成功数量。
    int succeeded = 0;
    /// 本批次更新数量。
    int updated = 0;
    /// 本批次失败数量。
    int failed = 0;
    for (final int index in selectedIndices) {
      _replaceItem(index, _state.items[index].copyWith(status: LocalBookImportItemStatus.importing, clearMessage: true));
      try {
        /// 单文件导入结果。
        final LocalBookImportResult result = await _coordinator.importFile(_state.items[index].file);
        if (result.updated) {
          updated += 1;
        } else {
          succeeded += 1;
        }
        _replaceItem(
          index,
          _state.items[index].copyWith(
            status: result.updated ? LocalBookImportItemStatus.updated : LocalBookImportItemStatus.imported,
            message: result.updated ? '已更新同一内容书籍' : '已加入书架',
            bookUrl: result.book.bookUrl,
          ),
        );
      } on LocalBookException catch (error) {
        failed += 1;
        _replaceItem(
          index,
          _state.items[index].copyWith(
            status: LocalBookImportItemStatus.failed,
            message: error.message,
            clearBookUrl: true,
          ),
        );
      }
      _emit(_state.copyWith(completed: _state.completed + 1));
    }
    _emit(_state.copyWith(busy: false));
    _effectController.add(
      ShowLocalBookImportMessageEffect('导入完成：新增 $succeeded，本次更新 $updated，失败 $failed'),
    );
  }

  /// 替换指定索引候选项并发出新状态。
  void _replaceItem(int index, LocalBookImportItem replacement) {
    /// 当前候选项可修改副本。
    final List<LocalBookImportItem> items = List<LocalBookImportItem>.of(_state.items);
    items[index] = replacement;
    _emit(_state.copyWith(items: items));
  }

  /// 保存并广播新的不可变页面状态。
  void _emit(LocalBookImportUiState state) {
    _state = state;
    if (!_stateController.isClosed) {
      _stateController.add(state);
    }
  }

  /// 释放页面状态和副作用流。
  Future<void> dispose() async {
    await _stateController.close();
    await _effectController.close();
  }
}
