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
      /// 规则脚本执行结果。
      final JsBridgeValue result = await lease.engine.evaluate(
        JsEvaluationRequest(
          scriptName: scriptName,
          source: _normalizeRuleScript(script),
          bindings: bindings,
          timeout: timeout,
          cancellationToken: cancellationToken,
          hostContext: context,
        ),
      );
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

  /// 关闭引擎池并释放所有原生资源。
  Future<void> close() async {
    _initializedEngines.clear();
    await _pool.close();
  }
}
