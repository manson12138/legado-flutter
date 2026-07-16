import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_dependencies.dart';
import '../../domain/usecase/change_book_source_use_case.dart';
import 'change_book_source_contract.dart';
import 'change_book_source_screen.dart';
import 'change_book_source_view_model.dart';

/// 连接整书换源 ViewModel 生命周期、Effect 和纯 UI 的路由层。
final class ChangeBookSourceRoute extends StatefulWidget {
  /// 创建整书换源路由。
  const ChangeBookSourceRoute({
    required this.dependencies,
    required this.bookUrl,
    super.key,
  });

  /// 应用组合根依赖。
  final AppDependencies dependencies;

  /// 需要从数据库重新确认的旧书籍稳定 URL。
  final String bookUrl;

  /// 创建路由状态。
  @override
  State<ChangeBookSourceRoute> createState() => _ChangeBookSourceRouteState();
}

/// 持有页面生命周期独占 ViewModel 和 Effect 订阅。
final class _ChangeBookSourceRouteState extends State<ChangeBookSourceRoute> {
  /// 当前页面唯一的整书换源 ViewModel。
  late final ChangeBookSourceViewModel _viewModel;

  /// 一次性 Effect 订阅。
  late final StreamSubscription<ChangeBookSourceEffect> _effectSubscription;

  /// 只有 ViewModel 确认可以离开或事务完成后才允许路由真正弹出。
  bool _allowPop = false;

  /// 创建 ViewModel 并开始监听换源结果。
  @override
  void initState() {
    super.initState();
    _viewModel = ChangeBookSourceViewModel(
      bookUrl: widget.bookUrl,
      bookshelfGateway: widget.dependencies.bookshelfGateway,
      coordinator: widget.dependencies.createChangeSourceCoordinator(),
      changeBookSource: widget.dependencies.changeBookSource,
      cancellationTokenFactory: widget.dependencies.createHttpCancellationToken,
      logger: widget.dependencies.logger,
    );
    _effectSubscription = _viewModel.effects.listen(_handleEffect);
  }

  /// 执行 Snackbar、关闭页面和携带新书主键返回调用页的副作用。
  void _handleEffect(ChangeBookSourceEffect effect) {
    if (!mounted) {
      return;
    }
    switch (effect) {
      case ShowChangeBookSourceMessageEffect(message: final String message):
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(message)));
      case CloseChangeBookSourceEffect():
        _requestPop();
      case CompleteChangeBookSourceEffect(result: final result):
        _requestPop(result);
    }
  }

  /// 下一帧解除返回拦截，并携带可选换源结果安全关闭当前路由。
  void _requestPop([ChangeBookSourceResult? result]) {
    if (_allowPop) {
      return;
    }
    setState(() {
      _allowPop = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((Duration timeStamp) {
      if (mounted) {
        Navigator.of(context).pop(result);
      }
    });
  }

  /// 取消任务、Effect 订阅和页面状态流。
  @override
  void dispose() {
    _effectSubscription.cancel();
    _viewModel.dispose();
    super.dispose();
  }

  /// 订阅 UiState 并连接无状态页面。
  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: _allowPop,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop) {
          _viewModel.onIntent(const BackFromChangeBookSourceIntent());
        }
      },
      child: StreamBuilder<ChangeBookSourceUiState>(
        stream: _viewModel.states,
        initialData: _viewModel.state,
        builder: (
          BuildContext context,
          AsyncSnapshot<ChangeBookSourceUiState> snapshot,
        ) {
          /// 当前可渲染的换源状态。
          final ChangeBookSourceUiState state = snapshot.data ?? _viewModel.state;
          return ChangeBookSourceScreen(
            state: state,
            onIntent: _viewModel.onIntent,
          );
        },
      ),
    );
  }
}
