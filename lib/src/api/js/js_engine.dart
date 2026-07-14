import 'dart:typed_data';

/// JavaScript 执行失败分类，避免业务层依赖具体引擎异常。
enum JsFailureKind {
  cancelled,
  timeout,
  memoryLimit,
  stackOverflow,
  syntax,
  runtime,
  bridge,
  unsupportedApi,
  closed,
  unknown,
}

/// JavaScript 执行异常；脚本正文和敏感绑定不会进入日志消息。
final class JsEngineException implements Exception {
  /// 创建安全的 JavaScript 异常。
  const JsEngineException({
    required this.kind,
    required this.message,
    this.scriptName,
    this.line,
    this.column,
    this.stack,
  });

  /// 失败分类。
  final JsFailureKind kind;

  /// 不包含 Cookie、Authorization 或正文的说明。
  final String message;

  /// 可选脚本逻辑名称。
  final String? scriptName;

  /// 可选错误行号。
  final int? line;

  /// 可选错误列号。
  final int? column;

  /// 经裁剪的 JavaScript 错误栈。
  final String? stack;

  @override
  String toString() => 'JsEngineException($kind, $message)';
}

/// JavaScript `undefined` 的 Dart 明确表示，不能与 `null` 合并。
final class JsUndefinedValue {
  /// 创建唯一的 undefined 值。
  const JsUndefinedValue._();

  /// 全局唯一实例。
  static const JsUndefinedValue instance = JsUndefinedValue._();
}

/// JavaScript 数组空洞的 Dart 明确表示。
final class JsArrayHoleValue {
  /// 创建唯一的数组空洞值。
  const JsArrayHoleValue._();

  /// 全局唯一实例。
  static const JsArrayHoleValue instance = JsArrayHoleValue._();
}

/// JavaScript 可接受或返回的跨引擎值。
///
/// 允许值包括 `null`、[JsUndefinedValue]、[JsArrayHoleValue]、`bool`、`num`、`String`、
/// `BigInt`、`DateTime`、[Uint8List]、列表和字符串键 Map；其他对象必须先转换 DTO。
typedef JsBridgeValue = Object?;

/// 可附加到执行请求的宿主桥上下文标记。
abstract interface class JsHostBridgeContext {}

/// JavaScript 取消令牌。
abstract interface class JsCancellationToken {
  /// 是否已经取消。
  bool get isCancelled;

  /// 注册取消监听；返回用于移除监听的回调。
  void Function() addCancellationListener(void Function() listener);
}

/// 可主动取消 JavaScript 的控制器。
final class JsCancellationController implements JsCancellationToken {
  /// 已注册取消监听。
  final Set<void Function()> _listeners = <void Function()>{};

  /// 当前取消状态。
  bool _cancelled = false;

  @override
  bool get isCancelled => _cancelled;

  /// 取消脚本并通知当前监听。
  void cancel() {
    if (_cancelled) {
      return;
    }
    _cancelled = true;
    /// 防止监听在通知期间修改集合。
    final List<void Function()> listeners = _listeners.toList(growable: false);
    for (final void Function() listener in listeners) {
      listener();
    }
    _listeners.clear();
  }

  @override
  void Function() addCancellationListener(void Function() listener) {
    if (_cancelled) {
      listener();
      return () {};
    }
    _listeners.add(listener);
    return () {
      _listeners.remove(listener);
    };
  }
}

/// 已编译脚本的引擎无关描述。
abstract interface class JsCompiledScript {
  /// 脚本逻辑名称。
  String get name;

  /// 释放编译产物。
  Future<void> close();
}

/// 单次脚本执行请求。
final class JsEvaluationRequest {
  /// 创建不可变执行请求。
  JsEvaluationRequest({
    required this.scriptName,
    required this.source,
    Map<String, JsBridgeValue> bindings = const <String, JsBridgeValue>{},
    this.timeout = const Duration(seconds: 5),
    this.cancellationToken,
    this.hostContext,
  }) : bindings = Map<String, JsBridgeValue>.unmodifiable(bindings);

  /// 不含敏感信息的脚本逻辑名称。
  final String scriptName;

  /// JavaScript 源码；不得写入常规日志。
  final String source;

  /// 注入脚本的 DTO 值。
  final Map<String, JsBridgeValue> bindings;

  /// 本次执行超时。
  final Duration timeout;

  /// 可选取消令牌。
  final JsCancellationToken? cancellationToken;

  /// 可选宿主 API 上下文；引擎只能识别其声明支持的具体实现。
  final JsHostBridgeContext? hostContext;
}

/// 与具体 QuickJS/JavaScriptCore 类型隔离的 JavaScript 引擎。
abstract interface class JsEngine {
  /// 引擎是否已经关闭。
  bool get isClosed;

  /// 编译脚本；不支持独立字节码的引擎可以返回安全源码句柄。
  Future<JsCompiledScript> compile({required String name, required String source});

  /// 执行脚本并返回结构化 Dart 值。
  Future<JsBridgeValue> evaluate(JsEvaluationRequest request);

  /// 执行已经编译的脚本。
  Future<JsBridgeValue> evaluateCompiled(
    JsCompiledScript script, {
    Map<String, JsBridgeValue> bindings = const <String, JsBridgeValue>{},
    Duration timeout = const Duration(seconds: 5),
    JsCancellationToken? cancellationToken,
    JsHostBridgeContext? hostContext,
  });

  /// 释放运行时、上下文、回调和脚本句柄。
  Future<void> close();
}

/// 创建彼此隔离的 JavaScript 引擎实例。
abstract interface class JsEngineFactory {
  /// 为指定书源创建独占引擎；不同书源不得共享可变 Scope。
  Future<JsEngine> create({required String sourceId});
}
