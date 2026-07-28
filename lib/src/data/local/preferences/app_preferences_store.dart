/// 应用内小型非关系偏好的同步键值存储边界。
///
/// Widget、ViewModel、UseCase 和领域模型不得依赖具体 MMKV 类型；各 Feature
/// 应继续通过类型化偏好服务使用本接口，避免在业务代码中散落键名。
abstract interface class AppPreferencesStore {
  /// 判断指定键当前是否存在。
  bool contains(String key);

  /// 读取布尔值；键不存在或底层值无法按该类型读取时返回 `null`。
  bool? readBool(String key);

  /// 读取整数值；键不存在或底层值无法按该类型读取时返回 `null`。
  int? readInt(String key);

  /// 读取浮点值；键不存在或底层值无法按该类型读取时返回 `null`。
  double? readDouble(String key);

  /// 读取字符串；键不存在或底层值无法按该类型读取时返回 `null`。
  String? readString(String key);

  /// 写入布尔值，并返回底层是否接受本次写入。
  bool writeBool(String key, bool value);

  /// 写入整数值，并返回底层是否接受本次写入。
  bool writeInt(String key, int value);

  /// 写入浮点值，并返回底层是否接受本次写入。
  bool writeDouble(String key, double value);

  /// 写入字符串，并返回底层是否接受本次写入。
  bool writeString(String key, String value);

  /// 删除指定键；键不存在时保持幂等。
  void remove(String key);
}
