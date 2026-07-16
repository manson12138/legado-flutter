/// 保存欢迎页当前可渲染的长期状态。
///
/// M1 只验证应用骨架，因此状态仅描述工程阶段，不包含书源、书架或阅读模拟数据。
final class WelcomeUiState {
  /// 创建不可变欢迎页状态。
  const WelcomeUiState({
    required this.title,
    required this.description,
  });

  /// 欢迎页标题。
  final String title;

  /// 说明当前页面仅用于验证工程骨架的正文。
  final String description;
}

/// 定义欢迎页允许发送给 ViewModel 的用户意图。
sealed class WelcomeIntent {
  /// 限制欢迎页意图只能由本文件声明的明确类型创建。
  const WelcomeIntent();
}

/// 表示用户请求确认当前工程骨架状态。
final class ConfirmScaffoldIntent extends WelcomeIntent {
  /// 创建无附加数据的骨架确认意图。
  const ConfirmScaffoldIntent();
}

/// 表示用户请求进入书源管理。
final class OpenBookSourceManagementIntent extends WelcomeIntent {
  /// 创建书源管理导航意图。
  const OpenBookSourceManagementIntent();
}

/// 请求打开 M06 多书源搜索页面。
final class OpenSearchIntent extends WelcomeIntent {
  /// 创建搜索导航意图。
  const OpenSearchIntent();
}

/// 请求打开 M07 实时书架页面。
final class OpenBookshelfIntent extends WelcomeIntent {
  /// 创建书架导航意图。
  const OpenBookshelfIntent();
}

/// 请求打开 M08.1 本地书导入页面。
final class OpenLocalBookImportIntent extends WelcomeIntent {
  /// 创建本地书导入导航意图。
  const OpenLocalBookImportIntent();
}

/// 请求打开应用设置页面。
final class OpenSettingsIntent extends WelcomeIntent {
  /// 创建设置页导航意图。
  const OpenSettingsIntent();
}

/// 定义欢迎页发出的一次性副作用，不将 Snackbar 等短暂行为存入 UiState。
sealed class WelcomeEffect {
  /// 限制欢迎页副作用只能由本文件声明的明确类型创建。
  const WelcomeEffect();
}

/// 请求路由层显示一次性消息。
final class ShowWelcomeMessageEffect extends WelcomeEffect {
  /// 创建包含安全展示文本的消息副作用。
  const ShowWelcomeMessageEffect({required this.message});

  /// 交给路由层展示的一次性消息。
  final String message;
}

/// 请求路由层打开书源管理页面。
final class NavigateToBookSourceManagementEffect extends WelcomeEffect {
  /// 创建无附加数据的书源管理导航副作用。
  const NavigateToBookSourceManagementEffect();
}

/// 请求路由层打开多书源搜索页面。
final class NavigateToSearchEffect extends WelcomeEffect {
  /// 创建搜索导航副作用。
  const NavigateToSearchEffect();
}

/// 请求路由层打开书架页面。
final class NavigateToBookshelfEffect extends WelcomeEffect {
  /// 创建书架导航副作用。
  const NavigateToBookshelfEffect();
}

/// 请求路由层打开本地书导入页面。
final class NavigateToLocalBookImportEffect extends WelcomeEffect {
  /// 创建本地书导入导航副作用。
  const NavigateToLocalBookImportEffect();
}

/// 请求路由层打开应用设置页面。
final class NavigateToSettingsEffect extends WelcomeEffect {
  /// 创建无附加数据的设置页导航副作用。
  const NavigateToSettingsEffect();
}
