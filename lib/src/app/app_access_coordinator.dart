import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../api/remote_app/remote_app_api.dart';
import '../data/repository/remote_app_configuration_repository.dart';
import '../help/logging/app_logger.dart';
import 'remote_app_bootstrapper.dart';

/// 应用准入状态，只有服务端明确拒绝才阻断界面。
final class AppAccessState {
  /// 创建应用准入状态。
  const AppAccessState({this.isRestoring = false, this.isChecking = false, this.hasConfirmedStatus = false, this.isAllowed = true, this.hasUpdate = false, this.forceUpdate = false, this.message, this.versionName, this.latestVersionCode, this.downloadUrl, this.changelog});
  /// 是否正在恢复当前安装包已确认的本地准入状态。
  final bool isRestoring;
  /// 是否正在请求服务端状态。
  final bool isChecking;
  /// 是否已从本地缓存或服务端成功取得可用于判断“已是最新”的状态。
  final bool hasConfirmedStatus;
  /// 当前版本是否被服务端允许使用。
  final bool isAllowed;
  /// 是否有可用升级。
  final bool hasUpdate;
  /// 是否要求升级后才能继续使用。
  final bool forceUpdate;
  /// 服务端受控文案。
  final String? message;
  /// 服务端推荐版本。
  final String? versionName;
  /// 服务端最新构建号。
  final int? latestVersionCode;
  /// 经服务端配置的外部升级地址。
  final String? downloadUrl;
  /// 服务端版本更新说明。
  final String? changelog;
  /// 是否需要不可绕过地阻断应用业务界面。
  bool get isBlocking => !isAllowed || forceUpdate;
}

/// 前台生命周期内每五分钟检查一次应用准入的协调器。
final class AppAccessCoordinator with WidgetsBindingObserver {
  /// 创建应用准入协调器。
  AppAccessCoordinator(this._bootstrapper, this._repository, this._logger);
  /// 启动配置与过滤规则协调器。
  final RemoteAppBootstrapper _bootstrapper;
  /// 准入状态持久化读取边界。
  final RemoteAppConfigurationRepository _repository;
  /// 版本检查诊断日志；不记录账号、下载地址或服务端文案。
  final AppLogger _logger;
  /// 供应用根订阅的受控状态。
  final ValueNotifier<AppAccessState> state = ValueNotifier<AppAccessState>(const AppAccessState());
  /// 前台轮询计时器。
  Timer? _timer;
  /// 防止慢请求和下一个轮询并发。
  bool _requesting = false;
  /// 是否已经登记生命周期观察器。
  bool _started = false;

  /// 启动首次检查与前台定时轮询。
  void start({String trigger = 'authenticated_session'}) {
    if (_started) {
      _logger.info(
        tag: appAccessCheckLogTag,
        message: 'stage=start_skipped reason=already_started trigger=$trigger',
      );
      return;
    }
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    _logger.info(
      tag: appAccessCheckLogTag,
      message: 'stage=started trigger=$trigger',
    );
    state.value = _stateWith(isRestoring: true);
    unawaited(_restoreCachedStateAndRefresh(trigger));
  }

  /// 先恢复与当前安装包匹配的本地状态，再进行不阻塞 UI 的网络复查。
  Future<void> _restoreCachedStateAndRefresh(String trigger) async {
    try {
      final RemoteAppBootstrapStatus? cachedStatus =
          await _repository.loadCachedBootstrapStatus();
      if (cachedStatus != null) {
        state.value = _stateFromStatus(cachedStatus);
        _logger.info(
          tag: appAccessCheckLogTag,
          message: 'stage=cache_restored trigger=$trigger allowed=${cachedStatus.allowed} has_update=${cachedStatus.hasUpdate} force_update=${cachedStatus.forceUpdate}',
        );
      }
    } on Object catch (error) {
      _logger.warning(
        tag: appAccessCheckLogTag,
        message: 'stage=cache_restore_failed trigger=$trigger error_type=${error.runtimeType}',
        error: error,
      );
    } finally {
      if (state.value.isRestoring) {
        state.value = _stateWith(isRestoring: false);
      }
      _schedule();
      await refresh(trigger: trigger);
    }
  }

