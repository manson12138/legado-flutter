import 'js_engine.dart';

/// 书源隔离的 JavaScript 引擎租约。
final class JsEngineLease {
  /// 创建租约；只允许池内部调用。
  JsEngineLease._(this.engine, this._release);

  /// 当前书源独占引擎。
  final JsEngine engine;

  /// 归还回调。
  final Future<void> Function({required bool reusable}) _release;

  /// 是否已经归还。
  bool _released = false;

  /// 归还引擎；脚本污染 Scope 或运行失败时传 `reusable: false`。
  Future<void> release({required bool reusable}) async {
    if (_released) {
      return;
    }
    _released = true;
    await _release(reusable: reusable);
  }
}

/// 按书源键隔离的轻量引擎池。
///
/// 每个书源最多保留一个空闲 Scope；不同书源永不复用同一实例，避免变量、Cookie 引用和
/// jsLib 状态泄漏。跨书源并发上限仍由上层业务调度器控制。
final class JsEnginePool {
  /// 创建引擎池。
  JsEnginePool(this._factory, {this.maxIdlePerSource = 1});

  /// 引擎工厂。
  final JsEngineFactory _factory;

  /// 每个书源保留的最大空闲引擎数。
  final int maxIdlePerSource;

  /// 按书源保存的空闲引擎。
  final Map<String, List<JsEngine>> _idle = <String, List<JsEngine>>{};

  /// 当前活跃引擎。
  final Set<JsEngine> _active = <JsEngine>{};

  /// 是否已经关闭池。
  bool _closed = false;

  /// 获取指定书源的独占引擎。
  Future<JsEngineLease> acquire(String sourceId) async {
    if (_closed) {
      throw const JsEngineException(
        kind: JsFailureKind.closed,
        message: 'JavaScript 引擎池已关闭',
      );
    }
    /// 当前书源空闲列表。
    final List<JsEngine> idle = _idle.putIfAbsent(sourceId, () => <JsEngine>[]);
    /// 可用引擎。
    final JsEngine engine = idle.isEmpty
        ? await _factory.create(sourceId: sourceId)
        : idle.removeLast();
    _active.add(engine);
    return JsEngineLease._(
      engine,
      ({required bool reusable}) => _release(sourceId, engine, reusable: reusable),
    );
  }

  /// 归还或销毁引擎。
  Future<void> _release(
    String sourceId,
    JsEngine engine, {
    required bool reusable,
  }) async {
    _active.remove(engine);
    if (_closed || !reusable || engine.isClosed) {
      await engine.close();
      return;
    }
    /// 当前书源空闲列表。
    final List<JsEngine> idle = _idle.putIfAbsent(sourceId, () => <JsEngine>[]);
    if (idle.length >= maxIdlePerSource) {
      await engine.close();
    } else {
      idle.add(engine);
    }
  }

  /// 关闭全部空闲和活跃引擎。
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    /// 等待关闭的全部引擎。
    final Set<JsEngine> engines = <JsEngine>{
      ..._active,
      ..._idle.values.expand((List<JsEngine> value) => value),
    };
    _active.clear();
    _idle.clear();
    for (final JsEngine engine in engines) {
      await engine.close();
    }
  }
}
