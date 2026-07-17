/// 保存应用主框架当前选中的一级目的地。
final class WelcomeUiState {
  /// 创建不可变主框架状态。
  const WelcomeUiState({this.selectedIndex = 0});

  /// 当前选中的一级导航索引，顺序为书架、搜索、书源和我的。
  final int selectedIndex;

  /// 复制主框架状态并替换明确传入的字段。
  WelcomeUiState copyWith({int? selectedIndex}) {
    return WelcomeUiState(selectedIndex: selectedIndex ?? this.selectedIndex);
  }
}

/// 定义应用主框架允许接收的用户意图。
sealed class WelcomeIntent {
  /// 限制主框架意图只能由本文件中的明确类型创建。
  const WelcomeIntent();
}

/// 请求切换书架、搜索、书源或我的一级目的地。
final class SelectPrimaryDestinationIntent extends WelcomeIntent {
  /// 创建一级目的地选择意图。
  const SelectPrimaryDestinationIntent(this.index);

  /// 目标在主导航列表中的索引。
  final int index;
}
