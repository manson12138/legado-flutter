/// 对 SQLite 行执行受控类型读取，避免各 DAO 使用强制空值断言或动态调用。
final class SqliteRowReader {
  /// 创建只读行解析器。
  const SqliteRowReader(this.row);

  /// sqflite 返回的列名到受控对象值映射。
  final Map<String, Object?> row;

  /// 读取不可空字符串；数据库类型不符时抛出包含列名的格式错误。
  String requiredString(String columnName) {
    /// 目标列的原始数据库值。
    final Object? value = row[columnName];
    if (value is String) {
      return value;
    }
    throw FormatException('数据库列 $columnName 不是必需的字符串');
  }

  /// 读取可空字符串，并保留 `null` 与空字符串的差异。
  String? nullableString(String columnName) {
    /// 目标列的原始数据库值。
    final Object? value = row[columnName];
    if (value == null || value is String) {
      return value as String?;
    }
    throw FormatException('数据库列 $columnName 不是可空字符串');
  }

  /// 读取不可空整数；SQLite 返回的其他数值类型会安全转换为整数。
  int requiredInt(String columnName) {
    /// 目标列的原始数据库值。
    final Object? value = row[columnName];
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    throw FormatException('数据库列 $columnName 不是必需的整数');
  }

  /// 读取可空整数；`null` 表示该偏移或配置不适用。
  int? nullableInt(String columnName) {
    /// 目标列的原始数据库值。
    final Object? value = row[columnName];
    if (value == null) {
      return null;
    }
    if (value is num) {
      return value.toInt();
    }
    throw FormatException('数据库列 $columnName 不是可空整数');
  }

  /// 将 SQLite 的 0/1 整数读取为不可空布尔值。
  bool requiredBool(String columnName) => requiredInt(columnName) != 0;

  /// 将 SQLite 的可空 0/1 整数读取为可空布尔值。
  bool? nullableBool(String columnName) {
    /// 目标列的可空整数值。
    final int? value = nullableInt(columnName);
    return value == null ? null : value != 0;
  }
}
