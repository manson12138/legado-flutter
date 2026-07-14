import 'dart:async';

import '../../help/logging/app_logger.dart';
import 'welcome_contract.dart';

/// 管理欢迎页状态、Intent 分发和 Effect 生命周期的 MVI 示例 ViewModel。
///
/// ViewModel 通过构造参数获取依赖，不访问 BuildContext，也不直接执行导航或系统 UI。
final class WelcomeViewModel {
  /// 创建欢迎页 ViewModel，并保存页面生命周期内使用的日志抽象。
  WelcomeViewModel({required AppLogger logger}) : _logger = logger;

  /// 页面通过构造注入获得的日志抽象。
  final AppLogger _logger;

  /// 欢迎页长期状态；M1 没有异步业务，因此状态保持不可变。
  final WelcomeUiState state = const WelcomeUiState(
    title: 'Legado Flutter',
    description: '工程骨架已就绪。当前页面仅验证主题、路由、依赖注入和 MVI/UDF 边界，尚未实现书源、书架或阅读业务。',
  );

  /// 承载一次性副作用的广播控制器，避免副作用进入长期页面状态。
  final StreamController<WelcomeEffect> _effectController =
      StreamController<WelcomeEffect>.broadcast();

  /// 对路由层公开的只读副作用流。
  Stream<WelcomeEffect> get effects => _effectController.stream;

  /// 欢迎页所有用户操作的唯一入口。
  void onIntent(WelcomeIntent intent) {
    switch (intent) {
      case ConfirmScaffoldIntent():
        _confirmScaffold();
      case OpenBookSourceManagementIntent():
        _effectController.add(const NavigateToBookSourceManagementEffect());
      case OpenSearchIntent():
        _effectController.add(const NavigateToSearchEffect());
      case OpenBookshelfIntent():
        _effectController.add(const NavigateToBookshelfEffect());
      case OpenLocalBookImportIntent():
        _effectController.add(const NavigateToLocalBookImportEffect());
    }
  }

  /// 把骨架确认转换为一次性消息 Effect，并记录非敏感状态信息。
  void _confirmScaffold() {
    _logger.info(message: '用户已触发 M1 工程骨架确认');
    _effectController.add(
      const ShowWelcomeMessageEffect(
        message: '骨架连接正常，请继续按验收步骤检查。',
      ),
    );
  }

  /// 在页面路由销毁时关闭 Effect 流，避免监听器和异步资源泄漏。
  Future<void> dispose() async {
    await _effectController.close();
  }
}
