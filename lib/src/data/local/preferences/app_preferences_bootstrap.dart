import 'package:mmkv/mmkv.dart';

import '../../../help/logging/app_logger.dart';
import 'app_preferences_store.dart';
import 'memory_app_preferences_store.dart';
import 'mmkv_app_preferences_store.dart';

/// 在 Flutter 首帧后单飞初始化应用唯一的 MMKV 偏好实例。
abstract final class AppPreferencesBootstrap {
  /// 应用小型偏好共用的单进程 MMKV 文件标识。
  static const String _storageId = 'legado.preferences';

  /// 当前进程共享的初始化任务，避免 Widget 重建或并发入口重复初始化原生库。
  static Future<AppPreferencesStore>? _initializationFuture;

  /// 返回当前进程唯一的偏好存储；MMKV 不可用时返回内存降级实现。
  static Future<AppPreferencesStore> initialize({
    required AppLogger logger,
  }) {
    final Future<AppPreferencesStore>? existing = _initializationFuture;
    if (existing != null) {
      return existing;
    }
    final Future<AppPreferencesStore> initialization = _initialize(logger);
    _initializationFuture = initialization;
    return initialization;
  }

  /// 执行一次 MMKV 原生初始化，不记录根目录、键名或偏好值。
  static Future<AppPreferencesStore> _initialize(AppLogger logger) async {
    try {
      await MMKV.initialize();
      final MMKV storage = MMKV(_storageId);
      logger.info(
        tag: appStartupLogTag,
        message: 'stage=app_preferences_ready backend=mmkv',
      );
      return MmkvAppPreferencesStore(storage);
    } on Object catch (error) {
      logger.warning(
        tag: appStartupLogTag,
        message:
            'stage=app_preferences_degraded backend=memory error_type=${error.runtimeType}',
      );
      return MemoryAppPreferencesStore();
    }
  }
}