  /// 释放计时器、观察器和状态通知器，避免应用根销毁后泄漏。
  void dispose() { _timer?.cancel(); if (_started) { WidgetsBinding.instance.removeObserver(this); } state.dispose(); }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycleState) {
    if (lifecycleState == AppLifecycleState.resumed) {
      _logger.info(tag: appAccessCheckLogTag, message: 'stage=foreground_resumed');
      _schedule();
      unawaited(refresh(trigger: 'foreground_resumed'));
      return;
    }
    _logger.info(tag: appAccessCheckLogTag, message: 'stage=foreground_stopped lifecycle=$lifecycleState');
    _timer?.cancel();
    _timer = null;
  }

  /// 请求一次最新状态；网络失败维持已经确认的准入状态，避免误阻断。
  Future<void> refresh({String trigger = 'manual_retry'}) async {
    if (_requesting) {
      _logger.info(
        tag: appAccessCheckLogTag,
        message: 'stage=request_skipped reason=in_flight trigger=$trigger',
      );
      return;
    }
    _requesting = true;
    _logger.info(tag: appAccessCheckLogTag, message: 'stage=request_started trigger=$trigger');
    state.value = _stateWith(isChecking: true);
    try {
      final RemoteAppBootstrapStatus? status = await _bootstrapper.refreshInBackground();
      if (status != null) {
        state.value = _stateFromStatus(status);
        _logger.info(
          tag: appAccessCheckLogTag,
          message: 'stage=request_applied trigger=$trigger allowed=${status.allowed} has_update=${status.hasUpdate} force_update=${status.forceUpdate} latest_version=${status.versionName ?? 'none'} latest_version_code=${status.latestVersionCode?.toString() ?? 'none'} has_download_url=${status.downloadUrl?.trim().isNotEmpty == true} has_changelog=${status.changelog?.trim().isNotEmpty == true}',
        );
      } else {
        _logger.warning(
          tag: appAccessCheckLogTag,
          message: 'stage=request_degraded trigger=$trigger reason=bootstrap_unavailable',
        );
      }
    } on Object catch (error) {
      _logger.warning(
        tag: appAccessCheckLogTag,
        message: 'stage=request_failed trigger=$trigger error_type=${error.runtimeType}',
        error: error,
      );
    } finally {
      _requesting = false;
      if (state.value.isChecking) { state.value = _stateWith(isChecking: false); }
    }
  }

  /// 只在前台保留一个五分钟轮询计时器。
  void _schedule() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(minutes: 5), (Timer timer) {
      unawaited(refresh(trigger: 'foreground_interval'));
    });
    _logger.info(tag: appAccessCheckLogTag, message: 'stage=interval_scheduled minutes=5');
  }

  /// 将服务端已校验的状态转换为 UI 只读状态。
  AppAccessState _stateFromStatus(RemoteAppBootstrapStatus status) =>
      AppAccessState(
        hasConfirmedStatus: true,
        isAllowed: status.allowed,
        hasUpdate: status.hasUpdate,
        forceUpdate: status.forceUpdate,
        message: status.accessMessage,
        versionName: status.versionName,
        latestVersionCode: status.latestVersionCode,
        downloadUrl: status.downloadUrl,
        changelog: status.changelog,
      );

  /// 基于当前状态仅修改启动恢复或请求中标记，保留已确认的准入结果。
  AppAccessState _stateWith({bool? isRestoring, bool? isChecking}) =>
      AppAccessState(
        isRestoring: isRestoring ?? state.value.isRestoring,
        isChecking: isChecking ?? state.value.isChecking,
        hasConfirmedStatus: state.value.hasConfirmedStatus,
        isAllowed: state.value.isAllowed,
        hasUpdate: state.value.hasUpdate,
        forceUpdate: state.value.forceUpdate,
        message: state.value.message,
        versionName: state.value.versionName,
        latestVersionCode: state.value.latestVersionCode,
        downloadUrl: state.value.downloadUrl,
        changelog: state.value.changelog,
      );
}
