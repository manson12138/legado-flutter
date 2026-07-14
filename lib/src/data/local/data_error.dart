import 'package:sqflite/sqflite.dart';

import '../../help/error/app_error.dart';

/// 表示数据层失败的稳定分类，避免上层依赖 sqflite 异常类型。
enum DataErrorKind {
  /// 主键、唯一索引、外键或不可空约束被违反。
  constraint,
  /// 已保存数据无法按声明类型或 JSON 结构解码。
  invalidStoredData,
  /// 数据库无法打开、关闭或执行操作。
  unavailable,
  /// 尚未精确分类但必须保留原因的数据层失败。
  unknown,
}

/// 保存数据层稳定错误与底层原因，仅供 Repository 转换使用。
final class DataException implements Exception {
  /// 创建不向 UI 泄漏数据库实现细节的数据异常。
  const DataException({
    required this.kind,
    required this.message,
    required this.cause,
    required this.stackTrace,
  });

  /// 数据失败分类。
  final DataErrorKind kind;
  /// 不包含 SQL、Cookie 或用户隐私内容的安全摘要。
  final String message;
  /// 原始异常，仅供诊断链路保留。
  final Object cause;
  /// 原始堆栈，保留失败位置。
  final StackTrace stackTrace;
}

/// 将任意 DAO 异常转换为稳定 [DataException]。
DataException toDataException(Object error, StackTrace stackTrace) {
  if (error is DataException) {
    return error;
  }
  if (error is FormatException) {
    return DataException(
      kind: DataErrorKind.invalidStoredData,
      message: '本地数据格式无效',
      cause: error,
      stackTrace: stackTrace,
    );
  }
  if (error is DatabaseException && _isConstraintError(error)) {
    return DataException(
      kind: DataErrorKind.constraint,
      message: '本地数据不满足唯一性或关联约束',
      cause: error,
      stackTrace: stackTrace,
    );
  }
  if (error is DatabaseException) {
    return DataException(
      kind: DataErrorKind.unavailable,
      message: '本地数据库暂时不可用',
      cause: error,
      stackTrace: stackTrace,
    );
  }
  return DataException(
    kind: DataErrorKind.unknown,
    message: '本地数据操作失败',
    cause: error,
    stackTrace: stackTrace,
  );
}

/// 判断旧版 sqflite 异常是否表示 SQLite 约束失败。
///
/// 优先检查 SQLite 标准结果码 19，同时保留唯一键、非空约束和平台错误文本回退，
/// 以兼容 Android 与 iOS 返回不同扩展结果码的情况。
bool _isConstraintError(DatabaseException error) {
  /// SQLite 原始或扩展结果码；扩展结果码的低 8 位仍为基础结果码。
  final int? resultCode = error.getResultCode();
  return (resultCode != null && (resultCode & 0xFF) == 19) ||
      error.isUniqueConstraintError() ||
      error.isNotNullConstraintError() ||
      error.toString().toLowerCase().contains('constraint failed');
}

/// 将数据层异常转换为领域和 UI 可识别的 [AppError]。
AppError dataExceptionToAppError(DataException error) {
  return AppError(
    kind: AppErrorKind.infrastructure,
    message: error.message,
    cause: error,
    stackTrace: error.stackTrace,
  );
}

/// 执行 Repository 数据操作，并保证抛出的失败都是稳定 [AppError]。
Future<T> guardDataOperation<T>(Future<T> Function() operation) async {
  try {
    return await operation();
  } on AppError {
    rethrow;
  } catch (error, stackTrace) {
    /// 当前底层错误对应的稳定数据异常。
    final DataException dataError = toDataException(error, stackTrace);
    throw dataExceptionToAppError(dataError);
  }
}

/// 包装 DAO 观察流，防止数据库异常直接穿过 Gateway。
Stream<T> guardDataStream<T>(Stream<T> source) async* {
  try {
    yield* source;
  } on AppError {
    rethrow;
  } catch (error, stackTrace) {
    /// 当前流失败对应的稳定数据异常。
    final DataException dataError = toDataException(error, stackTrace);
    throw dataExceptionToAppError(dataError);
  }
}
