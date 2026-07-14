import 'dart:convert';
import 'dart:typed_data';

import 'package:jsf/jsf.dart';

import 'js_engine.dart';
import 'legado_script_bridge.dart';
import 'script_context.dart';

/// 基于 JSF/QuickJS 的跨平台引擎工厂。
final class JsfJsEngineFactory implements JsEngineFactory {
  /// 创建引擎工厂。
  const JsfJsEngineFactory(this._bridge);

  /// Legado 宿主 API 桥。
  final LegadoScriptBridge _bridge;

  @override
  Future<JsEngine> create({required String sourceId}) async {
    return JsfJsEngine(sourceId: sourceId, bridge: _bridge);
  }
}

/// JSF/QuickJS 引擎适配器。
///
/// 每个实例只服务一个书源 Scope；64 MiB 内存、1 MiB 栈和原生中断超时是原型默认值。
final class JsfJsEngine implements JsEngine {
  /// 创建隔离的 JSF 运行时并注册唯一宿主桥函数。
  JsfJsEngine({required this.sourceId, required LegadoScriptBridge bridge})
    : _bridge = bridge,
      _runtime = JsRuntime(
        options: const JsRuntimeOptions(
          memoryLimitBytes: 64 * 1024 * 1024,
          maxStackSizeBytes: 1024 * 1024,
          timeout: Duration(seconds: 5),
        ),
      ) {
    _runtime.registerFunction('__legadoBridge', _handleBridgeCall);
  }

  /// 当前引擎绑定的书源标识。
  final String sourceId;

  /// Legado 宿主 API 桥。
  final LegadoScriptBridge _bridge;

  /// JSF QuickJS 运行时。
  final JsRuntime _runtime;

  /// 当前执行使用的 Legado 上下文。
  LegadoScriptContext? _activeContext;

  /// 当前执行的 JavaScript 取消令牌。
  JsCancellationToken? _activeCancellationToken;

  /// 是否正在执行脚本；单运行时禁止并发进入。
  bool _running = false;

  /// 是否已经关闭。
  bool _closed = false;

  @override
  bool get isClosed => _closed;

  @override
  Future<JsCompiledScript> compile({required String name, required String source}) async {
    _ensureOpen(name);
    return _JsfCompiledScript(name: name, source: source);
  }

  @override
  Future<JsBridgeValue> evaluate(JsEvaluationRequest request) async {
    _ensureOpen(request.scriptName);
    if (_running) {
      throw JsEngineException(
        kind: JsFailureKind.runtime,
        message: '同一书源 JavaScript 运行时不允许并发执行',
        scriptName: request.scriptName,
      );
    }
    if (request.cancellationToken?.isCancelled ?? false) {
      throw JsEngineException(
        kind: JsFailureKind.cancelled,
        message: '脚本执行已取消',
        scriptName: request.scriptName,
      );
    }
    /// Legado 宿主上下文。
    final JsHostBridgeContext? hostContext = request.hostContext;
    if (hostContext != null && hostContext is! LegadoScriptContext) {
      throw JsEngineException(
        kind: JsFailureKind.bridge,
        message: 'JSF 适配器收到不支持的宿主上下文',
        scriptName: request.scriptName,
      );
    }
    _running = true;
    _activeContext = hostContext is LegadoScriptContext ? hostContext : null;
    _activeCancellationToken = request.cancellationToken;
    _runtime.setTimeout(request.timeout);
    /// 移除取消监听的回调。
    final void Function()? removeCancellation = request.cancellationToken
        ?.addCancellationListener(() {
          if (!_closed) {
            _runtime.setTimeout(const Duration(milliseconds: 1));
          }
        });
    try {
      /// 注入值与脚本包装后的源码。
      final String wrapped = _wrapScript(request.source, request.bindings, _activeContext);
      /// JSF 结构化结果。
      final Object? value = await _runtime.evalAsync(
        wrapped,
        filename: request.scriptName,
      );
      if (request.cancellationToken?.isCancelled ?? false) {
        throw JsEngineException(
          kind: JsFailureKind.cancelled,
          message: '脚本执行已取消',
          scriptName: request.scriptName,
        );
      }
      return _convertResult(value);
    } on JsEngineException {
      rethrow;
    } on JsException catch (error) {
      throw _mapJsException(error, request.scriptName, request.cancellationToken);
    } catch (error) {
      throw JsEngineException(
        kind: JsFailureKind.unknown,
        message: 'JavaScript 引擎发生未知错误',
        scriptName: request.scriptName,
        stack: _safeErrorText(error),
      );
    } finally {
      removeCancellation?.call();
      _activeContext = null;
      _activeCancellationToken = null;
      _running = false;
    }
  }

