import 'dart:async';

import '../../domain/gateway/adult_content_gateway.dart';
import '../../help/error/app_error.dart';
import 'about_contract.dart';

/// 管理“关于”页的连点解锁手势、成人内容屏蔽开关和词库更新。
final class AboutViewModel {
  /// 创建“关于”页 ViewModel，并立即读取当前屏蔽状态。
  AboutViewModel({required AdultContentGateway adultContentGateway})
      : _adultContentGateway = adultContentGateway {
    onIntent(const LoadAboutStateIntent());
  }

  /// 应用组合根注入的成人内容屏蔽边界。
  final AdultContentGateway _adultContentGateway;

  /// 当前页面状态广播控制器。
  final StreamController<AboutUiState> _stateController =
      StreamController<AboutUiState>.broadcast();

  /// 一次性副作用广播控制器。
  final StreamController<AboutEffect> _effectController =
      StreamController<AboutEffect>.broadcast();

  /// 当前页面状态快照。
  AboutUiState _state = const AboutUiState();

  /// 页面可订阅的状态流。
  Stream<AboutUiState> get states => _stateController.stream;

  /// 页面读取的当前状态快照。
  AboutUiState get state => _state;

  /// 路由层可订阅的一次性副作用流。
  Stream<AboutEffect> get effects => _effectController.stream;

  /// 连点手势判定用的最近点击时间戳队列，单位毫秒。
  final List<int> _iconTapTimestampsMs = <int>[];

  /// 连点判定窗口：窗口外的旧点击不计入次数。
  static const Duration _tapWindow = Duration(seconds: 2);

  /// 判定为解锁手势所需的连续点击次数。
  static const int _requiredTapCount = 5;

  /// “关于”页全部用户操作的统一入口。
  void onIntent(AboutIntent intent) {
    switch (intent) {
      case LoadAboutStateIntent():
        unawaited(_load());
      case TapAppIconIntent():
        _onTapAppIcon();
      case ToggleBlockAdultContentIntent(enabled: final bool enabled):
        unawaited(_toggleBlocking(enabled));
      case UpdateAdultKeywordsIntent():
        unawaited(_updateKeywords());
    }
  }

  /// 读取当前屏蔽开关和生效词库数量。
  Future<void> _load() async {
    /// 当前是否屏蔽成人内容。
    final bool enabled = await _adultContentGateway.isBlockingEnabled();
    /// 当前生效关键词数量。
    final int count = await _adultContentGateway.keywordCount();
    _emitState(
      _state.copyWith(blockAdultContent: enabled, adultKeywordCount: count),
    );
  }

  /// 记录一次应用图标点击，在 2 秒内累计 5 次后解锁内容过滤管理入口。
  void _onTapAppIcon() {
    if (_state.contentFilterUnlocked) {
      return;
    }
    /// 当前点击时间戳。
    final int now = DateTime.now().millisecondsSinceEpoch;
    _iconTapTimestampsMs.add(now);
    _iconTapTimestampsMs.removeWhere(
      (int timestamp) => now - timestamp > _tapWindow.inMilliseconds,
    );
    if (_iconTapTimestampsMs.length >= _requiredTapCount) {
      _iconTapTimestampsMs.clear();
      _emitState(_state.copyWith(contentFilterUnlocked: true));
      _effectController.add(const ShowAboutMessageEffect('内容过滤管理已解锁'));
    }
  }

  /// 修改是否屏蔽成人内容并立即生效。
  Future<void> _toggleBlocking(bool enabled) async {
    await _adultContentGateway.setBlockingEnabled(enabled);
    _emitState(_state.copyWith(blockAdultContent: enabled));
  }

  /// 从远程拉取最新成人内容词库。
  Future<void> _updateKeywords() async {
    _emitState(_state.copyWith(updatingAdultKeywords: true));
    try {
      /// 更新成功后的最新关键词数量。
      final int count = await _adultContentGateway.updateFromRemote();
      _emitState(
        _state.copyWith(updatingAdultKeywords: false, adultKeywordCount: count),
      );
      _effectController.add(ShowAboutMessageEffect('词库更新成功，当前共 $count 条'));
    } on Object catch (error) {
      _emitState(_state.copyWith(updatingAdultKeywords: false));
      _effectController.add(
        ShowAboutMessageEffect('词库更新失败：${_safeMessage(error)}'),
      );
    }
  }

  /// 提取可安全展示给用户的错误摘要。
  String _safeMessage(Object error) {
    if (error is AppError) {
      return error.message;
    }
    return '请稍后重试';
  }

  /// 更新当前状态并通知页面监听器。
  void _emitState(AboutUiState state) {
    _state = state;
    if (!_stateController.isClosed) {
      _stateController.add(state);
    }
  }

  /// 释放页面生命周期持有的状态和副作用流。
  Future<void> dispose() async {
    await _stateController.close();
    await _effectController.close();
  }
}
