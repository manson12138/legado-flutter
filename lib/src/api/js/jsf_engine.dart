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
  /// 单段规则允许的宿主调用重放上限，防止异常脚本通过不断生成新调用占用无限内存。
  static const int _maximumReplayableBridgeCalls = 256;

  /// 通知当前 QuickJS 尝试暂停的内部标记；不包含 URL、Header、Cookie 或参数值。
  static const String _synchronousBridgePendingMarker =
      '__LEGADO_SYNCHRONOUS_BRIDGE_PENDING__';

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

  /// 当前规则的同步宿主调用重放状态；只在一次 [evaluate] 生命周期内存在。
  _SynchronousBridgeReplay? _activeBridgeReplay;

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
    if (hostContext is LegadoScriptContext) {
      try {
        await _bridge.prepareContext(hostContext);
      } catch (_) {
        throw JsEngineException(
          kind: JsFailureKind.bridge,
          message: '读取书源脚本运行变量失败',
          scriptName: request.scriptName,
          bridgeCalls: List<String>.unmodifiable(hostContext.bridgeCalls),
        );
      }
    }
    _running = true;
    _activeContext = hostContext is LegadoScriptContext ? hostContext : null;
    _activeCancellationToken = request.cancellationToken;
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
      /// Android Rhino 宿主方法同步返回，而 JSF 只能把 Dart Future 转成 Promise；重放器通过
      /// “发现异步调用 → 等待 Dart → 从头重放且复用已完成宿主结果”恢复旧书源观察到的同步值。
      final _SynchronousBridgeReplay replay = _SynchronousBridgeReplay(
        maximumEntries: _maximumReplayableBridgeCalls,
      );
      _activeBridgeReplay = replay;
      while (true) {
        if (request.cancellationToken?.isCancelled ?? false) {
          throw JsEngineException(
            kind: JsFailureKind.cancelled,
            message: '脚本执行已取消',
            scriptName: request.scriptName,
          );
        }
        // 网络等待不计入 QuickJS 的纯 CPU 执行时间；每次恢复前重新建立本次尝试的中断期限。
        _runtime.setTimeout(request.timeout);
        replay.beginAttempt();
        try {
          /// 当前重放尝试的 JSF 结构化结果。
          final Object? value = await _runtime.evalAsync(
            wrapped,
            filename: request.scriptName,
          );
          if (await _completePendingBridgeCall(replay)) {
            continue;
          }
          if (request.cancellationToken?.isCancelled ?? false) {
            throw JsEngineException(
              kind: JsFailureKind.cancelled,
              message: '脚本执行已取消',
              scriptName: request.scriptName,
            );
          }
          return _convertResult(value);
        } on JsException catch (error) {
          // 同步桥暂停通过内部异常立即退出当前 QuickJS 栈；宿主结果完成后重新执行同一规则。
          if (await _completePendingBridgeCall(replay)) {
            continue;
          }
          throw _mapJsException(error, request.scriptName, request.cancellationToken);
        }
      }
    } on JsEngineException catch (error) {
      /// 【FLUTTER_JS_COMPAT_LOG】宿主桥执行期间累计的方法名和参数类型轨迹。
      final List<String>? activeBridgeCalls = _activeContext?.bridgeCalls;
      if (error.bridgeCalls.isNotEmpty ||
          activeBridgeCalls == null ||
          activeBridgeCalls.isEmpty) {
        rethrow;
      }
      throw JsEngineException(
        kind: error.kind,
        message: error.message,
        scriptName: error.scriptName,
        line: error.line,
        column: error.column,
        stack: error.stack,
        bridgeCalls: List<String>.unmodifiable(activeBridgeCalls),
      );
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
      _activeBridgeReplay = null;
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
    /// 当前规则同步桥调用的稳定签名；按调用位置、表面和方法匹配，不保存敏感参数值。
    final _SynchronousBridgeCallSignature signature = _SynchronousBridgeCallSignature(
      surface: surface,
      method: method,
    );
    /// 当前规则重放状态。
    final _SynchronousBridgeReplay? replay = _activeBridgeReplay;
    if (replay != null) {
      /// 已完成调用在后续尝试中直接同步返回，禁止重复网络请求、Cookie 写入或缓存副作用。
      final Map<String, Object?>? replayed = replay.replay(signature);
      if (replayed != null) {
        return replayed;
      }
      /// 当前尝试已经发现一个待完成调用；后续宿主调用只继续触发暂停，不执行第二次副作用。
      if (replay.hasPendingCall) {
        return _synchronousBridgePendingEnvelope();
      }
    }
    try {
      /// 宿主桥原始返回值；同步 Helper 立即记录，Future 则由重放器等待后同步注入。
      final Object? value = _bridge.invoke(
        context,
        surface,
        method,
        methodArguments,
        cancellationToken: _activeCancellationToken,
      );
      if (value is Future<dynamic>) {
        if (replay == null) {
          return value.then<Map<String, Object?>>(
            _bridgeSuccessEnvelope,
            onError: (Object error, StackTrace _) => _bridgeFailureEnvelope(error),
          );
        }
        replay.setPendingCall(
          signature,
          value.then<Map<String, Object?>>(
            _bridgeSuccessEnvelope,
            onError: (Object error, StackTrace _) => _bridgeFailureEnvelope(error),
          ),
        );
        return _synchronousBridgePendingEnvelope();
      }
      /// 当前同步调用结果也加入重放记录，避免异步调用导致整段规则重跑时重复写缓存或变量。
      final Map<String, Object?> envelope = _bridgeSuccessEnvelope(value);
      replay?.recordImmediate(signature, envelope);
      return envelope;
    } catch (error) {
      /// 同步失败同样记录；脚本捕获异常后，后续重放必须观察到完全相同的失败。
      final Map<String, Object?> envelope = _bridgeFailureEnvelope(error);
      replay?.recordImmediate(signature, envelope);
      return envelope;
    }
  }

  /// 等待当前尝试发现的异步宿主调用并把结果加入同步重放记录。
  Future<bool> _completePendingBridgeCall(_SynchronousBridgeReplay replay) async {
    if (!replay.hasPendingCall) {
      return false;
    }
    await replay.completePendingCall();
    return true;
  }

  /// 创建只用于中断当前 QuickJS 尝试的安全失败信封。
  Map<String, Object?> _synchronousBridgePendingEnvelope() {
    return <String, Object?>{
      '_legadoBridgeEnvelope': true,
      'ok': false,
      'kind': JsFailureKind.bridge.name,
      'message': _synchronousBridgePendingMarker,
    };
  }

  /// 把同步或异步宿主桥成功值包装为不会与普通业务 Map 混淆的结构化结果。
  Map<String, Object?> _bridgeSuccessEnvelope(Object? value) {
    return <String, Object?>{
      '_legadoBridgeEnvelope': true,
      'ok': true,
      'value': value,
    };
  }

  /// 把宿主桥异常收敛为安全错误分类，禁止 JSF 将 DartError 对象继续当业务值使用。
  Map<String, Object?> _bridgeFailureEnvelope(Object error) {
    if (error is JsEngineException) {
      return <String, Object?>{
        '_legadoBridgeEnvelope': true,
        'ok': false,
        'kind': error.kind.name,
        'message': error.message,
      };
    }
    return <String, Object?>{
      '_legadoBridgeEnvelope': true,
      'ok': false,
      'kind': JsFailureKind.bridge.name,
      'message': '宿主桥执行失败',
    };
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
  const __hostValue = (value) => {
    if (Array.isArray(value)) return value.map(__hostValue);
    if (!value || typeof value !== 'object' || !value._legadoHostType) return value;
    return new Proxy(value, {
      get: (target, property) => {
        if (property === 'then') return undefined;
        if (property in target) return target[property];
        return (...args) => __callBridge(
          'host:' + String(target._legadoHostType),
          String(property),
          [target, ...args],
        );
      }
    });
  };
  const __unwrapBridge = (envelope) => {
    if (!envelope || envelope._legadoBridgeEnvelope !== true) {
      throw new Error('__LEGADO_BRIDGE_ERROR__bridge:宿主桥返回结构无效');
    }
    if (envelope.ok !== true) {
      const kind = String(envelope.kind || 'bridge');
      const message = String(envelope.message || '宿主桥执行失败');
      throw new Error('__LEGADO_BRIDGE_ERROR__' + kind + ':' + message);
    }
    return __hostValue(envelope.value);
  };
  const __callBridge = (surface, method, args) => {
    const envelope = __legadoBridge(surface, method, args);
    if (envelope && typeof envelope.then === 'function') {
      return envelope.then(__unwrapBridge);
    }
    return __unwrapBridge(envelope);
  };
  const __proxy = (surface) => new Proxy({}, {
    get: (_, method) => (...args) => {
      const value = __callBridge(surface, String(method), args);
      if (surface === 'java' && ['connect', 'get', 'head', 'post'].includes(String(method))) {
        if (value && typeof value.then === 'function') return value.then(__response);
        return __response(value);
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
        return (...args) => __callBridge('source', String(property), args);
      }
      const name = String(property);
      if (name.startsWith('get') && name.length > 3) {
        const field = name.charAt(3).toLowerCase() + name.slice(4);
        return () => target[field];
      }
      if (name.startsWith('set') && name.length > 3) {
        const field = name.charAt(3).toLowerCase() + name.slice(4);
        return (value) => {
          const saved = __callBridge(surface, 'setField', [field, value]);
          target[field] = saved;
          return saved;
        };
      }
      return target[property];
    },
    set: (target, property, value) => {
      if (property !== 'variable') {
        throw new Error('source 只允许修改 variable');
      }
      target[property] = value;
      __callBridge('source', 'setVariable', [String(value)]);
      return true;
    }
  });
  // 创建兼容 Java MutableMap 常用方法的模型变量 Map，并把写入同步回宿主模型状态。
  const __modelVariableMap = (surface, target) => {
    const values = __callBridge(surface, 'getVariableMap', []);
    const map = new Map(Object.entries(values));
    const nativeSet = map.set.bind(map);
    map.put = (key, value) => {
      const normalizedKey = String(key);
      const previous = map.has(normalizedKey) ? map.get(normalizedKey) : null;
      const updated = __callBridge(surface, 'putVariable', [normalizedKey, String(value)]);
      target.variable = updated.variable;
      nativeSet(normalizedKey, String(value));
      return previous;
    };
    map.containsKey = (key) => map.has(String(key));
    return map;
  };
  const __model = (surface, value) => value == null ? null : new Proxy(value, {
    get: (target, property) => {
      const name = String(property);
      if (name === 'getVariable') {
        return (key) => __callBridge(surface, 'getVariable', [String(key)]);
      }
      if (name === 'putVariable') {
        return (key, value) => {
          const updated = __callBridge(surface, 'putVariable', [String(key), String(value)]);
          target.variable = updated.variable;
          return updated.value;
        };
      }
      if (name === 'getVariableMap') {
        return () => __modelVariableMap(surface, target);
      }
      if (name.startsWith('get') && name.length > 3) {
        const field = name.charAt(3).toLowerCase() + name.slice(4);
        return () => target[field];
      }
      return target[property];
    },
    set: (target, property, value) => {
      const name = String(property);
      const saved = __callBridge(surface, 'setField', [name, value]);
      target[property] = saved;
      return true;
    }
  });
  globalThis.book = __model('book', __bindings.book);
  globalThis.chapter = __model('chapter', __bindings.chapter);
  globalThis.result = __response(__bindings.result);
  globalThis.Java = Object.freeze({
    type: (className) => __proxy('class:' + String(className))
  });
  const __package = (parts) => new Proxy(function () {}, {
    get: (_, property) => {
      if (property === 'then') return undefined;
      return __package([...parts, String(property)]);
    },
    apply: (_, __, args) => {
      if (parts.length < 2) throw new Error('Packages 调用缺少类名或方法名');
      const method = parts[parts.length - 1];
      const className = parts.slice(0, -1).join('.');
      return __callBridge('class:' + className, method, args);
    }
  });
  globalThis.Packages = __package([]);
  globalThis.org = __package(['org']);
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
    /// 【FLUTTER_JS_COMPAT_LOG】使用 JSF 原始消息，避免异常包装前缀干扰分类和行列定位。
    final String text = _safeErrorText(error.message);
    /// 错误分类文本。
    final String lower = text.toLowerCase();
    /// 结构化宿主桥错误标记；只包含固定分类和桥自身生成的安全消息。
    final RegExpMatch? bridgeFailure = RegExp(
      r'__LEGADO_BRIDGE_ERROR__([A-Za-z]+):',
    ).firstMatch(text);
    /// 宿主桥返回的固定失败分类；未知分类统一收敛为 bridge。
    final JsFailureKind? bridgeFailureKind = bridgeFailure == null
        ? null
        : _bridgeFailureKind(bridgeFailure.group(1));
    /// 错误分类。
    final JsFailureKind kind = cancellationToken?.isCancelled == true
        ? JsFailureKind.cancelled
        : bridgeFailureKind != null
        ? bridgeFailureKind
        : lower.contains('timeout') || lower.contains('interrupt')
        ? JsFailureKind.timeout
        : lower.contains('memory')
        ? JsFailureKind.memoryLimit
        : lower.contains('stack')
        ? JsFailureKind.stackOverflow
        : lower.contains('syntax')
        ? JsFailureKind.syntax
        : JsFailureKind.runtime;
    /// 【FLUTTER_JS_COMPAT_LOG】QuickJS 错误文本中可选的脚本行列位置，供统一诊断日志定位。
    final RegExpMatch? sourcePosition = RegExp(r':(\d+)(?::(\d+))?(?:\D|$)').firstMatch(text);
    return JsEngineException(
      kind: kind,
      message: kind == JsFailureKind.cancelled ? '脚本执行已取消' : 'JavaScript 执行失败',
      scriptName: scriptName,
      line: int.tryParse(sourcePosition?.group(1) ?? ''),
      column: int.tryParse(sourcePosition?.group(2) ?? ''),
      stack: text,
      bridgeCalls: List<String>.unmodifiable(
        _activeContext?.bridgeCalls ?? const <String>[],
      ),
    );
  }

  /// 将 JavaScript 错误标记中的固定名称还原为宿主桥失败枚举。
  JsFailureKind _bridgeFailureKind(String? value) {
    for (final JsFailureKind kind in JsFailureKind.values) {
      if (kind.name == value) {
        return kind;
      }
    }
    return JsFailureKind.bridge;
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

/// 单次宿主调用的内存签名，用于确认脚本重放仍沿着相同调用顺序执行。
final class _SynchronousBridgeCallSignature {
  /// 创建不写入日志的宿主调用签名。
  const _SynchronousBridgeCallSignature({
    required this.surface,
    required this.method,
  });

  /// 脚本可见对象表面，例如 `java`、`cookie` 或 `cache`。
  final String surface;

  /// 脚本调用的方法名。
  final String method;

  /// 判断两次调用是否具有相同表面和方法；参数可能包含时间戳或随机数，重放必须复用首次值。
  bool matches(_SynchronousBridgeCallSignature other) {
    return surface == other.surface && method == other.method;
  }
}

/// 已完成宿主调用及其结构化返回信封。
final class _SynchronousBridgeReplayEntry {
  /// 创建不可变重放项。
  const _SynchronousBridgeReplayEntry({required this.signature, required this.envelope});

  /// 原始宿主调用签名。
  final _SynchronousBridgeCallSignature signature;

  /// 成功或失败信封；重放时直接同步返回给 QuickJS。
  final Map<String, Object?> envelope;
}

/// 正在等待 Dart Future 的宿主调用。
final class _PendingSynchronousBridgeCall {
  /// 创建待完成调用。
  const _PendingSynchronousBridgeCall({required this.signature, required this.envelopeFuture});

  /// 待完成宿主调用签名。
  final _SynchronousBridgeCallSignature signature;

  /// 最终一定收敛为成功或失败信封的 Future。
  final Future<Map<String, Object?>> envelopeFuture;
}

/// 在一次规则执行内保存宿主调用记录，让 Dart 异步能力对旧 Rhino 脚本表现为同步返回。
final class _SynchronousBridgeReplay {
  /// 创建带有限记录数量的重放器。
  _SynchronousBridgeReplay({required this.maximumEntries});

  /// 单次规则允许保存的最大宿主调用数量。
  final int maximumEntries;

  /// 按脚本执行顺序保存的已完成宿主调用。
  final List<_SynchronousBridgeReplayEntry> _entries = <_SynchronousBridgeReplayEntry>[];

  /// 当前 QuickJS 尝试已经消费的记录位置。
  int _cursor = 0;

  /// 当前尝试发现的首个异步宿主调用。
  _PendingSynchronousBridgeCall? _pendingCall;

  /// 当前尝试是否正在等待宿主调用。
  bool get hasPendingCall => _pendingCall != null;

  /// 开始一次新的 QuickJS 重放尝试。
  void beginAttempt() {
    _cursor = 0;
    _pendingCall = null;
  }

  /// 返回当前位置已有的同步结果；没有历史记录时返回 null，表示需要真实调用宿主。
  Map<String, Object?>? replay(_SynchronousBridgeCallSignature signature) {
    if (_cursor >= _entries.length) {
      return null;
    }
    /// 当前脚本位置预期消费的历史调用。
    final _SynchronousBridgeReplayEntry entry = _entries[_cursor];
    if (!entry.signature.matches(signature)) {
      throw const JsEngineException(
        kind: JsFailureKind.bridge,
        message: '同步宿主调用重放路径发生变化',
      );
    }
    _cursor += 1;
    return entry.envelope;
  }

  /// 记录不需要等待的同步宿主调用，确保后续尝试不会重复其副作用。
  void recordImmediate(
    _SynchronousBridgeCallSignature signature,
    Map<String, Object?> envelope,
  ) {
    _ensureCapacity();
    _entries.add(_SynchronousBridgeReplayEntry(signature: signature, envelope: envelope));
    _cursor += 1;
  }

  /// 保存当前尝试发现的异步宿主调用；同一尝试只允许等待一个调用。
  void setPendingCall(
    _SynchronousBridgeCallSignature signature,
    Future<Map<String, Object?>> envelopeFuture,
  ) {
    if (_pendingCall != null) {
      return;
    }
    _ensureCapacity();
    _pendingCall = _PendingSynchronousBridgeCall(
      signature: signature,
      envelopeFuture: envelopeFuture,
    );
  }

  /// 等待异步宿主调用，并把最终信封追加到下一次可以同步读取的位置。
  Future<void> completePendingCall() async {
    /// 当前待完成调用的稳定局部引用。
    final _PendingSynchronousBridgeCall? pending = _pendingCall;
    if (pending == null) {
      return;
    }
    /// 已完成的成功或失败信封。
    final Map<String, Object?> envelope = await pending.envelopeFuture;
    _entries.add(
      _SynchronousBridgeReplayEntry(signature: pending.signature, envelope: envelope),
    );
    _pendingCall = null;
  }

  /// 在新增记录前检查单次规则上限。
  void _ensureCapacity() {
    if (_entries.length >= maximumEntries) {
      throw const JsEngineException(
        kind: JsFailureKind.bridge,
        message: '同步宿主调用数量超过单次规则上限',
      );
    }
  }
}
