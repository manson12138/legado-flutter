import 'package:mmkv/mmkv.dart';

import 'app_preferences_store.dart';

/// 使用单进程 MMKV 实现应用小型偏好的同步读写。
///
/// 该类型只能在数据层和应用组合根中创建，不能传入 Widget、ViewModel、
/// UseCase 或领域模型。
final class MmkvAppPreferencesStore implements AppPreferencesStore {
  /// 使用已经在启动阶段完成初始化的 MMKV 实例创建存储。
  const MmkvAppPreferencesStore(this._storage);

  /// 当前应用唯一的小型偏好 MMKV 实例。
  final MMKV _storage;

  @override
  bool contains(String key) => _storage.containsKey(key);

  @override
  bool? readBool(String key) {
    if (!_storage.containsKey(key)) {
      return null;
    }
    return _storage.decodeBool(key);
  }

  @override
  int? readInt(String key) {
    if (!_storage.containsKey(key)) {
      return null;
    }
    return _storage.decodeInt(key);
  }

  @override
  double? readDouble(String key) {
    if (!_storage.containsKey(key)) {
      return null;
    }
    return _storage.decodeDouble(key);
  }

  @override
  String? readString(String key) {
    if (!_storage.containsKey(key)) {
      return null;
    }
    return _storage.decodeString(key);
  }

  @override
  bool writeBool(String key, bool value) => _storage.encodeBool(key, value);

  @override
  bool writeInt(String key, int value) => _storage.encodeInt(key, value);

  @override
  bool writeDouble(String key, double value) =>
      _storage.encodeDouble(key, value);

  @override
  bool writeString(String key, String value) =>
      _storage.encodeString(key, value);

  @override
  void remove(String key) {
    _storage.removeValue(key);
  }
}
