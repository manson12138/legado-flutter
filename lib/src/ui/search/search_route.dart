import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/js/js_engine.dart';
import '../../api/js/script_interaction_broker.dart';
import '../../app/app_dependencies.dart';
import '../../app/app_navigation_observer.dart';
import '../../app/app_route.dart';
import '../../help/logging/app_logger.dart';
import '../book_info/book_info_contract.dart';
import '../book_source/book_source_login_route.dart';
import '../book_source/book_source_route.dart';
import 'search_contract.dart';
import 'search_screen.dart';
import 'search_view_model.dart';

/// 连接搜索 ViewModel 生命周期、Effect 和纯 UI 的路由层。
final class SearchRoute extends StatefulWidget {
  /// 创建搜索路由。
  const SearchRoute({
    required this.dependencies,
    required this.navigationObserver,
    this.embedded = false,
    this.onOpenBookSourceManagement,
    super.key,
  });
  /// 应用组合根依赖。
  final AppDependencies dependencies;

  /// 应用级路由观察器，用于详情和阅读链路最终离开后恢复搜索。
  final AppNavigationObserver navigationObserver;

  /// 是否嵌入应用一级导航；嵌入时不显示返回按钮。
  final bool embedded;

  /// 内嵌搜索页请求切换到书源管理一级页面并展示提示的回调。
  final ValueChanged<String>? onOpenBookSourceManagement;

  /// 创建路由状态。
  @override
  State<SearchRoute> createState() => _SearchRouteState();
}

