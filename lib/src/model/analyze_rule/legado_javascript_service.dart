import '../../api/js/js_engine.dart';
import '../../api/js/js_engine_pool.dart';
import '../../api/js/script_context.dart';

/// Legado 规则层使用的 JavaScript 统一入口。
final class LegadoJavaScriptService {
  /// 创建 JavaScript 服务。
  LegadoJavaScriptService(this._pool);

  /// 书源隔离引擎池。
  final JsEnginePool _pool;

  /// 已加载当前书源 jsLib 的引擎。
  final Set<JsEngine> _initializedEngines = <JsEngine>{};

  /// 执行 `@js:`、`<js>` 或内嵌脚本正文。
  Future<JsBridgeValue> evaluate({
    required String scriptName,
    required String script,
    required LegadoScriptContext context,
    Map<String, JsBridgeValue> bindings = const <String, JsBridgeValue>{},
    Duration timeout = const Duration(seconds: 5),
    JsCancellationToken? cancellationToken,
  }) async {
    /// 当前书源引擎租约。
    final JsEngineLease lease = await _pool.acquire(context.source.bookSourceUrl);
    /// 是否允许归还后复用 Scope。
    bool reusable = false;
    try {
      await _ensureJsLib(
        lease.engine,
        context,
        timeout: timeout,
        cancellationToken: cancellationToken,
      );
      /// 去除规则标记后的原始 JavaScript 正文。
      final String normalizedScript = _normalizeRuleScript(script);
      /// 当前脚本首次执行请求。
      final JsEvaluationRequest request = JsEvaluationRequest(
        scriptName: scriptName,
        source: normalizedScript,
        bindings: bindings,
        timeout: timeout,
        cancellationToken: cancellationToken,
        hostContext: context,
      );
      /// 规则脚本执行结果；仅对 Rhino 允许的顶层 `return` 做一次函数作用域兼容重试。
      JsBridgeValue result;
      try {
        result = await lease.engine.evaluate(request);
      } on JsEngineException catch (error) {
        if (!_requiresTopLevelReturnRetry(error)) {
          rethrow;
        }
        result = await lease.engine.evaluate(
          JsEvaluationRequest(
            scriptName: '$scriptName/top-level-return-compat',
            source: _wrapTopLevelReturn(normalizedScript),
            bindings: bindings,
            timeout: timeout,
            cancellationToken: cancellationToken,
            hostContext: context,
          ),
        );
      }
      reusable = true;
      return result;
    } finally {
      if (!reusable) {
        _initializedEngines.remove(lease.engine);
      }
      await lease.release(reusable: reusable);
    }
  }

  /// 首次使用引擎时加载书源公共 jsLib。
  Future<void> _ensureJsLib(
    JsEngine engine,
    LegadoScriptContext context, {
    required Duration timeout,
    JsCancellationToken? cancellationToken,
  }) async {
    if (_initializedEngines.contains(engine)) {
      return;
    }
    /// 书源公共脚本。
    final String? jsLib = context.source.jsLib;
    if (jsLib != null && jsLib.trim().isNotEmpty) {
      await engine.evaluate(
        JsEvaluationRequest(
          scriptName: '${context.source.bookSourceName}/jsLib',
          source: jsLib,
          timeout: timeout,
          cancellationToken: cancellationToken,
          hostContext: context,
        ),
      );
    }
    _initializedEngines.add(engine);
  }

  /// 去除 Android 规则标记，只把真实源码交给引擎。
  String _normalizeRuleScript(String script) {
    /// 去除首尾空白后的脚本。
    final String trimmed = script.trim();
    if (trimmed.toLowerCase().startsWith('@js:')) {
      return trimmed.substring(4);
    }
    if (trimmed.toLowerCase().startsWith('<js>') &&
        trimmed.toLowerCase().endsWith('</js>')) {
      return trimmed.substring(4, trimmed.length - 5);
    }
    return script;
  }

  /// 判断 QuickJS 错误是否为 Rhino 可接受的顶层 `return` 语法差异。
  bool _requiresTopLevelReturnRetry(JsEngineException error) {
    if (error.kind != JsFailureKind.syntax) {
      return false;
    }
    /// 小写引擎错误摘要，用于兼容 JSF 当前返回的两种常见表述。
    final String detail = (error.stack ?? error.message).toLowerCase();
    return detail.contains('return not in a function') ||
        detail.contains('illegal return statement');
  }

  /// 把包含顶层 `return` 的 Rhino 规则放入普通函数作用域执行。
  String _wrapTopLevelReturn(String script) {
    return '(function () {\n$script\n}).call(globalThis)';
  }

  /// 关闭引擎池并释放所有原生资源。
  Future<void> close() async {
    _initializedEngines.clear();
    await _pool.close();
  }
}
