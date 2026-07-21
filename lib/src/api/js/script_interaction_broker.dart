import 'dart:async';
import 'dart:collection';

import 'js_engine.dart';

/// 书源脚本允许申请的可见用户交互类型。
enum LegadoScriptInteractionKind {
  /// 内置浏览器登录、滑块或页面验证。
  browser,

  /// 图片验证码输入。
  verificationCode,
}

/// 页面完成脚本交互后返回给宿主桥的稳定结果。
final class LegadoScriptInteractionResult {
  /// 创建不可变交互结果。
  const LegadoScriptInteractionResult({required this.finalUri, required this.value});

  /// 用户完成交互时页面所在的最终地址。
  final Uri finalUri;

  /// 浏览器页面 HTML 或用户输入的验证码。
  final String value;
}

/// 一条等待唯一 UI 消费者处理的书源脚本交互请求。
final class LegadoScriptInteractionRequest {
  /// 创建交互请求；只允许 broker 创建并管理完成生命周期。
  LegadoScriptInteractionRequest._({
    required this.kind,
    required this.sourceUrl,
    required this.sourceName,
    required this.targetUri,
    required this.title,
    required this.html,
    required this.requiresPageResult,
  });

  /// 浏览器或图片验证码交互类型。
  final LegadoScriptInteractionKind kind;

  /// 发起请求的书源稳定 URL，仅用于关联来源，不展示完整地址。
  final String sourceUrl;

  /// 可向用户展示的书源名称。
  final String sourceName;

  /// 登录页面或验证码图片地址。
  final Uri targetUri;

  /// 书源脚本提供的页面标题；空值由 UI 使用默认标题。
  final String title;

  /// `startBrowser` 可选的初始 HTML。
  final String? html;

  /// 页面关闭时是否必须回传最终 HTML；普通 `startBrowser` 为假。
  final bool requiresPageResult;

  /// 当前请求的单次完成信号。
  final Completer<LegadoScriptInteractionResult> _completion =
      Completer<LegadoScriptInteractionResult>();

  /// 当前请求是否已经成功、失败或取消。
  bool get isCompleted => _completion.isCompleted;

  /// 宿主桥等待的交互结果 Future。
  Future<LegadoScriptInteractionResult> get result => _completion.future;

  /// UI 成功完成登录、验证或验证码输入。
  void complete(LegadoScriptInteractionResult result) {
    if (!_completion.isCompleted) {
      _completion.complete(result);
    }
  }

  /// UI 或生命周期以受控异常结束当前请求。
  void fail(Object error, [StackTrace? stackTrace]) {
    if (!_completion.isCompleted) {
      _completion.completeError(error, stackTrace ?? StackTrace.current);
    }
  }

  /// 用户取消当前提示，只结束发起请求的书源，不影响其他并发搜索任务。
  void cancelByUser() {
    fail(
      const JsEngineException(
        kind: JsFailureKind.interactionRequired,
        message: '用户取消了书源登录或验证',
      ),
    );
  }
}

/// 搜索路由处理可见交互的函数类型；业务层只保存回调，不依赖 `BuildContext`。
typedef LegadoScriptInteractionHandler =
    Future<void> Function(LegadoScriptInteractionRequest request);

/// 应用级书源脚本交互队列，同一时间最多向唯一 UI 消费者派发一个请求。
final class LegadoScriptInteractionBroker {
  /// 等待当前请求结束后再派发的先进先出队列。
  final ListQueue<LegadoScriptInteractionRequest> _pending =
      ListQueue<LegadoScriptInteractionRequest>();

  /// 当前正在由 UI 展示的唯一请求。
  LegadoScriptInteractionRequest? _active;

  /// 当前 UI 处理器是否已经真正退出；请求先被取消时仍等待页面关闭再放行队列。
  bool _activeHandlerFinished = true;

  /// 已挂载搜索路由的顺序栈；最上层可见路由是唯一活动消费者。
  final List<LegadoScriptInteractionHandler> _handlers =
      <LegadoScriptInteractionHandler>[];

  /// 领取当前活动请求的处理器，用于路由退出时只终止它承载的提示。
  LegadoScriptInteractionHandler? _activeHandler;

  /// broker 是否已经永久关闭。
  bool _closed = false;

  /// 挂载搜索页处理器；存在嵌套搜索路由时仅栈顶页面消费新请求。
  void attachHandler(LegadoScriptInteractionHandler handler) {
    if (_closed) {
      throw const JsEngineException(
        kind: JsFailureKind.closed,
        message: '书源交互队列已经关闭',
      );
    }
    _handlers.removeWhere(
      (LegadoScriptInteractionHandler existing) => identical(existing, handler),
    );
    _handlers.add(handler);
    _dispatchNext();
  }

