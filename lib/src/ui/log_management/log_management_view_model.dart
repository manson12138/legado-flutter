import 'dart:async';

import '../../help/logging/app_log_manager.dart';
import 'log_management_contract.dart';

/// 管理日志列表、文件操作和一次性页面副作用。
final class LogManagementViewModel {
  /// 创建日志管理 ViewModel，并立即加载沙盒日志列表。
  LogManagementViewModel({required AppLogManager logManager})
      : _logManager = logManager {
    onIntent(const ReloadLogFilesIntent());
  }

  /// 应用组合根注入的日志管理边界。
  final AppLogManager _logManager;

  /// 当前页面状态广播控制器。
  final StreamController<LogManagementUiState> _stateController =
      StreamController<LogManagementUiState>.broadcast();

  /// 一次性副作用广播控制器。
  final StreamController<LogManagementEffect> _effectController =
      StreamController<LogManagementEffect>.broadcast();

  /// 当前页面状态快照。
  LogManagementUiState _state = const LogManagementUiState(isLoading: true);

  /// 页面可订阅的状态流。
  Stream<LogManagementUiState> get states => _stateController.stream;

  /// 页面读取的当前状态快照。
  LogManagementUiState get state => _state;

  /// 路由层可订阅的一次性副作用流。
  Stream<LogManagementEffect> get effects => _effectController.stream;

  /// 日志管理页全部用户操作的统一入口。
  void onIntent(LogManagementIntent intent) {
    switch (intent) {
      case ReloadLogFilesIntent():
        unawaited(_reload());
      case ViewLogFileIntent(file: final AppLogFile file):
        unawaited(_view(file));
      case ShareLogFileIntent(file: final AppLogFile file):
        _effectController.add(ShareLogFileEffect(file));
      case EchoLogFileIntent(file: final AppLogFile file):
        unawaited(_echo(file));
      case DeleteLogFileIntent(file: final AppLogFile file):
        unawaited(_delete(file));
      case DeleteAllLogFilesIntent():
        unawaited(_deleteAll());
    }
  }

  /// 读取最新日志文件列表并更新页面状态。
  Future<void> _reload() async {
    _emitState(_state.copyWith(isLoading: true, clearError: true));
    try {
      final List<AppLogFile> files = await _logManager.listLogFiles();
      _emitState(
        LogManagementUiState(
          files: List<AppLogFile>.unmodifiable(files),
        ),
      );
    } on Object {
      _emitState(
        _state.copyWith(
          isLoading: false,
          errorMessage: '读取日志列表失败，请稍后重试。',
        ),
      );
    }
  }

  /// 完整读取目标日志，并把内容交给路由层打开查看器。
  Future<void> _view(AppLogFile file) async {
    try {
      final String content = await _logManager.readLogFile(file);
      _effectController.add(ShowLogContentEffect(file: file, content: content));
    } on Object {
      _effectController.add(const ShowLogMessageEffect('读取日志文件失败。'));
    }
  }

  /// 把目标日志完整分段输出到 ADB，并通知用户操作完成。
  Future<void> _echo(AppLogFile file) async {
    try {
      await _logManager.echoLogFileToAdb(file);
      _effectController.add(
        ShowLogMessageEffect('已将 ${file.name} 完整回显到 ADB。'),
      );
    } on Object {
      _effectController.add(const ShowLogMessageEffect('回显到 ADB 失败。'));
    }
  }

  /// 删除单个日志文件后重新加载列表。
  Future<void> _delete(AppLogFile file) async {
    try {
      await _logManager.deleteLogFile(file);
      _effectController.add(ShowLogMessageEffect('已删除 ${file.name}。'));
      await _reload();
    } on Object {
      _effectController.add(const ShowLogMessageEffect('删除日志文件失败。'));
    }
  }

  /// 删除全部日志文件后重新加载列表。
  Future<void> _deleteAll() async {
    try {
      await _logManager.deleteAllLogFiles();
      _effectController.add(const ShowLogMessageEffect('已删除全部日志。'));
      await _reload();
    } on Object {
      _effectController.add(const ShowLogMessageEffect('删除全部日志失败。'));
    }
  }

  /// 更新当前状态并通知页面监听器。
  void _emitState(LogManagementUiState state) {
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
