import 'app_preferences_store.dart';

/// MMKV 初始化失败时使用的进程内偏好降级实现。
///
/// 数据只在当前进程存活期间保留，目的是保证应用仍可进入并使用受控默认值；
/// 下次冷启动会重新尝试初始化 MMKV。
final class MemoryAppPreferencesStore implements AppPreferencesStore {
  /// 创建空的进程内偏好存储。
  MemoryAppPreferencesStore();

  /// 当前进程内按键保存的基础类型值。
  final Map<String, Object> _values = <String, Object>{};

  @override
  bool contains(String key) => _values.containsKey(key);

  @override
  bool? readBool(String key) {
    final Object? value = _values[key];
    return value is bool ? value : null;
  }

  @override
  int? readInt(String key) {
    final Object? value = _values[key];
    return value is int ? value : null;
  }

  @override
  double? readDouble(String key) {
    final Object? value = _values[key];
    return value is double ? value : null;
  }

  @override
  String? readString(String key) {
    final Object? value = _values[key];
    return value is String ? value : null;
  }

  @override
  bool writeBool(String key, bool value) {
    _values[key] = value;
    return true;
  }

  @override
  bool writeInt(String key, int value) {
    _values[key] = value;
    return true;
  }

  @override
  bool writeDouble(String key, double value) {
    _values[key] = value;
    return true;
  }

  @override
  bool writeString(String key, String value) {
    _values[key] = value;
    return true;
  }

  @override
  void remove(String key) {
    _values.remove(key);
  }
}