  @override
  Future<JsBridgeValue> evaluateCompiled(
    JsCompiledScript script, {
    Map<String, JsBridgeValue> bindings = const <String, JsBridgeValue>{},
    Duration timeout = const Duration(seconds: 5),
    JsCancellationToken? cancellationToken,
    JsHostBridgeContext? hostContext,
  }) {
    if (script is! _JsfCompiledScript || script.isClosed) {
      throw const JsEngineException(
        kind: JsFailureKind.closed,
        message: '编译脚本已关闭或不属于 JSF 引擎',
      );
    }
    return evaluate(
      JsEvaluationRequest(
        scriptName: script.name,
        source: script.source,
        bindings: bindings,
        timeout: timeout,
        cancellationToken: cancellationToken,
        hostContext: hostContext,
      ),
    );
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    _activeContext = null;
    _activeCancellationToken = null;
    _runtime.dispose();
  }

  /// 接收 JavaScript 代理发起的宿主 API 调用。
  Object? _handleBridgeCall(List<Object?> arguments) {
    /// 当前 Legado 上下文。
    final LegadoScriptContext? context = _activeContext;
    if (context == null) {
      throw const JsEngineException(
        kind: JsFailureKind.bridge,
        message: '脚本未提供 Legado 宿主上下文',
      );
    }
    if (arguments.length < 3) {
      throw const JsEngineException(
        kind: JsFailureKind.bridge,
        message: '宿主桥调用参数不足',
      );
    }
    /// API 表面名称。
    final String surface = arguments[0]?.toString() ?? '';
    /// 方法名称。
    final String method = arguments[1]?.toString() ?? '';
    /// 方法参数。
    final List<Object?> methodArguments = arguments[2] is List
        ? List<Object?>.from(arguments[2] as List)
        : <Object?>[];
    return _bridge.invoke(
      context,
      surface,
      method,
      methodArguments,
      cancellationToken: _activeCancellationToken,
    );
  }

  /// 包装脚本并安装 Legado 代理对象。
  String _wrapScript(
    String source,
    Map<String, JsBridgeValue> bindings,
    LegadoScriptContext? context,
  ) {
    /// 合并标准绑定和 Legado DTO。
    final Map<String, Object?> values = <String, Object?>{
      if (context != null) ...context.toBindings(),
      ...bindings,
    };
    /// 可安全嵌入 JavaScript 的 JSON。
    final String encodedBindings = jsonEncode(values, toEncodable: _jsonEncodable);
    /// 可安全嵌入 eval 的脚本文本。
    final String encodedSource = jsonEncode(source);
    return '''
(async function () {
  const __bindings = $encodedBindings;
  Object.assign(globalThis, __bindings);
  const __response = (value) => {
    if (!value || typeof value !== 'object' || !('body' in value)) return value;
    return new Proxy(value, {
      get: (target, property) => {
        if (property === 'body') return () => target.body;
        if (property === 'url') return () => target.url;
        if (property === 'statusCode') return () => target.statusCode;
        if (property === 'headers') return () => target.headers;
        if (property === 'header') return (name) => {
          const values = target.headers && target.headers[String(name).toLowerCase()];
          return Array.isArray(values) && values.length > 0 ? values[0] : null;
        };
        return target[property];
      }
    });
  };
  const __proxy = (surface) => new Proxy({}, {
    get: (_, method) => (...args) => {
      const value = __legadoBridge(surface, String(method), args);
      if (surface === 'java' && ['connect', 'get', 'head', 'post'].includes(String(method))) {
        return Promise.resolve(value).then(__response);
      }
      return value;
    }
  });
  globalThis.java = __proxy('java');
  globalThis.cookie = __proxy('cookie');
  globalThis.cache = __proxy('cache');
  globalThis.source = new Proxy(__bindings.source || {}, {
    get: (target, property) => {
      if (['getVariable', 'setVariable', 'putVariable', 'getLoginHeader', 'putLoginHeader',
           'getLoginInfo', 'putLoginInfo', 'getKey', 'getTag'].includes(String(property))) {
        return (...args) => __legadoBridge('source', String(property), args);
      }
      const name = String(property);
      if (name.startsWith('get') && name.length > 3) {
        const field = name.charAt(3).toLowerCase() + name.slice(4);
        return () => target[field];
      }
      return target[property];
    },
    set: (target, property, value) => {
      if (property !== 'variable') {
        throw new Error('source 只允许修改 variable');
      }
      target[property] = value;
      __legadoBridge('source', 'setVariable', ['variable', String(value)]);
      return true;
    }
  });
  const __model = (value) => value == null ? null : new Proxy(value, {
    get: (target, property) => {
      const name = String(property);
      if (name === 'getVariableMap') {
        return () => {
          try { return new Map(Object.entries(JSON.parse(target.variable || '{}'))); }
          catch (_) { return new Map(); }
        };
      }
      if (name.startsWith('get') && name.length > 3) {
        const field = name.charAt(3).toLowerCase() + name.slice(4);
        return () => target[field];
      }
      return target[property];
    }
  });
  globalThis.book = __model(__bindings.book);
  globalThis.chapter = __model(__bindings.chapter);
  globalThis.result = __response(__bindings.result);
  globalThis.Java = Object.freeze({
    type: (className) => __proxy('class:' + String(className))
  });
  const __value = (0, eval)($encodedSource);
  return await __value;
})()
''';
  }

