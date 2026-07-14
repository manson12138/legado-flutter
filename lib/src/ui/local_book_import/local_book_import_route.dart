import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_dependencies.dart';
import '../../domain/model/local_book.dart';
import '../../platform/local_book_platform_bridge.dart';
import 'local_book_import_contract.dart';
import 'local_book_import_screen.dart';
import 'local_book_import_view_model.dart';

/// 连接导入 ViewModel、文件选择平台边界和无状态 Screen。
final class LocalBookImportRoute extends StatefulWidget {
  /// 创建本地书导入路由。
  const LocalBookImportRoute({
    required this.dependencies,
    this.platformBridge = const DefaultLocalBookPlatformBridge(),
    super.key,
  });

  /// 应用组合根依赖。
  final AppDependencies dependencies;

  /// 系统文件选择平台边界。
  final LocalBookPlatformBridge platformBridge;

  /// 创建路由状态。
  @override
  State<LocalBookImportRoute> createState() => _LocalBookImportRouteState();
}

/// 持有页面 ViewModel 和 Effect 订阅生命周期。
final class _LocalBookImportRouteState extends State<LocalBookImportRoute> {
  /// 页面生命周期内唯一 ViewModel。
  late final LocalBookImportViewModel _viewModel;

  /// 一次性副作用订阅。
  late final StreamSubscription<LocalBookImportEffect> _effectSubscription;

  /// 创建 ViewModel 并监听平台副作用。
  @override
  void initState() {
    super.initState();
    _viewModel = LocalBookImportViewModel(
      coordinator: widget.dependencies.localBookImportCoordinator,
    );
    _effectSubscription = _viewModel.effects.listen(_handleEffect);
  }

  /// 在路由层执行文件选择、消息和返回行为。
  Future<void> _handleEffect(LocalBookImportEffect effect) async {
    switch (effect) {
      case PickLocalBooksEffect():
        try {
          /// 系统选择到且可立即复制的文件列表。
          final List<LocalBookPickedFile> files = await widget.platformBridge.pickBooks();
          if (files.isNotEmpty) {
            _viewModel.onIntent(LocalBooksPickedIntent(files));
          }
        } catch (error) {
          _showMessage(error is FormatException ? error.message.toString() : '读取系统文件失败');
        }
      case ShowLocalBookImportMessageEffect(message: final String message):
        _showMessage(message);
      case CloseLocalBookImportEffect():
        if (mounted) {
          await Navigator.of(context).maybePop();
        }
    }
  }

  /// 展示不会泄漏本地绝对路径的一次性消息。
  void _showMessage(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// 释放副作用订阅和 ViewModel 流。
  @override
  void dispose() {
    _effectSubscription.cancel();
    _viewModel.dispose();
    super.dispose();
  }

  /// 订阅状态并连接纯 UI。
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<LocalBookImportUiState>(
      stream: _viewModel.states,
      initialData: _viewModel.state,
      builder: (BuildContext context, AsyncSnapshot<LocalBookImportUiState> snapshot) {
        /// 当前可渲染页面状态。
        final LocalBookImportUiState state = snapshot.data ?? _viewModel.state;
        return LocalBookImportScreen(state: state, onIntent: _viewModel.onIntent);
      },
    );
  }
}
