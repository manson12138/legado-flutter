import 'app_error.dart';

/// 表示一个明确成功值或明确失败原因的领域操作结果。
sealed class AppResult<T> {
  /// 限制结果实例只能由本文件定义的成功或失败类型创建。
  const AppResult();
}

/// 保存领域操作成功后的不可变结果值。
final class AppSuccess<T> extends AppResult<T> {
  /// 创建包含成功数据的结果。
  const AppSuccess(this.value);

  /// 操作成功产生的数据。
  final T value;
}

/// 保存领域操作失败后的受控应用错误。
final class AppFailure<T> extends AppResult<T> {
  /// 创建包含明确失败原因的结果。
  const AppFailure(this.error);

  /// 操作失败的分类、摘要和可选原始原因。
  final AppError error;
}
