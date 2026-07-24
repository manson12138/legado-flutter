import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../api/remote_app/remote_app_api.dart';
import 'remote_app_bootstrapper.dart';

/// 应用准入状态，只有服务端明确拒绝才阻断界面。
final class AppAccessState {
  /// 创建应用准入状态。
  const AppAccessState({this.isChecking = false, this.isAllowed = true, this.hasUpdate = false, this.forceUpdate = false, this.message, this.versionName, this.latestVersionCode, this.downloadUrl, this.changelog});
  /// 是否正在请求服务端状态。
  final bool isChecking;
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
  AppAccessCoordinator(this._bootstrapper);
  /// 启动配置与过滤规则协调器。
  final RemoteAppBootstrapper _bootstrapper;
  /// 供应用根订阅的受控状态。
  final ValueNotifier<AppAccessState> state = ValueNotifier<AppAccessState>(const AppAccessState());
  /// 前台轮询计时器。
  Timer? _timer;
  /// 防止慢请求和下一个轮询并发。
  bool _requesting = false;
  /// 是否已经登记生命周期观察器。
  bool _started = false;

  /// 启动首次检查与前台定时轮询。
  void start() {
    if (_started) { return; }
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    _schedule();
    unawaited(refresh());
  }

  /// 释放计时器、观察器和状态通知器，避免应用根销毁后泄漏。
  void dispose() { _timer?.cancel(); if (_started) { WidgetsBinding.instance.removeObserver(this); } state.dispose(); }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycleState) {
    if (lifecycleState == AppLifecycleState.resumed) { _schedule(); unawaited(refresh()); return; }
    _timer?.cancel();
    _timer = null;
  }

  /// 请求一次最新状态；网络失败维持已经确认的准入状态，避免误阻断。
  Future<void> refresh() async {
    if (_requesting) { return; }
    _requesting = true;
    state.value = AppAccessState(isChecking: true, isAllowed: state.value.isAllowed, hasUpdate: state.value.hasUpdate, forceUpdate: state.value.forceUpdate, message: state.value.message, versionName: state.value.versionName, latestVersionCode: state.value.latestVersionCode, downloadUrl: state.value.downloadUrl, changelog: state.value.changelog);
    try {
      final RemoteAppBootstrapStatus? status = await _bootstrapper.refreshInBackground();
      if (status != null) {
        state.value = AppAccessState(isAllowed: status.allowed, hasUpdate: status.hasUpdate, forceUpdate: status.forceUpdate, message: status.accessMessage, versionName: status.versionName, latestVersionCode: status.latestVersionCode, downloadUrl: status.downloadUrl, changelog: status.changelog);
      }
    } finally {
      _requesting = false;
      if (state.value.isChecking) { state.value = AppAccessState(isAllowed: state.value.isAllowed, hasUpdate: state.value.hasUpdate, forceUpdate: state.value.forceUpdate, message: state.value.message, versionName: state.value.versionName, latestVersionCode: state.value.latestVersionCode, downloadUrl: state.value.downloadUrl, changelog: state.value.changelog); }
    }
  }

  /// 只在前台保留一个五分钟轮询计时器。
  void _schedule() { _timer?.cancel(); _timer = Timer.periodic(const Duration(minutes: 5), (Timer timer) { unawaited(refresh()); }); }
}
