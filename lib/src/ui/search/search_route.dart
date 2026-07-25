import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/js/js_engine.dart';
import '../../api/js/script_interaction_broker.dart';
import '../../app/app_dependencies.dart';
import '../../app/app_route.dart';
import '../../help/logging/app_logger.dart';
import '../book_info/book_info_contract.dart';
import '../book_source/book_source_login_route.dart';
import 'search_contract.dart';
import 'search_screen.dart';
import 'search_view_model.dart';

/// 连接搜索 ViewModel 生命周期、Effect 和纯 UI 的路由层。
final class SearchRoute extends StatefulWidget {
  /// 创建搜索路由。
  const SearchRoute({
    required this.dependencies,
    this.embedded = false,
    super.key,
  });
  /// 应用组合根依赖。
  final AppDependencies dependencies;

  /// 是否嵌入应用一级导航；嵌入时不显示返回按钮。
  final bool embedded;

  /// 创建路由状态。
  @override
  State<SearchRoute> createState() => _SearchRouteState();
}

/// 持有搜索 ViewModel 与 Effect 订阅。
final class _SearchRouteState extends State<SearchRoute> {
  /// 页面生命周期内唯一 ViewModel。
  late final SearchViewModel _viewModel;
  /// Effect 订阅。
  late final StreamSubscription<SearchEffect> _effectSubscription;
  /// 当前搜索页挂载到应用级交互队列的稳定处理器实例。
  late final LegadoScriptInteractionHandler _scriptInteractionHandler;

  /// 创建 ViewModel 并开始监听 Effect。
  @override
  void initState() {
    super.initState();
    _scriptInteractionHandler = _handleScriptInteraction;
    widget.dependencies.scriptInteractionBroker.attachHandler(
      _scriptInteractionHandler,
    );
    _viewModel = SearchViewModel(
      coordinator: widget.dependencies.createBookSearchCoordinator(),
      historyGateway: widget.dependencies.searchHistoryGateway,
      searchPreferences: widget.dependencies.searchPreferences,
      analyticsRecorder:
          widget.dependencies.remoteBookSourceSyncService.recordAnalyticsEvent,
      logger: widget.dependencies.logger,
    );
    _effectSubscription = _viewModel.effects.listen(_handleEffect);
  }

  /// 串行处理书源脚本发起的登录、网页验证或图片验证码请求。
  Future<void> _handleScriptInteraction(
    LegadoScriptInteractionRequest request,
  ) async {
    if (!mounted) {
      request.fail(
        const JsEngineException(
          kind: JsFailureKind.interactionRequired,
          message: '搜索页面已关闭，无法展示书源登录或验证',
        ),
      );
      return;
    }
    /// 用户是否确认让当前书源进入可见交互流程。
    final bool confirmed = await _confirmScriptInteraction(request);
    if (request.isCompleted) {
      return;
    }
    if (!confirmed) {
      request.cancelByUser();
      return;
    }
    switch (request.kind) {
      case LegadoScriptInteractionKind.browser:
        await _openScriptBrowser(request);
      case LegadoScriptInteractionKind.verificationCode:
        await _showVerificationCodeDialog(request);
    }
  }