  /// 将非 JSON 基础值转换为安全绑定。
  Object? _jsonEncodable(Object? value) {
    if (value is DateTime) {
      return value.toIso8601String();
    }
    if (value is BigInt) {
      return value.toString();
    }
    if (value is Uint8List) {
      return value.toList(growable: false);
    }
    throw JsEngineException(
      kind: JsFailureKind.bridge,
      message: '绑定包含未转换的 ${value.runtimeType} 对象',
    );
  }

  /// 将 JSF 特殊值转换为稳定契约值。
  Object? _convertResult(Object? value) {
    if (identical(value, jsUndefined)) {
      return JsUndefinedValue.instance;
    }
    if (identical(value, jsArrayHole)) {
      return JsArrayHoleValue.instance;
    }
    return value;
  }

  /// 映射 JSF 异常分类。
  JsEngineException _mapJsException(
    JsException error,
    String scriptName,
    JsCancellationToken? cancellationToken,
  ) {
    /// 经裁剪的小写错误文本。
    final String text = _safeErrorText(error);
    /// 错误分类文本。
    final String lower = text.toLowerCase();
    /// 错误分类。
    final JsFailureKind kind = cancellationToken?.isCancelled == true
        ? JsFailureKind.cancelled
        : lower.contains('timeout') || lower.contains('interrupt')
        ? JsFailureKind.timeout
        : lower.contains('memory')
        ? JsFailureKind.memoryLimit
        : lower.contains('stack')
        ? JsFailureKind.stackOverflow
        : lower.contains('syntax')
        ? JsFailureKind.syntax
        : JsFailureKind.runtime;
    return JsEngineException(
      kind: kind,
      message: kind == JsFailureKind.cancelled ? '脚本执行已取消' : 'JavaScript 执行失败',
      scriptName: scriptName,
      stack: text,
    );
  }

  /// 裁剪错误文本并移除长字符串，降低正文或令牌进入报告的风险。
  String _safeErrorText(Object error) {
    /// 原始错误文本。
    final String raw = error.toString().replaceAll(
      RegExp(r'''(["']).{120,}?\1''', dotAll: true),
      '<已隐藏长字符串>',
    );
    return raw.length <= 1200 ? raw : raw.substring(0, 1200);
  }

  /// 确认运行时仍可使用。
  void _ensureOpen(String scriptName) {
    if (_closed) {
      throw JsEngineException(
        kind: JsFailureKind.closed,
        message: 'JavaScript 引擎已关闭',
        scriptName: scriptName,
      );
    }
  }
}

/// JSF 原型编译句柄；当前保存源码，后续可替换为引擎字节码而不改变业务接口。
final class _JsfCompiledScript implements JsCompiledScript {
  /// 创建编译脚本句柄。
  _JsfCompiledScript({required this.name, required this.source});

  @override
  final String name;

  /// 不记录日志的脚本源码。
  final String source;

  /// 是否已经关闭。
  bool isClosed = false;

  @override
  Future<void> close() async {
    isClosed = true;
  }
}
