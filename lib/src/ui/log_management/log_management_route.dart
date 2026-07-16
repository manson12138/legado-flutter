import 'dart:async';

import 'package:cross_file/cross_file.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/app_dependencies.dart';
import '../../help/logging/app_log_manager.dart';
import 'log_management_contract.dart';
import 'log_management_screen.dart';
import 'log_management_view_model.dart';

/// 连接日志 ViewModel 生命周期、系统分享和只读查看器的路由层。
final class LogManagementRoute extends StatefulWidget {
  /// 创建接收应用组合根依赖的日志管理路由。
  const LogManagementRoute({required this.dependencies, super.key});

  /// 应用组合根传入的共享依赖。
  final AppDependencies dependencies;

  /// 创建负责页面生命周期接线的 State。
  @override
  State<LogManagementRoute> createState() => _LogManagementRouteState();
}

/// 持有日志管理 ViewModel、状态和副作用订阅。
final class _LogManagementRouteState extends State<LogManagementRoute> {
  /// 页面生命周期内唯一的日志管理 ViewModel。
  late final LogManagementViewModel _viewModel;

  /// ViewModel 状态流订阅。
  late final StreamSubscription<LogManagementUiState> _stateSubscription;

  /// ViewModel 一次性副作用流订阅。
  late final StreamSubscription<LogManagementEffect> _effectSubscription;

  /// 当前用于渲染页面的状态快照。
  late LogManagementUiState _state;

  /// 创建 ViewModel 并订阅页面状态与副作用。
  @override
  void initState() {
    super.initState();
    _viewModel = LogManagementViewModel(logManager: widget.dependencies.logManager);
    _state = _viewModel.state;
    _stateSubscription = _viewModel.states.listen((LogManagementUiState state) {
      if (mounted) {
        setState(() {
          _state = state;
        });
      }
    });
    _effectSubscription = _viewModel.effects.listen(_handleEffect);
  }

  /// 把一次性副作用转换为 Snackbar、查看器或系统分享面板。
  void _handleEffect(LogManagementEffect effect) {
    if (!mounted) {
      return;
    }
    switch (effect) {
      case ShowLogMessageEffect(message: final String message):
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(message)));
      case ShowLogContentEffect(
          file: final AppLogFile file,
          content: final String content,
        ):
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (BuildContext context) {
              return LogViewerPage(file: file, content: content);
            },
          ),
        );
      case ShareLogFileEffect(file: final AppLogFile file):
        unawaited(_shareLogFile(file));
    }
  }

  /// 调用 Android/iOS 系统分享面板发送原始日志文件。
  Future<void> _shareLogFile(AppLogFile file) async {
    try {
      /// iPad 分享面板需要锚点；使用当前路由根节点的全局区域。
      final RenderObject? renderObject = context.findRenderObject();
      final Rect? shareOrigin = renderObject is RenderBox
          ? renderObject.localToGlobal(Offset.zero) & renderObject.size
          : null;
      await SharePlus.instance.share(
        ShareParams(
          files: <XFile>[XFile(file.path, mimeType: 'text/plain')],
          title: '分享日志 ${file.name}',
          subject: 'Legado Flutter 日志 ${file.name}',
          sharePositionOrigin: shareOrigin,
        ),
      );
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('分享日志失败。')));
      }
    }
  }

  /// 释放状态订阅、副作用订阅和 ViewModel 资源。
  @override
  void dispose() {
    _stateSubscription.cancel();
    _effectSubscription.cancel();
    _viewModel.dispose();
    super.dispose();
  }

  /// 把当前状态和 Intent 入口传给无状态页面。
  @override
  Widget build(BuildContext context) {
    return LogManagementScreen(
      state: _state,
      onIntent: _viewModel.onIntent,
      onBack: () {
        Navigator.of(context).pop();
      },
    );
  }
}