  /// 仅展示书源名称和交互类型，禁止把 URL、Cookie 或页面正文带入提示框。
  Future<bool> _confirmScriptInteraction(
    LegadoScriptInteractionRequest request,
  ) async {
    /// 对话框中可安全展示的书源名称。
    final String sourceName = request.sourceName.trim().isEmpty
        ? '当前书源'
        : request.sourceName.trim();
    /// 根据请求类型生成不含敏感数据的操作说明。
    final String interactionLabel = switch (request.kind) {
      LegadoScriptInteractionKind.browser => '登录或网页验证',
      LegadoScriptInteractionKind.verificationCode => '图片验证码',
    };
    /// 用户对本次单独交互请求的明确选择。
    final bool? confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: Text(interactionLabel),
          content: Text('书源“$sourceName”请求$interactionLabel，是否继续？'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('继续'),
            ),
          ],
        );
      },
    );
    return confirmed ?? false;
  }

  /// 打开受控 WebView，并把用户完成时的最终地址和 HTML 返回给脚本桥。
  Future<void> _openScriptBrowser(
    LegadoScriptInteractionRequest request,
  ) async {
    if (!mounted) {
      request.cancelByUser();
      return;
    }
    /// 受控登录页关闭时返回的页面快照；返回空值表示用户主动取消。
    final BookSourceLoginResult? result = await Navigator.of(context)
        .push<BookSourceLoginResult>(
          MaterialPageRoute<BookSourceLoginResult>(
            builder: (BuildContext routeContext) => BookSourceLoginRoute(
              dependencies: widget.dependencies,
              sourceUrl: request.targetUri.toString(),
              title: request.title,
              initialHtml: request.html,
              capturePageResult: request.requiresPageResult,
            ),
          ),
        );
    if (request.isCompleted) {
      return;
    }
    if (result == null) {
      if (request.requiresPageResult) {
        request.cancelByUser();
      } else {
        request.complete(
          LegadoScriptInteractionResult(
            finalUri: request.targetUri,
            value: '',
          ),
        );
      }
      return;
    }
    request.complete(
      LegadoScriptInteractionResult(
        finalUri: result.finalUri,
        value: result.html,
      ),
    );
  }

  /// 展示携带统一 Cookie 的验证码图片，并把用户输入的文本返回给脚本桥。
  Future<void> _showVerificationCodeDialog(
    LegadoScriptInteractionRequest request,
  ) async {
    /// 验证码输入框控制器，只在当前串行提示生命周期内存在。
    final TextEditingController codeController = TextEditingController();
    /// 验证码图片请求头；获取失败时保持空集合，由服务器按未登录请求处理。
    Map<String, String> imageHeaders = const <String, String>{};
    try {
      /// 当前验证码域可发送的统一 Cookie 请求头，绝不写入日志或界面。
      final String cookieHeader = await widget.dependencies.cookieManager
          .getCookieHeader(request.targetUri);
      if (cookieHeader.isNotEmpty) {
        imageHeaders = <String, String>{'Cookie': cookieHeader};
      }
    } catch (error) {
      imageHeaders = const <String, String>{};
    }
    if (!mounted || request.isCompleted) {
      codeController.dispose();
      return;
    }
    /// 用户提交的验证码；对话框关闭或取消时为空。
    String? submittedCode;
    try {
      submittedCode = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext dialogContext) {
          return AlertDialog(
            title: Text(request.title.trim().isEmpty ? '输入验证码' : request.title.trim()),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Image.network(
                  request.targetUri.toString(),
                  headers: imageHeaders,
                  fit: BoxFit.contain,
                  errorBuilder: (
                    BuildContext imageContext,
                    Object imageError,
                    StackTrace? imageStackTrace,
                  ) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Text('验证码图片加载失败，请取消后重试'),
                    );
                  },
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: codeController,
                  autofocus: true,
                  textInputAction: TextInputAction.done,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: '验证码',
                  ),
                  onSubmitted: (String value) {
                    Navigator.of(dialogContext).pop(value.trim());
                  },
                ),
              ],
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () {
                  Navigator.of(dialogContext).pop(codeController.text.trim());
                },
                child: const Text('确定'),
              ),
            ],
          );
        },
      );
    } finally {
      codeController.dispose();
    }
    if (request.isCompleted) {
      return;
    }
    /// 去除用户误输入的首尾空白后的验证码。
    final String normalizedCode = submittedCode?.trim() ?? '';
    if (normalizedCode.isEmpty) {
      request.cancelByUser();
      return;
    }
    request.complete(
      LegadoScriptInteractionResult(
        finalUri: request.targetUri,
        value: normalizedCode,
      ),
    );
  }

  /// 执行搜索页导航和提示副作用。
  void _handleEffect(SearchEffect effect) {
    if (!mounted) {
      return;
    }
    switch (effect) {
      case OpenBookInfoEffect(group: final group, book: final book):
        /// 【搜书诊断日志】记录搜索结果点击后真正执行详情页导航的边界。
        widget.dependencies.logger.info(
          tag: bookDetailLogTag,
          message: '导航到书籍详情 candidateCount=${group.books.length} '
              'bookId=${appLogDiagnosticId(book.bookUrl)} '
              'sourceId=${appLogDiagnosticId(book.origin)}',
        );
        Navigator.of(context).pushNamed(
          AppRoute.bookInfo,
          arguments: BookInfoRouteArguments(
            group: group,
            selectedBook: book,
            analyticsEntry: 'search',
          ),
        );
      case ShowSearchMessageEffect(message: final String message):
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(message)));
      case CloseSearchEffect():
        Navigator.of(context).maybePop();
    }
  }

  /// 释放订阅和 ViewModel。
  @override
  void dispose() {
    widget.dependencies.scriptInteractionBroker.detachHandler(
      _scriptInteractionHandler,
    );
    _effectSubscription.cancel();
    _viewModel.dispose();
    super.dispose();
  }

  /// 订阅状态并连接纯 UI。
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<SearchUiState>(
      stream: _viewModel.states,
      initialData: _viewModel.state,
      builder: (BuildContext context, AsyncSnapshot<SearchUiState> snapshot) {
        /// 当前可渲染状态。
        final SearchUiState state = snapshot.data ?? _viewModel.state;
        return SearchScreen(
          state: state,
          onIntent: _viewModel.onIntent,
          showBackButton: !widget.embedded,
        );
      },
    );
  }
}
