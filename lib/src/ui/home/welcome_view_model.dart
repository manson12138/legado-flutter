import 'dart:async';

import 'welcome_contract.dart';

/// 管理应用主框架一级目的地选择状态。
final class WelcomeViewModel {
  /// 创建默认选中书架的主框架 ViewModel。
  WelcomeViewModel();

  /// 当前可立即渲染的主框架状态。
  WelcomeUiState _state = const WelcomeUiState();

  /// 向路由层广播一级目的地变化。
  final StreamController<WelcomeUiState> _stateController =
      StreamController<WelcomeUiState>.broadcast();

  /// 当前主框架状态。
  WelcomeUiState get state => _state;

  /// 后续主框架状态变化。
  Stream<WelcomeUiState> get states => _stateController.stream;

  /// 主框架所有用户操作的唯一入口。
  void onIntent(WelcomeIntent intent) {
    switch (intent) {
      case SelectPrimaryDestinationIntent(index: final int index):
        _selectDestination(index);
    }
  }

  /// 校验一级导航索引并发布新状态。
  void _selectDestination(int index) {
    if (index < 0 || index > 3 || index == _state.selectedIndex) {
      return;
    }
    _state = _state.copyWith(selectedIndex: index);
    if (!_stateController.isClosed) {
      _stateController.add(_state);
    }
  }

  /// 在应用主框架销毁时关闭状态流。
  Future<void> dispose() async {
    await _stateController.close();
  }
}