/// 持有搜索 ViewModel 与 Effect 订阅。
final class _SearchRouteState extends State<SearchRoute> with RouteAware {
  /// 页面生命周期内唯一 ViewModel。
  late final SearchViewModel _viewModel;
  /// Effect 订阅。
  late final StreamSubscription<SearchEffect> _effectSubscription;
  /// 当前搜索页挂载到应用级交互队列的稳定处理器实例。
  late final LegadoScriptInteractionHandler _scriptInteractionHandler;
  /// 当前订阅的宿主路由；内嵌模式下为主框架路由。
  ModalRoute<dynamic>? _subscribedRoute;
  /// 是否正在等待书籍详情及其后续阅读链路全部离开。
  bool _waitingForBookInfoReturn = false;
  /// 防止连续点击同一结果产生重复详情路由。
  bool _openingBookInfo = false;
  /// 搜索页“全部开启”确认框是否已经交给 Navigator 展示。
  bool _enableAllSearchSourcesDialogVisible = false;

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
      userScopeListenable: widget.dependencies.currentUserScope.userId,
      analyticsRecorder:
          widget.dependencies.remoteBookSourceSyncService.recordAnalyticsEvent,
      logger: widget.dependencies.logger,
    );
    _effectSubscription = _viewModel.effects.listen(_handleEffect);
  }

  /// 订阅当前宿主路由的可见性变化；依赖变化时先解除旧订阅。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    /// 当前搜索 Widget 所属的真实 Navigator 路由。
    final ModalRoute<dynamic>? route = ModalRoute.of(context);
    if (identical(route, _subscribedRoute)) {
      return;
    }
    if (_subscribedRoute != null) {
      widget.navigationObserver.unsubscribe(this);
    }
    _subscribedRoute = route;
    if (route != null) {
      widget.navigationObserver.subscribe(this, route);
    }
  }

  /// 只有搜索页宿主路由真正重新可见时才恢复，换源替换详情路由不会误触发。
  @override
  void didPopNext() {
    _resumeSearchAfterBookInfo();
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
        if (_openingBookInfo) {
          return;
        }
        _openingBookInfo = true;
        _waitingForBookInfoReturn = _viewModel.state.pausedForBookInfo;
        /// 【搜书诊断日志】记录搜索结果点击后真正执行详情页导航的边界。
        widget.dependencies.logger.info(
          tag: bookDetailLogTag,
          message: '导航到书籍详情 candidateCount=${group.books.length} '
              'bookId=${appLogDiagnosticId(book.bookUrl)} '
              'sourceId=${appLogDiagnosticId(book.origin)}',
        );
        unawaited(
          _openBookInfo(
            BookInfoRouteArguments(
              group: group,
              selectedBook: book,
              analyticsEntry: 'search',
            ),
          ),
        );
      case ShowSearchMessageEffect(message: final String message):
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(message)));
      case OpenBookSourceManagementEffect(message: final String message):
        unawaited(_openBookSourceManagement(message));
      case CloseSearchEffect():
        Navigator.of(context).maybePop();
    }
  }

  /// 打开书源管理；内嵌页面切换一级目的地，独立页面压入命名路由。
  Future<void> _openBookSourceManagement(String message) async {
    /// 主框架提供的切页回调；存在时禁止压入重复书源管理路由。
    final ValueChanged<String>? openEmbedded =
        widget.onOpenBookSourceManagement;
    if (openEmbedded != null) {
      openEmbedded(message);
      return;
    }
    await Navigator.of(context).pushNamed<void>(
      AppRoute.bookSourceManagement,
      arguments: BookSourceManagementRouteArguments(
        initialMessage: message,
      ),
    );
  }

  /// 根据 UiState 串行展示“全部开启搜索书源”确认框。
  void _syncEnableAllSearchSourcesDialog(String? pendingKeyword) {
    if (pendingKeyword == null || _enableAllSearchSourcesDialogVisible) {
      return;
    }
    _enableAllSearchSourcesDialogVisible = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _viewModel.state.pendingEnableAllSearchKeyword == null) {
        _enableAllSearchSourcesDialogVisible = false;
        return;
      }
      unawaited(_showEnableAllSearchSourcesDialog());
    });
  }

  /// 询问是否清除搜索页局部限制并立即继续原提交关键字。
  Future<void> _showEnableAllSearchSourcesDialog() async {
    /// 用户是否明确选择恢复全部搜索书源。
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('提示'),
          content: const Text('当前没有开启搜索书源，是否全部开启'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('全部开启'),
            ),
          ],
        );
      },
    );
    _enableAllSearchSourcesDialogVisible = false;
    if (!mounted) {
      return;
    }
    _viewModel.onIntent(
      confirmed == true
          ? const ConfirmEnableAllSearchSourcesIntent()
          : const DismissEnableAllSearchSourcesIntent(),
    );
  }

  /// 打开详情并兼容详情换源使用路由替换的场景。
  Future<void> _openBookInfo(BookInfoRouteArguments arguments) async {
    try {
      await Navigator.of(context).pushNamed(
        AppRoute.bookInfo,
        arguments: arguments,
      );
      if (!mounted) {
        return;
      }
      /// 导航 Future 完成时搜索宿主路由是否真的已经重新可见。
      final ModalRoute<dynamic>? route = ModalRoute.of(context);
      if (route?.isCurrent ?? false) {
        _resumeSearchAfterBookInfo();
      }
    } catch (_) {
      if (!mounted) {
        return;
      }
      _resumeSearchAfterBookInfo();
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('打开书籍详情失败')));
    } finally {
      _openingBookInfo = false;
    }
  }

  /// 清除等待标记并通知 ViewModel 从保留进度继续搜索。
  void _resumeSearchAfterBookInfo() {
    if (!_waitingForBookInfoReturn) {
      return;
    }
    _waitingForBookInfoReturn = false;
    _viewModel.onIntent(const ResumeSearchAfterBookInfoIntent());
  }

  /// 释放订阅和 ViewModel。
  @override
  void dispose() {
    widget.navigationObserver.unsubscribe(this);
    _subscribedRoute = null;
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
        _syncEnableAllSearchSourcesDialog(
          state.pendingEnableAllSearchKeyword,
        );
        return SearchScreen(
          state: state,
          onIntent: _viewModel.onIntent,
          showBackButton: !widget.embedded,
        );
      },
    );
  }
}
