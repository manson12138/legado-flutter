import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_dependencies.dart';
import '../../app/app_route.dart';
import '../../domain/model/book.dart';
import '../../domain/model/local_book.dart';
import '../../platform/external_local_book_open_service.dart';
import '../../platform/local_book_platform_bridge.dart';
import 'local_book_import_contract.dart';
import 'local_book_import_screen.dart';
import 'local_book_import_view_model.dart';

/// 连接导入 ViewModel、文件选择平台边界和无状态 Screen。
final class LocalBookImportRoute extends StatefulWidget {
  /// 创建本地书导入路由。
  const LocalBookImportRoute({
    required this.dependencies,
    this.externalOpenService,
    this.initialExternalFile,
    this.externalCleanupToken,
    this.platformBridge = const DefaultLocalBookPlatformBridge(),
    super.key,
  });

  /// 应用组合根依赖。
  final AppDependencies dependencies;

  /// Android 外部打开临时副本的释放边界。
  final ExternalLocalBookOpenService? externalOpenService;

  /// 外部“打开方式”入口预先提供的单个 TXT 候选。
  final LocalBookPickedFile? initialExternalFile;

  /// 与初始外部候选配对的一次性清理 token。
  final String? externalCleanupToken;

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

  /// 页面状态订阅，用于在单文件导入结束后及时释放外部临时副本。
  late final StreamSubscription<LocalBookImportUiState> _stateSubscription;

  /// 是否已经请求释放本页面拥有的外部临时副本。
  bool _externalTemporaryReleased = false;

  /// 是否已经开始用阅读器替换当前导入页，防止重复 Effect 创建重复路由。
  bool _openingImportedReader = false;

  /// 创建 ViewModel 并监听平台副作用。
  @override
  void initState() {
    super.initState();
    _viewModel = LocalBookImportViewModel(
      coordinator: widget.dependencies.localBookImportCoordinator,
    );
    _effectSubscription = _viewModel.effects.listen(_handleEffect);
    _stateSubscription = _viewModel.states.listen(_handleState);
    /// 外部打开候选直接进入确认列表，不自动写入书架。
    final LocalBookPickedFile? initialExternalFile =
        widget.initialExternalFile;
    if (initialExternalFile != null) {
      _viewModel.onIntent(
        LocalBooksPickedIntent(<LocalBookPickedFile>[initialExternalFile]),
      );
    }
  }

  /// 在外部候选导入成功、更新或失败后释放只供本次操作使用的 cache 副本。
  void _handleState(LocalBookImportUiState state) {
    if (_externalTemporaryReleased) {
      return;
    }
    final LocalBookPickedFile? initialExternalFile =
        widget.initialExternalFile;
    if (initialExternalFile == null) {
      return;
    }
    /// 与外部临时路径对应的当前候选状态。
    LocalBookImportItemStatus? externalStatus;
    for (final LocalBookImportItem item in state.items) {
      if (item.file.path == initialExternalFile.path) {
        externalStatus = item.status;
        break;
      }
    }
    if (externalStatus == LocalBookImportItemStatus.imported ||
        externalStatus == LocalBookImportItemStatus.updated ||
        externalStatus == LocalBookImportItemStatus.failed) {
      _releaseExternalTemporary();
    }
  }

  /// 在路由层执行文件选择、消息和返回行为。
  Future<void> _handleEffect(LocalBookImportEffect effect) async {
    switch (effect) {
      case PickLocalBooksEffect():
        try {
          /// 系统选择到且可立即复制的文件列表。
          final List<LocalBookPickedFile> files = await widget.platformBridge.pickBooks();
          if (files.isNotEmpty) {
            /// 新选择会替换现有候选，替换前释放不再使用的外部 cache 文件。
            _releaseExternalTemporary();
            _viewModel.onIntent(LocalBooksPickedIntent(files));
          }
        } catch (error) {
          _showMessage(error is FormatException ? error.message.toString() : '读取系统文件失败');
        }
      case ShowLocalBookImportMessageEffect(message: final String message):
        _showMessage(message);
      case OpenImportedLocalBookReaderEffect(
        book: final Book book,
        message: final String message,
      ):
        unawaited(_openImportedReader(book, message));
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

  /// 用已经保存的书籍快照替换导入页，并交给统一入口分流文本或 PDF 阅读器。
  Future<void> _openImportedReader(Book book, String message) async {
    if (_openingImportedReader || !mounted) {
      return;
    }
    _openingImportedReader = true;
    try {
      await Navigator.of(context).pushReplacementNamed<void, void>(
        AppRoute.reader,
        arguments: ReaderRouteArguments(
          bookUrl: book.bookUrl,
          initialMessage: message,
          initialBook: book,
          initialIsInBookshelf: true,
          entry: 'bookshelf',
        ),
      );
    } on Object {
      _openingImportedReader = false;
      _showMessage('书籍已加入书架，但暂时无法打开阅读器');
    }
  }

  /// 幂等释放 Android 原生层生成的一次性外部 TXT 临时副本。
  void _releaseExternalTemporary() {
    if (_externalTemporaryReleased) {
      return;
    }
    /// 只有非空 token 才表示本页面拥有外部临时副本。
    final String cleanupToken = widget.externalCleanupToken?.trim() ?? '';
    if (cleanupToken.isEmpty) {
      return;
    }
    _externalTemporaryReleased = true;
    final ExternalLocalBookOpenService? externalOpenService =
        widget.externalOpenService;
    if (externalOpenService != null) {
      unawaited(externalOpenService.releaseTemporary(cleanupToken));
    }
  }

  /// 释放副作用订阅和 ViewModel 流。
  @override
  void dispose() {
    _releaseExternalTemporary();
    _effectSubscription.cancel();
    _stateSubscription.cancel();
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
        return PopScope(
          canPop: !state.busy,
          child: LocalBookImportScreen(
            state: state,
            onIntent: _viewModel.onIntent,
          ),
        );
      },
    );
  }
}
