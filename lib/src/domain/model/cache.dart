/// 表示带可选过期时间的通用缓存，对应 Android `data.entities.Cache`。
final class Cache {
  /// 创建不可变缓存记录。
  const Cache({required this.key, this.value, this.deadline = 0});

  /// 缓存键，也是表主键。
  final String key;
  /// 缓存值；`null` 与空字符串保持不同语义。
  final String? value;
  /// 过期时间，Unix Epoch 毫秒；0 表示永不过期。
  final int deadline;
}
