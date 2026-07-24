import 'dart:async';

import '../../help/crash_reporting/crash_report_manager.dart';
import 'crash_report_management_contract.dart';

/// 协调报告列表、上传和删除，避免 UI 直接访问文件或网络。
final class CrashReportManagementViewModel {
  /// 创建并立即加载报告列表。
  CrashReportManagementViewModel({required CrashReportManager manager}) : _manager = manager { onIntent(const ReloadCrashReportsIntent()); }

  /// 应用组合根注入的崩溃报告边界。
  final CrashReportManager _manager;
  /// 状态广播流控制器。
  final StreamController<CrashReportManagementUiState> _stateController = StreamController<CrashReportManagementUiState>.broadcast();
  /// 一次性副作用广播流控制器。
  final StreamController<CrashReportManagementEffect> _effectController = StreamController<CrashReportManagementEffect>.broadcast();
  /// 当前状态快照。
  CrashReportManagementUiState _state = const CrashReportManagementUiState(isLoading: true);

  /// 页面订阅的状态流。
  Stream<CrashReportManagementUiState> get states => _stateController.stream;
  /// Route 订阅的一次性副作用流。
  Stream<CrashReportManagementEffect> get effects => _effectController.stream;
  /// 页面初始化时读取的状态快照。
  CrashReportManagementUiState get state => _state;

  /// 用户操作统一入口。
  void onIntent(CrashReportManagementIntent intent) {
    switch (intent) {
      case ReloadCrashReportsIntent(): unawaited(_reload());
      case UploadCrashReportIntent(report: final CrashReportFile report): unawaited(_upload(report));
      case ViewCrashReportIntent(report: final CrashReportFile report): unawaited(_view(report));
      case ShareCrashReportIntent(report: final CrashReportFile report): _effectController.add(ShareCrashReportEffect(report));
      case DeleteCrashReportIntent(report: final CrashReportFile report): unawaited(_delete(report));
      case DeleteAllCrashReportsIntent(): unawaited(_deleteAll());
    }
  }

  /// 从文件边界重新读取列表。
  Future<void> _reload() async {
    _emit(const CrashReportManagementUiState(isLoading: true));
    try { _emit(CrashReportManagementUiState(reports: List<CrashReportFile>.unmodifiable(await _manager.listReports()))); }
    on Object { _emit(const CrashReportManagementUiState(errorMessage: '读取崩溃日志失败，请稍后重试。')); }
  }
  /// 上传成功或失败后均刷新状态。
  Future<void> _upload(CrashReportFile report) async {
    _emit(CrashReportManagementUiState(isLoading: true, reports: _state.reports));
    try { await _manager.upload(report); _effectController.add(const ShowCrashReportMessageEffect('崩溃日志已上传。')); }
    on Object { _effectController.add(const ShowCrashReportMessageEffect('崩溃日志上传失败，可稍后重试。')); }
    await _reload();
  }
  /// 读取脱敏 JSON 并交给 Route 打开查看器。
  Future<void> _view(CrashReportFile report) async {
    try { _effectController.add(ShowCrashReportContentEffect(await _manager.readReport(report))); }
    on Object { _effectController.add(const ShowCrashReportMessageEffect('读取崩溃日志失败。')); }
  }
  /// 删除单份报告后刷新列表。
  Future<void> _delete(CrashReportFile report) async {
    try { await _manager.deleteReport(report); _effectController.add(const ShowCrashReportMessageEffect('崩溃日志已删除。')); await _reload(); }
    on Object { _effectController.add(const ShowCrashReportMessageEffect('删除崩溃日志失败。')); }
  }
  /// 删除全部报告后刷新列表。
  Future<void> _deleteAll() async {
    try { await _manager.deleteAllReports(); _effectController.add(const ShowCrashReportMessageEffect('全部崩溃日志已删除。')); await _reload(); }
    on Object { _effectController.add(const ShowCrashReportMessageEffect('删除崩溃日志失败。')); }
  }
  /// 更新快照并通知未释放的页面订阅。
  void _emit(CrashReportManagementUiState state) { _state = state; if (!_stateController.isClosed) { _stateController.add(state); } }
  /// 释放页面生命周期内创建的流控制器。
  Future<void> dispose() async { await _stateController.close(); await _effectController.close(); }
}
