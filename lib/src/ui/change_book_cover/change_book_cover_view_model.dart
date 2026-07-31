import 'dart:async';

import '../../domain/model/book.dart';
import '../../domain/model/book_search.dart';
import '../../domain/model/search_book.dart';
import '../../domain/usecase/update_book_custom_cover_use_case.dart';
import '../../help/error/app_result.dart';
import '../../model/web_book/book_cover_search_coordinator.dart';
import '../../model/web_book/book_search_coordinator.dart';
import 'change_book_cover_contract.dart';

/// 管理封面候选初始化、实时搜索、取消和字段级保存。
final class ChangeBookCoverViewModel {
  /// 创建面板生命周期独占的封面 ViewModel，并立即加载已有候选。
  ChangeBookCoverViewModel({
    required Book book,
    required List<SearchBook> initialCandidates,
    required BookCoverSearchCoordinator searchCoordinator,
    required UpdateBookCustomCoverUseCase updateCustomCover,
  }) : _book = book,
       _initialCandidates = List<SearchBook>.unmodifiable(initialCandidates),
       _searchCoordinator = searchCoordinator,
       _updateCustomCover = updateCustomCover {
    unawaited(_initialize());
  }

  /// 当前需要更新封面的书架书。
  final Book _book;

  /// 详情搜索阶段已经掌握的候选。
  final List<SearchBook> _initialCandidates;

  /// 三级封面搜索协调器。
  final BookCoverSearchCoordinator _searchCoordinator;

  /// 自定义封面字段级更新动作。
  final UpdateBookCustomCoverUseCase _updateCustomCover;

  /// 当前状态。
  ChangeBookCoverUiState _state = ChangeBookCoverUiState();

  /// 状态广播流。
  final StreamController<ChangeBookCoverUiState> _stateController =
      StreamController<ChangeBookCoverUiState>.broadcast();

  /// 一次性 Effect 广播流。
  final StreamController<ChangeBookCoverEffect> _effectController =
      StreamController<ChangeBookCoverEffect>.broadcast();

  /// 当前实时搜索句柄。
  BookSearchRun? _searchRun;

  /// 初始化和销毁代次。
  int _lifecycleGeneration = 0;

  /// 每次开始、停止或重试都会递增，用于拒绝旧搜索事件。
  int _searchGeneration = 0;

  /// ViewModel 是否已经释放。
  bool _disposed = false;

  /// 当前状态。
  ChangeBookCoverUiState get state => _state;

  /// 后续状态流。
  Stream<ChangeBookCoverUiState> get states => _stateController.stream;

  /// 一次性 Effect 流。
  Stream<ChangeBookCoverEffect> get effects => _effectController.stream;

  /// 处理封面面板用户操作。
  void onIntent(ChangeBookCoverIntent intent) {
    switch (intent) {
      case RefreshBookCoverCandidatesIntent():
        unawaited(_startSearch());
      case StopBookCoverSearchIntent():
        _stopSearch();
      case SelectBookCoverCandidateIntent(coverUrl: final String coverUrl):
        unawaited(_saveCover(coverUrl));
      case RestoreDefaultBookCoverIntent():
        unawaited(_saveCover(null));
    }
  }

  /// 加载书源可用性、详情候选和 SQLite 缓存，并在没有替代封面时自动搜索。
  Future<void> _initialize() async {
    _lifecycleGeneration += 1;
    /// 本次初始化代次。
    final int generation = _lifecycleGeneration;
    try {
      /// 初始化后的书源和候选快照。
      final BookCoverSearchPreparation preparation =
          await _searchCoordinator.prepare(
        book: _book,
        initialCandidates: _initialCandidates,
      );
      if (_disposed || generation != _lifecycleGeneration) {
        return;
      }
      /// 当前没有候选时使用的书源状态提示。
      final String? statusMessage = preparation.candidates.isNotEmpty
          ? null
          : preparation.visibleSourceCount == 0
          ? '当前没有书源，无法搜索封面'
          : preparation.enabledSources.isEmpty
          ? '当前没有开启的书源，无法搜索封面'
          : null;
      _emit(
        _state.copyWith(
          initializing: false,
          candidates: preparation.candidates,
          matchLevel: preparation.matchLevel,
          clearMatchLevel: preparation.matchLevel == null,
          visibleSourceCount: preparation.visibleSourceCount,
          enabledSourceCount: preparation.enabledSources.length,
          statusMessage: statusMessage,
          clearStatusMessage: statusMessage == null,
          clearErrorMessage: true,
        ),
      );
      if (preparation.candidates.isEmpty &&
          preparation.enabledSources.isNotEmpty) {
        await _startSearch();
      }
    } on Object {
      if (_disposed || generation != _lifecycleGeneration) {
        return;
      }
      _emit(
        _state.copyWith(
          initializing: false,
          errorMessage: '加载封面候选失败',
        ),
      );
    }
  }