  /// 解除指定搜索页；活动页面退出时终止它的提示并恢复下层消费者。
  void detachHandler(LegadoScriptInteractionHandler handler) {
    /// 移除前处理器数量，用于按实例身份判断指定路由是否曾挂载。
    final int handlerCountBeforeRemoval = _handlers.length;
    _handlers.removeWhere(
      (LegadoScriptInteractionHandler existing) => identical(existing, handler),
    );
    /// 是否真正移除了已挂载的指定路由处理器。
    final bool removed = _handlers.length != handlerCountBeforeRemoval;
    if (!removed) {
      return;
    }
    if (identical(_activeHandler, handler)) {
      /// 页面已经退出，旧提示随路由销毁，可立即释放槽位给恢复后的搜索页。
      final LegadoScriptInteractionRequest? active = _active;
      _active = null;
      _activeHandler = null;
      _activeHandlerFinished = true;
      active?.fail(
        const JsEngineException(
          kind: JsFailureKind.interactionRequired,
          message: '搜索页面已关闭，无法继续书源登录或验证',
        ),
      );
    }
    if (_handlers.isNotEmpty) {
      _dispatchNext();
      return;
    }
    _failAll(
      const JsEngineException(
        kind: JsFailureKind.interactionRequired,
        message: '搜索页面已关闭，无法继续书源登录或验证',
      ),
    );
  }

  /// 把交互请求加入串行队列；没有 UI 消费者时立即失败，禁止后台任务悬挂。
  Future<LegadoScriptInteractionResult> request({
    required LegadoScriptInteractionKind kind,
    required String sourceUrl,
    required String sourceName,
    required Uri targetUri,
    required String title,
    required bool requiresPageResult,
    String? html,
    JsCancellationToken? cancellationToken,
  }) {
    if (_closed) {
      return Future<LegadoScriptInteractionResult>.error(
        const JsEngineException(
          kind: JsFailureKind.closed,
          message: '书源交互队列已经关闭',
        ),
      );
    }
    if (_handlers.isEmpty) {
      return Future<LegadoScriptInteractionResult>.error(
        const JsEngineException(
          kind: JsFailureKind.interactionRequired,
          message: '当前没有可展示书源登录或验证的搜索页面',
        ),
      );
    }
    if (cancellationToken?.isCancelled ?? false) {
      return Future<LegadoScriptInteractionResult>.error(
        const JsEngineException(
          kind: JsFailureKind.cancelled,
          message: '书源登录或验证请求已取消',
        ),
      );
    }
    /// 新建且尚未交给 UI 的请求。
    final LegadoScriptInteractionRequest interactionRequest =
        LegadoScriptInteractionRequest._(
          kind: kind,
          sourceUrl: sourceUrl,
          sourceName: sourceName,
          targetUri: targetUri,
          title: title,
          html: html,
          requiresPageResult: requiresPageResult,
        );
    /// 从脚本取消令牌解除监听的回调。
    final void Function()? removeCancellationListener =
        cancellationToken?.addCancellationListener(() {
          interactionRequest.fail(
            const JsEngineException(
              kind: JsFailureKind.cancelled,
              message: '书源登录或验证请求已取消',
            ),
          );
        });
    _pending.addLast(interactionRequest);
    unawaited(
      interactionRequest.result.then<void>(
        (LegadoScriptInteractionResult _) {
          removeCancellationListener?.call();
          _finish(interactionRequest);
        },
        onError: (Object _, StackTrace __) {
          removeCancellationListener?.call();
          _finish(interactionRequest);
        },
      ),
    );
    _dispatchNext();
    return interactionRequest.result;
  }

  /// 当前请求完成后解除占用并派发队首请求。
  void _finish(LegadoScriptInteractionRequest request) {
    if (identical(_active, request)) {
      if (!_activeHandlerFinished) {
        return;
      }
      _active = null;
    } else {
      _pending.remove(request);
    }
    _dispatchNext();
  }

  /// 仅在没有活动请求时向当前唯一处理器派发一个队首请求。
  void _dispatchNext() {
    if (_closed || _active != null || _pending.isEmpty) {
      return;
    }
    /// 当前唯一 UI 处理器。
    final LegadoScriptInteractionHandler handler = _handlers.last;
    /// 本轮从队首领取的唯一请求。
    final LegadoScriptInteractionRequest request = _pending.removeFirst();
    _active = request;
    _activeHandler = handler;
    _activeHandlerFinished = false;
    unawaited(
      handler(request).then<void>(
        (_) {
          _handleHandlerFinished(request);
        },
        onError: (Object error, StackTrace stackTrace) {
          request.fail(error, stackTrace);
          _handleHandlerFinished(request);
        },
      ),
    );
  }

  /// UI 提示真正关闭后释放活动槽位；处理器漏回结果时用受控错误结束请求。
  void _handleHandlerFinished(LegadoScriptInteractionRequest request) {
    if (!identical(_active, request)) {
      return;
    }
    _activeHandlerFinished = true;
    _activeHandler = null;
    if (!request.isCompleted) {
      request.fail(
        const JsEngineException(
          kind: JsFailureKind.bridge,
          message: '书源登录或验证页面未返回结果',
        ),
      );
    }
    _finish(request);
  }

  /// 使用同一受控错误结束活动和排队请求。
  void _failAll(JsEngineException error) {
    /// 当前活动请求快照。
    final LegadoScriptInteractionRequest? active = _active;
    _active = null;
    _activeHandler = null;
    _activeHandlerFinished = true;
    active?.fail(error);
    /// 等待队列快照，避免完成回调修改正在遍历的集合。
    final List<LegadoScriptInteractionRequest> pending = _pending.toList(growable: false);
    _pending.clear();
    for (final LegadoScriptInteractionRequest request in pending) {
      request.fail(error);
    }
  }

  /// 永久关闭队列并结束所有等待请求。
  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    _handlers.clear();
    _failAll(
      const JsEngineException(
        kind: JsFailureKind.closed,
        message: '书源交互队列已经关闭',
      ),
    );
  }
}