  /// 取消旧任务并搜索全部准备阶段确认启用的书源。
  Future<void> _startSearch() async {
    if (_disposed || _state.initializing || _state.saving) {
      return;
    }
    if (_state.enabledSourceCount == 0) {
      _effectController.add(
        ShowChangeBookCoverMessageEffect(
          _state.visibleSourceCount == 0
              ? '当前没有书源，无法搜索封面'
              : '当前没有开启的书源，无法搜索封面',
        ),
      );
      return;
    }
    _searchRun?.cancel();
    _searchGeneration += 1;
    /// 本次搜索事件代次。
    final int generation = _searchGeneration;
    _emit(
      _state.copyWith(
        searching: true,
        failureCount: 0,
        progress: const BookSearchProgress(
          total: 0,
          completed: 0,
          succeeded: 0,
          failed: 0,
        ),
        clearStatusMessage: true,
        clearErrorMessage: true,
      ),
    );
    try {
      /// 当前搜索运行句柄。
      final BookSearchRun run = await _searchCoordinator.startSearch(
        onEvent: (BookCoverSearchEvent event) {
          if (_disposed || generation != _searchGeneration) {
            return;
          }
          _handleSearchEvent(event);
        },
      );
      if (_disposed || generation != _searchGeneration) {
        run.cancel();
        return;
      }
      _searchRun = run;
      unawaited(
        run.completion.whenComplete(() {
          if (_disposed || generation != _searchGeneration) {
            return;
          }
          _searchRun = null;
          _finishSearch();
        }),
      );
    } on Object {
      if (_disposed || generation != _searchGeneration) {
        return;
      }
      _emit(
        _state.copyWith(
          searching: false,
          errorMessage: '启动封面搜索失败',
        ),
      );
    }
  }

  /// 处理候选升级、单源失败和进度事件。
  void _handleSearchEvent(BookCoverSearchEvent event) {
    switch (event) {
      case BookCoverCandidatesChangedEvent(
        candidates: final candidates,
        matchLevel: final matchLevel,
      ):
        _emit(
          _state.copyWith(
            candidates: candidates,
            matchLevel: matchLevel,
            clearStatusMessage: true,
          ),
        );
      case BookCoverSearchFailureEvent():
        _emit(_state.copyWith(failureCount: _state.failureCount + 1));
      case BookCoverSearchProgressEvent(progress: final progress):
        _emit(_state.copyWith(progress: progress));
        if (progress.total > 0 && progress.completed >= progress.total) {
          _finishSearch();
        }
    }
  }

  /// 标记本轮搜索结束，并保留所有已经成功返回的候选。
  void _finishSearch() {
    if (!_state.searching) {
      return;
    }
    _emit(
      _state.copyWith(
        searching: false,
        statusMessage: _state.candidates.isEmpty
            ? '没有找到匹配且封面非空的结果'
            : _state.failureCount > 0
            ? '搜索完成，${_state.failureCount} 个书源失败'
            : '搜索完成',
      ),
    );
  }

  /// 停止当前搜索并使仍在路上的旧事件失效。
  void _stopSearch() {
    if (!_state.searching) {
      return;
    }
    _searchGeneration += 1;
    _searchRun?.cancel();
    _searchRun = null;
    _emit(
      _state.copyWith(
        searching: false,
        statusMessage: '已停止搜索',
      ),
    );
  }

  /// 保存候选 URL；空值表示恢复书源默认封面。
  Future<void> _saveCover(String? coverUrl) async {
    if (_disposed || _state.saving) {
      return;
    }
    _stopSearch();
    _emit(_state.copyWith(saving: true, clearErrorMessage: true));
    /// 字段级更新结果。
    final AppResult<Book> result = await _updateCustomCover.execute(
      _book.bookUrl,
      coverUrl,
    );
    if (_disposed) {
      return;
    }
    switch (result) {
      case AppSuccess<Book>(value: final Book book):
        _effectController.add(CloseBookCoverWithResultEffect(book));
      case AppFailure<Book>(error: final error):
        _emit(
          _state.copyWith(
            saving: false,
            errorMessage: error.message,
          ),
        );
    }
  }

  /// 发布新状态。
  void _emit(ChangeBookCoverUiState state) {
    if (_disposed) {
      return;
    }
    _state = state;
    _stateController.add(state);
  }

  /// 取消搜索并释放广播控制器。
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _lifecycleGeneration += 1;
    _searchGeneration += 1;
    _searchRun?.cancel();
    _searchRun = null;
    _stateController.close();
    _effectController.close();
  }
}
